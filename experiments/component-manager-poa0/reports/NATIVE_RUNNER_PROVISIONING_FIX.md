# POA-0 native runner provisioning and language isolation

REPORT_SCHEMA_VERSION=1
PREVIOUS_WORKFLOW_RUN_ID=29749303052
PREVIOUS_WORKFLOW_CLASSIFICATION=INFRASTRUCTURE_PARTIAL
ROOT_CAUSE_MACOS=Go was not available on either macOS runner
ROOT_CAUSE_WINDOWS=sqlite3 CLI was not available on the Windows runner
GO_SETUP_METHOD=actions/setup-go@v6
GO_VERSION_PIN=1.26.5
GO_CACHE_ENABLED=no
RUST_SETUP_METHOD=rustup toolchain install and default
RUST_VERSION_PIN=1.97.0
WINDOWS_SQLITE3_METHOD=Chocolatey package install
WINDOWS_SQLITE3_PACKAGE=sqlite
WINDOWS_SQLITE3_VERSION_PIN=3.53.3
WINDOWS_SQLITE3_CHECKSUM_POLICY=Chocolatey package checksums enforced; no ignore-checksums option
PROVISIONING_SCOPE=POA_ONLY
PROVISIONING_PRODUCTION_DEPENDENCY=no
IMPLEMENTATION_FILTERS=rust,go
EXPECTED_NATIVE_JOB_COUNT=8
TEST_SEMANTICS_CHANGED=no
FIXTURE_BYTES_CHANGED=no
SCHEMAS_CHANGED=no
IMPLEMENTATION_LOGIC_CHANGED=no

The workflow creates one independent job for every platform and language.
Rust jobs do not install or invoke the Go toolchain; Go jobs do not install or
invoke the Rust toolchain. Each job builds exactly one implementation. Because
the frozen, manifest-hashed harness deliberately owns one shared `rust go`
loop, orchestration exposes the selected binary under both temporary harness
names inside that disposable job. Thus every executed process is the selected
implementation while the frozen case declarations, expected-result logic,
fixtures, schemas, and fault-injection points remain byte-identical. Result
aggregation selects the 20 rows carrying the job's implementation name.

The Chocolatey-installed SQLite executable is disposable runner provisioning
only. Production core must use embedded/native SQLite and must not depend on
Chocolatey, runner-installed toolchains, or an external `sqlite3` executable.
