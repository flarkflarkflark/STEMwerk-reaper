# Windows selector durability contract and Rust fix

## Evidence basis

Native Windows Rust run
[29794395506](https://github.com/flarkflarkflark/STEMwerk-reaper/actions/runs/29794395506)
completed 18/18 diagnostic probes. Selector file `sync_all` and native
`FlushFileBuffers` succeeded. A read-only directory handle failed both calls
with Win32 error 5. A directory handle opened with `GENERIC_WRITE` and
`FILE_FLAG_BACKUP_SEMANTICS` opened and flushed successfully, including after
selector replacement. The process-crash probes preserved the old selector
before replacement and the new selector after replacement.

Microsoft documents that `FlushFileBuffers` requires a handle with write
access and that `FILE_FLAG_BACKUP_SEMANTICS` is required to obtain a directory
handle. It does not document this use as equivalent to POSIX parent-directory
`fsync`. `MOVEFILE_WRITE_THROUGH` documents flushing for the copy/delete move
path, and `ReplaceFileW` documents no durability guarantee. The diagnostic run
therefore proves process-crash behavior, not OS-crash or power-loss durability.

Primary sources:

- <https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew>
- <https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-flushfilebuffers>
- <https://learn.microsoft.com/en-us/windows/win32/fileio/obtaining-a-handle-to-a-directory>
- <https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw>
- <https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew>
- <https://doc.rust-lang.org/std/os/windows/fs/trait.OpenOptionsExt.html>

## Approved POA-0 contract

The platform-neutral generation, selector validity, run-pinning, rollback, and
recovery requirements remain unchanged. POSIX continues to require selector
file flush, same-filesystem replacement, and parent-directory `fsync`, with
every failure fatal.

Windows requires all of the following; none is optional:

- selector temporary-file flush through a write-capable handle;
- one native same-volume selector replacement;
- parent-directory open with `GENERIC_WRITE` and
  `FILE_FLAG_BACKUP_SEMANTICS`;
- parent-directory `FlushFileBuffers`;
- fatal handling of every open, write, flush, and replacement error;
- native process-crash selector-consistency validation;
- startup and recovery revalidation of selector and generation.

The contract does not claim POSIX-equivalent directory-entry OS-crash
durability, power-loss durability, undocumented same-volume
`MOVEFILE_WRITE_THROUGH` durability, or `ReplaceFileW` durability. This is not
best-effort behavior: every listed operation and validation remains mandatory.

## Rust implementation

The POA-only Windows helper now opens the parent with access
`GENERIC_WRITE`, share mode
`FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE`, disposition
`OPEN_EXISTING` through Rust `OpenOptions`, and create flag
`FILE_FLAG_BACKUP_SEMANTICS`. A Windows-only wrapper calls
`FlushFileBuffers`, captures `GetLastError` immediately when it fails, and
returns a structured `io::Error`. The owned `File` closes its handle on both
success and error return. Activation can return success only after this flush.

Selector serialization, selector file flush, `fs::rename` replacement,
generation construction, run pinning, leases, recovery validation, and every
non-Windows path are unchanged. No fallback, error suppression, subprocess,
PowerShell route, retry loop, extra write-through flag, or dependency was
added.

## Local verification

- `cargo fmt --check`, `cargo check`, `cargo test`, and clippy: PASS.
- Rust unit tests: 24/24.
- Windows GNU target check and clippy: PASS; this is compile evidence only.
- Rust common/lease/Linux: 24/24, 10/10, 4/4; mixed visibility 0.
- Go common/lease/Linux: 24/24, 10/10, 4/4; mixed visibility 0.
- Verifier policy guards: 20/20.
- Fixtures, expectations, schemas, cases, fault injections, Go source, and the
  frozen manifest are unchanged.

This remains POA-only. A targeted native Windows Rust rerun of CMN-001 and
CMN-008 is required. No OS-crash or power-loss guarantee is asserted.
