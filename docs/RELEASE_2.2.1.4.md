# STEMwerk v2.2.1.4

Hotfix release focused on stability and packaging consistency.

Included:
- Fixes Lua top-level local pressure in STEMwerk.lua.
- Improves Linux setup by preferring a managed, supported runtime before unsupported system Python.
- Keeps Linux setup free of privileged package-manager fallbacks.
- Enforces version consistency across VERSION, ReaPack metadata, script headers, UI strings, and CI.
- Keeps macOS setup and processing fixes from the previous stabilization round.
- Maintains working ReaPack/update flow across tested systems.

Validated flows:
- Windows: working
- macOS: working
- Linux / EndeavourOS: working
- ReaPack update + setup + processing: working on MacBookPro11,2 with EndeavourOS

Offline installers and model packs (v2.2.1.4):
- Download folder: [STEMwerk v2.2.1.4 Offline Bundles (Google Drive)](https://drive.google.com/drive/folders/1FuVnhxPI3MAKnKVE_4UTaoT1fHdnsv-h?usp=drive_link)
- Checksums: `installer/windows/dist/checksums.txt` (also available as `.sha256` files next to each installer)

Model bundles contained in the folder:
- Fast, Quality, 6-Stem, All-Models
- Specific builds for NVIDIA (CUDA), AMD/Intel (DirectML), and CPU-only.

Notes:
- These installers are self-contained and require no internet for runtime or model installation.
- Model packs (~75MB - ~421MB) are also available as separate ZIP files for existing installations.
