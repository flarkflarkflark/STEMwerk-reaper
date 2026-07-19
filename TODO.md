# STEMwerk TODO

This file is intentionally tracked in git so "what's next" survives VS Code / Copilot / ChatGPT sessions.

## Current / Next

- [ ] Final UI smoke-test after Native polish
  - EN / NL / DE
  - REAPER Native dark
  - REAPER Native light
  - flarkAUDIO Visual themes
  - Resize small / large
  - Main / Help / Progress / Complete top-right tooltips
  - Footer with long NL/DE strings
  - 4-stem / 6-stem model switching
  - All-intent across 4-stem ↔ 6-stem
  - At-least-one-stem invariant
  - Process tooltip title
  - Native Help tooltip sizing
  - Native Close / Process / Delete visual hierarchy

- [ ] Help / Reaper tab content polish
  - Explain temp/log/stem file locations and lifecycle
  - Explain Temp / Project / Custom stem file destinations
  - Explain cleanup policy: keep vs delete after import/save
  - Note REAPER media-copy behavior so users choose safely
  - Mention where support logs and temp folders can be found
  - Keep text musician-friendly, not programmer-heavy

- [ ] Progress / Complete header tooltip consistency check
  - Compare top-right icon tooltips with Main and Help
  - Verify EN/NL/DE strings
  - Verify dark/light Native and Visual
  - Verify no stale fallback text such as `tooltip lang`, `Run`, or `Click to STEMwerk`

- [ ] i18n / fallback sanity audit
  - Search for old fallback strings:
    - `tooltip lang`
    - `process action`
    - `temp files delete`
    - `progress queued`
    - `Click to STEMwerk`
    - `Klicken zum STEMwerk`
    - `Klik om STEMwerk`
    - raw `Run`
  - Verify `languages.lua` still starts with `local LANGUAGES = {`
  - Verify `return LANGUAGES` exists at EOF
  - Run `luac -p` on all touched Lua files

- [ ] Re-test REAPER UI scaling/status
  - Open `STEMwerk: Main` and resize the window using corners + edges
  - Verify all controls scale and remain clickable
  - Verify text does not overlap or clip at small + large sizes
  - Verify progress/status area stays visible during separation
  - Verify reopening restores last window size/position via ExtState
  - Verify running script again focuses existing window unless quick preset
  - Verify quick presets from toolbar run without showing the full dialog

## Recently completed UI polish

Keep this section until the next release notes / changelog pass, then remove or archive.

- [x] Native main button typography harmonized across columns/themes
- [x] Visual/default button text shadow simplified for better cross-theme consistency
- [x] Native Close button changed from destructive red to neutral secondary
- [x] Process / Verwerken / Verarbeiten button label restored and localized
- [x] Process tooltip title restored:
  - EN: `Ready to process`
  - NL: `Klaar om te verwerken`
  - DE: `Bereit zum Verarbeiten`
- [x] Removed colored STEM/logo rendering leak from Process tooltip title
- [x] Native Help tooltip size aligned closer to Main simple tooltips
- [x] Native Help typography polished
- [x] Main footer duration split and labelled as `Audio total`
- [x] Footer audio duration gets unit context for `m:ss` style durations
- [x] Enforce at least one selected stem
- [x] Keep existing no-stems warning as fallback only
- [x] Preserve stem selection on model switch
- [x] Preserve All stem intent across 4-stem / 6-stem model switch
- [x] Expand main action labels:
  - `Mute original`
  - `Delete original`
  - `Delete track`
  - `Mute selection`
  - `Delete selection`
- [x] Compact Native main header
- [x] Language / theme / UI top-right tooltip routing fixed across Main / Help / Select Audio
- [x] Browse label/i18n and custom path tooltip keys added
- [x] Main footer right side made more useful:
  - output summary on line 1
  - audio total on line 2

## v2.2.2.2 follow-up cleanup

- [ ] ReaPack/root vs `scripts/reaper` i18n structure cleanup
  - Decide one clear canonical shipped i18n source
  - Remove duplicated/confusing packaging paths
  - Validate the cleaned-up tree before the next full release build

- [ ] Build the next full release assets from a cleaned-up `main`
  - ReaPack/package metadata, repo tree, and release payload should agree
  - Confirm release asset filenames include version number
  - Confirm no untracked local scripts/patch helpers are included

- [ ] Reduce macOS setup bootstrap re-download/reinstall of the torch stack when runtime is already correct
  - Re-check current setup/repair behavior on Apple Silicon and Intel macOS
  - Avoid unnecessary torch reinstall when runtime verification already passes

- [ ] Path input / native folder picker cleanup
  - Do not use file-picker-as-folder-picker workaround
  - Prefer native OS folder picker via js_ReaScriptAPI if available
  - If js_ReaScriptAPI is missing:
    - disable Browse
    - show tooltip: `Folder picker requires js_ReaScriptAPI. Paste or type a path manually.`
  - Fix modal opening click being treated as outside-cancel
  - Keep Browse label capitalized
  - Add missing tooltips and i18n where appropriate
  - Keep path input reusable for:
    - custom stem folder
    - support bundle save location
    - Python path
    - FFmpeg path
    - runtime/model/cache folders

- [ ] OutputPlan / ImportPlan refactor
  - Investigate why multiple selected media items on the same source track can produce folders/stem tracks in reversed or unexpected order
  - Do not quick-fix with reverse loops
  - Build deterministic OutputPlan / ImportPlan:
    - collect selected items first
    - store source_track_guid
    - store source_item_guid
    - store item_position
    - store item_length
    - store original order
    - sort by source track + timeline position + tie-breaker
    - create folders/stem tracks from plan
    - import must not depend on job completion order
  - Future UI grouping:
    - Output: New tracks / In-place / Folder
    - Group: Per item / Per track / Selection
  - Naming/wildcard system later:
    - `$source`
    - `$track`
    - `$item`
    - `$stem`
    - `$model`
    - `$date`
    - `$index`
    - `$take`
    - `$project`

## Support / diagnostics

- [ ] Add visible About / Diagnostics / Copy report UI
  - Show installed package/script/ReaPack version clearly
  - Show runtime base path
  - Show Python path/version
  - Show FFmpeg path/version
  - Show torch / torchvision / torchaudio
  - Show audio-separator
  - Show onnxruntime
  - Show numpy / numba / llvmlite
  - Show backend/device profile and selected mode
  - Provide copy-to-clipboard diagnostics block for GitHub issues/forum posts

- [ ] Land/publish `STEMwerk_Save_Support_Bundle.lua`
  - Keep it as standalone Action List action
  - Also expose “Save Support Bundle” from `STEMwerk-SETUP.lua` maintenance UI
  - Reuse one collector implementation; do not duplicate logic
  - Must stay safe for:
    - no runtime
    - failed runtime
    - failed setup
    - failed separation
  - Keep version + OS/architecture block prominent at top of diagnostics
  - Never include audio/model/project payloads

- [ ] Add “Save Support Bundle” button in failure/no-stems/backend/Python/output-detection error UI
  - Show button at the exact failure moment
  - Reuse existing support bundle collector
  - Do not include audio/project/model payloads
  - Keep success/result UI clean
  - Localize button text
  - Decide whether to open save location after creation
  - Decide whether cancel-state should expose this subtly

- [ ] Finish hardening the support bundle collector from Linux manual-test findings
  - Ensure architecture, `uname`, Python version, and FFmpeg version are always reported when detectable
  - Ensure `python_diagnostics.txt` is never silently empty
  - Sanitize copied text logs and temp inventory so raw temp/media paths do not leak
  - Improve temp inventory metadata:
    - name
    - type
    - size
    - modified time
    - useful reason if unavailable

## GitHub issue follow-ups

### #23 — Installed version / diagnostics visibility

- Priority: support UX / medium
- Add visible About / Diagnostics / Copy report UI
- Show package/script version, runtime path, Python path/version, FFmpeg path, backend profile, torch stack, audio-separator, onnxruntime, NumPy/numba/llvmlite
- Make it easy for users to know what version is installed and copy support diagnostics

### #22 — Running-state cleanup after completion

- Priority: bug / cleanup-lifecycle / high
- Investigate case where stems are created and completion dialog appears, but main STEMwerk window does not return after OK
- STEMwerk then still thinks an instance is running
- Investigate:
  - stuck backend/Python process
  - singleton/running-state cleanup
  - temp folder handles
  - `collab_low` folder remaining locked
- Ensure completion/finalize path always clears running state and releases temp resources

### #21 — Batch output grouping for multiple selected items

- Priority: enhancement / workflow polish / medium
- Current behavior creates separate folder + child stem track per selected item
- Desired behavior:
  - when multiple selected items are on the same source track
  - and use same stem mode/output mode
  - optionally group outputs into one shared folder and one child track per stem type
- Treat as enhancement/workflow polish
- Track/routing behavior needs careful design

### #16 — Temp cleanup when only some stems are requested

- Priority: bug / cleanup-lifecycle / high
- Investigate temp files/folders not deleted when not all stems are requested
- Likely related to cleanup/finalize lifecycle and should be reviewed together with #22
- Ensure partial-stem workflows clean up temporary files safely without deleting user outputs or model cache

## REAPER progress / complete UI polish

- [x] Progress: model badge aligned with progress bar, no overflow
- [x] Progress: ETA parsing tolerant of stray spaces, no more `ETA: 2:`
- [x] Progress: device indicator reflects actual runtime device, no `GPU: DirectML` on Linux
- [x] Progress: CPU not highlighted as GPU; ETA not always green
- [x] Progress: Nerd Mode button moved so it does not overlap `Elapsed:`
- [x] Complete: add FX icon toggle near theme icon
- [x] Complete: remove Space as close/OK key
- [x] i18n: Nerd Mode tooltip strings
- [ ] Complete/progress: final header tooltip smoke-test against Main/Help
- [ ] Investigate laggy macOS tooltips/UI responsiveness separately from backend/runtime issues

## REAPER time-selection workflow correctness

- [x] Fix multi-track render producing empty `input.wav`
  - ffmpeg log
  - AudioAccessor fallback
- [x] Multi-track: refuse to launch job when per-track `input.wav` is empty
- [x] Time selection + `Mute sel`: if nothing is selected, operate on overlapping items
- [ ] Timeline Alignment / Trim Silence
  - Trim AI input to actual `AudioAccessor` boundaries within a time selection
  - Current behavior may process extra silence if time selection is larger than media item
  - Goal: reduce wasted GPU time
- [ ] Sample Rate Mismatches / Drift
  - Investigate potential sub-sample timing drift when items use different sample rate than REAPER project
- [ ] Padding Clicks / Fades
  - When items are padded with silence, apply micro-fade to avoid DC-offset clicks at zero-crossing

## Toolbar / action list

- [ ] Toolbar + icons + toolbar scripts final pass

| Script | Description |
|--------|-------------|
| **STEMwerk** | Main dialog — full control over model, stems, and options |
| **STEMwerk: Karaoke** | One-click vocal removal / karaoke workflow |
| **STEMwerk: Vocals Only** | Extract vocals |
| **STEMwerk: Drums Only** | Extract drums |
| **STEMwerk: Bass Only** | Extract bass |
| **STEMwerk: All Stems** | Extract all available stems |
| **STEMwerk: Setup Toolbar** | Add quick-access toolbar buttons |

- [ ] Verify quick presets from toolbar:
  - do not show full dialog unless expected
  - respect at-least-one-stem invariant
  - respect 4-stem/6-stem availability
  - use current output/import defaults safely

## Platform / installer backlog

### Linux AMD GPUs / ROCm support

- [ ] Detect ROCm availability:
  - `/opt/rocm`
  - `torch.version.hip`
  - `rocminfo`
- [ ] Install/guide correct ROCm-enabled PyTorch wheels for distro/ROCm version
- [ ] Ensure `audio_separator_process.py` reports usable GPU devices under ROCm
  - often via `torch.cuda`
- [ ] Update device UI/tooltips to explain ROCm requirements + fallback behavior

### Bazzite / Flatpak REAPER support

- [ ] Detect REAPER Flatpak config/scripts paths
  - likely under `~/.var/app/fm.reaper.Reaper/config/REAPER`
- [ ] Distinguish native/AppImage REAPER paths from Flatpak REAPER paths on Linux
- [ ] Extend Linux setup/sync flow so scripts land in correct REAPER Flatpak script directory
- [ ] Verify runtime/state paths still behave correctly with Flatpak-based REAPER
- [ ] Check whether current Linux installers/AppImage should detect or warn about Flatpak REAPER explicitly
- [ ] Add short Bazzite/Flatpak install note to README/help

### NVIDIA RTX 3060 laptop test matrix

- [ ] Windows fresh clone + venv setup
- [ ] Linux fresh clone + venv setup
- [ ] Install CUDA torch and verify via `python tools/gpu_check.py`
- [ ] Install REAPER scripts and verify device probe shows `cuda:0`
- [ ] Run short separation test and confirm log says `Using GPU`
- [ ] Validate multi-track mode + cancel behavior
- [ ] Validate tooltips + i18n + window placement on both OSes

### Windows installer

- [ ] Explore semi-bundled installer
  - Bundle Python installer payload
  - Bundle FFmpeg to avoid long first download
  - Keep bundled `stemwerk-core` as default path
  - Measure installer size impact for CPU / DirectML / CUDA users
  - Decide one smart installer vs optional offline Windows variants
- [ ] Clarify runtime/download expectations in docs
  - backend table for CPU / DirectML / CUDA download size
  - estimated installed size table
  - first-use model download size table for Fast / Quality / 6-Stem
  - normal processing works offline after setup + model download
  - model cache is persistent and usually survives reboots
  - correct ONNX Runtime package per backend:
    - `onnxruntime`
    - `onnxruntime-directml`
- [ ] Reduce SmartScreen / “Windows protected your PC” friction
  - Choose code-signing path:
    - Microsoft Trusted Signing
    - traditional code-signing certificate
  - Sign Windows installer artifacts with timestamping
  - Verify publisher identity stays stable across releases
  - Document false-positive / file-submission fallback for SmartScreen review

### macOS Apple Silicon / MPS

- [ ] Keep CPU as reliable Auto path on Apple Silicon until MPS is proven stable
  - Current hotfix behavior: Auto prefers CPU
  - Explicit Apple MPS remains available
  - Explicit MPS sets `PYTORCH_ENABLE_MPS_FALLBACK=1`
  - Unsupported-op failures surface clearer user-facing message
- [ ] Investigate whether stable Apple MPS support is possible for HTDemucs / audio-separator
  - Track PyTorch MPS limitation:
    - `Output channels > 65536 not supported at the MPS device`
  - Monitor PyTorch / Demucs / audio-separator MPS behavior over time
  - Revisit retry/fallback policy only after failure modes are better understood
- [ ] Keep Apple Silicon CI probes/manual workflows available but non-required until stable and low-noise
  - Manual Apple Silicon backend sanity workflow
  - Manual macOS MPS limitation probe
  - Avoid model downloads and real separation in required CI

## Runtime regression tests

- [ ] Catch partial separator installs
  - `import audio_separator` is not sufficient by itself
  - Verify `import onnxruntime`
  - Verify `from audio_separator.separator import Separator`
  - Add Windows DirectML regression case where:
    - `audio_separator` imports
    - ONNX Runtime is missing
    - or ONNX Runtime lacks `DmlExecutionProvider`

- [ ] Maintain headless CI coverage for support bundle collector
  - Exercise sanitization
  - Exercise missing-runtime behavior
  - Exercise forbidden-payload checks without requiring REAPER

## Long-file / chunked workflow

- [ ] Long-file safety: detect unusually long source items before separation
  - Warn users that Quality / 6-Stem may exceed RAM/VRAM or fail mid-run
  - Suggest trying Fast first for long recordings
  - Improve failure reporting when processing exits early

- [ ] Investigate chunked separation workflow for long recordings
  - Target live sets, DJ mixes, concerts, rehearsals, and long continuous recordings
  - Split input into chunks
  - Process each chunk separately
  - Reconstruct outputs
  - Goal: reduce memory pressure and improve stability

## Packaging / metadata / docs

- [ ] ReaPack/package metadata cleanup
  - Current feed/package display is confusing:
    - `STEMwerk-reaper/STEMwerk-reaper/...`
  - Make package naming, action naming, and installed version easier to identify
  - Review whether package description and display path can be simplified without breaking updates

- [ ] Vendor packaging hygiene
  - Replace/regenerate stale bundled `stemwerk_core-0.1.0-py3-none-any.whl`
  - Or stop shipping it as fallback once source-bundle packaging is stable

- [ ] README / docs visual pass
  - Add curated screenshots with GUI highlights
  - Annotated callouts for:
    - installer flow
    - main REAPER UI
    - setup/troubleshooting screens

- [ ] Repository housekeeping
  - Clean up local artifacts
  - Remove temporary patch scripts
  - Remove stale build clutter
  - Confirm no generated logs/assets are accidentally tracked

## Future

- [ ] Better ETA estimates / historical ETA
  - Backend progress percentage is not linear enough for reliable ETA
  - Do not calculate ETA from `progressState.percent`
  - Persist compact timing history per completed job
  - Group by model/device/mode/stem count where feasible
  - Use median historical duration per source audio second
  - Estimate total job duration from source duration
  - Show ETA only when enough comparable history exists
  - Hide ETA if confidence is low
  - Keep elapsed/status display as reliable baseline

- [ ] Progress/terminal UX — phase messages
  - Status labels are improved and localized
  - Timing diagnostics are available
  - Potential future improvements:
    - clearer phase messages if window lifecycle allows
    - elapsed-only display as reliable baseline
    - historical ETA once timing history exists
    - better multi-track job summary
  - No backend or progress-math changes unless explicitly planned

- [ ] Novice mode UX after installers stabilize
  - guided install outside REAPER
  - minimal prompts
  - clear GPU choice

- [ ] Bundled / offline distribution options
  - Windows CPU offline / semi-bundled installer
  - Windows DirectML offline / semi-bundled installer
  - Windows CUDA large offline installer as separate path
  - Linux CPU semi-bundled installer or AppImage
  - Linux ROCm / CUDA offline packs only if maintenance cost is acceptable
  - macOS semi-bundled installer path
  - Optional model packs:
    - Fast
    - Quality
    - 6-Stem

### Cross-platform Setup & Component Manager (future proposal)

This is a roadmap concept, not a commitment for the current 2.4 release line and
not a blocker for the existing installers. It requires a separate design phase
and explicit human approval before implementation.

Core boundary:

- `REAPER_IS_CONTROL_SURFACE=yes`
- `REAPER_IS_PACKAGE_MANAGER=no`
- Setup may be launched from REAPER, but dependency resolution, downloads,
  verification, installation, repair, and removal must run in a separate helper
  process rather than inside the REAPER process.

#### Product-first selection

- Ask users what they want to do: Normal Stems, 6-Stem, Direct Kit, Kit Split,
  or a future quality/specialist workflow.
- Keep model, backend, runtime, wheel, and accelerator names behind an advanced
  details view. Product intent is the primary input to dependency resolution.
- Detect OS, architecture, and available accelerators; recommend a compatible
  backend, block known-incompatible combinations, and always offer an explicit
  safe CPU choice. Never perform a silent backend fallback.
- Treat macOS Intel and Apple Silicon as different targets: Intel uses CPU;
  Apple Silicon may use MPS when the selected component supports it.
- Resolve shared dependencies once. Direct Kit and Kit Split may require a
  common base runtime plus their own model/assets, without duplicating the base.

Proposed platform/backend matrix:

| Platform | CPU | AMD | NVIDIA / native accelerator |
| --- | --- | --- | --- |
| Windows | supported | DirectML | CUDA |
| macOS Intel | supported | not applicable | not applicable |
| macOS Apple Silicon | supported | not applicable | MPS |
| Linux | supported | ROCm | CUDA |

#### Component lifecycle and distribution modes

- Support explicit `install`, `add`, `remove`, `repair`, `verify`, and
  `refresh` operations over managed components.
- Keep three distribution modes distinct:
  - **Online selective:** download and materialize only the runtime, model, and
    assets required by the selected product flow.
  - **Offline runtime:** ship a verified runtime/component payload while models
    remain separately selectable or obtainable.
  - **Offline all-models:** ship a complete, platform-specific model payload for
    environments that require a fully self-contained installer.
- An offline payload must still materialize only the selected compatible
  components into managed state; payload presence is not permission to activate
  every backend or model.

#### Release and payload publication

- Continue publishing normal/small verified assets through GitHub Releases.
- Large all-models installers may be built in-house and externally hosted, as
  with the Google Drive distribution line used for 2.3.0.0. The matching GitHub
  release description should link to the payload and publish its SHA-256.
- Do not make GitHub chunking a product requirement merely to fit a large
  installer into GitHub-hosted release assets.
- Preserve existing Windows CPU, DirectML, and CUDA distribution families;
  design separate macOS Intel and Apple Silicon families; add Linux CPU, ROCm,
  and CUDA families only through separately validated follow-up work.

#### Platform frontends

- **Windows:** an external Setup/Component Manager executable that can manage
  CPU, DirectML, and CUDA component families.
- **macOS:** separate signed/notarized Intel and Apple Silicon helper or package
  families, with architecture-specific component catalogs.
- **Linux:** a user-space helper with transactional installation into managed
  locations; no implicit system-package mutation or root requirement.

All frontends should consume one shared, versioned component-registry contract.
Each component entry should declare at least:

- component ID, version, product capability, and dependency edges;
- supported OS, architecture, accelerator/backend, and distribution mode;
- source URL or payload-relative source, byte size, and SHA-256;
- canonical destination and ownership boundary;
- install/materialization action and verification probe;
- removal/preservation policy and shared-component reference information;
- catalog/schema compatibility and minimum manager version.

#### Safety and state model

- Verify checksums and signatures where available before mutation.
- Stage downloads and extraction outside live managed state, then publish
  transactionally; failed operations must leave the last verified state usable.
- Maintain a machine-readable installed-component inventory and operation log.
- Repair verifies and restores selected managed components; it must not silently
  add products, switch accelerators, or remove preserved user/runtime state.
- Removal must respect shared dependencies and never delete user projects,
  configuration, unmanaged models, or another product's referenced component.
- Catalog or tooling failure is an explicit error, never an install trigger.
- Show disk-space impact, download size, destination, selected backend, and
  intended changes before confirmation; provide actionable failure and recovery
  guidance afterward.

#### Proposed architecture map

```text
REAPER control surface
  -> external Setup / Component Manager
       -> product-flow resolver
       -> platform and accelerator detector
       -> shared versioned component registry
       -> download / offline-payload source adapter
       -> checksum and compatibility verifier
       -> transactional materializer
       -> installed-component inventory and probes
```

#### Proposed delivery phases (no release commitment)

- **Phase A — Contract:** define product capabilities, component IDs, registry
  schema, ownership, state transitions, and compatibility rules.
- **Phase B — Resolver prototype:** prove deterministic product-to-component
  resolution and explicit CPU fallback without installing anything.
- **Phase C — Inventory and verification:** introduce read-only detection of
  installed managed components and reusable verification probes.
- **Phase D — Transaction core:** implement staged, checksum-verified,
  recoverable materialization and preserve-only repair semantics.
- **Phase E — Windows frontend:** cover existing CPU, DirectML, and CUDA families
  with online selective and explicitly scoped offline inputs.
- **Phase F — macOS frontends:** validate separate Intel CPU and Apple Silicon
  CPU/MPS signed/notarized distribution families.
- **Phase G — Linux frontend:** validate user-space CPU first, then ROCm and CUDA
  as independent, evidence-backed follow-ups.
- **Phase H — Offline publication:** define offline-runtime and all-models build,
  hosting, checksum/index, provenance, and native validation requirements.
- **Phase I — REAPER integration and UX:** expose launch/status controls only
  after the external manager and recovery path are independently proven.

- [ ] DirectML multi-track performance
  - Revisit parallel job processing for Windows DirectML once stability issue is understood
  - Current workaround forces sequential mode for DirectML multi-job runs
  - Goal: recover CUDA/CPU-like throughput without dropping outputs
  - Compare explicitly against Linux ROCm/CUDA behavior
