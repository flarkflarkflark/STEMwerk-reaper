# Core module installation: appendix

Status: appendix to the
[Core module installation design](Core_Module_Installation_Design.md),
split from revision 5a of 2026-10-30 in revision 6. It holds what the
design of record does not need to state the first route: the FFmpeg
inventory of 2.3, candidate pins, research findings, the later-routes
list, the parked open points and the resolved register. Moved text keeps
its wording, evidence kind and citations. The design's evidence
conventions and its `CORE` abbreviation apply here; "section N" refers
to the design, "section A.N" to this appendix.

## A.1 FFmpeg today (from design section 3.6)

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

## A.2 CANDIDATE FFmpeg pins for F3 (from design section 3.6)

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

## A.3 Managed Python CANDIDATE sizes and hashes (from design section 6.2)

Sizes and hashes (REPORTED, Astra research 2026-10-30, from
https://github.com/astral-sh/python-build-standalone/releases/download/20261026/SHA256SUMS;
the macOS archive was also downloaded and its hash measured):

| Target | Bytes | SHA-256 |
| --- | --- | --- |
| `x86_64-pc-windows-msvc` | 22,014,416 | `1f2ab53880fc67ea323398c6388e05af28addc99a8e389209f08a51fdff4b149` |
| `x86_64-unknown-linux-gnu` | 34,505,639 | `ce4f6d0a6cfdb3bed6e44c2f9affd85943c76a42e25ad3a259002f31d6fb8a20` |
| `aarch64-apple-darwin` | 25,035,343 | `353d5f1b4fd2715e7053f12f068435d5bbad16b91e057006b5d01e0925709a7e` |

## A.4 macOS quarantine and Gatekeeper findings (from design section 6.6)

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

## A.5 Later routes

Items that belong to later routes, as listed by the independent final
review. The open points keep their class (parked).

### Criterion (from design section 11.2)

| ID | OS | Criterion | Status | Evidence |
| --- | --- | --- | --- | --- |
| W9 | Windows | Repair while a separation runs is refused immediately with a retry option (F8; recorded now, built with repair) | DESCRIBED | None |

### Open points (from design section 12.2)

| ID | Item | Reason (one line) |
| --- | --- | --- |
| O13 | In-use marker for runtimes and assets (section 8) | Required by F8 for repair; the first route neither replaces nor removes |
| O14 | Repair from REAPER on Windows (D7) | Installer-only repair is policy (F8); revisit only with a proven lock (O4) and in-use protection (O13) |
| O16 | Reuse of a system FFmpeg (D11) | v1 uses only STEMwerk's own pair |
| O18 | Byte-range resume of downloads | Retry is a new operation in v1 |
| O19 | `--events-fd` (D5) | Not in v1; the events file is the only channel |
| O20 | `waiting` event state | Cut from v1 |
| O21 | Adopt path (section 4) | Designed, not built in v1 |
| O22 | External PySide6 Setup app (D12) | Later; not part of the first route |
| O23 | Repair, update and remove operations | Defined in 3.5 and section 4; first route builds plan, install, verify, cancel |
| O25 | #133 separation launcher (hidden PowerShell or `cmd` via VBScript) | Route rule in 6.5; the 2.3 separation launcher is out of scope |
| O26 | #130 RDNA4 (gfx1200) | First route is CPU only |
| O27 | #129 Mega 53 model request | Not one of the seven flows |
| O28 | #123 gfx1031 / ambiguous layout | GPU environment; layout lesson already in 3.2 |
| O34 | Code signing and notarisation of the outer executables and `.pkg` | Required for release; macOS test builds use a documented manual step (D12) |
| O35 | Telemetry (ONNX Runtime) | "no-download" is not "offline"; release question |
| O36 | DrumSep weight licence (M13) | Blocks release, not the build |
| O37 | Demucs integrity pins | Only needed for Normal Stems / Kit Split |
| O40 | Non-default DrumSep GPU indexes | GPU, not first route |
| O43 | Release qualification | Not in scope |
| O45 | Integration of other 2.3.x fixes into 2.4 | Separate from this plan |
| O49 | MP3 output (F1) | v1 offers WAV and FLAC only |
| O50 | macOS x86_64 FFmpeg and managed Python (F2, F6) | Part of the later Intel macOS route (G2); not in the first route's platform scope |
| O51 | Self-mirroring of pinned artifacts (F5) | Kept as an option; vendor download plus the scheduled check is the v1 model |
| O52 | Developer ID signing and notarisation of runtime payloads (F7) | Revisited before a public release |
| O53 | libuuid notice ambiguity, python-build-standalone issue #1329 (F6) | Release-engineering licence item (REPORTED, Astra research 2026-10-30, https://github.com/astral-sh/python-build-standalone/issues/1329) |

## A.6 Parked (first-route context)

From design section 12.2; class parked.

| ID | Item | Reason (one line) |
| --- | --- | --- |
| O11 | Materialization CLI has no `internal_error` net | Fast-follow fix in S0; the module CLI gets its own net in S2 |
| O12 | `cleanup.complete` is `null` for `internal_error` | Result is correct; known limit of acquisition |
| O17 | Detached signatures for the manifest (D9) | Deferred; hash pins in a versioned manifest suffice for v1 |
| O24 | Integrate Monterey ONNX fix into 2.4 | Basis of the later Intel macOS route with its own pin set (G2); until then Intel users stay on 2.3.x with that hotfix; lessons already applied (3.4, 3.5) |
| O29 | PR #107 unmerged (since 2026-07-19) | Scope is used as REPORTED (D4); route needs only Direct Kit |
| O30 | Reconcile PR #107's `stemwerk_dks` with `drumsep_mdx23c` (D3) | Decided for now; revisit when PR #107 merges |
| O31 | Happy Eyeballs for acquisition | Affects dual-stack latency, not correctness |
| O32 | System-managed symlinks (`/tmp`, `/var`, `/home`) | Refusal is safe; per-user `<root>` avoids them |
| O33 | Private `socket.SocketIO._sock` dependency | Re-check before CPython 3.13; route pins 3.12 (D2) |
| O38 | F2: non-ASCII redirect `Location` -> `UnicodeEncodeError` | Escapes the deadline but fails closed; Unicode criterion covers it |
| O39 | Test certificate `notBefore` backdating | Test hygiene |
| O41 | Handoff note items: redundant `shutdown` in `attach_response`, 9-11% deadline reports "TimeoutError", empty IPv6 conflict test without IPv6, `WSAEACCES` skips fixture retry | Test and diagnostics hygiene; no route criterion depends on them |
| O42 | Delivery of the outer layer via ReaPack or installers | Mechanism per D12 and section 4; first route can start from a hand-placed script or installer |
| O44 | Cleanup of host evidence folders | Housekeeping |

## A.7 Resolved (from design section 12.3)

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
