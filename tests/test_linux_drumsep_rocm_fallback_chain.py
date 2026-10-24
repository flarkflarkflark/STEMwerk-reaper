"""Regression pin for the Linux ROCm -> CUDA -> CPU fallback chain in
`_select_drumsep_runtime` (Direct Drum Kit Split, stage-2 runtime resolution).

This does NOT change behavior. It only pins the existing, unmodified control
flow of the default (non-Windows, non-macOS-arm64, non-explicit-cpu,
non-explicit-cuda) branch of `_select_drumsep_runtime` in
scripts/reaper/audio_separator_process.py, including a known legacy quirk:
the CUDA fallback attempt in that branch probes `cpu_candidates` (not
`cuda_candidates`), and an explicit "rocm" request can still silently end up
on CPU if ROCm verification fails.

`_probe_drumsep_runtime_candidates` is monkeypatched directly so no real
python interpreters, subprocesses, or torch/onnxruntime imports are needed.
"""

import importlib.util
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
PROCESS_SCRIPT = ROOT / "scripts" / "reaper" / "audio_separator_process.py"


def _load_module():
    spec = importlib.util.spec_from_file_location(
        "audio_separator_process_linux_drumsep_rocm_fallback_test", PROCESS_SCRIPT
    )
    module = importlib.util.module_from_spec(spec)
    assert spec is not None and spec.loader is not None
    spec.loader.exec_module(module)
    return module


class _OsProxy:
    """Wraps the real `os` module but reports posix, so `_is_windows_runtime()`
    (which checks `os.name == "nt"`) reads this as a non-Windows host
    regardless of what the test actually runs on."""

    def __init__(self, real_os, *, name):
        self._real_os = real_os
        self.name = name
        self.pathsep = ":" if name == "posix" else real_os.pathsep

    def __getattr__(self, attr):
        return getattr(self._real_os, attr)


@pytest.fixture
def linux_module(monkeypatch):
    module = _load_module()
    monkeypatch.setattr(module, "os", _OsProxy(module.os, name="posix"))
    monkeypatch.setattr(module.sys, "platform", "linux")
    monkeypatch.delenv("STEMWERK_BENCH_DRUMSEP_HELPER_DEVICE", raising=False)
    return module


def _fake_probe(rocm_responses=None, cuda_response=None, cpu_response=None):
    """Builds a fake replacement for `_probe_drumsep_runtime_candidates` plus
    a dict of per-kind call logs, so tests can assert exactly which probes
    were (or were not) invoked, and how many times.

    - rocm_responses: list of 4-tuples consumed in call order for successive
      require_gpu=True invocations (covers the retry-once-after-transient
      -failure path, which calls the probe twice).
    - cuda_response / cpu_response: a single 4-tuple each, returned for
      require_cuda=True / plain (require_gpu=False) invocations. Leaving one
      unset means that probe must never be called - the fake raises if it is,
      which is how "CUDA/CPU probe never invoked" gets asserted.
    """
    calls = {"rocm": [], "cuda": [], "cpu": []}
    rocm_queue = list(rocm_responses or [])

    def fake(candidates, require_gpu=False, require_mps=False, require_cuda=False, require_directml=False):
        assert require_mps is False
        assert require_directml is False
        if require_gpu:
            calls["rocm"].append(list(candidates))
            if not rocm_queue:
                raise AssertionError("rocm probe invoked more times than responses were queued")
            return rocm_queue.pop(0)
        if require_cuda:
            calls["cuda"].append(list(candidates))
            if cuda_response is None:
                raise AssertionError("cuda probe was not expected to be invoked in this scenario")
            return cuda_response
        calls["cpu"].append(list(candidates))
        if cpu_response is None:
            raise AssertionError("cpu probe was not expected to be invoked in this scenario")
        return cpu_response

    return fake, calls


@pytest.mark.parametrize(
    "requested_device,expected_policy",
    [("auto", "auto_prefer_rocm"), ("gpu", "gpu_prefer_rocm")],
)
def test_rocm_success_returns_rocm_without_probing_cuda_or_cpu(
    linux_module, tmp_path, requested_device, expected_policy
):
    module = linux_module
    rocm_python = Path("/fake/.venv-drumsep-rocm/bin/python")
    fake_probe, calls = _fake_probe(
        rocm_responses=[(rocm_python, "ok", {"torch_hip": "6.4"}, [])],
    )
    module._probe_drumsep_runtime_candidates = fake_probe

    selected, kind, info = module._select_drumsep_runtime(requested_device, tmp_path)

    assert (selected, kind) == (rocm_python, "rocm")
    assert info["selection_policy"] == expected_policy
    assert info["fallback_reason"] == ""
    assert len(calls["rocm"]) == 1
    assert calls["cuda"] == []
    assert calls["cpu"] == []


def test_rocm_failure_falls_back_to_cuda(linux_module, tmp_path):
    module = linux_module
    cuda_python = Path("/fake/.venv-drumsep/bin/python")
    fake_probe, calls = _fake_probe(
        rocm_responses=[(None, "rocm_no_hip", {}, [])],
        cuda_response=(cuda_python, "ok", {"torch_cuda_available": True}, []),
    )
    module._probe_drumsep_runtime_candidates = fake_probe

    selected, kind, info = module._select_drumsep_runtime("auto", tmp_path)

    assert (selected, kind) == (cuda_python, "cuda")
    assert info["selection_policy"] == "auto_prefer_cuda"
    assert info["fallback_reason"] == ""
    assert len(calls["rocm"]) == 1
    assert len(calls["cuda"]) == 1
    assert calls["cpu"] == []


def test_rocm_and_cuda_failure_falls_back_to_cpu(linux_module, tmp_path):
    module = linux_module
    cpu_python = Path("/fake/.venv-drumsep/bin/python")
    fake_probe, calls = _fake_probe(
        rocm_responses=[(None, "rocm_no_hip", {}, [])],
        cuda_response=(None, "cuda_unavailable", {}, []),
        cpu_response=(cpu_python, "ok", {}, []),
    )
    module._probe_drumsep_runtime_candidates = fake_probe

    selected, kind, info = module._select_drumsep_runtime("auto", tmp_path)

    assert (selected, kind) == (cpu_python, "cpu")
    assert info["selection_policy"] == "fallback_cpu"
    assert "rocm_skipped:rocm_no_hip" in info["fallback_reason"]
    assert "cuda_skipped:cuda_unavailable" in info["fallback_reason"]
    assert info["fallback_reason"] == "rocm_skipped:rocm_no_hip;cuda_skipped:cuda_unavailable"
    assert len(calls["rocm"]) == 1
    assert len(calls["cuda"]) == 1
    assert len(calls["cpu"]) == 1


def test_explicit_rocm_request_failure_skips_cuda_and_falls_back_to_cpu(linux_module, tmp_path):
    """Pins the known legacy behavior: even a literal `requested_device="rocm"`
    request silently ends up on CPU if ROCm verification fails - CUDA is
    never attempted for an explicit rocm request (only the implicit
    auto/gpu-normalized path probes CUDA as a fallback), but the CPU probe
    still runs unconditionally. This is deliberately not "fixed" here."""
    module = linux_module
    cpu_python = Path("/fake/.venv-drumsep/bin/python")
    fake_probe, calls = _fake_probe(
        rocm_responses=[(None, "rocm_no_hip", {}, [])],
        cpu_response=(cpu_python, "ok", {}, []),
        # cuda_response intentionally left None: if the CUDA probe is invoked
        # at all for an explicit "rocm" request, the fake raises and the
        # test fails.
    )
    module._probe_drumsep_runtime_candidates = fake_probe

    selected, kind, info = module._select_drumsep_runtime("rocm", tmp_path)

    assert (selected, kind) == (cpu_python, "cpu")
    assert info["selection_policy"] == "fallback_cpu"
    assert info["fallback_reason"] == "rocm_skipped:rocm_no_hip"
    assert "cuda_skipped" not in info["fallback_reason"]
    assert len(calls["rocm"]) == 1
    assert calls["cuda"] == []
    assert len(calls["cpu"]) == 1


@pytest.mark.parametrize("transient_detail", ["rocm_cuda_unavailable", "rocm_no_device_names"])
def test_rocm_transient_failure_retries_once_then_succeeds(linux_module, tmp_path, monkeypatch, transient_detail):
    module = linux_module
    slept = []
    monkeypatch.setattr(module.time, "sleep", lambda seconds: slept.append(seconds))

    rocm_python = Path("/fake/.venv-drumsep-rocm/bin/python")
    fake_probe, calls = _fake_probe(
        rocm_responses=[
            (None, transient_detail, {}, []),
            (rocm_python, "ok", {"torch_hip": "6.4"}, []),
        ],
    )
    module._probe_drumsep_runtime_candidates = fake_probe

    selected, kind, info = module._select_drumsep_runtime("auto", tmp_path)

    assert (selected, kind) == (rocm_python, "rocm")
    assert info["selection_policy"] == "auto_prefer_rocm"
    assert info["fallback_reason"] == ""
    assert len(calls["rocm"]) == 2
    assert calls["cuda"] == []
    assert calls["cpu"] == []
    assert slept == [1.0]
