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

Offline model packs (new release assets):
- STEMwerk-Model-Pack-Fast-v2.2.1.4.zip (~75 MB)
- STEMwerk-Model-Pack-Quality-v2.2.1.4.zip (~298 MB)
- STEMwerk-Model-Pack-6-Stem-v2.2.1.4.zip (~49 MB)
- STEMwerk-Model-Pack-All-v2.2.1.4.zip (~421 MB)
- STEMwerk-Model-Packs-v2.2.1.4-SHA256.txt (checksums)

Notes:
- These packs contain offline model cache files only.
- Runtime/bootstrap dependencies are not bundled in these model-pack assets.
