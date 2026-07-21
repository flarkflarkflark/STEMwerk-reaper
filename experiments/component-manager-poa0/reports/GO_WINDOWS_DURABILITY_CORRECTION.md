# Go Windows selector durability correction

Rust Windows is the native-validated behavioral reference: selector-file flush,
native replacement, write-capable parent-directory open, and native parent
flush all pass, including bounded process-crash recovery.

The Go root cause was `syncDir` using `os.Open(path)` followed by `Sync()` on
Windows. That produces a read-only directory handle rather than the approved
Windows durability primitive. The correction is build-tagged: Windows validates
the target is a directory, calls `CreateFileW` with `GENERIC_WRITE`, share
read/write/delete, `OPEN_EXISTING`, and `FILE_FLAG_BACKUP_SEMANTICS`, then calls
`FlushFileBuffers`. Open and flush errors remain fatal and the handle is always
closed. The non-Windows implementation remains the original `os.Open`/`Sync`.

Selector serialization, selector-file flush, `os.Rename`, activation ordering,
recovery semantics, cases, expectations, fixtures, schemas, fault injections,
contract, Rust source, and SQLite queries are unchanged. Windows-only unit tests
cover a valid directory, a missing directory, and file rejection; local and
cross-compile gates cover the native binding and fail-closed source contract.

The implementation gate is 17/17: Windows write-handle compilation, directory
flag, native flush binding, missing-directory rejection, file rejection, fatal
open and flush errors, file-flush/replace/parent-flush ordering, success only
after parent flush, handle close on success and flush failure, unchanged
non-Windows behavior, and absence of subprocess, PowerShell, retry, or silent
success in the implementation. `gofmt`, Go build/test, Windows amd64 test and
binary cross-compilation, YAML parsing, PowerShell parsing, mode isolation, and
push classification pass. The unchanged local regressions pass at matrix 40/40,
lease 10/10 per implementation, Linux 4/4 per implementation, zero mixed
visibility failures, Rust unit tests 24/24, and verifier policy 20/20.

Equality guards confirm no changes to Rust, the durability contract, case IDs or
sources, expected results, fixtures, schemas, fault injections, selector
serialization, generation/run-pinning/lease/recovery models, SQLite semantics,
the frozen manifest, verifier policy, the normal eight-job matrix, or the Rust
extended mode. Test semantics are unchanged; the added tests exercise only the
corrected implementation primitive.

Manual mode `windows-go-durability` creates one Windows Go job with fixed cases
CMN-001 and CMN-008, exact SQLite 3.53.3, the existing verifier inputs, existing
fault injection, and existing Go `recover` entrypoint. The one-use push
classifier is bounded to parent `f5788a492f415b959c5c9de861f92d3a19bb3050`
and the exact workflow, Go, and report paths. A targeted native run is required.
No OS-crash, power-loss, or POSIX-equivalent durability claim is made.
