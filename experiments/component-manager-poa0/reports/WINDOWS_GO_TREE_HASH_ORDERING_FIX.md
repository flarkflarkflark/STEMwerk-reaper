# POA-0 Windows Go frozen tree-hash ordering fix

## Trigger and scope

Full native matrix run `29840616530` used governance head
`5701409309ef17f33550431405d93c2d9f1762ce`. Both Windows jobs passed the
strict change-policy and Rust-tree checks, then stopped at `Go tree drift`
before build or case execution. The expected Go-tree hash is
`4c2f0fd99d5987b565080091c01f4f90d60a920e9d353cfcd4b39b233aecb9ab`.
Reproduction of the pre-fix Windows pipeline gives
`1784e91787fb597745377f31ab38b8a81f6fdace8ddeb654b8afeb34134d16a9`.

This change treats only that Windows ordering mismatch. The independent macOS
`MAC-001` filesystem-probe failure remains out of scope.

## Canonical generator contract

`scripts/generate-frozen-manifest.sh` recursively enumerates regular files,
excludes `Cargo.lock`, hashes exact file bytes with SHA-256, orders paths using
`LC_ALL=C`, and hashes UTF-8 records formatted as
`<sha256><two spaces><relative path><LF>`. Relative paths use `/`; file modes
do not contribute. The Unix strict verifier implements the same contract and
reproduces the frozen Go hash. An independent Git-object reconstruction also
reproduces it. Neither generator nor frozen manifest is changed here.

All nine current Go paths are ASCII. Therefore .NET ordinal, case-sensitive,
culture-independent string ordering is byte-for-byte equivalent to the
generator's UTF-8 byte order for this frozen pathset.

## First divergent record

The first divergence is one-based record index 5. Both lists have `main.go` at
index 4. The reference list then contains:

```text
114c2d9277c72124e8d16d03a7a36e3a026f183131359afde78edc6fded26de7  process_identity_darwin.go
a313688f8b2843a27d9baa52918f4d7e194705e6246e44fd8a57887205d57054  process_identity_darwin_test.go
```

The pre-fix Windows list reverses those two records. It likewise puts
`syncdir_windows_test.go` before `syncdir_windows.go`. There are no missing,
extra, duplicate or non-ASCII paths and no file-hash or file-byte differences.
The divergent character class is underscore versus dot in otherwise identical
ASCII prefixes.

## Root cause and minimal fix

The pre-fix PowerShell verifier sorted absolute `FullName` values through
`Sort-Object FullName -CaseSensitive`, whose comparer remains culture-aware;
it normalized relative separators only after sorting. Under `en-US`, `nl-NL`
and `tr-TR`, that pipeline reproducibly yields the same incorrect
`1784e917...` hash.

The fix normalizes relative paths to `/` before ordering, rejects duplicate
normalized paths, and calls `[Array]::Sort` with
`[StringComparer]::Ordinal`. File enumeration, exclusions, exact-byte SHA-256,
two-space record format, UTF-8 without BOM, final LF and fail-closed hash
comparison remain unchanged.

## Regression evidence

The bounded PowerShell regression suite contains twenty guards: current Go
reference matching, reversed enumeration, case, underscore, hyphen, digits,
nested paths, separator normalization, `en-US`, `nl-NL`, `tr-TR`, missing and
extra files, byte and path drift, duplicate normalized paths, LF-only records,
unchanged manifest SHA, unchanged Rust hash and unchanged harness hash.

The isolated `windows-tree-verifier` workflow mode runs exactly those guards
and the complete strict frozen verifier on one Windows runner without building
either implementation or executing cases. It uploads reference and Windows
record lists, normalized paths, per-file hashes, a domain summary and errors.
Native Windows verification is required before this blocker can be closed.
