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
| `managed_python` | runtime | S5a `verify_managed_python` + S6 receipt `tree_sha256` and `s5b_tree_sha256` |
| `module_venv` | runtime | S6 receipt `tree_sha256`, zero-`.pyc` gate, and `-I -B` runtime import probe |
| `ffmpeg` | ffmpeg | S7: installed tree against the pin AND the receipt (exact entries, kinds, modes, size and SHA-256 of `ffmpeg`, `ffprobe`, `LICENSE.txt`, `NOTICE.txt`), then the round-trip probe |
| `drumsep_assets` | asset | exact size, then SHA-256 |
| `reaper_activation` | activation | none yet (S9) |

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
`None`, and raises `ComponentLookupError` when it cannot be read. When
`lookup` is omitted (`None`), `verify_module` uses `_default_lookup_for_root(root, module_id)`:
if neither `<root>/state/module-registry.v1.json` nor
`<root>/state/modules/<module>.receipt.json` exists, it returns
`NoRegistryLookup` (`lookup: "no_registry"`), which finds nothing and reports
`not_installed` (`decided_by_rule: 3`). When both the registry and the
integrity-checked module receipt exist and match (`read_and_validate_module_record`),
it returns `RegistryLookup` (`lookup: "module_registry"`), which resolves
`managed_python`, `module_venv`, `drumsep_assets` and, from S7, `ffmpeg` (leaving
`reaper_activation` absent until S9). If either the registry or
receipt is missing while the other exists, or if they disagree or fail schema
validation, it returns `UnverifiableRegistryLookup` (`lookup: "module_registry"`),
which raises `ComponentLookupError` so the module is classified as
`installation_state: "unknown"` (`decided_by_rule: 2`). Legacy 2.3 layouts are
never read.

**Classification.** A component the lookup does not find is `absent`. A
lookup that fails gives `unverifiable` (`lookup_failed`). A found component
without a verifier is `unverifiable` (`verifier_unavailable`), so the module
is `unknown` and never `installed`. Otherwise the verifier decides between
`present_passing`, `present_failing` and `unverifiable`.

**Runtime verifier (`verify_runtime_component` and `verify_s6_runtime_interpreter`).**
For `managed_python`, the verifier runs `managed_python.verify_managed_python`
and compares `module_registry.compute_tree_identity` (`tree_sha256`,
`s5b_tree_sha256`, `entry_count`, `total_bytes`, `pyc_count`) against the
module receipt. For `module_venv`, the verifier compares the full tree
identity against the receipt, requires `pyc_count == 0`, checks installed
package versions against the locked set, and runs an isolated `-I -B`
probe importing `torch`, `onnx`, `onnxruntime`, `librosa`, `soundfile`,
`audio_separator`, and `stemwerk_core`. A readable content, mode, or
symlink mutation in a published runtime directory produces `present_failing`
(`repair_required`, `decided_by_rule: 1`). An unreadable file or directory in
the tree is `unverifiable` (`tree_unreadable`, state `unknown`). Worker startup
(`drumsep_runtime`, and the worker before it spawns the DrumSep helper) calls
`verify_s6_runtime_interpreter` before launching a separation on an
S6-managed interpreter (`<root>/runtimes/<module>/<pin>/bin/python`), refusing
execution when the receipt/registry or runtime tree fails verification or
cannot be verified, or when the requested interpreter path differs from the
registered runtime. Numba writes its `.nbi`/`.nbc` caches regardless of the
bytecode policy, so the worker gives that helper a `NUMBA_CACHE_DIR` in a
per-process directory under `TMPDIR`, removed at exit, and refuses to run if
`TMPDIR` is inside the runtime. Inherited values are ignored for S6 runtimes;
other runtimes keep their caller's setting. Starting the venv's `bin/python`
directly without `-B` or `PYTHONDONTWRITEBYTECODE=1` still writes bytecode into
the venv and the managed Python, and this comparison reports it.
A `drum_kit.venv-publication.json` record is not a registration: verification
ignores it, and it only allows `install` to resume an interrupted publication.

**Asset verifier.** Once a lookup names a directory, everything wrong there
is `present_failing`: `location_missing`, `location_not_directory`,
`asset_file_missing`, `asset_not_regular_file`, `asset_size_mismatch`,
`asset_integrity_mismatch`, and `symlink_not_allowed` for a symbolic link or
reparse point at the directory, an ancestor or a file (the asset
materialization policy). A wrong-sized file is not hashed. `asset_unreadable`,
`location_unreadable` and `location_invalid` (not an absolute path) are
`unverifiable`. Files are opened read-only without following links; other
files in the directory are ignored.
Readiness resolves the registered S6 asset location even when that directory
is missing or the registration is unverifiable, so legacy `<root>/models/`
cannot mask a damaged S6 installation. It falls back to legacy models only
when no S6 registration exists.

For live `drum_kit_direct` readiness, a registration with no managed
FFmpeg receipt entry reports `managed_ffmpeg_pending` and remains unavailable,
even if a system FFmpeg or legacy runtime is usable on the same host. With an
entry, readiness is the module's own pair: verified, then run through the
round-trip probe. A pair that does not verify is `FAIL`
(`ffmpeg_unavailable`); a system FFmpeg is never consulted for a registered
module. The install result names S9 activation as pending.

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

## The FFmpeg pair (S7)

The vendor SHA-256 in `ffmpeg-pin.v1.json` covers the archive only. At
extraction Core records the size and SHA-256 of the extracted `ffmpeg`,
`ffprobe`, `LICENSE.txt` and `NOTICE.txt` in the receipt (`components.ffmpeg.files`),
together with `tree_sha256`. Verification re-reads the installed files and
compares them with the pin and with the receipt. Any difference is
`present_failing`, hence `repair_required`: a wrong size or hash
(`ffmpeg_file_size_mismatch`, `ffmpeg_file_hash_mismatch`), a missing or extra
entry (`ffmpeg_file_missing`, `ffmpeg_unexpected_entry`), a link or other
non-regular file (`ffmpeg_not_regular_file`), a changed mode
(`ffmpeg_mode_mismatch`), a pin or receipt that disagrees (`ffmpeg_pin_mismatch`,
`ffmpeg_receipt_mismatch`). A file that cannot be read is `unverifiable`.

The probe then runs the installed binaries from a private scratch directory
outside the runtime tree, with a minimal explicit environment, 30 s per command
and 60 s in total: version lines and build configuration equal to the pin
(no `--enable-gpl`, no `--enable-nonfree`), and deterministic stereo 16- and
24-bit audio, 2 s, encoded WAV to FLAC and decoded back to WAV, which must be
bit-exact; `ffprobe` must describe the FLAC file. A missing codec, a crash, a
timeout or a lossy decode is `present_failing` with a `probe_*` reason code.

The worker guard (`verify_s6_ffmpeg_for_interpreter`, `s6_ffmpeg_pair`) checks
the tree without the probe and refuses to start a Direct Kit job when the pair
is not verified. A registered module never falls back to a system FFmpeg.

## Not in this slice

The REAPER activation check arrives with S9. Until it is present, a verified
installation reports `installation_state: "partial"` (`decided_by_rule: 4`).
