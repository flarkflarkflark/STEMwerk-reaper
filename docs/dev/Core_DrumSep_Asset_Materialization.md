# Core DrumSep asset materialization (v1)

`stemwerk_core.asset_materialization` provides one bounded provisioning
primitive: copying Core's two pinned DrumSep model assets from explicit local
source files into a new destination directory. It verifies source and staged
bytes against `model_assets.DIRECT_DKS_MODEL_EXPECTED_SHA256` and records what
the operation created.

This is an executor building block, not a Drum Kit installer. It does not read
installation previews, discover sources, download content, install packages,
provision runtimes, load models, run inference, adopt existing content, repair,
update or remove anything. Installation previews remain informational with
`executable=false`.

## API

```python
from pathlib import Path
from stemwerk_core import model_assets
from stemwerk_core.asset_materialization import (
    MaterializationRequest,
    materialize_drumsep_assets,
    validate_drumsep_materialization,
)

request = MaterializationRequest(
    sources={
        model_assets.DIRECT_DKS_MODEL_FILENAME: Path("/absolute/input/model.ckpt"),
        model_assets.DIRECT_DKS_MODEL_YAML: Path("/absolute/input/model.yaml"),
    },
    destination=Path("/absolute/new/drumsep-assets"),
)

validation = validate_drumsep_materialization(request)  # read-only
result = materialize_drumsep_assets(request)             # validates again, then writes
```

The source mapping must contain exactly the two authoritative filenames. Hashes
are never accepted from the caller. Production validation and mutation always
use Core's existing filename/SHA-256 mapping and identify that policy as
`stemwerk_core.model_assets.DIRECT_DKS_MODEL_EXPECTED_SHA256`.

Validation requires absolute paths without `..` segments. Every existing
source and destination-parent path component must be free of symbolic links;
on Windows, reparse points such as junctions are rejected too. The
rejection covers every reparse point, including OneDrive and other cloud
placeholders and deduplicated files, so a destination (or source) under a
OneDrive-synced folder, which is often where Windows places Documents, is
refused by design rather than special-cased.
Sources must be distinct, readable regular files. The destination parent must
already exist and remain stable through the operation. On Linux and macOS it
must be owned by the current user and not be group- or world-writable. On
Windows Core does not translate POSIX mode bits into an ownership claim: the
caller supplies a non-reparse parent and the operating system enforces its
ACLs for the current process. The destination itself must not exist as any
filesystem object. Source/destination aliases are rejected.

## CLI

```bash
python -I -B -m stemwerk_core.asset_materialization \
  --checkpoint-source /absolute/input/model.ckpt \
  --config-source /absolute/input/model.yaml \
  --destination /absolute/new/drumsep-assets \
  --pretty
```

The CLI prints one JSON result to stdout. Exit `0` means the complete directory
was published; callers must still inspect `cleanup.complete`. Exit `2` prints a
versioned JSON error to stderr with a stable error code, whether publication
occurred, the destination and published receipt path when applicable, and any
owned temporary paths that could not be cleaned. Argument parsing errors use
argparse's exit `2` behavior.

## Copy and publication contract

After validation, the operation acquires an exclusive sibling lock and creates
an owned sibling staging directory. It copies bytes through new regular files;
it never hard-links or changes the sources. Each staged asset is hashed again.
The receipt is written and re-read, and staging must contain exactly both assets
and the receipt before publication.

Publication uses one native no-replace directory rename:

- Linux calls `renameat2` with `RENAME_NOREPLACE`.
- macOS calls `renamex_np` with `RENAME_EXCL`.
- Windows calls the Unicode `MoveFileExW` API with flags `0`. In particular,
  Core does not request replacement, cross-volume copy/delete, delayed rename
  or hard-link behavior.

Staging is created beside the destination, keeping the rename on one
filesystem. The single native call prevents an empty or populated destination
that appears concurrently from being overwritten. A platform API can be
detected during preflight, but support by the destination filesystem is known
only when publication runs. Unsupported syscalls, flags or filesystems and
cross-filesystem results fail with `publication_unsupported`; there is no
check-then-rename, copying or overwrite-capable fallback.

The supported trust boundary is a caller-selected local filesystem and
cooperatively stable ancestors. Ancestor components are checked at validation
and the destination parent's identity is checked immediately before
publication; an ancestor swapped between validation and publication (for
example for a junction or symbolic link) falls under that cooperative
ancestor-stability assumption and is not defended against.

Platform status:

| Platform | CI `asset-publication-native` job | Host runs |
| --- | --- | --- |
| Linux | ubuntu-24.04: 34 of 34, green on f2865b1 | EndeavourOS dev host, worktree on NTFS: every change; Arch laptop, kernel 7.2, ext4, non-root: 0ff9db9 |
| macOS | macOS arm64: 34 of 34, green on f2865b1 | Apple M1, macOS 26.7.1, APFS: 377612e; Intel i7, macOS 15.7.9, APFS: 0ff9db9 |
| Windows | Windows Server 2025: 34 of 34, green on f2865b1 | Windows 11 Pro 25H2, NTFS, Defender real-time protection on: 0ff9db9 |

Each host run covered the `native_publication` selection, the three asset test
files and the preparation CLI with the real pinned DrumSep files (a second run
was refused with `destination_exists`; the sources were unchanged). The host
runs predate 5d57bf6, the watchdog change. The latest green CI run is
40610308255 on f2865b1, on all three operating systems. History: on 5d57bf6 (run
40603074419) Windows passed 33 of 34, failing only the watchdog-alone
header-stall time bound, which f2865b1 replaced with a per-OS bound (see the
Windows wake-up note in `Core_DrumSep_Asset_Acquisition.md`). In scope: native
no-replace publication, the controlled acquisition tests and local-source
preparation. Not covered: model inference, external downloads, full installation
and release qualification. Simulated adapter tests do not qualify a platform,
and no result is generalized to every local or network filesystem.

Known Windows limits: open handles, ACLs, sharing rules, and the documented
`MoveFileExW` path-length rules can cause a normal `publication_failed` result.
In particular `ERROR_SHARING_VIOLATION` (32) can occur while antivirus,
search-indexer or backup software holds a handle on the staging directory. Core
does not retry: the result is a clean `publication_failed` that names the
operation, `GetLastError` number and paths, the destination is not created and
the staging directory and lock are removed. Native errors on every platform
report the operation, the errno name and number (`GetLastError` on Windows) and
the staging and destination paths, while the error codes stay stable.
No power-loss or crash-durability claim is made.

Failures before publication leave pre-existing content untouched and remove
only the operation's inode-checked staging directory and lock. If cleanup is
incomplete, the exact remaining paths are returned in the error. A competing
operation, including one in another process, fails on the exclusive lock or
the final no-replace rename.

After the no-replace rename, the published destination is never a cleanup
target. If an exception or interrupt occurs at the publication boundary, Core
compares the destination receipt with this operation's expected receipt before
reporting publication state. Ordinary errors include `published`,
`destination`, and `receipt_path`. `published` is `null` instead of falsely
reporting `false` if destination identity cannot be inspected. Cancellation
exceptions retain their original type and carry the same attributes plus
`cleanup_remaining`; where supported, Python's exception note also renders
those recovery facts. A successfully published
result remains a success if only lock cleanup fails, with
`cleanup.complete=false` and the remaining lock path reported. These behaviors
cover exception cleanup and atomic visibility, not recovery from `SIGKILL`, a
kernel crash, or power loss.

## Receipt and authority limits

The published directory contains `stemwerk-materialization-receipt.v1.json`.
Its `schema_version` is `1.0.0` and it records:

- a UUID operation identity, operation type and absolute destination;
- the Core pin-policy identity and a canonical policy fingerprint;
- both artifact filenames and verified SHA-256 values;
- the exact filenames created and the staged verification outcome.

The receipt covers this materialization operation only. It is not a signature,
license evidence, authority over the parent directory, an adoption record or
permission to overwrite, repair or remove the files later. It does not promote
readiness ownership to `verified_managed`. Successful materialization does not
establish runtime readiness or complete Drum Kit installation.

## Remaining provisioning scope

This primitive intentionally leaves source acquisition and licensing, runtime
and FFmpeg provisioning, target selection for active installations,
ownership/adoption policy, repair/update/removal, receipts across operations,
rollback, orchestration and post-install readiness revalidation unresolved.

Focused tests use small injected trusted specifications; only the public
production functions bind to the real Core pins. They cover success,
receipt consistency, corrupt/missing/unreadable sources, invalid paths,
symlinks/reparse points, existing destinations, aliases, interruption,
incomplete copies, publication failure, post-publication errors and
interrupts, competing processes, and incomplete cleanup reporting. Tests that
require POSIX FIFO support or unprivileged POSIX permission behavior skip
explicitly when that capability is unavailable. Simulated adapter tests are
marked separately from native publication tests and do not qualify a platform.

Link and reparse-point rejection has real-link tests in addition to the mocked
reparse-point cleanup test. A shared test helper (`tests/asset_link_helpers.py`) creates a directory junction on
Windows (`_winapi.CreateJunction`, no fallback, with an assertion that the result
is a reparse point) and a directory symlink elsewhere, so these tests need no
symlink privilege and exist unchanged on every OS. Covered roles: a
pre-existing directory link at the destination itself, a directory link as the
destination parent, a directory link as a deeper destination ancestor, a
directory link as a source ancestor, a directory link substituted at an owned
cleanup path, and a directory link substituted for the staging directory during
a failed operation. Each asserts the documented error or cleanup result and
that the link target's content is untouched. The Windows junction branch of the
helper cannot run on Linux and is exercised only by the native Windows job.

The `native_publication` selection runs in the `asset-publication-native` CI
job on Linux, macOS and Windows, over the materialization, preparation and
acquisition test files (acquisition contributes its binary-mode and
acquisition-to-materializer tests and its real directory-link reparse tests; its
fixture uses only the standard library and an embedded localhost certificate).
Its junit guard fails the job unless at least `MIN_NATIVE_PUBLICATION_TESTS`
tests ran (the current selection size, set
once in the job environment) and none were skipped, errored or failed. On
native CI and for native qualification a skip therefore fails the run instead
of passing silently. The selection contains no file-symlink test and needs no
symlink privilege. Three file-symlink tests remain outside it, because Windows
has no unprivileged file-level link: the materializer source-symlink test
(skipped on Windows) and two acquisition substitution tests (partial file and
staged source, skipped where a file symlink cannot be created without
privilege, as on Windows without Developer Mode or administrator rights). All
three skip with "requires unprivileged symlink creation". The full portable
selection keeps legitimate skips; it only reports them (`-rs`). The jobs have
run on all three operating systems; see the platform status above.

## Native API references

- Linux: [`renameat2(2)` and `RENAME_NOREPLACE`](https://man7.org/linux/man-pages/man2/rename.2.html)
- macOS: Apple documents the
  [`volumeSupportsExclusiveRenamingKey`](https://developer.apple.com/documentation/foundation/urlresourcekey/volumesupportsexclusiverenamingkey)
  capability in terms of `renamex_np(2)` with `RENAME_EXCL`. The userspace
  definition (`0x00000004`) is in
  [`<sys/stdio.h>`](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/stdio.h),
  which `renamex_np(2)` documents as reached through `#include <stdio.h>`; the kernel-side
  `VFS_RENAME_EXCL` in `vnode_if.h` is a separate VFS constant.
- Windows: Microsoft documents
  [`MoveFileExW`](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw)
  flags, same-drive directory behavior, Unicode paths and error reporting, and
  its [directory-move example](https://learn.microsoft.com/en-us/windows/win32/fileio/moving-directories)
  states that the destination cannot already exist.
- Python documents the portable `st_dev`/`st_ino` identity fields and Windows
  [`st_file_attributes`/`st_reparse_tag`](https://docs.python.org/3/library/os.html#os.stat_result)
  used for reconciliation and identity-bounded cleanup.
