# Test architecture and future CI gates

## Test layers

1. Pure domain unit/property tests
2. JSON Schema conformance and negative fixtures
3. Storage implementation contract tests
4. SQLite rebuild and migration tests
5. Filesystem fault injection
6. Platform adapter shared/native tests
7. Trust/signature/canonicalization public test vectors
8. Compatibility target/flow matrix
9. Command/application orchestration tests
10. Helper protocol validation/auth/replay tests
11. Viewmodel contract/golden tests
12. Consumer fixtures without consumer runtime
13. Crash/recovery phase tests
14. Lease/process-ID-reuse tests
15. GC safety/property tests
16. Installer smoke tests
17. End-to-end vertical-slice tests

TEST_LAYER_COUNT=17

PURE_UNIT_TEST_SCOPE=identity/version/digest/canonicalization values, immutable aggregate invariants, compatibility, trust/revocation policy, leases, pins and GC with no I/O

CONTRACT_TEST_SCOPE=all 21 schemas, positive/negative fixtures, generated-binding drift, store/adapter/helper/viewmodel interfaces and application error/idempotency semantics

PLATFORM_NATIVE_TEST_SCOPE=durable replace and directory flush, no-follow/reparse handling, permissions/ACLs, process-start identity and helper identity on real Linux x86_64, Windows x86_64, macOS arm64 and macOS x86_64 where supported

FAULT_INJECTION_SCOPE=short writes, fsync/rename/parent-sync failure, changed identity, disk full, permission denied, crash at every journal boundary, SQLite busy/corruption and helper timeout/replay

FAKE_INTERFACE_COUNT=8

REAL_NATIVE_RUNNERS_REQUIRED=Linux x86_64, Windows x86_64, macOS arm64 and macOS Intel x86_64 before the adapter or release gate that claims each target; SLICE-0 requires none

TEST_ARCHITECTURE_STATUS=RESOLVED

Deterministic fakes are Clock, Filesystem, ProcessProbe, DigestVerifier, SignatureVerifier, CatalogSource, HelperClient and RandomSource.

## CI gate schedule

| # | Gate | First mandatory |
|---:|---|---|
| 1 | gofmt, go vet, go test | SLICE-0 |
| 2 | static analysis | SLICE-0 |
| 3 | dependency vulnerability audit | SLICE-0 when first dependency enters |
| 4 | license audit | SLICE-0 when first dependency enters |
| 5 | schema validation | SLICE-0 |
| 6 | generated-code drift | SLICE-0 after generator selection |
| 7 | unit tests | SLICE-0 |
| 8 | contract tests | SLICE-0 |
| 9 | cross-platform compile | SLICE-0 |
| 10 | native adapter tests | SLICE-4 then expanded SLICE-7 |
| 11 | deterministic artifact comparison | SLICE-2 |
| 12 | SBOM generation/validation | SLICE-2 |
| 13 | signing verification | SLICE-6 |
| 14 | installer smoke | SLICE-10 |
| 15 | consumer integration smoke | SLICE-8 |
| 16 | migration compatibility | SLICE-2 |
| 17 | rollback/recovery | SLICE-4 |
| 18 | release provenance | pre-release after SLICE-10 |

CI_GATE_COUNT=18

SLICE_1_REQUIRED_GATES=gofmt/vet/test, static analysis, dependency/license audit when applicable, schema validation, generated drift, unit, contract and cross-platform compile

PRE_BETA_REQUIRED_GATES=1-13 plus migration and rollback/recovery, all claimed native adapters green

PRE_RELEASE_REQUIRED_GATES=all 18 gates including installer and consumer smoke, SBOM and provenance

NATIVE_RUNNER_REQUIREMENTS=hosted/self-hosted runners must prove actual OS/architecture; no emulation substitutes for durability or identity claims

REPRODUCIBLE_BUILD_POLICY=pinned Go/tool/dependency versions, immutable lock/checksum inputs, offline generation, SOURCE_DATE_EPOCH-style normalized metadata where applicable and two clean-build artifact digests compared

SBOM_POLICY=generate CycloneDX or SPDX for module, tools and bundled native/helper/installer artifacts; sign/attest it with release provenance and fail on unreviewed drift

DEPENDENCY_POLICY=DEPENDENCY_POLICY.md is mandatory; frozen/checksummed resolution, license/provenance/advisory review and install scripts/network disabled by default

CI_GATE_PLAN_STATUS=RESOLVED

This task adds no release workflow. A documentation-only push classification suppresses the existing POA native matrix without changing future normal push or manual-dispatch semantics.
