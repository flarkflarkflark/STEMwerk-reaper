import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "scripts" / "reaper" / "STEMwerk_Bootstrap_Windows.ps1"
SETUP = ROOT / "scripts" / "reaper" / "_internal" / "STEMwerk_Setup_Internal.lua"


def _bootstrap() -> str:
    return BOOTSTRAP.read_text(encoding="utf-8-sig")


def _probe_code() -> str:
    text = _bootstrap()
    function_start = text.index("function TestMainTorchAudioRuntime")
    code_start = text.index("$probeCode = @'", function_start) + len("$probeCode = @'")
    return text[code_start : text.index("\n'@", code_start)].lstrip("\r\n")


def _run_probe(tmp_path: Path, torch_version: str, audio_version: str | None, backend: str) -> str:
    modules = tmp_path / "modules"
    torch = modules / "torch"
    torch.mkdir(parents=True)
    (torch / "__init__.py").write_text(f'__version__ = "{torch_version}"\n', encoding="utf-8")
    if audio_version is not None:
        audio = modules / "torchaudio"
        audio.mkdir()
        (audio / "__init__.py").write_text(
            f'__version__ = "{audio_version}"\n', encoding="utf-8"
        )
    result = tmp_path / "result.txt"
    env = os.environ.copy()
    env.update(
        {
            "PYTHONPATH": str(modules),
            "STEMWERK_TORCHAUDIO_RESULT": str(result),
            "STEMWERK_TORCHAUDIO_BACKEND": backend,
            "STEMWERK_TORCHAUDIO_VERSION": "2.4.1",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
    )
    subprocess.run([sys.executable, "-c", _probe_code()], check=True, env=env)
    return result.read_text(encoding="utf-8")


def test_windows_cpu_and_cuda_torchaudio_contracts_use_matching_official_indexes() -> None:
    text = _bootstrap()
    assert '$pytorchCpuIndex = "https://download.pytorch.org/whl/cpu"' in text
    assert '$pytorchCudaIndex = "https://download.pytorch.org/whl/cu121"' in text
    assert 'Requirement = "torchaudio==$torchAudioVersion+cpu"' in text
    assert 'Requirement = "torchaudio==$torchAudioVersion$torchCudaSuffix"' in text
    assert 'Index = $pytorchCpuIndex' in text
    assert 'Index = $pytorchCudaIndex' in text


def test_torchaudio_repair_does_not_replace_healthy_torch() -> None:
    text = _bootstrap()
    start = text.index("function EnsureMatchedTorchaudioRuntime")
    end = text.index("\nfunction ", start + 10)
    function = text[start:end]
    assert '"--no-deps"' in function
    assert '"--index-url"' in function
    assert "$contract.Requirement" in function
    assert "torch==" not in function
    assert "torchvision==" not in function


def test_cuda_backend_install_uses_the_complete_matched_stack() -> None:
    text = _bootstrap()
    start = text.index("function InstallBackendRuntime")
    end = text.index("function VerifyBackendRuntime", start)
    function = text[start:end]
    assert '$torchAudioCudaReq = "torchaudio==$torchAudioVersion$torchCudaSuffix"' in function
    assert "$torchCudaReq" in function
    assert "$torchAudioCudaReq" in function
    assert '"--index-url",$pytorchCudaIndex' in function


def test_readiness_probes_torchaudio_version_and_backend() -> None:
    text = _bootstrap()
    assert "function TestMainTorchAudioRuntime" in text
    assert 'errors.append("torchaudio_missing")' in text
    assert 'errors.append("torchaudio_version_mismatch")' in text
    assert 'errors.append("torchaudio_backend_mismatch")' in text
    assert "EnsureMatchedTorchaudioRuntime $PythonPath $BackendName" in text
    assert '$script:torchAudioOk' in text


def test_import_probe_accepts_cpu_pair_and_rejects_missing_or_mismatched_audio(tmp_path: Path) -> None:
    assert _run_probe(tmp_path / "ok", "2.4.1+cpu", "2.4.1+cpu", "cpu") == (
        "ok|torch_torchaudio_compatible"
    )
    assert _run_probe(tmp_path / "missing", "2.4.1+cpu", None, "cpu") == (
        "repair_required|torchaudio_missing"
    )
    assert _run_probe(tmp_path / "mismatch", "2.4.1+cpu", "2.3.1+cpu", "cpu") == (
        "repair_required|torchaudio_version_mismatch"
    )


def test_import_probe_preserves_backend_identity(tmp_path: Path) -> None:
    assert _run_probe(tmp_path / "cuda", "2.4.1+cu121", "2.4.1+cu121", "cuda") == (
        "ok|torch_torchaudio_compatible"
    )
    assert _run_probe(tmp_path / "wrong", "2.4.1+cu121", "2.4.1+cpu", "cuda") == (
        "repair_required|torchaudio_backend_mismatch"
    )


def test_missing_main_torchaudio_blocks_ready_marker() -> None:
    text = _bootstrap()
    assert '$mainRuntimeStatus -ne "ok"' in text
    assert '$readyStatus = "repair_required"' in text
    assert '$status = "repair_required"' in text
    assert '$statusReason = $mainReadyDetail' in text


def test_windows_setup_does_not_override_torchaudio_drift_with_stale_success() -> None:
    text = SETUP.read_text(encoding="utf-8")
    assert 'local windowsTorchaudioContractFailed = OS == "Windows"' in text
    assert 'runtimeDriftReason == "torchaudio_missing_for_demucs"' in text
    assert 'runtimeDriftReason == "torchaudio_version_mismatch"' in text
    assert "local authoritativeRuntimeVerified = authoritativeBootstrapVerified" in text
    assert "and not windowsTorchaudioContractFailed" in text
    assert 'state.STATUS = "repair_required"' in text
    assert "state.STATUS_REASON = runtimeDriftReason" in text


def test_drumsep_contract_and_other_platform_bootstraps_are_not_changed_by_contract() -> None:
    text = _bootstrap()
    assert '$drumsepTorchVersion = "2.12.0"' in text
    assert '$drumsepTorchVisionVersion = "0.27.0"' in text
    assert "STEMwerk_Bootstrap_Linux.sh" not in text
    assert "STEMwerk_Bootstrap_macOS.sh" not in text


def test_no_offline_allmodels_or_update_patch_is_added() -> None:
    text = _bootstrap().lower()
    assert "update-patch" not in text
    # Existing legacy mode detection is retained, but this fix must not add a package route.
    assert "build_offline" not in text
