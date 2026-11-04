# Managed Python bootstrap: the Core side (slice S5a)

The managed Python is obtained by a small outer layer before Core can run
([design](Core_Module_Installation_Design.md), sections 6.1 and 6.2,
decisions D9, D12, F5, F6, G1, G3 and G4). Slice S5 is split at
implementation (design section 13, review note R5-04):

- **S5a, this page:** the manifest and its parser, the read-only
  verification of a published runtime, how Core starts under `-I` before any
  venv exists (O54), and the cleanup of stale bootstrap staging (O55).
- **S5b, later:** the outer layers themselves (the `sh` bootstrap on Linux,
  then Inno Setup on Windows, then the `sh` bootstrap on macOS), the
  per-release pin check and the scheduled manifest-URL job (C21), the honest
  bootstrap failure results (C22), the Linux baseline run (L9) and host runs
  on clean accounts.

Nothing in S5a downloads, unpacks or publishes a runtime. No command uses
these libraries to mutate yet; the lock acquisition that runs the O55 cleanup
is first used by the install operation (slice S6).

## The manifest

`CORE/runtime-manifest.v1.tsv` is the one source of truth for the pinned
managed Python (D9, G4); `CORE` abbreviates
`scripts/reaper/vendor/stemwerk-core/src/stemwerk_core`. The outer layers and
Core read the same file. `stemwerk_core.runtime_manifest` parses it.

```text
stemwerk-runtime-manifest/1
<platform>\t<name>\t<url>\t<size>\t<sha256>
```

- ASCII without a byte order mark; every line ends with one LF, no CR
  (`.gitattributes` keeps it LF on every checkout); no empty lines, comments
  or spaces; exactly five TAB-separated fields per record.
- `platform`: `linux-x86_64`, `darwin-arm64` or `win-x86_64`, each with
  exactly one record. `darwin-x86_64` is parked (O50).
- `name`: the pin id `python-<3.12.x>-<YYYYMMDD>`, also the published
  directory name. Patch version and build date are both pinned (F6); D2
  limits the managed runtime to CPython 3.12.
- `url`: exactly the python-build-standalone release asset
  `…/releases/download/<build>/cpython-<version>%2B<build>-<target>-install_only_stripped.tar.gz`
  of that name and platform; a record whose name and URL disagree is refused.
- `size`: positive decimal bytes; `sha256`: 64 lowercase hex digits.

Any deviation is `manifest_invalid` with the line number. A `sh` script reads
the file with builtins only (`IFS=<TAB> read -r`); a test runs exactly that
loop and compares it with Core's parse. Inno's Pascal reader is S5b.

Pinned records (F6 candidate, now the manifest pins):

| Platform | Target | Bytes | SHA-256 |
| --- | --- | --- | --- |
| `linux-x86_64` | `x86_64-unknown-linux-gnu` | 34,505,639 | `ce4f6d0a6cfdb3bed6e44c2f9affd85943c76a42e25ad3a259002f31d6fb8a20` |
| `darwin-arm64` | `aarch64-apple-darwin` | 25,035,343 | `353d5f1b4fd2715e7053f12f068435d5bbad16b91e057006b5d01e0925709a7e` |
| `win-x86_64` | `x86_64-pc-windows-msvc` | 22,014,416 | `1f2ab53880fc67ea323398c6388e05af28addc99a8e389209f08a51fdff4b149` |

All three are CPython 3.12.16, python-build-standalone build `20261026`,
`install_only_stripped`. The plan binds the record of its platform as
`actions.managed_python`, so a changed pin changes the consent fingerprint
(C15); an invalid shipped manifest makes `plan` fail with `manifest_invalid`.

### Trust, compatibility and execution are separate claims

| Claim | Established by | Not established by |
| --- | --- | --- |
| Acquisition integrity | `check_archive`: the downloaded file is a regular file with exactly the pinned size, then exactly the pinned SHA-256; size is checked first, so a truncated or oversized download is refused without hashing; nothing is unpacked after a mismatch | TLS or a successful HTTPS transfer, which prove transport only |
| Why the pin is trusted | The pin is in this versioned repository file. When it was chosen, all three values were compared with the upstream `SHA256SUMS` of build `20261026`, with the release API's per-asset size and digest, and with the measured bytes of a download (REPORTED, evidence of slice S5a, 2026-11-04). Detached signatures are deferred (O17) | The vendor's current state: the per-release and scheduled checks that re-compare the pins are S5b (C21) |
| Package compatibility | Partly: the archive layouts were inspected (below); the Linux interpreter needs at most `GLIBC_2.17` and no ELF in the archive lists `libgcc_s` as needed (static read only). Native runs on the G2 environments (L9, Windows 10 22H2, macOS 14 arm64) are S5b/S11 | An inspected archive does not qualify a platform |
| Execution verification | `verify_managed_python` (below) on the published tree, on the host itself | Any check of the archive |

Archive layout of the three pins (REPORTED, inspected 2026-11-04 without
extracting): one top-level `python/` directory; no absolute or `..` member
names, hard links or special mode bits; the Linux archive has 1,049 and the
macOS archive 10 relative symbolic links, all resolving inside `python/`;
the Windows archive has none. The interpreter file is `python/bin/python3.12`
(Linux, macOS; `bin/python3` is a link to it) or `python/python.exe`
(Windows). The longest member name is 106 characters (Linux, macOS) and 105
(Windows), so the Windows runtime tree is deepest at
`<root>\runtimes\python\python-3.12.16-20261026\` plus 99 characters.

Release engineering keeps the per-target licence notices of the matching
full distributions, because the stripped archives do not carry them (F6);
the libuuid notice question stays parked (O53).

## Starting Core under `-I` before any venv (O54)

**Resolution (S5a).** The outer layer starts Core by running Core's shipped
source directory:

```text
<runtime>/bin/python3.12 -I -B <…>/vendor/stemwerk-core/src <arguments>
<runtime>\python.exe     -I -B <…>\vendor\stemwerk-core\src <arguments>
```

`<arguments>` and the output contract are exactly those of
`python -m stemwerk_core.module_install` (see
[the CLI](Core_Module_Install_CLI.md)). `src/__main__.py` imports
`stemwerk_core.module_install` and calls its `main`.

Why this works: Python runs a directory that contains `__main__.py` by
putting that directory first on `sys.path`, also in isolated mode. `-I`
ignores every `PYTHON*` environment variable and the user site-packages and
does not add the current directory, so nothing outside the shipped source
and the pinned interpreter's own standard library is imported. `-B` writes
no `__pycache__` into the shipped source. Nothing is installed into the
managed Python, which therefore stays byte-identical to the verified archive
contents.

Alternatives considered and not taken:

- Installing Core into the managed Python's site-packages would change the
  published runtime after its verification and would be a second mutation by
  the outer layer, which G1 does not allow.
- `-c "import sys; sys.path.insert(…)…"` puts code into Inno and `sh` command
  lines twice, with their quoting rules; one shipped file is simpler.
- The macOS-only `stemwerk_core-0.1.1` wheel predates the installation
  modules and exists for one platform; building a wheel per release adds a
  build artifact and a hash without changing what is importable.

Constraints the outer layers and distribution must meet (S5b, S9):

- Every front end must ship the whole tracked `vendor/stemwerk-core/src`
  tree, including `__main__.py` and `runtime-manifest.v1.tsv`. Today only the
  Linux package copies the whole `scripts/reaper/` tree; the ReaPack, Inno
  and `.pkg` file lists name a few Core files (design O54).
- The modules this entry imports use only the standard library: a test
  imports `module_install`, `install_lock`, `install_bootstrap`,
  `managed_python` and `runtime_manifest` under `-I -S` and finds no other
  top-level module. Any third-party import in that graph breaks the
  bootstrap and fails the test.
- From a shipped source tree, `--describe` reports `core_version: null`;
  there is no distribution metadata until Core is installed into a venv.

Tests start the entry in a real child interpreter from a copy of the source
in a path with non-ASCII characters (`Jürgen ñ 名`), with a decoy
`stemwerk_core` in the current directory and on `PYTHONPATH`, and check that
`--describe`, `plan` and an `unknown_module` error behave as the CLI
contract says and that no `__pycache__` appears. CI runs them natively on
Linux, macOS and Windows with the runner's Python; the pinned managed Python
itself is exercised on Linux by the S5a smoke (evidence), not in CI.

## Verifying a published runtime

`managed_python.verify_managed_python(root, record)` checks
`<root>/runtimes/python/<name>/` read-only and returns `status` `verified`,
`absent` or `invalid` with `reasons`:

1. Location: every component from `<root>` down is a real directory
   (`runtime_path_ineligible`, `runtime_path_unavailable`).
2. Tree, walked without following links: directories; regular files with a
   single link (`hard_link`); on POSIX relative symbolic links whose resolved
   target, following every link on the way, stays inside the runtime
   (`absolute_link`, `link_escapes_runtime`). On Windows no link or reparse
   point is allowed (`link_not_allowed`, `reparse_point`). Anything else is
   `special_file`.
3. Interpreter: the platform's interpreter file is a regular file
   (`interpreter_missing`). Only then is it started, as
   `-I -B -c <probe>` with stdin closed, no console window on Windows and a
   60-second timeout. It must report CPython, exactly the pinned version, the
   platform's machine (`x86_64`, `arm64`, `AMD64`), 64-bit pointers, isolated
   mode and `sys.prefix` equal to the runtime directory
   (`implementation_mismatch`, `version_mismatch`, `architecture_mismatch`,
   `pointer_size_mismatch`, `not_isolated`, `prefix_mismatch`;
   `interpreter_failed`, `interpreter_timeout`, `interpreter_output_invalid`).

A tree that fails steps 1 or 2 is never executed. For the outer layer's
reuse decision G1 requires only that the interpreter reports the pinned
version; this function is the deeper check Core applies.

## Stale bootstrap staging (O55, C24)

**Resolution (S5a).** Layout and liveness signal:

| Path | Written by | Content |
| --- | --- | --- |
| `<root>/logs/<op>/events.ndjson` | outer layer, then Core | events (design 7.2); the outer layer appends at least every 5 s while it works, except during one blocking unpack step |
| `<root>/tmp/<op>/bootstrap/` | outer layer only | download, unpack, owner record; removed by the outer layer after it published or failed |
| `<root>/tmp/<op>/bootstrap/owner` | outer layer, first file in `bootstrap/` | one line: `stemwerk-bootstrap-owner/1<TAB><op><TAB><pid><LF>` |
| `<root>/tmp/<op>/core/`, `journal.ndjson` | Core only | its own staging and journal ([lock and journal](Core_Install_Lock.md)) |

`install_bootstrap.inspect_staging(root)` classifies every
`<root>/tmp/<op>/bootstrap/` read-only. It is `stale` only if both hold:

- silence of at least 15 minutes (`stale_after`): no modification time of
  the events file, of `bootstrap/` or of any direct entry of it is more
  recent;
- the recorded process is proven gone on this host. A running owner keeps it
  (`kept_owner_running`), and so does a process whose state cannot be
  determined (`kept_owner_unknown`) or an owner record naming another
  operation (`kept_owner_other_operation`). Without a readable owner record
  (a crash before it was written, or a malformed one, reported in `detail`)
  only the silence decides.

Other statuses: `kept_recent` (silent for less than the bound),
`kept_current_operation`, `kept_ineligible` (the operation directory or
`bootstrap/` is not a directory, or is a link or reparse point). Names under
`<root>/tmp/` that are not canonical operation ids are never looked at.

`install_bootstrap.remove_stale_staging(root, current_operation_id=…)` removes
only `stale` entries: it checks the identity (device, inode, directory) found
during inspection again, removes `bootstrap/` with `shutil.rmtree`, which
never follows links or junctions inside it, and then removes
`<root>/tmp/<op>/` only if it is empty, so Core's journal and `core/` stay.
Outcomes: `removed`, `kept_identity_mismatch`, `kept_remove_failed`; a
failed removal is retried at the next start. `install_lock.acquire` calls it
right after journal recovery, under the lock; the report is
`lock.bootstrap_cleanup`. Logs are never removed.

Known limits:

- An active bootstrap holds no lock (G1), so only the liveness signal
  protects it. A reused process id can keep stale staging longer, never
  remove active staging. A staging directory on a root shared with another
  host is judged by its silence; its process id says nothing on this host.
- The bound assumes the outer layer's contract above. An outer layer that
  stays silent for 15 minutes and whose process id is gone is treated as
  crashed.
- The registry and receipts (S6) must never reference `<root>/tmp/`; there is
  no registry yet, so nothing can reference it now.

## What S5b must add

- `sh` outer layer (Linux first, then macOS) and Inno (Windows, G3):
  create `<root>/logs/<op>/` exclusively, write events with
  `source: "outer_layer"` and phase `bootstrap`, write the owner record,
  download into `bootstrap/`, check size then SHA-256 against the record for
  its platform, unpack (Inno: the system `tar.exe` by absolute path),
  publish `bootstrap/python` to `<root>/runtimes/python/<name>/` with a
  no-replace rename or reuse a verified copy, remove `bootstrap/`, and on any
  failure write a `failed` event and a result file (C22). `sh` has no
  portable no-replace rename for directories (`mv` moves a directory into an
  existing one on macOS); S5b chooses and tests the mechanism.
- Named failures, at least: platform outside the manifest, no `curl` or
  `wget`, network unavailable (C14), size mismatch, SHA-256 mismatch, unpack
  failure, publish conflict, verification of the reused or published
  interpreter failed, cancelled (marker, design 7.4).
- The per-release pin check and the scheduled manifest-URL job (C21), the
  Linux baseline run (L9) and clean-account host runs.
