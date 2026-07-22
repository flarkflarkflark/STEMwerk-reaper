# POA-0 x86_64 Darwin statfs ABI binding fix

## Evidence and root cause

Isolated run `29924132859` executed strict frozen verification successfully in
all four `MAC-001` jobs. arm64 Rust (`88936820338`) and Go (`88936820392`)
decoded APFS metadata and passed every operational probe step. Intel Rust
(`88936820516`) and Go (`88936820353`) failed before mutation: `statfs` returned
zero, but filesystem and mount strings decoded empty and `mount_flags` equaled
the recorded device identifier.

Apple's `sys/mount.h` defines two ABIs on Darwin targets that retain legacy
inode compatibility:

- legacy `struct statfs`: 336 bytes on LP64 x86_64, with 15-byte filesystem
  name and 90-byte mount names;
- `__DARWIN_STRUCT_STATFS64`: 2168 bytes, alignment 8, with filesystem type at
  offset 72, mount-on at 88, mount-from at 1112, 16-byte filesystem type and
  1024-byte mount names.

The compiler redirects an x86_64 source call using the modern structure to
`statfs$INODE64`. The ctypes adapter bypassed that compile-time redirection and
looked up bare `statfs`, but supplied the 2168-byte modern structure. The
legacy function wrote its `f_fsid` at offset 64, where the modern structure
expects `f_flags`, explaining why the observed flag value equaled `st_dev`.
The modern string area begins at offset 72, which contains zeroed legacy scalar
fields, explaining all three empty strings. The root cause is therefore
`WRONG_STATFS_SYMBOL_BINDING`, HIGH confidence; it is not a filesystem or
component-manager capability failure.

The source of truth is Apple's exported `sys/mount.h`. The isolated native run
compiles `macos-statfs-layout.c` against each runner's installed macOS SDK and
records the exact SDK path/version, native size/alignment/offsets, compiler-
selected symbol, return code, errno, decoded metadata, and raw bytes around the
three string fields.

## Minimal fix

The adapter now models the complete modern structure, including `f_flags_ext`
and seven reserved words. It keeps `statfs` on arm64 and selects
`statfs$INODE64` only for x86_64, with prototype
`int(const char *, struct statfs *)`, explicit ctypes argument/return types,
zero-initialized storage, and immediate errno capture after a nonzero return.
Required filesystem type, mount-on, and mount-from strings must all be nonempty.
No subprocess, shell-output parser, runner-name branch, filesystem hardcode,
skip, or fallback-to-PASS was added.

The arm64 call path, size, alignment, relevant offsets, decoding, and capability
sequence remain unchanged. Only x86_64 symbol resolution changes functionally.
The `MAC-001` case source, `apfs-active-replace` expectation, same-volume check,
file flush, replacement, directory open/fsync, observation, cleanup, and
fail-closed behavior are unchanged.

## Test-first proof and rerun boundary

Before implementation, all 20 new ABI guards failed because the explicit ABI
model and binding functions did not exist. After the fix, 20/20 pass, covering
the legacy x86_64 reproduction; both architecture sizes, alignments and offsets;
MFSNAMELEN/MNAMELEN; NUL and full-field decoding; empty-field rejection;
return/errno handling; arm64 and x86_64 APFS decoding; Unicode and space-bearing
mount names; and absence of a shell fallback. The original 20 capability tests
also remain green.

Workflow mode `macos-mac001` remains a fixed four-job, one-case diagnostic with
strict verification before execution. Its native C layout artifact and ctypes
layout artifact must match before the filesystem operation begins. No full
eight-job matrix is authorized in this change.
