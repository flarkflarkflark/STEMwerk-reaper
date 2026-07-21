param(
  [Parameter(Mandatory=$true)][ValidateSet('rust','go')][string]$Implementation,
  [ValidateSet('normal','windows-rust-copy-hash')][string]$DiagnosticMode = 'normal',
  [string]$DiagnosticCases = '',
  [string[]]$AvailableCommands
)

$ErrorActionPreference = 'Stop'

function Test-CommandAvailable([string]$Name) {
  if ($null -ne $AvailableCommands) { return $AvailableCommands -contains $Name }
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

if ($DiagnosticMode -eq 'windows-rust-copy-hash') {
  if ($Implementation -ne 'rust') { throw 'Diagnostic mode is restricted to Rust' }
  if ($DiagnosticCases -cnotin @('CMN-001,CMN-008', 'CMN-008')) { throw 'Unsupported diagnostic case selection' }
  foreach ($Capability in @('bash','powershell','rustc','cargo')) {
    if (-not (Test-CommandAvailable $Capability)) { throw "UNSUPPORTED_ENVIRONMENT: $Capability absent" }
  }
  'DIAGNOSTIC_PREFLIGHT_MODE=windows-rust-copy-hash'
  'SQLITE3_REQUIRED_FOR_SELECTED_ROUTE=no'
  'SQLITE3_PREFLIGHT_SKIPPED_REASON=selected cases do not use sqlite3 before instrumented copy/hash interval'
  return
}

if ($DiagnosticCases) { throw 'DiagnosticCases is only valid in diagnostic mode' }
if (-not (Test-CommandAvailable 'sqlite3')) { throw 'UNSUPPORTED_ENVIRONMENT: sqlite3 absent' }
if (-not (Test-CommandAvailable 'bash')) { throw 'UNSUPPORTED_ENVIRONMENT: Git Bash absent' }
'SQLITE3_REQUIRED_FOR_SELECTED_ROUTE=yes'
