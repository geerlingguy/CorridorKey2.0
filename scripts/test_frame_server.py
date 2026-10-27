#!/usr/bin/env python3
"""Offline test of the plug-in render path (FrameEngine + ck_server protocol).

Builds a *tiny, randomly initialised* CorridorKey (real Stage1/Stage2/RVM code,
stand-in C-RADIO/MoGe) so the whole windowed pipeline, the caches and the wire
protocol can be exercised on CPU without the 5 GB of weights. Output values are
meaningless; shapes, dtypes, caching and protocol behaviour are what's checked.

    python scripts/test_frame_server.py
"""
from __future__ import annotations

import os
import socket
import struct
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import numpy as np  # noqa: E402
import torch  # noqa: E402
import torch.nn as nn  # noqa: E402

import corridorkey.model as ck_model  # noqa: E402
from corridorkey import device as dev  # noqa: E402


class FakeFoundations(nn.Module):
    """Stand-in for C-RADIO + MoGe with the right output shapes; real RVM."""

    def __init__(self, device="cpu", **_):
        super().__init__()
        from corridorkey.rvm import RVMVideoSiamMAE
        self.use_moge, self.use_cradio, self.use_rvm = True, True, True
        self.rvm = RVMVideoSiamMAE(variant="small").to(device).eval()
        self.proj_c = nn.Conv2d(3, 32, 16, stride=16)
        self.proj_m = nn.Conv2d(3, 768, 14, stride=14)
        self.register_buffer("rvm_mean", torch.zeros(self.rvm.embed_dim))
        self.register_buffer("rvm_std", torch.ones(self.rvm.embed_dim))
        self.calls = 0

    cradio_dim = property(lambda self: 32)
    moge_dim = property(lambda self: 768)
    rvm_dim = property(lambda self: self.rvm.embed_dim)

    def forward(self, rgb_moge=None, rgb_cradio=None, rgb_rvm=None, rvm_state=None):
        self.calls += rgb_cradio.shape[0]
        return {"cradio": self.proj_c(rgb_cradio).float(),
                "moge": self.proj_m(rgb_moge).float()}


def tiny_model():
    ck_model.FrozenFoundations = FakeFoundations
    m = ck_model.CorridorKeyV3(
        d_16=64, d_64=128, n_enc_16=1, n_body_64=1, n_dec_16=6,
        num_heads_16=2, num_heads_64=2, stage1_hint_adaln_blocks=1,
        stage1_mid_16_blocks=1, d_stage2=128, n_blocks_stage2=8,
        n_final_blocks_stage2=2, num_heads_stage2=2,
        device="cpu", gradient_checkpoint=False, stage1_recurrent_64_sites=(),
    )
    return m.eval()


def fnv64(buf: bytes) -> str:
    # Same idea as the plug-in's hash; any stable 64-bit content hash works.
    import hashlib
    return hashlib.blake2b(buf, digest_size=8).hexdigest()


def client_key(port, frames, center, params, hints=None):
    """Python mirror of what the FxPlug effect does over the socket."""
    H, W = frames[0].shape[:2]
    blobs = {}
    hashes = []
    for f in frames:
        b = np.ascontiguousarray(f, np.float16).tobytes()
        h = fnv64(b)
        hashes.append(h)
        blobs[h] = b
    hint_json = {}
    for i, m in (hints or {}).items():
        b = np.ascontiguousarray(m, np.float16).tobytes()
        h = "m" + fnv64(b)
        blobs[h] = b
        hint_json[str(i)] = {"hash": h, "w": m.shape[1], "h": m.shape[0]}
    from ck_server import recv_msg, send_msg, _recv_exact
    with socket.create_connection(("127.0.0.1", port)) as s:
        send_msg(s, {"op": "key", "w": W, "h": H, "frames": hashes, "center": center,
                     "hints": hint_json, "params": params})
        need = recv_msg(s)
        assert "need" in need, need
        for h in need["need"]:
            s.sendall(blobs[h])
        reply = recv_msg(s)
        assert reply.get("ok"), reply
        raw = _recv_exact(s, reply["bytes"])
    return np.frombuffer(raw, np.float16).reshape(H, W, 4), need["need"]


def main():
    torch.manual_seed(0)
    dev.set_active("cpu")
    model = tiny_model()

    from corridorkey.frame_engine import FrameEngine, KeyParams
    engine = FrameEngine(model)

    rng = np.random.default_rng(0)
    H, W = 150, 260   # deliberately not a multiple of 128
    clip = [np.concatenate([rng.random((H, W, 3), np.float32) * 1.5,
                            np.ones((H, W, 1), np.float32)], -1).astype(np.float16)
            for _ in range(6)]

    # --- direct engine use -------------------------------------------------
    hs = [f"f{i}" for i in range(6)]
    for h, f in zip(hs, clip):
        engine.add_frame(h, f)
    t0 = time.time()
    out = engine.key(hs[0:3], 1, KeyParams())
    print(f"engine: window=3 -> {out.shape} {out.dtype} in {time.time() - t0:.2f}s")
    assert out.shape == (H, W, 4) and out.dtype == np.float16
    assert np.isfinite(out.astype(np.float32)).all()
    a = out[..., 3].astype(np.float32)
    assert (a >= 0).all() and (a <= 1).all()
    calls = model.foundations.calls
    engine.key(hs[1:4], 1, KeyParams())          # overlaps 2 cached frames
    assert model.foundations.calls == calls + 1, "foundation features not reused"
    again = engine.key(hs[0:3], 1, KeyParams())  # exact repeat -> result cache
    assert again is out
    for mode in ("matte", "foreground", "orientation"):
        o = engine.key(hs[0:1], 0, KeyParams(output=mode))
        assert o.shape == (H, W, 4)
    matte = engine.key(hs[0:1], 0, KeyParams(output="matte"))
    assert np.allclose(matte[..., 3], 1)
    engine.add_hint("m0", np.ones((H // 2, W // 2), np.float16))   # different size on purpose
    engine.key(hs[0:3], 1, KeyParams(), {0: "m0"})
    engine.key(hs[0:3], 1, KeyParams(gamut="rec2020", flip_vertical=True))
    print("engine: caching, modes, hints, gamut, flip OK")

    # --- over the socket ---------------------------------------------------
    import ck_server
    port = 47999
    th = threading.Thread(target=ck_server.serve,
                          args=(lambda: (engine, "cpu"), "127.0.0.1", port), daemon=True)
    th.start()
    for _ in range(50):
        try:
            socket.create_connection(("127.0.0.1", port)).close()
            break
        except OSError:
            time.sleep(0.1)
    with socket.create_connection(("127.0.0.1", port)) as s:
        ck_server.send_msg(s, {"op": "ping"})
        print("ping:", ck_server.recv_msg(s))
    new_clip = [f.copy() for f in clip]
    new_clip[2][0, 0, 0] = 0.123  # make it differ from the engine-cached frames
    o1, need1 = client_key(port, new_clip[1:4], 1, {"output": "composite"},
                           hints={1: np.full((H, W), 0.5, np.float16)})
    o2, need2 = client_key(port, new_clip[2:5], 0, {"output": "composite"})
    print(f"socket: first request uploaded {len(need1)} blobs, overlapping window uploaded {len(need2)}")
    assert len(need1) == 4 and len(need2) == 1
    assert o1.shape == (H, W, 4)

    # Concurrent clients (hosts render on several threads)
    errs = []

    def worker(i):
        try:
            client_key(port, new_clip[i:i + 2], 0, {"output": "matte"})
        except Exception as e:  # pragma: no cover
            errs.append(e)
    ts = [threading.Thread(target=worker, args=(i,)) for i in range(4)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert not errs, errs
    print("socket: protocol, dedupe and concurrency OK")
    print("ALL OK")


if __name__ == "__main__":
    main()
