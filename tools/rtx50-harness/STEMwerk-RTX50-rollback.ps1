#Requires -Version 5.1
<#
    STEMwerk-RTX50-rollback.ps1  (v2)

    Restores the STEMwerk venv (%LOCALAPPDATA%\STEMwerk\.venv) using the
    durable trusted transaction baseline (see lib\RuntimeState.ps1),
    never from a manifest file whose provenance can't be verified and
    never by assuming an arbitrary version.

    Decision matrix (spec section 11):
      - already at the exact coherent release baseline -> no-op PASS.
      - a trusted baseline is on record (mixed or experimental current
        state) -> restore it and verify the FULL trio, not just torch.
      - no trusted baseline exists -> offer the documented STEMwerk
        2.3.1.1 release trio ONLY if independent identity checks
        corroborate this really is that release environment; otherwise
        fail closed and require manual attention.

    EXIT CODES: 0 = rollback verified / no-op; 1 = rollback failed or
    verification failed; 2 = could not run safely (fail closed); 3 =
    aborted by user; 4 = unexpected error.
#>
param(
    [switch]$Yes
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'lib\Invoke-NativeProcess.ps1')
. (Join-Path $ScriptRoot 'lib\Reporting.ps1')
. (Join-Path $ScriptRoot 'lib\GpuDetect.ps1')
. (Join-Path $ScriptRoot 'lib\VenvSafety.ps1')
. (Join-Path $ScriptRoot 'lib\RuntimeState.ps1')
. (Join-Path $ScriptRoot 'lib\Rollback.ps1')

$ProbeScript = Join-Path $ScriptRoot 'lib\probe_env.py'
$SmokeScript = Join-Path $ScriptRoot 'lib\smoke_test.py'

function Main {
    $reportsDir = Join-Path $ScriptRoot 'reports'
    $reportInfo = New-HarnessReport -ReportsDirectory $reportsDir -RunName 'rtx50-rollback'
    $ReportPath = $reportInfo.ReportPath
    $StatePath = $reportInfo.StatePath

    Write-Host "STEMwerk #118 RTX 50-series harness: ROLLBACK (v2)"
    Write-Host "Report: $ReportPath"
    Write-Host ""

    try {
        Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'STARTED'

        $venvPath = Get-ExpectedStemwerkVenvPath
        $identity = Test-StemwerkVenvIdentity -VenvPath $venvPath
        Write-ReportSection -ReportPath $ReportPath -Title 'STEMwerk venv identity check' -Body ("Target path: $venvPath`n`nOk: $($identity.Ok)`n`nReasons:`n- " + ($(if ($identity.Reasons.Count -gt 0) { $identity.Reasons -join "`n- " } else { '(all checks passed)' })))
        if (-not $identity.Ok) {
            Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body 'FAIL (closed): could not verify STEMwerk venv identity. Refusing to touch anything.'
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'PRECHECK_FAIL'
            Complete-HarnessState -StatePath $StatePath -FinalResult 'FAIL'
            return 2
        }
        $venvPython = $identity.PythonExe

        $currentTrio = Get-InstalledTorchTrio -PythonExe $venvPython
        $currentCoherence = Get-RuntimeCoherenceState -InstalledTrio $currentTrio
        $txRead = Read-TransactionState
        Write-ReportKeyValues -ReportPath $ReportPath -Pairs ([ordered]@{
            'installed torch/vision/audio' = "$($currentTrio.Packages['torch']) / $($currentTrio.Packages['torchvision']) / $($currentTrio.Packages['torchaudio'])"
            'current runtime state'        = $currentCoherence
            'transaction record exists'    = $txRead.Exists
            'transaction record corrupt'   = $txRead.Corrupt
        })

        # Already at the exact coherent release baseline: no-op success.
        if ($currentCoherence -eq 'RELEASE_BASELINE') {
            Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body 'PASS (no-op): the environment is already the exact coherent STEMwerk release baseline. Nothing to restore.'
            if ($txRead.Exists -and -not $txRead.Corrupt) {
                Clear-TransactionState
                Write-ReportLine -ReportPath $ReportPath -Text 'A stale transaction record was found and cleared since the environment is already coherent at baseline.'
            }
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'ROLLBACK_VERIFIED'
            Complete-HarnessState -StatePath $StatePath -FinalResult 'PASS' -RollbackRequired $false -RollbackAttempted $false -RollbackVerified $true
            Write-Host "RESULT: PASS (already at baseline). Full report: $ReportPath" -ForegroundColor Green
            return 0
        }

        # A trusted baseline is on record: restore it regardless of
        # whether current state is mixed or the experimental target.
        if ($txRead.Exists -and -not $txRead.Corrupt -and $txRead.Data.baseline) {
            $rollbackResult = Invoke-RollbackFlow -PythonExe $venvPython -Baseline $txRead.Data.baseline -ProbeScriptPath $ProbeScript -SmokeScriptPath $SmokeScript -ReportPath $ReportPath -StatePath $StatePath -Transaction $txRead.Data
            if ($rollbackResult.Ok -and $rollbackResult.Verified) {
                Complete-HarnessState -StatePath $StatePath -FinalResult 'PASS' -RollbackRequired $true -RollbackAttempted $true -RollbackVerified $true
                Write-Host "RESULT: ROLLBACK VERIFIED. Full report: $ReportPath" -ForegroundColor Green
                return 0
            }
            else {
                Complete-HarnessState -StatePath $StatePath -FinalResult 'FAIL' -RollbackRequired $true -RollbackAttempted $true -RollbackVerified $false
                Write-Host "RESULT: ROLLBACK STATUS UNKNOWN / MANUAL ATTENTION REQUIRED. Full report: $ReportPath" -ForegroundColor Red
                return 1
            }
        }

        # No trusted baseline. Only remaining option: the documented
        # release fallback, gated by independent identity corroboration.
        Write-ReportSection -ReportPath $ReportPath -Title 'No trusted baseline on record' -Body (
            "No usable transaction record exists (Exists=$($txRead.Exists), Corrupt=$($txRead.Corrupt)). Checking whether " +
            "this still looks like the documented STEMwerk 2.3.1.1 release environment closely enough to offer its " +
            "known trio as an assumed recovery target."
        )
        $corroboration = Test-LooksLikeKnownStemwerkReleaseEnvironment -PythonExe $venvPython
        Write-ReportKeyValues -ReportPath $ReportPath -Pairs ([ordered]@{
            'looks like documented STEMwerk 2.3.1.1 environment' = $corroboration.Ok
            'reasons'                                              = $(if ($corroboration.Reasons.Count -gt 0) { $corroboration.Reasons -join '; ' } else { '(all corroborating checks passed)' })
        })

        if (-not $corroboration.Ok) {
            Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body (
                'FAIL (closed): no trusted baseline exists and this environment does not sufficiently corroborate as the ' +
                'documented STEMwerk 2.3.1.1 release. Refusing to invent a rollback target. **MANUAL ATTENTION REQUIRED.**'
            )
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'PRECHECK_FAIL'
            Complete-HarnessState -StatePath $StatePath -FinalResult 'FAIL'
            return 2
        }

        Write-Host ""
        Write-Host "No trusted baseline is on record for this machine. The documented STEMwerk 2.3.1.1 release trio" -ForegroundColor Yellow
        Write-Host "(torch 2.4.1+cu121 / torchvision 0.19.1+cu121 / torchaudio 2.4.1+cu121) can be restored as a" -ForegroundColor Yellow
        Write-Host "best-effort recovery." -ForegroundColor Yellow
        $proceed = $Yes.IsPresent
        if (-not $proceed) {
            $answer = Read-Host "Type RESTORE-DOCUMENTED-BASELINE to proceed with this assumed recovery"
            $proceed = ($answer -eq 'RESTORE-DOCUMENTED-BASELINE')
        }
        if (-not $proceed) {
            Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body 'ABORTED by user. Nothing was touched.'
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'ABORTED_BY_USER'
            Complete-HarnessState -StatePath $StatePath -FinalResult 'ABORTED'
            return 3
        }

        $assumedBaseline = ConvertTo-BaselineObjectFromKnownTrio -KnownTrio (Get-KnownTrio 'RELEASE_BASELINE')
        $rollbackResult = Invoke-RollbackFlow -PythonExe $venvPython -Baseline $assumedBaseline -ProbeScriptPath $ProbeScript -SmokeScriptPath $SmokeScript -ReportPath $ReportPath -StatePath $StatePath -Transaction $null
        if ($rollbackResult.Ok -and $rollbackResult.Verified) {
            Complete-HarnessState -StatePath $StatePath -FinalResult 'PASS' -RollbackRequired $true -RollbackAttempted $true -RollbackVerified $true
            Write-Host "RESULT: ROLLBACK VERIFIED (assumed documented baseline). Full report: $ReportPath" -ForegroundColor Green
            return 0
        }
        else {
            Complete-HarnessState -StatePath $StatePath -FinalResult 'FAIL' -RollbackRequired $true -RollbackAttempted $true -RollbackVerified $false
            Write-Host "RESULT: ROLLBACK STATUS UNKNOWN / MANUAL ATTENTION REQUIRED. Full report: $ReportPath" -ForegroundColor Red
            return 1
        }
    }
    catch {
        $errText = $_ | Out-String
        try {
            Write-ReportSection -ReportPath $ReportPath -Title 'UNEXPECTED EXCEPTION' -Body ('```' + "`n" + $errText + "`n" + '```' + "`n`n**ROLLBACK STATUS UNKNOWN / MANUAL ATTENTION REQUIRED.**")
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'UNEXPECTED_EXCEPTION'
            Complete-HarnessState -StatePath $StatePath -FinalResult 'UNKNOWN'
        }
        catch {
            Write-Host "FATAL: unexpected error AND failed to write to report: $errText" -ForegroundColor Red
        }
        Write-Host "UNEXPECTED ERROR - see report: $ReportPath" -ForegroundColor Red
        return 4
    }
}

exit (Main)
