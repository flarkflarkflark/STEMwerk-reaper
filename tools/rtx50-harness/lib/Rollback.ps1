# Rollback.ps1
#
# Shared rollback flow used both automatically (by the main test script,
# when a post-mutation verification step fails) and manually (by
# STEMwerk-RTX50-rollback.ps1 / ROLLBACK-STEMwerk-RTX50.cmd).
#
# Restores the ACTUAL captured baseline manifest - never an assumed
# version string - and re-verifies the restored environment before
# declaring success.

Set-StrictMode -Version Latest

function Invoke-RollbackFlow {
    param(
        [Parameter(Mandatory = $true)][string]$PythonExe,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$ProbeScriptPath,
        [Parameter(Mandatory = $true)][string]$SmokeScriptPath,
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)][string]$StatePath
    )

    Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'ROLLBACK_ATTEMPTED' -Note "restoring from $ManifestPath"

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        Write-ReportSection -ReportPath $ReportPath -Title 'Rollback' -Body "FAIL: baseline manifest not found at $ManifestPath. ROLLBACK STATUS UNKNOWN / MANUAL ATTENTION REQUIRED."
        Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'ROLLBACK_FAILED_UNKNOWN'
        return [PSCustomObject]@{ Ok = $false; Verified = $null; Reason = 'manifest missing' }
    }

    $manifestRaw = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    Write-ReportSection -ReportPath $ReportPath -Title 'Rollback target (from captured baseline manifest)' -Body ('```' + "`n" + ($manifestRaw | ConvertTo-Json -Depth 6) + "`n" + '```')

    $restore = Invoke-BaselineRestore -PythonExe $PythonExe -ManifestPath $ManifestPath
    Write-ReportNativeResult -ReportPath $ReportPath -Title 'Rollback: pip install (restore baseline)' -NativeResult $restore.Native

    if (-not $restore.Ok) {
        Write-ReportSection -ReportPath $ReportPath -Title 'Rollback result' -Body 'FAIL: pip install for baseline restore did not succeed. ROLLBACK STATUS UNKNOWN / MANUAL ATTENTION REQUIRED.'
        Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'ROLLBACK_FAILED_UNKNOWN'
        return [PSCustomObject]@{ Ok = $false; Verified = $false; Reason = 'pip install for restore failed' }
    }

    # Re-verify: exact versions, torch.version.cuda, CUDA available, basic
    # CUDA op, STEMwerk imports.
    $verifyInfo = Get-PhysicalGpuInfo -PythonPath $PythonExe -ProbeScriptPath $ProbeScriptPath
    Write-ReportSection -ReportPath $ReportPath -Title 'Rollback verification: version/arch probe' -Body ('```' + "`n" + $(if ($verifyInfo.RawJson) { $verifyInfo.RawJson } else { 'no output' }) + "`n" + '```')

    $smoke = Invoke-NativeProcess -FilePath $PythonExe -ArgumentList @($SmokeScriptPath)
    Write-ReportNativeResult -ReportPath $ReportPath -Title 'Rollback verification: CUDA smoke test + STEMwerk imports' -NativeResult $smoke

    $versionsMatch = ($verifyInfo.TorchVersion -eq "$($manifestRaw.packages.torch)+$($manifestRaw.cuda_tag)") -or ($verifyInfo.TorchVersion -eq $manifestRaw.packages.torch)
    $verified = $versionsMatch -and $verifyInfo.CudaAvailable -and $smoke.Success

    Write-ReportKeyValues -ReportPath $ReportPath -Pairs ([ordered]@{
        'expected torch version' = "$($manifestRaw.packages.torch)+$($manifestRaw.cuda_tag)"
        'actual torch version'   = $verifyInfo.TorchVersion
        'cuda available'         = $verifyInfo.CudaAvailable
        'smoke test success'     = $smoke.Success
        'ROLLBACK VERIFIED'      = $verified
    })

    if ($verified) {
        Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'ROLLBACK_VERIFIED'
        return [PSCustomObject]@{ Ok = $true; Verified = $true; Info = $verifyInfo; Smoke = $smoke }
    }
    else {
        Write-ReportSection -ReportPath $ReportPath -Title 'Rollback result' -Body 'FAIL: post-rollback verification did not match expected baseline. **ROLLBACK STATUS UNKNOWN / MANUAL ATTENTION REQUIRED.**'
        Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'ROLLBACK_FAILED_UNKNOWN'
        return [PSCustomObject]@{ Ok = $false; Verified = $false; Info = $verifyInfo; Smoke = $smoke }
    }
}
