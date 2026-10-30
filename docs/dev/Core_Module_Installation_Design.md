# Core module installation: design and first route

Status: design proposal for review, revision 5 (2026-10-30). It applies the
owner's decisions D1-D12, F1-F9 and G1-G4, the independent reviews of
revisions 1 and 3, and the installation research of 2026-10-30. Nothing in
this document is implemented unless it is marked as existing behavior with
a `file:line` citation at `9c410f951c8e9160ee64c883938f9420b654577d`.
All paths are relative to the repository root; `CORE` abbreviates
`scripts/reaper/vendor/stemwerk-core/src/stemwerk_core`.

## Evidence conventions

Every statement in this document has exactly one of five kinds.

| Kind | Meaning | How it is marked |
| --- | --- | --- |
| EXISTING | Verified in code or docs at HEAD | `file:line` citation |
| REPORTED | CI, host, review, support or research result | source (run ID, host, issue, upstream documentation URL, or "Astra research 2026-10-30" with the upstream URL it cites) |
| DECIDED | Owner decision of 2026-10-30 | "DECIDED (Dn)", see the table below |
| PROPOSED | Design decision made by this document | "proposed", "must", "will" |
| OPEN | Unknown or undecided | only in section 12, as an `O` row |

Open points appear only in section 12. Each is classified "blocks the first
route" or "parked"; resolved items keep their ID in section 12.3.

"Astra research 2026-10-30" is the owner-commissioned research note
`STEMwerk-2.4-installation-research.md` (outside the repository). Every
statement it makes about repository code was re-read at HEAD before it is
recorded here as EXISTING. Its probe results and upstream facts stay
REPORTED; pins it found are CANDIDATE pins, not final pins.

Issue states were read with `gh issue view` on 2026-10-30. PR #107 is not
merged. It is used as REPORTED scope (D4). Its body is cited by section as
"PR #107 (unmerged) body". The scope document the PR proposes does not
exist at HEAD; statements that appear only there are cited as "PR #107
(unmerged) diff" with the section name of that proposed document.

## Decisions

All decisions were taken by the owner on 2026-10-30. D1-D12 shaped
revision 2; F1-F9 follow the research and refine D7, D9, D11 and D12;
G1-G4 settle the bootstrap order, the minimum environments, the Inno
download and the manifest format.

| ID | Decision (DECIDED 2026-10-30) | Sections |
| --- | --- | --- |
| D1 | Immutable asset sets under `<root>/assets/<set-id>/`; an atomically written registry in `<root>/state/` maps module to set-id; readiness and worker resolve through it; `<root>/models` is read-only legacy; no symlinks or pointer files | 3.3, 5.1, 10.4 |
| D2 | Managed runtime is Python 3.12; CI unit-tests Core on 3.11 and 3.12 | 6.3, 13 |
| D3 | Engine ID stays `drumsep_mdx23c`; display name "STEMwerk DKS"; reconcile with PR #107 when it merges | 10.3, 12 |
| D4 | PR #107 is REPORTED scope (unmerged); cite its body sections, not a repository path | Conventions, 1 |
| D5 | NDJSON events go to a file under `<root>/logs/<op>/`; the CLI contract (stdout success JSON, stderr error JSON, exit 0/2/3) is untouched; no `--events-fd` in v1; the terminal result is also written to a result file | 7.2 |
| D6 | A cancel marker file is the single primary cancel mechanism on all platforms; Core checks it at safe points; POSIX signals are an optional fast path; no `CTRL_BREAK_EVENT` dependency | 7.4 |
| D7 | Front ends per OS: Windows installs and repairs through the external installer, REAPER on Windows shows read-only status; macOS/Linux use `STEMwerk-SETUP.lua`, which starts Core detached, follows the events file, cancels via the marker and reads the result file; only Core mutates, always under the lock (bootstrap carve-out: G1) | 6.1, 6.5, 7.6 |
| D8 | One per-user lock at `<root>/state/locks/install.lock` (PID, start time, heartbeat); a live lock is never broken; both front ends mutate only through the Core CLI (bootstrap carve-out: G1) | 8 |
| D9 | Managed Python from python-build-standalone; one versioned manifest `{url, size, sha256}` in the repository, read by both the outer layer and Core; a CI job checks the pins against upstream checksums per release; detached signatures deferred | 6.2 |
| D10 | Reuse is read-only (ownership `external`); adoption is opt-in | 4 |
| D11 | FFmpeg in v1 is only STEMwerk's own pinned `ffmpeg`/`ffprobe` pair (manifest as in D9); the worker always uses that pair; verify includes encode/decode probes per offered output format; reuse of a system FFmpeg is parked | 3.1, 3.6, 13 |
| D12 | No new outer-layer technology in v1: Inno Setup per user on Windows in one window; the existing bootstrap shell script started by `STEMwerk-SETUP.lua` on macOS/Linux; the PySide6 Setup app is later; macOS signing and notarisation required for release | 6.1 |
| F1 | Output formats in v1: WAV and FLAC only; MP3 parked | 3.6 |
| F2 | macOS arm64 FFmpeg: STEMwerk's own LGPL build (existing recipe), published as a STEMwerk release asset with its licence text and pointers to the official source tarball and the recipe; macOS x86_64 parked | 3.6, 6.2 |
| F3 | Windows/Linux FFmpeg: BtbN LGPL month-end builds; the researched assets are CANDIDATE pins; final pins are chosen in the implementation slice with native qualification | 3.6, 13 |
| F4 | Static FFmpeg builds; disk preflight counts their size | 3.6, 7.1 |
| F5 | Pinned artifacts are downloaded from the vendor by pinned URL and SHA-256; no self-mirroring requirement; a scheduled CI job checks every manifest URL; the release step ships licence texts and source pointers with every bundled or STEMwerk-hosted FFmpeg | 6.2, 13 |
| F6 | Managed Python candidate: CPython 3.12.16, python-build-standalone 20261026, `install_only_stripped`, three targets; pin patch and build date, never "latest"; release engineering keeps the per-target licence notices | 6.2 |
| F7 | macOS runtime payloads in v1: vendor/ad-hoc signatures plus pinned hashes, provided a clean-Mac test of the real path passes; no blanket quarantine removal, no local re-signing | 6.6, 11.2 |
| F8 | Windows repair while a separation runs is refused immediately with a retry option; Core coordinates with separation jobs and never replaces the runtime it runs from; installer-only repair is a maintenance policy, not an elevation need | 7.6, 8 |
| F9 | An install continues when REAPER is closed (not across logout or shutdown); launch contract `ExecProcess(cmd, -1)`, `nohup` shell stage, self-detaching Core, startup acknowledgement file; gates: quit, force-quit, reattach | 6.5, 7.6, 11.2 |
| G1 | Order on a fresh account: bootstrap -> preflight -> lock -> rest. The outer layer only fetches the pinned Python, verifies size and SHA-256 against the manifest, unpacks it into per-operation staging and publishes it no-replace (or reuses a verified one), writing its early events and, on failure, an honest failure event and result in the same format and layout; Core then runs preflight, takes the lock and does everything else | 5.1, 6.1, 7.1, 7.2, 7.4, 7.6, 8, 10.1 |
| G2 | Minimum environments: Windows 10 22H2 or newer; Linux x86_64 with glibc >= 2.28 and kernel >= 4.18; macOS 14.0 or newer on Apple Silicon; REAPER 7.0 or newer supported and tested, older versions warned, not blocked; Intel macOS is a later route, its users stay on 2.3.x | 6.2, 7.1, 10.3, 11, 12.3, 13 |
| G3 | Inno's built-in download with the manifest's required SHA-256, progress in the same window; extraction with the in-box `tar.exe`, started hidden by Inno itself; no VBScript, no PowerShell; `curl.exe` fallback only if Inno lacks hash-verified download | 6.1, 12.3, 13 |
| G4 | Manifest: line-oriented, tab-separated, readable by Inno Pascal and `sh`; one source of truth | 6.2 |

## 1. Purpose, scope, non-goals

**Purpose.** Define one installation contract that provisions, verifies,
repairs and removes the optional modules of STEMwerk 2.4, and choose the
smallest complete first route to build against it.

**Principles (PROPOSED).**

1. Core owns all installation logic. Every front end (the Windows
   installer, `STEMwerk-SETUP.lua`, a later external GUI) is a front end of
   ONE contract; none carries its own installation rules.
2. Provisioning, repair and removal run outside the REAPER process. A front
   end starts them, shows progress and presents results.
3. Installation never requires elevation and writes only per-user locations.

**Product scope.** Seven flows: Normal Stems, 6-Stem, Direct Kit, Kit Split,
Vocals HQ, De-Reverb, Vocal De-Reverb (REPORTED, PR #107 (unmerged) body,
"Summary"). PR #107 also requires a Setup and Component Manager with
Install, Add, Remove, Repair, Verify and Refresh lifecycle actions, and
states that REAPER "remains the control surface, not the package manager"
(REPORTED, PR #107 (unmerged) body, "Required Setup & Component Manager").
This document designs the Core side of that contract.

**Where the code is today.** The Core catalog contains three workflows:
`normal_stems`, `drum_kit_direct`, `drum_kit_split`
(`CORE/catalog/workflows.v1.json:5,28,47`) and five models: `htdemucs`,
`htdemucs_ft`, `htdemucs_6s`, `hdemucs_mmi`, `drumsep_mdx23c`
(`CORE/catalog/models.v1.json:5,12,19,26,33`). Vocals HQ, De-Reverb and
Vocal De-Reverb have no catalog entry at HEAD. PR #107 describes De-Reverb
and Vocal De-Reverb as "not implemented or registered", and Vocals HQ as a
"dev-only runtime proof" under the hidden, experimental registry ID
`bs_roformer_viperx` with "no user-facing activation" (REPORTED, PR #107
(unmerged) diff, "Required flow contract" and "Vocals HQ"). That ID does
not occur in any tracked file at HEAD (EXISTING: `git grep` at HEAD, no
match).

**Non-goals.**

- No GUI design beyond what the contract needs (events, states, errors).
- No GPU enablement, no new device support, no inference changes.
- No offline/all-models artifacts; PR #107 defers that decision to a
  release-candidate review (REPORTED, PR #107 (unmerged) body,
  "Offline/all-models release decision").
- No 2.3.x support fixes; those stay on their own branches (section 13).
- No release qualification (section 12).

## 2. Three axes, never merged into one status

A module has three independent statuses. A front end must show them
separately and must never collapse them into one badge.

### 2.1 Installation state

PROPOSED. A module is **installed** if and only if every required runtime,
FFmpeg, asset and activation component of the module is present AND passes
the installation contract's verification (section 3). Values:

| Value | Meaning |
| --- | --- |
| `not_installed` | Verification finds no component of the module |
| `partial` | Every present component passes; at least one is missing |
| `installed` | All components present and verified |
| `repair_required` | At least one present component fails verification |
| `unknown` | Verification of at least one component could not run |

**Precedence (PROPOSED).** Each component is classified as absent,
present-failing, present-passing or unverifiable. The module state is the
first rule that matches:

1. Any component present-failing: `repair_required`. This wins over
   `partial`: a module with one missing and one corrupt component is
   `repair_required`, because a missing component never hides a corrupt one.
2. Any component unverifiable: `unknown`.
3. All components absent: `not_installed`.
4. Any component absent: `partial`. A module whose files are intact but
   whose activation is missing is `partial` (section 3.1).
5. Otherwise: `installed`.

Examples of `unknown`: `<root>` or a receipt cannot be read, or a receipt
was written by a newer contract MAJOR (section 9). A held install lock is
NOT a reason for `unknown`. `verify` is read-only and never takes the lock
(section 8); published components are immutable and appear through a single
no-replace rename, so a concurrent install cannot expose a half-written
component to `verify`. While a live lock exists, `verify` still reports the
state it observes and adds `operation_in_progress: true` with the
operation ID from the lock, so a front end can say "installation running"
instead of the state.

Installation state is a property of the files and the contract. It does not
depend on hardware that may be temporarily absent.

### 2.2 Readiness now

PROPOSED. Readiness answers a different question: can the chosen workflow run
now on the chosen device? A missing GPU does not undo an installation. The
required output shape is, for example:

```text
module: drum_kit   installation: installed
readiness: not_ready   requested_device: cuda:0
  reason: device_unavailable   (chosen GPU not present)
  alternatives: [ {device: cpu, available: true, automatic: false} ]
```

Showing CPU as an alternative is NOT permission for automatic fallback. In
2.3 a failed GPU setup fell back to CPU without telling the user (REPORTED,
issue #130: "fails and fall backs to CPU"). Core already encodes the rule that
a CPU result for an explicitly requested non-CPU device is an "unexpected CPU
downgrade" (EXISTING: `CORE/device_policy.py:81-86`,
`CORE/device_policy.py:158-163`, `CORE/runtime_resolution.py:94-99`), and PR
#107 requires that the manager "never silently fall back to another backend"
(REPORTED, PR #107 (unmerged) diff, "Minimum 2.4 capabilities" item 5). The
installation contract adopts this: a device switch is always an explicit user
action, never a result of install, verify or repair.

Existing readiness already reports per-component verdicts with the shared
vocabulary PASS, FAIL, SKIPPED, UNAVAILABLE, NOT_APPLICABLE
(EXISTING: `CORE/verdicts.py:10-14`) in the document kind
`stemwerk_readiness_report` (EXISTING: `CORE/readiness.py:93-94`). Readiness
stays the authority for axis 2; this design adds no second readiness model.

### 2.3 Ownership

PROPOSED. Ownership says who may change or remove a component. It is
recorded per component, not per module. Values:

| Value | May Core modify or remove it? |
| --- | --- |
| `core_managed` | Yes, only through the contract's verified operations |
| `adopted` | Yes, after an explicit adoption record (section 4) |
| `external` | No. Core may reuse it read-only |
| `unknown` | No |

EXISTING today: every ownership assessment is `unknown`, including paths under
managed directories (`docs/dev/Core_Installation_Plan_Preview.md:16-19`;
`CORE/installation_plan.py:508`), and the materialization receipt "does not
promote readiness ownership to `verified_managed`"
(`docs/dev/Core_DrumSep_Asset_Materialization.md:170-171`). `core_managed`
becomes reachable only when Core creates a component through the new route and
records it in a module receipt (section 3.2).

## 3. Installation contract

### 3.1 Required components per module

PROPOSED. A module descriptor lists components of four kinds. Each has a
verification rule; "present" without verification never counts.

| Kind | Examples | Verified by |
| --- | --- | --- |
| Runtime | Python interpreter, venv, pinned wheels | Interpreter runs; import and version checks against the pinned set |
| FFmpeg | STEMwerk's own `ffmpeg` and `ffprobe` pair (D11) | Size and SHA-256 against the manifest; both run; versions match the manifest; encode/decode probes (section 3.6) |
| Asset | Model checkpoint and config | Exact size and SHA-256 against Core pins |
| Activation | Front-end registration | Front-end-specific check, below |

**Activation.** "Activation" is what makes an installed module usable from a
front end. For REAPER it includes registering the actions (REPORTED, issue
#121: "no stemwerk action after install"; fixed for 2.3.1.3 per the
maintainer's closing comment). Activation is verified as its own component:
a module whose files are intact but whose action is not registered is
`partial`, not `installed` (precedence rule 4 in section 2.1).

**What exists for verification today (EXISTING).**

- DrumSep runtime verification imports `audio_separator`, `numpy`, `torch`,
  `onnx`, `onnxruntime` in the candidate interpreter with a 120 s timeout
  (`CORE/drumsep_runtime.py:30`, `CORE/drumsep_runtime.py:288-310`).
- DrumSep assets are checked by filename and SHA-256 from pins
  (`CORE/model_assets.py:20-23`, `CORE/model_assets.py:26-42`;
  `CORE/readiness.py:568-587`, `CORE/readiness.py:684-688`).
- Demucs model presence is checked without hashes; the preview keeps
  `integrity="unverified"` for it
  (`docs/dev/Core_Installation_Plan_Preview.md:136-137`).
- FFmpeg discovery is read-only path probing over environment variables,
  runtime bases, state files and finally `PATH`
  (`CORE/managed_runtime.py:83-130`).

**What does not exist.** There is no module descriptor, no activation check
in Core, no FFmpeg pair validator in Core with a stated reason (the 2.3
message was "ignoring invalid ffmpeg pair", REPORTED, issue #120), and no
single `verify` operation that composes these checks.

### 3.2 Module receipt

PROPOSED. A **module receipt** is a versioned JSON file written by Core at the
end of an install or verify operation. Rules:

1. It records the outcome of that operation: module ID, contract version,
   per-component identity (path, version, SHA-256 where applicable),
   ownership value, verification result, operation ID, and a tool version.
   It carries no timestamps that affect fingerprints of inputs.
2. It is **not proof** that the installation is still intact. Only a fresh
   verification is proof. Consumers must re-verify before relying on it.
3. Its presence alone grants no right to modify or remove anything. Mutation
   rights come from the ownership value of each component, and `core_managed`
   is only valid when verification of that component currently passes.
4. Detection of an installation goes through the registry (section 5.1), the
   receipt and verification, never through guessing directory layouts. Issue
   #123 (Linux, gfx1031, "Tried running and repairing multiple times") shows
   the cost of ambiguous layouts; Core already keeps two root conventions
   deliberately unmerged (EXISTING: `CORE/managed_runtime.py:12-17`), and the
   existing venv names `.venv`, `.venv-drumsep`, `.venv-drumsep-rocm`,
   `.venv-drumsep-cuda`, `.venv-drumsep-directml` are discovered by name
   (EXISTING: `CORE/managed_runtime.py:166-168`,
   `CORE/managed_runtime.py:177-182`). Name-based discovery stays a
   read-only legacy path that can produce `external`/`unknown` ownership
   only; it never yields `core_managed`.

### 3.3 Relationship to the asset materialization receipt

EXISTING: `stemwerk-materialization-receipt.v1.json` is written inside the
published asset directory and records operation UUID, destination, pin policy
identity and fingerprint, both filenames with verified SHA-256 values, and the
created names (`CORE/asset_materialization.py:29`;
`docs/dev/Core_DrumSep_Asset_Materialization.md:158-172`). The doc states it
covers that operation only, is not a signature, licence evidence, adoption
record or permission to overwrite, repair or remove.

PROPOSED relationship: the asset receipt stays unchanged and is **evidence
input** to the module receipt (the asset component references its operation
ID and receipt SHA-256). The module receipt lives outside the asset directory,
in `<root>/state/modules/` (section 5.1), so an asset set remains a
self-contained, immutable unit (DECIDED, D1). The module receipt never
replaces the asset receipt and never re-labels it as ownership authority;
ownership comes from the module receipt's own operation.

### 3.4 Dependency policy

PROPOSED.

1. **Fully pinned per platform.** Every package in a managed runtime is pinned
   to an exact version, including transitive packages that have caused
   failures. Issue #113: an unpinned `librosa` resolved to 1.0.0 and broke
   Direct Kit (REPORTED; fixed in 2.3.1.1 by pinning 0.11.0 per the
   maintainer's closing comment). The pin set is data, hash-addressed, and
   verified after install.
2. **Binary-only installs.** Core never builds from source on a user machine:
   `--only-binary=:all:` (or per-package equivalents) for every install, and a
   missing wheel is a clear, named failure (`binary_wheel_unavailable`), not
   a compiler error.
3. **Platform-scoped pins that do not leak.** A pin needed for one platform
   must not alter another. Lesson from the Monterey ONNX fix (REPORTED,
   2.3.1.3 hotfix worktree, not in 2.4): the pin is chosen by a function of
   (architecture, OS major) that returns empty elsewhere (worktree
   `scripts/reaper/STEMwerk_Bootstrap_macOS.sh:56`,
   `select_macos_onnx_version`), is installed with `--only-binary=onnx`
   (same file, line 1775), and the test executes the production selector and
   asserts empty results for Apple Silicon and macOS 13+ (worktree
   `tests/test_macos_monterey_onnx_hotfix_2313.py`). EXISTING at HEAD:
   platform constraint files already exist per backend
   (`scripts/reaper/constraints/base.txt`, `cuda.txt`, `directml.txt`,
   `macos.txt`, `macos-intel.txt`).

### 3.5 Repair states

PROPOSED, from the Monterey bootstrap lesson (REPORTED, worktree
`scripts/reaper/STEMwerk_Bootstrap_macOS.sh:1671-1736`: policy states
`match`, `mismatch` -> `repair_required`, `broken` -> `rebuild_required`,
`missing`):

| Observed | Action | Destructive? |
| --- | --- | --- |
| Healthy and matches the pin set | Preserve and continue | No |
| Missing, or import-broken | Rebuild required | Yes (new component) |
| Importable but wrong version | Repair required | Yes (replace) |

Rule: **resolve the full plan before any destructive action.** The probe and
the plan (including pip dry-run resolution) complete first; nothing is removed
until the whole plan is known to be satisfiable. A failed plan leaves the
existing installation untouched. The Monterey worktree test writes a
`HEALTHY_RUNTIME_MUST_SURVIVE_REPAIR` sentinel and asserts it is unchanged
after repair (REPORTED, worktree
`tests/test_macos_intel_bootstrap_steps_2313.py:131-132,200`; the HEAD copy
of that test has no such sentinel). Issue #113 documented the opposite: "on
verify failure it deletes and recreates the venv, reinstalling the same
broken combination".

Repair is defined here but not built in the first route (section 10.3).

### 3.6 FFmpeg

**Today (EXISTING, re-read at HEAD).** Each 2.3 route gets FFmpeg
differently, and none validates more than "the tools run and print an
FFmpeg banner":

| Route | Source today | Pin and integrity | Validation |
| --- | --- | --- | --- |
| Windows bundled | Gyan 9.0.1 essentials from Gyan's GitHub release | URL and SHA-256 pinned (`installer/windows/fetch_runtime_assets.sh:26-28`, `fetch_runtime_assets.ps1:36-38`), verified by `verify_sha256` / `Verify-Sha256` (`.sh:53-84`, `.ps1:86-87`); fetched by `.github/workflows/release-installers.yml:196-201`, embedded by `installer/windows/STEMwerk.iss:154-155` | Pair check below |
| Windows online | Rolling `https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip` (`scripts/reaper/STEMwerk_Bootstrap_Windows.ps1:159-160`) | No version or hash; the archive check is a 1 MB minimum and `bin/ffmpeg.exe`/`bin/ffprobe.exe` entries (`TestFfmpegArchive`, same file `:730-746`); SHA-256 is only used for DrumSep assets (`:2548-2600`) | Pair check below |
| Linux | First executable of `<runtime>/bin`, `<runtime>/ffmpeg/bin`, `/usr/local/bin`, `/usr/bin`, `/snap/bin` (`scripts/reaper/STEMwerk_Bootstrap_Linux.sh:2775-2786`); else `imageio-ffmpeg==0.6.0` in the venv (`:16`, `:843-870`, `:2788-2798`) | Package version only; no archive pin; no `ffprobe` | `-version` exit code only (`:2799-2805`) |
| macOS arm64 bundled | STEMwerk's own build of official FFmpeg 8.0.3 source, LGPL-2.1-or-later, static, `--disable-network`, `--disable-autodetect` (`tools/macos_ffmpeg.py:19-22,39-51`) | Source SHA-256 checked before build (`:436-439`); build only on native Apple Silicon (`:430-431`); `CONFIG_GPL`/`CONFIG_NONFREE` must be 0 (`:459-465`); release audit `validate_ffmpeg_pair` and `validate_official_provenance` (`:313`, `:511`); no LAME, so no MP3 encoder (no `lame`/`mp3` in the file) | Runtime: sibling `ffprobe`, executable, `-version`, banner check below (`scripts/reaper/STEMwerk_Bootstrap_macOS.sh:107-160`) |
| macOS online | Any validated pair from bundled, runtime, Homebrew, MacPorts, `/usr/local` or `PATH` (`STEMwerk_Bootstrap_macOS.sh:2078-2112`) | None | Same runtime check |

The Windows "invalid FFmpeg pair" check (`TestFfmpegPair`,
`scripts/reaper/STEMwerk_Bootstrap_Windows.ps1:706-727`) requires a sibling
`ffprobe.exe` and a zero exit code from `-version` of both; line 920 logs
`Ignoring invalid FFmpeg pair: <path> reason=<reason>`. It compares no
versions, checks no codecs, verifies no hash and establishes no licence.
The macOS `validate_ffmpeg_pair` goes one step further: the first output
line must start with `ffmpeg version ` or `ffprobe version `, else
`ffmpeg_identity_mismatch` or `ffprobe_identity_mismatch`, and `dyld`
errors are named `*_dependency_failed`
(`scripts/reaper/STEMwerk_Bootstrap_macOS.sh:107-160`, banners at
`:139-142,153-156`). Core readiness runs `ffmpeg -version` over the
discovered candidates and accepts exit 0 with stdout starting with
`ffmpeg` (`CORE/readiness_collect.py:863-906`, prefix check `:886`). Both
are identity checks of the banner, not of a version, build or hash.

Licences of today's binaries (REPORTED, Astra research 2026-10-30): Gyan
builds are GPLv3 (https://www.gyan.dev/ffmpeg/builds/); the binary that
`imageio-ffmpeg` 0.6.0 selects is a John Van Sickle static build, GPLv3
(https://raw.githubusercontent.com/imageio/imageio-ffmpeg/v0.6.0/imageio_ffmpeg/_definitions.py,
https://johnvansickle.com/ffmpeg/); STEMwerk's own macOS build is
LGPL-2.1-or-later (EXISTING, `tools/macos_ffmpeg.py:22`). Reports #119
(custom-path pair not found) and #120 ("ignoring invalid ffmpeg pair"
without the failed condition) are the user-visible cost (REPORTED, issues
#119, #120).

**Migration.** FFmpeg from a 2.3 installation is legacy: ownership
`external`, never adopted and never repaired (D10, D11).

**Decisions.** DECIDED (D11, F1-F4):

- Only STEMwerk's own pinned `ffmpeg`/`ffprobe` pair is installed and used
  in v1. Reuse of a system FFmpeg is parked (section 12, O16).
- Output formats in v1 are WAV and FLAC only; MP3 is parked (F1; O49).
- Static builds (F4): fewer moving parts, no DLL or shared-library
  conflicts; preflight counts their size (section 7.1).
- macOS arm64 (F2): STEMwerk's own LGPL build from the existing recipe,
  published as a STEMwerk release asset with its licence text and pointers
  to the official FFmpeg source tarball and to the recipe. macOS x86_64 is
  parked (O50).
- Windows and Linux (F3): BtbN LGPL month-end builds. The final pins are
  chosen in slice S7 with native qualification.

CANDIDATE pins for F3 (REPORTED, Astra research 2026-10-30; release
`autobuild-2026-09-30-13-08`, checksums from
https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-09-30-13-08/checksums.sha256):

| Target | Asset | Bytes | SHA-256 (published) |
| --- | --- | --- | --- |
| Windows x86_64 | `ffmpeg-n9.0.2-17-g2a571b6068-win64-lgpl-9.0.zip` | 171,535,354 (API size; not downloaded) | `6b264b9e6019103f601d98c292bd332fd87acf1c5e941ddff4fb71760fe63432` |
| Linux x86_64 | `ffmpeg-n9.0.2-17-g2a571b6068-linux64-lgpl-9.0.tar.xz` | 137,863,452 (measured) | `2d41cbea0ca1a15029b638330740f78d6f5aeb062355bf425433fc938705350a` (measured hash matches) |

Linux probe of that candidate (REPORTED, Astra research 2026-10-30, on a
Linux host): encoders and decoders `flac`, `pcm_s16le`, `pcm_s24le`,
`pcm_f32le` present; `-buildconf` has `--enable-version3` and neither
`--enable-gpl` nor `--enable-nonfree`; `-L` reports LGPL version 3 or later;
`ffprobe -version` names the same build; extracted `ffmpeg` and `ffprobe`
are 142,534,568 and 142,305,128 bytes. The Windows build's capabilities are
untested. BtbN keeps month-end builds for about two years and only the
last 14 daily builds (REPORTED,
https://github.com/BtbN/FFmpeg-Builds/blob/master/README.md).

**Rules (PROPOSED).**

- **Our pair, always.** The worker receives the explicit path of our pair,
  or our directory first in the worker's own environment; never the user's
  `PATH`. EXISTING discovery honors `STEMWERK_FFMPEG_PATH`, `FFMPEG_PATH`,
  `IMAGEIO_FFMPEG_EXE` and ends with `shutil.which("ffmpeg")`
  (`CORE/managed_runtime.py:104-105,127-128`); the route does not use that
  discovery for modules it installed (criterion C19).
- **Verify includes probes.** `verify` checks size and SHA-256 against the
  manifest, both versions against the manifest, and runs a tiny encode and
  decode round trip for WAV and FLAC with our pair (criterion C20).
  EXISTING: the DrumSep worker requests `output_format: "WAV"`
  (`scripts/reaper/_internal/stemwerk_drumsep_process.py:900`).

## 4. Reuse vs adoption

DECIDED (D10): reuse is read-only with ownership `external`; adoption is
opt-in.

Components that may already exist: a 2.3.x ReaPack or installer payload, the
standalone, a user-provided Python, a user-provided FFmpeg (issues #119,
#120). Reuse means Core reads and runs the component after verifying it. It
does not make Core the owner and grants no right to adopt, repair or remove
it. For FFmpeg, v1 does not reuse at all (D11, section 3.6).

| Option | Effect | Default |
| --- | --- | --- |
| Reuse read-only | Verified, used, ownership `external`; never modified | **Default** |
| Adopt | Explicit user action; Core records ownership `adopted` with a receipt | Opt-in; designed, not built in v1 |
| Replace with managed copy | Core installs its own; the old one is left alone | Opt-in |
| Repair/remove external | Not offered | Never |

The adopt path is specified by this section and section 3.2 so that the
receipt format leaves room for it, but it is not built in v1 (section 12,
O21).

**Rejection must state the exact reason.** When a user component fails
verification, the result names the check, the observed value and the expected
value, for example `ffprobe_version_mismatch: ffmpeg 8.0.1, ffprobe 7.1`.
Python 3.14 is rejected with the reason "outside the supported range",
because the pinned ML stack supports 3.11 and 3.12 on Windows (REPORTED,
maintainer comment on #120) and the vendored Core declares
`requires-python = ">=3.10,<3.13"`
(EXISTING: `scripts/reaper/vendor/stemwerk-core/pyproject.toml:9`).

**Migration of an old payload.** An old 2.3.x payload is detected only via
its known marker files and treated as `external` until adopted or replaced.
Mixed states have caused failures: issue #112 (an older installer copy
launched while newer ReaPack files sat beside it) and issue #111 (ReaPack
updated the scripts while the `.pkg` payload was still the old one)
(REPORTED, both closed). The route must surface a duplicate-installation
finding instead of choosing silently (criterion C16).

**What ReaPack can and cannot deliver.** ReaPack can deliver Lua, helper
scripts and descriptors; it cannot install heavy payloads such as a macOS
`.pkg` (REPORTED, maintainer comment on issue #111: "ReaPack updates the
REAPER scripts, but it cannot install the macOS .pkg bundle"). This matches
the existing architecture note "No large runtime binaries in `index.xml`"
(EXISTING: `docs/dev/STEMwerk_Managed_Runtime_Architecture.md:76-79`).
Therefore the heavy path is always: ReaPack (or an installer) places a small
launcher; Core downloads and verifies the payload.

## 5. Per-user locations, no elevation, Unicode

### 5.1 Locations and target layout

EXISTING: the managed runtime root is `%LOCALAPPDATA%\STEMwerk` on Windows,
`~/Library/Application Support/STEMwerk` on macOS, and
`$XDG_DATA_HOME/STEMwerk` or `~/.local/share/STEMwerk` on Linux; the model
cache is `<root>/models`; legacy runtime bases are probed for state files in
`state/` (`CORE/managed_runtime.py:138-155`,
`CORE/managed_runtime.py:189-193`, `CORE/managed_runtime.py:114-121`).

DECIDED (D1) target layout under the same root (`<root>`), with details
PROPOSED where marked:

| Path | Content |
| --- | --- |
| `<root>/assets/<set-id>/` | Immutable published asset set, each with its own asset receipt (D1) |
| `<root>/runtimes/python/<pin-id>/` | Managed Python published by the outer layer, named after its manifest record so a verified copy is reused (PROPOSED; G1) |
| `<root>/runtimes/<module>/<id>/` | Module venv built by Core, one directory per immutable runtime ID (PROPOSED) |
| `<root>/runtimes/ffmpeg/<id>/` | STEMwerk's pinned FFmpeg pair (PROPOSED; D11) |
| `<root>/state/module-registry.v1.json` | Registry: module -> set-id (D1); runtime and FFmpeg IDs (PROPOSED) |
| `<root>/state/modules/<module>.receipt.json` | Module receipt (section 3.2) |
| `<root>/state/locks/install.lock` | Installation lock (D8, section 8) |
| `<root>/logs/<op>/` | `events.ndjson`, `result.json`, `cancel.request`, `started`, tool logs (D5, D6, F9) |
| `<root>/tmp/<op>/` | Staging, download workspace and journal, on the same volume |
| `<root>/models/` | Legacy model cache: read-only, ownership `external` or `unknown` (D1) |

`<op>` is the operation ID (section 7.2).

**Registry rules.** DECIDED (D1): the registry is small, written
atomically, and is the only way readiness and the worker find a module's
asset set. There are no symlinks and no pointer files. PROPOSED details:

- Core writes it only under the install lock, as a new file in
  `<root>/state/` followed by one atomic replace. This is the only replacing
  rename in the design; every published component uses the no-replace rename.
- Extending the registry to runtime and FFmpeg IDs uses the same mechanism;
  this extension is PROPOSED, not part of D1.
- A registry entry is a resolution hint, not proof: resolution is followed
  by verification, as for the receipt (section 3.2).
- Readiness passes the resolved set directory as the asset base. EXISTING:
  `drumsep_asset_evidence` already accepts an explicit `model_cache_dir` and
  falls back to `managed_model_cache_dir()` otherwise
  (`CORE/model_assets.py:26-35`). For modules without a registry entry,
  readiness keeps today's legacy behavior, including the
  `AUDIO_SEPARATOR_MODEL_DIR` override (`CORE/managed_runtime.py:189-193`).
- Old asset sets stay in place after a newer set is registered; removing
  them is part of the later remove operation, not of the first route.

Setup and repair never elevate. If a path needs elevation, the operation
fails with a named error; it does not prompt (PROPOSED). PR #107 asks the
Windows Setup to account for UAC (REPORTED, PR #107 (unmerged) diff,
"Platform-specific execution"); this design asks that the Core operations
themselves stay unelevated. The existing Windows installer already runs per
user (EXISTING: `PrivilegesRequired=lowest`,
`installer/windows/STEMwerk.iss:100`).

Staging must be on the same volume as the destination, because publication
uses a single no-replace rename (EXISTING:
`docs/dev/Core_DrumSep_Asset_Materialization.md:91-93`). Today acquisition
uses the OS temporary directory (EXISTING: `CORE/asset_preparation.py:170`);
this is a gap for low-space and cross-volume cases (section 7.1).

OneDrive and other reparse points are refused by design, including a
destination under a OneDrive-synced Documents folder (EXISTING:
`docs/dev/Core_DrumSep_Asset_Materialization.md:43-49`). `%LOCALAPPDATA%` is
not redirected by default, but the route must report the exact refusal
reason if a user's profile is redirected.

Windows path length is a route risk: a deep `site-packages` tree under
`%LOCALAPPDATA%\STEMwerk\runtimes\…` can exceed the classic 260-character
`MAX_PATH` limit (section 12, O9).

### 5.2 Unicode must survive end to end

Acceptance criterion (PROPOSED): every component named in the route handles
non-ASCII user names and paths without loss, from the first prompt to the
last log line: installer or shell wrapper, Python, subprocess arguments and
environment, state files, event and result files, logs, preflight checks,
and process launching.

Reason (REPORTED): two independent Windows reports with non-ASCII user
names: issue #134 ("ä", open) and issue #128 ("Ñ", closed 2026-10-28).
In both, the support bundle showed the character replaced with `?` or `�` in
some stored paths (maintainer comments on #128 and #134). The root cause is
unproven. In particular, an internal maintainer forensics note (project
memory, not in the repository) attributes #128 to a non-Unicode cause; that
note is unverified here and the criterion stays regardless, because #134 is
open and shows a path replaced with `?`. The root cause gates qualification
of the route (W2, S10, S11), not its construction (section 12, O1).

EXISTING partial coverage: Core's publication uses the Unicode `MoveFileExW`
API (`docs/dev/Core_DrumSep_Asset_Materialization.md:87-89`), the
materialization and preparation CLIs write JSON with `ensure_ascii=False`
(`CORE/asset_materialization.py:1079,1090`,
`CORE/asset_preparation.py:814,827,839`), and `managed_runtime` reads state
files as UTF-8 with `errors="ignore"` (`CORE/managed_runtime.py:36`).
The last one is a hazard: undecodable bytes are silently dropped, which can
turn a path into a different valid path. The route must read state strictly
and fail with a named error.

## 6. Bootstrap without an existing Python

Goal: from a fresh non-admin account with no Python, a small outer layer
obtains, verifies and publishes a managed Python and hands over to Core
(G1).

### 6.1 The outer layer

DECIDED (D12): no new technology in v1.

| OS | Outer layer (D12) | Notes |
| --- | --- | --- |
| Windows | Inno Setup, per user, `PrivilegesRequired=lowest`, ONE window: it bootstraps the managed Python (G1), then starts Core and shows Core's progress on a progress page by reading the events file | Download and unpack per G3, below |
| macOS | The existing bootstrap shell script, started by `STEMwerk-SETUP.lua`; delivered via ReaPack or the existing `.pkg` | Signing and notarisation of the outer layer required for release; a documented manual step for test builds; runtime payloads: section 6.6 (F7) |
| Linux | The existing bootstrap shell script, started by `STEMwerk-SETUP.lua`; delivered via ReaPack or the existing Linux installers | Needs `curl` or `wget`; absence is a named error |

EXISTING: both bootstrap scripts start with `#!/bin/sh`
(`scripts/reaper/STEMwerk_Bootstrap_Linux.sh:1`,
`scripts/reaper/STEMwerk_Bootstrap_macOS.sh:1`), and the REAPER entry point
is `scripts/reaper/STEMwerk-SETUP.lua`, which loads
`_internal/STEMwerk_Setup_Internal.lua`
(`scripts/reaper/STEMwerk-SETUP.lua:62-65`). The owner's decisions name it
"STEMwerk_SETUP.lua"; this document uses the file name at HEAD.

**Bootstrap order and lock ownership (DECIDED, G1).** On a fresh account
the order is bootstrap -> preflight -> lock -> rest. The outer layer (Inno
on Windows, the bootstrap shell on macOS and Linux) does only this:

1. Fetch the pinned managed-Python archive named by the manifest (section
   6.2) into the per-operation staging directory `<root>/tmp/<op>/`.
2. Verify size, then SHA-256, against the manifest. A mismatch is a named
   failure and nothing is unpacked.
3. Unpack into that staging directory.
4. Publish to `<root>/runtimes/python/<pin-id>/` with a no-replace rename.
   If a verified runtime already exists there, reuse it and remove the
   staging. A concurrent bootstrap that loses the rename does the same.
   PROPOSED: "verified" here means the interpreter reports the pinned
   version; Core's `verify` checks the runtime in depth.

It writes its early events in the same NDJSON format and the same
`<root>/logs/<op>/` layout as Core (section 7.2) and, on failure, an honest
`failed` event and a result file in the same format (criterion C22). It
does nothing else. It then starts Core with the published Python
(`python -I -B -m stemwerk_core.module_install …`); Core runs preflight,
takes the lock and performs everything else, including the module venv
into which Core and the wheels are installed. How the shipped Core source
is importable under `-I` before that venv exists is open (O54); S5
resolves it. On macOS and Linux the existing scripts gain a narrow mode
for this; their 2.3 logic is not reused by the route.

**Carve-out (G1).** Wherever this document says "only Core mutates, always
under the lock", this exception applies: before Core runs, the outer layer
may write only its staging directory, the no-replace publish of the
managed Python, and the operation's files in `<root>/logs/<op>/` (events,
result, its own stdout/stderr logs). It never writes the registry,
receipts, venvs, FFmpeg or assets.

**Windows download and unpack (DECIDED, G3).** Inno downloads the archive
with its built-in download support and the manifest's SHA-256 as the
required hash, with progress in the same single window, and extracts it
with the in-box `tar.exe`, started hidden by Inno itself; no VBScript and
no PowerShell (section 6.5). The primary variant applies, not the
`curl.exe` fallback:

- Inno version at HEAD (EXISTING): not pinned. CI runs
  `choco install innosetup` without a version
  (`.github/workflows/release-installers.yml:174-177`) and calls
  `Inno Setup 6\ISCC.exe` (`:192-194`, `:207-211`); the script has no
  `#if Ver` check, no `MinVersion` and no download code. It uses
  `WizardStyle=modern dynamic` and `IsDarkInstallMode`, plus
  `*DynamicDark` images (`installer/windows/STEMwerk.iss:95,280`;
  `:74,83`); the dynamic style, `IsDarkInstallMode` and new `DynamicDark`
  directives arrived in Inno 6.6.0 of 2025-11-11 (REPORTED,
  https://jrsoftware.org/files/is6-whatsnew.htm). Any build that compiles
  today therefore uses 6.6.0 or newer; the latest listed is 6.7.4.
- Hash-verified download (REPORTED): `DownloadTemporaryFile` and
  `CreateDownloadPage` arrived in 6.1.0 (beta of 2020-09-13) with "SHA-256
  hash checking of the downloaded file"
  (https://jrsoftware.org/files/is6.1-whatsnew.htm). A set
  `RequiredSHA256OfFile` that does not match raises an exception
  (https://jrsoftware.org/ishelp/topic_isxfunc_downloadtemporaryfile.htm);
  the download page's `Add` takes the hash as its third argument
  (https://github.com/jrsoftware/issrc/blob/main/Examples/CodeDownloadFiles.iss).
- `tar.exe` (REPORTED): in Windows since build 17063 and based on
  libarchive's `bsdtar`
  (https://devblogs.microsoft.com/commandline/tar-and-curl-come-to-windows/,
  https://learn.microsoft.com/en-us/windows/tar/), which extracts `zip`
  and gzip-compressed tar and detects the compression when reading
  (https://man.freebsd.org/cgi/man.cgi?query=bsdtar&sektion=1). Under G1
  Inno unpacks only the python-build-standalone `.tar.gz`; the BtbN `.zip`
  is unpacked by Core.

PROPOSED details: Inno starts `tar.exe` by absolute path in the system
directory, never through `PATH` (a GNU `tar` on `PATH` is another tool),
with `Exec` and `SW_HIDE`, waits with `ewWaitUntilTerminated` and checks
the exit code (https://jrsoftware.org/ishelp/topic_isxfunc_exec.htm). It
publishes with `RenameFile`, which fails if the target exists
(https://jrsoftware.org/ishelp/topic_isxfunc_renamefile.htm). CI pins the
Inno version and the script refuses to compile below 6.6.0; S5 confirms
the system-directory path as seen from Inno's process. The installer sets
`MinVersion` to the G2 floor (section 10.3); without it Inno defaults to
6.1sp1 (REPORTED, https://jrsoftware.org/files/is6-whatsnew.htm, 6.3.0).

The external PySide6 Setup app is later work and not part of the first route
(D12; section 12, O22).

### 6.2 Trust model and manifest

DECIDED (D9): the managed Python comes from python-build-standalone. One
versioned manifest of `{url, size, sha256}` per platform lives in the
repository and is read by both the outer layer and Core. A CI job verifies
the pins against the upstream checksums for every release. Detached
signatures are deferred (section 12, O17). The same manifest mechanism
carries the FFmpeg pair (D11).

**Distribution (DECIDED, F5).** Every pinned artifact is downloaded from
its vendor by the pinned URL and checked against the manifest's size and
SHA-256. Self-mirroring is not required (parked option, O51). Instead, a
scheduled CI job (for example weekly) checks that every manifest URL is
still reachable and still matches its pinned size and SHA-256; a red job
means "bump the pin before users are affected" (O47, criterion C21). The
reason is upstream retention: BtbN keeps month-end builds for about two
years (section 3.6), and python-build-standalone publishes irregularly,
seven tags in October 2026 (REPORTED, Astra research 2026-10-30,
https://api.github.com/repos/astral-sh/python-build-standalone/releases?per_page=10).
STEMwerk's own macOS FFmpeg is a STEMwerk release asset (F2). Bundled
installers already redistribute FFmpeg today (section 3.6), so the release
step ships licence texts and source pointers with every bundled or
STEMwerk-hosted FFmpeg; that duty belongs to the release workflow and is
not left implicit (O48).

**Managed Python CANDIDATE pin (DECIDED as candidate, F6).** CPython
3.12.16, python-build-standalone build 20261026, `install_only_stripped`.
Both patch version and build date are pinned, never "latest". Release
engineering keeps the per-target licence notices from the matching full
distribution, because the stripped archives do not carry the dependency
licences (REPORTED, Astra research 2026-10-30,
https://docs.astral.sh/python-build-standalone/running/#licensing).
`x86_64-apple-darwin` is parked (O50); the libuuid notice ambiguity is
parked for release (O53). Sizes and hashes (REPORTED, Astra research
2026-10-30, from
https://github.com/astral-sh/python-build-standalone/releases/download/20261026/SHA256SUMS;
the macOS archive was also downloaded and its hash measured):

| Target | Bytes | SHA-256 |
| --- | --- | --- |
| `x86_64-pc-windows-msvc` | 22,014,416 | `1f2ab53880fc67ea323398c6388e05af28addc99a8e389209f08a51fdff4b149` |
| `x86_64-unknown-linux-gnu` | 34,505,639 | `ce4f6d0a6cfdb3bed6e44c2f9affd85943c76a42e25ad3a259002f31d6fb8a20` |
| `aarch64-apple-darwin` | 25,035,343 | `353d5f1b4fd2715e7053f12f068435d5bbad16b91e057006b5d01e0925709a7e` |

The research also reports a `libgcc_s.so.1` dependency introduced in a
recent build (python-build-standalone issue #1358); the Linux pin is
qualified in S5 on a distribution at the G2 baseline (glibc 2.28, kernel
4.18; criterion L9).

**Manifest format (DECIDED, G4).** A line-oriented text file with a
version header and one tab-separated record per artifact
(`platform name url size sha256`), readable by Inno Setup's Pascal script
and by POSIX `sh` without extra tools. Core parses the same file; there is
one source of truth.

PROPOSED details:

- Verification order: size, then SHA-256, then unpack. A mismatch is a named
  failure and nothing is unpacked.
- Core carries its own pins for assets (EXISTING:
  `CORE/model_assets.py:20-23`) and, newly, for the wheel set.
- TLS to the host is necessary but never sufficient: EXISTING acquisition
  already states "Public availability, successful HTTPS transfer and a
  SHA-256 match establish availability and content identity only"
  (`docs/dev/Core_DrumSep_Asset_Acquisition.md:291-293`).

### 6.3 Supported Python versions

DECIDED (D2): the managed runtime is CPython 3.12, and CI must unit-test
Core on both 3.11 and 3.12.

EXISTING: the macOS bootstrap already pins `3.12`
(`scripts/reaper/STEMwerk_Bootstrap_macOS.sh:16`); Core declares
`>=3.10,<3.13` (`scripts/reaper/vendor/stemwerk-core/pyproject.toml:9`);
the "CI Fast" workflow runs both its `tests` job and the native publication
jobs on Python 3.11 only (`.github/workflows/ci-full.yml:22,147`). Adding
3.12 is therefore new work (M14). 3.11 stays tested because Core is also
run read-only by existing 2.3 interpreters, and the reported Windows host
used Python 3.11.0 (REPORTED, handoff 2026-10-30).

Reason for 3.12 as the ceiling: the pinned ML stack (PyTorch, numba,
audio-separator, native dependencies) is not automatically available for
newer interpreters (REPORTED, maintainer comment on issue #120 explaining
why 3.14 is ignored). The private `socket.SocketIO._sock` dependency in
acquisition must be re-checked before any move to 3.13 (EXISTING:
`docs/dev/Core_DrumSep_Asset_Acquisition.md:177-183`).

### 6.4 Offline behavior

PROPOSED: offline is a **named state**, not a silent mode switch. If the
download is needed and the network is unreachable, the operation ends with
`network_unavailable`, leaves the previous state intact, and never "goes
online" or "goes offline" on its own (criterion C14). This matches PR #107's
"never silently go online in offline mode" (REPORTED, PR #107 (unmerged)
diff, "Minimum 2.4 capabilities" item 5). Local-source preparation already
exists and never falls back to network (EXISTING:
`docs/dev/Core_DrumSep_Asset_Preparation.md:50-51`).

### 6.5 Process launching

Issue #133: McAfee blocked `run_hidden.vbs` with error `800700E1` at line 3
(REPORTED, issue #133, open; the reporter later removed McAfee and it works).
EXISTING: the Lua workflow writes `run_hidden.vbs` in three places:

- `scripts/reaper/_internal/STEMwerk_Workflow.lua:604-677`: `WScript.Shell`
  `sh.Run cmd, 0, False` starts a hidden PowerShell (lines 671-673), run
  through `wscript`.
- `:756-770` and `:1294-1310`: `WshShell.Run "cmd /c …", 0, True` starts
  Python through a hidden `cmd /c` with redirected output (lines 767-768 and
  1307-1308), run through `cscript`.

DECIDED (D7) and PROPOSED rule: the new route never uses hidden PowerShell
via VBScript, nor any generated script, to start Core.

- **Windows.** The first route does not launch an install from REAPER.
  Install and repair go through the external installer, as today; REAPER on
  Windows shows status only (read-only readiness and `verify`) and may open
  the installer. Any future Windows launch from REAPER must also avoid the
  #133 pattern; repair from REAPER on Windows is parked (section 12, O14).
- **macOS and Linux: launch contract (DECIDED, F9).**
  1. `STEMwerk-SETUP.lua` starts the bootstrap with
     `reaper.ExecProcess(cmd, -1)`. The API documents only that `-1` means
     "no wait/terminate" (REPORTED, Astra research 2026-10-30,
     https://www.reaper.fm/sdk/reascript/reascripthelp.html#ExecProcess);
     it is silent on a new session and on survival after REAPER quits, so
     the route relies on neither, and the return value is never taken as
     success. Steps 2-4 provide the detachment.
  2. The shell stage runs under `nohup` with stdin from `/dev/null` and
     stdout/stderr redirected to files in `<root>/logs/<op>/`; `nohup`
     alone does not redirect descriptors that are already pipes (REPORTED,
     same research, https://man7.org/linux/man-pages/man1/nohup.1p.html).
  3. Once the managed Python exists, Core detaches itself with
     `subprocess.Popen(start_new_session=True, close_fds=True)` and explicit
     streams (REPORTED, same research,
     https://docs.python.org/3.12/library/subprocess.html#subprocess.Popen).
     Nothing relies on the Linux `setsid` command, which macOS may not
     provide.
  4. Core writes a startup acknowledgement file `<root>/logs/<op>/started`
     (PROPOSED name); only that file confirms the launch.
  EXISTING: the setup code already calls
  `reaper.ExecProcess(cmd, timeoutMs)` with a default timeout of 1,200,000
  ms (`scripts/reaper/_internal/STEMwerk_Setup_Internal.lua:305-308`) and
  tracks a bootstrap PID with `kill -0` / `tasklist` (same file,
  `:2245-2268`). The gates are REAPER quit, REAPER force-quit and
  reattachment after reopen (criteria L6-L8, A6-A8).

Replacing the 2.3 separation launcher is outside this design (section 12,
O25).

### 6.6 macOS signatures and quarantine

DECIDED (F7): in v1 the macOS runtime payloads (managed Python, FFmpeg)
rely on their vendor or ad-hoc signatures plus the pinned hashes, provided
a clean-Mac acceptance test of the real path passes: REAPER ->
`STEMwerk-SETUP.lua` -> bootstrap -> Core -> download -> execute Python and
FFmpeg (criterion A9). There is no blanket quarantine removal and no local
re-signing as an installation mechanism. Developer ID signing and
notarisation of runtime payloads are revisited before a public release
(O52).

Findings behind the decision (REPORTED, Astra research 2026-10-30):

- Command-line `curl` and `tar` do not set or propagate quarantine
  (https://developer.apple.com/forums/thread/706442). Python's `urllib`
  sets none either; this is an inference from the CPython 3.12.16 source,
  not a macOS observation
  (https://github.com/python/cpython/blob/v3.12.16/Lib/urllib/request.py#L222).
- Native arm64 code needs a valid signature, which may be ad-hoc
  (https://support.apple.com/en-sa/guide/security/secebb113be1/web). The
  candidate `aarch64-apple-darwin` Python carries ad-hoc, linker-signed
  code signatures (static header read, not `codesign --verify`).
- A notarised `.pkg` does not cover files Core downloads later
  (https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).
- Reports of SIGKILL with ad-hoc python-build-standalone binaries exist
  (https://github.com/astral-sh/uv/issues/16726), so only the native test
  in A9 can prove the path.

## 7. Preflight, progress and cancellation

### 7.1 Preflight

PROPOSED. Preflight is Core's first step after the bootstrap (G1) and is
read-only. Before any further download or mutation, it computes and
reports:

- **Free space** on the volume that holds `<root>`, including temporary,
  cache, extraction and venv-build space, using a measured table per module
  and platform rather than the download size. Issue #120: 3 GB announced,
  4+ GB used, failure with `[Errno 28] No space left on device` mid-install
  (REPORTED). EXISTING for 2.3 installers: the Inno Setup script asks
  for 5120 MB (online) or 12288 MB (bundled) plus 5 GiB extra
  (`installer/windows/STEMwerk.iss:44-53,114`). The Core route needs its own
  estimate, validated by an observed install (section 12, O5). It counts
  the static FFmpeg pair (F4): the Linux candidate archive is 137,863,452
  bytes and unpacks to two executables of about 142 MB each (REPORTED,
  section 3.6). Preflight does not reserve space; an `ENOSPC` later in the
  install still ends in an honest failure with nothing partially published
  (criterion C18).
- Writability and eligibility of every path (no links or reparse points).
  EXISTING for asset destinations: preparation calls the materializer's
  shared publication preflight before any acquisition
  (`docs/dev/Core_DrumSep_Asset_Preparation.md:99-102`), which refuses
  symbolic links and every reparse point
  (`docs/dev/Core_DrumSep_Asset_Materialization.md:43-49`).
- Supported platform, architecture and minimum OS version (G2, section
  10.3; criterion C23); required system runtime. On Windows
  an absent Visual C++ runtime is a named preflight error,
  `vcpp_runtime_missing` (criterion W7; REPORTED, issue #126, DLL
  initialization failure fixed by installing the redistributable). EXISTING:
  the 2.3 Windows bootstrap only warns (`LogVisualCppRuntimeStatus`,
  `scripts/reaper/STEMwerk_Bootstrap_Windows.ps1:379,408`;
  `tests/test_windows_vcpp_runtime_preflight_2313.py:8-12`).
- Windows path-length budget for the deepest planned path (section 12, O9).
- Network reachability for the hosts the plan needs (section 6.4).
- Whether an existing installation, lock or duplicate 2.3.x payload exists
  (section 4).

Preflight output is the install **plan**: a list of actions with sizes. The
user's consent applies to that plan; execution refuses to start with a plan
whose fingerprint changed (criterion C15).

### 7.2 Progress: events file and result file

EXISTING: Core has a minimal callback `ProgressCallback(percent: float,
message: str)` (`CORE/progress.py:6-10`), used for separation, not for
installation. The 2.3 Linux bootstrap reports through `set_status`, which
logs a `STATUS=… REASON=…` line and writes the state file
(`scripts/reaper/STEMwerk_Bootstrap_Linux.sh:766-773`), called for example
as `set_status "deps_failed" "torch_cpu_install_failed"` (same file,
lines 2329, 2335, 2718). The Windows bootstrap logs
`STEMWERK_STATUS detail=…` lines
(`scripts/reaper/STEMwerk_Bootstrap_Windows.ps1:308-311`), which the setup
UI strips for display
(`scripts/reaper/_internal/STEMwerk_Setup_Internal.lua:986-987`).

DECIDED (D5): events are written as NDJSON to a file, and the existing CLI
contract stays untouched. There is no `--events-fd` in v1 (section 12,
O19).

PROPOSED details:

- **Operation ID.** The front end chooses a UUID and passes it to the
  outer layer, which creates `<root>/logs/<op>/` exclusively and refuses an
  existing directory (G1). Core receives it as `--operation-id` and accepts
  the directory only if it holds the outer layer's events for the same ID
  and no result file; it continues their `seq`. Core records the ID in the
  lock while it runs and in the module receipt afterwards. The front end
  keeps the ID itself (for REAPER, for example in its persistent extended
  state) so it can find the files again after a restart.
- **Events file** `<root>/logs/<op>/events.ndjson`: one JSON object per
  line, UTF-8, `protocol: "stemwerk-install-events/1"`, with `operation_id`
  and a monotonic `seq` on every line. Each line is written with one write
  and flushed. A reader ignores an incomplete last line and re-reads it on
  the next poll. Front ends poll the file (REAPER through `reaper.defer`,
  the Windows installer through a timer).
- **Result file** `<root>/logs/<op>/result.json`, written once, atomically
  (new file, then rename), and BEFORE the same document is printed to
  stdout or stderr. It holds the exit code and the exact terminal document
  of the CLI contract below. A front end that started Core detached reads
  the result file instead of the exit code and the streams.

Event states (v1):

| `state` | Meaning | Required fields |
| --- | --- | --- |
| `active_determinate` | Working; known progress | `phase`, `done`, `total`, `unit` |
| `active_indeterminate` | Working; no measure | `phase`, `since_seconds` |
| `possibly_stalled` | No progress event beyond a phase-specific limit | `phase`, `silent_seconds` |
| `retrying` | Recoverable intermediate failure; will retry | `phase`, `error_code`, `attempt`, `max_attempts` |
| `failed` | Final failure of the phase | `phase`, `error_code`, `detail`, `action` |
| `done` | Phase finished | `phase`, `verified` |

A `waiting` state (waiting on a named external condition) is cut from v1
(section 12, O20).

Phases are ordered and named: `bootstrap` (outer layer only: fetch,
verify, unpack and publish the managed Python, G1), `preflight`, `lock`,
`create_environment`, `install_packages`, `fetch_ffmpeg`, `verify_ffmpeg`,
`fetch_assets`, `verify_assets`, `publish`, `activate`, `verify_module`.
Heartbeats are written at least every 5 seconds in any `active_*` state so
a front end can tell "alive" from "possibly stalled". Two observed failures
motivate the states: the Windows CUDA install showed only "Still running"
for 2000+ seconds (REPORTED, host report relayed to this design task; no
run ID), and the Monterey bootstrap logged `deps_failed` before finishing
`ok` (REPORTED, Monterey validation, likewise relayed; the worktree log is
not cited here). A flat status line cannot express either case; the `retrying`
state names the second.

**Terminal result.** The final result is NOT part of the event stream. It
follows the existing CLI output contract unchanged (EXISTING): one JSON
document on stdout and exit `0` on success; a handled failure prints a
versioned JSON error document on stderr and exits `2`; any other
`Exception` becomes a versioned `internal_error` document on stderr with
exit `3`, nothing on stdout, and only the exception type in the message;
`BaseException`s propagate unchanged
(`docs/dev/Core_DrumSep_Asset_Acquisition.md:41-59`;
`docs/dev/Core_DrumSep_Asset_Preparation.md:76-95`;
`CORE/asset_acquisition.py:1406-1433`, `CORE/asset_preparation.py:804-833`).
Exit `0` does not by itself mean "complete": callers must also inspect
`cleanup.complete` (EXISTING:
`docs/dev/Core_DrumSep_Asset_Materialization.md:68-69`).

Two verified limits of the existing contract: the materialization CLI
catches only `MaterializationError` and has no `internal_error` safety net
(EXISTING: `CORE/asset_materialization.py:1058-1085`), and
`cleanup.complete` is `null` for acquisition's `internal_error`
(`docs/dev/Core_DrumSep_Asset_Acquisition.md:56-57`). The first is a
fast-follow fix (slice S0; section 12, O11), the second is parked (O12).
The new module CLI gets its own safety net in S2. Because a detached Core
may run with closed or redirected streams, a `BrokenPipeError` while
printing must never prevent the result file from being written (section 12,
O2).

**Actionable messages.** Every `failed` and `retrying` event carries a stable
`error_code`, the failed check, the observed and expected values, and one
suggested `action` the front end can render. Issue #112 ("Rebuild-venv
blocked: canonical_resolution_failed") is the counter-example: a code with no
cause or next step.

### 7.3 Models are provisioned during installation

PROPOSED: all assets in the module descriptor are fetched and verified in the
install, never lazily during a separation. Issue #118: a model download
started at roughly 11-13% of processing and failed with a "check your
VPN/firewall" message (REPORTED, issue #118, closed). Readiness remains
read-only and never downloads (EXISTING: `CORE/readiness.py:684-688`;
`CORE/model_assets.py:3-6`).

### 7.4 Cancellation, retry, idempotency

DECIDED (D6): a cancel marker file is the single primary cancel mechanism
on all platforms; Core checks it at safe points; POSIX signals are only an
optional fast path; there is no dependency on `CTRL_BREAK_EVENT`.

PROPOSED details:

- **Marker.** The front end requests cancel by creating the empty file
  `<root>/logs/<op>/cancel.request`. Apart from the outer layer's
  bootstrap carve-out (section 6.1), this is the only file a front end ever
  writes under `<root>`; it is a request, not a state change. The outer
  layer checks it between its bootstrap steps (on Windows also Inno's own
  download cancel) and ends with an honest cancelled result. Core never
  removes it during the operation. `SIGINT` or `SIGTERM` on macOS and Linux
  set the same internal flag. Killing the process (`taskkill`, `kill -9`) is
  not a cancel and is handled as a crash (section 8).
- **Safe points.** At every event boundary; inside network reads between
  chunks (EXISTING acquisition is bounded by deadlines, not by a cancel
  signal: `docs/dev/Core_DrumSep_Asset_Acquisition.md:210-217`, so a cancel
  hook is new work); and during a pip step, where Core may stop its own pip
  child process because everything it builds is in staging. Never inside the
  final rename: that is one native call (EXISTING:
  `docs/dev/Core_DrumSep_Asset_Materialization.md:91-93`), so a cancel
  observed during it takes effect afterwards and the result reports whether
  publication happened (criterion C17).
- **What remains after cancel or failure.** Staging under `<root>/tmp/<op>/`
  is removed by the operation itself; the previously installed module state
  is untouched; a half-built environment is never published (it is built in
  staging and renamed in). The final status reports exactly what remains.
  EXISTING for assets: failures before publication leave pre-existing content
  untouched and remove only the operation's own staging and lock
  (`docs/dev/Core_DrumSep_Asset_Materialization.md:138-140`); an interrupt
  retains its original exception type and carries phase, publication and
  cleanup facts (`docs/dev/Core_DrumSep_Asset_Preparation.md:133-135`).
- **Retry and resume.** First route: retry is a new operation that starts
  from verification of what exists; there is no byte-range resume
  (EXISTING: "There is no resume support or persistent cache",
  `docs/dev/Core_DrumSep_Asset_Acquisition.md:231-232`). Resume is parked
  (section 12, O18).
- **Idempotency.** Running install twice on a verified module is a no-op that
  returns `installed`. EXISTING for assets: a second preparation run is
  refused with `destination_exists` and sources are unchanged (REPORTED,
  host runs on Linux, macOS and Windows; see
  `docs/dev/Core_DrumSep_Asset_Materialization.md:114-116`). The module
  operation must turn this refusal into "already installed, verified".

### 7.5 Honest final status

PROPOSED. The final status is computed from the post-install verification
(section 3), never from the process exit status of the last step. The
result is `installed` only if every required component passes. Otherwise it
lists each failed component with its error code. Issue #120 ("installer
reports working while failing to install half the files") and issue #126,
a native DLL initialization failure behind a silent CPU fallback
(`tests/test_windows_vcpp_runtime_preflight_2313.py:4-8`), both gave a
success impression despite a failed component (REPORTED).

Post-install guidance belongs in the front end, shown from the result
document, not a raw markdown file opened through the system file association
(REPORTED, issue #122: "opens as a markdown file", "contains potentially
misleading info"; the 2.3.1.3 fix made the Finished page depend on the
bootstrap result but still opens the guide through the file association,
per the maintainer's closing comment).

### 7.6 Front ends per OS

DECIDED (D7):

- **All OSes.** Any front end may READ state (registry, receipts, lock,
  events, result, `verify`, readiness). Only Core mutates, always under the
  lock (D8), except for the outer layer's bootstrap carve-out before Core
  runs (G1, section 6.1). The cancel marker (section 7.4) is a request, not
  a mutation.
  Which front end shows what is decided per OS.
- **Windows.** The Inno Setup installer is the only installing and
  repairing front end in the first route (D12). REAPER shows read-only
  status and may open the installer. Repair from REAPER on Windows stays
  parked (O14).
- **Why Windows repair is installer-only (DECIDED, F8).** It is a
  maintenance and lifecycle policy, not an elevation need. EXISTING history
  in this worktree: `c62aa41` (2026-08-28, "fix(setup): enforce
  platform-safe maintenance policy") made Windows checks read-only and
  routed repair to the installer; `787c7ec` (2026-10-02, "fix(windows):
  prevent in-REAPER repair dispatch") fixed a Windows Repair/Rebuild path
  that cleared bootstrap state and attempted `/bin/sh`; the installer has
  run per user since `375c366` (2026-03-20), which added
  `PrivilegesRequired=lowest` (today `installer/windows/STEMwerk.iss:100`;
  runtime root `{localappdata}\STEMwerk`, `:348`). The current guards are
  `scripts/reaper/_internal/STEMwerk_Runtime_Setup.lua:745-748` and
  `scripts/reaper/_internal/STEMwerk_Setup_Internal.lua:2798-2815,5585-5590`.
  Inno's `CloseApplications` only covers files Inno itself installs or
  deletes (REPORTED, Astra research 2026-10-30,
  https://jrsoftware.org/ishelp/topic_setup_closeapplications.htm), and the
  runtime is deliberately outside the script's `[InstallDelete]` boundary
  (EXISTING: `installer/windows/STEMwerk.iss:138-142`). So the installer
  alone does not stop a running separation: Core must.
- **Repair while a separation runs (DECIDED, F8).** Refused immediately
  with a clear message and the option to retry later (criterion W9). Core
  coordinates with separation jobs through in-use protection (section 8)
  and never replaces the runtime it is itself running from.
- **macOS and Linux.** `STEMwerk-SETUP.lua` is the front end. It starts the
  bootstrap detached (section 6.5), follows progress by reading the events
  file, cancels through the marker and reads the result file. DECIDED (F9):
  an install continues when REAPER is closed, but not across logout or
  shutdown; the UI says so clearly. On reopen the setup reads the lock, the
  events and the result and shows the state (criteria L6-L8, A6-A8).

PR #107 likewise asks that heavy installation not run in Lua and that the
Linux helper be "started and monitored from REAPER where appropriate"
(REPORTED, PR #107 (unmerged) diff, "Platform-specific execution").

## 8. Locking and crash recovery

**EXISTING.** Materialization takes an exclusive sibling lock file created
with `O_CREAT|O_EXCL`; a competing operation fails with
`publication_conflict` (`CORE/asset_materialization.py:424-440`). The doc
makes no `SIGKILL`, kernel-crash or power-loss claim
(`docs/dev/Core_DrumSep_Asset_Materialization.md:136,154-156`). There is
no stale-lock detection in either asset module (searched `stale` in
`CORE/asset_materialization.py` and `CORE/asset_acquisition.py`: no match).

**DECIDED (D8).** One per-user lock at `<root>/state/locks/install.lock`,
recording PID, process start time and a heartbeat. A live lock is never
broken. Both front ends mutate only through the Core CLI. The one exception
is the outer layer's bootstrap before Core runs (G1, section 6.1): it does
not take the lock, and its no-replace publish of the managed Python is safe
without it. Core takes the lock right after preflight.

**PROPOSED details.**

- First route: **one mutating installation operation per user**. Read-only
  operations (preflight, `verify`, readiness, `--describe`) never take the
  lock; they may read it to report `operation_in_progress` (section 2.1).
- The lock is created exclusively and also records the operation ID and the
  host name; the heartbeat is rewritten atomically.
- **Stale detection.** A lock is stale only if its PID is gone (or the start
  time differs) AND the heartbeat is older than a bound. A stale lock is
  removed by the next mutating operation, which then runs recovery before
  starting.
- **Recovery of half-finished operations.** Each operation writes a journal
  in `<root>/tmp/<op>/journal.json` before each mutation (what it will
  create, rename or remove). Recovery reads the journal: unpublished staging
  is removed under the existing identity checks; published results are
  verified, not deleted. Anything not recorded in a journal is never
  touched (criterion C13). The outer layer's bootstrap staging has no
  journal; its cleanup is open (O55).
- **Components in use.** Before replacing or removing a runtime or asset,
  an operation must check for a running separation that uses it, and the
  mutating process never runs from the runtime it replaces (DECIDED, F8).
  The proposed mechanism is an in-use marker written by the separation (PID
  and start time) and an immediate refusal with `component_in_use` instead
  of waiting or killing. The first route neither replaces nor removes, so
  building it is parked until repair (section 12, O13).

## 9. Contract versioning and front-end/Core negotiation

PROPOSED. Core exposes `python -I -B -m stemwerk_core.module_install
--describe` (read-only, no lock, no mutation, stdout JSON) returning:

```json
{"kind":"stemwerk_install_capabilities","contract_version":"1.0.0",
 "event_protocol":"stemwerk-install-events/1","core_version":"…",
 "modules":["drum_kit"],"operations":["plan","install","verify","cancel"],
 "platforms":["linux-x86_64","darwin-arm64","win-x86_64"]}
```

It is built in slice S2 (M15).

Rules:

- `contract_version` follows semantic versioning. A front end accepts any
  `1.x` it knows. A higher MAJOR means "do not mutate; show the update
  message".
- A front end that does not know a module or an operation hides it; it does
  not guess.
- On mismatch the front end shows exactly one of: "Core too old", "front end
  too old", or "unsupported platform", with the observed and expected
  versions, and offers no install button.
- Existing schema versions are already explicit (`schema_version="1.0.0"`
  in the preview and readiness documents: EXISTING
  `docs/dev/Core_Installation_Plan_Preview.md:9-10`, `CORE/readiness.py:93`);
  the new documents follow the same convention.

## 10. Routes

### 10.1 Route A: new installation (full)

PROPOSED sequence (order DECIDED, G1), each step is a phase in the events
file:

1. Bootstrap by the outer layer (section 6.1): fetch, verify, unpack and
   publish the managed Python no-replace, or reuse a verified copy; then
   start Core.
2. Preflight and plan (section 7.1); user consent to the plan fingerprint.
3. Acquire the lock (section 8).
4. Create the module venv from the managed Python; install the
   platform-scoped pinned wheel set, binary-only; dry-run resolve first
   (section 3.4).
5. Fetch and verify the pinned FFmpeg pair (section 3.6).
6. Fetch and verify assets (reuse EXISTING `prepare_drumsep_assets` with
   `acquire=True`, `docs/dev/Core_DrumSep_Asset_Preparation.md:39-48`),
   publishing a new set under `<root>/assets/<set-id>/` (D1).
7. Publish: no-replace rename of venv and FFmpeg directories; then the
   atomic registry update (section 5.1).
8. Activate (front-end-specific).
9. Verify the module (section 3), including the FFmpeg probes, and write the
   module receipt.
10. Write the result file, release the lock, emit the terminal result.

### 10.2 Route B: reuse of an existing installation

PROPOSED sequence:

1. Detect through registry, receipt and verification, never layout guessing.
2. Verify each found component against the pin set; give exact rejection
   reasons.
3. Classify (section 3.5): healthy -> `external` reuse, nothing written;
   broken -> report with options; wrong version -> offer "replace with
   managed copy" (Route A for that component only).
4. Write a module receipt with `external` ownership for reused components.

Route B writes almost nothing and exercises neither bootstrap nor
cancellation, so it cannot be the first route.

### 10.3 The choice

Criterion: the smallest complete route that actually exercises bootstrap,
per-user locations, progress AND cancellation. Copying assets into an already
prepared environment does not qualify.

**Chosen first route: Route A for the Direct Kit module (workflow
`drum_kit_direct`), CPU device only.**

| Candidate | Why not / why |
| --- | --- |
| Vocals HQ | No Core catalog entry at HEAD; PR #107 reports a dev-only runtime proof under the hidden, experimental ID `bs_roformer_viperx` with no user-facing activation and an open licence review (REPORTED, PR #107 (unmerged) diff, "Required flow contract") |
| De-Reverb, Vocal De-Reverb | No catalog entry; "not implemented or registered" (REPORTED, PR #107 (unmerged) diff, "Required flow contract"); the route would also have to build the module |
| Normal Stems / 6-Stem | Runtime is the same size or larger; Demucs weights have no Core integrity pins (EXISTING: `docs/dev/Core_Installation_Plan_Preview.md:136-137`), so verification would need new pins first |
| Kit Split | Superset of Direct Kit plus Normal Stems; larger, no extra contract coverage |
| **Direct Kit** | Single stage; both assets already hash-pinned (EXISTING: `CORE/model_assets.py:20-23`); acquisition, materialization and preparation primitives exist, and the preview's default module is `drum_kit` (EXISTING: `CORE/installation_plan.py:31`); runtime has its own verifier (EXISTING: `CORE/drumsep_runtime.py:288`); issues #113 and #120 exercised exactly its runtime |

**Naming.** DECIDED (D3): the engine ID stays `drumsep_mdx23c`
(`CORE/catalog/models.v1.json:33`) and the display name is "STEMwerk DKS".
PR #107 calls the model `stemwerk_dks` (REPORTED, PR #107 (unmerged) diff,
"Required flow contract"); the names are reconciled when PR #107 merges
(section 12, O30).

Justification: Direct Kit is the only module whose assets already have a
complete, tested acquire-verify-publish chain (REPORTED, CI run 40720954223
and the host runs in the handoff), so the new work is concentrated on what
the criterion requires: bootstrap, per-user locations, progress and
cancellation. CPU only keeps GPU questions (#130, #123) out of the first
route; device choice stays explicit (section 2.2).

Lifecycle scope of the first route: preflight/plan, install, verify, cancel.
Repair, update and remove are defined by the contract (3.5, 4) but are built
in a later route; they are not claimed here (section 12, O23).

Platform scope of the first route: Windows x86_64, Linux x86_64, macOS
Apple Silicon. Intel macOS is outside the module's current contract (PR #107
flow table: "current contract excludes Intel Mac" for Direct Kit, REPORTED,
PR #107 (unmerged) diff, "Required flow contract"; EXISTING at HEAD:
`tests/test_macos_intel_bootstrap_steps_2313.py:179` asserts
`DKS_SUPPORTED` is `"false"` on Intel).

**Minimum environments (DECIDED, G2).**

| Platform | Minimum | Basis |
| --- | --- | --- |
| Windows x86_64 | Windows 10 22H2 or newer, including Windows 11 | Matches the BtbN baseline (REPORTED, Astra research 2026-10-30, https://github.com/BtbN/FFmpeg-Builds/blob/master/README.md); enforced through Inno `MinVersion` (section 6.1) |
| Linux x86_64 | glibc >= 2.28 and kernel >= 4.18 | BtbN baseline (same source); the python-build-standalone Linux pin is qualified on such a distribution in S5 (issue #1358; criterion L9) |
| macOS | Apple Silicon, macOS 14.0 or newer | Set by the pinned `onnxruntime==1.27.0` wheel, minos 14.0 (EXISTING: `tools/macos_ffmpeg.py:30-37`; pin `tools/build_macos_apple_silicon_payload.py:106`), not by FFmpeg, whose build target is 12.0 (`tools/macos_ffmpeg.py:28`) |
| REAPER | 7.0 or newer supported and tested; acceptance on a current 7.x | Older versions get a clear "not tested, please update" warning, not a block; only a missing required API is a hard, clean failure (criterion C23). EXISTING: no REAPER version gate at HEAD; only the support bundle records `reaper.GetAppVersion()` (`scripts/reaper/STEMwerk_Save_Support_Bundle.lua:6089`) |

Intel macOS, including Monterey 12, is a later route with its own pin set,
based on the validated 2.3.1.3 Monterey ONNX fix (section 12, O24, O50).
Until then Intel Mac users stay on 2.3.x, including that hotfix.

### 10.4 What is missing to build it

| # | Missing | Why it blocks |
| --- | --- | --- |
| M1 | Module descriptor and `verify` that composes runtime, FFmpeg, assets, activation, with the precedence rule (2.1) | Axis 1 has no defined meaning without it |
| M2 | Module receipt writer/reader (section 3.2) | Detection without layout guessing |
| M3 | Pinned wheel set for the DrumSep CPU venv per platform, binary-only | Exists only as bootstrap-script logic, not as Core data |
| M4 | Versioned manifest for python-build-standalone and the FFmpeg pair, read by outer layer and Core; the per-release CI pin check (D9) and the scheduled URL check (F5) | No Core code obtains a Python; the narrow outer-layer mode is unwritten |
| M5 | Runtime build in staging plus no-replace publish | Existing publish is for assets only |
| M6 | Events file, result file, startup acknowledgement and cancel-marker handling (D5, D6, F9) | Only a percent/message callback exists |
| M7 | Install lock (D8) with stale detection and journal | Existing lock is per-destination, no stale logic |
| M8 | Preflight with measured space table, path-length budget and the G2 minimum-OS check | 2.3 estimate was wrong (#120) |
| M9 | Asset-set registry in `<root>/state/`, and resolution through it by readiness and the worker (D1). Today readiness verifies files under `<root>/models` (EXISTING: `CORE/model_assets.py:26-42`, `CORE/readiness.py:584-587`) and the materializer requires a new destination (EXISTING: `docs/dev/Core_DrumSep_Asset_Materialization.md:55-56`) | A published asset set must be what readiness and the worker read |
| M10 | Activation check for REAPER (action registration) | Part of "installed" |
| M11 | Final FFmpeg pins from the F3 candidates; macOS arm64 build published as a release asset with licence text and source pointers (F2); acquisition, verification, WAV/FLAC probes; worker uses the pair by explicit path (D11) | Shared component; #119, #120; no route pins or validates FFmpeg today (section 3.6) |
| M12 | Unicode test path: non-ASCII user name end to end | Acceptance criterion, #134 |
| M13 | Resolution of DrumSep weight licence for redistribution (EXISTING gap: `docs/dev/Core_DrumSep_Asset_Acquisition.md:282-296`) | Blocks release, not the build |
| M14 | Core unit tests on Python 3.11 and 3.12 in CI (D2; EXISTING: 3.11 only, `.github/workflows/ci-full.yml:22,147`) | D2 requires both |
| M15 | `--describe` capabilities endpoint (section 9) | Front ends cannot negotiate without it |
| M16 | Front ends per D7, D12, F9 and G3: Inno bootstrap (download, `tar.exe`, publish) and progress page reading the events file; `STEMwerk-SETUP.lua` launch contract (section 6.5), events reader, cancel, reattach, REAPER version warning (G2); read-only status in REAPER on Windows | No front end can drive the route |

## 11. Acceptance criteria for the chosen route

Each criterion is marked **DESCRIBED** (design only, not demonstrated) or
**PROVEN** (only the exact sub-criterion demonstrated, with evidence type).
Evidence types: *code/test* = test or code at HEAD with `file:line`;
*REPORTED* = CI or host run with source.

CI source: run 40720954223 on 9c410f9, five jobs green, native minimum 34
(REPORTED). Windows host source: Windows 11 Pro 25H2 AMD dev machine, runs 1-4
on 9c410f9 (REPORTED, handoff 2026-10-30). Other hosts predate commits 5d57bf6
and 9c410f9 (REPORTED, handoff 2026-10-28).

Acceptance environments (DECIDED, G2; section 10.3): Windows 10 22H2 or
Windows 11; a Linux x86_64 distribution at the glibc 2.28 / kernel 4.18
baseline (L9) plus a current one; macOS 14.0 or newer on Apple Silicon; a
current REAPER 7.x. Intel macOS is not an acceptance environment of this
route.

### 11.1 Common to all OS

| ID | Criterion | Status | Evidence |
| --- | --- | --- | --- |
| C1 | Fresh non-admin account without Python: install completes and verify passes | DESCRIBED | None |
| C2 | Events file shows every phase in order, with heartbeat at least every 5 s; result file matches the CLI terminal document | DESCRIBED | None |
| C3 | Cancel during download and during pip leaves the previous state intact and no staging | DESCRIBED | None |
| C4 | Second install is a verified no-op | DESCRIBED | None; sub-criterion C4a below |
| C4a | Second asset preparation is refused with `destination_exists`, sources unchanged | PROVEN (REPORTED) | Host runs on Linux, macOS, Windows (handoff 2026-10-28, run 3); Windows on 9c410f9 (handoff 2026-10-30, run 3) |
| C5 | Low free disk space: preflight refuses with required and available figures | DESCRIBED | None |
| C6 | Installation never elevates and writes only under `<root>` | DESCRIBED | None |
| C7 | Success is reported only when post-install verification passes | DESCRIBED | None |
| C8 | Lock: two concurrent installs, second fails with `lock_held`; stale lock recovered | DESCRIBED | None; asset-level exclusivity is C8a |
| C8a | Concurrent materialization to one destination: second fails on lock or rename | PROVEN (code/test + REPORTED) | `docs/dev/Core_DrumSep_Asset_Materialization.md:138-142`; `tests/test_core_asset_materialization.py:862` and `:915`; both in the native selection that ran in CI run 40720954223 |
| C9 | No-replace publication of an asset directory | PROVEN (REPORTED) | CI run 40720954223 native Linux, macOS, Windows; hosts per handoff |
| C10 | Local-source preparation with real pinned DrumSep files | PROVEN (REPORTED) | Linux/macOS/Windows hosts (handoff 2026-10-28); Windows on 9c410f9 (handoff 2026-10-30, run 3) |
| C11 | CLI `internal_error`: exit 3, empty stdout, one JSON, no leak | PROVEN (code/test + REPORTED) | `tests/test_core_asset_acquisition.py:2753`, `tests/test_core_asset_preparation.py:484`; CI run 40720954223; Windows host run 4 on 9c410f9; review of 9c410f9 (Kimi) with a real subprocess |
| C12 | Download verification: size and SHA-256 checked, retries bounded | PROVEN (code/test) | Behavior: `docs/dev/Core_DrumSep_Asset_Acquisition.md:110-119,210-217`; tests: `tests/test_core_asset_acquisition.py` (portable and native selections; CI run 40720954223) |
| C13 | Crash or power loss mid-install, then rerun: journal recovery removes unpublished staging and verifies published results | DESCRIBED | None |
| C14 | Offline machine: install ends with `network_unavailable`, previous state intact | DESCRIBED | None |
| C15 | Plan fingerprint changed between consent and execution: execution refused | DESCRIBED | None |
| C16 | Duplicate 2.3.x payload detected and surfaced, never chosen silently | DESCRIBED | None |
| C17 | Cancel during the final rename: publication either happened or not, and the result says which | DESCRIBED | None |
| C18 | `ENOSPC` mid-install despite a passing preflight: honest failure, nothing partially published | DESCRIBED | None |
| C19 | Our FFmpeg pair is used even with a system FFmpeg first on `PATH` | DESCRIBED | None |
| C20 | Encode/decode round trip with our pair passes for WAV and FLAC (F1) | DESCRIBED | None; the Linux candidate lists the codecs (REPORTED, section 3.6), no round trip was run |
| C21 | The scheduled manifest-URL check job fails on a deliberately broken pin (F5) | DESCRIBED | None |
| C22 | Bootstrap with a wrong pinned hash or a truncated archive: the outer layer writes a `failed` event and a result file in the Core format under `<root>/logs/<op>/`, publishes nothing, writes nothing outside the G1 carve-out; a second bootstrap reuses a verified runtime | DESCRIBED | None |
| C23 | Below the G2 OS floor the install is refused with observed and required versions; REAPER older than 7.0 shows "not tested, please update" and proceeds; a missing required API ends in a clean, named failure | DESCRIBED | None |
| C24 | A stale bootstrap staging directory left under `<root>/tmp/` by a crashed outer layer is removed on the next start of Core; the staging directory of an active bootstrap is never touched (O55) | DESCRIBED | None |

Note on C11: host evidence exists only for the Windows dev machine; the host
runs on other machines predate 9c410f9. The materialization CLI is not
covered (section 12, O11).

### 11.2 Per OS

| ID | OS | Criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| W1 | Windows | Account without Python, non-admin, Defender on | DESCRIBED | None |
| W2 | Windows | User name with non-ASCII character (for example "ä", "Ñ") | DESCRIBED | None; issues #134, #128 |
| W3 | Windows | Cancel via the marker file from the installer's progress page | DESCRIBED | None |
| W4 | Windows | Reparse point destination refused with exact reason | PROVEN (code/test + REPORTED) | `docs/dev/Core_DrumSep_Asset_Acquisition.md:243-264`; native Windows CI job |
| W5 | Windows | Asset publication with `MoveFileExW` on NTFS, Defender on | PROVEN (REPORTED) | Windows host runs 1-4 on 9c410f9: native 34/0/0/0 |
| W6 | Windows | Antivirus launch of helper not flagged | DESCRIBED | None; issue #133 is the reason |
| W7 | Windows | Visual C++ runtime absent: named preflight error `vcpp_runtime_missing` | DESCRIBED | None; 2.3 only warns (section 7.1) |
| W8 | Windows | REAPER shows read-only status and can open the installer; it offers no install action | DESCRIBED | None |
| W9 | Windows | Repair while a separation runs is refused immediately with a retry option (F8; recorded now, built with repair) | DESCRIBED | None |
| L1 | Linux | Fresh non-admin account without Python | DESCRIBED | None |
| L2 | Linux | `XDG_DATA_HOME` honored; non-ASCII home path | DESCRIBED | None |
| L3 | Linux | Cancel via the marker, and via the `SIGINT`/`SIGTERM` fast path, leaves previous state | DESCRIBED | None |
| L4 | Linux | `renameat2` no-replace publication | PROVEN (REPORTED) | CI native ubuntu-24.04 and 26.04, run 40720954223; Arch laptop on 0ff9db9 |
| L5 | Linux | OpenSSL 3.0.x acquisition behavior | PROVEN (REPORTED) | CI tests job and native ubuntu-24.04 (3.0.13 enforced), run 40720954223 |
| L6 | Linux | REAPER quit during install: the install completes; the startup acknowledgement was written (F9) | DESCRIBED | None |
| L7 | Linux | REAPER force-quit during install: the install completes (F9) | DESCRIBED | None |
| L8 | Linux | Setup reopened during or after install reattaches and shows the state from lock, events and result (F9) | DESCRIBED | None |
| L9 | Linux | Pinned managed Python and FFmpeg run on a distribution at the G2 baseline (glibc 2.28, kernel 4.18) | DESCRIBED | None; python-build-standalone issue #1358 is the reason |
| A1 | macOS Apple Silicon | Account without Python, non-admin | DESCRIBED | None |
| A2 | macOS | Non-ASCII user name | DESCRIBED | None |
| A3 | macOS | `renamex_np` no-replace publication | PROVEN (REPORTED) | CI native macOS, run 40720954223; M1 host on 377612e, Intel host on 0ff9db9 |
| A4 | macOS | A symlinked destination ancestor (as `/tmp` and `/var` are) is refused | PROVEN (code/test) | `tests/test_core_asset_materialization.py:296,315`; `docs/dev/Core_DrumSep_Asset_Materialization.md:43-45` |
| A5 | macOS | Cancel via the marker from `STEMwerk-SETUP.lua` leaves previous state and no staging | DESCRIBED | None |
| A6 | macOS | REAPER quit during install: the install completes; the startup acknowledgement was written (F9) | DESCRIBED | None |
| A7 | macOS | REAPER force-quit during install: the install completes (F9) | DESCRIBED | None |
| A8 | macOS | Setup reopened during or after install reattaches and shows the state from lock, events and result (F9) | DESCRIBED | None |
| A9 | macOS | Clean Mac, real path: REAPER -> `STEMwerk-SETUP.lua` -> bootstrap -> Core -> download -> managed Python and FFmpeg execute, without quarantine removal or re-signing (F7) | DESCRIBED | None |

Counts for section 11 (53 rows with an ID, C1 to A9):

| Status | Count | Rows |
| --- | --- | --- |
| DESCRIBED | 41 | C1-C8, C13-C24, W1-W3, W6-W9, L1-L3, L6-L9, A1-A2, A5-A9 |
| PROVEN, code/test only | 2 | C12, A4 |
| PROVEN, REPORTED only | 7 | C4a, C9, C10, W5, L4, L5, A3 |
| PROVEN, code/test and REPORTED | 3 | C8a, C11, W4 |

PROVEN means only the exact sub-criterion in the row. In particular a
complete install from an account without Python (C1, W1, L1, A1) is NOT
proven by anything.

## 12. Open points

Class is "blocks the first route" or "parked". IDs are stable across
revisions; resolved items move to section 12.3.

### 12.1 Blocks the first route

| ID | Item | Reason (one line) |
| --- | --- | --- |
| O1 | #134 / #128 root cause (non-ASCII user names) | Gates qualification (W2, S10, S11), not construction |
| O2 | `BrokenPipeError` on closed or redirected stdout/stderr | A detached Core must still write its result file; fix in S0 for existing CLIs, S2 for the module CLI |
| O3 | Managed-Python manifest and hash pins (M4, D9, F6) | Bootstrap cannot be exercised without them; F6 gives the candidate |
| O4 | Install lock and journal (M7, D8) | Needed for cancel and recovery criteria |
| O5 | Measured space table (M8), including the static FFmpeg pair (F4) | C5 cannot be tested without it |
| O9 | Windows `MAX_PATH` / long-path limits for deep `site-packages` under `<root>\runtimes\…` | Route risk on Windows; S6 must measure the deepest path and keep IDs short |
| O47 | Scheduled manifest-URL CI check (F5) | Blocks first-route distribution; constructed in S5 (C21) |
| O48 | Licence texts and source pointers shipped with every bundled or STEMwerk-hosted FFmpeg (F5) | Blocks publishing or sharing any STEMwerk-hosted or bundled FFmpeg (S7 release asset, bundled installers, external test builds). Does not block local construction |
| O54 | How Core is started after the outer layer has published only the pinned Python (G1) | Open question: where Core's code comes from on a fresh account, and how the managed Python runs it under `-I` before any module venv exists. Constraints: 2.3 ships Core as plain files and makes it importable only by `pip install` into its venv (EXISTING: `scripts/reaper/STEMwerk_Bootstrap_Windows.ps1:3436-3444`, `scripts/reaper/STEMwerk_Bootstrap_Linux.sh:2576-2579`); `-I` ignores `PYTHON*` variables and the user site-packages, and `-m` then does not prepend the current directory (REPORTED, https://docs.python.org/3/using/cmdline.html); the ReaPack (`index.xml:125-131`), Inno (`installer/windows/STEMwerk_Windows_Payload.iss:69-75`, included at `installer/windows/STEMwerk.iss:146`) and `.pkg` (`installer/macos/payload-manifest.txt:132-138`) file lists name 7 of the 30 tracked files under `scripts/reaper/vendor/stemwerk-core`, while the Linux package copies the whole `scripts/reaper/` tree (`installer/linux/stage_payload.sh:10,29-32`). Mechanism not decided; class and owner DECIDED 2026-10-30; S5 resolves it |
| O55 | Cleanup after a crashed outer-layer bootstrap | Its staging `<root>/tmp/<op>/` has no journal, so journal recovery (section 8, C13) never removes it. PROPOSED direction: on start, Core removes outer-layer staging directories that belong to no active operation (no live lock holder, not referenced by any registry or receipt); the outer layer holds no lock (G1), so S5 also defines how an active bootstrap is recognized. Class and owner DECIDED 2026-10-30; S5 specifies and tests it (C24) |

### 12.2 Parked

| ID | Item | Reason (one line) |
| --- | --- | --- |
| O11 | Materialization CLI has no `internal_error` net | Fast-follow fix in S0; the module CLI gets its own net in S2 |
| O12 | `cleanup.complete` is `null` for `internal_error` | Result is correct; known limit of acquisition |
| O13 | In-use marker for runtimes and assets (section 8) | Required by F8 for repair; the first route neither replaces nor removes |
| O14 | Repair from REAPER on Windows (D7) | Installer-only repair is policy (F8); revisit only with a proven lock (O4) and in-use protection (O13) |
| O16 | Reuse of a system FFmpeg (D11) | v1 uses only STEMwerk's own pair |
| O17 | Detached signatures for the manifest (D9) | Deferred; hash pins in a versioned manifest suffice for v1 |
| O18 | Byte-range resume of downloads | Retry is a new operation in v1 |
| O19 | `--events-fd` (D5) | Not in v1; the events file is the only channel |
| O20 | `waiting` event state | Cut from v1 |
| O21 | Adopt path (section 4) | Designed, not built in v1 |
| O22 | External PySide6 Setup app (D12) | Later; not part of the first route |
| O23 | Repair, update and remove operations | Defined in 3.5 and section 4; first route builds plan, install, verify, cancel |
| O24 | Integrate Monterey ONNX fix into 2.4 | Basis of the later Intel macOS route with its own pin set (G2); until then Intel users stay on 2.3.x with that hotfix; lessons already applied (3.4, 3.5) |
| O25 | #133 separation launcher (hidden PowerShell or `cmd` via VBScript) | Route rule in 6.5; the 2.3 separation launcher is out of scope |
| O26 | #130 RDNA4 (gfx1200) | First route is CPU only |
| O27 | #129 Mega 53 model request | Not one of the seven flows |
| O28 | #123 gfx1031 / ambiguous layout | GPU environment; layout lesson already in 3.2 |
| O29 | PR #107 unmerged (since 2026-07-19) | Scope is used as REPORTED (D4); route needs only Direct Kit |
| O30 | Reconcile PR #107's `stemwerk_dks` with `drumsep_mdx23c` (D3) | Decided for now; revisit when PR #107 merges |
| O31 | Happy Eyeballs for acquisition | Affects dual-stack latency, not correctness |
| O32 | System-managed symlinks (`/tmp`, `/var`, `/home`) | Refusal is safe; per-user `<root>` avoids them |
| O33 | Private `socket.SocketIO._sock` dependency | Re-check before CPython 3.13; route pins 3.12 (D2) |
| O34 | Code signing and notarisation of the outer executables and `.pkg` | Required for release; macOS test builds use a documented manual step (D12) |
| O35 | Telemetry (ONNX Runtime) | "no-download" is not "offline"; release question |
| O36 | DrumSep weight licence (M13) | Blocks release, not the build |
| O37 | Demucs integrity pins | Only needed for Normal Stems / Kit Split |
| O38 | F2: non-ASCII redirect `Location` -> `UnicodeEncodeError` | Escapes the deadline but fails closed; Unicode criterion covers it |
| O39 | Test certificate `notBefore` backdating | Test hygiene |
| O40 | Non-default DrumSep GPU indexes | GPU, not first route |
| O41 | Handoff note items: redundant `shutdown` in `attach_response`, 9-11% deadline reports "TimeoutError", empty IPv6 conflict test without IPv6, `WSAEACCES` skips fixture retry | Test and diagnostics hygiene; no route criterion depends on them |
| O42 | Delivery of the outer layer via ReaPack or installers | Mechanism per D12 and section 4; first route can start from a hand-placed script or installer |
| O43 | Release qualification | Not in scope |
| O44 | Cleanup of host evidence folders | Housekeeping |
| O45 | Integration of other 2.3.x fixes into 2.4 | Separate from this plan |
| O49 | MP3 output (F1) | v1 offers WAV and FLAC only |
| O50 | macOS x86_64 FFmpeg and managed Python (F2, F6) | Part of the later Intel macOS route (G2); not in the first route's platform scope |
| O51 | Self-mirroring of pinned artifacts (F5) | Kept as an option; vendor download plus the scheduled check is the v1 model |
| O52 | Developer ID signing and notarisation of runtime payloads (F7) | Revisited before a public release |
| O53 | libuuid notice ambiguity, python-build-standalone issue #1329 (F6) | Release-engineering licence item (REPORTED, Astra research 2026-10-30, https://github.com/astral-sh/python-build-standalone/issues/1329) |

### 12.3 Resolved

Resolved in revision 3 by the research and the owner's decisions F1-F9:

| ID | Was | Resolution | Remaining work |
| --- | --- | --- | --- |
| O6 | FFmpeg build source and licence per platform | F2, F3, F4 (section 3.6) | Final pins in S7; C20 |
| O7 | macOS Gatekeeper and quarantine for downloaded runtimes | F7 (section 6.6) | A9 in S11 |
| O8 | Detached launch mechanism from Lua on macOS and Linux | F9 (section 6.5) | L6-L8, A6-A8 in S9 |
| O15 | Original reason for installer-only repair on Windows | F8: maintenance policy, not elevation (section 7.6) | W9 with the repair route |

Resolved in revision 4 by the owner's decisions G2 and G3:

| ID | Was | Resolution | Remaining work |
| --- | --- | --- | --- |
| O10 | How Inno Setup downloads and unpacks the pinned archives | G3: Inno's built-in download with required SHA-256 (since 6.1.0) and hidden in-box `tar.exe`; no `curl.exe` fallback needed (section 6.1) | Pin the Inno version in CI and refuse to compile below 6.6.0; prove download, hash refusal, extraction and cancel in S5 (C22, W3) |
| O46 | Minimum supported OS, glibc and REAPER versions | G2 (section 10.3) | Inno `MinVersion`, Core preflight floor and REAPER warning (C23); baseline Linux run in S5 (L9) |

Resolved in revision 2 by D1-D12: outer-layer technology (D12), target
layout (D1), events channel and the stdout collision (D5), cancel mechanism
(D6), front ends and launching from REAPER on Windows (D7), lock location
(D8), managed-Python source (D9), FFmpeg in v1 (D11), engine naming for now
(D3), Python versions (D2).

Counts: 10 items block the first route (O1-O5, O9, O47, O48, O54, O55),
39 are parked (O11-O14, O16-O45, O49-O53) and 6 are resolved (O6-O8, O15 in
revision 3; O10, O46 in revision 4). No item is RESEARCH PENDING.
Handoff backlog items 1 and 2 (CI pinning, CLI safety net for acquisition
and preparation) are already done by 4f66b34 and 9c410f9 (REPORTED,
handoff 2026-10-30) and are not listed.

## 13. Slice plan for the first route

Ordered slices. Each ends with evidence that can be reviewed on its own. No
new hardening slice is planned unless a slice's evidence shows a defect in
code already at HEAD; S0 is the one exception, allowed only if it stays
independent of the later slices. Support fixes for 2.3.x stay on their own
branches and are not part of this plan.

| # | Slice | Covers | Depends on | Evidence |
| --- | --- | --- | --- | --- |
| S0 | Early small fixes (optional, independent) | O2 for the existing CLIs, O11 | None | Real-subprocess tests; CI native jobs |
| S1 | Module descriptor, `verify`, state precedence; CI on 3.11 and 3.12 | M1, M14 | D2 | Unit tests; CI portable job on both versions |
| S2 | Events file, result file, startup acknowledgement, terminal result, module CLI safety net, `--describe` | M6 (files), M15, O2 | D5, F9 | Contract tests; real-subprocess test with closed streams; CI native jobs |
| S3 | Install lock, journal, stale detection | M7 | D8 | Concurrency and kill tests on Linux, macOS, Windows native CI |
| S4 | Preflight and plan fingerprint, path-length budget, static FFmpeg size, minimum-OS check | M8 | S1; F4, G2 | Tests with injected free-space values and OS versions (C23); one observed install to calibrate |
| S5 | Manifest (G4), per-release pin check, scheduled manifest-URL check; outer-layer bootstrap (G1): managed-Python acquisition, verification and no-replace publish; Inno download and `tar.exe` unpack (G3); how Core starts under `-I` before any venv (O54); cleanup of stale bootstrap staging (O55) | M4, O3, O47, O54, O55 | S2; D9, D12, F5, F6, G1, G3, G4 | Hash-mismatch and truncation tests with honest bootstrap results (C22); stale and active bootstrap staging (C24); scheduled job red on a broken pin (C21); Linux baseline run (L9); host run on a clean account |
| S6 | Runtime build in staging, pinned binary-only wheels, publish, asset-set registry, module receipt, honest status | M2, M3, M5, M9 | S1, S3; D1, O9 | Dry-run resolve test; tests that failed components yield `repair_required` or `partial`; host runs per OS |
| S7 | FFmpeg: final pins from the F3 candidates, macOS arm64 release asset with licence text and source pointers, release-workflow licence duty, acquisition, verify, WAV/FLAC probes | M11, O48 | S5; D11, F1-F5 | Native probe on Windows, Linux, macOS (C20); system FFmpeg on `PATH` test (C19); release asset carries licence and source pointers |
| S8 | Cancellation | M6 (cancel), W3, L3, A5 | D6; S2, S3 | Cancel tests at each phase; host runs |
| S9 | Front ends and activation, launch contract, REAPER version warning | M10, M16 | D7, D12, F9, G2 | REAPER fresh-profile test; REAPER below 7.0 warns (C23); quit, force-quit and reattach (L6-L8, A6-A8); Inno progress page smoke |
| S10 | Unicode end-to-end | M12 | O1 | Windows host with non-ASCII user name (needs the reporter or an equivalent account) |
| S11 | First-route qualification | C1, W1, L1, A1, A9, C5 and the remaining DESCRIBED rows | All slices; O1 | Host runs from a clean non-admin account without Python on all three OS in the G2 acceptance environments (section 11); clean-Mac real path (A9) |

W9 belongs to the later repair route and is not closed by these slices.
S5 to S11 need native hosts. S11 closes the DESCRIBED criteria in section 11
only when the hosts actually run them. An unsigned outer executable (the
Inno Setup installer) will likely meet SmartScreen and antivirus friction
during first-build qualification; S11 records that behavior as observed
evidence, and signing remains release work (section 12, O34).
