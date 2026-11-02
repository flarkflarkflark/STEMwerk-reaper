# Core module verification

`stemwerk_core.module_verify` reports the installation state of a module
(axis 1 of the [installation design](Core_Module_Installation_Design.md),
section 2.1). The command line `module_install verify` prints the same
document as one line of JSON with sorted keys; see
[Core module CLI](Core_Module_Install_CLI.md).

## Descriptor

`stemwerk_core.module_descriptors.DIRECT_KIT` describes the Direct Kit
module: module `drum_kit`, workflow `drum_kit_direct`, engine
`drumsep_mdx23c`, display name "STEMwerk DKS". Its components, in order:

| Component | Kind | Verifier |
| --- | --- | --- |
| `managed_python` | runtime | none yet |
| `module_venv` | runtime | none yet |
| `ffmpeg` | ffmpeg | none yet |
| `drumsep_assets` | asset | exact size, then SHA-256 |
| `reaper_activation` | activation | none yet |

The asset pins are not repeated: SHA-256 values come from `model_assets`,
byte sizes from `asset_acquisition`.

## API

```python
from stemwerk_core.module_verify import verify_module

document = verify_module("drum_kit", lookup=None, verifiers=None, root=None)
```

`verify_descriptor(descriptor, lookup=..., verifiers=..., root=...)` does the
same for an explicit `ModuleDescriptor`. An unknown module raises
`ValueError`. `root` is where the install lock is read; the default is
`managed_runtime_root()`.

**Lookup.** A lookup has a `lookup_id` and
`locate(module_id, component_id)`, which returns a `ComponentLocation` or
`None`, and raises `ComponentLookupError` when it cannot be read. The
default `NoRegistryLookup` finds nothing and touches no file, so a real
verification today is `not_installed`. Legacy 2.3 layouts are never read.
The module registry (slice S6) will provide the real lookup.

**Classification.** A component the lookup does not find is `absent`. A
lookup that fails gives `unverifiable` (`lookup_failed`). A found component
without a verifier is `unverifiable` (`verifier_unavailable`), so the module
is `unknown` and never `installed`. Otherwise the verifier decides between
`present_passing`, `present_failing` and `unverifiable`.

**Asset verifier.** Once a lookup names a directory, everything wrong there
is `present_failing`: `location_missing`, `location_not_directory`,
`asset_file_missing`, `asset_not_regular_file`, `asset_size_mismatch`,
`asset_integrity_mismatch`, and `symlink_not_allowed` for a symbolic link or
reparse point at the directory, an ancestor or a file (the asset
materialization policy). A wrong-sized file is not hashed. `asset_unreadable`,
`location_unreadable` and `location_invalid` (not an absolute path) are
`unverifiable`. Files are opened read-only without following links; other
files in the directory are ignored.

**State.** The first matching rule of section 2.1 decides: any
`present_failing` -> `repair_required`; any `unverifiable` -> `unknown`; all
`absent` -> `not_installed`; any `absent` -> `partial`; otherwise
`installed`.

## Document

```json
{"kind": "stemwerk_module_verification", "schema_version": "1.1.0",
 "descriptor_version": "1.0.0", "module_id": "drum_kit",
 "workflow_id": "drum_kit_direct", "engine_id": "drumsep_mdx23c",
 "display_name": "STEMwerk DKS", "lookup": "no_registry",
 "installation_state": "not_installed", "decided_by_rule": 3,
 "operation_in_progress": false, "operation_id": null, "lock_status": "free",
 "components": [{"component_id": "managed_python", "kind": "runtime",
   "class": "absent", "reason_code": "not_found", "location": null}, …]}
```

Keys appear in this order and components in descriptor order. A verified
asset component adds `files`, one entry per pin with `name`, `result`
(`verified` or the failing code), `expected_size`, `observed_size` and
`expected_sha256`.

**Running operation** (schema 1.1.0, design section 2.1). `verify` reads
the install lock under `<root>/state/locks/` without taking it, creating
anything or changing anything, and reports:

| `lock_status` | `operation_in_progress` | `operation_id` |
| --- | --- | --- |
| `free` (no lock) | `false` | `null` |
| `held` | `true` | from the lock |
| `stale` (owner gone, see [the lock](Core_Install_Lock.md)) | `false` | `null` when the lock was abandoned during creation, else from the lock |
| `foreign_host` (written on another computer) | `null` | from the lock |
| `unsupported` (this platform cannot probe the owner) | `null` | from the lock |
| `unreadable` (malformed lock, or a link inside `<root>`) | `null` | `null` |

`null` means the lock cannot be judged. A lock never changes
`installation_state`: published components appear only through a no-replace
rename, so a running installation cannot expose a half-written component.
Without the OS lock, `verify` judges staleness from the PID, its start time
and the heartbeat; a lock whose owner died within the last 30 seconds is
still `held`.

## Not in this slice

No module receipt is read or written (S6). The runtime verifiers arrive with
S5 and S6, the FFmpeg verifier with S7 and the activation check with S9.
