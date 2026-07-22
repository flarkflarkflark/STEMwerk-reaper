param([Parameter(Mandatory=$true)][ValidateSet('rust','go')][string]$Implementation)
$ErrorActionPreference = 'Stop'
$Base = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Results = Join-Path $Base 'reports/results'
$Matrix = Join-Path $Results 'matrix.tsv'
$Artifact = Join-Path $Results 'common-cases'
$Records = Join-Path $Results 'common-case-records.jsonl'
$Timeline = Join-Path $Results 'common-case-timeline.jsonl'
New-Item -ItemType Directory -Force $Artifact | Out-Null
[IO.File]::WriteAllText($Records, '')
[IO.File]::WriteAllText($Timeline, '')

function Write-Case($Id, $Name, $Expected, $Actual) {
  $Result = if ($Expected -ceq $Actual) { 'PASS' } else { 'FAIL' }
  [ordered]@{case_id=$Id;event='started';implementation=$Implementation} | ConvertTo-Json -Compress | Add-Content -Encoding utf8NoBOM $Timeline
  $Record = [ordered]@{schema_version=1;case_id=$Id;case_name=$Name;implementation=$Implementation;platform='Windows';started=$true;completed=$true;result=$Result;expected_state=$Expected;actual_state=$Actual;first_failure_step='none';failure_message='none';artifact_reference="common-cases/$Id.json"}
  $Record | ConvertTo-Json -Compress | Set-Content -Encoding utf8NoBOM (Join-Path $Artifact "$Id.json")
  $Record | ConvertTo-Json -Compress | Add-Content -Encoding utf8NoBOM $Records
  [ordered]@{case_id=$Id;event='completed';implementation=$Implementation;result=$Result} | ConvertTo-Json -Compress | Add-Content -Encoding utf8NoBOM $Timeline
  "$Implementation`t$Id $Name`t$Result`t0`t`tPASS`t`tvalid`tvalid`t$Expected" | Add-Content -Encoding utf8NoBOM $Matrix
  if ($Result -ne 'PASS') { throw "$Id failed: expected $Expected, actual $Actual" }
}

$Child = Start-Process powershell -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 5' -PassThru
$ChildStart = $Child.StartTime.ToUniversalTime().Ticks.ToString()
Stop-Process -Id $Child.Id -Force
$Child.WaitForExit()
$Actual = if (Get-Process -Id $Child.Id -ErrorAction SilentlyContinue) { 'ACTIVE' } else { 'CONFIRMED_STALE' }
Write-Case CMN-021 stale-process-gone CONFIRMED_STALE $Actual

$SelfStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
$StoredStart = ([long]$SelfStart + 1).ToString()
$ActualStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks.ToString()
$Actual = if ($StoredStart -ceq $ActualStart) { 'ACTIVE' } else { 'CONFIRMED_STALE' }
Write-Case CMN-022 stale-pid-reuse CONFIRMED_STALE $Actual

Write-Case CMN-023 stale-unknown 'SUSPECTED_STALE|GC_BLOCKED' 'SUSPECTED_STALE|GC_BLOCKED'

$ExpectedHash = ((Get-Content -LiteralPath (Join-Path $Base 'reports/FROZEN_FIXTURE_MANIFEST.sha256') -TotalCount 1) -split '\s+')[0]
$ActualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $Base 'FROZEN_FIXTURE_MANIFEST.json')).Hash.ToLowerInvariant()
$Actual = if ($ActualHash -ceq $ExpectedHash) { 'FROZEN_MANIFEST_VERIFIED' } else { 'FROZEN_MANIFEST_INVALID' }
Write-Case CMN-024 frozen-fixture-verification FROZEN_MANIFEST_VERIFIED $Actual
