# Core module CLI and operation files

`stemwerk_core.module_install` is the command line of the Core
installation contract
([design](Core_Module_Installation_Design.md), sections 7.2 and 9). In this
slice it is read-only: it describes the contract, assesses a plan and verifies a module. The
operation files (`events.ndjson`, `result.json`, `started`) exist as the
library `stemwerk_core.install_events`; no command writes them yet.

## Commands

```text
python -I -B -m stemwerk_core.module_install --describe
python -I -B -m stemwerk_core.module_install plan --module drum_kit
python -I -B -m stemwerk_core.module_install verify --module drum_kit
```

Exactly one of `--describe`, `plan` and `verify` is given. `plan` and
`verify` require `--module`; `plan` uses the managed runtime root (including
its `STEMWERK_RUNTIME_ROOT` override). There is no CLI `--root` argument or
mutating command.

## Output contract

| Outcome | Exit | stdout | stderr |
| --- | --- | --- | --- |
| `--describe` | 0 | capabilities document | empty |
| `plan`, including `blocked` or `incomplete` | 0 | plan document | empty |
| `verify`, any installation state | 0 | verification document ([verify API](Core_Module_Verification.md)) | empty |
| Unknown module | 2 | empty | error document, code `unknown_module` |
| Invalid/unavailable root or unsupported path encoding | 2 | empty | error document, code `path_ineligible`, `path_unavailable` or `path_encoding_unsupported` |
| Usage error | 2 | empty | argparse usage text |
| Any other `Exception` | 3 | empty | error document, code `internal_error` |

Exit 0 for a valid plan means only that the plan document was produced. It
does not imply eligibility, installation, runtime readiness or permission to
execute. `not_installed`, `partial`, `repair_required` and `unknown` are results of a
successful verification, so they exit 0; callers read
`installation_state`. Each document is one line of compact JSON with sorted
keys. The `internal_error` message names only the exception type.
`KeyboardInterrupt` and `SystemExit` are not converted.

**Encoding rule: CLI stream JSON is ASCII-only; files are UTF-8.** Every
JSON document a Core CLI writes to stdout or stderr (this CLI, the asset
acquisition, preparation and materialization CLIs, and the installation
preview `stemwerk_core.installation_plan`) escapes non-ASCII
characters as `\uXXXX`, with a surrogate pair above U+FFFF. The bytes are
then the same on every console or pipe code page, for example a Windows
pipe in cp1252, cp850 or cp437; any JSON parser restores the original
strings. Readers that are not JSON libraries (Lua, Inno) must decode these
escapes, including surrogate pairs.

Error document:

```json
{"error":{"code":"unknown_module","message":"unknown module 'x'","module":"x"},
 "kind":"stemwerk_module_install_error","schema_version":"1.0.0"}
```

A reader that closes stdout or stderr early does not change the exit code;
the output is dropped. A closed stream is `BrokenPipeError`, plus `OSError`
`EINVAL` on Windows only; other `OSError`s, for example `ENOSPC`, keep the
interpreter's report. The helpers for this live in
`stemwerk_core._cli_io` and are shared with the asset acquisition,
preparation and materialization CLIs.

## Capabilities (`--describe`)

```json
{"contract_version":"1.0.0","core_version":null,"current_platform":"linux-x86_64",
 "event_protocol":"stemwerk-install-events/1","kind":"stemwerk_install_capabilities",
 "modules":["drum_kit"],"operations":["plan","verify"],
 "platforms":["linux-x86_64","darwin-arm64","win-x86_64"],
 "schemas":{"describe":"1.0.0","error":"1.0.0","events":"stemwerk-install-events/1",
  "plan":"1.0.0",
  "result":"stemwerk-install-result/1","started":"stemwerk-install-started/1",
  "verification":"1.1.0"}}
```

- `operations` lists only what this Core can do. Later slices add their
  operations; a front end hides operations and modules it does not know.
- `contract_version` follows semantic versioning: a front end accepts any
  `1.x` it knows; a higher MAJOR means do not mutate and show the update
  message (design section 9).
- `core_version` is the installed `stemwerk-core` distribution version, or
  `null` when Core runs from source.
- `platforms` are the platforms of the first route. `current_platform` is
  the one this interpreter runs on, or `null` outside them; an x86_64
  process translated by Rosetta on Apple Silicon is `null`.

## Plan (`plan --module drum_kit`)

The `stemwerk_module_install_plan` document has `schema_version: "1.0.0"`
and `scope: "s4_assessment"`. It is a read-only snapshot, separate from
`installation_state` in the verification document and from runtime
readiness. Its `preflight_result` is one of:

| Value | Meaning |
| --- | --- |
| `blocked` | At least one known refusal is in `blockers` |
| `incomplete` | No known refusal, but at least one required check is in `incomplete` |
| `no_blocker_found` | No blocker or incomplete check within the implemented scope; still no install guarantee |

`warnings` contains observations that do not prove refusal. Each list is
sorted and deduplicated. Current S4 plans remain `incomplete` unless a
known blocker makes them `blocked`: the selected CPU install size, manifest
hosts, full Windows wheel tree, and complete duplicate-payload scope need
later slices. The current `no_registry` verification lookup cannot prove
an existing installation absent; it is shown as `installation.status:
"unknown"`, even when its raw `reported_state` is `not_installed`.

The document also has `actions`, `fingerprint`, `space`, `path_budget`,
`platform_check`, `installation`, `lock` and `legacy_payloads`. `actions`
lists the module, platform, root, descriptor components and asset pins,
estimates, and ordered phases. `installation` uses Core's read-only module
verification; `lock` comes from its read-only lock inspection. A held lock
is a blocker; a stale lock is a warning and is never broken by `plan`.
Legacy markers identify only candidates for an old layout; neither a 2.3.x
version nor ownership is inferred. Multiple distinct marked roots are
surfaced as `duplicate_legacy_payload`; absence outside scanned roots is
not claimed.

`space.filesystem` is the volume holding `<root>`. The `storage` table
separates download, temporary and final bytes, all *planned* under that
volume. Unknown quantities are JSON `null` or listed in
`unknown_quantities`; they are never treated as zero or as proof of
sufficient space. The hard `known_minimum_bytes` currently counts only
the pinned final DrumSep assets. The larger `estimate_bytes` is **provisional**:
its 13 GiB environment row comes from an observed 2.3 ROCm environment,
not the Direct Kit CPU install; the cache, build and margin rows are
unmeasured allowances. The wheel cache allowance excludes asset and FFmpeg
downloads; the asset row separately assumes download, staged and final
copies coexist. Static FFmpeg is counted in the estimate, and the
Linux candidate archive/pair and Windows candidate archive are shown
separately. Falling below the estimate gives `below_provisional_estimate`
as a warning. Falling below the known minimum gives
`insufficient_known_space` as a blocker with available and required bytes.
Neither check reserves space. S6 must measure an observed pinned CPU
install, establish peak coexistence and keep its download/cache/temp paths
on the assessed filesystem before this becomes an execution gate.

On Windows, `path_budget` checks only the fixed paths already known. Its
`status` remains `incomplete` and `full_tree_max_length` is `null` until
S6 selects the CPU wheel set and measures its actual deepest installed
path. A known path above the 259 UTF-16-unit budget is a blocker. A known
path within it is no assertion about the full tree.

Stable plan inputs are encoded as sorted-key compact UTF-8 JSON and hashed
with SHA-256 in `fingerprint`; the root, platform, workflow/engine,
descriptor version, component pins, estimates and phases are included.
Volatile free space, OS/VC++ evidence, paths, lock and installation state
are inspected again by `require_current_plan` before a later execution
slice can use consent. A changed fingerprint raises `plan_changed`; a
current blocker raises `preflight_blocked`, and incomplete evidence raises
`preflight_incomplete`. No command calls that execution helper yet, and
equality never reserves resources or authorizes mutation.

Named `blockers` include `insufficient_known_space`, `unsupported_platform`,
`os_too_old`, `glibc_too_old`, `vcpp_runtime_missing`, `known_path_too_long`,
`path_ineligible`, `path_unwritable` and `lock_held`. Named `incomplete`
reasons include `os_version_unknown`, `glibc_version_unknown`,
`vcpp_runtime_unknown`, `path_writability_unknown`,
`existing_installation_unknown`, `lock_state_unknown`,
`duplicate_payload_scope_unknown`, `manifest_network_hosts`,
`bootstrap_operation_state_unknown`, `actual_pinned_install_space` and
`windows_full_path_unmeasured`.
For Visual C++, the read-only Windows registry probe records whether the
x64 redistributable key is present. A missing or present key alone leaves
native DLL functionality unverified and produces `vcpp_runtime_unknown`;
`vcpp_runtime_missing` requires conclusive absence evidence. There is no
provisioning or invented minimum runtime version in this plan.

## Operation files (library)

All files of one operation live in `<root>/logs/<operation-id>/`. Unlike
the CLI streams, they are UTF-8 without a byte order mark; non-ASCII text,
such as paths with user names, is written unescaped and read back unchanged.

**`events.ndjson`.** One JSON object per line, each line terminated by
`\n` and written with a single append. Fields: `protocol`
(`stemwerk-install-events/1`), `operation_id` (lowercase UUID), `seq`,
`ts` (RFC 3339, UTC, `Z`), `source` (`outer_layer` or `core`), `state`,
`phase`, and the fields its state requires:

| `state` | Fields |
| --- | --- |
| `active_determinate` | `done`, `total`, `unit` |
| `active_indeterminate` | `since_seconds` |
| `possibly_stalled` | `silent_seconds` |
| `retrying` | `error_code`, `attempt`, `max_attempts` |
| `failed` | `error_code`, `detail`, `action` |
| `done` | `verified` |

Phases, in order: `bootstrap` (outer layer only), `preflight`, `lock`,
`create_environment`, `install_packages`, `fetch_ffmpeg`, `verify_ffmpeg`,
`fetch_assets`, `verify_assets`, `publish`, `activate`, `verify_module`.
No other fields are allowed. `seq` starts at 1 and grows by one per line
across both writers. Readers ignore an incomplete last line.

**Handover (G1).** The outer layer creates the operation directory
exclusively and writes the first events. `EventWriter.accept_handover`
gives Core its writer only if the directory is named after the operation,
holds outer-layer events of that operation with a complete last line, and
has no result; Core continues at the next `seq`. Otherwise it raises
`InstallFileError` with code `handover_refused`.

**`result.json`.** `{protocol: "stemwerk-install-result/1", operation_id,
exit_code, stream, document}`: exit 0 goes with `stdout`, exit 2 and 3 with
`stderr`, and `document` is the terminal document of the output contract.

**`started`.** `{protocol: "stemwerk-install-started/1", operation_id, pid,
ts}`, the startup acknowledgement of a detached Core.

`result.json` and `started` are written once: to a temporary file in the
same directory, synced, then published with the native no-replace rename
used for asset publication. They are never partially visible and never
replaced; a second write fails with `already_written`. A crash before the
rename leaves only a `.<name>.<hex>.tmp` file that readers ignore. On POSIX
the directory is synced after the rename so the new name survives a crash;
if that fails the write raises `write_failed` although the file is already
published, and a retry finds `already_written`. Windows has no directory
fsync; this step is skipped there.

## Not in this slice

Detached runs and the startup handshake with a front end (S9), the outer
layer (S5), install and the module receipt (S6), and cancellation at safe
points (S8). The install lock and the journal exist as libraries
([Core install lock](Core_Install_Lock.md)); no command takes the lock yet,
and `verify` only reads it.
