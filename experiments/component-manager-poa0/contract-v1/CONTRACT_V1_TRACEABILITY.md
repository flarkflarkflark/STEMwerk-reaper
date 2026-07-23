# Contract v1 traceability

| CONTRACT_REQUIREMENT_ID | SOURCE_DECISION | CONTRACT_SECTION | SCHEMA | TEST | STATUS |
|---|---|---:|---|---|---|
| CMV1-CORE-001 | CORE-001 | 1 | component | component-runtime-main | APPROVED |
| CMV1-STATE-001 | STATE-001 | 19 | desired-state | desired-state | APPROVED |
| CMV1-RECEIPT-001 | RECEIPT-001 | 18 | receipt | receipt | APPROVED |
| CMV1-GEN-001 | GEN-001 | 21 | generation | generation | APPROVED |
| CMV1-GEN-002 | GEN-002 | 14 | selector | selector | APPROVED |
| CMV1-GEN-003 | GEN-003 | 15 | generation | unknown-compatibility | APPROVED |
| CMV1-PIN-001 | PIN-001 | 25 | run-pin | run-pin | APPROVED |
| CMV1-LEASE-001 | LEASE-001 | 26 | lease | lease | APPROVED |
| CMV1-LEASE-002 | LEASE-002 | 26 | lease | unknown-lease-identity | APPROVED |
| CMV1-COMP-001 | COMP-001 | 11 | component | missing-runtime-main | APPROVED |
| CMV1-COMP-002 | COMP-002 | 11 | component | component-runtime-drumsep | APPROVED |
| CMV1-COMP-003 | COMP-003 | 10 | component | component-runtime-main | APPROVED |
| CMV1-MODEL-001 | MODEL-001 | 12 | component | unsigned-untrusted-model | APPROVED |
| CMV1-UI-001 | UI-001 | 30 | viewmodel | viewmodel | APPROVED |
| CMV1-PLATFORM-001 | PLATFORM-001 | 33 | helper-request | helper-request | APPROVED |
| CMV1-CASE-001 | CASE-001 | 40 | diagnostic-event | diagnostic-event | APPROVED |
| CMV1-CLAIM-001 | CLAIM-001 | 41 | error | error | APPROVED |
| CMV1-ID-001 | Contract input 4 | 6 | component | duplicate-component-identity | APPROVED |
| CMV1-VERSION-001 | Contract input 5 | 7 | component | same-version-different-digest | APPROVED |
| CMV1-ARTIFACT-001 | Contract input 6 | 8 | artifact | digest-mismatch | APPROVED |
| CMV1-PROVENANCE-001 | Contract input 8 | 9 | provenance | provenance | BLOCKED_POLICY |
| CMV1-SELECTOR-001 | Contract input 15 | 22 | selector | selector | APPROVED |
| CMV1-ROLLBACK-001 | Contract input 17 | 23 | generation | generation | APPROVED |
| CMV1-RECOVERY-001 | Contract input 18 | 24 | diagnostic-event | diagnostic-event | APPROVED |
| CMV1-GC-001 | Contract input 23 | 27 | generation | active-generation-gc-attempt | APPROVED |
| CMV1-CATALOG-001 | Contract input 26 | 28 | catalog | catalog | APPROVED |
| CMV1-HELPER-001 | Contract input 29 | 31 | helper-result | helper-result | APPROVED |
| CMV1-ERROR-001 | Contract input 25 | 35 | error | error | APPROVED |
| CMV1-FAIL-001 | CASE-001 | 36 | artifact | digest-mismatch | APPROVED |
| CMV1-FAIL-002 | COMP-001 | 36 | generation | missing-runtime-main | APPROVED |
| CMV1-FAIL-003 | GEN-003 | 36 | generation | incompatible-backend | APPROVED |
| CMV1-FAIL-004 | GEN-003 | 36 | generation | unknown-compatibility | APPROVED |
| CMV1-FAIL-005 | PIN-001 | 36 | run-pin | mixed-generation | APPROVED |
| CMV1-FAIL-006 | RECEIPT-001 | 36 | receipt | invalid-receipt | APPROVED |
| CMV1-FAIL-007 | LEASE-002 | 36 | lease | unknown-lease-identity | APPROVED |
| CMV1-FAIL-008 | LEASE-002 | 36 | generation | active-generation-gc-attempt | APPROVED |
| CMV1-FAIL-009 | MODEL-001 | 36 | component | unsigned-untrusted-model | APPROVED |
| CMV1-FAIL-010 | CLAIM-001 | 37 | selector | unsupported-schema-major | APPROVED |
| CMV1-FAIL-011 | Contract input 5 | 36 | component | same-version-different-digest | APPROVED |
| CMV1-FAIL-012 | GEN-003 | 36 | generation | duplicate-component-identity | APPROVED |

All 17 approved architecture decisions are traced. Every schema has a valid example,
and each of the twelve enumerated fail-closed rules has a negative fixture.
