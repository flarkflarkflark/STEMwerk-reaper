# STEMwerk 2.4 Linux DrumSep Asset Distribution

## Status and scope

Status: accepted contract-first design for the first Linux implementation PR.
This decision defines distribution and materialization obligations; it does not
implement or publish a payload, bootstrap, installer, or release.

## Decision

The only canonical source is
`tools/assets/drumsep/config_drumsep_mdx23c.yaml`, governed by
`tools/assets/drumsep/compatibility_config_contract.json`. Its canonical bytes
are 2331 bytes, SHA-256 `b7165bb73a0b08df49ac4ed5fe7424e29bf2f707b5878300f729a7e92671257a`,
with 86 LF and zero CR bytes. No platform may maintain a second source copy.

Linux receives those exact bytes through two channel families:

1. `online-minimal` must explicitly distribute the asset. Prefer adding it as a
   ReaPack source so a ReaPack-only installation has a local audited source. If
   that is incompatible with the package layout, the online stage must carry it
   and a ReaPack-only installation must report `payload-required` before any
   mutation. A repository-only path is never a valid end-user source.
2. `offline-bundled-cpu-allmodels`, `offline-bundled-rocm-allmodels`, and
   `offline-bundled-cuda-allmodels` must bundle the same canonical bytes in
   their local payload.

After staging, every channel exposes the source below the installed STEMwerk
tree in one platform-defined bundled compatibility-asset location. The Linux
bootstrap resolves that installed local location; it must never read the source
from a development checkout and must never download the config at runtime.

## Closed-world inventory and audit

One shared asset inventory maps the contract filename, role, size, SHA-256, and
newline policy into every Linux variant. Builders copy from the canonical repo
asset and inventories record the resulting bytes. Audits are closed-world:
missing, duplicate, unexpected, differently sized, differently hashed, or
wrong-newline files fail the builder/release gate. The online audit covers the
ReaPack or staged source as well as its installed destination; each offline
audit covers its variant manifest and staged filesystem.

The release gate must enumerate all four Linux variants and the Linux
materializer entrypoint. It may not infer compliance merely because the shared
asset exists in the repository.

## Materialization state table

The Linux bootstrap reads only the locally installed, checksum-audited source.
It applies this exact behavior:

| Destination state | Required action |
| --- | --- |
| Missing | Copy to a sibling temporary file, verify it, then atomically create the destination. |
| Canonical | Return success without rewriting the destination. |
| Exact legacy CRLF (`17d1649…`, 2417 bytes) | Copy canonical bytes to a sibling temporary file, verify, then atomically replace. |
| Any other checksum or size | Fail closed and leave the destination unchanged. |

Temporary-copy and final-destination fingerprints must be verified. Failure to
copy, verify, or atomically replace leaves the previous destination intact and
returns a diagnostic status. No state permits a network fallback.

## Required implementation validation

- Clean install: source and destination are inventoried; missing becomes
  canonical without network access.
- Upgrade: the exact legacy CRLF file migrates atomically; unknown bytes remain
  untouched and fail closed.
- Same-version Repair: canonical is a byte- and mtime-preserving no-op.
- A-to-B: only the compatibility config changes from exact legacy to canonical.
- B-to-C: a second run is empty and model/runtime inventories are immutable.
- Normal stems, Direct Kit, and Kit Split pass on native Linux CPU/ROCm where
  supported; offline and no-network promises are tested independently.

Scripts/runtime skew is prevented by versioning the asset obligation with the
shared contract, auditing both scripts and the local payload before mutation,
and returning an actionable `payload-required` or `runtime-older-than-scripts`
status when the installed runtime cannot satisfy the current scripts.

## Early Linux NVIDIA validation

Book a Linux NVIDIA cloud GPU early in the 2.4 cycle, before candidate freeze.
Run S1/S2 smokes, normal stems, Direct Kit, Kit Split, the offline NVIDIA/CUDA
payload, and no-network validation. Capture A-to-B and B-to-C filesystem
inventories and verify CUDA runtime/helper isolation. Qualification must execute
the current candidate and inspect its generated bundle; grep-only conclusions
from historical bundles are not evidence.

## Incremental delivery

The first implementation PR should make the online path and Linux materializer
conform, with native ROCm Repair/convergence proof. Offline CPU, ROCm, and
NVIDIA/CUDA payload distribution may follow in separate PRs so each inventory
and artifact family can be reviewed and validated independently. Registry-v2,
Vocals HQ, and runtime unification remain outside this workstream.
