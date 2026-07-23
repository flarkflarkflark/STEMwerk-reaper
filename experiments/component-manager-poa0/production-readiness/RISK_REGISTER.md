# Risk register

| ID | Description | Likelihood | Impact | Mitigation | Detection | Owner | Blocks first slice | Residual risk |
|---|---|---|---|---|---|---|---|---|
| R-001 | RFC 8785 mismatch changes signed IDs | MEDIUM | HIGH | bounded library/vector spike and cross-language vectors | deterministic conformance CI | security | no | unusual number edge cases |
| R-002 | schema generator drift weakens validation | MEDIUM | HIGH | pin tool/checksum, commit output, runtime validation | clean regeneration diff | schema | no | upstream abandonment |
| R-003 | SQLite driver differs across targets | MEDIUM | HIGH | native CGO/pure-Go spike and contract suite | build/crash matrix | storage/platform | no | OS filesystem variance |
| R-004 | Windows durability primitive is weaker than claimed | HIGH | HIGH | handle-based replace/flush proof and fault injection before activation | native power/crash proxy tests | Windows owner | no | hardware/AV interference |
| R-005 | macOS Intel runner/tool longevity | MEDIUM | MEDIUM | pin runner/toolchain and define support review | scheduled build health | macOS owner | no | ecosystem retirement |
| R-006 | codesigning/helper identity complexity delays release | MEDIUM | HIGH | isolate adapter, closed handshake and staged signing plan | negative identity tests | security/release | no | certificate operations |
| R-007 | 30-day offline trust expiry burdens support | MEDIUM | MEDIUM | expiry telemetry, signed offline refresh/runbook | expiry simulations/support metrics | trust owner | no | prolonged disconnection |
| R-008 | GC deletes protected/shared data | HIGH | HIGH | unknown-means-keep, dry run, count+age, pins/leases/reference proof | property/fault/crash tests | GC owner | no | storage growth from conservatism |
| R-009 | helper privilege escalation | MEDIUM | HIGH | closed enum, confined handles, peer/code identity, no shell | abuse/replay/path tests | security/platform | no | OS-specific attack surface |
| R-010 | stale consumer viewmodel starts wrong generation | MEDIUM | HIGH | revision tokens, unavailable state and exact run pin | stale/mixed fixtures | viewmodel owner | no | user-visible blocking |
| R-011 | model provenance is incomplete | MEDIUM | HIGH | require signed provenance and isolated development scope | provenance/schema audit | catalog owner | no | third-party metadata quality |
| R-012 | offline all-models distribution is too large | HIGH | MEDIUM | content addressing, optional sets and capacity planning later | artifact-size budget | product/packaging | no | offline availability tradeoff |
| R-013 | contract becomes over-abstracted in Go | MEDIUM | MEDIUM | concrete values, 20 justified effect/policy interfaces, API review each slice | interface/use-site review | Go maintainer | no | future consumer pressure |
| R-014 | POA semantics leak into production | MEDIUM | HIGH | Contract-first reimplementation, no copy, equality/traceability gates | path/diff/contract tests | architecture owner | no | undocumented POA assumptions |

RISK_COUNT=14

HIGH_HIGH_RISK_COUNT=2

FIRST_SLICE_BLOCKING_RISK_COUNT=0

FIRST_SLICE_BLOCKING_RISKS=none

All risks have mitigations and detection. R-001/R-002 are deliberately retired or bounded during SLICE-0 before their outputs are trusted; they do not block starting that spike-only/read-only slice. R-004 and R-008 block their later mutation gates, not the first slice.
