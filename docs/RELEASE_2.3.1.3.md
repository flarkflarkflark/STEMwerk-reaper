# STEMwerk 2.3.1.3

## Scope

`2.3.1.3` is a focused setup and runtime-reliability release on top of
`2.3.1.2`. It preserves the existing model, dependency, and backend policy
while closing five release-blocking integration gaps found during RC
validation.

## Fixed behaviors

- **Windows Repair/Rebuild dispatch safety.** Repair and rebuild requests
  launched from inside REAPER hand off to the external setup path instead of
  running repair work in the REAPER process.
- **Linux gfx1031 single-item propagation.** The selected ROCm architecture
  override now reaches single-item workers as well as multi-item runs.
- **DrumSep verification window.** Runtime verification allows up to 120
  seconds, preventing false setup failures when a healthy DrumSep runtime is
  slow to start.
- **Windows NVIDIA explicit-CPU recovery.** DrumSep and Kit Split preserve an
  explicit CPU selection end to end instead of incorrectly returning to the
  CUDA path.
- **Windows bundled FFmpeg reproducibility.** The bundled-installer build uses
  the stable pinned FFmpeg release-asset URL, so a fresh build can retrieve
  the expected archive reproducibly.

## Supported release artifacts

The public release matrix is exactly five installer artifacts plus one
checksum manifest:

| File | Platform / role |
|---|---|
| `STEMwerk-Setup-2.3.1.3.exe` | Windows standard installer |
| `STEMwerk-Setup-2.3.1.3-bundled.exe` | Windows bundled installer |
| `STEMwerk-2.3.1.3.pkg` | macOS standard installer |
| `STEMwerk-2.3.1.3-bundled-apple-silicon.pkg` | macOS Apple Silicon bundled recovery installer |
| `STEMwerk-2.3.1.3-x86_64.AppImage` | Linux AppImage |
| `SHA256SUMS-2.3.1.3.txt` | Combined checksum manifest for the five installers |

There is no separate Intel macOS package in this matrix. Linux `.deb`, `.rpm`,
and Arch packages remain build tooling rather than published release assets.
The retired Windows update-patch installer and the historical offline
allmodels installers are also outside this release matrix.

## Platform notes

- Windows standard and bundled installers remain the supported Windows
  install/update routes. The final BUILD run must set
  `windows_bundled_asset=true` so the bundled artifact required by the
  checksum contract is present.
- The standard macOS package supports the existing Intel and Apple Silicon
  setup paths. The bundled package is Apple Silicon only and remains a
  runtime-recovery package without bundled models.
- Linux release distribution remains ReaPack plus the x86_64 AppImage. ROCm
  compatibility remains dependent on supported hardware and drivers.
- The dependency pins, model identities, and NVIDIA/DrumSep processing logic
  are unchanged by this version/metadata slice.

## Validation status

Source-level release gates for this candidate are complete. This statement
does not certify final installer bytes: the five generated installers and the
combined checksum manifest still require platform smoke validation before the
release may be tagged or published.

Live ReaPack URL reachability is also deferred until the immutable
`v2.3.1.3` tag exists. Before that tag is pushed, the payload URLs are checked
structurally for tag, path, and repository consistency only.

## Build and publication workflow

1. Review and commit the version/metadata sync, then fast-forward the
   authoritative release branch to that exact commit.
2. Re-run `tools/version_sync.py --check` and
   `tools/release_gate.py --check` on that exact source SHA.
3. Run BUILD mode with publication disabled and
   `windows_bundled_asset=true`.
4. Smoke the exact Windows standard, Windows bundled, macOS standard, macOS
   bundled Apple Silicon, Linux AppImage, and checksum-manifest bytes.
5. Only after every smoke passes, tag that validated SHA as `v2.3.1.3`, push
   the tag, verify the ReaPack payload URLs live, and run PUBLICATION mode with
   the validated BUILD run ID.

No final artifact smoke, tag, push, or publication result is claimed by this
document.
