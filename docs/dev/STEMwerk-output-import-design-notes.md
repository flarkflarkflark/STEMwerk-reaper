# STEMwerk Output/Import Design Notes

## Scope
Design/audit only. No runtime code changes in this note.

## Current Situation (as implemented)

### 1) Output destination (currently one binary switch)
In main UI, output is currently a binary radio:
- `New tracks` (`SETTINGS.createNewTracks = true`)
- `In-place` (`SETTINGS.createNewTracks = false`)

Reference:
- `scripts/reaper/STEMwerk.lua` around output UI (`drawRadio`): lines ~11367-11376.

### 2) Grouping (newly added)
- Setting key: `outputGrouping`
- Values: `per_item` (default), `source_track`
- Persisted in ExtState and normalized with fallback to `per_item`.

References:
- `scripts/reaper/_internal/STEMwerk_Settings.lua`: `normalizeOutputGrouping`, load/save around lines ~74-80, ~115-120, ~262-263.
- `scripts/reaper/STEMwerk.lua`: default settings and normalize helper around lines ~1212, ~1236-1241.

Important behavior:
- Grouping is only applied when destination is `new_tracks`.
- For non-New-Tracks, code force-falls back to `per_item` at processing time.

Reference:
- `scripts/reaper/STEMwerk.lua` in `_sep.processAllStemsResult`: lines ~18083-18088.

### 3) “Stem files” is not output destination
Current `Stem files` section controls where intermediate/final stem WAV files are stored before/around import:
- `temp`
- `project_media`
- `custom`

This is storage/I/O policy, not track import style.

References:
- `scripts/reaper/STEMwerk.lua` lines ~11406-11455.
- Labels/tooltips via helper functions in `scripts/reaper/_internal/STEMwerk_Helpers.lua` (`getStemFiles*`).

### 4) Takes behavior is currently tied to in-place flow
Current takes pipeline is in-place replacement flow:
- replace source item/selection
- create one multi-take item from stem files
- optional post-process explode modes

References:
- In-place UI options: `keep_takes`, `explode_*` in `STEMwerk.lua` lines ~11560-11596.
- Core logic in `scripts/reaper/_internal/STEMwerk_Workflow.lua`:
  - `replaceInPlacePartial` (~916+)
  - `replaceInPlace` (~1056+)

## Terminology Collision (what is currently mixed)

1. `Output` currently mixes destination and import style conceptually:
- “In-place” implicitly means “import as takes on source item”.
- “New tracks” implies “separate items on new tracks”.

2. `Grouping` is destination-specific (New Tracks only), but rendered in same column as `Stem files` and `Output`, which may imply universal effect.

3. `Stem files` sounds like import mode to users, but technically is disk location policy.

4. `Takes` appears both as:
- core in-place replacement model
- post-process explode options
This can be interpreted as global import style, while code scope is currently mostly in-place.

## Takes Code Reuse Assessment

### What exists and is reusable
- Robust take-merging logic exists in in-place functions:
  - create per-stem temp item
  - merge into one main item with multiple takes
  - preserve naming/colors
  - apply source playback state with guard against double-stretch

References:
- `WORKFLOW.replaceInPlace*` + `applyPlaybackStateToTake` in `STEMwerk_Workflow.lua`.

- New-tracks creation already has stable ordering, per-item overlap slicing, source-track grouping hooks and preplanned target routing.

References:
- `createStemTracksForSelection` in `STEMwerk.lua` (~14619+)
- `resolveTrackTargets` / shared targets in `_sep.processAllStemsResult` (~18298+)

### What does NOT exist yet
- A dedicated “new track target + multi-take single item” import path.
- Today, New Tracks path imports one item per stem track (not one item with multiple takes).

## Feasibility: “New Tracks + Takes”

Verdict: **Technically feasible** with moderate UI/logic refactor, no backend separator changes required.

### Functional definition options
Option A (recommended first):
- For each target context (per item or per source track), create **one target track**.
- Import stems as **takes on one item** at the context time position.

Option B:
- Keep one stem track per stem type but also add takes per track (less intuitive, not recommended).

Option A aligns with user expectation of “takes op nieuwe tracks/items”.

### Compatibility with grouping
- `Per item`: very logical. Each selected source item -> one new target track with one multi-take item.
- `Per source track`: also logical. One shared target track per source track, each clip position gets a multi-take item on that same target track.

## Key Risks / Regression Points

1. Item-length and overlap slicing
- Must preserve existing overlap logic used by `createStemTracksForSelection` (`pos/len` per item/time-selection slice).

2. Playback-rate/pitch transfer
- In-place currently applies guarded playback-state transfer.
- New Tracks + Takes should reuse same guard, otherwise risk double-stretch or pitch mismatch.

3. Naming consistency
- Need deterministic take naming (`Take n/m: <source> - <stem>` style) and track naming conventions per grouping mode.

4. Import order stability
- Existing per-track insertion cursor logic must stay deterministic for multi-item runs.
- Especially with `source_track` grouping, item order on shared targets must remain timeline-stable.

5. Undo granularity
- Current functions open nested undo blocks in several paths.
- New mode should align with existing top-level undo block behavior to avoid noisy undo stack.

6. Post-process explode semantics
- Current explode options are in-place oriented.
- For new-tracks+takes, either disable explode options initially or explicitly scope them.

7. Footer/help/status text
- Current footer strings assume either “new tracks” or “in-place takes”.
- New import style introduces a third visible model needing explicit wording.

## Proposed UI Taxonomy (clean separation)

### 1) Uitvoerbestemming (where stems go)
- Nieuwe tracks
- Op bronitems (in-place)

### 2) Importstijl (how stems are materialized)
Contextual by destination:
- If `Nieuwe tracks`:
  - Losse stem-items (current behavior)
  - Takes op nieuw doelitem (new feature)
- If `Op bronitems`:
  - Takes op bronitem (current behavior; implied default)

### 3) Groepering (only for Nieuwe tracks)
- Per item
- Per brontrack
- Disabled + tooltip when destination != Nieuwe tracks (already implemented pattern)

### 4) Stem files (rename for clarity)
Suggested label: `Stem file opslag` / `Stem file location`
- Temp
- Project
- Custom

This avoids confusion with import style.

## Suggested Implementation Order

1. Internal model split (small refactor)
- Introduce explicit `outputDestination` and `importStyle` settings, keep backward mapping from `createNewTracks` for compatibility.

2. Implement New Tracks + Takes importer (Option A)
- Reuse overlap/ordering/grouping pipeline from `createStemTracksForSelection`.
- Reuse take-merge/playback-state guard from `WORKFLOW.replaceInPlace*`.

3. UI wiring
- Add Importstijl control with contextual visibility.
- Keep Groepering scoped to Nieuwe tracks.

4. Footer/help/i18n polish
- Clarify destination vs import style vs file storage.

5. Regression tests/manual smoke matrix
- Per item + per source track for both import styles under New Tracks.
- Time-selection overlaps, item playrate, naming, and undo behavior.

## Minimal Safe Slice Recommendation

For first delivery of this feature:
- Only add `Nieuwe tracks + Takes op nieuw doelitem`.
- Keep In-place behavior unchanged.
- Keep grouping behavior unchanged and scoped to New Tracks.
- Defer advanced explode behavior in new mode.

This keeps risk contained and makes UX immediately clearer.

## Workflow-First REAPER Design

STEMwerk output/import opties moeten ontworpen worden rond echte REAPER-workflows, niet alleen rond interne codepaden.

### 1) Simple/default workflow
- Doel: gebruiker wil snel stems op nieuwe tracks.
- Veilige default met weinig keuzes.
- Basispad: `New Tracks + Per item + losse stem-items`.

### 2) Arrangement/montage workflow
- Doel: meerdere clips op één source track samen netjes organiseren.
- Basispad: `New Tracks + Per source track`.
- Dit is precies de nieuwe grouping-feature.

### 3) Take-based REAPER workflow
- Doel: stems/varianten beheren als takes.
- Huidig: bronitem-takes via in-place workflow.
- Toekomstig: mogelijke `New Tracks + Takes` variant.
- Eisen: REAPER-native gedrag en volledig undoable.

### 4) Cleanup/replace workflow
- Doel: origineel dempen/wissen/vervangen (power-user).
- Moet duidelijk gelabeld, voorspelbaar en undoable blijven.
- Geen verborgen destructief gedrag.

### 5) File-management workflow
- Vraag: waar blijven stemfiles?
- `Temp / Project / Eigen` gaat over opslaglocatie.
- Dit is geen importstijl.
- Daarom later bij voorkeur label-polish: `Stem files` -> `Opslag` of `Stem-bestandopslag`.

## Design Principles

- Defaults veilig en simpel houden.
- Luxe/advanced opties contextueel tonen of activeren.
- Niets onverwacht destructief doen.
- REAPER-native concepten gebruiken: items, takes, tracks, folders, source tracks.
- Outputstructuur moet voorspelbaar zijn.
- Alle acties moeten goed undoable blijven.
- Unsupported combinaties liever disabled + tooltip dan stil verwarrend gedrag.

## Recommended Rollout Order

1. Terminologie/layout polish: `Stem files` -> `Opslag`.
2. Eventueel importstijl-concept ontwerpen.
3. Pas daarna `New Tracks + Takes` prototype.
4. Pas veel later eventueel advanced presets/workflow modes.
