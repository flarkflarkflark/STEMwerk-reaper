#Requires -Version 5.1
<#
    Test-MixedNoBaseline.ps1  (DEV-ONLY, excluded from tester ZIP)

    Scenario C (spec section 12): a mixed torch stack with NO trusted
    transaction baseline on record at all (e.g. a v1 tester was used
    previously, or the transaction file was lost). Reproduces this for
    real: creates the mixed state WITHOUT ever writing a transaction
    record first, then runs the real public tester with -Yes (so it takes
    the documented-release-fallback recovery path automatically, since
    corroboration should succeed on this genuine STEMwerk install) and
    confirms it recovers to the exact original baseline rather than
    inventing/guessing anything else.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HarnessRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $HarnessRoot 'lib\Invoke-NativeProcess.ps1')
. (Join-Path $HarnessRoot 'lib\VenvSafety.ps1')
. (Join-Path $HarnessRoot 'lib\RuntimeState.ps1')

$venvPath = Get-ExpectedStemwerkVenvPath
$identity = Test-StemwerkVenvIdentity -VenvPath $venvPath
if (-not $identity.Ok) {
    Write-Host "FAIL: cannot verify STEMwerk venv identity: $($identity.Reasons -join '; ')" -ForegroundColor Red
    exit 2
}
$venvPython = $identity.PythonExe

function Show-Trio {
    param([string]$Label)
    $trio = Get-InstalledTorchTrio -PythonExe $venvPython
    Write-Host "${Label}: torch=$($trio.Packages['torch']) torchvision=$($trio.Packages['torchvision']) torchaudio=$($trio.Packages['torchaudio'])"
    return $trio
}

Write-Host "=== Step 1: require exact coherent RELEASE_BASELINE, and no pre-existing transaction record ==="
$before = Show-Trio -Label 'Before test'
if ((Get-RuntimeCoherenceState -InstalledTrio $before) -ne 'RELEASE_BASELINE') {
    Write-Host "FAIL: venv is not at the exact coherent release baseline. Refusing to run this test." -ForegroundColor Red
    exit 2
}
if ((Read-TransactionState).Exists) {
    Write-Host "Clearing a pre-existing transaction record so this test starts from a genuinely 'no baseline on record' state."
    Clear-TransactionState
}
Write-Host "PASS: starting from coherent baseline with no transaction record" -ForegroundColor Green

Write-Host ""
Write-Host "=== Step 2: create a mixed state WITHOUT ever recording a transaction/baseline ==="
$torchOnly = Invoke-NativeProcess -FilePath $venvPython -ArgumentList @('-m', 'pip', 'install', '--index-url', 'https://download.pytorch.org/whl/cu128', 'torch==2.7.1') -TimeoutSeconds 1800 -HeartbeatSeconds 20 -HeartbeatAction { param($s) Write-Host "  ... still installing ($s s elapsed)" }
if (-not $torchOnly.Success) {
    Write-Host "FAIL: could not reproduce the mixed state" -ForegroundColor Red
    exit 2
}
$mixed = Show-Trio -Label 'After creating mixed state'
if ((Get-RuntimeCoherenceState -InstalledTrio $mixed) -ne 'MIXED_OR_UNKNOWN') {
    Write-Host "FAIL: expected MIXED_OR_UNKNOWN" -ForegroundColor Red
    exit 1
}
if ((Read-TransactionState).Exists) {
    Write-Host "FAIL: a transaction record unexpectedly exists - this test requires none" -ForegroundColor Red
    exit 2
}
Write-Host "PASS: reproduced a mixed state with confirmed NO transaction record on disk" -ForegroundColor Green

Write-Host ""
Write-Host "=== Step 3: run the REAL public tester with -Yes (auto-accepts the assumed-recovery prompt) ==="
$testerScript = Join-Path $HarnessRoot 'STEMwerk-RTX50-cu128-test.ps1'
$run = Invoke-NativeProcess -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $testerScript, '-Yes') -TimeoutSeconds 900
Write-Host "Tester exit code: $($run.ExitCode)"

$reportPath = $null
if ($run.StdOut -match 'Report:\s*(.+\.md)') { $reportPath = $Matches[1].Trim() }

Write-Host ""
Write-Host "=== Step 4: verify recovery ==="
$after = Show-Trio -Label 'After tester run'
$ok = $true
if ($run.ExitCode -ne 0) { Write-Host "FAIL: expected exit 0, got $($run.ExitCode)" -ForegroundColor Red; $ok = $false }
if ($reportPath -and (Test-Path -LiteralPath $reportPath)) {
    $reportText = Get-Content -LiteralPath $reportPath -Raw
    if ($reportText -notmatch '(?i)no trusted baseline') {
        Write-Host "FAIL: expected the report to document the no-trusted-baseline / documented-release-fallback path" -ForegroundColor Red
        $ok = $false
    }
    else {
        Write-Host "Confirmed: report documents the no-trusted-baseline recovery path."
    }
}
else {
    Write-Host "FAIL: could not find report to check" -ForegroundColor Red; $ok = $false
}
foreach ($pkg in @('torch', 'torchvision', 'torchaudio')) {
    if ($after.Packages[$pkg] -ne $before.Packages[$pkg]) {
        Write-Host "FAIL: $pkg ended at $($after.Packages[$pkg]), expected original $($before.Packages[$pkg])" -ForegroundColor Red
        $ok = $false
    }
}

if ($ok) {
    Write-Host ""
    Write-Host "PASS: mixed state with no trusted baseline was correctly recovered via the documented-release fallback." -ForegroundColor Green
    exit 0
}
else {
    Write-Host ""
    Write-Host "TEST FAILED - verify machine state manually." -ForegroundColor Red
    exit 1
}
