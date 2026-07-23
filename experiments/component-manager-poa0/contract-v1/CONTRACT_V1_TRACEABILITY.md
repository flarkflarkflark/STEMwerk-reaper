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
| CMV1-PROVENANCE-001 | Contract input 8 | 9 | provenance | provenance | APPROVED |
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

## Policy-closure requirements

| CONTRACT_REQUIREMENT_ID | BLOCKER | ADR | SECTION | SCHEMA | POSITIVE | NEGATIVE | TEST | PROFILE |
|---|---|---|---:|---|---|---|---|---|
| CMV1-TRUST-001 | BLOCKER-TRUST-001 | ADR-001 | 9 | trust-root | official-trust-root | unknown-official-trust-root | test_01_scope_isolation | core |
| CMV1-TRUST-002 | BLOCKER-TRUST-001 | ADR-001 | 9 | trust-root | user-enrolled-trust-root | official-tofu-attempt | test_02_no_official_tofu | core |
| CMV1-TRUST-003 | BLOCKER-TRUST-001 | ADR-001 | 9 | provenance | provenance | development-artifact-official-generation | test_03_user_enrollment_auditable_confirmation | catalog producer |
| CMV1-SIGN-001 | BLOCKER-SIGN-001 | ADR-002 | 38 | signature-envelope | valid-signature-envelope | invalid-signature | test_04_primary_algorithm | core |
| CMV1-SIGN-002 | BLOCKER-SIGN-001 | ADR-002 | 38 | signature-envelope | valid-signature-envelope | unknown-signature-algorithm | test_05_algorithm_allowlist | core |
| CMV1-SIGN-003 | BLOCKER-SIGN-001 | ADR-002 | 38 | artifact | artifact | unsigned-official-catalog | test_06_signed_digest_binding | catalog producer |
| CMV1-REVOKE-001 | BLOCKER-REVOCATION-001 | ADR-003 | 39 | revocation-statement | revocation-statement | revoked-signing-key | test_07_new_install_revoked | core |
| CMV1-REVOKE-002 | BLOCKER-REVOCATION-001 | ADR-003 | 39 | trust-snapshot | key-rotation-statement | broken-rotation-chain | test_08_active_recovery_default | core |
| CMV1-REVOKE-003 | BLOCKER-REVOCATION-001 | ADR-003 | 39 | revocation-statement | revocation-statement | rollback-to-revoked-generation | test_09_critical_deny | core |
| CMV1-OFFLINE-001 | BLOCKER-REVOCATION-001 | ADR-003 | 39 | trust-snapshot | offline-trust-snapshot | expired-offline-trust-snapshot | test_10_expired_install | core |
| CMV1-OFFLINE-002 | BLOCKER-REVOCATION-001 | ADR-003 | 39 | trust-snapshot | offline-trust-snapshot | clock-rollback-trust-expiry | test_12_clock_rollback | core |
| CMV1-CATALOG-SEC-001 | BLOCKER-REVOCATION-001 | ADR-003 | 28 | catalog | catalog-sequence-advance | lower-catalog-sequence | test_14_lower_sequence | catalog producer |
| CMV1-CATALOG-SEC-002 | BLOCKER-REVOCATION-001 | ADR-003 | 28 | catalog | signed-official-catalog | same-sequence-different-digest | test_15_same_sequence_digest_fork | catalog producer |
| CMV1-CATALOG-SEC-003 | BLOCKER-REVOCATION-001 | ADR-003 | 28 | catalog | signed-official-catalog | unsigned-official-catalog | test_13_monotonic_advance | catalog producer |
| CMV1-GC-002 | BLOCKER-GC-001 | ADR-004 | 27 | retention-policy | retention-policy | gc-before-count-threshold | test_16_count_threshold | core |
| CMV1-GC-003 | BLOCKER-GC-001 | ADR-004 | 27 | retention-policy | retention-policy | gc-before-age-threshold | test_17_age_threshold | core |
| CMV1-GC-004 | BLOCKER-GC-001 | ADR-004 | 27 | retention-policy | gc-eligible-inactive-generation | gc-with-suspected-lease | test_19_suspected_or_unknown_kept | core |
| CMV1-GC-005 | BLOCKER-GC-001 | ADR-004 | 27 | retention-policy | gc-eligible-inactive-generation | gc-with-unknown-ownership | test_20_shared_reference_and_dry_run | core |
| CMV1-SCHEMA-COMPAT-001 | BLOCKER-SCHEMA-001 | ADR-005 | 37 | schema-capabilities | schema-capability-advertisement | unknown-schema-major-policy | test_21_unknown_major | all |
| CMV1-SCHEMA-COMPAT-002 | BLOCKER-SCHEMA-001 | ADR-005 | 37 | schema-capabilities | schema-capability-advertisement | helper-core-schema-mismatch | test_22_newer_minor | platform helper |
| CMV1-SCHEMA-COMPAT-003 | BLOCKER-SCHEMA-001 | ADR-005 | 37 | schema-capabilities | downgrade-compatible-state | lossy-downgrade | test_23_writer_and_downgrade_window | core |
| CMV1-INTERACTION-001 | all five | ADR-001..005 | 43 | diagnostic-event | diagnostic-event | development-artifact-official-generation | test_24_policy_interaction_matrix | diagnostic producer |
| CMV1-TRUST-004 | BLOCKER-TRUST-001 | ADR-001 | 9 | trust-root | official-trust-root | official-tofu-attempt | test_02_no_official_tofu | installer |
| CMV1-REVOKE-004 | BLOCKER-REVOCATION-001 | ADR-003 | 39 | trust-snapshot | offline-trust-snapshot | clock-rollback-trust-expiry | test_12_clock_rollback | core |
| CMV1-GC-006 | BLOCKER-GC-001 | ADR-004 | 27 | retention-policy | retention-policy | gc-before-age-threshold | test_18_count_and_age | core |

All 25 policy-closure requirements are traced and tested. No new fail-closed rule
or schema lacks a corresponding fixture/example.
