# Implementation Plan: Component Manager POA-0

## Architecture

- Shared declarative fixtures and schemas are authoritative for both binaries.
- Immutable component directories and generation manifests are the durable
  source; SQLite/WAL is a rebuildable projection.
- Activation is one fsynced same-volume rename of `state/active.tmp` to
  `state/active`; processing-like readers resolve it exactly once and lease the
  resolved generation.
- Deterministic POA-only fault hooks exercise recovery boundaries.

## Ordered slices

1. Contract fixtures/schemas and tests that reject absent binaries.
2. Native plan/install/verify with receipts and generation activation.
3. Rollback, rebuild, recovery, cancellation, and deterministic faults.
4. Run pinning, lease-aware GC check, concurrency, and mixed-view reader test.
5. Shared 20-case matrix, measurements, native CI design, and verdict.

## Checkpoints

- Contract: fixtures hash and validate; both builds clean.
- Lifecycle: clean/idempotent install and rollback pass for both.
- Resilience: crash/rebuild/pinning matrix passes with mixed count zero.
- Completion: reports contain evidence and hygiene checks remain scoped.

## Risks

- Linux cannot prove NTFS/APFS rename behavior: native CI remains mandatory.
- A process killed after active swap can leave SQLite stale: recovery rebuilds
  the projection from immutable manifests and receipts.
- Filesystem permissions are advisory immutability: receipt hashes detect drift.
