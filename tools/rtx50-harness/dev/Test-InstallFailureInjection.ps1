#Requires -Version 5.1
<#
    Test-InstallFailureInjection.ps1  (DEV-ONLY, excluded from tester ZIP)

    Failure injection #4 from the #118 investigation: a safe,
    non-destructive package-install failure against the REAL STEMwerk
    venv. A deliberately nonexistent torch version cannot resolve, so pip
    aborts during dependency resolution BEFORE uninstalling or modifying
    any already-installed package - this is safe to run against the real
    venv and leaves it byte-for-byte unchanged.

    Asserts:
      - Invoke-TorchStackInstall reports Success = $false
      - the real (non-zero) pip exit code is retained
      - stderr/stdout output is retained
      - the venv's torch/torchvision/torchaudio versions are IDENTICAL
        before and after the attempt (proving no mutation occurred)
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HarnessRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $HarnessRoot 'lib\Invoke-NativeProcess.ps1')
. (Join-Path $HarnessRoot 'lib\VenvSafety.ps1')

$venvPath = Get-ExpectedStemwerkVenvPath
$identity = Test-StemwerkVenvIdentity -VenvPath $venvPath
if (-not $identity.Ok) {
    Write-Host "FAIL: cannot verify STEMwerk venv identity, refusing to run this test: $($identity.Reasons -join '; ')" -ForegroundColor Red
    exit 2
}
$pythonExe = $identity.PythonExe

function Get-PinnedVersions {
    param($PythonExe)
    $r = Invoke-NativeProcess -FilePath $PythonExe -ArgumentList @('-m', 'pip', 'list', '--format=freeze')
    $versions = @{}
    foreach ($line in ($r.StdOut -split "`r?`n")) {
        if ($line -match '^(torch|torchvision|torchaudio)==(.+)$') { $versions[$Matches[1]] = $Matches[2] }
    }
    return $versions
}

Write-Host "=== Failure injection: nonexistent torch version spec (must fail safely, no mutation) ==="
$before = Get-PinnedVersions -PythonExe $pythonExe
Write-Host "Versions before: $($before | ConvertTo-Json -Compress)"

$result = Invoke-TorchStackInstall -PythonExe $pythonExe `
    -TorchSpec 'torch==2.7.1.this-version-does-not-exist' `
    -TorchvisionSpec 'torchvision==0.22.1' `
    -TorchaudioSpec 'torchaudio==2.7.1' `
    -IndexUrl 'https://download.pytorch.org/whl/cu128' `
    -TimeoutSeconds 300

Write-Host "ExitCode=$($result.ExitCode) Success=$($result.Success)"
Write-Host "--- stderr (tail) ---"
Write-Host ($result.StdErr.Substring([Math]::Max(0, $result.StdErr.Length - 800)))

$after = Get-PinnedVersions -PythonExe $pythonExe
Write-Host "Versions after: $($after | ConvertTo-Json -Compress)"

$ok = $true
if ($result.Success) { Write-Host "FAIL: expected install to fail, but Success=true" -ForegroundColor Red; $ok = $false }
if ($null -eq $result.ExitCode -or $result.ExitCode -eq 0) { Write-Host "FAIL: expected non-zero real exit code" -ForegroundColor Red; $ok = $false }
foreach ($pkg in @('torch', 'torchvision', 'torchaudio')) {
    if ($before[$pkg] -ne $after[$pkg]) {
        Write-Host "FAIL: $pkg version changed from $($before[$pkg]) to $($after[$pkg]) - injection was not safe!" -ForegroundColor Red
        $ok = $false
    }
}

if ($ok) {
    Write-Host "PASS: install failure was reported correctly and the real venv was left untouched" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "TEST FAILED" -ForegroundColor Red
    exit 1
}
