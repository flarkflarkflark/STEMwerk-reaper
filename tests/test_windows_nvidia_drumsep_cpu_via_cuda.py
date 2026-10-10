"""Windows NVIDIA: explicit CPU for Direct Kit / Kit Split must be able to use
an already-installed CUDA DrumSep runtime (.venv-drumsep-cuda) as a genuine
CPU execution environment when no dedicated CPU DrumSep runtime
(.venv-drumsep) exists.

Reproduced on a clean bundled Windows NVIDIA install (RTX 3060 Laptop GPU,
STEMwerk 2.3.1.2): Setup/Repair only provisions .venv-drumsep-cuda (never a
separate CPU venv, never DirectML) on this hardware. Explicit CPU for Direct
Kit and Kit Split failed with error_reason=drumsep_cpu_runtime_missing even
though the same clean install's CUDA DKS runs succeed (actual_drum_outputs=6,
expected_drum_outputs=6, ok=true, PASS for both Auto and explicit CUDA), so
the DrumSep install itself is healthy.

This is structurally identical to the proven Linux ROCm-as-CPU case (see
test_linux_amd_drumsep_cpu_via_rocm.py) and the proven Windows DirectML-as-CPU
case (see test_windows_amd_drumsep_cpu_via_directml.py): a CUDA-capable Torch
BUILD is not evidence a specific job executed on the GPU. The DrumSep helper
(scripts/reaper/_internal/stemwerk_drumsep_process.py) only enables GPU
execution when --device cuda is passed -- for --device cpu it always takes
the plain mdx_params/demucs_params/mdxc_params={"device": "cpu"} path,
identical to what a dedicated CPU venv would run, regardless of which venv's
interpreter is running the helper. build_drumsep_subprocess_env additionally
blanks CUDA_VISIBLE_DEVICES/NVIDIA_VISIBLE_DEVICES whenever the resolved
backend is "cpu", so the CUDA-capable interpreter cannot touch the GPU even
though it is CUDA-capable -- defense in depth on top of the helper's own
device gating.

The fix extends the same _select_drumsep_runtime explicit_cpu branch that
already carries the Linux ROCm-as-CPU and Windows DirectML-as-CPU tiers, by
adding a third, disjoint Windows-only tier that probes .venv-drumsep-cuda
with require_gpu=False (plain import/health check, not a live CUDA capability
check) after the CPU and DirectML tiers have both missed or failed.

These tests exercise the real _select_drumsep_runtime function (not a mock of
it), matching the existing convention in test_windows_amd_drumsep_cpu_via_directml.py
and test_linux_amd_drumsep_cpu_via_rocm.py: only _verify_drumsep_runtime --
the actual subprocess probe -- is faked, so the resolver's real candidate-
building/fallback/failure-classification logic runs unmodified.
"""

import importlib.util
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
    return _load_module(AUDIO_PROCESS, "audio_separator_process_nvidia_cpu_via_cuda_test")


class _OsProxy:
    def __init__(self, real_os, *, name: str):
        self._real_os = real_os
        self.name = name
        self.pathsep = ";" if name == "nt" else real_os.pathsep

    def __getattr__(self, attr):
        return getattr(self._real_os, attr)


def _set_windows(module, monkeypatch):
    monkeypatch.setattr(module, "os", _OsProxy(module.os, name="nt"))
    monkeypatch.setattr(module.sys, "platform", "win32")
    monkeypatch.setattr(module.platform, "machine", lambda: "AMD64")


def _make_fake_python(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    try:
        path.chmod(0o755)
    except Exception:
        pass
    return path


def _cuda_versions_payload():
    return {
        "versions": {"audio-separator": "0.34.1", "torch": "2.4.1+cu121", "onnxruntime": "1.26.0"},
        "torch_hip": "",
        "torch_cuda_available": True,
        "device_names": ["NVIDIA GeForce RTX 3060 Laptop GPU"],
        "directml_available": False,
        "directml_device_count": 0,
        "onnxruntime_providers": ["CUDAExecutionProvider", "CPUExecutionProvider"],
    }


# --- A: dedicated CPU runtime present and healthy -> unchanged behavior ----


def test_explicit_cpu_prefers_healthy_dedicated_cpu_runtime(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_windows(module, monkeypatch)
    cpu_python = _make_fake_python(tmp_path / ".venv-drumsep" / "Scripts" / "python.exe")
    cuda_python = _make_fake_python(tmp_path / ".venv-drumsep-cuda" / "Scripts" / "python.exe")

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
    assert info.get("runtime_source_family", "") != "cuda"
    assert cuda_python not in probed


# --- B: dedicated CPU runtime missing, CUDA runtime healthy -> use it ------
# This is the exact clean bundled Windows NVIDIA layout from the bug report:
# .venv-drumsep-cuda exists, .venv-drumsep and .venv-drumsep-directml are
# absent.


def test_explicit_cpu_falls_back_to_cuda_runtime_when_cpu_runtime_missing(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_windows(module, monkeypatch)
    cuda_python = _make_fake_python(tmp_path / ".venv-drumsep-cuda" / "Scripts" / "python.exe")

    def fake_verify(path, require_gpu=False, **kwargs):
        assert require_gpu is False, "CPU-via-CUDA probe must not require GPU"
        assert not kwargs.get("require_cuda"), "CPU-via-CUDA probe must not require live CUDA capability"
        if path == cuda_python:
            return True, "ok", _cuda_versions_payload()
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, kind, info = module._select_drumsep_runtime("cpu", tmp_path)

    assert selected == cuda_python
    assert kind == "cpu", "execution backend must be reported as cpu, not cuda"
    assert info["selection_policy"] == "explicit_cpu_via_cuda_runtime"
    assert info["runtime_source_family"] == "cuda", "must not erase that the interpreter came from the CUDA env"
    assert info["fallback_reason"] == "cpu_skipped:missing;directml_skipped:missing"
    assert info["detail"] == "ok"


def test_kit_split_explicit_cpu_also_falls_back_to_cuda_runtime(tmp_path, monkeypatch):
    """Kit Split (drumsep_extract) and Direct Kit both consume the same shared
    _select_drumsep_runtime resolver (see the structural test below), so this
    documents that Kit Split gets the identical fix, not a re-derivation of
    it."""
    module = _load_audio_process()
    _set_windows(module, monkeypatch)
    cuda_python = _make_fake_python(tmp_path / ".venv-drumsep-cuda" / "Scripts" / "python.exe")

    def fake_verify(path, require_gpu=False, **kwargs):
        if path == cuda_python:
            return True, "ok", _cuda_versions_payload()
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    # Kit Split and Direct Kit both request the runtime the same way -- there
    # is no separate "kit split" device request shape to exercise here.
    selected, kind, info = module._select_drumsep_runtime("cpu", tmp_path)

    assert selected == cuda_python
    assert kind == "cpu"
    assert info["selection_policy"] == "explicit_cpu_via_cuda_runtime"


# --- C: dedicated CPU runtime broken (not just missing), CUDA healthy ------


def test_explicit_cpu_falls_back_to_cuda_runtime_when_cpu_runtime_broken(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_windows(module, monkeypatch)
    cpu_python = _make_fake_python(tmp_path / ".venv-drumsep" / "Scripts" / "python.exe")
    cuda_python = _make_fake_python(tmp_path / ".venv-drumsep-cuda" / "Scripts" / "python.exe")

    def fake_verify(path, require_gpu=False, **kwargs):
        if path == cpu_python:
            return False, "ModuleNotFoundError: torch", {}
        if path == cuda_python:
            return True, "ok", _cuda_versions_payload()
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, kind, info = module._select_drumsep_runtime("cpu", tmp_path)

    # Existing convention elsewhere in this function (cuda->cpu, mps->cpu,
    # rocm->cpu on Linux, directml->cpu on Windows) falls through to the next
    # tier regardless of whether the preferred tier was "missing" or actually
    # broken -- mirrored here rather than inventing a new, narrower policy.
    assert selected == cuda_python
    assert kind == "cpu"
    assert info["selection_policy"] == "explicit_cpu_via_cuda_runtime"
    assert info["runtime_source_family"] == "cuda"
    assert info["fallback_reason"] == "cpu_skipped:ModuleNotFoundError: torch;directml_skipped:missing"


# --- D: no CPU, DirectML, or CUDA runtime exists -> original missing failure


def test_explicit_cpu_missing_failure_preserved_when_no_runtime_exists(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_windows(module, monkeypatch)
    # Neither .venv-drumsep, .venv-drumsep-directml, nor .venv-drumsep-cuda
    # is created.

    def fake_verify(path, require_gpu=False, **kwargs):
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, reason, info = module._select_drumsep_runtime("cpu", tmp_path)

    assert selected is None
    assert reason == "missing"
    assert info["selection_policy"] == "explicit_cpu"
    assert info["directml_cpu_detail"] == "missing"
    assert info["cuda_cpu_detail"] == "missing"


# --- E: no CPU/DirectML runtime, CUDA runtime present but broken -----------


def test_explicit_cpu_broken_when_only_cuda_present_and_broken(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_windows(module, monkeypatch)
    cuda_python = _make_fake_python(tmp_path / ".venv-drumsep-cuda" / "Scripts" / "python.exe")

    def fake_verify(path, require_gpu=False, **kwargs):
        if path == cuda_python:
            return False, "ImportError: onnxruntime", {}
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, reason, info = module._select_drumsep_runtime("cpu", tmp_path)

    assert selected is None
    # Aggregation mirrors the existing rocm/directml->cpu fallback chain:
    # "missing" only when every attempted tier was "missing".
    assert reason == "broken"
    assert info["cpu_detail"] == "missing"
    assert info["directml_cpu_detail"] == "missing"
    assert info["cuda_cpu_detail"] == "ImportError: onnxruntime"


# --- F: Auto on the same Windows NVIDIA layout is unaffected -- still CUDA -


def test_auto_on_windows_nvidia_still_prefers_cuda_gpu_unchanged(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_windows(module, monkeypatch)
    cuda_python = _make_fake_python(tmp_path / ".venv-drumsep-cuda" / "Scripts" / "python.exe")

    def fake_verify(path, require_gpu=False, require_cuda=False, **kwargs):
        if path == cuda_python and require_cuda:
            return True, "ok", _cuda_versions_payload()
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, kind, info = module._select_drumsep_runtime("auto", tmp_path)

    assert selected == cuda_python
    assert kind == "cuda"
    assert info["selection_policy"] in {"gpu_prefer_cuda", "auto_prefer_cuda"}


# --- G: explicit CUDA request is unaffected ---------------------------------


def test_explicit_cuda_request_unchanged(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_windows(module, monkeypatch)
    cuda_python = _make_fake_python(tmp_path / ".venv-drumsep-cuda" / "Scripts" / "python.exe")

    def fake_verify(path, require_gpu=False, require_cuda=False, **kwargs):
        if path == cuda_python and require_cuda:
            return True, "ok", _cuda_versions_payload()
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, kind, info = module._select_drumsep_runtime("cuda", tmp_path)

    assert selected == cuda_python
    assert kind == "cuda"
    assert info["selection_policy"] == "explicit_cuda"


# --- H: Windows AMD machine (DirectML only) is unaffected -- resolves via --
# DirectML before CUDA is ever probed (CUDA candidate simply does not exist).


def test_explicit_cpu_on_windows_amd_machine_does_not_probe_cuda(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_windows(module, monkeypatch)
    directml_python = _make_fake_python(tmp_path / ".venv-drumsep-directml" / "Scripts" / "python.exe")
    # No .venv-drumsep-cuda -- plausible AMD-only machine.

    probed_cuda = []

    def fake_verify(path, require_gpu=False, **kwargs):
        if path == directml_python:
            return True, "ok", {
                "versions": {"audio-separator": "0.34.1", "torch": "2.4.1+cpu"},
                "torch_hip": "",
                "torch_cuda_available": False,
                "directml_available": True,
                "directml_device_count": 2,
            }
        if "cuda" in str(path).lower():
            probed_cuda.append(path)
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, kind, info = module._select_drumsep_runtime("cpu", tmp_path)

    assert selected == directml_python
    assert kind == "cpu"
    assert info["selection_policy"] == "explicit_cpu_via_directml_runtime"
    assert not probed_cuda, "DirectML success must short-circuit before the CUDA tier is ever probed"


# --- I: CPU-via-CUDA subprocess environment gets real CPU isolation --------


def test_cpu_via_cuda_subprocess_env_hides_gpu_devices(tmp_path, monkeypatch):
    module = _load_audio_process()
    cuda_python = tmp_path / ".venv-drumsep-cuda" / "Scripts" / "python.exe"
    cuda_venv = tmp_path / ".venv-drumsep-cuda"
    base_env = {
        "PATH": "C:\\Windows\\System32",
        "CUDA_VISIBLE_DEVICES": "0",
        "NVIDIA_VISIBLE_DEVICES": "0",
    }

    env, diagnostics = module.build_drumsep_subprocess_env(base_env, cuda_python, cuda_venv, "cpu")

    assert env["CUDA_VISIBLE_DEVICES"] == ""
    assert env["NVIDIA_VISIBLE_DEVICES"] == ""
    assert diagnostics["drumsep_subprocess_env_profile"] == "cpu_isolated"
    assert diagnostics["drumsep_helper_device_arg"] == "cpu"
    assert diagnostics["drumsep_python"] == str(cuda_python)


# --- J: provenance is distinguishable from effective execution -------------


def test_provenance_distinguishes_cuda_source_from_cpu_execution(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_windows(module, monkeypatch)
    cuda_python = _make_fake_python(tmp_path / ".venv-drumsep-cuda" / "Scripts" / "python.exe")

    def fake_verify(path, require_gpu=False, **kwargs):
        if path == cuda_python:
            return True, "ok", _cuda_versions_payload()
        return False, "missing", {}

    monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
    selected, kind, info = module._select_drumsep_runtime("cpu", tmp_path)

    # Effective execution backend:
    assert kind == "cpu"
    # Physical runtime source family is preserved, not erased:
    assert info["runtime_source_family"] == "cuda"
    assert info["versions"]["torch"] == "2.4.1+cu121"
    assert str(selected) == str(cuda_python)


# --- K: the helper --device flag actually resolved for this run is "cpu" --
# Explicit CPU cannot silently become CUDA: even though the *host* interpreter
# is .venv-drumsep-cuda, the *execution* device string threaded through to the
# DrumSep helper subprocess (via _resolve_benchmark_drumsep_helper_device,
# called with runtime_kind="cpu") must resolve to "cpu", not "cuda".


def test_resolved_helper_device_stays_cpu_when_host_is_cuda_venv(tmp_path, monkeypatch):
    module = _load_audio_process()
    _set_windows(module, monkeypatch)
    cuda_python = _make_fake_python(tmp_path / ".venv-drumsep-cuda" / "Scripts" / "python.exe")
    monkeypatch.delenv(module.BENCHMARK_DRUMSEP_HELPER_DEVICE_ENV, raising=False)

    device, reason = module._resolve_benchmark_drumsep_helper_device("cpu", "cpu", cuda_python)

    assert device == "cpu"
    assert device != "cuda"


def test_dks_extract_stage2_backend_reports_cpu_not_cuda_despite_interpreter_path(tmp_path):
    """_detect_dks_extract_stage2_backend must trust the resolver's kind
    ("cpu") over path-sniffing the interpreter's location, which would
    otherwise see "cuda" in the .venv-drumsep-cuda path and misreport the
    backend."""
    module = _load_audio_process()
    cuda_python = tmp_path / ".venv-drumsep-cuda" / "Scripts" / "python.exe"
    backend = module._detect_dks_extract_stage2_backend("cpu", {"kind": "cpu"}, cuda_python)
    assert backend == "cpu"


# --- L: Direct Kit and Kit Split both consume the shared resolver ----------


def test_direct_kit_and_kit_split_both_call_shared_resolver():
    text = AUDIO_PROCESS.read_text(encoding="utf-8")
    extract_idx = text.index("_is_extract_dks_source(args.workflow_mode, args.workflow_source)")
    direct_idx = text.index("_is_direct_dks_source(args.workflow_mode, args.workflow_source)")
    extract_block = text[extract_idx : extract_idx + 3000]
    direct_block = text[direct_idx : direct_idx + 3000]
    assert "_select_drumsep_runtime(device_preference)" in extract_block, "Kit Split must use the shared resolver"
    assert "_select_drumsep_runtime(device_preference)" in direct_block, "Direct Kit must use the shared resolver"


# --- M: the CUDA-as-CPU fallback is structurally Windows-only and ordered --
# after the CPU, ROCm (Linux-only), and DirectML (Windows-only) tiers.


def test_cuda_as_cpu_fallback_is_scoped_to_windows_explicit_cpu_branch():
    text = AUDIO_PROCESS.read_text(encoding="utf-8")
    explicit_cpu_idx = text.index("if explicit_cpu:")
    next_top_level_idx = text.index("\n    if explicit_cuda and sys.platform.startswith(\"linux\"):", explicit_cpu_idx)
    explicit_cpu_block = text[explicit_cpu_idx:next_top_level_idx]

    assert "explicit_cpu_via_rocm_runtime" in explicit_cpu_block
    assert "explicit_cpu_via_directml_runtime" in explicit_cpu_block
    assert "explicit_cpu_via_cuda_runtime" in explicit_cpu_block

    rocm_guard_idx = explicit_cpu_block.index('if sys.platform.startswith("linux"):')
    directml_guard_idx = explicit_cpu_block.index("if _is_windows_runtime():")
    cuda_guard_idx = explicit_cpu_block.rindex("if _is_windows_runtime():")

    assert rocm_guard_idx < directml_guard_idx < cuda_guard_idx, (
        "ROCm-as-CPU must stay the Linux-only tier, and DirectML-as-CPU must "
        "be probed strictly before CUDA-as-CPU within the Windows-only tiers"
    )

    # The ROCm-as-CPU probe must not run when the DirectML/CUDA-as-CPU probes
    # run, and vice versa -- each platform tier is gated by a disjoint
    # predicate, and the two Windows tiers are sequential, not nested.
    rocm_block_end = explicit_cpu_block.index('directml_cpu_detail = "missing"')
    rocm_block = explicit_cpu_block[rocm_guard_idx:rocm_block_end]
    assert "_is_windows_runtime()" not in rocm_block

    directml_block_end = explicit_cpu_block.index('cuda_cpu_detail = "missing"')
    directml_block = explicit_cpu_block[directml_guard_idx:directml_block_end]
    assert "explicit_cpu_via_cuda_runtime" not in directml_block, "DirectML tier must return before the CUDA tier begins"


def test_macos_and_linux_explicit_cpu_never_probe_cuda_as_cpu_candidates(tmp_path, monkeypatch):
    for plat, os_name in (("linux", "posix"), ("darwin", "posix")):
        module = _load_audio_process()
        monkeypatch.setattr(module, "os", _OsProxy(module.os, name=os_name))
        monkeypatch.setattr(module.sys, "platform", plat)
        monkeypatch.setattr(module.platform, "machine", lambda: "arm64" if plat == "darwin" else "x86_64")
        cuda_python = _make_fake_python(tmp_path / plat / ".venv-drumsep-cuda" / "Scripts" / "python.exe")

        probed = []

        def fake_verify(path, require_gpu=False, **kwargs):
            probed.append(path)
            return False, "missing", {}

        monkeypatch.setattr(module, "_verify_drumsep_runtime", fake_verify)
        module._select_drumsep_runtime("cpu", tmp_path / plat)

        assert cuda_python not in probed, f"{plat} explicit CPU must never probe CUDA-as-CPU candidates via this new tier"
