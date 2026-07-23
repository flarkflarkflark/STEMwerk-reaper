# Readiness traceability

Every approved Contract-v1 requirement maps to a production package/API or concrete value, storage authority where applicable, its normative schema, first realizing slice, test layer and implementation gate. Status READY means design-mapped, not implemented or authorized.

| Contract requirement | ADR | Package | Interface | Storage object | Schema | Vertical slice | Test layer | Implementation gate | Status |
|---|---|---|---|---|---|---|---|---|---|
| CMV1-CORE-001 | none | component | none (concrete value) | components/artifacts | component | SLICE-1 | 1/2 | P4/P5/P6/P7 | READY |
| CMV1-STATE-001 | none | state | none (concrete value) | state | desired-state | SLICE-1 | 1/2 | P4/P5/P6/P7 | READY |
| CMV1-RECEIPT-001 | none | receipt | ReceiptStore | receipts | receipt | SLICE-2 | 3/4/5 | P4/P5/P6/P7/P9 | READY |
| CMV1-GEN-001 | none | generation/state/lifecycle | GenerationStore/CompatibilityResolver | generations/selectors/journals | generation | SLICE-3 | 1/2 | P4/P5/P6/P7/P9 | READY |
| CMV1-GEN-002 | none | generation/state/lifecycle | GenerationStore/CompatibilityResolver | generations/selectors/journals | selector | SLICE-4 | 5/6/13 | P4/P5/P6/P7/P9 | READY |
| CMV1-GEN-003 | none | generation/state/lifecycle | GenerationStore/CompatibilityResolver | generations/selectors/journals | generation | SLICE-3 | 1/2 | P4/P5/P6/P7/P9 | READY |
| CMV1-PIN-001 | none | runpin | RunPinStore | generations/locks-leases | run-pin | SLICE-5 | 13/14/15 | P4/P5/P6/P7/P9 | READY |
| CMV1-LEASE-001 | none | lease | LeaseStore | generations/locks-leases | lease | SLICE-5 | 13/14/15 | P4/P5/P6/P7/P9 | READY |
| CMV1-LEASE-002 | none | lease | LeaseStore | generations/locks-leases | lease | SLICE-5 | 13/14/15 | P4/P5/P6/P7/P9 | READY |
| CMV1-COMP-001 | none | component | none (concrete value) | components/artifacts | component | SLICE-3 | 1/2 | P4/P5/P6/P7/P9 | READY |
| CMV1-COMP-002 | none | component | none (concrete value) | components/artifacts | component | SLICE-3 | 1/2 | P4/P5/P6/P7/P9 | READY |
| CMV1-COMP-003 | none | component | none (concrete value) | components/artifacts | component | SLICE-3 | 1/2 | P4/P5/P6/P7/P9 | READY |
| CMV1-MODEL-001 | none | component | none (concrete value) | components/artifacts | component | SLICE-10 | 16/17 | P4/P5/P6/P7/P9 | READY |
| CMV1-UI-001 | none | viewmodel | ViewModelService | none | viewmodel | SLICE-8 | 11/12 | P4/P5/P6/P7/P9 | READY |
| CMV1-PLATFORM-001 | none | internal/platform/helperprotocol | Filesystem | none | helper-request | SLICE-7 | 5/6/13 | P4/P5/P6/P7/P9 | READY |
| CMV1-CASE-001 | none | diagnostics | DiagnosticSink | diagnostics | diagnostic-event | SLICE-8 | 11/12 | P4/P5/P6/P7/P9 | READY |
| CMV1-CLAIM-001 | none | diagnostics | DiagnosticSink | diagnostics | error | SLICE-8 | 11/12 | P4/P5/P6/P7/P9 | READY |
| CMV1-ID-001 | none | artifact/identity/version/digest | none (concrete value) | none | component | SLICE-0 | 1/2 | P0/P1/P2/P3/P5/P6/P7/P8 | READY |
| CMV1-VERSION-001 | none | artifact/identity/version/digest | none (concrete value) | none | component | SLICE-0 | 1/2 | P0/P1/P2/P3/P5/P6/P7/P8 | READY |
| CMV1-ARTIFACT-001 | none | artifact/identity/version/digest | none (concrete value) | components/artifacts | artifact | SLICE-0 | 1/2 | P0/P1/P2/P3/P5/P6/P7/P8 | READY |
| CMV1-PROVENANCE-001 | none | provenance | none (concrete value) | components/artifacts | provenance | SLICE-1 | 1/2 | P4/P5/P6/P7 | READY |
| CMV1-SELECTOR-001 | none | generation/state/lifecycle | SelectorPublisher | generations/selectors/journals | selector | SLICE-4 | 5/6/13 | P4/P5/P6/P7/P9 | READY |
| CMV1-ROLLBACK-001 | none | generation/state/lifecycle | RecoveryService | generations/selectors/journals | generation | SLICE-4 | 5/6/13 | P4/P5/P6/P7/P9 | READY |
| CMV1-RECOVERY-001 | none | generation/state/lifecycle | RecoveryService | generations/selectors/journals | diagnostic-event | SLICE-4 | 5/6/13 | P4/P5/P6/P7/P9 | READY |
| CMV1-GC-001 | none | gc | GarbageCollector | generations/locks-leases | generation | SLICE-5 | 13/14/15 | P4/P5/P6/P7/P9 | READY |
| CMV1-CATALOG-001 | none | catalog | CatalogService | catalogs | catalog | SLICE-1 | 1/2 | P4/P5/P6/P7 | READY |
| CMV1-HELPER-001 | none | internal/platform/helperprotocol | HelperClient | none | helper-result | SLICE-9 | 9/10/13 | P4/P5/P6/P7/P9 | READY |
| CMV1-ERROR-001 | none | diagnostics | DiagnosticSink | diagnostics | error | SLICE-8 | 11/12 | P4/P5/P6/P7/P9 | READY |
| CMV1-FAIL-001 | none | contract plus owning policy package | none (concrete value) | none | artifact | SLICE-1 | 1/2 | P4/P5/P6/P7 | READY |
| CMV1-FAIL-002 | none | contract plus owning policy package | none (concrete value) | none | generation | SLICE-1 | 1/2 | P4/P5/P6/P7 | READY |
| CMV1-FAIL-003 | none | contract plus owning policy package | none (concrete value) | none | generation | SLICE-1 | 1/2 | P4/P5/P6/P7 | READY |
| CMV1-FAIL-004 | none | contract plus owning policy package | none (concrete value) | none | generation | SLICE-1 | 1/2 | P4/P5/P6/P7 | READY |
| CMV1-FAIL-005 | none | contract plus owning policy package | none (concrete value) | none | run-pin | SLICE-1 | 1/2 | P4/P5/P6/P7 | READY |
| CMV1-FAIL-006 | none | contract plus owning policy package | none (concrete value) | none | receipt | SLICE-1 | 1/2 | P4/P5/P6/P7 | READY |
| CMV1-FAIL-007 | none | contract plus owning policy package | none (concrete value) | none | lease | SLICE-1 | 1/2 | P4/P5/P6/P7 | READY |
| CMV1-FAIL-008 | none | contract plus owning policy package | none (concrete value) | none | generation | SLICE-1 | 1/2 | P4/P5/P6/P7 | READY |
| CMV1-FAIL-009 | none | contract plus owning policy package | none (concrete value) | none | component | SLICE-1 | 1/2 | P4/P5/P6/P7 | READY |
| CMV1-FAIL-010 | none | contract plus owning policy package | none (concrete value) | none | selector | SLICE-1 | 1/2 | P4/P5/P6/P7 | READY |
| CMV1-FAIL-011 | none | contract plus owning policy package | none (concrete value) | none | component | SLICE-1 | 1/2 | P4/P5/P6/P7 | READY |
| CMV1-FAIL-012 | none | contract plus owning policy package | none (concrete value) | none | generation | SLICE-1 | 1/2 | P4/P5/P6/P7 | READY |
| CMV1-TRUST-001 | ADR-001 | trust | TrustVerifier | trust | official-trust-root | SLICE-6 | 2/7/9 | P4/P5/P6/P7/P9 | READY |
| CMV1-TRUST-002 | ADR-001 | trust | TrustVerifier | trust | user-enrolled-trust-root | SLICE-6 | 2/7/9 | P4/P5/P6/P7/P9 | READY |
| CMV1-TRUST-003 | ADR-001 | trust | TrustVerifier | trust | provenance | SLICE-6 | 2/7/9 | P4/P5/P6/P7/P9 | READY |
| CMV1-SIGN-001 | ADR-002 | signature | SignatureVerifier | trust | valid-signature-envelope | SLICE-6 | 2/7/9 | P4/P5/P6/P7/P9 | READY |
| CMV1-SIGN-002 | ADR-002 | signature | SignatureVerifier | trust | valid-signature-envelope | SLICE-6 | 2/7/9 | P4/P5/P6/P7/P9 | READY |
| CMV1-SIGN-003 | ADR-002 | signature | SignatureVerifier | trust | artifact | SLICE-6 | 2/7/9 | P4/P5/P6/P7/P9 | READY |
| CMV1-REVOKE-001 | ADR-003 | revocation | RevocationProvider | trust | revocation-statement | SLICE-6 | 2/7/9 | P4/P5/P6/P7/P9 | READY |
| CMV1-REVOKE-002 | ADR-003 | revocation | RevocationProvider | trust | key-rotation-statement | SLICE-6 | 2/7/9 | P4/P5/P6/P7/P9 | READY |
| CMV1-REVOKE-003 | ADR-003 | revocation | RevocationProvider | trust | revocation-statement | SLICE-6 | 2/7/9 | P4/P5/P6/P7/P9 | READY |
| CMV1-OFFLINE-001 | ADR-003 | revocation | RevocationProvider | trust | offline-trust-snapshot | SLICE-6 | 2/7/9 | P4/P5/P6/P7/P9 | READY |
| CMV1-OFFLINE-002 | ADR-003 | revocation | RevocationProvider | trust | offline-trust-snapshot | SLICE-6 | 2/7/9 | P4/P5/P6/P7/P9 | READY |
| CMV1-CATALOG-SEC-001 | ADR-003 | catalog | CatalogService | catalogs | catalog-sequence-advance | SLICE-6 | 2/7/9 | P4/P5/P6/P7/P9 | READY |
| CMV1-CATALOG-SEC-002 | ADR-003 | catalog | CatalogService | catalogs | signed-official-catalog | SLICE-6 | 2/7/9 | P4/P5/P6/P7/P9 | READY |
| CMV1-CATALOG-SEC-003 | ADR-003 | catalog | CatalogService | catalogs | signed-official-catalog | SLICE-6 | 2/7/9 | P4/P5/P6/P7/P9 | READY |
| CMV1-GC-002 | ADR-004 | gc | GarbageCollector | generations/locks-leases | retention-policy | SLICE-5 | 13/14/15 | P4/P5/P6/P7/P9 | READY |
| CMV1-GC-003 | ADR-004 | gc | GarbageCollector | generations/locks-leases | retention-policy | SLICE-5 | 13/14/15 | P4/P5/P6/P7/P9 | READY |
| CMV1-GC-004 | ADR-004 | gc | GarbageCollector | generations/locks-leases | gc-eligible-inactive-generation | SLICE-5 | 13/14/15 | P4/P5/P6/P7/P9 | READY |
| CMV1-GC-005 | ADR-004 | gc | GarbageCollector | generations/locks-leases | gc-eligible-inactive-generation | SLICE-5 | 13/14/15 | P4/P5/P6/P7/P9 | READY |
| CMV1-SCHEMA-COMPAT-001 | ADR-005 | contract | none (concrete value) | components/artifacts | schema-capability-advertisement | SLICE-3 | 1/2 | P4/P5/P6/P7/P9 | READY |
| CMV1-SCHEMA-COMPAT-002 | ADR-005 | contract | none (concrete value) | components/artifacts | schema-capability-advertisement | SLICE-3 | 1/2 | P4/P5/P6/P7/P9 | READY |
| CMV1-SCHEMA-COMPAT-003 | ADR-005 | contract | none (concrete value) | components/artifacts | downgrade-compatible-state | SLICE-3 | 1/2 | P4/P5/P6/P7/P9 | READY |
| CMV1-INTERACTION-001 | ADR-001..005 | contract | none (concrete value) | none | diagnostic-event | SLICE-6 | 2/7/9 | P4/P5/P6/P7/P9 | READY |
| CMV1-TRUST-004 | ADR-001 | trust | TrustVerifier | trust | official-trust-root | SLICE-6 | 2/7/9 | P4/P5/P6/P7/P9 | READY |
| CMV1-REVOKE-004 | ADR-003 | revocation | RevocationProvider | trust | offline-trust-snapshot | SLICE-6 | 2/7/9 | P4/P5/P6/P7/P9 | READY |
| CMV1-GC-006 | ADR-004 | gc | GarbageCollector | generations/locks-leases | retention-policy | SLICE-5 | 13/14/15 | P4/P5/P6/P7/P9 | READY |

READINESS_TRACEABILITY_ROW_COUNT=65

UNMAPPED_CONTRACT_REQUIREMENTS=none

PACKAGES_WITHOUT_CONTRACT_BASIS=none

PUBLIC_APIS_WITHOUT_REQUIREMENT=none

SLICES_WITHOUT_EXIT_GATE=none

RISKS_WITHOUT_MITIGATION=none
