# Production implementation gates

| Gate | Required evidence | Pass condition | Fail condition | Owner | Blocks |
|---|---|---|---|---|---|
| GATE-P0 | this readiness set and validation report | complete, reviewed, blocker zero | missing/inconsistent document | architecture owner | any implementation |
| GATE-P1 | repository/package/API graph | approved roots, owners, acyclic graph | unresolved root/cycle/ownership | Go maintainer | SLICE-0 |
| GATE-P2 | bounded generator/JCS spike | pinned reproducible offline tooling and vectors | no conformant/supportable choice | schema/security owner | binding merge and SLICE-1 |
| GATE-P3 | FIRST_SLICE_SCOPE.md approval | exact allowed/forbidden scope and exit gate | scope includes effects or later slice | product/architecture owner | SLICE-0 |
| GATE-P4 | first-slice CI evidence | all mandatory tests/builds green | any required gate fails | implementation owner | SLICE-1 |
| GATE-P5 | Contract-v1 tree digest/diff | zero normative/schema/ADR drift or separately approved contract change | unauthorized drift | contract owner | every merge |
| GATE-P6 | POA/evidence equality guards | evidence/native/harness/runtime trees unchanged | regression or promotion | evidence owner | every production slice |
| GATE-P7 | dependency review record | owner, need, version/checksum, license, provenance, transitive/advisory/script policy approved | unreviewed or excessive dependency | security owner | dependency introduction |
| GATE-P8 | target build plan and build-tag audit | supported tags compile and unsupported target fails closed | implicit fallback/target gap | platform owner | SLICE-0 exit and adapters |
| GATE-P9 | explicit mutation authorization | separate task names exact mutation slice/roots/platforms/rollback | implicit or broad authority | release/product owner | first persistent/state mutation |

IMPLEMENTATION_GATE_COUNT=10

GATES_READY=6

GATES_BLOCKED=4

BLOCKED_GATES=GATE-P2 pending SLICE-0 spike; GATE-P4 pending SLICE-0 implementation; GATE-P7 pending actual dependency candidates; GATE-P9 intentionally pending first mutation task

P0, P1, P3, P5, P6 and P8 are ready for SLICE-0 entry. A gate described as blocked is a chronological hold for the work it names, not a readiness blocker for earlier work. Gate state never grants implementation authority by itself.
