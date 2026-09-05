#Requires -Version 5.1
<#
    Test-NativeProcess.ps1  (DEV-ONLY, excluded from the tester ZIP)

    MANDATORY regression test for STEMwerk #118 harness failure #2: the
    Windows PowerShell 5.1 NativeCommandError that aborted the harness
    when a Python/PyTorch UserWarning appeared on stderr, even though the
    process exited 0.

    Runs the SAME Invoke-NativeProcess helper the real harness uses
    (lib\Invoke-NativeProcess.ps1) against two fixtures:

      1. dev\warn_exit0.py       - stdout output + UserWarning on stderr,
                                    exits 0. MUST be treated as SUCCESS,
                                    with both stdout and the warning text
                                    retained.
      2. dev\err_exit_nonzero.py - stderr output, exits 7. MUST be treated
                                    as FAILURE, with stderr and the real
                                    exit code (7) retained.

    Exits 0 if both assertions pass, 1 otherwise. Prints a PASS/FAIL line
    per assertion.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HarnessRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $HarnessRoot 'lib\Invoke-NativeProcess.ps1')

# Use the same python that runs the real harness's probes: prefer the
# STEMwerk venv python if present, else whatever python is on PATH.
$pythonExe = "$env:LOCALAPPDATA\STEMwerk\.venv\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $pythonExe)) {
    $pythonExe = 'python'
}

$failures = 0

Write-Host "=== Test 1: UserWarning on stderr + exit 0 must be SUCCESS ==="
$r1 = Invoke-NativeProcess -FilePath $pythonExe -ArgumentList @((Join-Path $ScriptRoot 'warn_exit0.py'))
Write-Host "ExitCode=$($r1.ExitCode) Success=$($r1.Success) TimedOut=$($r1.TimedOut)"
Write-Host "--- stdout ---"
Write-Host $r1.StdOut
Write-Host "--- stderr ---"
Write-Host $r1.StdErr

$t1ok = $true
if ($r1.LaunchException) { Write-Host "FAIL: unexpected PowerShell launch exception: $($r1.LaunchException)" -ForegroundColor Red; $t1ok = $false }
if ($r1.ExitCode -ne 0) { Write-Host "FAIL: expected exit code 0, got $($r1.ExitCode)" -ForegroundColor Red; $t1ok = $false }
if (-not $r1.Success) { Write-Host "FAIL: expected Success=true" -ForegroundColor Red; $t1ok = $false }
if ($r1.StdOut -notmatch 'useful stdout output before the warning') { Write-Host "FAIL: stdout before warning missing" -ForegroundColor Red; $t1ok = $false }
if ($r1.StdOut -notmatch 'useful stdout output after the warning') { Write-Host "FAIL: stdout after warning missing" -ForegroundColor Red; $t1ok = $false }
if ($r1.StdErr -notmatch 'UserWarning') { Write-Host "FAIL: expected UserWarning text retained in stderr" -ForegroundColor Red; $t1ok = $false }
if ($t1ok) { Write-Host "PASS: Test 1" -ForegroundColor Green } else { $failures++ }

Write-Host ""
Write-Host "=== Test 2: stderr output + non-zero exit must be FAILURE ==="
$r2 = Invoke-NativeProcess -FilePath $pythonExe -ArgumentList @((Join-Path $ScriptRoot 'err_exit_nonzero.py'))
Write-Host "ExitCode=$($r2.ExitCode) Success=$($r2.Success) TimedOut=$($r2.TimedOut)"
Write-Host "--- stderr ---"
Write-Host $r2.StdErr

$t2ok = $true
if ($r2.LaunchException) { Write-Host "FAIL: unexpected PowerShell launch exception: $($r2.LaunchException)" -ForegroundColor Red; $t2ok = $false }
if ($r2.ExitCode -ne 7) { Write-Host "FAIL: expected exit code 7, got $($r2.ExitCode)" -ForegroundColor Red; $t2ok = $false }
if ($r2.Success) { Write-Host "FAIL: expected Success=false" -ForegroundColor Red; $t2ok = $false }
if ($r2.StdErr -notmatch 'about to fail') { Write-Host "FAIL: expected stderr text retained" -ForegroundColor Red; $t2ok = $false }
if ($t2ok) { Write-Host "PASS: Test 2" -ForegroundColor Green } else { $failures++ }

Write-Host ""
if ($failures -eq 0) {
    Write-Host "ALL NATIVE PROCESS REGRESSION TESTS PASSED" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "$failures TEST(S) FAILED" -ForegroundColor Red
    exit 1
}
