from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WINDOWS_DIR = ROOT / "installer" / "windows"
ISS = WINDOWS_DIR / "STEMwerk.iss"
PAYLOAD_ISS = WINDOWS_DIR / "STEMwerk_Windows_Payload.iss"
BOOTSTRAP = ROOT / "scripts" / "reaper" / "STEMwerk_Bootstrap_Windows.ps1"
LICENSE = WINDOWS_DIR / "STEMwerk_License_Agreement.txt"

SOURCE_RE = re.compile(
    r'^Source: "(?P<source>[^"]+)"; DestDir: "(?P<dest>[^"]+)";',
    re.MULTILINE,
)


def _extract_powershell_function(text: str, name: str) -> str:
    start = text.index(f"function {name}")
    brace = text.index("{", start)
    depth = 0
    in_single = False
    in_double = False
    for index in range(brace, len(text)):
        char = text[index]
        previous = text[index - 1] if index else ""
        if char == "'" and not in_double and previous != "`":
            in_single = not in_single
        elif char == '"' and not in_single and previous != "`":
            in_double = not in_double
        elif not in_single and not in_double:
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    return text[start : index + 1]
    raise AssertionError(f"unterminated PowerShell function: {name}")


def _run_policy_harness(tmp_path: Path, effective: str, list_throws: bool) -> list[str]:
    function = _extract_powershell_function(
        BOOTSTRAP.read_text(encoding="utf-8-sig"), "LogExecutionPolicyStatus"
    )
    list_behavior = (
        'throw "scope probe unavailable"'
        if list_throws
        else "return @([pscustomobject]@{Scope='Process'; ExecutionPolicy='Undefined'})"
    )
    harness = tmp_path / "policy-harness.ps1"
    harness.write_text(
        f"""
$script:Events = [System.Collections.Generic.List[string]]::new()
function LogProgress([string]$Message) {{ $script:Events.Add('PROGRESS=' + $Message) }}
function LogLine([string]$Message) {{ $script:Events.Add('LOG=' + $Message) }}
function LogStatusDetail([string]$Message) {{ $script:Events.Add('DETAIL=' + $Message) }}
function Set-Status([string]$State, [string]$Reason) {{ $script:Events.Add('STATUS=' + $State + ':' + $Reason) }}
function Get-ExecutionPolicy {{
  param([switch]$List)
  if ($List) {{ {list_behavior} }}
  return '{effective}'
}}
{function}
LogExecutionPolicyStatus
$script:Events
""",
        encoding="utf-8",
    )
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-File", str(harness)],
        check=True,
        text=True,
        capture_output=True,
    )
    return result.stdout.splitlines()


def _current_payload_names() -> set[str]:
    mappings = SOURCE_RE.finditer(PAYLOAD_ISS.read_text(encoding="utf-8"))
    return {match["source"].rsplit("\\", 1)[-1] for match in mappings}


def _simulate_owned_root_upgrade(root: Path, bundled: bool) -> None:
    # Mirrors the installer contract: clear only the fully STEMwerk-owned app root,
    # then stage the current manifest. Runtime/models live outside this root.
    for child in root.iterdir():
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()
    for name in _current_payload_names():
        (root / name).write_text("current", encoding="utf-8")
    if bundled:
        bundled_root = root / "_bundled"
        (bundled_root / "python").mkdir(parents=True)
        (bundled_root / "ffmpeg").mkdir(parents=True)
        (bundled_root / "python" / "python-3.11.8-amd64.exe").write_bytes(b"python")
        (bundled_root / "ffmpeg" / "ffmpeg-release-essentials.zip").write_bytes(b"ffmpeg")


def test_installer_replaces_only_the_owned_application_root() -> None:
    text = ISS.read_text(encoding="utf-8")
    assert "[InstallDelete]" in text
    assert 'Type: filesandordirs; Name: "{app}\\*"' in text
    assert 'Type: filesandordirs; Name: "{userappdata}\\REAPER\\Scripts\\*"' not in text
    assert 'Type: filesandordirs; Name: "{localappdata}\\STEMwerk"' not in text.split(
        "[InstallDelete]", 1
    )[1].split("[", 1)[0]


def test_online_upgrade_removes_legacy_platform_files_and_stale_bundle(tmp_path: Path) -> None:
    app = tmp_path / "REAPER" / "Scripts" / "STEMwerk-reaper"
    app.mkdir(parents=True)
    for stale in (
        "STEMwerk_Bootstrap_Linux.sh",
        "STEMwerk_Bootstrap_Linux_Launcher.sh",
        "STEMwerk_Bootstrap_macOS.sh",
    ):
        (app / stale).write_text("legacy", encoding="utf-8")
    (app / "_bundled" / "ffmpeg").mkdir(parents=True)
    (app / "_bundled" / "ffmpeg" / "ffmpeg-release-essentials.zip").write_bytes(b"old")

    _simulate_owned_root_upgrade(app, bundled=False)

    assert not (app / "STEMwerk_Bootstrap_Linux.sh").exists()
    assert not (app / "STEMwerk_Bootstrap_Linux_Launcher.sh").exists()
    assert not (app / "STEMwerk_Bootstrap_macOS.sh").exists()
    assert not (app / "_bundled").exists()
    assert (app / "STEMwerk_Bootstrap_Windows.ps1").exists()


def test_bundled_upgrade_replaces_the_old_bundle(tmp_path: Path) -> None:
    app = tmp_path / "REAPER" / "Scripts" / "STEMwerk-reaper"
    (app / "_bundled" / "obsolete").mkdir(parents=True)
    (app / "_bundled" / "obsolete" / "2.3.0.4.txt").write_text("old", encoding="utf-8")

    _simulate_owned_root_upgrade(app, bundled=True)

    assert not (app / "_bundled" / "obsolete").exists()
    assert (app / "_bundled" / "python" / "python-3.11.8-amd64.exe").is_file()
    assert (app / "_bundled" / "ffmpeg" / "ffmpeg-release-essentials.zip").is_file()


def test_runtime_and_model_cache_are_outside_owned_application_cleanup(tmp_path: Path) -> None:
    app = tmp_path / "AppData" / "Roaming" / "REAPER" / "Scripts" / "STEMwerk-reaper"
    models = tmp_path / "AppData" / "Local" / "STEMwerk" / "models"
    app.mkdir(parents=True)
    models.mkdir(parents=True)
    checkpoint = models / "cached-model.ckpt"
    checkpoint.write_bytes(b"preserve-me")

    _simulate_owned_root_upgrade(app, bundled=False)

    assert checkpoint.read_bytes() == b"preserve-me"


def test_clean_runtime_remains_opt_in_and_models_require_their_own_option() -> None:
    text = ISS.read_text(encoding="utf-8")
    assert 'Name: "cleanup_runtime"' in text
    assert 'Name: "cleanup_models"' in text
    assert "if WizardIsTaskSelected('cleanup_runtime') then" in text
    assert "Result := Result + ' -CleanRuntime'" in text
    assert "if WizardIsTaskSelected('cleanup_models') then" in text
    assert "Result := Result + ' -CleanModels'" in text


def test_online_bootstrap_uses_download_when_no_current_bundle_exists() -> None:
    text = BOOTSTRAP.read_text(encoding="utf-8-sig")
    assert '$bundledFfmpegZip = Join-NormalizedWindowsPath $bundledRuntimeDir' in text
    assert 'if ($bundledRuntimeMode -and (Test-Path $bundledFfmpegZip))' in text
    assert '} elseif ($bundledRuntimeMode) {' in text
    assert 'LogProgress "FFMPEG_SOURCE=download"' in text


def test_effective_bypass_remains_success_when_scope_list_probe_fails(tmp_path: Path) -> None:
    events = _run_policy_harness(tmp_path, "Bypass", list_throws=True)
    assert "PROGRESS=PowerShell execution policy (effective): Bypass" in events
    assert "PROGRESS=EXECUTION_POLICY_STATUS=ok" in events
    assert not [event for event in events if event.startswith("STATUS=failed")]
    assert "LOG=Execution policy check failed" not in events


def test_genuinely_blocking_policy_fails_closed(tmp_path: Path) -> None:
    events = _run_policy_harness(tmp_path, "Restricted", list_throws=False)
    assert "PROGRESS=EXECUTION_POLICY_STATUS=failed" in events
    assert "STATUS=failed:execution_policy_restricted" in events
    assert any("PowerShell policy is restrictive (Restricted)" in event for event in events)


def test_installer_date_is_compile_time_metadata_not_a_stale_license_literal() -> None:
    iss_text = ISS.read_text(encoding="utf-8")
    license_text = LICENSE.read_text(encoding="utf-8")
    assert "GetDateTimeString('yyyy-mm-dd'" in iss_text
    assert "VersionInfoDescription=" in iss_text
    assert "{#MyBuildDate}" in iss_text
    assert not re.search(r"(?m)^Date: 2026-07-11$", license_text)


def test_upgrade_contract_keeps_windows_payload_allowlist_narrow() -> None:
    text = PAYLOAD_ISS.read_text(encoding="utf-8").lower()
    assert "stemwerk_bootstrap_windows.ps1" in text
    assert "stemwerk_bootstrap_linux" not in text
    assert "stemwerk_bootstrap_macos" not in text
    assert "update-patch" not in text
    assert "allmodels" not in text
