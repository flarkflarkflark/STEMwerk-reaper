#Requires -Version 5.1
<#
    Test-Heartbeat.ps1  (DEV-ONLY, excluded from tester ZIP)

    Regression test for the v2 heartbeat feature (spec section 7): a long-
    running native process must produce periodic heartbeat output instead
    of looking hung, and must still report the correct exit code and
    captured stdout/stderr afterward. Uses a short (12s) sleep instead of
    a real pip install so this runs quickly.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HarnessRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $HarnessRoot 'lib\Invoke-NativeProcess.ps1')

$pythonExe = "$env:LOCALAPPDATA\STEMwerk\.venv\Scripts\python.exe"
if (-not (Test-Path -LiteralPath $pythonExe)) { $pythonExe = 'python' }

$heartbeats = New-Object System.Collections.Generic.List[int]
$action = { param($s) $Script:heartbeats.Add($s) | Out-Null; Write-Host "  heartbeat at ${s}s" }
# Scriptblocks passed as -HeartbeatAction run in their own scope; capture
# via a script-scoped list instead of a closure variable.
$Script:heartbeats = $heartbeats

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$r = Invoke-NativeProcess -FilePath $pythonExe -ArgumentList @((Join-Path $ScriptRoot 'sleep_a_bit.py'), '12') -HeartbeatSeconds 3 -HeartbeatAction $action
$sw.Stop()

Write-Host "ExitCode=$($r.ExitCode) Success=$($r.Success) DurationMs=$($r.DurationMs)"
Write-Host "Heartbeats observed: $($Script:heartbeats.Count) at $($Script:heartbeats -join ', ')s"

$ok = $true
if (-not $r.Success -or $r.ExitCode -ne 0) { Write-Host "FAIL: expected success/exit 0" -ForegroundColor Red; $ok = $false }
if ($r.StdOut -notmatch 'done sleeping') { Write-Host "FAIL: expected stdout to be captured correctly" -ForegroundColor Red; $ok = $false }
if ($Script:heartbeats.Count -lt 2) { Write-Host "FAIL: expected at least 2 heartbeats during a 12s sleep with a 3s interval, got $($Script:heartbeats.Count)" -ForegroundColor Red; $ok = $false }
if ($sw.Elapsed.TotalSeconds -lt 10) { Write-Host "FAIL: process returned suspiciously fast for a 12s sleep" -ForegroundColor Red; $ok = $false }

if ($ok) {
    Write-Host "PASS: heartbeat fired during the long operation, exit code and stdout were still captured correctly" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "TEST FAILED" -ForegroundColor Red
    exit 1
}
