# STEMwerk 2.2.1 Linux Hotfix Release Plan

## Goal

Replace the defective Linux `v2.2.1` assets with rebuilds from the fixed
Linux bootstrap source, without touching the Windows installer or retagging the
release.

## Scope

- Replace Linux release assets only.
- Keep tag `v2.2.1` unchanged.
- Keep Windows asset unchanged.
- macOS rebuild is optional for source consistency, but not required for this
  Linux-only bootstrap fix.

## Linux assets to replace

- `STEMwerk-2.2.1-x86_64.AppImage`
- `stemwerk_2.2.1_amd64.deb`
- `stemwerk-2.2.1-1.noarch.rpm`
- `stemwerk-2.2.1-1-any.pkg.tar.zst`

## Local rebuild

```bash
export STEMWERK_VERSION=2.2.1
bash installer/linux/rebuild_linux_artifacts.sh all
```

Expected outputs are written to `installer/linux/dist/` together with:

- `STEMwerk-2.2.1-linux-build-manifest.txt`

## Local verification

```bash
ls -1 installer/linux/dist
cat installer/linux/dist/STEMwerk-2.2.1-linux-build-manifest.txt
```

Verify that the manifest contains:

- `version=2.2.1`
- the current source commit
- sha256 lines for all four Linux artifacts

## Exact `gh` replacement commands

These commands replace the existing Linux assets on the existing `v2.2.1`
release without moving the tag:

```bash
gh release view v2.2.1

gh release upload v2.2.1 \
  installer/linux/dist/STEMwerk-2.2.1-x86_64.AppImage \
  installer/linux/dist/stemwerk_2.2.1_amd64.deb \
  installer/linux/dist/stemwerk-2.2.1-1.noarch.rpm \
  installer/linux/dist/stemwerk-2.2.1-1-any.pkg.tar.zst \
  --clobber

gh release view v2.2.1 --json url,assets
```

## Why all Linux assets, not only AppImage

All Linux packages are built from the same `scripts/reaper/` source tree.
Replacing only the AppImage would leave the `.deb`, `.rpm`, and Arch package on
the same public version with the old Linux bootstrap bug.

## Explicitly not part of this hotfix

- Windows installer replacement
- New tag or retag
- Installer redesign
- Package-manager-time Python bootstrap on Linux