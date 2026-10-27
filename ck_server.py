#!/usr/bin/env python3
"""CorridorKey local render server for host plug-ins (Final Cut Pro / Motion FxPlug).

The FxPlug effect runs inside a sandboxed XPC service and can't host PyTorch,
so it ships frames to this process over a localhost TCP socket. The model is
loaded once and stays resident; frames, foundation features and results are
cached by content hash so scrubbing and re-renders are cheap.

    python ck_server.py                 # 127.0.0.1:47823, auto device (MPS on a Mac)
    python ck_server.py --port 47900 --device mps

Wire protocol (all integers little-endian):

    message  := u32 json_length, json_bytes
    request  := message {"op": "ping"} | message {"op": "key", ...} followed by blobs

  key request JSON:
    {"op": "key", "w": W, "h": H,
     "frames": ["<hash>", ...],          # temporal window, oldest first
     "center": i,                         # index of the frame to output
     "hints":  {"<i>": {"hash": "...", "w": hw, "h": hh}},   # optional mattes
     "params": {"output": "composite", "despill": 0.5, "hint_quality": 0.95,
                "gamut": "rec709", "flip_vertical": false}}
  server replies  message {"need": ["<hash>", ...]}
  client sends one blob per needed hash, in that order:
    frame blob: W*H*4 float16 RGBA (premultiplied, linear, rows top to bottom)
    hint blob:  hw*hh float16 matte
  server replies  message {"ok": true, "w": W, "h": H, "bytes": N} + N bytes RGBA float16
             or   message {"ok": false, "error": "..."}
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import socketserver
import struct
import sys
import threading
import time
import traceback
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import numpy as np  # noqa: E402

PROTOCOL_VERSION = 1
DEFAULT_PORT = 47823
MAX_JSON = 1 << 20
MAX_SIDE = 16384


def _recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray(n)
    view = memoryview(buf)
    got = 0
    while got < n:
        k = sock.recv_into(view[got:], n - got)
        if k == 0:
            raise ConnectionError("client closed connection")
        got += k
    return buf  # bytearray: numpy views over it stay writable


def recv_msg(sock: socket.socket) -> dict:
    (n,) = struct.unpack("<I", _recv_exact(sock, 4))
    if n > MAX_JSON:
        raise ValueError(f"json message too large ({n} bytes)")
    return json.loads(_recv_exact(sock, n).decode("utf-8"))


def send_msg(sock: socket.socket, obj: dict, payload: bytes | memoryview | None = None) -> None:
    data = json.dumps(obj, separators=(",", ":")).encode("utf-8")
    sock.sendall(struct.pack("<I", len(data)) + data)
    if payload is not None:
        sock.sendall(payload)


class EngineHolder:
    """Loads the model in the background so the socket comes up immediately."""

    def __init__(self, factory):
        self._factory = factory
        self.engine = None
        self.error: str | None = None
        self.device = None
        self._ready = threading.Event()
        threading.Thread(target=self._load, daemon=True, name="model-loader").start()

    def _load(self):
        try:
            t0 = time.time()
            self.engine, self.device = self._factory()
            print(f"[ck_server] model ready on {self.device} in {time.time() - t0:.1f}s", flush=True)
        except Exception as exc:  # surface the reason to the plug-in
            self.error = f"{type(exc).__name__}: {exc}"
            traceback.print_exc()
        finally:
            self._ready.set()

    def wait(self, timeout: float | None = None):
        self._ready.wait(timeout)
        if self.engine is None:
            raise RuntimeError(self.error or "model is still loading")
        return self.engine


def _params_from_json(p: dict):
    from corridorkey.frame_engine import KeyParams, OUTPUT_MODES
    out = KeyParams()
    output = str(p.get("output", out.output))
    if output not in OUTPUT_MODES:
        raise ValueError(f"unknown output mode {output!r}")
    out.output = output
    out.despill = float(np.clip(p.get("despill", out.despill), 0.0, 1.0))
    out.hint_quality = float(np.clip(p.get("hint_quality", out.hint_quality), 0.0, 1.0))
    gamut = str(p.get("gamut", out.gamut)).lower()
    out.gamut = "rec2020" if gamut in ("rec2020", "2020", "bt2020") else "rec709"
    out.flip_vertical = bool(p.get("flip_vertical", False))
    out.matte_clip_black = float(np.clip(p.get("matte_clip_black", 0.0), 0.0, 1.0))
    out.matte_clip_white = float(np.clip(p.get("matte_clip_white", 1.0), 0.0, 1.0))
    return out


def make_handler(holder: EngineHolder):
    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            sock: socket.socket = self.request
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            try:
                while True:
                    try:
                        req = recv_msg(sock)
                    except ConnectionError:
                        return
                    op = req.get("op")
                    if op == "ping":
                        send_msg(sock, {
                            "ok": True, "version": PROTOCOL_VERSION,
                            "ready": holder.engine is not None,
                            "device": holder.device, "error": holder.error,
                        })
                    elif op == "key":
                        self._key(sock, req)
                    else:
                        send_msg(sock, {"ok": False, "error": f"unknown op {op!r}"})
            except Exception as exc:
                traceback.print_exc()
                try:
                    send_msg(sock, {"ok": False, "error": f"{type(exc).__name__}: {exc}"})
                except OSError:
                    pass

        def _key(self, sock, req):
            W, H = int(req["w"]), int(req["h"])
            if not (0 < W <= MAX_SIDE and 0 < H <= MAX_SIDE):
                raise ValueError(f"bad frame size {W}x{H}")
            frames = [str(h) for h in req["frames"]]
            hints_in = req.get("hints") or {}
            hints = {int(k): v for k, v in hints_in.items()}
            params = _params_from_json(req.get("params") or {})
            t0 = time.time()
            engine = holder.wait(timeout=600)

            need = engine.missing(frames, [v["hash"] for v in hints.values()])
            send_msg(sock, {"need": need})
            hint_by_hash = {v["hash"]: v for v in hints.values()}
            frame_set = set(frames)
            for h in need:
                if h in frame_set:
                    raw = _recv_exact(sock, W * H * 4 * 2)
                    engine.add_frame(h, np.frombuffer(raw, np.float16).reshape(H, W, 4))
                else:
                    meta = hint_by_hash[h]
                    hw, hh = int(meta["w"]), int(meta["h"])
                    if not (0 < hw <= MAX_SIDE and 0 < hh <= MAX_SIDE):
                        raise ValueError(f"bad hint size {hw}x{hh}")
                    raw = _recv_exact(sock, hw * hh * 2)
                    engine.add_hint(h, np.frombuffer(raw, np.float16).reshape(hh, hw))
            t1 = time.time()
            out = engine.key(frames, int(req.get("center", 0)), params,
                             {i: v["hash"] for i, v in hints.items()})
            out = np.ascontiguousarray(out, dtype=np.float16)
            if out.shape != (H, W, 4):
                raise RuntimeError(f"engine returned {out.shape}, expected {(H, W, 4)}")
            send_msg(sock, {"ok": True, "w": W, "h": H, "bytes": out.nbytes}, memoryview(out).cast("B"))
            print(f"[ck_server] {W}x{H} window={len(frames)} center={req.get('center', 0)} "
                  f"hints={len(hints)} uploaded={len(need)} "
                  f"upload={t1 - t0:.2f}s key={time.time() - t1:.2f}s", flush=True)

    return Handler


class ThreadingServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True


def default_factory(args):
    def factory():
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from corridorkey.frame_engine import FrameEngine
        from corridorkey.runtime import RuntimePaths, load_model
        paths = RuntimePaths.from_package(Path(__file__).resolve().parent, args.weights)
        model = load_model(paths, device=args.device)
        from corridorkey import device as dev
        engine = FrameEngine(model, frame_cache_gb=args.frame_cache_gb,
                             feature_cache_gb=args.feature_cache_gb,
                             result_cache_gb=args.result_cache_gb)
        return engine, dev.active()
    return factory


def serve(factory, host: str, port: int):
    holder = EngineHolder(factory)
    with ThreadingServer((host, port), make_handler(holder)) as srv:
        print(f"[ck_server] listening on {host}:{port}", flush=True)
        try:
            srv.serve_forever()
        except KeyboardInterrupt:
            pass


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--host", default="127.0.0.1",
                    help="Bind address. Keep this on localhost; there is no authentication.")
    ap.add_argument("--port", type=int, default=int(os.environ.get("CORRIDORKEY_PORT", DEFAULT_PORT)))
    ap.add_argument("--device", default=os.environ.get("CORRIDORKEY_DEVICE", "auto"),
                    choices=("auto", "cuda", "mps", "cpu"))
    ap.add_argument("--weights", default=None)
    ap.add_argument("--frame_cache_gb", type=float, default=4.0)
    ap.add_argument("--feature_cache_gb", type=float, default=2.0)
    ap.add_argument("--result_cache_gb", type=float, default=2.0)
    args = ap.parse_args()
    serve(default_factory(args), args.host, args.port)


if __name__ == "__main__":
    main()
