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

GATES_READY=9

GATES_BLOCKED=1

BLOCKED_GATES=GATE-P9 intentionally pending first mutation task

P2's JCS and runtime-schema-tool portions and P4 passed through the approved SLICE-0 implementation and final corrected cross-platform evidence at `ab59eef7d00de7e0d6e4d2467fb815a3d0975eb3`. `SCHEMA_BINDINGS_PLAN.md` still records `SCHEMA_GENERATOR=TO_BE_SELECTED`: SLICE-1 introduces no generated binding, and any proposal to do so reopens the generator portion of P2 before merge. P7 passed for the existing two pinned dependencies and is re-applied to every proposed dependency; SLICE-1 forbids new dependencies. P8 passed, including XPG-001 and XPG-002. Gate state never grants implementation authority by itself.

SLICE_1_AUTHORIZATION_GATE=approved documentation-closure head plus separate explicit owner authorization naming component-manager/docs/SLICE_1_SCOPE.md

SLICE_1_FINAL_EXIT_GATE=exactly one owner-approved full four-platform native dispatch on a pinned candidate head; same-head rerun only for evidenced infrastructure failure
