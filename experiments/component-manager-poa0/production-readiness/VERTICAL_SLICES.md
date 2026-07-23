# Vertical slice sequence

Every slice starts only after its entry gate is approved, provides contract-visible value, and leaves a revertable state. All implementations are unauthorized in this readiness task.

## Slices

### SLICE-0 — Production skeleton and contract bindings

Value: buildable production module with strong contract types and fail-closed read-only schema validation. Scope: module, contract/identity/version/digest/canonicaljson binding boundaries, embedded schema resources, generator/JCS spikes and unit/contract tests. Excludes filesystem mutation, SQLite, network, activation, trust enrollment, helper, installer and consumer. Packages: contract, identity, version, digest, canonicaljson plus schema binding support. Requirements: CMV1-ID-001, VERSION-001, ARTIFACT-001, SCHEMA-COMPAT-001..003, SIGN-001. Tests: layers 1,2,7,9. Entry: GATE-P0/P1/P3/P5/P6/P8. Exit: generator and JCS choice pinned, cross-platform compile and contract negatives green, no effects. Native: none. Rollback: revert its bounded commits. Risk: LOW.

### SLICE-1 — Read-only catalog and component validation

Value: validate catalog/component identity, version, digest and compatibility inputs without network. Scope: parse supplied bytes and explain errors. Excludes writes/downloads/trust enrollment. Packages: artifact, provenance, component, catalog, compatibility, signature boundary. Requirements: CMV1-CORE/COMP/CATALOG/FAIL-001..004/011..012. Tests: layers 1,2,7,8,9. Entry: SLICE-0 exit and P2/P4/P7. Exit: all contract catalog/component fixtures deterministic and fail closed. Native: none. Rollback: remove read-only handlers. Risk: LOW.

### SLICE-2 — Immutable local store and rebuildable index

Value: publish verified artifacts/receipts and rebuild index. Excludes generations/activation. Packages: receipt, internal/store/files, internal/store/sqlite, journal. Requirements: RECEIPT-001, ARTIFACT-001, FAIL-006. Tests: layers 2-5,9,13. Entry: dependency/SQLite decision and storage contract tests. Exit: crash-safe immutable publication and clean rebuild. Native: Linux first plus compile all. Rollback: selector untouched; rebuild/drop index. Risk: MEDIUM.

### SLICE-3 — Generation construction and compatibility

Value: construct immutable, non-active generations and readiness explanation. Excludes selector mutation. Packages: generation, compatibility, lifecycle, state types. Requirements: GEN-001/003, COMP-001..003, FAIL-002..004/012. Tests: 1,2,8,9,13. Entry: SLICE-2. Exit: mixed/unknown/incomplete generations rejected. Native: none. Rollback: unreferenced generated objects GC-ineligible until explicit later policy. Risk: MEDIUM.

### SLICE-4 — Activation and rollback, fake then Linux

Value: generation-atomic durable activation/rollback on Linux. Excludes other native platforms. Packages: state, lifecycle, journal, internal/platform/linux. Requirements: GEN-002, SELECTOR-001, ROLLBACK-001, RECOVERY-001. Tests: 3,5,6,9,13,17. Entry: SLICE-3 and native durability proof. Exit: fault matrix proves old/new selector only and recovery. Native: Linux. Rollback: publish prior verified generation selector. Risk: HIGH.

### SLICE-5 — Run pins, leases and safe GC

Value: processing binds exactly one generation and safe storage can be reclaimed. Packages: runpin, lease, gc. Requirements: PIN/LEASE/GC requirements and FAIL-005/007/008. Tests: 1,5,13-15. Entry: stable activation. Exit: unknown/suspected references always keep data and count+age rules pass. Native: Linux process identity. Rollback: disable collection, retain bytes. Risk: HIGH.

### SLICE-6 — Trust, signatures and offline catalog state

Value: locally testable official/user trust, revocation and monotone offline state. Excludes signing/private keys/network fetch. Packages: trust, signature, revocation, catalog. Requirements: all TRUST/SIGN/REVOKE/OFFLINE/CATALOG-SEC/INTERACTION. Tests: 2,7,9,13,17. Entry: JCS vectors and dependency review. Exit: policy verifier suite and interaction matrix pass. Native: none. Rollback: preserve last accepted trust evidence; block mutation. Risk: HIGH.

### SLICE-7 — Windows and macOS activation adapters

Value: same activation contract on remaining targets. Packages: internal/platform/windows and darwin. Requirements: PLATFORM-001, SELECTOR/RECOVERY. Tests: 3,5,6,13,17. Entry: SLICE-4 semantics frozen. Exit: native durability/identity matrices green. Native: Windows x86_64, macOS arm64/x86_64. Rollback: platform capability disabled; state preserved. Risk: HIGH.

### SLICE-8 — Viewmodel and read-only consumer

Value: stable manager status/readiness/action projection with pin handoff. Excludes consumer writes. Packages: viewmodel, diagnostics, read-only transport. Requirements: UI-001, PIN-001, ERROR/CLAIM/CASE. Tests: 9,11,12,17. Entry: pinning and viewmodel transport selected. Exit: stale/unavailable/mixed-generation fixtures fail closed. Native: consumer-supported targets. Rollback: consumer reports unavailable. Risk: MEDIUM.

### SLICE-9 — Install/repair commands and helper protocol

Value: bounded privileged operations with recovery. Excludes generic elevation/shell. Packages: internal/app, helperprotocol, internal/helper. Requirements: HELPER-001, PLATFORM-001, RECOVERY-001. Tests: 5,6,9,10,13,17. Entry: helper transport/auth threat review. Exit: allowlist, replay, confinement and crash tests green. Native: all targets. Rollback: disable helper mutation and recover journal. Risk: HIGH.

### SLICE-10 — Installer integration and seven-flow readiness

Value: deployable manager and readiness for Normal Stems, 6-Stem, Direct Kit, Kit Split, Vocals HQ, De-Reverb and Vocal De-Reverb. Excludes UI expansion/release until gates pass. Packages: transport/packaging integration only. Requirements: CORE/COMP/MODEL/UI/PLATFORM. Tests: 8,12,16,17. Entry: prior slices and installer authorization. Exit: all 18 CI gates and seven flow fixtures green. Native: all target OS/architectures. Rollback: installer rollback preserves active/rollback generations. Risk: HIGH.

For every slice: IMPLEMENTATION_AUTHORIZED_IN_THIS_TASK=no.

VERTICAL_SLICE_COUNT=11

FIRST_IMPLEMENTABLE_SLICE=SLICE-0

FIRST_SLICE_DEPENDENCY_COUNT=0

FIRST_SLICE_NATIVE_REQUIREMENT=none; cross-platform compile only

SLICE_ORDER_STATUS=RESOLVED
