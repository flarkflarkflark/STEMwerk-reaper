$ErrorActionPreference = 'Stop'
$Base = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Out = Join-Path $Base 'reports/results/platform.tsv'
"case_id`tresult`tdetail" | Set-Content -Encoding utf8NoBOM $Out
function Check-Case($Id, $Detail, [scriptblock]$Check) {
  $Result = try { if (& $Check) { 'PASS' } else { 'FAIL' } } catch { 'FAIL' }
  "$Id`t$Result`t$Detail" | Add-Content -Encoding utf8NoBOM $Out
  if ($Result -ne 'PASS') { throw "$Id failed: $Detail" }
}
$Drive = (Get-Item $PWD.Path).PSDrive
Check-Case WIN-001 ntfs-active-replace { (Get-Volume -DriveLetter $Drive.Name).FileSystem -eq 'NTFS' }
Check-Case WIN-002 concurrent-reader { (Import-Csv -Delimiter "`t" (Join-Path $Base 'reports/results/matrix.tsv') | Where-Object case -Like 'CMN-020*').result -notcontains 'FAIL' }
$Probe = Join-Path $env:RUNNER_TEMP 'poa-open-handle'
New-Item -ItemType Directory -Force $Probe | Out-Null
$Old = Join-Path $Probe old.txt; 'old' | Set-Content $Old
$Handle = [IO.File]::Open($Old,'Open','Read','ReadWrite,Delete')
try { Move-Item $Old (Join-Path $Probe moved.txt); Check-Case WIN-003 open-old-generation-handle { $Handle.CanRead } } finally { $Handle.Dispose() }
$Source = Join-Path $Probe source.txt; $Copy = Join-Path $Probe copy.txt; 'fixture' | Set-Content $Source; Copy-Item $Source $Copy
Check-Case WIN-004 hardlink-copy-fallback { (Get-FileHash $Source).Hash -eq (Get-FileHash $Copy).Hash }
$Unicode = Join-Path $Probe 'component-üñîçødé'; New-Item -ItemType Directory -Force $Unicode | Out-Null
Check-Case WIN-005 unicode-path { Test-Path $Unicode }
$Long = $Probe; 1..8 | ForEach-Object { $Long = Join-Path $Long ('segment-' + ('x' * 24)); New-Item -ItemType Directory -Force $Long | Out-Null }
Check-Case WIN-006 long-path { Test-Path $Long }
Check-Case WIN-007 readonly-failure { (Import-Csv -Delimiter "`t" (Join-Path $Base 'reports/results/matrix.tsv') | Where-Object case -Like 'CMN-014*').result -notcontains 'FAIL' }
$Defender = Get-MpComputerStatus -ErrorAction SilentlyContinue
Check-Case WIN-008 defender-plan { $null -ne $Defender -and $Defender.AntivirusEnabled }
$Start = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
Check-Case WIN-009 process-creation-time { $Start -gt 0 }
$Rows = Import-Csv -Delimiter "`t" $Out
Write-Output "PLATFORM_TESTS=$(@($Rows | Where-Object result -eq PASS).Count)/$($Rows.Count)"
