# Windows Rust in-process SHA-256 fix

## Scope and root cause

This is an experimental, disposable POA-0-only Rust implementation fix. It is
not production code and does not select a final implementation language.

Windows diagnostic run
[29779476144](https://github.com/flarkflarkflark/STEMwerk-reaper/actions/runs/29779476144)
proved that native file copying, paths containing spaces, Unicode paths, and
path translation all worked. Rust then stopped before `artifact_verified`
because Windows PowerShell 5.1 did not expose `Get-FileHash`; the external
command exited 1 with `CommandNotFoundException`. The bounded evidence is in
artifacts [CMN-001](https://github.com/flarkflarkflark/STEMwerk-reaper/actions/runs/29779476144/artifacts/8476005971)
and [CMN-008](https://github.com/flarkflarkflark/STEMwerk-reaper/actions/runs/29779476144/artifacts/8476006593).

## Implementation

The Rust POA now uses `sha2` 0.11.0 from RustCrypto with default features
disabled. The crate is pure Rust, licensed `MIT OR Apache-2.0`, has MSRV 1.85,
and is compatible with the workflow's pinned Rust 1.97. It requires no native
library, OpenSSL, shell, subprocess, PowerShell, or runtime network access.

`sha256_file` opens the input with `std::fs::File` and feeds a `BufReader` into
an incremental `Sha256` hasher through a fixed 16 KiB buffer. Only the 32-byte
digest is converted to an exact 64-character lowercase hexadecimal string.
There is no whole-file buffering, temporary hash copy, platform branch, or
fallback executable.

Hash open and read errors enter the existing result envelope and journal as
`HASH_OPEN_FAILED` and `HASH_READ_FAILED`, with the affected path and I/O cause.
Mismatch remains fail-closed and structured under the frozen existing
`CHECKSUM_MISMATCH` code so expected-results fixtures do not change. All paths
exit nonzero through the existing command error path.

## Regression and dependency evidence

- Rust SHA implementation tests: 13/13 PASS, covering known and empty digests,
  binary bytes, space and Unicode paths, missing and directory inputs, exact
  lowercase formatting, fail-closed mismatch, injected read failure, a file
  larger than the streaming buffer, and absence of hash subprocesses.
- `cargo fmt --check`, `cargo check`, `cargo test`, and
  `cargo clippy -- -D warnings`: PASS.
- Dependency tree: `sha2`, `digest`, `block-buffer`, `crypto-common`,
  `hybrid-array`, `typenum`, `cfg-if`, and `cpufeatures`; zero native build,
  OpenSSL, shell, or PowerShell dependencies.
- Local Rust native regression: common/filter 24/24, lease 10/10, Linux
  platform 4/4, mixed-generation visibility 0.
- Local Go native regression: common/filter 24/24, lease 10/10, Linux platform
  4/4, mixed-generation visibility 0.

The case IDs and case source, expected-results tree, fixtures, schemas, Go
source, frozen manifest, fault injections, CMN-001/CMN-008 expectations, other
native expectations, and harness semantics are unchanged. The only workflow
change is the exact commit-message push guard needed to prevent the fix push
from starting the forbidden full eight-job matrix; the existing bounded
Windows Rust `CMN-001,CMN-008` diagnostic selection is otherwise unchanged.
