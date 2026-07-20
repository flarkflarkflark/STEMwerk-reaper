param([string]$ExpectedArch = 'x86_64')
$ErrorActionPreference = 'Stop'
$Base = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Set-Location $Base
& "$Base/scripts/verify-frozen-fixtures.ps1"
if (-not (Get-Command sqlite3 -ErrorAction SilentlyContinue)) { throw 'UNSUPPORTED_ENVIRONMENT: sqlite3 absent' }
if (-not (Get-Command bash -ErrorAction SilentlyContinue)) { throw 'UNSUPPORTED_ENVIRONMENT: Git Bash absent' }
New-Item -ItemType Directory -Force "$Base/bin", "$Base/.caches/cargo-home", "$Base/.caches/cargo-target", "$Base/.caches/go-build", "$Base/.caches/go-mod", "$Base/.caches/go-path", "$Base/reports/results" | Out-Null
@("rustc=$(rustc --version)","cargo=$(cargo --version)","go=$(go version)","git=$(git --version)") | Set-Content -Encoding utf8NoBOM "$Base/reports/results/toolchains.txt"
$env:CARGO_HOME = "$Base/.caches/cargo-home"; $env:CARGO_TARGET_DIR = "$Base/.caches/cargo-target"
cargo test --manifest-path "$Base/rust/Cargo.toml"
cargo build --release --manifest-path "$Base/rust/Cargo.toml"
Copy-Item "$env:CARGO_TARGET_DIR/release/component-manager-poa0.exe" "$Base/bin/cm-rust.exe" -Force
$env:GOCACHE = "$Base/.caches/go-build"; $env:GOMODCACHE = "$Base/.caches/go-mod"; $env:GOPATH = "$Base/.caches/go-path"
Push-Location "$Base/go"; try { go test ./...; go build -buildvcs=false -trimpath -o "$Base/bin/cm-go.exe" . } finally { Pop-Location }
& "$Base/scripts/assert-native-platform.ps1" -ExpectedArch $ExpectedArch | Tee-Object -FilePath "$Base/reports/results/platform-info.txt"
$env:MSYS_NO_PATHCONV = '0'
$BashBase = (& bash -lc "cygpath -u '$Base'").Trim()
& bash "$BashBase/harness/run-matrix.sh"
if ($LASTEXITCODE -ne 0) { throw 'Common matrix failed' }
& "$Base/harness/lease-policy-tests.ps1"
& "$Base/harness/platform-tests.ps1"
$Summary = [ordered]@{schema_version=1;commit=$env:GITHUB_SHA;os='windows';architecture=$ExpectedArch;rust=@{build='PASS';common_matrix='24/24';classification='PASS_NATIVE'};go=@{build='PASS';common_matrix='24/24';classification='PASS_NATIVE'};mixed_component_visibility_count=0}
$Summary | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8NoBOM "$Base/reports/results/native-summary.json"
$Report = @"
# POA-0 native matrix result

- Commit: $env:GITHUB_SHA
- Workflow run: $env:GITHUB_RUN_ID
- Runner image: $env:ImageOS $env:ImageVersion
- Native OS/architecture: windows / $ExpectedArch
- Rust: PASS_NATIVE, common matrix 24/24
- Go: PASS_NATIVE, common matrix 24/24
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
