#Requires -Version 5.1
<#
    Run-RealSeparationSmoke.ps1  (DEV-ONLY, not part of the tester ZIP)

    Runs the REAL production STEMwerk separation backend
    (scripts\reaper\audio_separator_process.py - the exact script REAPER's
    Lua actions invoke via os.execute/ExecProcess for "Normal Stems") on a
    short real stereo test file, through the currently-installed STEMwerk
    venv. This is stronger evidence than import checks or synthetic CUDA
    tensor ops: it proves a real htdemucs/htdemucs_ft inference pass
    completes end-to-end (model load, CUDA execution, stem writing) under
    whatever torch/CUDA stack is currently installed.

    Uses the harness's own Invoke-NativeProcess helper (the same PS 5.1-
    safe, non-corrupting native process invocation used by the harness
    itself) rather than raw PowerShell redirection, which is known to
    mangle stderr output under Windows PowerShell 5.1.
#>
param(
    [Parameter(Mandatory = $true)][string]$Model,
    [string]$Device = 'auto',
    [Parameter(Mandatory = $true)][string]$InputWav,
    [Parameter(Mandatory = $true)][string]$OutputDir,
    [int]$TimeoutSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HarnessRoot = Split-Path -Parent $ScriptRoot
$RepoRoot = Split-Path -Parent (Split-Path -Parent $HarnessRoot)
. (Join-Path $HarnessRoot 'lib\Invoke-NativeProcess.ps1')

$venvPython = "$env:LOCALAPPDATA\STEMwerk\.venv\Scripts\python.exe"
$processScript = Join-Path $RepoRoot 'scripts\reaper\audio_separator_process.py'

if (-not (Test-Path -LiteralPath $venvPython)) { throw "STEMwerk venv python not found: $venvPython" }
if (-not (Test-Path -LiteralPath $processScript)) { throw "audio_separator_process.py not found: $processScript" }
if (-not (Test-Path -LiteralPath $InputWav)) { throw "input wav not found: $InputWav" }

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

Write-Host "Running REAL separation: model=$Model device=$Device"
Write-Host "  script:    $processScript"
Write-Host "  input:     $InputWav"
Write-Host "  outputDir: $OutputDir"

$result = Invoke-NativeProcess -FilePath $venvPython -ArgumentList @($processScript, $InputWav, $OutputDir, '--model', $Model, '--device', $Device) -TimeoutSeconds $TimeoutSeconds

Set-Content -LiteralPath (Join-Path $OutputDir 'stdout.log') -Value $result.StdOut -Encoding UTF8
Set-Content -LiteralPath (Join-Path $OutputDir 'stderr.log') -Value $result.StdErr -Encoding UTF8

Write-Host ""
Write-Host "ExitCode: $($result.ExitCode)  Success: $($result.Success)  TimedOut: $($result.TimedOut)  Duration: $($result.DurationMs) ms"

$stems = Get-ChildItem -Path $OutputDir -Filter '*.wav' -ErrorAction SilentlyContinue
Write-Host "Stem files produced: $($stems.Count)"
foreach ($s in $stems) { Write-Host "  $($s.Name)  $($s.Length) bytes" }

if ($result.Success -and $stems.Count -gt 0) {
    Write-Host "RESULT: PASS - real separation completed and produced stem files" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "RESULT: FAIL" -ForegroundColor Red
    exit 1
}
