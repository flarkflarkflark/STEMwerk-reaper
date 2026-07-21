# Windows selector durability primitive diagnostic plan

## Evidence basis and unchanged contract

Targeted run `29791206769` proved that selector temp write/flush, selector
replace, and parent-directory open with `FILE_FLAG_BACKUP_SEMANTICS` succeed.
The unchanged `File::sync_all()` on that read-only directory handle returns
Win32 error 5. This plan diagnoses that boundary without changing production
selection, durability, expectations, or contract.

The frozen POA contract requires crash recovery, generation-level activation,
atomic Windows/NTFS temp-write/replace, and zero mixed visibility. It does not
explicitly state a power-loss guarantee. Current implementation intent is:
selector bytes are flushed before replace; replace publishes one complete
selector atomically; parent-directory sync then attempts to durably record the
directory-entry change. CMN-001/008 exercise process-failure behavior, not a
power-loss test.

| Contract property | POSIX primitive | Current Windows primitive | Evidence |
|---|---|---|---|
| selector bytes before replace | file `fsync` | file `FlushFileBuffers` through `sync_all` | native PASS |
| atomic selector publication | same-filesystem rename | `std::fs::rename` | native PASS |
| parent entry durability | parent-directory `fsync` | directory `FlushFileBuffers` through `sync_all` | native Win32 5 |
| process-crash visibility | atomic rename plus recovery | same route | CMN-008 blocked at directory flush |
| power-loss persistence | filesystem/device dependent | no proven equivalent | not tested or claimed |

## Official documentation basis

- Microsoft `FlushFileBuffers` requires `GENERIC_WRITE` and documents an open
  file handle; it does not list directory handles as supported:
  https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-flushfilebuffers
- Microsoft directory-handle documentation requires
  `FILE_FLAG_BACKUP_SEMANTICS` and lists APIs that accept directory handles;
  `FlushFileBuffers` is absent:
  https://learn.microsoft.com/en-us/windows/win32/fileio/obtaining-a-handle-to-a-directory
- `MOVEFILE_WRITE_THROUGH` documents its flush guarantee for a move implemented
  as copy/delete, so same-volume rename durability is not established by that
  wording:
  https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw
- `REPLACEFILE_WRITE_THROUGH` is explicitly unsupported and `ReplaceFileW`
  documents replacement/metadata behavior, not a power-loss guarantee:
  https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew
- Rust `File::sync_all` attempts to synchronize file data and metadata; the
  Windows native evidence is checked directly against `FlushFileBuffers`:
  https://doc.rust-lang.org/std/fs/struct.File.html#method.sync_all

## Native probe plan and artifacts

Eighteen isolated Windows/NTFS candidates cover selector file `sync_all`, direct
`FlushFileBuffers`, ordinary and Win32 replacement APIs, read versus write
directory handles, parent flush, open/deny-share/read-only targets, new-target
and repeated rename, two crash boundaries, and post-termination selector-byte
verification. Every candidate records API, flags, source/target, return,
GetLastError, object state, selector bytes, and observed claim level.

The global `windows-selector-durability-probes` artifact and both case artifacts
preserve summary, API JSONL, activation timeline, Win32 errors, flags, selector
hashes, crash results, stdout/stderr/events, tree, and case root. Evidence is
sufficient only when native observations agree with official API scope. No
power-loss claim can be proven on the hosted runner.

This is disposable POA-only diagnostic instrumentation. It performs no
functional primitive switch, contract change, expectation change, or language
decision.
