# Reporting.ps1
#
# Fail-safe report writer. Design goals (STEMwerk #118 harness gen 3):
#   - The report file is created at the very start of the run, before any
#     detection/mutation logic executes, and every section is appended (and
#     flushed) as it happens - never buffered only in memory until the end.
#     A crash, Ctrl+C, or unexpected exception can never result in "nothing
#     saved in report folder".
#   - Runtime state (baseline verified / mutation started / rollback
#     required / etc.) is tracked explicitly in a companion .state.json
#     file that is rewritten on every transition, so a human (or a future
#     run) can tell exactly how far execution got even if the process was
#     killed mid-flight.

Set-StrictMode -Version Latest

function New-HarnessReport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReportsDirectory,

        [Parameter(Mandatory = $true)]
        [string]$RunName
    )

    if (-not (Test-Path -LiteralPath $ReportsDirectory)) {
        New-Item -ItemType Directory -Path $ReportsDirectory -Force | Out-Null
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $base = Join-Path $ReportsDirectory "$RunName-$stamp"
    $reportPath = "$base.md"
    $statePath = "$base.state.json"

    $header = @"
# STEMwerk #118 RTX 50-series / Blackwell test harness report

Run name: $RunName
Started (local time): $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
Host: $env:COMPUTERNAME
User: $env:USERNAME
PowerShell version: $($PSVersionTable.PSVersion.ToString())
PowerShell edition: $($PSVersionTable.PSEdition)

---

"@
    Set-Content -LiteralPath $reportPath -Value $header -Encoding UTF8

    $state = [ordered]@{
        run_name           = $RunName
        started_utc        = (Get-Date).ToUniversalTime().ToString('o')
        state              = 'NOT_STARTED'
        state_history      = @()
        report_path        = $reportPath
        rollback_required  = $false
        rollback_attempted = $false
        rollback_verified  = $null
        final_result       = $null
    }
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statePath -Encoding UTF8

    return [PSCustomObject]@{
        ReportPath = $reportPath
        StatePath  = $statePath
    }
}

function Write-ReportSection {
    param(
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Body = ''
    )
    $text = "`n## $Title`n`n$Body`n"
    Add-Content -LiteralPath $ReportPath -Value $text -Encoding UTF8
}

function Write-ReportLine {
    param(
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [string]$Text = ''
    )
    Add-Content -LiteralPath $ReportPath -Value $Text -Encoding UTF8
}

function Write-ReportKeyValues {
    <#
        Writes a flat table of key/value pairs. Accepts an [ordered]
        hashtable or a plain hashtable.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)]$Pairs
    )
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($key in $Pairs.Keys) {
        $lines.Add("- **$key**: $($Pairs[$key])")
    }
    Add-Content -LiteralPath $ReportPath -Value ($lines -join "`n") -Encoding UTF8
    Add-Content -LiteralPath $ReportPath -Value '' -Encoding UTF8
}

function Write-ReportNativeResult {
    <#
        Records a native process invocation (see Invoke-NativeProcess.ps1)
        in full: command line, exit code, stdout, stderr. This is what
        keeps warning-only stderr output visible in the report instead of
        being discarded.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)]$NativeResult
    )
    $body = @()
    $body += '```'
    $body += "command:   $($NativeResult.CommandLine)"
    $body += "exit code: $($NativeResult.ExitCode)"
    $body += "success:   $($NativeResult.Success)"
    $body += "timed out: $($NativeResult.TimedOut)"
    $body += "duration:  $($NativeResult.DurationMs) ms"
    if ($NativeResult.LaunchException) {
        $body += "launch exception: $($NativeResult.LaunchException.ToString())"
    }
    $body += '```'
    $body += ''
    $body += '<details><summary>stdout</summary>'
    $body += ''
    $body += '```'
    $body += $(if ([string]::IsNullOrWhiteSpace($NativeResult.StdOut)) { '(empty)' } else { $NativeResult.StdOut.TrimEnd() })
    $body += '```'
    $body += '</details>'
    $body += ''
    $body += '<details><summary>stderr</summary>'
    $body += ''
    $body += '```'
    $body += $(if ([string]::IsNullOrWhiteSpace($NativeResult.StdErr)) { '(empty)' } else { $NativeResult.StdErr.TrimEnd() })
    $body += '```'
    $body += '</details>'

    Write-ReportSection -ReportPath $ReportPath -Title $Title -Body ($body -join "`n")
}

function Set-HarnessState {
    <#
        Rewrites the .state.json file with the new state, appending to
        state_history so the full transition sequence is recoverable.
        Also writes a one-line breadcrumb into the human-readable report.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$ReportPath,
        [Parameter(Mandatory = $true)][string]$NewState,
        [string]$Note = ''
    )

    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    $historyEntry = [ordered]@{
        state     = $NewState
        timestamp = (Get-Date).ToUniversalTime().ToString('o')
        note      = $Note
    }

    # $state.state_history comes back as a plain object array from
    # ConvertFrom-Json; rebuild explicitly to keep this PS 5.1-safe.
    $newHistory = @()
    if ($state.state_history) { $newHistory += $state.state_history }
    $newHistory += [PSCustomObject]$historyEntry

    $state.state = $NewState
    $state.state_history = $newHistory

    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatePath -Encoding UTF8

    $noteText = ''
    if ($Note) { $noteText = " - $Note" }
    Write-ReportLine -ReportPath $ReportPath -Text "> **[state]** $NewState$noteText  ($(Get-Date -Format 'HH:mm:ss'))"
}

function Complete-HarnessState {
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)]$FinalResult,
        [bool]$RollbackRequired = $false,
        [bool]$RollbackAttempted = $false,
        $RollbackVerified = $null
    )
    $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    $state.final_result = $FinalResult
    $state.rollback_required = $RollbackRequired
    $state.rollback_attempted = $RollbackAttempted
    $state.rollback_verified = $RollbackVerified
    $state | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $StatePath -Encoding UTF8
}
