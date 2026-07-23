# Component Manager POA-0 formal verdict

## Status

- Evidence baseline: run `29976687812`, attempt 1.
- Branch/head: `experiment/component-manager-poa0` at
  `7519ca21dba57f01c9b3b6b0cae046e511bb8f6c`.
- Matrix: 8/8 jobs and strict verifiers PASS.
- Concrete results: 326/326 PASS; zero FAIL and NOT_RUN.
- Artifact audit: 470/470 files valid.
- Selected core language: Go, confidence HIGH.
- Architecture: `APPROVED_WITH_NON_BLOCKING_CONTRACT_FOLLOWUPS`.
- Contract-v1 native gate: `READY`; blockers: none.

The corrected total is `2*38 + 2*43 + 4*41 = 326`. Independent completed,
unique-PASS-ID and selected-record counts all equal 326. Of 486 raw rows, 160
counterpart aliases are excluded. Exactly 64 timeline/probe events are not
case records. CMN-001..024 and record-derived common set equality pass in all
eight jobs; CMN-021..024 each pass 8/8.

## Fifteen-criterion language scorecard

| Criterion | Rust | Go | Outcome |
|---|---|---|---|
| Native functional correctness | PASS | PASS | tie |
| Cross-platform consistency | PASS | PASS | tie |
| Platform-native API integration | PASS | PASS | tie |
| Durability correctness | PASS | PASS | tie |
| Process-crash recovery | PASS | PASS | tie |
| Lease/process-identity correctness | PASS | PASS | tie |
| Fail-closed behavior | PASS | PASS | tie |
| Artifact and diagnostic quality | PASS | PASS | tie |
| Implementation complexity | MINOR_CONCERN | PASS | Go |
| Dependency footprint | MINOR_CONCERN | PASS | Go |
| Build simplicity | MINOR_CONCERN | PASS | Go |
| Distribution and packaging simplicity | PASS | PASS | tie |
| Maintainability | MINOR_CONCERN | PASS | Go |
| Testability | PASS | PASS | tie |
| Shared Component Manager core suitability | PASS | PASS | Go |

Rust scores 11 PASS and 4 MINOR_CONCERN; Go scores 15 PASS. Both are
functionally equivalent in the native matrix and Rust is not disqualified. Go
wins the predetermined tie-break because the POA has zero Go module
dependencies, simpler build/distribution, lower platform-separated complexity
and lower expected maintenance load. One shared Go production core is
approved; a dual-core design is not. The Rust POA remains reference evidence.
Reopening the language decision requires a separate ADR.

## Architecture and native gate

Immutable generations, generation-atomic publication, run pinning, lease
identity, rollback, recovery, rebuildable SQLite state, immutable receipts,
fail-closed integrity, component independence and concrete case records are
validated. Platform durability remains governed by explicit Windows, macOS and
Linux contracts. There are zero blocking and zero rejected criteria.

Non-blocking Contract-v1 work remains: generation compatibility policy,
precise `runtime.main` and optional `runtime.drumsep` boundaries, model policy,
catalog/viewmodel boundary, REAPER consumer integration and installer/helper
boundaries. These do not block `CONTRACT_V1_NATIVE_GATE=READY`.

## Erratum and limits

Historical pre-closure run `29934682382` correctly had 294 concrete records.
The earlier apparent 326 was a hardcoded phantom total; 328 was a manual
arithmetic error. Only run `29976687812` establishes the current corrected 326.
Targeted run `29941607856` is closure evidence only.

No OS-crash or power-loss guarantee is claimed. Evidence freeze is governance,
not Contract v1, final production schemas, product code, packaging or release.
