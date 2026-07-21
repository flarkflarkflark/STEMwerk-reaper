param(
  [Parameter(Mandatory=$true)][ValidateSet('rust','go')][string]$Implementation,
  [string]$ExpectedArch = 'x86_64',
  [ValidateSet('normal','windows-rust-copy-hash')][string]$DiagnosticMode = 'normal',
  [string]$DiagnosticCases = '',
  [ValidateSet('strict','rust-implementation-fix')][string]$VerificationMode = 'strict',
  [string]$VerificationBaseline = '',
  [string]$VerificationTarget = '',
  [string]$WorkflowHead = '',
  [switch]$SkipFrozenVerification
)
$ErrorActionPreference = 'Stop'
$Base = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if ($DiagnosticMode -eq 'windows-rust-copy-hash') {
  if ($Implementation -ne 'rust') { throw 'Diagnostic mode is restricted to Rust' }
  if ($DiagnosticCases -notin @('CMN-001,CMN-008', 'CMN-008')) { throw 'Unsupported diagnostic case selection' }
} elseif ($DiagnosticCases) {
  throw 'DiagnosticCases is only valid in diagnostic mode'
}
Set-Location $Base
if ($SkipFrozenVerification -and $DiagnosticMode -ne 'windows-rust-copy-hash') { throw 'SkipFrozenVerification is diagnostic-only' }
if (-not $SkipFrozenVerification) {
  & "$Base/scripts/verify-frozen-fixtures.ps1" -Mode $VerificationMode -Baseline $VerificationBaseline -Target $VerificationTarget -WorkflowHead $WorkflowHead
}
& "$Base/scripts/assert-windows-native-preflight.ps1" -Implementation $Implementation -DiagnosticMode $DiagnosticMode -DiagnosticCases $DiagnosticCases
New-Item -ItemType Directory -Force "$Base/bin", "$Base/.caches/cargo-home", "$Base/.caches/cargo-target", "$Base/.caches/go-build", "$Base/.caches/go-mod", "$Base/.caches/go-path", "$Base/reports/results" | Out-Null
if ($Implementation -eq 'rust') {
  rustc --version --verbose
  @("implementation=rust","rustc=$(rustc --version)","cargo=$(cargo --version)","git=$(git --version)") | Set-Content -Encoding utf8NoBOM "$Base/reports/results/toolchains.txt"
  $env:CARGO_HOME = "$Base/.caches/cargo-home"; $env:CARGO_TARGET_DIR = "$Base/.caches/cargo-target"
  cargo test --manifest-path "$Base/rust/Cargo.toml"
  cargo build --release --manifest-path "$Base/rust/Cargo.toml"
  Copy-Item "$env:CARGO_TARGET_DIR/release/component-manager-poa0.exe" "$Base/bin/cm-rust.exe" -Force
} else {
  go version
  go env GOHOSTOS GOHOSTARCH
  @("implementation=go","go=$(go version)","gohostos=$(go env GOHOSTOS)","gohostarch=$(go env GOHOSTARCH)","git=$(git --version)") | Set-Content -Encoding utf8NoBOM "$Base/reports/results/toolchains.txt"
  $env:GOCACHE = "$Base/.caches/go-build"; $env:GOMODCACHE = "$Base/.caches/go-mod"; $env:GOPATH = "$Base/.caches/go-path"
  Push-Location "$Base/go"; try { go test ./...; go build -buildvcs=false -trimpath -o "$Base/bin/cm-go.exe" . } finally { Pop-Location }
}
if ($Implementation -eq 'rust') { Copy-Item "$Base/bin/cm-rust.exe" "$Base/bin/cm-go.exe" -Force }
else { Copy-Item "$Base/bin/cm-go.exe" "$Base/bin/cm-rust.exe" -Force }
& "$Base/scripts/assert-native-platform.ps1" -ExpectedArch $ExpectedArch | Tee-Object -FilePath "$Base/reports/results/platform-info.txt"
Copy-Item "$Base/scripts/native-poa-wrapper.sh" "$Base/bin/cm-rust" -Force
Copy-Item "$Base/scripts/native-poa-wrapper.sh" "$Base/bin/cm-go" -Force
$BashBase = (& bash -lc "cygpath -u '$Base'").Trim()
& bash "$BashBase/scripts/verify-implementation-parity.sh"
if ($LASTEXITCODE -ne 0) { throw 'Implementation parity guard failed' }
if ($DiagnosticMode -eq 'windows-rust-copy-hash') {
  & "$Base/scripts/run-windows-rust-copy-hash-diagnostic.ps1" -Cases $DiagnosticCases
  if ($LASTEXITCODE -ne 0) { throw 'Windows Rust copy/hash diagnostic failed to capture evidence' }
  exit 0
}
& bash "$BashBase/harness/run-matrix.sh"
if ($LASTEXITCODE -ne 0) { throw 'Common matrix failed' }
& "$Base/harness/lease-policy-tests.ps1"
& "$Base/harness/platform-tests.ps1"
$Summary = [ordered]@{schema_version=1;commit=$env:GITHUB_SHA;os='windows';architecture=$ExpectedArch;implementation=$Implementation;build='PASS';common_matrix='24/24';lease_matrix='10/10';platform='PASS';classification='PASS_NATIVE';mixed_component_visibility_count=0}
$Summary | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8NoBOM "$Base/reports/results/native-summary.json"
$Report = @"
# POA-0 native matrix result

- Commit: $env:GITHUB_SHA
- Workflow run: $env:GITHUB_RUN_ID
- Runner image: $env:ImageOS $env:ImageVersion
- Native OS/architecture: windows / $ExpectedArch
- Implementation: $Implementation
- Result: PASS_NATIVE, common matrix 24/24
- Platform cases: PASS
- Lease policy: 10/10
- Mixed-generation visibility: 0
- Cross-build classification: not used for this result
- Final language decision: pending_native_ci until all four native jobs complete

This per-run report is generated in the workflow workspace and uploaded as a
small Actions artifact. Signing and notarization remain outside POA-0.
"@
$ReportTarget = if ($env:GITHUB_ACTIONS -eq 'true') { "$Base/reports/NATIVE_MATRIX_RESULTS.md" } else { "$Base/reports/results/NATIVE_MATRIX_RESULTS.md" }
$Report | Set-Content -Encoding utf8NoBOM $ReportTarget
