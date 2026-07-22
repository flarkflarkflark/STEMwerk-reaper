# POA-0 macOS MAC-001 filesystem probe fix

## Scope and source evidence

This bounded change investigates only `MAC-001` from full native matrix run
`29840616530`. The frozen case source remains
`harness/platform-tests.sh`, case name `apfs-active-replace`. The contract in
`NATIVE_MATRIX_CONTRACT.md` requires a flushed selector file, same-filesystem
rename/replacement, and parent-directory fsync; every failure is fatal.

All four failures had the same execution path. Strict frozen verification,
the common matrix (24/24), and the lease matrix (10/10) passed before the
platform script stopped at its first case:

| Job | Runner selector / image | Native route | Result artifact |
|---|---|---|---|
| `88668316360` macOS Intel x86_64 rust native | `macos-15-intel` / `macos-15` `20260715.0340.1` | x86_64 Rust | only `MAC-001 FAIL apfs-active-replace` |
| `88668316224` macOS Intel x86_64 go native | `macos-15-intel` / `macos-15` `20260715.0340.1` | x86_64 Go | only `MAC-001 FAIL apfs-active-replace` |
| `88668316226` macOS Apple Silicon arm64 rust native | `macos-15` / `macos-15-arm64` `20260715.0234.1` | arm64 Rust | only `MAC-001 FAIL apfs-active-replace` |
| `88668316223` macOS Apple Silicon arm64 go native | `macos-15` / `macos-15-arm64` `20260715.0234.1` | arm64 Go | only `MAC-001 FAIL apfs-active-replace` |

Every runner used macOS 15.7.7 (24G720), workspace
`/Users/runner/work/STEMwerk-reaper/STEMwerk-reaper`, and runner temp root
`/Users/runner/work/_temp`. The old artifacts did not record native mount
metadata or syscall errno. Their `platform-info.txt` reported `FILESYSTEM=/`.

## Root cause

The primary classification is `WRONG_MACOS_FILESYSTEM_ASSUMPTION`, in the
platform-adapter layer, with HIGH confidence. On Darwin, BSD `stat -f %T PATH`
formats the file type; for the workspace directory it returned `/`. The harness
incorrectly treated that output as a filesystem type and compared it with
`apfs`. Consequently all four jobs failed identically before creating a probe
root, writing a file, calling fsync, replacing a name, opening/flushing a
directory, observing state, or cleaning probe state. There was no failing
filesystem syscall and therefore no errno. The run proves a probe bug, not a
Rust/Go limitation or absence of the required filesystem capability.

The old run cannot prove case sensitivity, Unicode normalization, hardlink,
symlink, rename, directory-fsync, mount-flag, or sandbox properties because it
performed none of those probes. Those properties are recorded as unknown until
the isolated native validation. No conclusion is inferred from the runner name.

## Minimal correction

`scripts/macos-filesystem-probe.py` is a Darwin-specific syscall adapter. It:

1. creates its root beneath the selected workspace results directory;
2. creates and writes an existing selector destination;
3. calls `fsync` on the file descriptor;
4. creates, writes, and flushes a temporary selector in that same root;
5. compares native `st_dev` values and fails with `EXDEV` on mismatch;
6. calls native rename replacement through `os.replace`;
7. opens the directory with `O_RDONLY|O_DIRECTORY` and calls `fsync`;
8. reads back the replacement and verifies the temporary name is absent;
9. removes the probe root and fails if cleanup errors or leaves it present;
10. emits summary, filesystem, mount, syscall, errno, timeline, cleanup, and
    error artifacts on both success and failure.

Darwin filesystem identity comes directly from `statfs(2)`, not a shell-output
parser or runner-name special case. Errors capture `OSError.errno` in the
immediate exception handler, all opened descriptors close in `finally` blocks,
and no error is suppressed or converted to PASS. The normal Darwin orchestrator
uses this adapter and retains the other frozen platform checks unchanged in the
macOS platform adapter. Linux, Windows, product code, core implementations,
fixtures, schemas, cases, expectations, contracts, manifest, and verifier are
unchanged.

The probe validates API availability and live operational semantics only. It
does not simulate process crash, OS crash, or power loss, and makes no
OS-crash/power-loss durability claim.

## Test-first and equality evidence

Before the adapter existed, the new 20-test suite failed at import, reproducing
the absent/correctness gap. After implementation, all 20 guards pass: legacy
failure reproduction; same/cross-volume behavior; directory open; file fsync;
replacement; directory fsync; immediate errno; cleanup success/failure;
read-only and missing-parent failures; existing destination; Unicode and spaces;
x86_64 and arm64 routes; Rust and Go routes; and unchanged expectation literal.

The frozen harness, `MAC-001` case line, expectation, top manifest and its hash,
verifier, generator, Rust tree, Go tree, expected results, fixtures, schemas,
fault injections, durability contract, lease contract, generation/recovery/run
pinning models, Windows source, and Linux source remain byte-identical to
`d76bedcb3b767d6b1821d9e6ed44a26d74751d26`.

## Isolated validation boundary

Workflow mode `macos-mac001` has a fixed `MAC-001` pool and exactly four jobs:
Intel Rust, Intel Go, Apple Silicon Rust, and Apple Silicon Go. Each performs
the complete strict frozen verification before executing only this probe and
uploads per-job evidence. The one authorized push is suppressed only when its
parent is exactly `d76bedcb3b767d6b1821d9e6ed44a26d74751d26` and every changed
path is in the explicit fix-path set. No full eight-job matrix is part of this
change. A complete normal matrix remains a separate follow-up after four-job
native PASS.
