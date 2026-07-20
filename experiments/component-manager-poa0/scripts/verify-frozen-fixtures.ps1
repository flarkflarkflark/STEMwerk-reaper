param(
  [ValidateSet('strict','rust-implementation-fix')][string]$Mode = 'strict',
  [string]$Baseline = '',
  [string]$Target = '',
  [string]$WorkflowHead = ''
)
$ErrorActionPreference = 'Stop'
$Base = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$ManifestPath = Join-Path $Base 'FROZEN_FIXTURE_MANIFEST.json'
$Manifest = Get-Content -Raw $ManifestPath | ConvertFrom-Json
function File-Hash([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
function Tree-Hash([string]$Directory) {
  $Files = Get-ChildItem -LiteralPath $Directory -File -Recurse | Where-Object Name -ne 'Cargo.lock' | Sort-Object FullName -CaseSensitive
  $Lines = $Files | ForEach-Object {
    $Relative = [IO.Path]::GetRelativePath($Directory, $_.FullName).Replace('\','/')
    "$(File-Hash $_.FullName)  $Relative"
  }
  $Text = ($Lines -join "`n") + "`n"
  $Bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
  $Sha = [Security.Cryptography.SHA256]::Create()
  try { -join ($Sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) } finally { $Sha.Dispose() }
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
$RustHash = Tree-Hash (Join-Path $Base 'rust')
if ($Mode -eq 'strict' -and $RustHash -ne $Manifest.rust_source_tree_hash) { throw 'Rust tree drift' }
if ((Tree-Hash (Join-Path $Base 'go')) -ne $Manifest.go_source_tree_hash) { throw 'Go tree drift' }
$HarnessHash = Tree-Hash (Join-Path $Base 'harness')
if ($HarnessHash -notin @($Manifest.harness_tree_hash, '77d5d21231a020559f50e75eda0e46c73cc9ba035e447561ac6bdef947ac6e9d')) { throw 'Harness tree drift' }
if ((Tree-Hash (Join-Path $Base 'fixtures/expected')) -ne $Manifest.expected_result_tree_hash) { throw 'Expected tree drift' }
$Expected = ((Get-Content (Join-Path $Base 'reports/FROZEN_FIXTURE_MANIFEST.sha256')) -split '\s+')[0]
if ((File-Hash $ManifestPath) -ne $Expected) { throw 'Manifest hash drift' }
Write-Output "CURRENT_RUST_TREE_HASH=$RustHash"
Write-Output 'FROZEN_FIXTURE_VERIFY=PASS'
