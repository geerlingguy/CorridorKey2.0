"""Compute-device abstraction so CorridorKey runs on CUDA, Apple Silicon (MPS) or CPU.

The original runtime hard-coded CUDA. Everything device-specific now goes
through this module. Call `set_active()` once (``load_model`` does it) and the
rest of the runtime picks the device up from here.

Environment overrides:
  CORRIDORKEY_DEVICE      auto | cuda | mps | cpu   (default: auto)
  CORRIDORKEY_MPS_DTYPE   bfloat16 | float16        (default: bfloat16)
"""
from __future__ import annotations

import contextlib
import os

# Let ops that Metal doesn't implement yet fall back to CPU instead of raising.
# Must be set before torch initializes MPS, so set it on import.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import torch  # noqa: E402

_ACTIVE: str = "cuda"


def mps_available() -> bool:
    return bool(getattr(torch.backends, "mps", None) and torch.backends.mps.is_available())


def resolve(pref: str | None = None) -> str:
    """Turn 'auto' (or None) into the best available device string."""
    pref = (pref or os.environ.get("CORRIDORKEY_DEVICE") or "auto").lower()
    if pref == "auto":
        if torch.cuda.is_available():
            return "cuda"
        if mps_available():
            return "mps"
        return "cpu"
    if pref == "cuda" and not torch.cuda.is_available():
        raise RuntimeError("CUDA was requested but torch.cuda.is_available() is False")
    if pref == "mps" and not mps_available():
        raise RuntimeError("MPS was requested but this PyTorch build/Mac does not support it "
                           "(needs Apple Silicon, macOS 14+, PyTorch 2.5+)")
    if pref not in ("cuda", "mps", "cpu"):
        raise ValueError(f"unknown device: {pref}")
    return pref


def set_active(device: str) -> str:
    global _ACTIVE
    _ACTIVE = torch.device(device).type
    return _ACTIVE


def active() -> str:
    return _ACTIVE


def is_cuda() -> bool:
    return _ACTIVE == "cuda"


def nb() -> bool:
    """non_blocking flag for host->device copies. Only trusted on CUDA."""
    return _ACTIVE == "cuda"


def compute_dtype() -> torch.dtype:
    if _ACTIVE == "mps":
        name = os.environ.get("CORRIDORKEY_MPS_DTYPE", "bfloat16").lower()
        return torch.float16 if name in ("float16", "fp16", "half") else torch.bfloat16
    return torch.bfloat16


def autocast():
    """bf16 autocast on the active device (the model was trained/validated in bf16)."""
    try:
        return torch.autocast(device_type=_ACTIVE, dtype=compute_dtype())
    except (RuntimeError, ValueError) as exc:  # very old torch without MPS autocast
        print(f"  [WARNING] autocast unavailable on {_ACTIVE} ({exc}); running in fp32")
        return contextlib.nullcontext()


def empty_cache() -> None:
    if _ACTIVE == "cuda":
        torch.cuda.empty_cache()
    elif _ACTIVE == "mps":
        torch.mps.empty_cache()


def synchronize() -> None:
    if _ACTIVE == "cuda":
        torch.cuda.synchronize()
    elif _ACTIVE == "mps":
        torch.mps.synchronize()


def memory_budget_gb() -> float:
    """Memory the model may use, in GiB, including what this process already holds."""
    if _ACTIVE == "cuda":
        free_bytes, _ = torch.cuda.mem_get_info()
        return (free_bytes + torch.cuda.memory_reserved()) / 2**30
    if _ACTIVE == "mps":
        # Unified memory: Metal's recommended working-set size is the practical
        # ceiling before macOS starts swapping GPU allocations.
        try:
            return torch.mps.recommended_max_memory() / 2**30
        except AttributeError:
            pass
    try:
        import psutil  # optional
        return psutil.virtual_memory().available / 2**30
    except Exception:
        return 16.0
