"""Behavioral coverage for the Intel-macOS four-step bootstrap policy."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path


BOOTSTRAP = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh")


def _read_env(path: Path) -> dict[str, str]:
    return {
        key: value
        for line in path.read_text(encoding="utf-8").splitlines()
        if "=" in line
        for key, value in [line.split("=", 1)]
    }


def _write_executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


def _seed_core_models(home: Path) -> None:
    model_dir = home / "Library/Application Support/STEMwerk/models"
    model_dir.mkdir(parents=True)
    for name in (
        "htdemucs.yaml",
        "955717e8-8726e21a.th",
        "htdemucs_ft.yaml",
        "f7e0c4bc-ba3fe64a.th",
        "d12395a8-e57c48e6.th",
        "92cfc3b6-ef3bcb9c.th",
        "04573f0d-f3cf25b2.th",
        "htdemucs_6s.yaml",
        "5c90dfd2-34c22ccb.th",
    ):
        (model_dir / name).write_bytes(b"fixture\n")


def test_bootstrap_declares_four_intel_steps_and_keeps_five_for_arm64() -> None:
    text = BOOTSTRAP.read_text(encoding="utf-8")
    assert 'if [ "${MAC_ARCH}" = "x86_64" ]; then\n  STEP_TOTAL="4"\nelse\n  STEP_TOTAL="5"\nfi' in text
    for index, label in (
        ("1", "Preparing runtime"),
        ("2", "Installing Python runtime"),
        ("3", "Installing STEMwerk runtime"),
        ("4", "Checking FFmpeg"),
    ):
        assert f'set_progress "{index}" "${{STEP_TOTAL}}" "{label}"' in text
    assert 'if [ "${MAC_ARCH}" != "x86_64" ]; then\n  set_progress "5" "${STEP_TOTAL}" "Preparing Drum Kit runtime"\nfi' in text


def test_real_intel_bootstrap_tail_has_no_dks_work_and_still_verifies_main_runtime(tmp_path: Path) -> None:
    script_dir = tmp_path / "reaper"
    script_dir.mkdir()
    shutil.copy2(BOOTSTRAP, script_dir / BOOTSTRAP.name)

    # A deliberately present bundled DrumSep marker proves the Intel path does
    # not even seed bundled DKS assets before recording unsupported/skipped.
    bundled_drumsep = script_dir / "_bundled/macos/apple-silicon/drumsep"
    bundled_drumsep.mkdir(parents=True)
    (bundled_drumsep / "MUST_NOT_COPY").write_text("sentinel\n", encoding="utf-8")

    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    _write_executable(fake_bin / "uname", "#!/bin/sh\nprintf 'x86_64\\n'\n")
    _write_executable(fake_bin / "sw_vers", "#!/bin/sh\nprintf '15.7.9\\n'\n")
    for tool in ("ffmpeg", "ffprobe"):
        _write_executable(fake_bin / tool, f"#!/bin/sh\nprintf '%s\\n' '{tool} version fixture'\n")
    for tool in ("curl", "wget"):
        _write_executable(fake_bin / tool, "#!/bin/sh\nprintf '%s\\n' network >> \"${NETWORK_MARKER}\"\nexit 1\n")

    runtime = tmp_path / "runtime"
    (runtime / "state").mkdir(parents=True)
    python = runtime / ".venv/bin/python"
    python.parent.mkdir(parents=True)
    _write_executable(
        python,
        """#!/bin/sh
case "${1:-}" in
  -c)
    case "${2:-}" in
      *sys.version_info*) printf '%s\n' '3.12.13' ;;
      *'import numba'*) printf '%s\n' IMPORT_NUMBA >> "${PY_CALL_MARKER}" ;;
      *'import audio_separator'*) printf '%s\n' IMPORT_AUDIO_SEPARATOR >> "${PY_CALL_MARKER}" ;;
      *'import onnxruntime; print'*) printf '%s\n' '1.23.2' ;;
      *'import onnxruntime'*) printf '%s\n' IMPORT_ONNXRUNTIME >> "${PY_CALL_MARKER}" ;;
      *'import stemwerk_core'*) printf '%s\n' IMPORT_STEMWERK_CORE >> "${PY_CALL_MARKER}" ;;
    esac
    exit 0
    ;;
esac
body=$(cat)
case "$body" in
  *'summary = ";".join'*)
    printf '%s\n' 'match|python=3.12;architecture=x86_64;audio-separator=0.23.0;numpy=1.26.4;numba=0.59.1;llvmlite=0.42.0;torch=2.2.2;torchaudio=2.2.2;samplerate=0.1.0'
    ;;
  *'expected_numpy = '*)
    printf '%s\n' ASSERT_PINNED_TORCH >> "${PY_CALL_MARKER}"
    printf '%s\n' 'ok|profile=fixture'
    ;;
  *'errors = []'*)
    printf '%s\n' VERIFY_AUDIO_SEPARATOR_DEPS >> "${PY_CALL_MARKER}"
    printf '%s\n' ok
    ;;
  *'_direct_dks_preflight_check'*)
    printf '%s\n' ENSURE_DRUMSEP_ASSETS >> "${PY_CALL_MARKER}"
    ;;
esac
""",
    )

    home = tmp_path / "home"
    home.mkdir()
    _seed_core_models(home)
    state = tmp_path / "bootstrap.env"
    log = tmp_path / "bootstrap.log"
    py_calls = tmp_path / "python-calls.log"
    network = tmp_path / "network.log"

    env = dict(os.environ)
    env.update(
        {
            "PATH": f"{fake_bin}:{env['PATH']}",
            "HOME": str(home),
            "PY_CALL_MARKER": str(py_calls),
            "NETWORK_MARKER": str(network),
        }
    )
    result = subprocess.run(
        [
            "/bin/sh",
            str(script_dir / BOOTSTRAP.name),
            "--runtime-base",
            str(runtime),
            "--state-file",
            str(state),
            "--log-file",
            str(log),
            "--mode",
            "repair",
        ],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr + "\n" + log.read_text(encoding="utf-8")

    state_fields = _read_env(state)
    ready_fields = _read_env(runtime / "state/ready_to_go.env")
    log_text = log.read_text(encoding="utf-8")
    call_text = py_calls.read_text(encoding="utf-8")

    assert state_fields["STEP_TOTAL"] == "4"
    assert "STEP 4/4: Checking FFmpeg" in log_text
    assert "STEP 5/" not in log_text
    assert "Preparing Drum Kit runtime" not in log_text
    assert "ENSURE_DRUMSEP_ASSETS" not in call_text
    assert not (home / "Library/Application Support/STEMwerk/models/MUST_NOT_COPY").exists()
    for marker in (
        "IMPORT_NUMBA",
        "IMPORT_AUDIO_SEPARATOR",
        "VERIFY_AUDIO_SEPARATOR_DEPS",
        "IMPORT_ONNXRUNTIME",
        "IMPORT_STEMWERK_CORE",
        "ASSERT_PINNED_TORCH",
    ):
        assert marker in call_text
    assert ready_fields["MAIN_RUNTIME_STATUS"] == "ok"
    assert ready_fields["DRUMSEP_READY_RUNTIME_STATUS"] == "skipped"
    assert ready_fields["DRUMSEP_READY_MODEL_STATUS"] == "skipped"
    assert ready_fields["DRUMSEP_STATUS"] == "unsupported_mac_intel"
    assert ready_fields["DKS_SUPPORTED"] == "false"
    assert ready_fields["READY_TO_GO_DETAIL"] == "unsupported_mac_intel"
    assert not network.exists()


def test_intel_dks_calls_are_inside_the_non_intel_branch() -> None:
    text = BOOTSTRAP.read_text(encoding="utf-8")
    tail = text[text.index('if [ "${MAC_ARCH}" = "x86_64" ]; then\n  if [ "${STATUS}" = "ok" ]') :]
    intel_branch, arm_branch = tail.split('elif [ "${STATUS}" = "ok" ]', 1)
    assert "bundled_drumsep_dir" not in intel_branch
    assert "ensure_drumsep_assets" not in intel_branch
    assert 'READY_RUNTIME_STATUS="skipped"' in intel_branch
    assert 'READY_DRUMSEP_MODEL_STATUS="skipped"' in intel_branch
    assert 'READY_DETAIL="unsupported_mac_intel"' in intel_branch
    assert "bundled_drumsep_dir" in arm_branch
    assert "ensure_drumsep_assets" in arm_branch
