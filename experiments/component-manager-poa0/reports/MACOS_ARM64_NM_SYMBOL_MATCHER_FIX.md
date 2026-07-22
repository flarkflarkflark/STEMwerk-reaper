# POA-0 arm64 nm symbol evidence matcher fix

## Evidence and root cause

Run `29926117271` passed strict frozen verification in all four jobs. Intel Rust
and Go both proved `_statfs$INODE64`, matched the native SDK layout, decoded
valid APFS metadata, and passed every MAC-001 operation. arm64 Rust and Go
stopped before native layout execution and before MAC-001.

Their preserved `nm -u` output contains one undefined symbol per line without a
type prefix, including exact `_statfs`. The workflow required the tool-specific
text shape ` U _statfs$`. Apple `nm -u` therefore produced valid evidence that
the grep rejected. The primary root cause is `NM_U_OUTPUT_PREFIX_ASSUMPTION`,
in workflow orchestration, with HIGH confidence.

The old matcher also had no normalization artifact or explicit unknown-format
classification. Intel used a fixed substring search which happened to match
its raw output; arm64 used an anchored expression that required a prefix absent
from its raw output.

## Minimal normalized matcher

`test-macos-nm-symbol-matcher.py` is both the bounded runtime matcher and its
20-case regression suite. For every nonempty raw line it:

1. trims leading and trailing whitespace;
2. accepts either one symbol token or exactly `U` plus one symbol token;
3. validates the complete symbol token, rejecting comments, filenames and
   unknown token layouts;
4. compares exact tokens against `_statfs` for arm64 or `_statfs$INODE64` for
   x86_64;
5. requires exactly one match, making zero and duplicate matches fatal;
6. leaves the raw file unchanged and emits normalized symbols plus a JSON
   match summary containing the raw SHA-256.

Accepted forms include bare, padded `U`, space-separated `U`, tab-separated
`U`, LF and CRLF records. Tests reject `_statfs_extra`, `foo_statfs`,
`_statfs$INODE32`, `_statfs$INODE64_extra`, the wrong architecture's symbol,
empty evidence, defined-symbol layouts and duplicate matches. No substring
match, warning, skip or fallback-to-PASS remains.

## Equality and rerun boundary

The statfs binding, ctypes structures, native ABI helper, filesystem adapter,
MAC-001 capability and expectation, Rust, Go, Windows, Linux, harness core,
manifest, verifier, generator, fixtures, schemas, fault injections and
contracts are byte-identical to `45e69a329afda2cea3267643569c756e60541be8`.
Only workflow symbol-evidence normalization changes functionally.

The existing fixed `macos-mac001` mode remains exactly four macOS jobs and one
case, with strict verification and ABI evidence before the probe. One isolated
rerun is required. A full eight-job matrix is explicitly deferred.
