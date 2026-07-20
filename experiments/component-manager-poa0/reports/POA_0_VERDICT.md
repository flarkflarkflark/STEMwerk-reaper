# Component Manager POA-0 verdict

## Basis and scope

`origin/main` was `d22e67e36b3d0b4ef014dbfa91a4f6ad8541708a` after fetch. PR #107
was open and draft, with remote head
`bfe9076f90cd9b4982fabf765e0c779a65e74c74`; that head was selected because
it contains only the current 2.4 scope document above confirmed main. This
disposable branch contains no product, installer, runtime, release, or workflow
changes.

Linux toolchains: Rust 1.95.0, Cargo 1.95.0, Go 1.26.5-X, Git 2.55.0, GCC
16.1.1. The worktree is on ext4 with 22,698,520,576 free bytes at preflight.
No Windows cross-toolchain or macOS SDK was present.

## Evidence

Rust and Go both implement the same eight-command fixture CLI and consume the
same catalog and seven schemas. The 20-case harness passed 20/20 for each
implementation. It proved dependency closure, pre-materialization SHA256,
advisory-read-only component directories, immutable receipts, generation-level
activation, rollback by changing only `state/active`, projection rebuild from
receipts/generations, structured failures, cancellation, deterministic crash
boundaries, recovery, a mutation lock, and JSON-only stdout.

The active selector uses a flushed `active.tmp` and same-volume rename. The
reader matrix observed `MIXED_COMPONENT_VISIBILITY_COUNT=0`. A run resolves
active once, writes a generation lease, emits two stages using that same
generation while a concurrent install changes active, and removes its lease on
normal exit. The harness confirms a would-be GC must stop while that lease is
present; POA-0 intentionally exposes no GC command.

SQLite/WAL contains only inventory, ownership, consumers, generation history,
and operation metadata. `desired.json` and `settings.json` remain outside it.
Quarantining `state.db` and running `state-rebuild` restored two inventory rows
without reinstalling artifacts. A missing `desired.json`, receipt drift, and
artifact drift fail closed.

## Architecture assessment

- Option B: supported locally, pending native filesystem evidence.
- Receipts: supported, with the caveat that filesystem read-only flags are
  advisory and cryptographic drift checks remain essential.
- Rebuildable SQLite projection plus external desired/settings: supported.
- Generation activation and single active-file primitive: supported on ext4.
- Lease/run pinning: supported locally; stale-lease expiry policy is not yet a
  Contract v1 decision.
- REAPER viewmodel-only boundary: architecturally consistent but not exercised;
  no REAPER code exists in this POA.

The architecture needs one revision before Contract v1: production candidates
must embed SQLite and use real JSON/schema libraries rather than depend on
`sqlite3`, `sha256sum`, or manual parsing. That is a POA implementation
limitation, not a falsification of generation-level activation.

## Platform and language verdict

Go cross-compiles from Linux to Windows amd64 and macOS amd64/arm64. Those
outputs were not executed. Rust cross-builds were unavailable because no
cross-targets/toolchains were installed. Native Windows, macOS Intel, and macOS
arm64 tests remain NOT_RUN. Output inspection shows Rust dynamically links
glibc/libgcc and Go is statically linked, but external process dependencies
mean neither is self-contained.

Both languages are locally viable. Rust leads local binary/RSS/build metrics;
Go has easier standard-library JSON/SHA ergonomics and exposed one Windows
crashhook portability fix. The objective preliminary preference is `none`.
`FINAL_LANGUAGE_DECISION=pending_native_ci`.

## Blockers and next step

Before Contract v1: run the unchanged behavioral contract natively on Windows
NTFS, macOS Intel APFS, and macOS arm64 APFS; define stale-lease recovery;
replace external process/manual-JSON shortcuts in any production
reimplementation; and decide whether Windows exit-137 fault injection is an
adequate crash proxy under Defender. Then review schemas explicitly and choose
a language using native evidence. Do not copy this POA into product code.

## Native transport addendum

The experimental branch now freezes fixtures, schemas, source/harness tree
hashes, expected semantic results, 24 common native case IDs, and a formal
stale-lease policy. A dedicated workflow targets Linux x86_64, Windows x86_64,
macOS Intel x86_64, and macOS arm64 with native architecture/filesystem gates.
The authoritative experiment commit and run ID are recorded by `GITHUB_SHA`
and `GITHUB_RUN_ID` in each uploaded job report. Language status remains
`pending_native_ci`; this addendum does not rewrite the original Linux result.
