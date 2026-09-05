#Requires -Version 5.1
<#
    STEMwerk-RTX50-rollback.ps1

    Restores the STEMwerk venv (%LOCALAPPDATA%\STEMwerk\.venv) to the
    exact baseline captured by the most recent STEMwerk-RTX50-cu128-test.ps1
    run (or a specific manifest passed with -ManifestPath).

    Never assumes version numbers - always restores exactly what the
    baseline manifest recorded.
#>
param(
    [string]$ManifestPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'lib\Invoke-NativeProcess.ps1')
. (Join-Path $ScriptRoot 'lib\Reporting.ps1')
. (Join-Path $ScriptRoot 'lib\GpuDetect.ps1')
. (Join-Path $ScriptRoot 'lib\VenvSafety.ps1')
. (Join-Path $ScriptRoot 'lib\Rollback.ps1')

$ProbeScript = Join-Path $ScriptRoot 'lib\probe_env.py'
$SmokeScript = Join-Path $ScriptRoot 'lib\smoke_test.py'

function Main {
    $reportsDir = Join-Path $ScriptRoot 'reports'
    $reportInfo = New-HarnessReport -ReportsDirectory $reportsDir -RunName 'rtx50-rollback'
    $ReportPath = $reportInfo.ReportPath
    $StatePath = $reportInfo.StatePath

    Write-Host "STEMwerk #118 RTX 50-series harness: ROLLBACK"
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

        if (-not $ManifestPath) {
            $candidates = @(Get-ChildItem -Path $reportsDir -Filter '*.baseline.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            if ($candidates.Count -eq 0) {
                Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body 'FAIL: no -ManifestPath given and no *.baseline.json found under reports\. Nothing was touched.'
                Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'PRECHECK_FAIL'
                Complete-HarnessState -StatePath $StatePath -FinalResult 'FAIL'
                return 2
            }
            $ManifestPath = $candidates[0].FullName
            Write-ReportLine -ReportPath $ReportPath -Text "No -ManifestPath given; using most recent baseline manifest: $ManifestPath"
        }

        $rollbackResult = Invoke-RollbackFlow -PythonExe $venvPython -ManifestPath $ManifestPath -ProbeScriptPath $ProbeScript -SmokeScriptPath $SmokeScript -ReportPath $ReportPath -StatePath $StatePath

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
