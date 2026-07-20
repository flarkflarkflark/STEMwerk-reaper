$ErrorActionPreference = 'Stop'
$Script = Join-Path $PSScriptRoot 'assert-windows-native-preflight.ps1'

function Assert-Fails([scriptblock]$Action, [string]$Expected) {
  $Failed = $false
  try { & $Action }
  catch {
    $Failed = $true
    if ($_.Exception.Message -notlike "*$Expected*") { throw }
  }
  if (-not $Failed) { throw "expected failure containing: $Expected" }
}

$DiagnosticOutput = & $Script -Implementation rust -DiagnosticMode windows-rust-copy-hash -DiagnosticCases 'CMN-001,CMN-008' -AvailableCommands @('bash','powershell','rustc','cargo')
if ($DiagnosticOutput -notcontains 'SQLITE3_REQUIRED_FOR_SELECTED_ROUTE=no') { throw 'Diagnostic route did not bypass unused sqlite3 capability' }
'DIAGNOSTIC_WITHOUT_SQLITE3_REACHES_CASE_SELECTION=PASS'

Assert-Fails { & $Script -Implementation rust -DiagnosticMode normal -AvailableCommands @('bash','rustc','cargo') } 'sqlite3 absent'
'NORMAL_WINDOWS_WITHOUT_SQLITE3_FAILS_PREFLIGHT=PASS'

Assert-Fails { & $Script -Implementation rust -DiagnosticMode windows-rust-copy-hash -DiagnosticCases 'CMN-999' -AvailableCommands @('bash','powershell','rustc','cargo') } 'Unsupported diagnostic case selection'
'INVALID_DIAGNOSTIC_CASE_FAILS_CLOSED=PASS'

Assert-Fails { & $Script -Implementation rust -DiagnosticMode normal -DiagnosticCases 'CMN-001,CMN-008' -AvailableCommands @('bash','powershell','rustc','cargo') } 'DiagnosticCases is only valid in diagnostic mode'
'UNRELATED_MODE_SQLITE3_BEHAVIOR_UNCHANGED=PASS'
