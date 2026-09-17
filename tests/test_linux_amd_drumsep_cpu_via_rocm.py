"""AMD Linux: explicit CPU for Direct Kit / Kit Split must be able to use an
already-installed ROCm DrumSep runtime (.venv-drumsep-rocm) as a genuine CPU
execution environment when no dedicated CPU DrumSep runtime (.venv-drumsep)
exists.

Proven on real AMD Linux / RX 9070 hardware: the production DrumSep MDX23C
helper, invoked with --device cpu inside .venv-drumsep-rocm/bin/python,
produces requested_device=cpu / effective_device=cpu / model_device=cpu /
separator_onnx_provider=["CPUExecutionProvider"] and all six valid stems --
no GPU is touched. The bug was purely in _select_drumsep_runtime's
explicit_cpu branch, which only ever probed the dedicated .venv-drumsep
candidates and never considered .venv-drumsep-rocm as CPU-capable.

These tests exercise the real _select_drumsep_runtime function (not a mock
of it), matching the existing convention in test_drumsep_mps_direct_demix.py
(test_drumsep_runtime_selector_prefers_mps_for_auto_on_apple_silicon et al.):
only _verify_drumsep_runtime -- the actual subprocess probe -- is faked, so
the resolver's real candidate-building/fallback/failure-classification logic
runs unmodified.
"""

import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
AUDIO_PROCESS = ROOT / "scripts" / "reaper" / "audio_separator_process.py"


def _load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def _load_audio_process():
    return _load_module(AUDIO_PROCESS, "audio_separator_process_amd_cpu_via_rocm_test")


class _OsProxy:
    def __init__(self, real_os, *, name: str):
        self._real_os = real_os
        self.name = name
        self.pathsep = ":" if name == "posix" else real_os.pathsep

    def __getattr__(self, attr):
        return getattr(self._real_os, attr)


def _set_linux(module, monkeypatch):
    monkeypatch.setattr(module, "os", _OsProxy(module.os, name="posix"))
    monkeypatch.setattr(module.sys, "platform", "linux")
    monkeypatch.setattr(module.platform, "machine", lambda: "x86_64")


def _make_fake_python(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    path.chmod(0o755)
    return path


def _rocm_versions_payload():
    return {
        "versions": {"audio-separator": "0.34.1", "torch": "2.10.0+rocm7.0"},
        "torch_hip": "7.0.51831",
        "torch_cuda_available": True,
        "device_names": ["AMD Radeon RX 9070"],
    }


# --- A: dedicated CPU runtime present and healthy -> unchanged behavior ----


def test_explicit_cpu_prefers_healthy_dedicated_cpu_runtime(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_linux(module, monkeypatch)
    cpu_python = _make_fake_python(tmp_path / ".venv-drumsep" / "bin" / "python")
    rocm_python = _make_fake_python(tmp_path / ".venv-drumsep-rocm" / "bin" / "python")

    probed = []

    def fake_verify(path, require_gpu=False, **kwargs):
        probed.append(path)
        if path == cpu_python:
            return True, "ok", {"versions": {"audio-separator": "0.34.1", "torch": "2.4.1+cpu"}}
        raise AssertionError(f"should not probe {path} when dedicated CPU runtime is healthy")

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, kind, info = module._select_drumsep_runtime("cpu", tmp_path)

    assert selected == cpu_python
    assert kind == "cpu"
    assert info["selection_policy"] == "explicit_cpu"
    assert info.get("runtime_source_family", "") != "rocm"
    assert rocm_python not in probed


# --- B: dedicated CPU runtime missing, ROCm runtime healthy -> use ROCm ----


def test_explicit_cpu_falls_back_to_rocm_runtime_when_cpu_runtime_missing(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_linux(module, monkeypatch)
    # .venv-drumsep is never created -- matches the real AMD installation.
    rocm_python = _make_fake_python(tmp_path / ".venv-drumsep-rocm" / "bin" / "python")

    def fake_verify(path, require_gpu=False, **kwargs):
        assert require_gpu is False, "CPU-via-ROCm probe must not require GPU"
        if path == rocm_python:
            return True, "ok", _rocm_versions_payload()
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, kind, info = module._select_drumsep_runtime("cpu", tmp_path)

    assert selected == rocm_python
    assert kind == "cpu", "execution backend must be reported as cpu, not rocm"
    assert info["selection_policy"] == "explicit_cpu_via_rocm_runtime"
    assert info["runtime_source_family"] == "rocm", "must not erase that the interpreter came from the ROCm env"
    assert info["fallback_reason"] == "cpu_skipped:missing"
    assert info["detail"] == "ok"


# --- C: dedicated CPU runtime broken (not just missing), ROCm healthy -----


def test_explicit_cpu_falls_back_to_rocm_runtime_when_cpu_runtime_broken(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_linux(module, monkeypatch)
    cpu_python = _make_fake_python(tmp_path / ".venv-drumsep" / "bin" / "python")
    rocm_python = _make_fake_python(tmp_path / ".venv-drumsep-rocm" / "bin" / "python")

    def fake_verify(path, require_gpu=False, **kwargs):
        if path == cpu_python:
            return False, "ModuleNotFoundError: torch", {}
        if path == rocm_python:
            return True, "ok", _rocm_versions_payload()
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, kind, info = module._select_drumsep_runtime("cpu", tmp_path)

    # Existing convention elsewhere in this function (cuda->cpu, mps->cpu)
    # falls through to the next tier regardless of whether the preferred
    # tier was "missing" or actually broken -- mirrored here rather than
    # inventing a new, narrower policy.
    assert selected == rocm_python
    assert kind == "cpu"
    assert info["selection_policy"] == "explicit_cpu_via_rocm_runtime"
    assert info["runtime_source_family"] == "rocm"
    assert info["fallback_reason"] == "cpu_skipped:ModuleNotFoundError: torch"


# --- D: neither CPU nor ROCm runtime exists -> original missing failure ---


def test_explicit_cpu_missing_failure_preserved_when_no_runtime_exists(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_linux(module, monkeypatch)
    # Neither .venv-drumsep nor .venv-drumsep-rocm is created.

    def fake_verify(path, require_gpu=False, **kwargs):
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, reason, info = module._select_drumsep_runtime("cpu", tmp_path)

    assert selected is None
    assert reason == "missing"
    assert info["selection_policy"] == "explicit_cpu"
    assert info["rocm_cpu_detail"] == "missing"


# --- E: no CPU runtime, ROCm runtime present but broken -> deterministic --


def test_explicit_cpu_broken_when_only_rocm_present_and_broken(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_linux(module, monkeypatch)
    rocm_python = _make_fake_python(tmp_path / ".venv-drumsep-rocm" / "bin" / "python")

    def fake_verify(path, require_gpu=False, **kwargs):
        if path == rocm_python:
            return False, "ImportError: onnxruntime", {}
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, reason, info = module._select_drumsep_runtime("cpu", tmp_path)

    assert selected is None
    # Aggregation mirrors the existing cuda/directml->cpu fallback chain:
    # "missing" only when every attempted tier was "missing".
    assert reason == "broken"
    assert info["cpu_detail"] == "missing"
    assert info["rocm_cpu_detail"] == "ImportError: onnxruntime"


# --- F: Auto on AMD is unaffected -----------------------------------------


def test_auto_on_amd_still_prefers_rocm_gpu_unchanged(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_linux(module, monkeypatch)
    rocm_python = _make_fake_python(tmp_path / ".venv-drumsep-rocm" / "bin" / "python")

    def fake_verify(path, require_gpu=False, **kwargs):
        if path == rocm_python:
            return True, "ok", _rocm_versions_payload()
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, kind, info = module._select_drumsep_runtime("auto", tmp_path)

    assert selected == rocm_python
    assert kind == "rocm"
    assert info["selection_policy"] == "auto_prefer_rocm"


# --- G: explicit AMD GPU device name on AMD is unaffected ------------------


def test_explicit_amd_device_name_still_prefers_rocm_gpu_unchanged(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_linux(module, monkeypatch)
    rocm_python = _make_fake_python(tmp_path / ".venv-drumsep-rocm" / "bin" / "python")

    def fake_verify(path, require_gpu=False, **kwargs):
        if path == rocm_python:
            return True, "ok", _rocm_versions_payload()
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, kind, info = module._select_drumsep_runtime("AMD Radeon RX 9070", tmp_path)

    assert selected == rocm_python
    assert kind == "rocm"
    assert info["selection_policy"] == "gpu_prefer_rocm"


# --- H: CPU-via-ROCm subprocess environment gets real CPU isolation -------


def test_cpu_via_rocm_subprocess_env_hides_gpu_devices(tmp_path, monkeypatch):
    module = _load_audio_process()
    rocm_python = tmp_path / ".venv-drumsep-rocm" / "bin" / "python"
    rocm_venv = tmp_path / ".venv-drumsep-rocm"
    base_env = {
        "PATH": "/usr/bin",
        "HIP_VISIBLE_DEVICES": "0",
        "ROCR_VISIBLE_DEVICES": "0",
        "HSA_OVERRIDE_GFX_VERSION": "11.0.0",
        "CUDA_VISIBLE_DEVICES": "0",
    }

    env, diagnostics = module.build_drumsep_subprocess_env(base_env, rocm_python, rocm_venv, "cpu")

    assert env["CUDA_VISIBLE_DEVICES"] == ""
    assert env["NVIDIA_VISIBLE_DEVICES"] == ""
    assert "HIP_VISIBLE_DEVICES" not in env
    assert "ROCR_VISIBLE_DEVICES" not in env
    assert "HSA_OVERRIDE_GFX_VERSION" not in env
    assert diagnostics["drumsep_subprocess_env_profile"] == "cpu_isolated"
    assert diagnostics["drumsep_python"] == str(rocm_python)


# --- I: provenance is distinguishable from effective execution ------------


def test_provenance_distinguishes_rocm_source_from_cpu_execution(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_linux(module, monkeypatch)
    rocm_python = _make_fake_python(tmp_path / ".venv-drumsep-rocm" / "bin" / "python")

    def fake_verify(path, require_gpu=False, **kwargs):
        if path == rocm_python:
            return True, "ok", _rocm_versions_payload()
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, kind, info = module._select_drumsep_runtime("cpu", tmp_path)

    # Effective execution backend:
    assert kind == "cpu"
    # Physical runtime source family is preserved, not erased:
    assert info["runtime_source_family"] == "rocm"
    assert info["versions"]["torch"] == "2.10.0+rocm7.0"
    assert info["torch_hip"] == "7.0.51831"
    assert str(selected) == str(rocm_python)


# --- J: Direct Kit and Kit Split both consume the shared resolver ---------


def test_direct_kit_and_kit_split_both_call_shared_resolver():
    text = AUDIO_PROCESS.read_text(encoding="utf-8")
    extract_idx = text.index("_is_extract_dks_source(args.workflow_mode, args.workflow_source)")
    direct_idx = text.index("_is_direct_dks_source(args.workflow_mode, args.workflow_source)")
    extract_block = text[extract_idx : extract_idx + 3000]
    direct_block = text[direct_idx : direct_idx + 3000]
    assert "_select_drumsep_runtime(device_preference)" in extract_block, "Kit Split must use the shared resolver"
    assert "_select_drumsep_runtime(device_preference)" in direct_block, "Direct Kit must use the shared resolver"


# ===========================================================================
# Explicit AMD GPU selection: "cuda:0" is a torch device NAMESPACE, not proof
# of NVIDIA hardware. ROCm/HIP builds of PyTorch also report as torch.cuda,
# so the REAPER UI selecting "RX 9070" ends up sending the same "cuda:0" a
# real NVIDIA GPU would send. _select_drumsep_runtime's explicit_cuda-on-
# Linux branch previously assumed "cuda:0" always means NVIDIA and only ever
# probed cpu_candidates (.venv-drumsep) with require_cuda=True -- which is
# always missing on this AMD install, giving drumsep_runtime_missing even
# though .venv-drumsep-rocm is healthy and Auto already selects it correctly.
#
# The fix reuses the exact same live capability check Auto's gpu_prefer_rocm
# branch already trusts (_verify_drumsep_runtime(..., require_gpu=True):
# torch_hip non-empty, torch_cuda_available, real device names) against
# rocm_candidates, before ever assuming the request is NVIDIA. On a genuine
# NVIDIA machine that candidate is simply missing, so behavior is unchanged.
# ===========================================================================


def _make_fake_python_cuda(path: Path) -> Path:
    return _make_fake_python(path)


def _nvidia_versions_payload():
    return {
        "versions": {"audio-separator": "0.34.1", "torch": "2.4.1+cu121"},
        "torch_hip": "",
        "torch_cuda_available": True,
        "device_names": ["NVIDIA GeForce RTX 3060"],
    }


# --- A: explicit cuda:0 on an AMD/ROCm install resolves through ROCm ------


def test_explicit_cuda0_on_amd_resolves_to_healthy_rocm_runtime(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_linux(module, monkeypatch)
    rocm_python = _make_fake_python(tmp_path / ".venv-drumsep-rocm" / "bin" / "python")
    # .venv-drumsep never created -- the genuine-NVIDIA-CUDA check (tried
    # first, so a machine with real CUDA available is never redirected to
    # ROCm) correctly fails as "missing" before falling back to ROCm here.

    probed_require_cuda = []

    def fake_verify(path, require_gpu=False, require_cuda=False, **kwargs):
        if require_cuda:
            probed_require_cuda.append(path)
            return False, "missing", {}
        if path == rocm_python and require_gpu:
            return True, "ok", _rocm_versions_payload()
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, kind, info = module._select_drumsep_runtime("cuda:0", tmp_path)

    assert selected == rocm_python
    assert kind == "rocm", "execution backend must be rocm, not cuda"
    assert info["selection_policy"] == "explicit_cuda_namespace_resolved_rocm"
    assert info["torch_hip"] == "7.0.51831"
    assert probed_require_cuda, "genuine NVIDIA CUDA must be checked first, so a real CUDA machine is never hijacked"


# --- B: another cuda:N index reaching the resolver behaves the same -------


def test_explicit_cuda_index_on_amd_resolves_to_rocm(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_linux(module, monkeypatch)
    rocm_python = _make_fake_python(tmp_path / ".venv-drumsep-rocm" / "bin" / "python")

    def fake_verify(path, require_gpu=False, **kwargs):
        if path == rocm_python and require_gpu:
            return True, "ok", _rocm_versions_payload()
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, kind, info = module._select_drumsep_runtime("cuda:1", tmp_path)

    assert selected == rocm_python
    assert kind == "rocm"
    assert info["selection_policy"] == "explicit_cuda_namespace_resolved_rocm"


# --- C: ROCm runtime missing -> falls through to existing NVIDIA path -----


def test_explicit_cuda0_falls_through_to_nvidia_path_when_rocm_missing(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_linux(module, monkeypatch)
    # Neither .venv-drumsep-rocm nor .venv-drumsep exists -- a plausible
    # plain NVIDIA machine that has never run DrumSep before.

    def fake_verify(path, require_gpu=False, require_cuda=False, **kwargs):
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, reason, info = module._select_drumsep_runtime("cuda:0", tmp_path)

    assert selected is None
    # Existing NVIDIA-path failure info, not relabeled as a ROCm failure.
    assert "cuda_detail" in info
    assert "cpu_detail" in info
    assert info.get("selection_policy") != "explicit_cuda_namespace_resolved_rocm"
    assert "rocm_python" not in info, ".venv-drumsep must not be misattributed as the ROCm runtime"


# --- D: ROCm runtime present but broken -> deterministic ROCm failure -----


def test_explicit_cuda0_reports_rocm_failure_when_rocm_runtime_broken(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_linux(module, monkeypatch)
    rocm_python = _make_fake_python(tmp_path / ".venv-drumsep-rocm" / "bin" / "python")

    def fake_verify(path, require_gpu=False, require_cuda=False, **kwargs):
        if path == rocm_python:
            return False, "rocm_no_hip", {}
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, reason, info = module._select_drumsep_runtime("cuda:0", tmp_path)

    assert selected is None
    assert reason == "broken"
    assert info["rocm_detail"] == "rocm_no_hip"
    assert info["selection_policy"] == "explicit_cuda_namespace_resolved_rocm"
    # The genuine-NVIDIA-CUDA check already ran (and missed) first, so its
    # detail is present for diagnostics, but the CPU fallback must not have
    # been chased -- this is a ROCm runtime problem, not a CPU-only machine.
    assert info["cuda_detail"] == "missing"
    assert "cpu_detail" not in info


# --- E: genuine NVIDIA machine keeps its existing CUDA behavior -----------


def test_explicit_cuda0_on_nvidia_machine_unchanged(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_linux(module, monkeypatch)
    cuda_capable_python = _make_fake_python(tmp_path / ".venv-drumsep" / "bin" / "python")
    # .venv-drumsep-rocm does not exist on an NVIDIA machine.

    def fake_verify(path, require_gpu=False, require_cuda=False, **kwargs):
        if require_gpu and not require_cuda:
            # This is the ROCm disambiguation probe -- .venv-drumsep-rocm
            # is absent on a genuine NVIDIA machine.
            return False, "missing", {}
        if require_cuda and path == cuda_capable_python:
            return True, "ok", _nvidia_versions_payload()
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, kind, info = module._select_drumsep_runtime("cuda:0", tmp_path)

    assert selected == cuda_capable_python
    assert kind == "cuda", "NVIDIA Linux explicit CUDA must remain unchanged"
    assert info["selection_policy"] == "explicit_cuda"


# --- I / J: the ROCm disambiguation is structurally Linux-only -------------


def test_rocm_namespace_disambiguation_is_scoped_to_linux_explicit_cuda_branch():
    text = AUDIO_PROCESS.read_text(encoding="utf-8")
    linux_idx = text.index('if explicit_cuda and sys.platform.startswith("linux"):')
    windows_idx = text.index("if _is_windows_runtime() and explicit_cuda:")
    linux_block = text[linux_idx : linux_idx + 3200]
    windows_block = text[windows_idx : windows_idx + 1600]
    assert "explicit_cuda_namespace_resolved_rocm" in linux_block
    assert "explicit_cuda_namespace_resolved_rocm" not in windows_block, "Windows explicit CUDA must be untouched"
    # macOS never reaches an explicit_cuda branch at all: its GPU path is
    # gated on _is_darwin_arm64() with device "mps"/"gpu"/"auto", which
    # returns before explicit_cuda is ever evaluated.
    darwin_idx = text.index("if _is_darwin_arm64() and normalized_request in")
    assert darwin_idx < linux_idx, "macOS's mps-preferring branch must be evaluated before the Linux cuda:N branch"
