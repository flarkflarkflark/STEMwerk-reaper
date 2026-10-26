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
source and destination-parent path component must be free of symbolic links.
Sources must be distinct, readable regular files. The destination parent must
already exist, be owned by the current user, not be group- or world-writable,
and remain stable through the operation. The destination itself must not exist
as any filesystem object. Source/destination aliases are rejected.

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

Publication currently supports Linux filesystems that implement atomic
`renameat2(RENAME_NOREPLACE)` for same-filesystem directory renames. Staging is
created beside the destination to keep publication on one filesystem. The
no-replace operation prevents an empty or populated destination that appears
concurrently from being overwritten. Other platforms and filesystems that do
not provide this operation fail with `publication_unsupported` before
publication. No cross-platform, network-filesystem or crash-durability claim is
made. The contract assumes destination ancestors are not being maliciously
renamed concurrently; their identity is checked before publication.

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

Focused tests are portable and use small injected trusted specifications; only
the public production functions bind to the real Core pins. They cover success,
receipt consistency, corrupt/missing/unreadable sources, invalid paths,
symlinks, existing destinations, aliases, interruption, incomplete copies,
publication failure, post-publication errors and interrupts, competing
processes, and incomplete cleanup reporting. Tests that require Linux
`renameat2`, POSIX FIFO support, or unprivileged POSIX permission behavior skip
explicitly when that capability is unavailable; the unsupported-platform path
is tested without invoking a weaker publication fallback.
