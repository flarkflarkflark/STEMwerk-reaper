# STEMwerk 2.4.0 Runtime and Payload Handoff

This document is the implementation handoff from the cancelled 2.3.0.5 release
line. It is sufficient context for beginning the 2.4 runtime/payload work; it
does not authorize changes on the closed 2.3.0.5 line.

## Baseline

```text
BASE_MAIN_SHA=b991b3347ae548d1b5a7ea6274d0ee68dfd768db
SOURCE_RELEASE_LINE=cancelled-2.3.0.5
TARGET_RELEASE=2.4.0
```

## Linux optional DrumSep runtime policy

`DRUMSEP_OPTIONAL_RUNTIME_REPAIR_POLICY=preserve_only`

Normal Linux Repair no longer creates or rebuilds the optional CPU or ROCm
DrumSep sibling runtime. Setup can create an absent sibling through its explicit
Drum Kit runtime action, and the same user-facing action is required to rebuild
an existing consistent sibling. Missing, inconsistent, failed, or incomplete
sibling state is reported without automatic mutation.

Recommended local start branch:
`feature/2.4-runtime-payload-unification`.

## Already implemented

- Shared compatibility-config asset and shared contract JSON.
- macOS and Windows materializers.
- Windows payload integration.
- Canonical checkpoint in-memory catalog adapter.
- Alias compatibility with fail-closed behavior.
- Linux shell-hygiene fix.
- Test-harness portability fixes.

These implementations are the preserved baseline, not permission to publish a
2.3.0.5 release.

## Missing work

- Linux distribution of the canonical asset.
- Linux online and offline payload inventory coverage.
- An atomic Linux materializer.
- Linux migration tests.
- A complete cross-platform candidate rebuild and qualification.

The materializer contract must distinguish four cases:

| Input state | Required result |
| --- | --- |
| Missing | Create from the officially bundled canonical source |
| Canonical | No-op |
| Exact known legacy | Migrate atomically to canonical |
| Unknown checksum | Fail closed without overwrite |

## Do not reverse

- Do not pin NumPy below 2.4.
- Do not copy aliases during processing.
- Do not introduce duplicate canonical assets.
- Do not overwrite an unknown checksum.
- Do not add a network fallback.
- Do not use ReaPack-only Apple Silicon Repair when a bundled payload is
  required.
- Do not activate Vocals HQ before 2.4 contract validation.
- Do not activate model-registry-v2 before 2.4 contract validation.

## Required 2.4 validation matrix

### Static and contract checks

- [ ] Shared asset has one canonical owner and verified size/checksum.
- [ ] Platform stages, builders, inventories, and audits agree.
- [ ] Missing, canonical, exact-legacy, and unknown-checksum cases pass.
- [ ] ReaPack/package/installer skew produces actionable diagnostics.

### Installation lifecycle

- [ ] Clean install passes on every supported platform/package family.
- [ ] Upgrade from the supported 2.3 baseline passes.
- [ ] Same-version Repair converges idempotently.
- [ ] No-network install/Repair behavior passes where an offline payload is
  promised.

### Immutability and failure behavior

- [ ] Runtime remains unchanged during processing.
- [ ] Models remain unchanged during processing.
- [ ] No processing-time alias copy occurs.
- [ ] Unknown config content fails closed without mutation.
- [ ] No unapproved network fallback occurs.

### Platform and device coverage

- [ ] macOS Apple Silicon: CPU and MPS.
- [ ] macOS Intel: CPU and explicit DrumSep support policy.
- [ ] Windows: CPU offline, DirectML, and NVIDIA CUDA.
- [ ] Linux: CPU online/offline, AMD ROCm, and NVIDIA CUDA.
- [ ] Normal stems, Direct Kit, and Kit Split are exercised wherever supported.

## First 2.4 work package

1. Create a new 2.4 feature branch from `b991b334`.
2. Inventory every platform payload.
3. Design one shared asset inventory.
4. Add Linux distribution of the canonical asset.
5. Implement the Linux materializer.
6. Test Linux CPU and ROCm.
7. Test Linux NVIDIA.
8. Requalify Windows and macOS.
9. Only then consider features such as Vocals HQ and model-registry-v2.

The first package is complete only when the full matrix above is backed by a
candidate built from one frozen commit/build ID.
