"""Regression tests for the 2.3.1.0 Windows bundled-online release blocker:
resolved FFmpeg was not reachable by DrumSep child processes.

Live reproduction (Windows 11 VM, WinGet FFmpeg links disabled so no
system/PATH FFmpeg was discoverable): the bundled-online installer correctly
extracted and live-validated its embedded FFmpeg, and core/Demucs model
prefetch successfully used the resolved absolute path -- but
"Verify DrumSep runtime" then failed with:

    ERROR - separator - FFmpeg is not installed. Please install FFmpeg...
    FileNotFoundError: [WinError 2] The system cannot find the file specified

because audio-separator's check_ffmpeg_installed() invokes bare
subprocess.check_output(["ffmpeg", "-version"]), and the resolved bundled
FFmpeg bin directory was never added to that child process's PATH.

Root cause: VerifyDrumsepRuntime (the CPU DrumSep verify function, matching
the live log's plain "Verify DrumSep runtime" label) was the only DrumSep
verify function that never called ResolveWindowsFfmpegPath or wrapped its
child Python invocation in InvokeWithResolvedFfmpegEnvironment -- unlike its
VerifyDrumsepCudaRuntime/VerifyDrumsepDirectmlRuntime siblings, which already
did (from the prior WinGet-resolver fix). Fixed by bringing it in line with
that existing, already-correct pattern.

Actual Kit Split/DrumSep *processing* (not bootstrap-time verification) was
traced separately: it always routes through audio_separator_process.py,
which calls _configure_ffmpeg_runtime() (reads STEMWERK_FFMPEG_PATH/
bootstrap.env/capabilities.env, prepends the resolved ffmpeg bin dir to
os.environ["PATH"]) before ever launching the DrumSep stage2 helper
subprocess via build_drumsep_subprocess_env(), which filters PATH by root
but does not strip the ffmpeg bin dir. Section K below proves this
behaviorally rather than assuming it.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "scripts" / "reaper" / "STEMwerk_Bootstrap_Windows.ps1"
AUDIO_SEPARATOR_PROCESS = ROOT / "scripts" / "reaper" / "audio_separator_process.py"


def _ps_function(text: str, name: str) -> str:
    start = text.index(f"function {name}")
    brace = text.index("{", start)
    depth = 0
    single = False
    double = False
    for index in range(brace, len(text)):
        char = text[index]
        previous = text[index - 1] if index else ""
        if char == "'" and not double and previous != "`":
            single = not single
        elif char == '"' and not single and previous != "`":
            double = not double
        elif not single and not double:
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    return text[start : index + 1]
    raise AssertionError(name)


# --- H/I/J: DrumSep CPU/CUDA/DirectML verify all receive the resolved -------
# FFmpeg PATH (behavioral, real pwsh subprocess) ------------------------------

# Normalize-WindowsPath/Join-NormalizedWindowsPath are Windows-specific (they
# normalize to backslash paths), which is correct on a real Windows host but
# meaningless against a hermetic POSIX tmp_path on this Linux test runner --
# Test-Path on a backslash-mangled path never finds anything here. Neither
# function is touched by this fix, so the harness defines a POSIX-safe
# stand-in for Join-NormalizedWindowsPath instead of extracting the real one.
_COMMON_DEPS = ("GetFfprobePathForFfmpeg", "TestFfmpegPair", "IsFfmpegShim", "ResolveWindowsFfmpegPath", "InvokeWithResolvedFfmpegEnvironment")


def _make_pair(dir_path: Path) -> Path:
    dir_path.mkdir(parents=True, exist_ok=True)
    ffmpeg = dir_path / "ffmpeg.exe"
    ffmpeg.write_bytes(b"fixture")
    (dir_path / "ffprobe.exe").write_bytes(b"fixture")
    return ffmpeg


def _run_drumsep_verify_harness(tmp_path: Path, target_function: str, extra_deps: tuple[str, ...] = ()) -> dict[str, str]:
    """Extracts the real PowerShell source for ResolveWindowsFfmpegPath's
    dependency chain plus the target Verify*Runtime function, stubs the
    model/dependency-version machinery and RunHidden (capturing PATH at the
    exact moment RunHidden is invoked -- i.e. from inside
    InvokeWithResolvedFfmpegEnvironment's scriptblock, proving the real
    wrapping mechanism, not a re-implementation of it), and runs it with the
    real pwsh interpreter."""
    text = BOOTSTRAP.read_text(encoding="utf-8-sig")
    deps = _COMMON_DEPS + extra_deps
    functions = "\n".join(_ps_function(text, name) for name in deps)
    target = _ps_function(text, target_function)

    runtime = tmp_path / "runtime"
    ffmpeg = _make_pair(runtime / "ffmpeg" / "bin")
    model_dir = tmp_path / "models"
    model_dir.mkdir()
    model_file = model_dir / "model.ckpt"
    model_file.write_bytes(b"fixture")
    model_yaml = model_dir / "model.yaml"
    model_yaml.write_bytes(b"fixture")

    python_path = tmp_path / "python.exe"
    python_path.write_bytes(b"fixture")

    nonexistent = tmp_path / "does_not_exist"
    harness = tmp_path / "harness.ps1"
    harness.write_text(
        f"""
$RuntimeBase = '{runtime}'
$localAppData = '{nonexistent / "lad"}'
$programFiles = '{nonexistent / "pf"}'
$programFilesX86 = '{nonexistent / "pf86"}'
function LogProgress([string]$Message) {{ }}
function LogLine([string]$Message) {{ }}
function InstallFfmpegDirect {{ return $null }}
function GetDrumsepModelDir {{ return '{model_dir}' }}
function GetDrumsepModelFilePath {{ return '{model_file}' }}
function GetDrumsepModelYamlPath {{ return '{model_yaml}' }}
function GetDrumsepDirectmlModelFilePath {{ return '{model_file}' }}
function GetDrumsepDirectmlModelYamlPath {{ return '{model_yaml}' }}
function Join-NormalizedWindowsPath([string]$BasePath, [string[]]$ChildParts) {{
    $current = $BasePath
    foreach ($child in $ChildParts) {{ if (-not [string]::IsNullOrWhiteSpace($child)) {{ $current = Join-Path $current $child }} }}
    return $current
}}
$global:CapturedPath = $null
function RunHidden([string]$File, [string[]]$Arguments, [string]$Description) {{
    $global:CapturedPath = $env:PATH
    $global:LASTEXITCODE = 0
}}
{functions}
{target}
$result = {target_function} '{python_path}'
Write-Output ("RESULT=" + $(if ($result -is [string]) {{ $result }} else {{ $result.Status }}))
Write-Output ("CAPTURED_PATH_HAS_FFMPEG_DIR=" + $(if ($global:CapturedPath) {{ ($global:CapturedPath -split ';') -icontains '{ffmpeg.parent}' }} else {{ 'false' }}))
""",
        encoding="utf-8",
    )
    result = subprocess.run(["pwsh", "-NoProfile", "-File", str(harness)], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    return dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)


def test_drumsep_cpu_verify_receives_resolved_ffmpeg_on_path():
    """H: the exact bug from the live reproduction -- DrumSep CPU verify's
    child process must see the resolved (runtime-local/bundled) FFmpeg bin
    directory on its PATH."""
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        state = _run_drumsep_verify_harness(Path(tmp), "VerifyDrumsepRuntime")
    assert state["RESULT"] == "ok"
    assert state["CAPTURED_PATH_HAS_FFMPEG_DIR"] == "True"


def test_drumsep_cuda_verify_receives_resolved_ffmpeg_on_path():
    """I: CUDA verify must receive the same resolved FFmpeg PATH (already
    fixed in the prior round; guarded here against regression)."""
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        state = _run_drumsep_verify_harness(Path(tmp), "VerifyDrumsepCudaRuntime")
    assert state["RESULT"] == "ok"
    assert state["CAPTURED_PATH_HAS_FFMPEG_DIR"] == "True"


def test_drumsep_directml_verify_receives_resolved_ffmpeg_on_path():
    """J: DirectML verify must receive the same resolved FFmpeg PATH
    (already fixed in the prior round; guarded here against regression)."""
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        state = _run_drumsep_verify_harness(Path(tmp), "VerifyDrumsepDirectmlRuntime")
    assert state["RESULT"] == "ok"
    assert state["CAPTURED_PATH_HAS_FFMPEG_DIR"] == "True"


# --- C/D: PATH preservation and spaces (behavioral) -------------------------


def test_ffmpeg_path_injection_preserves_existing_path_and_handles_spaces(tmp_path: Path):
    """C/D: InvokeWithResolvedFfmpegEnvironment must prepend the ffmpeg bin
    dir (even when it contains spaces) while leaving the rest of the
    original PATH intact and in order, with no broken quoting/tokenization."""
    text = BOOTSTRAP.read_text(encoding="utf-8-sig")
    function = _ps_function(text, "InvokeWithResolvedFfmpegEnvironment")
    ffmpeg_dir = tmp_path / "Some Folder" / "STEMwerk" / "ffmpeg" / "bin"
    ffmpeg_dir.mkdir(parents=True)
    ffmpeg_exe = ffmpeg_dir / "ffmpeg.exe"
    ffmpeg_exe.write_bytes(b"fixture")
    harness = tmp_path / "harness.ps1"
    harness.write_text(
        f"""
{function}
$env:PATH = 'C:\\Windows\\System32;C:\\Windows'
InvokeWithResolvedFfmpegEnvironment '{ffmpeg_exe}' {{
    Write-Output ("INSIDE_PATH=" + $env:PATH)
}}
Write-Output ("AFTER_PATH=" + $env:PATH)
""",
        encoding="utf-8",
    )
    result = subprocess.run(["pwsh", "-NoProfile", "-File", str(harness)], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    state = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    inside_parts = state["INSIDE_PATH"].split(";")
    assert str(ffmpeg_dir) == inside_parts[0], "resolved ffmpeg dir must be prepended, spaces intact, no quoting added"
    assert "C:\\Windows\\System32" in inside_parts
    assert "C:\\Windows" in inside_parts
    assert state["AFTER_PATH"] == "C:\\Windows\\System32;C:\\Windows", "original PATH must be restored after the block"


def test_ffmpeg_path_injection_avoids_duplicate_insertion(tmp_path: Path):
    """Requirement 5: avoid duplicate insertion where practical."""
    text = BOOTSTRAP.read_text(encoding="utf-8-sig")
    function = _ps_function(text, "InvokeWithResolvedFfmpegEnvironment")
    ffmpeg_dir = tmp_path / "ffmpeg" / "bin"
    ffmpeg_dir.mkdir(parents=True)
    ffmpeg_exe = ffmpeg_dir / "ffmpeg.exe"
    ffmpeg_exe.write_bytes(b"fixture")
    harness = tmp_path / "harness.ps1"
    harness.write_text(
        f"""
{function}
$env:PATH = '{ffmpeg_dir};C:\\Windows'
InvokeWithResolvedFfmpegEnvironment '{ffmpeg_exe}' {{
    Write-Output ("INSIDE_PATH=" + $env:PATH)
}}
""",
        encoding="utf-8",
    )
    result = subprocess.run(["pwsh", "-NoProfile", "-File", str(harness)], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    state = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    assert state["INSIDE_PATH"].split(";").count(str(ffmpeg_dir)) == 1


# --- M: no global/system PATH mutation --------------------------------------


def test_ffmpeg_path_injection_never_touches_machine_or_user_path():
    """M: no setx, no registry PATH write, no permanent environment
    mutation -- only $env:PATH (process-local) may be touched, and it must
    be restored in a finally block."""
    text = BOOTSTRAP.read_text(encoding="utf-8-sig")
    function = _ps_function(text, "InvokeWithResolvedFfmpegEnvironment")
    assert "setx" not in function.lower()
    assert "[Environment]::SetEnvironmentVariable" not in function.replace(" ", "")
    assert "HKEY" not in function.upper()
    assert "Registry" not in function
    assert "finally {" in function
    assert "$env:PATH = $previousPath" in function


def test_windows_verify_only_still_has_no_reachable_allowinstall_after_cpu_fix():
    """Regression guard: adding FFmpeg resolution to VerifyDrumsepRuntime
    must not reopen the AllowInstall-reachable-from-Check-only bug fixed in
    the prior round. VerifyDrumsepRuntime's own new AllowInstall switch must
    default to false, and none of the Check/ready-to-go call sites may pass
    it explicitly."""
    text = BOOTSTRAP.read_text(encoding="utf-8-sig")
    fn = _ps_function(text, "VerifyDrumsepRuntime")
    assert "function VerifyDrumsepRuntime([string]$PythonPath, [switch]$AllowInstall)" in fn
    assert "ResolveWindowsFfmpegPath -AllowInstall:$AllowInstall" in fn

    ready_body = text[text.index("function VerifyExistingReadyRuntime") : text.index("function RunReadyToGoVerifyOnly")]
    for line in ready_body.splitlines():
        if "VerifyDrumsepRuntime" in line:
            assert "-AllowInstall" not in line, f"Check/ready-to-go call site must not pass -AllowInstall: {line}"

    install_fn = _ps_function(text, "InstallDrumsepRuntime")
    assert "VerifyDrumsepRuntime $drumsepPython -AllowInstall" in install_fn


# --- K: actual DrumSep *processing* worker launch (behavioral, real Python) -


def _write_bootstrap_env(state_dir: Path, ffmpeg_path: Path) -> None:
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "bootstrap.env").write_text(f"FFMPEG_PATH={ffmpeg_path}\n", encoding="utf-8")


def test_processing_worker_env_includes_resolved_ffmpeg_bin_dir(tmp_path: Path, monkeypatch):
    """K: prove the REAL processing launcher functions (not just
    verification) propagate the resolved FFmpeg bin dir into the DrumSep
    child subprocess's PATH -- exercising the actual
    _configure_ffmpeg_runtime() + build_drumsep_subprocess_env() functions
    from audio_separator_process.py with no system ffmpeg discoverable
    (shutil.which('ffmpeg') mocked to None, matching the live repro state),
    only a runtime-local/bundled bootstrap.env FFMPEG_PATH available."""
    sys.path.insert(0, str(AUDIO_SEPARATOR_PROCESS.parent))
    try:
        import importlib

        spec = importlib.util.spec_from_file_location("audio_separator_process_under_test", AUDIO_SEPARATOR_PROCESS)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        runtime_base = tmp_path / "STEMwerk"
        ffmpeg_bin = runtime_base / "ffmpeg" / "ffmpeg-9.0.1-essentials_build" / "bin"
        ffmpeg_exe = ffmpeg_bin / ("ffmpeg.exe" if module.os.name == "nt" else "ffmpeg")
        ffmpeg_bin.mkdir(parents=True)
        ffmpeg_exe.write_bytes(b"fixture")
        ffmpeg_exe.chmod(0o755)

        _write_bootstrap_env(runtime_base / "state", ffmpeg_exe)

        monkeypatch.setattr(module.shutil, "which", lambda name: None)
        monkeypatch.setattr(module, "_runtime_base_candidates", lambda: [runtime_base])
        for key in ("STEMWERK_FFMPEG_PATH", "FFMPEG_PATH", "IMAGEIO_FFMPEG_EXE"):
            monkeypatch.delenv(key, raising=False)
        monkeypatch.setenv("PATH", "/usr/bin")

        resolved_path, wrapper, path_prefix = module._configure_ffmpeg_runtime()
        assert resolved_path is not None, "must resolve the runtime-local/bundled FFmpeg with no system ffmpeg present"

        import os as _os

        base_env = module._clean_env()
        drumsep_python = tmp_path / "venv-drumsep" / ("Scripts" if _os.name == "nt" else "bin") / "python"
        drumsep_python.parent.mkdir(parents=True)
        drumsep_python.touch()
        helper_env, _diag = module.build_drumsep_subprocess_env(
            base_env, drumsep_python, module._runtime_venv_root(drumsep_python), "cpu"
        )

        helper_path_parts = helper_env["PATH"].split(_os.pathsep)
        assert str(ffmpeg_bin) in helper_path_parts, (
            "the DrumSep child subprocess environment must still contain the resolved "
            f"FFmpeg bin dir after build_drumsep_subprocess_env filtering; got PATH={helper_env['PATH']}"
        )
    finally:
        sys.path.remove(str(AUDIO_SEPARATOR_PROCESS.parent))


# --- L: Check-only remains non-mutating -------------------------------------


def test_check_only_source_still_has_no_persistent_writes_after_this_fix():
    """L: this fix must not reintroduce any capabilities.env/bootstrap.env/
    ExtState writes into the Check-only (windowsVerifyTick) flow -- guards
    the prior round's accepted fix (commit 6c628bf1)."""
    lua_setup = ROOT / "scripts" / "reaper" / "_internal" / "STEMwerk_Setup_Internal.lua"
    text = lua_setup.read_text(encoding="utf-8")
    start = text.index("local function windowsVerifyTick()")
    end = text.index("local function windowsVerifyStart(runtime, separatorScript, reuseWindow)", start)
    body = text[start:end]
    forbidden = ("updateBootstrapEnv(", "writeCapabilities(", 'setExt("ffmpegPath"', 'setExt("pythonPath"')
    found = [token for token in forbidden if token in body]
    assert not found, f"Check only source still contains persistent writes: {found}"
