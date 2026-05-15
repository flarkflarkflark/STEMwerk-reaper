"""Apple Silicon MPS smoke probe.

Two layers of testing:

1. Gate-logic tests that run anywhere. They exercise the
   STEMWERK_EXPERIMENTAL_MPS opt-in around
   _enforce_mps_demucs_cpu_policy() without needing torch or MPS hardware.

2. Real-hardware smoke probe that only runs on Apple Silicon when torch
   reports MPS is both built and available. It does a tiny torch
   tensor-on-MPS allocation + matmul and reports timing; failure is
   captured as a test diagnostic, not a hard error, so we can record
   results in the model matrix without breaking CI on non-Apple machines.

Run with: pytest tests/test_apple_silicon_mps_smoke.py -v
"""
from __future__ import annotations

import importlib.util
import os
import platform
import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"

if str(CORE_SRC) not in sys.path:
    sys.path.insert(0, str(CORE_SRC))


def _load_audio_separator_process_module():
    path = ROOT / "scripts" / "reaper" / "audio_separator_process.py"
    spec = importlib.util.spec_from_file_location("audio_separator_process_smoke", path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def _is_apple_silicon() -> bool:
    return platform.system() == "Darwin" and platform.machine().lower() in {"arm64", "aarch64"}


def _torch_mps_ready() -> bool:
    try:
        import torch
    except Exception:
        return False
    backend = getattr(torch.backends, "mps", None)
    if backend is None:
        return False
    try:
        return bool(backend.is_built()) and bool(backend.is_available())
    except Exception:
        return False


# --- Gate-logic tests (platform-independent) ----------------------------------

def test_experimental_flag_default_off(monkeypatch):
    module = _load_audio_separator_process_module()
    monkeypatch.delenv(module.EXPERIMENTAL_MPS_ENV, raising=False)
    assert module._experimental_mps_enabled() is False


@pytest.mark.parametrize("value", ["1", "true", "True", "YES", "on"])
def test_experimental_flag_truthy_values(monkeypatch, value):
    module = _load_audio_separator_process_module()
    monkeypatch.setenv(module.EXPERIMENTAL_MPS_ENV, value)
    assert module._experimental_mps_enabled() is True


@pytest.mark.parametrize("value", ["0", "false", "no", "off", ""])
def test_experimental_flag_falsy_values(monkeypatch, value):
    module = _load_audio_separator_process_module()
    monkeypatch.setenv(module.EXPERIMENTAL_MPS_ENV, value)
    assert module._experimental_mps_enabled() is False


def test_demucs_mps_policy_forces_cpu_without_flag(monkeypatch):
    module = _load_audio_separator_process_module()
    monkeypatch.delenv(module.EXPERIMENTAL_MPS_ENV, raising=False)
    monkeypatch.setattr(module.sys, "platform", "darwin")
    monkeypatch.setattr(module.platform, "machine", lambda: "arm64")
    result = module._enforce_mps_demucs_cpu_policy("mps", "mps", "htdemucs")
    assert result == "cpu"


def test_demucs_mps_policy_bypassed_with_flag(monkeypatch):
    module = _load_audio_separator_process_module()
    monkeypatch.setenv(module.EXPERIMENTAL_MPS_ENV, "1")
    monkeypatch.setattr(module.sys, "platform", "darwin")
    monkeypatch.setattr(module.platform, "machine", lambda: "arm64")
    result = module._enforce_mps_demucs_cpu_policy("mps", "mps", "htdemucs")
    assert result == "mps"


def test_env_json_includes_experimental_flag(monkeypatch):
    module = _load_audio_separator_process_module()
    monkeypatch.setenv(module.EXPERIMENTAL_MPS_ENV, "1")
    env = module._build_env_json()
    assert env["experimental_mps_enabled"] is True

    monkeypatch.delenv(module.EXPERIMENTAL_MPS_ENV, raising=False)
    env = module._build_env_json()
    assert env["experimental_mps_enabled"] is False


# --- Apple Silicon hardware probes (skipped elsewhere) ------------------------

apple_only = pytest.mark.skipif(
    not _is_apple_silicon(),
    reason="Apple Silicon hardware required for MPS smoke probe",
)
mps_only = pytest.mark.skipif(
    not _torch_mps_ready(),
    reason="torch.backends.mps must be built and available",
)


@apple_only
@mps_only
def test_torch_mps_tensor_allocation_and_matmul():
    """Smoke probe: confirm a tiny matmul runs on MPS without exception."""
    import torch

    device = torch.device("mps")
    start = time.time()
    a = torch.randn(64, 64, device=device)
    b = torch.randn(64, 64, device=device)
    c = (a @ b).sum().item()
    elapsed = time.time() - start
    assert isinstance(c, float)
    print(f"[smoke] mps matmul ok in {elapsed*1000:.1f}ms result={c:.3f}")


@apple_only
@mps_only
def test_select_device_mps_returns_mps_with_flag(monkeypatch):
    """When the experimental flag is on, requesting mps must reach torch."""
    module = _load_audio_separator_process_module()
    monkeypatch.setenv(module.EXPERIMENTAL_MPS_ENV, "1")
    out = module._enforce_mps_demucs_cpu_policy("mps", "mps", "htdemucs")
    assert out == "mps"


@apple_only
@mps_only
def test_demucs_on_mps_load_only(tmp_path, monkeypatch):
    """Load-only probe: instantiate StemSeparator on MPS without running
    separate(). This is the cheapest path that touches the audio-separator
    + Demucs model loader; if it raises here we record the failure but the
    test is allowed to xfail because the known
    'output channels > 65536' issue is precisely what this branch
    investigates."""
    monkeypatch.setenv("STEMWERK_EXPERIMENTAL_MPS", "1")
    monkeypatch.setenv("PYTORCH_ENABLE_MPS_FALLBACK", "1")
    try:
        from stemwerk_core import StemSeparator
    except Exception as exc:  # pragma: no cover - import guard
        pytest.skip(f"stemwerk_core unavailable: {exc}")

    try:
        sep = StemSeparator(model="htdemucs", device="mps")
        assert sep is not None
        print("[smoke] StemSeparator(model=htdemucs, device=mps) constructed ok")
    except Exception as exc:
        pytest.xfail(f"StemSeparator construction failed on MPS: {exc!r}")
