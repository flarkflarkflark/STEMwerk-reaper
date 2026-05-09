# STEMwerk TODO

This file is intentionally tracked in git so "what's next" survives VS Code / Copilot chat sessions.

## Current

- [ ] Kijken of onderstaande todo-lijst nog actueel is, welke zaken zijn aangepakt, welke moeten nog, etc. (volgende keer)
- [ ] Themes: investigate user-themable UI (fonts/colors/styles) vs current look
	- Define theme tokens (palette, fonts, sizes)
	- Apply tokens in UI draw helpers (buttons, headers, panels)
	- Optional: load overrides from a theme file with safe defaults
- [ ] Processing window: investigate start delay (show immediately)
- [x] Run pytest + i18n checks
- [x] Verify CI workflow passes (replicated locally)
- [x] Align Lua @version with APP_VERSION
- [x] Decide default DEBUG_MODE behavior
- [x] Sanity-check Python path auto-detect
- [ ] Re-test REAPER UI scaling/status
- [x] Confirm DirectML/device options docs
- [ ] Help: add "Reaper" menu entry with a page for temp files + settings
	- Explain temp/log/stem file locations and lifecycle
	- Add configurable cleanup policy (keep vs delete after import/save)
	- Note REAPER media copy behavior so users choose safely

- [ ] REAPER progress/complete UI polish
	- [x] Progress: model badge aligned with progress bar (no overflow)
	- [x] Progress: ETA parsing tolerant of stray spaces (no more "ETA: 2:")
	- [x] Progress: device indicator reflects actual runtime device (no "GPU: DirectML" on Linux)
	- [x] Progress: CPU not highlighted as GPU; ETA not always green
	- [x] Progress: Nerd Mode button moved so it doesn't overlap "Elapsed:"
	- [x] Complete: add FX icon toggle near theme icon
	- [x] Complete: remove Space as a close/OK key
	- [x] i18n: Nerd Mode tooltip strings
	- [ ] Complete: verify all header tooltips consistent with main/progress windows

- [ ] REAPER time-selection workflow correctness
	- [x] Fix multi-track render producing empty `input.wav` (ffmpeg log + AudioAccessor fallback)
	- [x] Multi-track: refuse to launch job when per-track `input.wav` is empty
	- [x] Time selection + "Mute sel": if nothing is selected, operate on overlapping items (auto semantics)

- [ ] REAPER UI: merge language/day-night/FX into 1 icon + add TT (tooltips) toggle
	- Auto-hide quick icons until hover (like help pages)

- [ ] Linux AMD GPUs: ROCm support (if hardware/driver supports it)
	- Detect ROCm availability (e.g. `/opt/rocm`, `torch.version.hip`, `rocminfo`)
	- Install/guide correct ROCm-enabled PyTorch wheels for the user’s distro/ROCm version
	- Ensure `audio_separator_process.py` reports usable GPU devices under ROCm (often via `torch.cuda`)
	- Update device UI/tooltips to explain ROCm requirements + fallback behavior

- [ ] Bazzite / Flatpak REAPER support
	- Detect REAPER Flatpak config/scripts paths (likely under `~/.var/app/fm.reaper.Reaper/config/REAPER`)
	- Distinguish native/AppImage REAPER paths from Flatpak REAPER paths on Linux
	- Extend Linux setup/sync flow so scripts land in the correct REAPER Flatpak script directory
	- Verify runtime/state paths still behave correctly with Flatpak-based REAPER
	- Check whether current Linux installers/AppImage should detect or warn about Flatpak REAPER explicitly
	- Add a short Bazzite/Flatpak install note to README/help

- [ ] Test matrix: NVIDIA RTX 3060 laptop (Windows + Linux)
	- Fresh clone + venv setup
	- Install GPU backend (CUDA torch) and verify via `python tools/gpu_check.py`
	- Install REAPER scripts + verify device probe shows `cuda:0`
	- Run short separation test (time selection) and confirm log says `Using GPU`
	- Validate multi-track mode + cancel behavior
	- Validate tooltips + i18n + window placement on both OSes

- [ ] Windows installer: explore semi-bundled installer
	- Bundle Python installer payload into the Windows setup flow
	- Bundle FFmpeg into the Windows setup flow to avoid the long first download
	- Keep `stemwerk-core` bundled from the installer payload as the default path
	- Measure final installer size impact for CPU / DirectML / CUDA users
	- Decide whether to keep one smart installer or add optional offline Windows variants later

- [ ] Windows installer docs: clarify runtime/download expectations
	- Add backend table for CPU / DirectML / CUDA download size
	- Add estimated installed size table
	- Add first-use model download size table (`Fast`, `Quality`, `6-Stem`)
	- State clearly that normal processing works offline after setup + model download
	- State that model cache is persistent and usually survives reboots
	- Mention the correct ONNX Runtime package per backend (`onnxruntime` vs `onnxruntime-directml`)

- [ ] Windows distribution: reduce SmartScreen / "Windows protected your PC" friction
	- Choose code-signing path: Microsoft Trusted Signing or a traditional code-signing certificate
	- Sign Windows installer artifacts with timestamping in the release/build flow
	- Verify publisher identity stays stable across releases so reputation can accumulate
	- Document false-positive / file-submission fallback for SmartScreen review

- [ ] Runtime regression tests: catch partial separator installs
	- Add a check that `import audio_separator` is not considered sufficient by itself
	- Verify `import onnxruntime` and `from audio_separator.separator import Separator` in setup/runtime validation paths
	- Add a regression case for Windows DirectML where `audio_separator` imports but ONNX Runtime is missing or lacks `DmlExecutionProvider`

- [ ] Long-file safety: detect unusually long source items before separation
	- Warn users that `Quality` / `6-Stem` may exceed RAM/VRAM or fail mid-run on long recordings
	- Suggest trying `Fast` first for long recordings
	- Improve failure reporting when processing exits early so long-track memory/runtime crashes are surfaced clearly instead of silently returning

- [ ] Investigate chunked separation workflow for long recordings
	- Target live sets, DJ mixes, concerts, rehearsals, and other long continuous recordings
	- Split input into time chunks, process each chunk separately, then reconstruct outputs
	- Goal: reduce memory pressure and improve stability for long-track separation

### REAPER UI scaling/status checklist

- [ ] Open `Stemwerk: Main` and resize the window (corners + edges)
- [ ] Verify all controls scale and remain clickable (checkboxes, presets, device/model dropdowns)
- [ ] Verify text does not overlap or clip at small + large sizes
- [ ] Verify progress/status area stays visible during separation
- [ ] Verify reopening restores last window size/position (ExtState)
- [ ] Verify focus behavior: running script again focuses existing window (unless quick preset)
- [ ] Verify quick presets from toolbar run without showing dialog (Karaoke/Vocals/Drums/Bass/All)

## TODO

Toolbar + Icons + Toolbarscripts:

| Script | Description |
|--------|-------------|
| **Stemwerk:** | Main dialog - full control over model, stems, and options |
| **Stemwerk: Karaoke** | One-click vocal removal (keeps drums, bass, other) |
| **Stemwerk: Vocals Only** | Extract vocals to new track |
| **Stemwerk: Drums Only** | Extract drums to new track |
| **Stemwerk: Bass Only** | Extract bass to new track |
| **Stemwerk: All Stems** | Extract all stems to separate tracks |
| **Stemwerk: Setup Toolbar** | Add quick-access toolbar buttons |

## v2.2.2.2 follow-up cleanup

- [ ] ReaPack/root vs `scripts/reaper` i18n structure cleanup
	- Decide one clear canonical shipped i18n source
	- Remove duplicated/confusing packaging paths
	- Validate the cleaned-up tree before the next full release build
- [ ] Reduce macOS setup bootstrap re-download/reinstall of the torch stack when the runtime is already correct
	- Re-check current setup/repair behavior on Apple Silicon and Intel macOS
	- Avoid unnecessary torch reinstall when runtime verification already passes
- [ ] Build the next full release assets from a cleaned-up `main`
	- ReaPack/package metadata, repo tree, and release payload should agree

## Support / diagnostics

- [ ] Add a visible About / Diagnostics / Copy report UI
	- Show installed package/script/ReaPack version clearly
	- Show runtime base path, Python path/version, FFmpeg path/version
	- Show torch / torchvision / torchaudio / audio-separator / onnxruntime
	- Show numpy / numba / llvmlite
	- Show backend/device profile and selected mode
	- Provide a copy-to-clipboard diagnostics block that is easy to paste into GitHub issues/forum posts
- [ ] Land/publish `STEMwerk_Save_Support_Bundle.lua`
	- Keep it as a standalone Action List action
	- Also expose “Save Support Bundle” from the `STEMwerk-SETUP.lua` maintenance UI
	- Reuse one collector implementation; do not duplicate logic
	- Must stay safe for no runtime / failed runtime / failed setup / failed separation
	- Keep version + OS/architecture block prominent at the top of diagnostics
	- Never include audio/model/project payloads
- [ ] Finish hardening the support bundle collector from Linux manual-test findings
	- Ensure architecture, `uname`, Python version, and FFmpeg version are always reported when detectable
	- Ensure `python_diagnostics.txt` is never silently empty
	- Sanitize copied text logs and temp inventory so raw temp/media paths do not leak
	- Improve temp inventory metadata: name, type, size, modified time, and useful reason if unavailable

## GitHub issue follow-ups

### #23 — Installed version / diagnostics visibility
- Priority: support UX / medium priority
- Add a visible About / Diagnostics / Copy report UI.
- Show STEMwerk package/script version, runtime path, Python path/version, FFmpeg path, backend profile, torch/torchvision/torchaudio, audio-separator, onnxruntime, NumPy/numba/llvmlite.
- This should make it easy for users to know what version is installed and copy support diagnostics.

### #22 — Running-state cleanup after completion
- Priority: bug / cleanup-lifecycle / higher priority
- Investigate case where stems are created and completion dialog appears, but main STEMwerk window does not return after OK.
- STEMwerk then still thinks an instance is running.
- Investigate stuck backend/Python process, singleton/running-state cleanup, temp folder handles, and `collab_low` folder remaining locked.
- Ensure completion/finalize path always clears running state and releases temp resources.

### #21 — Batch output grouping for multiple selected items
- Priority: enhancement / workflow polish / medium priority
- Current behavior creates a separate folder + child stem track per selected item.
- Desired behavior: when multiple selected items are on the same source track and use the same stem mode/output mode, optionally group outputs into one shared folder and one child track per stem type.
- Treat as enhancement/workflow polish; track/routing behavior needs careful design.

### #16 — Temp cleanup when only some stems are requested
- Priority: bug / cleanup-lifecycle / higher priority
- Investigate temp files/folders not deleted when not all stems are requested.
- Likely related to cleanup/finalize lifecycle and should be reviewed together with #22.
- Ensure partial-stem workflows clean up temporary files safely without deleting user outputs or model cache.

## macOS Apple Silicon / MPS follow-up

- [ ] Keep CPU as the reliable Auto path on Apple Silicon until MPS is proven stable
	- Current hotfix behavior: Auto prefers CPU, explicit Apple MPS remains available
	- Current explicit MPS behavior sets `PYTORCH_ENABLE_MPS_FALLBACK=1`
	- Known unsupported-op failures now surface a clearer user-facing message
- [ ] Investigate whether stable Apple MPS support is possible for HTDemucs / audio-separator
	- Track the real PyTorch MPS limitation: `Output channels > 65536 not supported at the MPS device`
	- Monitor PyTorch / Demucs / audio-separator MPS behavior over time
	- Revisit retry/fallback policy only after the failure modes are better understood

## CI / testing

- [ ] Keep Apple Silicon CI probes/manual workflows available but non-required until they are stable and low-noise
	- Manual Apple Silicon backend sanity workflow
	- Manual macOS MPS limitation probe
	- Avoid model downloads and real separation in required CI
- [ ] Maintain headless CI coverage for the support bundle collector
	- Exercise sanitization, missing-runtime behavior, and forbidden-payload checks without requiring REAPER

## UI / theme polish

- [ ] Add optional UI/theme accessibility polish
	- Optional “REAPER Native” theme
	- Reduced visual FX mode
	- Tooltip detail/off setting
	- Keep flarkAUDIO theme selectable
- [ ] Investigate whether laggy macOS tooltips/UI responsiveness is separate from backend/runtime issues

## ReaPack/package metadata cleanup

- [ ] Clarify ReaPack/package naming and installed-version visibility
	- Current feed/package display is confusing (`STEMwerk-reaper/STEMwerk-reaper/...`)
	- Make package naming, action naming, and installed version easier to identify
	- Review whether the package description and display path can be simplified without breaking updates

## Future

- **Timeline Alignment / Trim Silence:** Trim the input to the AI-engine to the actual `AudioAccessor` boundaries within a time selection. Currently, if a time selection is larger than the media item, the engine processes the extra silence, which wastes GPU time.
- **Sample Rate Mismatches / Drift:** Investigate potential sub-sample timing drifts when items with different sample rates than the REAPER project are processed via a time selection.
- **Padding Clicks / Fades:** When items are padded with silence to match a longer time selection, apply a micro-fade to prevent DC-offset clicks at the zero-crossing.
- (After installers exist) Add “novice mode” UX: guided install outside REAPER, minimal prompts, clear GPU choice
- **Bundled / Offline Distribution Options:** Revisit backend-specific bundled packages after Windows is stabilized.
	- Windows CPU offline / semi-bundled installer
	- Windows DirectML offline / semi-bundled installer
	- Windows CUDA large offline installer as a separate release path
	- Linux CPU semi-bundled installer or AppImage
	- Linux ROCm / CUDA offline packs only if maintenance cost is acceptable
	- macOS semi-bundled installer path
	- Optional model packs: `Fast`, `Quality`, `6-Stem`
- **DirectML multi-track performance:** Revisit parallel job processing for Windows DirectML once the stability issue is understood. Current workaround forces sequential mode for DirectML multi-job runs; goal is to recover CUDA/CPU-like throughput without dropping outputs. Compare this explicitly against Linux ROCm/CUDA behavior.
- **Vendor packaging hygiene:** Replace or regenerate the stale bundled `stemwerk_core-0.1.0-py3-none-any.whl`, or stop shipping it as a fallback once source-bundle packaging is stable.
- **Repository housekeeping:** Clean up worktree / local artifacts / temporary build clutter once the current installer and runtime work settles down
- **README / Docs visual pass:** Add curated screenshots with GUI highlights and annotated callouts for installer flow, main REAPER UI, and setup/troubleshooting screens
