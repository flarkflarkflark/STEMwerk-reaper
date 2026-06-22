# Installer builds (CI)

These are **packaging helpers** so you can download installers from GitHub and test on Windows/macOS/Linux.

## Outputs

- Windows: `STEMwerk-Setup-<version>.exe` (Inno Setup)
- Windows patch: `STEMwerk-<version>-offline-patch.exe` (Inno Setup)
- macOS: `STEMwerk-<version>.pkg` (pkgbuild)
- Linux (Debian/Ubuntu): `stemwerk_<version>_amd64.deb` (dpkg-deb)
- Linux (portable): `STEMwerk-<version>-x86_64.AppImage` (AppImageKit)
- Linux (Fedora/RHEL/openSUSE): `stemwerk-<version>-1.noarch.rpm` (rpmbuild)
- Linux (Arch): `stemwerk-<version>-1-any.pkg.tar.zst` (makepkg)

Release-note caveat for the current `2.3.0.0` line:

- final release-candidate code basis is `95013e6d8e9e3bf6cda0456264612153678ed1c0`
- that final Windows follow-up restores normal CPU multi-item `cap2` scheduling and fixes DrumSep ready-state persistence/`ready_to_go` reporting
- any Linux/Windows artifacts or manifests generated from `21a59cd64686b6cc8c6feca62ac863d8a9e13b6a`, `e06507c99e6e336cbbf36892a39c97876d10daa0`, or `328c614c8adcdc8244c8bb9bf601083907f29032` are stale and must be rebuilt from `95013e6d8e9e3bf6cda0456264612153678ed1c0` or later before release/publish
- do not "fix up" checked-in `dist/` outputs by hand; rebuild from source when release work resumes

The canonical release version is stored in the repo root `VERSION` file.
For release tags, the workflow enforces: tag `vX.Y.Z` must match `VERSION`.
Keep ReaPack metadata and script headers in sync with `VERSION` by running `python tools/version_sync.py --write` before tagging.

## CI builds (GitHub Actions)

- Release builds: push a tag `vX.Y.Z` to trigger `.github/workflows/release-installers.yml`.
  - Builds installers on Windows/macOS/Linux and uploads them to the GitHub Release.
  - Also stores the artifacts in the Actions run.
- Manual builds: run `.github/workflows/build-installers.yml` for ad-hoc artifact-only builds.

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
- Requires: `curl` (appimagetool is downloaded automatically)
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

## Hotfix notes

- Linux release replacement steps for `v2.2.1` are documented in `docs/RELEASE_2.2.1_LINUX_HOTFIX.md`.
- Non-Windows status UI recommendations are documented in `docs/NON_WINDOWS_STATUS_UI_PROPOSAL.md`.
