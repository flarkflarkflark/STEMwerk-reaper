# STEMwerk 2.2.2 Refactor & Cross-Platform Plan

Working notes for the next release line. Main branch is maintenance (2.2.1.x). Refactor happens on `refactor/2.2.2-dev`.

## Release theme

Cross-platform consistency and installer UX. Not a visual release — the theming work (see THEMING_PLAN.md) happens in parallel but is not the headline.

## Diagnosis

### Symptom 1: 119 `OS == "..."` branches across 9 files

47 in `STEMwerk.lua` itself, 36 in `STEMwerk_Setup_Internal.lua`, the rest spread across Devices, Helpers, Runtime_Setup, System, Window, Workflow, Messages. Each branch is a potential drift point between platforms.

### Symptom 2: three process-spawning mechanisms used interchangeably

`reaper.ExecProcess`, `os.execute`, and `io.popen` are used in different call sites, often with fallback chains. No single authoritative entry point for "run a subprocess." Known consequence: macOS `ExecProcess` blocks UI synchronously, unlike Linux. Fix is currently hard because spawn paths are not centralized.

### Symptom 3: three bootstrap scripts doing the same flow in different languages

- `STEMwerk_Bootstrap_Windows.ps1` — 1011 lines
- `STEMwerk_Bootstrap_Linux.sh` — 768 lines
- `STEMwerk_Bootstrap_macOS.sh` — 401 lines

All three perform: Python detection (3.10-3.12), venv creation, pip upgrade, numpy<2, stemwerk-core install from vendor, audio-separator + backend-specific torch, ffmpeg detection, verification, state-file write. Same step order. Same step labels. Same state-file format. Any bootstrap bug must be fixed three times.

### Symptom 4: asymmetric dependency pinning

- Windows pins torch==2.4.1+cu121, torch-directml==0.2.5.dev240914, onnxruntime-directml==1.24.4
- Linux installs audio-separator[gpu] without version pin
- macOS pins audio-separator==0.23.0

Same STEMwerk release can install different audio-separator versions on different platforms.

### Symptom 5: primitives still in STEMwerk.lua

`STEMwerk_UI_Draw.lua` has stub method bodies for `drawButton`, `drawCheckbox`, `drawRadio`, `drawToggleButton`, `drawTooltipStyled`, `drawTooltip` marked `-- ...existing code...`. The extraction was started but not finished. `STEMwerk.lua` is still 18183 lines.

## 2.2.2 Scope — the three layers

### Layer 1: `STEMwerk_Platform.lua`

New module. Single source of truth for OS detection, path normalization, shell quoting, and process spawning. Thin abstraction over what exists — not a rewrite.

Proposed API surface (sketch, refine during implementation):
- `Platform.spawn(cmd, args, opts)` — unified process spawn with async semantics where supported
- `Platform.quote(arg)` — shell-safe quoting per platform
- `Platform.pathSep()` — returns `\` on Windows, `/` elsewhere
- `Platform.pathJoin(...)` — path concatenation with correct separator
- `Platform.isWindows()`, `Platform.isMac()`, `Platform.isLinux()` — explicit predicates
- `Platform.hasAsyncExec()` — capability probe

Migration model: new module introduced as pure passthrough (identical per-platform behavior to current code). Call sites migrate opportunistically — new code goes through Platform, old code keeps working. Over several releases this naturally drains the 119 OS branches.

Critical: this module unlocks the macOS async-spawn fix. Once `Platform.spawn` is the single spawn entry point, the macOS branch can be changed to async in one place instead of across many call sites.

### Layer 2: primitives extraction completed

Fill the already-designed stubs in `STEMwerk_UI_Draw.lua`:
- `drawButton`, `drawCheckbox`, `drawRadio`, `drawToggleButton`
- `drawTooltipStyled`, `drawTooltip`
- `fitTextToBox`, `_wrapTextToWidth`

Pure relocation. No signature changes. Call sites in `STEMwerk.lua` can stay the same via thin wrappers if needed for diff size, then be inlined in a follow-up.

This unlocks the theming Pass A from THEMING_PLAN.md — once primitives live in a dedicated module, style-token usage changes are local to that file.

### Layer 3: installer UX polish (NOT bootstrap convergence)

Bootstrap convergence (rewriting the three shell scripts into one Lua-orchestrated flow) is 2.2.3 work. Too large and too risky for 2.2.2.

For 2.2.2, additive-only improvements:

1. **`versions.json` (or `versions.lua`)** as single source of truth for dependency pinning. All three bootstraps read from it. Gedrag blijft identiek; only pinning becomes symmetric and editable in one place.

2. **Pre-flight checks** in Lua before spawning bootstrap:
   - Windows: PowerShell execution policy probe; if restrictive, offer in-UI "run with bypass" option (spawn with `-ExecutionPolicy Bypass` flag — works without changing user's system policy)
   - All platforms: write-test on `${RUNTIME_BASE}` to detect permission issues before the venv step fails cryptically
   - All platforms: disk-space check (warn under 8 GB free, abort under 4 GB)
   - Linux: Flatpak REAPER detection via `/proc/self/root/.flatpak-info` — abort with clear message if detected
   - macOS: strip quarantine attribute (`xattr -dr com.apple.quarantine ...`) on venv after creation

3. **Error code → user message mapping** in `STEMwerk_Messages.lua`. Translate technical codes (`stemwerk_core_install_failed`, `numpy_install_failed`, `onnxruntime_missing_after_setup`) into actionable user-facing instructions with a retry button and a "copy diagnostics" button.

4. **Live "last log line" in UI** during install. The state-file polling loop already exists; extend it to also read the tail of the log file and display the latest line. Changes a frozen "Installing..." into visible ongoing activity.

5. **Python 3.13 support**. Expand accepted range to 3.10-3.13. Test on macOS and Linux first. Windows can stay stricter if DirectML wheels lag.

6. **Generic ROCm detection**. Remove the hardcoded `gfx1201|rx 9070` grep in `STEMwerk_Bootstrap_Linux.sh`. Match on `gfx` pattern with a known-good allowlist as informational warning only, not as gate.

7. **CUDA version auto-detection**. Parse `nvidia-smi` output for the driver's CUDA version and select the matching torch wheel index (cu118/cu121/cu124) instead of hardcoded `cu121`.

8. **Windows embeddable Python** (longer-term consideration, possibly 2.2.3). Bundle Python embedded distribution to remove dependency on system Python and PowerShell execution policy entirely. Biggest UX unlock for Windows but requires distribution changes.

## Explicitly NOT in 2.2.2

- Bootstrap script convergence (three → one) — 2.2.3+
- Resumable install with per-step done-markers — 2.2.3+
- Apple Silicon MPS opt-in — 2.2.3+
- Offline installer zips per platform+backend — 2.2.3+
- Version-mismatch detection and upgrade flow — 2.2.3+
- Model checksum verification — later
- `curl | bash` distribution model — rejected; see DISTRIBUTION_NOTES below

## Distribution strategy (for context, no 2.2.2 change needed)

ReaPack handles the Lua layer (UI, workflow, theming, i18n) — small, text-only, fast updates. This keeps working as-is.

Python runtime (venv, torch, audio-separator, ffmpeg) is treated as an external runtime dependency, not part of the ReaPack payload. First-run bootstrap resolves it, future re-runs verify health.

`curl | bash` and `irm | iex` patterns were considered and rejected:
- Don't solve Windows execution policy (user still in PowerShell)
- Don't solve Python detection, venv creation, backend install
- Introduce trust-surface issues (professional/studio IT won't allow)
- Cause version drift (main-branch script vs pinned release)
- Lose REAPER-integrated install UI and re-trigger capability
- Lose progress visibility for 15-45 minute installs

Current bootstrap architecture is functionally superior; needs UX polish, not replacement.

Three distribution channels aligned with user groups:
1. **ReaPack + guided first-run** — mainstream users (95%)
2. **Offline installer zips** per platform+backend — studio users without stable internet (2.2.3+)
3. **Manual git + pip** — developers, unchanged

## Execution order for 2.2.2

1. Primitives extraction (`STEMwerk_UI_Draw.lua` stubs → filled)
2. Theming Pass A (gloss per theme — see THEMING_PLAN.md)
3. `STEMwerk_Platform.lua` as pure passthrough (no behavior change)
4. macOS async spawn via `Platform.spawn` (the one real cross-platform bug fix this release)
5. Installer UX items 1-7 from Layer 3 (in dependency order: versions.json first, then pre-flights, then messages, then live-log, then expanded Python range, then generic ROCm, then CUDA auto-detect)

Windows embeddable Python (item 8) depends on distribution changes — evaluate separately.

## Known constraints from CLAUDE_BRIEF

- Avoid workflow/apply/finalize surgery
- Avoid runtime/setup redesign
- Avoid main-branch changes
- Main remains on maintenance line 2.2.1.x

All items in this plan respect these constraints. Layer 3 items are additive (new checks, new translations, new UI surfaces) rather than structural rewrites of the setup pipeline.
