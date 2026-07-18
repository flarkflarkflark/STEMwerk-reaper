from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LINUX_BOOTSTRAP = ROOT / "scripts/reaper/STEMwerk_Bootstrap_Linux.sh"
MACOS_BOOTSTRAP = ROOT / "scripts/reaper/STEMwerk_Bootstrap_macOS.sh"
WINDOWS_BOOTSTRAP = ROOT / "scripts/reaper/STEMwerk_Bootstrap_Windows.ps1"

REQUIRED_LAYOUT = (
    "audio_separator_process.py",
    "_internal/STEMwerk_Managed_Python.sh",
    "vendor/stemwerk-core/pyproject.toml",
    "vendor/stemwerk-core/src/stemwerk_core/__init__.py",
    "vendor/stemwerk-core/src/stemwerk_core/separator.py",
)

PLATFORM_LAYOUT_STATUS = {
    "macOS": "REQUIRED_PRESENT",
    "Linux": "REQUIRED_PRESENT",
    "Windows": "DOCUMENTED_GAP",
}
WINDOWS_LAYOUT_BACKLOG = "BACKLOG_WINDOWS_STAGED_LAYOUT_FAILFAST"


def _linux_text() -> str:
    return LINUX_BOOTSTRAP.read_text(encoding="utf-8")


def _make_layout(tmp_path: Path) -> Path:
    layout = tmp_path / "layout"
    layout.mkdir()
    shutil.copy2(LINUX_BOOTSTRAP, layout / LINUX_BOOTSTRAP.name)
    for relative in REQUIRED_LAYOUT:
        target = layout / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("fixture\n", encoding="utf-8")
    return layout


def _run_layout(layout: Path, tmp_path: Path) -> tuple[subprocess.CompletedProcess[str], Path, Path, Path]:
    runtime = tmp_path / "runtime-must-not-exist"
    reporting = tmp_path / "reporting"
    reporting.mkdir()
    state = reporting / "bootstrap.env"
    log = reporting / "bootstrap.log"
    sentinel = tmp_path / "unchanged-sentinel"
    sentinel.write_text("unchanged\n", encoding="utf-8")
    env = os.environ.copy()
    env.update({"HOME": str(tmp_path / "home"), "XDG_DATA_HOME": str(tmp_path / "xdg")})
    result = subprocess.run(
        [
            "/bin/sh",
            str(layout / LINUX_BOOTSTRAP.name),
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
        text=True,
        capture_output=True,
        timeout=30,
    )
    assert not runtime.exists()
    assert sentinel.read_text(encoding="utf-8") == "unchanged\n"
    return result, state, log, sentinel


def test_linux_required_layout_contract_is_explicit_and_main_backed() -> None:
    script = _linux_text()
    assert "validate_required_reaper_layout()" in script
    for relative in REQUIRED_LAYOUT:
        assert (ROOT / "scripts/reaper" / relative).is_file()
        assert relative in script
    assert '_required_path="${SCRIPT_DIR}/${_required_relative}"' in script


def test_cross_platform_staged_layout_guard_status_is_explicit() -> None:
    macos = MACOS_BOOTSTRAP.read_text(encoding="utf-8")
    linux = _linux_text()
    windows = WINDOWS_BOOTSTRAP.read_text(encoding="utf-8")
    assert PLATFORM_LAYOUT_STATUS == {
        "macOS": "REQUIRED_PRESENT",
        "Linux": "REQUIRED_PRESENT",
        "Windows": "DOCUMENTED_GAP",
    }
    assert "validate_required_reaper_layout()" in macos
    assert "if ! validate_required_reaper_layout; then" in macos
    assert "validate_required_reaper_layout()" in linux
    assert "if ! validate_required_reaper_layout; then" in linux
    if PLATFORM_LAYOUT_STATUS["Windows"] == "PRESENT":
        assert "validate_required_reaper_layout" in windows
    else:
        assert PLATFORM_LAYOUT_STATUS["Windows"] == "DOCUMENTED_GAP"
        assert WINDOWS_LAYOUT_BACKLOG == "BACKLOG_WINDOWS_STAGED_LAYOUT_FAILFAST"
    assert WINDOWS_LAYOUT_BACKLOG == "BACKLOG_WINDOWS_STAGED_LAYOUT_FAILFAST"


def test_linux_layout_validation_precedes_every_runtime_mutation_class() -> None:
    script = _linux_text()
    execution = script[script.index('if [ -z "${RUNTIME_BASE}" ]'):]
    validation = execution.index("if ! validate_required_reaper_layout; then")
    mutation_markers = (
        'if [ "${MODE}" = "rebuild-venv"',
        'mkdir -p "${RUNTIME_BASE}/state"',
        'set_progress "1"',
        'set_progress "2"',
        "install_managed_python_runtime",
        "create_venv_with_selected_python",
        "pip_install_with_scope",
        "ensure_core_model_cache",
        'apply_drumsep_sibling_policy "cpu"',
        'apply_drumsep_sibling_policy "rocm"',
        'resolve_main_drumsep_runtime_policy "rocm"',
    )
    for marker in mutation_markers:
        assert validation < execution.index(marker), marker


def test_complete_layout_reaches_one_safe_post_validation_sentinel(tmp_path: Path) -> None:
    layout = _make_layout(tmp_path)
    bootstrap = layout / LINUX_BOOTSTRAP.name
    script = bootstrap.read_text(encoding="utf-8")
    needle = '  log "staged_layout_validation=ok"\n'
    assert script.count(needle) == 1
    bootstrap.write_text(
        script.replace(needle, needle + '  log "HARNESS_POST_VALIDATION_SENTINEL=1"\n  exit 0\n'),
        encoding="utf-8",
    )
    result, _state, log, _sentinel = _run_layout(layout, tmp_path)
    assert result.returncode == 0
    text = log.read_text(encoding="utf-8")
    assert "staged_layout_validation=ok" in text
    assert text.count("HARNESS_POST_VALIDATION_SENTINEL=1") == 1


def test_missing_audio_process_fails_before_runtime_mutation(tmp_path: Path) -> None:
    layout = _make_layout(tmp_path)
    (layout / "audio_separator_process.py").unlink()
    result, state, log, _sentinel = _run_layout(layout, tmp_path)
    assert result.returncode != 0
    assert "STATUS=deps_failed" in state.read_text(encoding="utf-8")
    assert "STATUS_REASON=staged_layout_incomplete:audio_separator_process.py" in state.read_text(encoding="utf-8")
    text = log.read_text(encoding="utf-8")
    assert "staged_layout_validation=failed:audio_separator_process.py" in text
    assert "Installing optional DrumSep ROCm" not in text
    assert "drumsep" not in state.read_text(encoding="utf-8").lower()


def test_missing_second_contract_file_fails_before_runtime_mutation(tmp_path: Path) -> None:
    layout = _make_layout(tmp_path)
    missing = "_internal/STEMwerk_Managed_Python.sh"
    (layout / missing).unlink()
    result, state, log, _sentinel = _run_layout(layout, tmp_path)
    assert result.returncode != 0
    assert f"STATUS_REASON=staged_layout_incomplete:{missing}" in state.read_text(encoding="utf-8")
    text = log.read_text(encoding="utf-8")
    assert f"staged_layout_validation=failed:{missing}" in text
    assert "Installing optional DrumSep ROCm" not in text
