"""Random-access, windowed CorridorKey inference for host plug-ins.

The command-line runtime streams a whole clip front to back. Editing hosts
(Final Cut Pro, Motion, ...) ask for one output frame at a time, in any order,
but can hand the plug-in a few neighbouring frames along with it. This module
keys one *center* frame using a small temporal window around it:

    frames  t-k ... t ... t+k   ->  stage 1 over the window (same as one Hann
                                    window of the CLI runtime), then stage 2
                                    on the center frame only.

Per-frame foundation features (C-RADIO + MoGe) are cached by content hash, so
scrubbing or rendering sequentially through a clip reuses them across windows.
RVM is recurrent, so it is re-run over each window from a fresh state (it is
small, at 1/4 resolution).

All image I/O is HWC float32/float16 numpy in scene-linear light, which is what
FxPlug hands a plug-in that asks for kFxImageColorInfo_RGB_LINEAR.
"""
from __future__ import annotations

import threading
from collections import OrderedDict
from dataclasses import dataclass

import numpy as np
import torch
import torch.nn.functional as F

from . import color_utils as cu
from . import device as dev
from .runtime import _build_foundation_inputs, _despill_average_srgb_torch

# Linear-light gamut conversions (D65), from ITU-R BT.2087 / BT.2020.
_REC2020_TO_REC709 = torch.tensor([
    [1.660491, -0.587641, -0.072850],
    [-0.124550, 1.132900, -0.008349],
    [-0.018151, -0.100579, 1.118730],
], dtype=torch.float32)
_REC709_TO_REC2020 = torch.tensor([
    [0.627404, 0.329283, 0.043313],
    [0.069097, 0.919540, 0.011362],
    [0.016391, 0.088013, 0.895595],
], dtype=torch.float32)

OUTPUT_MODES = ("composite", "matte", "foreground", "orientation")


@dataclass
class KeyParams:
    output: str = "composite"        # one of OUTPUT_MODES
    despill: float = 0.5             # 0..1, applied to composite/foreground
    hint_quality: float = 0.95       # trust in explicit hints
    gamut: str = "rec709"            # working gamut of the incoming pixels
    flip_vertical: bool = False      # input rows are bottom-up
    matte_clip_black: float = 0.0    # optional matte levels (0 = off)
    matte_clip_white: float = 1.0

    def cache_tag(self) -> tuple:
        return (self.output, round(self.despill, 4), round(self.hint_quality, 4),
                self.gamut, self.flip_vertical,
                round(self.matte_clip_black, 4), round(self.matte_clip_white, 4))


class _LRU:
    """Byte-budgeted LRU, thread-safe."""

    def __init__(self, budget_bytes: int):
        self.budget = int(budget_bytes)
        self.used = 0
        self.items: OrderedDict = OrderedDict()
        self.lock = threading.Lock()

    @staticmethod
    def _size(value) -> int:
        if isinstance(value, np.ndarray):
            return value.nbytes
        if isinstance(value, torch.Tensor):
            return value.numel() * value.element_size()
        if isinstance(value, (tuple, list)):
            return sum(_LRU._size(v) for v in value)
        if isinstance(value, dict):
            return sum(_LRU._size(v) for v in value.values())
        if isinstance(value, (bytes, bytearray)):
            return len(value)
        return 64

    def get(self, key):
        with self.lock:
            if key not in self.items:
                return None
            self.items.move_to_end(key)
            return self.items[key]

    def __contains__(self, key):
        with self.lock:
            return key in self.items

    def put(self, key, value):
        size = self._size(value)
        if size > self.budget:
            return
        with self.lock:
            if key in self.items:
                self.used -= self._size(self.items.pop(key))
            self.items[key] = value
            self.used += size
            while self.used > self.budget and self.items:
                _, old = self.items.popitem(last=False)
                self.used -= self._size(old)


class FrameEngine:
    """Keys single frames with optional temporal context. One GPU job at a time."""

    shape_quantum = 128

    def __init__(self, model, *, frame_cache_gb: float = 4.0,
                 feature_cache_gb: float = 2.0, result_cache_gb: float = 2.0):
        self.model = model
        self.device = torch.device(dev.active())
        self.frames = _LRU(int(frame_cache_gb * 2**30))      # hash -> HxWx4 f16 numpy
        self.hints = _LRU(int(frame_cache_gb * 2**28))       # hash -> HxW f16 numpy
        self.features = _LRU(int(feature_cache_gb * 2**30))  # (hash, tag) -> dict
        self.results = _LRU(int(result_cache_gb * 2**30))    # key -> HxWx4 f16 numpy
        self.gpu_lock = threading.Lock()
        # Everything stays resident on the compute device. On Apple Silicon this
        # is unified memory, so there is nothing to gain from shuffling modules
        # back to the CPU the way the CUDA CLI path does.
        model.to(self.device)
        model.eval()

    # ------------------------------------------------------------------ cache

    def missing(self, frame_hashes, hint_hashes) -> list[str]:
        need = [h for h in frame_hashes if h not in self.frames]
        need += [h for h in hint_hashes if h not in self.hints]
        # de-duplicate, keep order
        return list(dict.fromkeys(need))

    def add_frame(self, h: str, rgba: np.ndarray) -> None:
        self.frames.put(h, rgba)

    def add_hint(self, h: str, matte: np.ndarray) -> None:
        self.hints.put(h, matte)

    # --------------------------------------------------------------- tensors

    def _to_linear709(self, rgba: np.ndarray, params: KeyParams) -> tuple[torch.Tensor, torch.Tensor]:
        """HWC RGBA numpy -> (3,H,W) straight linear Rec.709 RGB, (1,H,W) alpha, on device."""
        t = torch.from_numpy(np.ascontiguousarray(rgba)).to(self.device).float()
        if params.flip_vertical:
            t = torch.flip(t, dims=[0])
        rgb = t[..., :3].permute(2, 0, 1)
        alpha = t[..., 3:4].permute(2, 0, 1).clamp(0.0, 1.0)
        # Hosts hand over premultiplied pixels; the model wants straight color.
        rgb = torch.where(alpha > 1e-4, rgb / alpha.clamp(min=1e-4), rgb)
        if params.gamut == "rec2020":
            rgb = torch.einsum("ij,jhw->ihw", _REC2020_TO_REC709.to(self.device), rgb)
        return rgb, alpha

    def _pad(self, x: torch.Tensor, Hp: int, Wp: int) -> torch.Tensor:
        H, W = x.shape[-2:]
        pt, pl = (Hp - H) // 2, (Wp - W) // 2
        pb, pr = Hp - H - pt, Wp - W - pl
        if not (pt or pb or pl or pr):
            return x
        mode = "reflect" if (pt < H and pb < H and pl < W and pr < W) else "replicate"
        squeeze = x.dim() == 3
        y = F.pad(x.unsqueeze(0) if squeeze else x, (pl, pr, pt, pb), mode=mode)
        return y[0] if squeeze else y

    @torch.no_grad()
    def _foundation_feats(self, h: str, display: torch.Tensor, params: KeyParams):
        """Normalized C-RADIO/MoGe features at /64 for one padded display frame, cached."""
        key = (h, params.gamut, params.flip_vertical, tuple(display.shape[-2:]))
        hit = self.features.get(key)
        if hit is not None:
            return hit
        rgb = display.unsqueeze(0).unsqueeze(0)  # (1,1,3,H,W)
        rgb_radio, rgb_moge = _build_foundation_inputs(rgb)
        with dev.autocast():
            ff = self.model.foundations(
                rgb_cradio=rgb_radio.reshape(1, 3, *rgb_radio.shape[-2:]),
                rgb_moge=rgb_moge.reshape(1, 3, *rgb_moge.shape[-2:]),
            )
        out = {k: ff[k].float().cpu().to(torch.float16)
               for k in ("cradio", "moge") if ff.get(k) is not None}
        self.features.put(key, out)
        return out

    # ---------------------------------------------------------------- keying

    @torch.no_grad()
    def key(self, frame_hashes: list[str], center: int, params: KeyParams,
            hint_hashes: dict[int, str] | None = None) -> np.ndarray:
        """Return HxWx4 float16 RGBA (premultiplied, same gamut/orientation as input)."""
        hint_hashes = dict(hint_hashes or {})
        if not frame_hashes:
            raise ValueError("no frames")
        center = max(0, min(int(center), len(frame_hashes) - 1))
        rkey = (tuple(frame_hashes), center,
                tuple(sorted(hint_hashes.items())), params.cache_tag())
        hit = self.results.get(rkey)
        if hit is not None:
            return hit

        frames = []
        for h in frame_hashes:
            f = self.frames.get(h)
            if f is None:
                raise KeyError(f"frame {h} not uploaded")
            frames.append(f)
        H, W = frames[center].shape[:2]
        if any(f.shape[:2] != (H, W) for f in frames):
            # A neighbour with a different size (e.g. clip edge) is useless context.
            keep = [i for i, f in enumerate(frames) if f.shape[:2] == (H, W)]
            center = keep.index(center)
            frames = [frames[i] for i in keep]
            frame_hashes = [frame_hashes[i] for i in keep]
            hint_hashes = {keep.index(i): v for i, v in hint_hashes.items() if i in keep}

        if params.output == "orientation":
            return self._orientation_card(frames[center], params)

        with self.gpu_lock:
            # Hosts often ask for the same frame from several threads at once.
            hit = self.results.get(rkey)
            if hit is not None:
                return hit
            out = self._key_locked(frames, frame_hashes, center, params, hint_hashes, H, W)
            self.results.put(rkey, out)
        return out

    def _key_locked(self, frames, frame_hashes, center, params, hint_hashes, H, W):
        model = self.model
        q = self.shape_quantum
        Hp, Wp = -(-H // q) * q, -(-W // q) * q
        T = len(frames)
        pad_t, pad_l = (Hp - H) // 2, (Wp - W) // 2

        model_frames, display_frames, cradio, moge = [], [], [], []
        center_alpha = None
        for i, (h, f) in enumerate(zip(frame_hashes, frames)):
            linear, alpha = self._to_linear709(f, params)
            if i == center:
                center_alpha = alpha
            display = cu.linear_to_vfm_sdr_torch(linear)
            model_in = cu.linear_to_asinh(linear)
            display = self._pad(display, Hp, Wp)
            model_in = self._pad(model_in, Hp, Wp)
            feats = self._foundation_feats(h, display, params)
            model_frames.append(model_in)
            display_frames.append(display)
            moge.append(feats["moge"])
            if "cradio" in feats:
                cradio.append(feats["cradio"])

        cdt = dev.compute_dtype()
        rgb = torch.stack(model_frames).unsqueeze(0).to(cdt)               # (1,T,3,Hp,Wp)
        moge_feat = torch.cat(moge).unsqueeze(0).to(self.device).float()   # (1,T,C,h,w)
        cradio_feat = (torch.cat(cradio).unsqueeze(0).to(self.device).float()
                       if cradio else None)

        rvm_feat = None
        if model.foundations.rvm is not None:
            disp = torch.stack(display_frames)                             # (T,3,Hp,Wp)
            He, We = Hp // 4, Wp // 4
            rgb_rvm = F.interpolate(disp.float(), size=(He, We), mode="bilinear",
                                    align_corners=False).clamp(0.0, 1.0).unsqueeze(0)
            with dev.autocast():
                feats, _state = model.foundations.rvm(rgb_rvm, state=None)
            mean = model.foundations.rvm_mean.view(1, 1, -1, 1, 1).float()
            std = model.foundations.rvm_std.view(1, 1, -1, 1, 1).float().clamp(min=1e-6)
            rvm_feat = (feats.float() - mean) / std

        hint = torch.zeros(1, T, 1, Hp, Wp, device=self.device, dtype=cdt)
        hint_q = torch.zeros(1, T, device=self.device, dtype=cdt)
        any_hint = False
        for i, hh in hint_hashes.items():
            matte = self.hints.get(hh)
            if matte is None or not (0 <= i < T):
                continue
            m = torch.from_numpy(np.ascontiguousarray(matte)).to(self.device).float()
            if params.flip_vertical:
                m = torch.flip(m, dims=[0])
            if m.shape != (H, W):
                m = F.interpolate(m[None, None], size=(H, W), mode="bilinear",
                                  align_corners=False)[0, 0]
            hint[0, i, 0] = self._pad(m.clamp(0, 1)[None], Hp, Wp)[0].to(cdt)
            hint_q[0, i] = float(params.hint_quality)
            any_hint = True
        if not any_hint:
            hint_q.fill_(-1.0)   # "decide the subject yourself"

        with dev.autocast():
            s1 = model.stage1(rgb, hint, moge_feat, cradio_feat=cradio_feat,
                              rvm_feat=rvm_feat, t_stride=1.0, hint_quality=hint_q)
        baton = s1["baton"][:, center:center + 1].float()                  # (1,1,d,h16,w16)
        with torch.inference_mode(), dev.autocast():
            logits = model.stage2(rgb[:, center:center + 1], baton)
            if isinstance(logits, tuple):
                logits = logits[0]
        logits = logits[0, 0].float()[:, pad_t:pad_t + H, pad_l:pad_l + W]  # (4,H,W)
        del s1, baton, rgb, hint, moge_feat, cradio_feat, rvm_feat

        alpha = logits[0:1].clamp(0.0, 1.0)
        lo, hi = float(params.matte_clip_black), float(params.matte_clip_white)
        if lo > 0.0 or hi < 1.0:
            alpha = ((alpha - lo) / max(hi - lo, 1e-4)).clamp(0.0, 1.0)
        fg = cu.asinh_to_linear(logits[1:4])
        fg = _despill_average_srgb_torch(fg[None], strength=float(params.despill))[0]

        if params.output == "matte":
            rgb_out, a_out = alpha.expand(3, -1, -1), torch.ones_like(alpha)
        elif params.output == "foreground":
            rgb_out, a_out = fg, torch.ones_like(alpha)
        else:  # composite: premultiplied keyed foreground, respecting source alpha
            a_out = alpha * center_alpha
            rgb_out = fg * a_out
        if params.gamut == "rec2020" and params.output != "matte":
            rgb_out = torch.einsum("ij,jhw->ihw", _REC709_TO_REC2020.to(rgb_out.device), rgb_out)
        out = torch.cat([rgb_out, a_out], dim=0).permute(1, 2, 0)
        if params.flip_vertical:
            out = torch.flip(out, dims=[0])
        dev.empty_cache()
        return out.clamp(-65000, 65000).to(torch.float16).cpu().numpy()

    def _orientation_card(self, frame: np.ndarray, params: KeyParams) -> np.ndarray:
        """Source image with a white arrow in what the *model* thinks is the top-left.

        If the arrow shows up at the bottom of the viewer, the host delivers
        bottom-up rows: toggle "Flip Vertical" in the effect.
        """
        out = np.array(frame, dtype=np.float16, copy=True)
        H, W = out.shape[:2]
        s = max(16, min(H, W) // 6)
        y, x = np.mgrid[0:s, 0:s]
        tri = np.abs(x - (s - 1) / 2.0) <= y * 0.5   # arrowhead pointing up
        r0 = s // 4
        r1, c1 = min(H, r0 + s), min(W, r0 + s)
        mask = np.zeros((H, W), bool)
        mask[r0:r1, r0:c1] = tri[:r1 - r0, :c1 - r0]
        if params.flip_vertical:
            mask = mask[::-1]
        out[mask] = np.array([1, 1, 1, 1], np.float16)
        return out
