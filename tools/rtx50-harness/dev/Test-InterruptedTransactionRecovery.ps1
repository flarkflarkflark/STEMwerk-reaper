#Requires -Version 5.1
<#
    Test-InterruptedTransactionRecovery.ps1  (DEV-ONLY, excluded from tester ZIP)

    THE key #118 v2 acceptance test (spec section 13's final bullet /
    section 12 Scenario B). Reproduces, for real, the exact mixed state a
    real RTX 5070 tester (pan-athen) hit when his first run appeared to
    hang during pip install and was killed after ~10 minutes:

        torch 2.7.1+cu128, torchvision 0.19.1+cu121, torchaudio 2.4.1+cu121

    Steps:
      1. Require the venv to currently be the exact coherent
         RELEASE_BASELINE (refuses to run otherwise - this test must start
         from a known-good state).
      2. Manually capture+persist a trusted baseline transaction record,
         exactly as the real harness would at the start of a real run, and
         advance it to TORCH_INSTALL_IN_PROGRESS.
      3. Upgrade ONLY torch (not torchvision/torchaudio) to reproduce the
         exact mixed trio above - simulating "the process was killed after
         torch was replaced but before torchvision/torchaudio were".
      4. Run the REAL PUBLIC tester script (STEMwerk-RTX50-cu128-test.ps1)
         exactly as a real user would (with -Yes for non-interactivity).
      5. Assert it:
           - detects MIXED_OR_UNKNOWN
           - detects and reports an INTERRUPTED TRANSACTION
           - recovers using the REAL saved baseline (never the mixed
             state, never a value made up from what was currently
             installed)
           - ends with the exact original coherent RELEASE_BASELINE,
             independently re-verified by this test
           - clears the transaction record on verified success

    This test performs real pip operations on the real STEMwerk venv, as
    explicitly instructed - it is not safe to run outside that dedicated
    venv, and this script verifies venv identity before doing anything.
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
    Write-Host "FAIL: cannot verify STEMwerk venv identity, refusing to run this test: $($identity.Reasons -join '; ')" -ForegroundColor Red
    exit 2
}
$venvPython = $identity.PythonExe

function Show-Trio {
    param([string]$Label)
    $trio = Get-InstalledTorchTrio -PythonExe $venvPython
    Write-Host "${Label}: torch=$($trio.Packages['torch']) torchvision=$($trio.Packages['torchvision']) torchaudio=$($trio.Packages['torchaudio'])"
    return $trio
}

Write-Host "=== Step 1: require exact coherent RELEASE_BASELINE before starting ==="
$before = Show-Trio -Label 'Before test'
$beforeCoherence = Get-RuntimeCoherenceState -InstalledTrio $before
if ($beforeCoherence -ne 'RELEASE_BASELINE') {
    Write-Host "FAIL: venv is not at the exact coherent release baseline (classified as $beforeCoherence). Refusing to run this test - it must start from a known-good state." -ForegroundColor Red
    exit 2
}
Write-Host "PASS: confirmed exact coherent RELEASE_BASELINE" -ForegroundColor Green

Write-Host ""
Write-Host "=== Step 2: manually capture+persist a trusted baseline, as a real run would ==="
$baseline = ConvertTo-BaselineObject -InstalledTrio $before
$tx = New-TransactionRecord -Phase 'BASELINE_CAPTURED' -Baseline $baseline -Target (Get-KnownTrio 'EXPERIMENTAL_CU128') -ReportPath ''
Write-TransactionStateAtomic -Record $tx
$tx = Set-TransactionPhase -Record $tx -NewPhase 'MUTATION_STARTED' -Note 'test: simulating a real run about to mutate'
$tx = Set-TransactionPhase -Record $tx -NewPhase 'TORCH_INSTALL_IN_PROGRESS' -Note 'test: simulating the pip install actually starting'
Write-Host "Transaction record written at $(Get-TransactionStatePath), phase=$($tx.phase)"

Write-Host ""
Write-Host "=== Step 3: upgrade ONLY torch, reproducing pan-athen's exact observed mixed state ==="
# Deliberately does NOT go through Invoke-TorchStackInstall (which always
# installs all three from the same index) - this reproduces exactly what
# a killed-mid-install pip run leaves behind: torch already replaced from
# the cu128 index, torchvision/torchaudio untouched at their old cu121
# versions (pip installs the packages named on its command line in turn;
# a kill between the first and later ones is exactly pan-athen's report).
$torchOnly = Invoke-NativeProcess -FilePath $venvPython -ArgumentList @('-m', 'pip', 'install', '--index-url', 'https://download.pytorch.org/whl/cu128', 'torch==2.7.1') -TimeoutSeconds 1800 -HeartbeatSeconds 20 -HeartbeatAction { param($s) Write-Host "  ... still installing torch-only ($s s elapsed)" }
if (-not $torchOnly.Success) {
    Write-Host "FAIL: could not even reproduce the mixed state (torch-only install failed). Aborting test; attempting cleanup rollback." -ForegroundColor Red
    Clear-TransactionState
    exit 2
}
$mixed = Show-Trio -Label 'After simulated interruption'
$mixedCoherence = Get-RuntimeCoherenceState -InstalledTrio $mixed
Write-Host "Classified as: $mixedCoherence"
if ($mixedCoherence -ne 'MIXED_OR_UNKNOWN') {
    Write-Host "FAIL: expected the reproduced state to classify as MIXED_OR_UNKNOWN, got $mixedCoherence" -ForegroundColor Red
    exit 1
}
Write-Host "PASS: reproduced the exact pan-athen-style mixed state and it correctly classifies as MIXED_OR_UNKNOWN" -ForegroundColor Green

Write-Host ""
Write-Host "=== Step 4: run the REAL public tester exactly as a user would ==="
$testerScript = Join-Path $HarnessRoot 'STEMwerk-RTX50-cu128-test.ps1'
$run = Invoke-NativeProcess -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $testerScript, '-Yes') -TimeoutSeconds 900
Write-Host "Tester exit code: $($run.ExitCode)"
Write-Host "--- tester stdout (tail) ---"
Write-Host ($run.StdOut.Substring([Math]::Max(0, $run.StdOut.Length - 2000)))

Write-Host ""
Write-Host "=== Step 5: verify recovery ==="
$after = Show-Trio -Label 'After tester run'
$afterCoherence = Get-RuntimeCoherenceState -InstalledTrio $after

$ok = $true
if ($run.ExitCode -ne 0) { Write-Host "FAIL: expected the tester to exit 0 (rollback verified), got $($run.ExitCode)" -ForegroundColor Red; $ok = $false }

$reportPath = $null
if ($run.StdOut -match 'Report:\s*(.+\.md)') { $reportPath = $Matches[1].Trim() }
if (-not $reportPath -or -not (Test-Path -LiteralPath $reportPath)) {
    Write-Host "FAIL: could not locate the report file from tester stdout to check detection wording" -ForegroundColor Red; $ok = $false
}
else {
    $reportText = Get-Content -LiteralPath $reportPath -Raw
    if ($reportText -notmatch '(?i)interrupted transaction') {
        Write-Host "FAIL: expected the report to mention the interrupted transaction detection (checked $reportPath)" -ForegroundColor Red
        $ok = $false
    }
    else {
        Write-Host "Confirmed: report at $reportPath documents the interrupted transaction detection."
    }
}
if ($afterCoherence -ne 'RELEASE_BASELINE') { Write-Host "FAIL: expected final state to be exact coherent RELEASE_BASELINE, got $afterCoherence" -ForegroundColor Red; $ok = $false }
foreach ($pkg in @('torch', 'torchvision', 'torchaudio')) {
    if ($after.Packages[$pkg] -ne $before.Packages[$pkg]) {
        Write-Host "FAIL: $pkg ended at $($after.Packages[$pkg]), expected exact original $($before.Packages[$pkg])" -ForegroundColor Red
        $ok = $false
    }
}
$txAfter = Read-TransactionState
if ($txAfter.Exists) {
    Write-Host "FAIL: expected the transaction record to be cleared after a verified successful recovery, but it still exists (phase=$($txAfter.Data.phase))" -ForegroundColor Red
    $ok = $false
}
else {
    Write-Host "Confirmed: transaction record was cleared after verified recovery."
}

if ($ok) {
    Write-Host ""
    Write-Host "PASS: interrupted mixed-state transaction was detected, the REAL captured baseline (not the mixed state) was used for recovery, and the machine ended at the exact original baseline." -ForegroundColor Green
    exit 0
}
else {
    Write-Host ""
    Write-Host "TEST FAILED - machine may not be at baseline. Run ROLLBACK-STEMwerk-RTX50.cmd and inspect manually." -ForegroundColor Red
    exit 1
}
