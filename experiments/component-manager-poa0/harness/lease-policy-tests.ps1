$ErrorActionPreference = 'Stop'
$Base = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Out = Join-Path $Base 'reports/results/lease-policy.tsv'
New-Item -ItemType Directory -Force (Split-Path -Parent $Out) | Out-Null
"case_id`texpected`tactual`tresult" | Set-Content -Encoding utf8NoBOM $Out
$HostId = [Environment]::MachineName
$SelfProcess = Get-Process -Id $PID
$SelfStart = $SelfProcess.StartTime.ToUniversalTime().Ticks.ToString()

function Classify-Lease($LeaseHost, $ProcessId, $ExpectedStart, $Probe, $State) {
  if ($State -eq 'released') { return 'RELEASED' }
  if ($LeaseHost -ne $HostId) { return 'SUSPECTED_STALE' }
  if ($Probe -eq 'unknown') { return 'SUSPECTED_STALE' }
  $Process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if (-not $Process) { return 'CONFIRMED_STALE' }
  try { $Actual = $Process.StartTime.ToUniversalTime().Ticks.ToString() } catch { return 'SUSPECTED_STALE' }
  if ($Actual -eq $ExpectedStart) { return 'ACTIVE' }
  return 'CONFIRMED_STALE'
}
function Check-Case($Id, $Expected, $Actual) {
  $Result = if ($Expected -eq $Actual) { 'PASS' } else { 'FAIL' }
  "$Id`t$Expected`t$Actual`t$Result" | Add-Content -Encoding utf8NoBOM $Out
}
Check-Case LEASE-001 ACTIVE (Classify-Lease $HostId $PID $SelfStart ok active)
Check-Case LEASE-002 RELEASED (Classify-Lease $HostId $PID $SelfStart ok released)
Check-Case LEASE-003 CONFIRMED_STALE (Classify-Lease $HostId 2147483647 0 ok active)
Check-Case LEASE-004 CONFIRMED_STALE (Classify-Lease $HostId $PID ([string]([long]$SelfStart + 1)) ok active)
Check-Case LEASE-005 SUSPECTED_STALE (Classify-Lease other-host $PID $SelfStart ok active)
Check-Case LEASE-006 SUSPECTED_STALE (Classify-Lease $HostId $PID $SelfStart unknown active)
Check-Case LEASE-007 ACTIVE (Classify-Lease $HostId $PID $SelfStart ok active)
Check-Case LEASE-008 ACTIVE (Classify-Lease $HostId $PID $SelfStart ok active)
$Child = Start-Process powershell -ArgumentList '-NoProfile','-Command','Start-Sleep -Seconds 5' -PassThru
$ChildStart = $Child.StartTime.ToUniversalTime().Ticks.ToString()
Stop-Process -Id $Child.Id -Force
$Child.WaitForExit()
Check-Case LEASE-009 CONFIRMED_STALE (Classify-Lease $HostId $Child.Id $ChildStart ok active)
$Suspected = Classify-Lease other-host $PID $SelfStart ok active
Check-Case LEASE-010 GC_BLOCKED $(if ($Suspected -eq 'SUSPECTED_STALE') { 'GC_BLOCKED' } else { 'GC_ALLOWED' })
$Rows = Import-Csv -Delimiter "`t" $Out
$Passed = @($Rows | Where-Object result -eq PASS).Count
Write-Output "LEASE_POLICY_TESTS=$Passed/$($Rows.Count)"
if ($Passed -ne $Rows.Count) { exit 1 }
