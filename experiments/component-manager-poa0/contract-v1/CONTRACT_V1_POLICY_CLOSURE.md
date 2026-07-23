# Contract v1 implementation-policy closure

## Source reconstruction

| Blocker | Contract | Open-policy source | Review source | Existing trace | Affected schemas | Profiles | Fail-closed risk |
|---|---|---|---|---|---|---|---|
| BLOCKER-TRUST-001 | 9, 38 | former item 1 | security review | CMV1-PROVENANCE-001 | provenance, trust-root | core, catalog producer, installer | attacker bootstrap or scope escalation |
| BLOCKER-SIGN-001 | 38 | former item 2 | security review | CMV1-PROVENANCE-001 | signature-envelope, artifact, catalog | core, producer, helper | forgery or algorithm confusion |
| BLOCKER-REVOCATION-001 | 28, 39 | former item 3 | security review | CMV1-CATALOG-001 | trust-snapshot, revocation, catalog | core, producer | compromise persistence or rollback |
| BLOCKER-GC-001 | 27 | former item 4 | implementability review | CMV1-GC-001 | retention-policy, desired-state | core | irreversible protected-data deletion |
| BLOCKER-SCHEMA-001 | 37 | former item 5 | implementability review | CMV1-FAIL-010 | schema-capabilities, helper request | all profiles | unreadable active/rollback state |

There are no source conflicts and no unresolved conflicts. Each was blocking because
production behavior would otherwise require an undocumented safety choice.

## Decision criteria and alternatives

All decisions were evaluated for fail-closed safety, offline operation, Windows/macOS/Linux
applicability, development without production infrastructure, compromise recovery,
rollback resistance, auditability, determinism, backward compatibility, operational
complexity, user recovery, least privilege, testability, extensibility and absence of
hidden cloud dependencies.

| Blocker | Options considered | Selected | Rejected | Confidence | Residual risk |
|---|---|---|---|---|---|
| TRUST | scoped pre-distribution; global root; official TOFU; cloud enrollment | scoped trusted distribution plus explicit user enrollment | global blast radius, TOFU, cloud-only | HIGH | operational root ceremony |
| SIGN | Ed25519; ECDSA P-256; RSA; unrestricted agility | Ed25519 primary, P-256 transition, profile v1 | RSA and unrestricted algorithms | HIGH | JCS interoperability |
| REVOCATION | online-only; indefinite cache; bounded signed snapshot | monotone signed 30-day snapshot and catalog chain | online-only and indefinite cache | HIGH | availability after expiry |
| GC | age-only; count-only; conjunction; keep forever | protected classes plus count-and-age conjunction | single threshold and unbounded retention | HIGH | capacity planning |
| SCHEMA | read-any minor; exact-only; advertised strict window | major 1, current/minimum 1.0.0, advertised minor gate | permissive reads and lossy downgrade | HIGH | future adapter complexity |

## Policy interactions

| ID | Policies | Scenario | Required behavior | Fail-closed point | Contradiction | Resolution |
|---|---|---|---|---|---|---|
| INT-001 | revocation/offline | revoked key with expired snapshot | block state changes; last critical deny still applies | trust evaluation | no | active recovery only when no critical deny |
| INT-002 | catalog/offline | cached lower catalog | reject sequence/digest rollback | catalog acceptance | no | persist monotone evidence |
| INT-003 | schema/rollback | downgrade cannot read rollback generation | refuse downgrade | downgrade precheck | no | verify active plus two rollback generations |
| INT-004 | GC/revocation | revoked payload is inactive | retain 90 days after replacement | GC eligibility | no | preserve forensic evidence |
| INT-005 | GC/lease | lease identity suspected | keep generation | GC eligibility | no | uncertainty is protected |
| INT-006 | trust/rotation | old catalog signed before rotation | accept only valid chain/status/time | signature verification | no | overlap and signed chain |
| INT-007 | development/trust | development artifact proposed for official generation | reject scope mismatch | generation construction | no | isolated trust domains |
| INT-008 | active/revocation | critical deny arrives | refuse processing, preserve bytes | run start | no | explicit diagnostic/recovery |
| INT-009 | model/signing | unsigned development model | only isolated development generation | trust evaluation | no | no official scope inheritance |
| INT-010 | helper/offline | helper metadata cannot refresh | require valid cached official.helper trust | helper authorization | no | expiry blocks privileged change |

POLICY_INTERACTION_COUNT=10

POLICY_INTERACTION_CONTRADICTION_COUNT=0

UNRESOLVED_POLICY_INTERACTION_COUNT=0

## Closure result

All five blockers have an accepted ADR, normative contract, machine-readable schema,
valid and invalid examples, tests, traceability, and passing reviews.

IMPLEMENTATION_BLOCKERS_CLOSED=5/5

REMAINING_IMPLEMENTATION_BLOCKERS=none

CONTRACT_POLICY_GATE=READY

PRODUCTION_READINESS_GATE_AUTHORIZED=yes

PRODUCTION_IMPLEMENTATION_AUTHORIZED=no
