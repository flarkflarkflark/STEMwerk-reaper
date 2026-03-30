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
