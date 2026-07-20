# POA-0 native transport fix

REPORT_SCHEMA_VERSION=1
PREVIOUS_WORKFLOW_RUN_ID=29748336850
PREVIOUS_WORKFLOW_CLASSIFICATION=TRANSPORT_FAIL
DECLARED_OLD_MANIFEST_SHA256=80a1082a2d167cb671621073281648bef302a48b8d52e961aef116aa96908dab
COMMITTED_PRE_FIX_MANIFEST_SHA256=2e924b3b74bbd2b654d6caa7982062c738c37bf6d207fa0fc8787452f4b5b783
ROOT_CAUSE_UNIX=directly executed shell scripts were committed as mode 100644
ROOT_CAUSE_WINDOWS=checkout line-ending conversion changed frozen text bytes
EOL_POLICY=POA contractual text and source files use deterministic LF on every platform; PowerShell uses LF; known binary fixture extensions use -text
EXECUTABLE_MODE_FIX_COUNT=8
BINARY_FIXTURES_PROTECTED=yes
POST_FIX_MANIFEST_SHA256=2e924b3b74bbd2b654d6caa7982062c738c37bf6d207fa0fc8787452f4b5b783
RENORMALIZATION_RESULT=canonical LF renormalization changed zero tracked content bytes; manifest and fixture hashes remained byte-identical to commit 8753d484
TEST_SEMANTICS_CHANGED=no

## Executable mode fixes

- `scripts/run-native-matrix.sh`
- `scripts/verify-frozen-fixtures.sh`
- `scripts/build.sh`
- `scripts/assert-native-platform.sh`
- `harness/run-matrix.sh`
- `harness/lease-policy-tests.sh`
- `harness/platform-tests.sh`
- `harness/contract-smoke.sh`

No documentation, JSON, YAML, schema, fixture, PowerShell, generator, or
measurement file was made executable. Test cases, expected results, schemas,
fixtures, fault hooks, Rust logic, Go logic, and matrix size are unchanged.
