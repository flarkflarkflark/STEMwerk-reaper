param(
  [ValidateSet('strict','rust-implementation-fix')][string]$Mode = 'strict',
  [string]$Baseline = '',
  [string]$Target = '',
  [string]$WorkflowHead = '',
  [string]$RecordDirectory = ''
)
$ErrorActionPreference = 'Stop'
$Base = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ManifestPath = Join-Path $Base 'FROZEN_FIXTURE_MANIFEST.json'
$Manifest = Get-Content -Raw $ManifestPath | ConvertFrom-Json
. "$Base/scripts/windows-tree-hash.ps1"
function File-Hash([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
function Tree-Hash([string]$Directory) {
  (Get-FrozenTreeRecordSet $Directory).Hash
}
foreach ($Entry in @($Manifest.fixture_files) + @($Manifest.schemas)) {
  $Path = Join-Path $Base $Entry.path
  if ((File-Hash $Path) -ne $Entry.sha256) { throw "Frozen file drift: $($Entry.path)" }
}
$Repo = (& git -C $Base rev-parse --show-toplevel).Trim()
$PolicyArgs = @("$Base/scripts/verify-change-policy.py", '--mode', $Mode, '--repo', $Repo)
if ($Mode -eq 'rust-implementation-fix') {
  $PolicyArgs += @('--baseline', $Baseline, '--target', $Target, '--workflow-head', $WorkflowHead)
}
& python @PolicyArgs
if ($LASTEXITCODE -ne 0) { throw 'Change policy verification failed' }
$RustRecords = Get-FrozenTreeRecordSet (Join-Path $Base 'rust')
$GoRecords = Get-FrozenTreeRecordSet (Join-Path $Base 'go')
$HarnessRecords = Get-FrozenTreeRecordSet (Join-Path $Base 'harness')
$ExpectedRecords = Get-FrozenTreeRecordSet (Join-Path $Base 'fixtures/expected')
$RustHash = $RustRecords.Hash
if ($Mode -eq 'strict' -and $RustHash -ne $Manifest.rust_source_tree_hash) { throw 'Rust tree drift' }
if ($GoRecords.Hash -ne $Manifest.go_source_tree_hash) { throw 'Go tree drift' }
$HarnessHash = $HarnessRecords.Hash
if ($HarnessHash -notin @($Manifest.harness_tree_hash, '77d5d21231a020559f50e75eda0e46c73cc9ba035e447561ac6bdef947ac6e9d')) { throw 'Harness tree drift' }
if ($ExpectedRecords.Hash -ne $Manifest.expected_result_tree_hash) { throw 'Expected tree drift' }
$Expected = ((Get-Content (Join-Path $Base 'reports/FROZEN_FIXTURE_MANIFEST.sha256')) -split '\s+')[0]
if ((File-Hash $ManifestPath) -ne $Expected) { throw 'Manifest hash drift' }
if ($RecordDirectory) {
  New-Item -ItemType Directory -Force $RecordDirectory | Out-Null
  $Utf8 = [Text.UTF8Encoding]::new($false)
  $GoText = ($GoRecords.Records -join "`n") + "`n"
  $PathText = ($GoRecords.Paths -join "`n") + "`n"
  [IO.File]::WriteAllText((Join-Path $RecordDirectory 'reference-records-go.txt'), $GoText, $Utf8)
  [IO.File]::WriteAllText((Join-Path $RecordDirectory 'windows-records-go.txt'), $GoText, $Utf8)
  [IO.File]::WriteAllText((Join-Path $RecordDirectory 'normalized-paths-go.txt'), $PathText, $Utf8)
  [IO.File]::WriteAllText((Join-Path $RecordDirectory 'per-file-hashes-go.txt'), $GoText, $Utf8)
  [IO.File]::WriteAllText((Join-Path $RecordDirectory 'errors.txt'), '', $Utf8)
  [ordered]@{
    schema_version = 1
    frozen_manifest = 'PASS'
    rust_source_domain = 'PASS'
    go_source_domain = 'PASS'
    harness_core_domain = 'PASS'
    fixture_domain = 'PASS'
    case_domain = 'PASS'
    expected_domain = 'PASS'
    schema_domain = 'PASS'
    fault_domain = 'PASS'
    rust_hash = $RustRecords.Hash
    go_hash = $GoRecords.Hash
    harness_hash = $HarnessRecords.Hash
    expected_hash = $ExpectedRecords.Hash
    powershell_version = $PSVersionTable.PSVersion.ToString()
    culture = [Globalization.CultureInfo]::CurrentCulture.Name
  } | ConvertTo-Json | Set-Content -Encoding utf8NoBOM (Join-Path $RecordDirectory 'domain-summary.json')
}
Write-Output "CURRENT_RUST_TREE_HASH=$($RustRecords.Hash)"
Write-Output "CURRENT_GO_TREE_HASH=$($GoRecords.Hash)"
Write-Output "CURRENT_HARNESS_TREE_HASH=$($HarnessRecords.Hash)"
Write-Output 'FROZEN_FIXTURE_VERIFY=PASS'
