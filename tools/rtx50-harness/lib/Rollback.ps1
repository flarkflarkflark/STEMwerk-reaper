# Rollback.ps1
#
# Shared rollback flow used both automatically (by the main test script,
# when a post-mutation verification step fails) and manually (by
# STEMwerk-RTX50-rollback.ps1 / ROLLBACK-STEMwerk-RTX50.cmd).
#
# v2: restores from the durable transaction record's trusted baseline
# object (see RuntimeState.ps1), never from a manifest file whose
# provenance can't be verified. Also fixes a v1 verification bug: v1 only
# compared torch's version string (with a redundant, always-false OR
# branch that concatenated the cuda tag twice); v2 compares the FULL
# restored trio against the exact recorded baseline trio via
# Get-RuntimeCoherenceState-equivalent exact matching, so a rollback that
# gets torch right but torchvision/torchaudio wrong is correctly reported
# as NOT verified instead of a false PASS.

Set-StrictMode -Version Latest

function Invoke-RollbackFlow {
    param(
        [Parameter(Mandatory = $true)][string]$PythonExe,
        [Parameter(Mandatory = $true)]$Baseline,
        [Parameter(Mandatory = $true)][string]$ProbeScriptPath,
        [Parameter(Mandatory = $true)][string]$SmokeScriptPath,
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)][string]$StatePath,
        $Transaction = $null
    )

    Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'ROLLBACK_ATTEMPTED' -Note 'restoring from the durable trusted baseline'
    if ($Transaction) { $Transaction = Set-TransactionPhase -Record $Transaction -NewPhase 'ROLLBACK_STARTED' -Note 'restoring recorded baseline' }

    Write-ReportSection -ReportPath $ReportPath -Title 'Rollback target (from durable trusted baseline)' -Body ('```' + "`n" + ($Baseline | ConvertTo-Json -Depth 6) + "`n" + '```')

    $restore = Invoke-BaselineRestore -PythonExe $PythonExe -Baseline $Baseline
    Write-ReportNativeResult -ReportPath $ReportPath -Title 'Rollback: pip install (restore baseline)' -NativeResult $restore.Native

    if (-not $restore.Ok) {
        Write-ReportSection -ReportPath $ReportPath -Title 'Rollback result' -Body 'FAIL: pip install for baseline restore did not succeed. ROLLBACK STATUS UNKNOWN / MANUAL ATTENTION REQUIRED.'
        Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'ROLLBACK_FAILED_UNKNOWN'
        if ($Transaction) { $Transaction = Set-TransactionPhase -Record $Transaction -NewPhase 'INTERRUPTED_UNKNOWN' -Note 'pip install for rollback restore failed; baseline preserved for retry' }
        return [PSCustomObject]@{ Ok = $false; Verified = $false; Reason = 'pip install for restore failed'; Transaction = $Transaction }
    }

    # Re-verify the FULL trio (not just torch) plus torch.version.cuda,
    # CUDA available, a basic CUDA op, and STEMwerk imports.
    $installedTrio = Get-InstalledTorchTrio -PythonExe $PythonExe
    $verifyInfo = Get-PhysicalGpuInfo -PythonPath $PythonExe -ProbeScriptPath $ProbeScriptPath
    Write-ReportSection -ReportPath $ReportPath -Title 'Rollback verification: version/arch probe' -Body ('```' + "`n" + $(if ($verifyInfo.RawJson) { $verifyInfo.RawJson } else { 'no output' }) + "`n" + '```')

    $smoke = Invoke-NativeProcess -FilePath $PythonExe -ArgumentList @($SmokeScriptPath)
    Write-ReportNativeResult -ReportPath $ReportPath -Title 'Rollback verification: CUDA smoke test + STEMwerk imports' -NativeResult $smoke

    $trioMatches = $true
    foreach ($pkg in @('torch', 'torchvision', 'torchaudio')) {
        if (-not $installedTrio.Ok -or -not $installedTrio.Packages.Contains($pkg) -or $installedTrio.Packages[$pkg] -ne $Baseline.packages.$pkg) {
            $trioMatches = $false
        }
    }
    $verified = $trioMatches -and $verifyInfo.CudaAvailable -and $smoke.Success

    Write-ReportKeyValues -ReportPath $ReportPath -Pairs ([ordered]@{
        'expected trio (torch/vision/audio)' = "$($Baseline.packages.torch) / $($Baseline.packages.torchvision) / $($Baseline.packages.torchaudio)"
        'actual trio (torch/vision/audio)'   = "$($installedTrio.Packages['torch']) / $($installedTrio.Packages['torchvision']) / $($installedTrio.Packages['torchaudio'])"
        'full trio matches baseline exactly' = $trioMatches
        'cuda available'                     = $verifyInfo.CudaAvailable
        'smoke test success'                 = $smoke.Success
        'ROLLBACK VERIFIED'                  = $verified
    })

    if ($verified) {
        Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'ROLLBACK_VERIFIED'
        if ($Transaction) {
            $Transaction = Set-TransactionPhase -Record $Transaction -NewPhase 'ROLLBACK_VERIFIED' -Note 'restored trio matches recorded baseline exactly; clearing transaction'
            Clear-TransactionState
        }
        return [PSCustomObject]@{ Ok = $true; Verified = $true; Info = $verifyInfo; Smoke = $smoke; Transaction = $Transaction }
    }
    else {
        Write-ReportSection -ReportPath $ReportPath -Title 'Rollback result' -Body 'FAIL: post-rollback verification did not match expected baseline. **ROLLBACK STATUS UNKNOWN / MANUAL ATTENTION REQUIRED.**'
        Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'ROLLBACK_FAILED_UNKNOWN'
        if ($Transaction) { $Transaction = Set-TransactionPhase -Record $Transaction -NewPhase 'INTERRUPTED_UNKNOWN' -Note 'post-rollback verification failed; baseline preserved, NOT cleared' }
        return [PSCustomObject]@{ Ok = $false; Verified = $false; Info = $verifyInfo; Smoke = $smoke; Transaction = $Transaction }
    }
}
