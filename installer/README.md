# Installer builds (CI)

These are **packaging helpers** so you can download installers from GitHub and test on Windows/macOS/Linux.

## Outputs

- Windows: `STEMwerk-Setup-<version>.exe` (Inno Setup)
- macOS: `STEMwerk-<version>.pkg` (pkgbuild)
- Linux (Debian/Ubuntu): `stemwerk_<version>_amd64.deb` (dpkg-deb)
- Linux (portable): `STEMwerk-<version>-x86_64.AppImage` (AppImageKit)
- Linux (Fedora/RHEL/openSUSE): `stemwerk-<version>-1.noarch.rpm` (rpmbuild)
- Linux (Arch): `stemwerk-<version>-1-any.pkg.tar.zst` (makepkg)

The canonical release version is stored in the repo root `VERSION` file.
For release tags, the workflow enforces: tag `vX.Y.Z` must match `VERSION`.

## CI builds (GitHub Actions)

- Release builds: push a tag `vX.Y.Z` to trigger `.github/workflows/release-installers.yml`.
  - Builds installers on Windows/macOS/Linux and uploads them to the GitHub Release.
  - Also stores the artifacts in the Actions run.
- Manual builds: run `.github/workflows/build-installers.yml` for ad-hoc artifact-only builds.

## Install locations

- Windows: `%USERPROFILE%\\Documents\\STEMwerk`
- macOS: `/Users/Shared/STEMwerk`
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
