# POA-0 native platform infrastructure fix

REPORT_SCHEMA_VERSION=1
PREVIOUS_WORKFLOW_RUN_ID=29761342728
PREVIOUS_WORKFLOW_CLASSIFICATION=INFRASTRUCTURE_PARTIAL
MACOS_ROOT_CAUSE=external POA sqlite3 CLI absent on macos-15-intel and macos-15
MACOS_SQLITE3_METHOD=official SQLite precompiled architecture-specific CLI archives
MACOS_SQLITE3_VERSION_PIN=3.53.3
MACOS_SQLITE3_X64_URL=https://www.sqlite.org/2026/sqlite-tools-osx-x64-3530300.zip
MACOS_SQLITE3_X64_SHA256=defe731640fe6a5d9a21e1bf0fac40f0c4a7bab53b52a2094f6c4c4aa04e5a42
MACOS_SQLITE3_ARM64_URL=https://www.sqlite.org/2026/sqlite-tools-osx-arm64-3530300.zip
MACOS_SQLITE3_ARM64_SHA256=f7b7c3666fce6efe96cba23e661e288bd56cc695fb9a1581445d4eb41cf4ccac
MACOS_SQLITE3_CHECKSUM_PINNED=yes
MACOS_SQLITE3_PROVISIONING_SCOPE=POA_ONLY
WINDOWS_ROOT_CAUSE=MSYS path was passed unchanged to native Windows jq
WINDOWS_JQ_PATH_FIX=convert only jq manifest arguments with cygpath -m on MINGW MSYS or CYGWIN
WINDOWS_PATH_CONVERSION_SCOPE=jq_boundary_only
GENERIC_PATH_REWRITE_USED=no
CYGPATH_USED=yes
TEST_SEMANTICS_CHANGED=no
FIXTURES_CHANGED=no
SCHEMAS_CHANGED=no
RUST_SOURCE_CHANGED=no
GO_SOURCE_CHANGED=no
FAULT_INJECTIONS_CHANGED=no
EXPECTED_NATIVE_JOB_COUNT=8

The official archives were additionally matched against the SHA3-256 values
published on SQLite's download page before their SHA256 pins were recorded.
The installed executable is expected at
`$RUNNER_TEMP/poa0-sqlite-3.53.3/sqlite3` on both macOS architectures.

This is disposable POA runner provisioning only. Production core must use
embedded/native SQLite and must not depend on Homebrew, downloaded runner
tools, or an external `sqlite3` executable.
