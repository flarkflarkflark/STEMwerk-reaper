# Installer builds (CI)

These are **packaging helpers** so you can download installers from GitHub and test on Windows/macOS/Linux.

## Published artifact matrix

The public release matrix is exactly five installer files plus one combined
checksum manifest. Nothing else is published as a GitHub release asset for a
given `<version>`:

- Windows standard: `STEMwerk-Setup-<version>.exe` (Inno Setup)
- Windows bundled: `STEMwerk-Setup-<version>-bundled.exe` (Python + FFmpeg included)
- macOS standard: `STEMwerk-<version>.pkg` (pkgbuild)
- macOS bundled (Apple Silicon): `STEMwerk-<version>-bundled-apple-silicon.pkg`
- Linux (portable): `STEMwerk-<version>-x86_64.AppImage` (AppImageKit)
- Checksum manifest: `SHA256SUMS-<version>.txt`, generated from the five files above

`installer/linux/build_deb.sh`, `build_rpm.sh`, and `build_archpkg.sh` remain
available as build tooling (native Linux packages build successfully), but
`.deb`/`.rpm`/Arch packages are deliberately **not** part of the published
release matrix and are not built by the release workflow.

The Windows update patch (`STEMwerk-<version>-update-patch.exe`) remains
retired for the `2.3.x` line, which requires full runtime migration (main venv
+ DrumSep venv + model assets + `ready_to_go.env`):

- publish only `STEMwerk-Setup-<version>.exe` and `STEMwerk-Setup-<version>-bundled.exe`
- keep `STEMwerk-<version>-update-patch.exe` retired and unpublished
- do not "fix up" checked-in `dist/` outputs by hand; rebuild from source when release work resumes

The canonical release version is stored in the repo root `VERSION` file.
The release workflow enforces: tag `vX.Y.Z` must match `VERSION`, and the
checked-out commit must resolve to that exact tag before any build starts.
Keep ReaPack metadata and script headers in sync with `VERSION` by running `python tools/version_sync.py --write` before tagging.

## CI builds (GitHub Actions)

The only release-facing workflow is `.github/workflows/release-installers.yml`
(`workflow_dispatch` only -- there is no tag-push trigger). Build and publish
are separate stages within it:

- `validate-version` verifies `VERSION`/tag agreement and that the checkout
  resolves to the exact commit the release tag points at, before any build
  job runs.
- `windows-exe`, `macos-pkg`, and `linux-packages` each build their platform's
  artifacts and upload them as Actions run artifacts. They never publish
  anything to a GitHub Release themselves.
- `checksums` downloads the built artifacts and writes the single combined
  `SHA256SUMS-<version>.txt` manifest. If signing/notarization is ever applied
  to these artifacts, that must happen (externally) before this job runs, so
  the manifest checksums the exact bytes that ship.
- `publish` downloads the built artifacts plus the checksum manifest and
  uploads them to the GitHub Release for the resolved tag -- but only runs at
  all when the `upload_release_assets` workflow input is explicitly set to
  `true`. It defaults to `false`: an ordinary run only builds and checksums,
  it never publishes.

Third-party Actions used by this workflow are pinned to full immutable commit
SHAs (not floating major/minor tags like `@v4`).

## Install locations

- Windows: `%USERPROFILE%\\Documents\\STEMwerk`
- macOS: `~/Library/Application Support/STEMwerk` (runtime) and `~/Library/Application Support/REAPER/Scripts/STEMwerk-reaper` (scripts)
- Linux: `/usr/share/stemwerk`

The REAPER Lua scripts live under `scripts/reaper/` inside the installed folder.

## Building locally

### Windows
- Install Inno Setup (ISCC)
- Run ISCC on `installer/windows/STEMwerk.iss`

### macOS
- `STEMWERK_VERSION=$(cat VERSION) bash installer/macos/build_pkg.sh`

### Linux (Debian/Ubuntu)
- `sudo apt-get install -y rsync dpkg-dev`
- `STEMWERK_VERSION=$(cat VERSION) bash installer/linux/build_deb.sh`

### Linux (AppImage)
- Requires: `curl` (appimagetool is downloaded automatically, pinned to a fixed AppImageKit release with checksum verification -- see Immutable source expectations below)
- `STEMWERK_VERSION=$(cat VERSION) bash installer/linux/build_appimage.sh`

### Linux (RPM)
- Install `rpm` / `rpmbuild` (package name varies per distro)
- `STEMWERK_VERSION=$(cat VERSION) bash installer/linux/build_rpm.sh`

### Linux (Arch)
- Requires Docker (build runs inside `archlinux:latest`)
- `STEMWERK_VERSION=$(cat VERSION) bash installer/linux/build_archpkg.sh`

### Linux (all release artifacts)
- Rebuild only the Linux release assets and write a manifest with hashes:
- `STEMWERK_VERSION=$(cat VERSION) bash installer/linux/rebuild_linux_artifacts.sh all`
- Or target a subset:
- `STEMWERK_VERSION=$(cat VERSION) bash installer/linux/rebuild_linux_artifacts.sh appimage rpm`

## Build hygiene

- `installer/linux/build*`, `installer/linux/dist`, `installer/macos/build`, and `installer/macos/dist` are generated output and should not be committed.
- The authoritative packaging input is `scripts/reaper/` plus the installer definitions under `installer/`.
- For Linux release replacements, rebuild from source instead of editing generated `build-*` folders.

## Immutable source expectations

Release-facing distribution inputs are pinned, not tracked against a moving
branch/alias:

- ReaPack `index.xml` package payload sources point at the immutable release
  tag (e.g. `v2.3.1.2`), never `main`/`master`/`latest`. The ReaPack
  subscription/discovery URL that points users at `index.xml` itself is the
  one intentionally moving reference -- it has to keep tracking the default
  branch so existing subscribers see new releases. `tools/release_gate.py`
  fails closed if any payload source isn't pinned to the release tag or a
  full commit SHA.
- `installer/linux/build_appimage.sh` downloads `appimagetool` from a fixed
  AppImageKit release URL with an expected SHA-256; a checksum mismatch
  fails the build instead of silently using unexpected bytes.
- Third-party GitHub Actions in `release-installers.yml` are pinned to full
  commit SHAs.

## Hotfix notes

- Linux release replacement steps for `v2.2.1` are documented in `docs/RELEASE_2.2.1_LINUX_HOTFIX.md`.
- Non-Windows status UI recommendations are documented in `docs/NON_WINDOWS_STATUS_UI_PROPOSAL.md`.
