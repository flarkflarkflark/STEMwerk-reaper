from __future__ import annotations

import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "scripts" / "reaper" / "STEMwerk_Bootstrap_Windows.ps1"
SETUP = ROOT / "scripts" / "reaper" / "_internal" / "STEMwerk_Setup_Internal.lua"
INSTALLER = ROOT / "installer" / "windows" / "STEMwerk_Installer_Windows.ps1"
ISS = ROOT / "installer" / "windows" / "STEMwerk.iss"


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


def _run_ready_harness(tmp_path: Path, ffmpeg_valid: bool) -> dict[str, str]:
    text = BOOTSTRAP.read_text(encoding="utf-8-sig")
    function = _ps_function(text, "WriteReadyToGoState")
    runtime = tmp_path / "runtime"
    (runtime / "state").mkdir(parents=True)
    harness = tmp_path / "ready.ps1"
    harness.write_text(
        f"""
$RuntimeBase = '{runtime}'
$script:FfmpegValidated = ${str(ffmpeg_valid).lower()}
function GetReadyToGoStatePath {{ Join-Path $RuntimeBase 'state/ready_to_go.env' }}
function LogProgress([string]$Message) {{ }}
{function}
$core = @{{ model_dir = 'models'; fast = 'ok'; quality = 'ok'; sixstem = 'ok' }}
WriteReadyToGoState 'cpu' 'ok' 'ok' $core 'ok' 'ok'
$path = GetReadyToGoStatePath
if (Test-Path $path) {{ Get-Content $path }} else {{ 'MARKER_ABSENT=yes' }}
""",
        encoding="utf-8",
    )
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-File", str(harness)],
        check=True,
        text=True,
        capture_output=True,
    )
    values: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def _run_pair_harness(tmp_path: Path, scenario: str) -> dict[str, str]:
    text = BOOTSTRAP.read_text(encoding="utf-8-sig")
    functions = "\n".join(
        _ps_function(text, name) for name in ("GetFfprobePathForFfmpeg", "TestFfmpegPair")
    )
    tools = tmp_path / "tools"
    tools.mkdir(parents=True)
    ffmpeg = tools / "ffmpeg.exe"
    ffprobe = tools / "ffprobe.exe"
    if scenario != "empty":
        ffmpeg.write_bytes(b"fixture")
    if scenario not in ("empty", "missing_ffprobe"):
        ffprobe.write_bytes(b"fixture")
    harness = tmp_path / "pair.ps1"
    harness.write_text(
        f"""
function RunHidden([string]$Path, [string[]]$Args, [string]$Description) {{
    if ('{scenario}' -eq 'invalid_ffmpeg' -and $Path -like '*ffmpeg.exe') {{ $global:LASTEXITCODE = 1 }}
    elseif ('{scenario}' -eq 'invalid_ffprobe' -and $Path -like '*ffprobe.exe') {{ $global:LASTEXITCODE = 1 }}
    else {{ $global:LASTEXITCODE = 0 }}
}}
{functions}
$pair = TestFfmpegPair '{'' if scenario == 'empty' else ffmpeg}'
'STATUS=' + $pair.Status
'REASON=' + $pair.Reason
""",
        encoding="utf-8",
    )
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-File", str(harness)],
        check=True,
        text=True,
        capture_output=True,
    )
    return dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)


def _run_download_failure_harness(tmp_path: Path) -> dict[str, str]:
    text = BOOTSTRAP.read_text(encoding="utf-8-sig")
    functions = "\n".join(
        _ps_function(text, name) for name in ("GetFfmpegDownloadFailure", "DownloadFfmpegArchive")
    )
    target = tmp_path / "ffmpeg.zip"
    harness = tmp_path / "download.ps1"
    harness.write_text(
        f"""
$script:Attempts = 0
function LogProgress([string]$Message) {{ }}
function LogLine([string]$Message) {{ }}
function TestFfmpegArchive([string]$Path) {{ return $false }}
function Start-Sleep {{ param([int]$Seconds) }}
function Invoke-WebRequest {{
    $script:Attempts++
    throw [System.Net.WebException]::new('timeout fixture', [System.Net.WebExceptionStatus]::Timeout)
}}
{functions}
$ok = DownloadFfmpegArchive 'https://example.invalid/ffmpeg.zip' '{target}'
'OK=' + $ok
'ATTEMPTS=' + $script:Attempts
'PARTIAL_EXISTS=' + (Test-Path '{target}.partial')
""",
        encoding="utf-8",
    )
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-File", str(harness)],
        check=True,
        text=True,
        capture_output=True,
    )
    return dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)


def test_invalid_ffmpeg_pair_never_writes_ready_marker(tmp_path: Path) -> None:
    assert _run_ready_harness(tmp_path, False) == {"MARKER_ABSENT": "yes"}


def test_valid_ffmpeg_pair_allows_ready_marker(tmp_path: Path) -> None:
    state = _run_ready_harness(tmp_path, True)
    assert state["READY_TO_GO_STATUS"] == "ok"
    assert state["MAIN_RUNTIME_STATUS"] == "ok"


def test_pair_validation_requires_both_executables_and_version_probes() -> None:
    text = BOOTSTRAP.read_text(encoding="utf-8-sig")
    function = _ps_function(text, "TestFfmpegPair")
    assert 'Reason = "ffmpeg_path_missing"' in function
    assert 'Reason = "ffmpeg_executable_missing"' in function
    assert 'Reason = "ffprobe_executable_missing"' in function
    assert 'Reason = "ffmpeg_validation_failed"' in function
    assert 'Reason = "ffprobe_validation_failed"' in function
    assert '@("-version")' in function


def test_pair_validation_behavioral_matrix(tmp_path: Path) -> None:
    assert _run_pair_harness(tmp_path / "empty", "empty") == {
        "STATUS": "missing_ffmpeg", "REASON": "ffmpeg_path_missing"
    }
    assert _run_pair_harness(tmp_path / "probe", "missing_ffprobe")["REASON"] == (
        "ffprobe_executable_missing"
    )
    assert _run_pair_harness(tmp_path / "bad_ffmpeg", "invalid_ffmpeg")["REASON"] == (
        "ffmpeg_validation_failed"
    )
    assert _run_pair_harness(tmp_path / "bad_ffprobe", "invalid_ffprobe")["REASON"] == (
        "ffprobe_validation_failed"
    )
    assert _run_pair_harness(tmp_path / "valid", "valid") == {
        "STATUS": "ok", "REASON": "ffmpeg_pair_valid"
    }


def test_transient_download_failure_retries_three_times_and_removes_partial(tmp_path: Path) -> None:
    assert _run_download_failure_harness(tmp_path) == {
        "OK": "False", "ATTEMPTS": "3", "PARTIAL_EXISTS": "False"
    }


def test_online_download_has_bounded_diagnostic_retry_contract() -> None:
    text = BOOTSTRAP.read_text(encoding="utf-8-sig")
    function = _ps_function(text, "DownloadFfmpegArchive")
    assert "$maxAttempts = 3" in function
    assert "FFMPEG_DOWNLOAD_ATTEMPT=" in function
    assert "FFMPEG_DOWNLOAD_FAILURE_CLASS=" in function
    assert "Remove-Item -Path $partialPath" in function
    assert "-TimeoutSec 120" in function
    assert "-MaximumRedirection 5" in function
    assert "TestFfmpegArchive" in function
    assert "Move-Item -Path $partialPath -Destination $TargetPath" in function


def test_online_mode_cannot_consume_stale_bundled_archive() -> None:
    bootstrap = BOOTSTRAP.read_text(encoding="utf-8-sig")
    installer = INSTALLER.read_text(encoding="utf-8-sig")
    iss = ISS.read_text(encoding="utf-8")
    assert '$bundledRuntimeMode = ($env:STEMWERK_BUNDLED_RUNTIME -eq "1")' in bootstrap
    assert "if ($bundledRuntimeMode -and (Test-Path $bundledFfmpegZip))" in bootstrap
    assert "[switch]$BundledRuntime" in installer
    assert '$env:STEMWERK_BUNDLED_RUNTIME = "1"' in installer
    assert "Result := Result + ' -BundledRuntime';" in iss


def test_current_ffmpeg_failure_blocks_stale_authoritative_success() -> None:
    text = SETUP.read_text(encoding="utf-8")
    assert 'local windowsFfmpegVerificationFailed = OS == "Windows"' in text
    assert 'verificationError == "ffmpeg_missing"' in text
    assert 'verificationError == "ffmpeg_unusable"' in text
    assert "and not windowsFfmpegVerificationFailed" in text
    assert 'state.STATUS_REASON = currentBootstrapFailureReason' in text
    assert "#errors == 0 or authoritativeRuntimeVerified" in text


def test_setup_checks_ffprobe_and_preserves_ffmpeg_failure_reason() -> None:
    text = SETUP.read_text(encoding="utf-8")
    assert "local function canRunFfmpegPair" in text
    assert 'ffmpeg_install_failed' in text
    assert 'ffprobe_executable_missing' in text
    assert 'ffprobe_validation_failed' in text
    assert 'STATUS = "missing_ffmpeg"' in text


def test_existing_release_contracts_remain_narrow() -> None:
    text = BOOTSTRAP.read_text(encoding="utf-8-sig").lower()
    assert '$torchaudioversion = "2.4.1"' in text
    assert "update-patch" not in text
    assert "build_offline" not in text
