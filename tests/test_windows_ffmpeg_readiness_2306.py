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


# --- WinGet/shim resolver readiness contract (2.3.1.0) ---------------------
#
# Live evidence: a working WinGet-backed ffmpeg.exe (real, functional
# executable at ...\Microsoft\WinGet\Links\ffmpeg.exe) was unconditionally
# rejected as a "shim" purely by path text, before it was ever executed --
# so readiness reported ffmpeg_path_missing despite a fully working install.
# The fix makes IsFfmpegShim/isWindowsFfmpegShimPath reject only genuine
# WindowsApps App Execution Alias stubs (non-functional without a Store
# install) and lets every other candidate be decided by a real -version
# probe (TestFfmpegPair/canRunFfmpegPair). It also fixes two "try only the
# first candidate" bugs (Get-ChildItem -Recurse | Select -First 1, and
# Get-Command without -All) so an earlier invalid candidate no longer blocks
# a later valid one.

# Normalize-WindowsPath/Join-NormalizedWindowsPath are Windows-specific
# (they normalize to backslash paths), which is correct on a real Windows
# host but meaningless against a hermetic POSIX tmp_path on this Linux test
# runner -- Test-Path on a backslash-mangled path never finds anything here.
# Neither function is touched by this fix, so the harness below defines a
# POSIX-safe stand-in for Join-NormalizedWindowsPath instead of extracting
# the real one, so it can exercise ResolveWindowsFfmpegPath's *iteration*
# logic (the thing this fix actually changes) without depending on
# Windows-only path normalization.
_RESOLVE_DEPENDENCIES = (
    "GetFfprobePathForFfmpeg",
    "TestFfmpegPair",
    "IsFfmpegShim",
    "ResolveWindowsFfmpegPath",
)


def _make_pair(dir_path: Path, valid: bool = True) -> Path:
    dir_path.mkdir(parents=True, exist_ok=True)
    ffmpeg = dir_path / "ffmpeg.exe"
    ffmpeg.write_bytes(b"fixture")
    if valid:
        (dir_path / "ffprobe.exe").write_bytes(b"fixture")
    return ffmpeg


def _run_resolve_harness(
    tmp_path: Path,
    *,
    path_candidates: list[tuple[Path, bool]] = (),
    runtime_ffmpeg_dirs: list[tuple[str, bool]] = (),
    bad_exec_markers: list[str] = (),
) -> dict[str, str]:
    """path_candidates: [(ffmpeg.exe path, succeeds_at_minus_version)].
    runtime_ffmpeg_dirs: [(subdir name under $RuntimeBase/ffmpeg, succeeds)].
    bad_exec_markers additionally names any path substring RunHidden should
    fail for (used so a WinGet Links candidate can exist as real files but
    still fail its -version probe, proving IsFfmpegShim no longer rejects it
    by path alone -- TestFfmpegPair's real probe is what decides)."""
    text = BOOTSTRAP.read_text(encoding="utf-8-sig")
    functions = "\n".join(_ps_function(text, name) for name in _RESOLVE_DEPENDENCIES)

    runtime = tmp_path / "runtime"
    runtime.mkdir(parents=True, exist_ok=True)
    for name, succeeds in runtime_ffmpeg_dirs:
        _make_pair(runtime / "ffmpeg" / name, valid=succeeds)
        if not succeeds:
            bad_exec_markers = list(bad_exec_markers) + [str((runtime / "ffmpeg" / name / "ffmpeg.exe"))]

    path_cmd_lines = []
    for ffmpeg_path, succeeds in path_candidates:
        path_cmd_lines.append(f"[pscustomobject]@{{ Source = '{ffmpeg_path}' }}")
        if not succeeds:
            bad_exec_markers = list(bad_exec_markers) + [str(ffmpeg_path)]
    path_cmd_array = ", ".join(path_cmd_lines) if path_cmd_lines else "@()"

    bad_marker_ps = ", ".join(f"'{m}'" for m in bad_exec_markers)

    nonexistent = tmp_path / "does_not_exist"
    harness = tmp_path / "resolve.ps1"
    harness.write_text(
        f"""
$RuntimeBase = '{runtime}'
$localAppData = '{nonexistent / "lad"}'
$programFiles = '{nonexistent / "pf"}'
$programFilesX86 = '{nonexistent / "pf86"}'
$badExecMarkers = @({bad_marker_ps})
function LogProgress([string]$Message) {{ }}
function LogLine([string]$Message) {{ }}
function InstallFfmpegDirect {{ return $null }}
function Join-NormalizedWindowsPath([string]$BasePath, [string[]]$ChildParts) {{
    $current = $BasePath
    foreach ($child in $ChildParts) {{
        if (-not [string]::IsNullOrWhiteSpace($child)) {{ $current = Join-Path $current $child }}
    }}
    return $current
}}
function RunHidden([string]$File, [string[]]$Arguments, [string]$Description) {{
    $global:LASTEXITCODE = 0
    foreach ($marker in $badExecMarkers) {{
        if ($File -like ('*' + $marker)) {{ $global:LASTEXITCODE = 1 }}
    }}
}}
function Get-Command {{
    param([string]$Name, [switch]$All, [string]$ErrorAction)
    if ($Name -ne 'ffmpeg') {{ return $null }}
    return @({path_cmd_array})
}}
{functions}
$result = ResolveWindowsFfmpegPath
'RESULT=' + $(if ($result) {{ $result }} else {{ 'NULL' }})
'VALIDATED=' + $script:FfmpegValidated
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


def test_is_ffmpeg_shim_behavioral_matrix() -> None:
    text = BOOTSTRAP.read_text(encoding="utf-8-sig")
    function = _ps_function(text, "IsFfmpegShim")
    harness_lines = "\n".join(
        f"'{label}=' + (IsFfmpegShim '{path}')"
        for label, path in {
            "WINGET_LINKS": r"C:\Users\Administrator\AppData\Local\Microsoft\WinGet\Links\ffmpeg.exe",
            "WINGET_PACKAGES": r"C:\Users\Administrator\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_x\ffmpeg-8.1\bin\ffmpeg.exe",
            "WINDOWSAPPS": r"C:\Users\Administrator\AppData\Local\Microsoft\WindowsApps\ffmpeg.exe",
            "NORMAL": r"C:\ffmpeg\bin\ffmpeg.exe",
        }.items()
    )
    harness = f"{function}\n{harness_lines}\n"
    import tempfile

    with tempfile.NamedTemporaryFile(suffix=".ps1", mode="w", delete=False) as f:
        f.write(harness)
        path = f.name
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-File", path], check=True, text=True, capture_output=True
    )
    values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
    assert values["WINGET_LINKS"] == "False", "valid WinGet Links path must not be lexically rejected (A)"
    assert values["WINGET_PACKAGES"] == "False", "WinGet Packages install dir must not be lexically rejected"
    assert values["WINDOWSAPPS"] == "True", "WindowsApps App Execution Alias stub must stay rejected (D)"
    assert values["NORMAL"] == "False"


def test_resolver_accepts_valid_winget_links_pair(tmp_path: Path) -> None:
    """A: valid WinGet\\Links-backed ffmpeg + sibling ffprobe => PASS."""
    winget = tmp_path / "Microsoft" / "WinGet" / "Links"
    ffmpeg = _make_pair(winget, valid=True)
    state = _run_resolve_harness(tmp_path, path_candidates=[(ffmpeg, True)])
    assert state["RESULT"] == str(ffmpeg)
    assert state["VALIDATED"] == "True"


def test_resolver_skips_invalid_winget_candidate_and_uses_later_valid_path(tmp_path: Path) -> None:
    """B: WinGet candidate invalid, later PATH candidate valid => PASS."""
    winget_ffmpeg = _make_pair(tmp_path / "WinGet" / "Links", valid=True)
    real_ffmpeg = _make_pair(tmp_path / "RealFfmpeg" / "bin", valid=True)
    state = _run_resolve_harness(
        tmp_path,
        path_candidates=[(winget_ffmpeg, False), (real_ffmpeg, True)],
    )
    assert state["RESULT"] == str(real_ffmpeg)


def test_resolver_recursive_runtime_discovery_does_not_stop_at_first_invalid_candidate(
    tmp_path: Path,
) -> None:
    """C: first recursively discovered runtime candidate invalid, later one valid => PASS.
    Filesystem enumeration order for Get-ChildItem -Recurse is not guaranteed,
    so this behavioral run alone can pass "by luck" even against the old
    Select-Object -First 1 bug if the valid candidate happens to enumerate
    first. The deterministic proof is the companion source assertion below;
    this run additionally proves the fixed code actually finds the valid
    candidate end-to-end regardless of which one enumerates first."""
    state = _run_resolve_harness(
        tmp_path,
        runtime_ffmpeg_dirs=[("a_legacy_broken", False), ("z_current_working", True)],
    )
    assert state["RESULT"] != "NULL"
    assert "z_current_working" in state["RESULT"] and state["RESULT"].endswith("ffmpeg.exe")


def test_resolver_runtime_discovery_tries_all_candidates_not_just_first() -> None:
    """C (deterministic): the recursive runtime-ffmpeg discovery must iterate
    every Get-ChildItem match via a foreach/continue loop, not grab a single
    result with Select-Object -First 1 and give up if it is invalid."""
    text = BOOTSTRAP.read_text(encoding="utf-8-sig")
    function = _ps_function(text, "ResolveWindowsFfmpegPath")
    assert "Select-Object -First 1" not in function
    assert "foreach ($runtimeFfmpeg in $runtimeFfmpegCandidates)" in function
    assert "Get-Command ffmpeg -All -ErrorAction SilentlyContinue" in function


def test_resolver_rejects_windowsapps_only_even_when_executable_would_succeed(tmp_path: Path) -> None:
    """D: WindowsApps/shim-only => FAIL, even though the RunHidden stub is
    configured to let every executable "succeed" -- proves the rejection
    happens by classification, never reaching the probe."""
    stub = tmp_path / "WindowsApps" / "ffmpeg.exe"
    stub.parent.mkdir(parents=True, exist_ok=True)
    stub.write_bytes(b"fixture")
    (stub.parent / "ffprobe.exe").write_bytes(b"fixture")
    state = _run_resolve_harness(tmp_path, path_candidates=[(stub, True)])
    assert state["RESULT"] == "NULL"


def test_resolver_rejects_ffmpeg_without_sibling_ffprobe(tmp_path: Path) -> None:
    """E: ffmpeg valid, ffprobe absent => FAIL (resolver-level; TestFfmpegPair's
    own matrix already covers this at the pair-validation level)."""
    lonely = tmp_path / "lonely"
    lonely.mkdir()
    ffmpeg = lonely / "ffmpeg.exe"
    ffmpeg.write_bytes(b"fixture")
    state = _run_resolve_harness(tmp_path, path_candidates=[(ffmpeg, True)])
    assert state["RESULT"] == "NULL"


def test_check_only_call_graph_has_no_reachable_allowinstall(tmp_path: Path) -> None:
    """H/I: RunReadyToGoVerifyOnly's full reachable call graph (including the
    CUDA/DirectML verify helpers it calls transitively through
    VerifyExistingReadyRuntime) must never pass an unconditional
    -AllowInstall to ResolveWindowsFfmpegPath. `-AllowInstall:$AllowInstall`
    is a safe conditional passthrough that defaults to $false and is
    allowed; a bare `-AllowInstall` is not."""
    text = BOOTSTRAP.read_text(encoding="utf-8-sig")
    reachable = (
        "RunReadyToGoVerifyOnly",
        "VerifyExistingReadyRuntime",
        "VerifyDrumsepRuntime",
        "VerifyDrumsepCudaRuntime",
        "VerifyDrumsepDirectmlRuntime",
        "ProbeMainRuntimeReady",
        "GetReadyToGoRuntimeState",
    )
    import re

    bare_allowinstall = re.compile(r"-AllowInstall(?!:)")
    for name in reachable:
        body = _ps_function(text, name)
        matches = bare_allowinstall.findall(body)
        assert not matches, f"{name} contains an unconditional -AllowInstall: {matches}"


def test_mutating_drumsep_install_paths_still_pass_allowinstall_explicitly() -> None:
    """J: mutating Repair/Setup Install* functions must still be able to
    install FFmpeg when explicitly permitted -- the conditional passthrough
    must actually be invoked with $AllowInstall=$true from those callers,
    not silently dropped."""
    text = BOOTSTRAP.read_text(encoding="utf-8-sig")
    install_directml = _ps_function(text, "InstallDrumsepDirectmlRuntime")
    install_cuda = _ps_function(text, "InstallDrumsepCudaRuntime")
    assert "VerifyDrumsepDirectmlRuntime $drumsepPython -AllowInstall" in install_directml
    assert install_directml.count("VerifyDrumsepDirectmlRuntime $drumsepPython -AllowInstall") == 2
    assert "VerifyDrumsepCudaRuntime $drumsepPython -AllowInstall" in install_cuda
    assert install_cuda.count("VerifyDrumsepCudaRuntime $drumsepPython -AllowInstall") == 2
    # The top-level mutating bootstrap flow (Mode=repair/drumsep-runtime,
    # not ready-to-go-verify) must still fall back to a real install.
    assert "$ffmpeg = ResolveWindowsFfmpegPath -AllowInstall" in text


def test_lua_explicit_ffmpeg_override_outranks_persisted_bootstrap_state() -> None:
    """G (Lua Check side): an explicit/current user-selected FFmpeg path
    (ExtState) must be considered before stale persisted bootstrap.env
    state, not after -- both are still re-validated live via
    isValidFfmpegPath regardless of order. NOTE: PowerShell ready-to-go
    verification (RunReadyToGoVerifyOnly) has no existing parameter/state
    handoff to receive this Lua-side ExtState value at all, so this ordering
    fix only changes Lua "Check"; it does not make ready-to-go consume an
    explicit override (no such plumbing exists in this codebase today)."""
    text = SETUP.read_text(encoding="utf-8")
    start = text.index('if step == 3 then')
    end = text.index("if step == 4 then", start)
    block = text[start:end]
    ext_idx = block.index('local extPath = resolvePath(getExt("ffmpegPath"))')
    state_idx = block.index('local statePath = resolvePath(state.FFMPEG_PATH or "")')
    assert ext_idx < state_idx, "explicit ExtState override must be considered before persisted bootstrap.env state"


def test_lua_persisted_ffmpeg_path_falls_through_when_deleted() -> None:
    """F: a stored/persisted FFmpeg path that no longer exists on disk must
    fall through to later candidates, not be treated as success. This is an
    existing invariant (isValidFfmpegPath requires fileExists) that the
    reordering fix above must not weaken."""
    text = SETUP.read_text(encoding="utf-8")
    assert (
        'local function isValidFfmpegPath(path)\n'
        '    if path == "" or not fileExists(path) or isWindowsFfmpegShimPath(path) then return false end'
    ) in text
