# STEMwerk 2.2.2 — Route B Release Checklist

**Branch:** `refactor/2.2.2-dev`
**Target release date:** 1 May 2026

---

## 1. Release identity

STEMwerk 2.2.2 is a focused cleanup and polish release: UI primitive
extraction, theming Pass A, platform phase-1 groundwork, i18n and
presentation consistency, and setup/install UX feedback improvements.

It is **not** the macOS async-spawn fix release. It is **not** a runtime
or setup redesign. It is **not** a cross-platform resolution release. It
is a disciplined Route B scope — groundwork and polish, no structural
rewrites, no speculative scope expansion.

If an item is not in the Route B plan (`docs/planning/REFACTOR_2_2_2.md`),
it is not in 2.2.2.

---

## 2. Must-have before release

- [ ] Route B scope remains contained — no new items have been merged that were not in the original plan
- [ ] `STEMwerk_UI_Draw.lua` extraction is finished and stable (no regressions in draw behavior)
- [ ] Theming Pass A is landed (gloss token per theme, shadow spread tuning)
- [ ] `STEMwerk_Platform.lua` phase 1 exists and loads cleanly on all platforms
- [ ] Setup/install UX feedback improvements are working:
  - [ ] Error-code to human-message mapping
  - [ ] Live "last log line" feedback during install
  - [ ] Runtime-dir write test runs before expensive setup steps
  - [ ] Windows execution-policy check (if included) is safe and clearly presented
- [ ] i18n and presentation pass is complete (no mixed-language labels, no raw keys visible in UI)
- [ ] Typography and spacing are consistent across all UI surfaces
- [ ] Final theming coherence: themes feel visually distinct on pilot themes (studio, aurora, copper)
- [ ] Windows smoke test passes (setup, main UI, at least one separation)
- [ ] Linux smoke test passes (setup, main UI, at least one separation)
- [ ] At least one macOS non-regression sanity check (confirm nothing regressed; async fix not required)
- [ ] No obvious regressions vs. 2.2.1.x in validation matrix
- [ ] Release notes can describe the release honestly without claiming any out-of-scope fix landed
- [ ] `docs/` and `README` are consistent with the actual 2.2.2 scope
- [ ] Working tree on release branch is clean (no uncommitted stubs, no leftover WIP)
- [ ] `VERSION` file updated to `2.2.2`
- [ ] `index.xml` (ReaPack index) updated and consistent

---

## 3. Nice-to-have

Items below are welcome if they land cleanly before 1 May 2026, but are
**not blockers**. If not ready, they move to 2.2.3.

- [ ] Shadow Pass B (widen shadow spread to perceptual threshold) — low risk if Pass A is stable
- [ ] Minor tooltip shadow tint per theme — follows from Pass A naturally
- [ ] Button padding ±2px per theme — only if primitives are fully stable
- [ ] Any small ergonomic improvements to setup messages or log formatting that are genuinely low-risk

---

## 4. Explicitly out of scope

The following are **not** part of 2.2.2 and must not be merged or promised:

| Item | Reason |
|---|---|
| macOS async-spawn fix | Higher-risk runtime behavior work; moved to 2.2.3 unless proven separately |
| Python 3.13 support | Validation surface too large for this release window |
| Generic ROCm auto-detection improvements | Hardware detection broadening is not validated enough for Route B |
| CUDA version auto-detection | Backend-selection logic changes too risky for a polish release |
| Bootstrap convergence (three scripts → one flow) | Too large; belongs to 2.2.3 design |
| Runtime/setup redesign | Structural; outside Route B entirely |
| Resumable install | Requires state-model changes not central to Route B |
| Offline installer redesign | Packaging/distribution scope too large |
| Windows embedded Python | Requires distribution and support model changes |
| `STEMwerk_Platform.lua` phase 2 | Deeper behavior rewrite; 2.2.3 work |
| Theming Pass C / additional themes (noir, forest, soft) | Optional future phases; not required for Route B |
| Larger native/UserPlugin exploration | Architecture scope outside 2.2.2 |
| Any item not explicitly listed in REFACTOR_2_2_2.md | Out by default; vague "maybe" items are cut by rule |

---

## 5. Known issues to call out

Items below are acknowledged and documented but are **not release blockers**
for 2.2.2:

- **Windows window flicker / console flicker** — existing behavior, no regression introduced in 2.2.2; tracked for future work
- **Playback-rate alignment issue** — pre-existing; not introduced in Route B scope
- **macOS async-spawn behavior** — known, intentionally deferred to 2.2.3; must be called out clearly in release notes
- **Setup edge cases on non-standard Python paths** — existing surface; 2.2.2 improves error messaging but does not fully resolve all path-resolution edge cases
- **Light-mode elevation visual parity** — Pass A brings improvements but full parity across all surfaces may take further passes

---

## 6. Release-ready criteria

2.2.2 is ready to ship when **all** of the following are true:

- [ ] All must-have checklist items above are completed
- [ ] No regressions in Windows smoke test
- [ ] No regressions in Linux smoke test
- [ ] macOS non-regression check shows no new breakage
- [ ] `VERSION` is `2.2.2`, `index.xml` is consistent
- [ ] Release notes accurately describe what landed (Route B scope only)
- [ ] No known crashes introduced in this release
- [ ] Working tree is clean on the release branch
- [ ] No out-of-scope items were merged without explicit decision

If any must-have item is not complete by 1 May 2026, defer it to 2.2.3.
Do not slip the date by expanding scope.

---

## 7. Release-notes skeleton

> **Draft only — fill in final details at release time.**

---

### STEMwerk 2.2.2

STEMwerk 2.2.2 is a focused cleanup and polish release: cleaner UI
primitives, theme-aware visual finish, platform groundwork, and better
setup feedback.

**Included in this release:**

- Extracted shared draw primitives (`STEMwerk_UI_Draw.lua`) for cleaner UI code structure
- Theming Pass A: per-theme gloss and shadow tuning; pilot themes (studio, aurora, copper) now feel visually distinct
- `STEMwerk_Platform.lua` phase 1: passthrough groundwork for future platform handling
- Setup/install UX improvements: clearer error messages, live install progress feedback, runtime-dir write test
- i18n and typography consistency pass across all UI surfaces

**Known limitations / notes:**

- macOS async-spawn behavior is unchanged in this release; fix is planned for 2.2.3
- Python 3.13 is not validated in this release
- Windows window flicker is a pre-existing behavior and is not resolved in 2.2.2
- Playback-rate alignment is a pre-existing limitation; not changed in this release

---

*This checklist is authoritative for the 2.2.2 Route B release pass.
Refer to `docs/planning/REFACTOR_2_2_2.md` for the full scope contract.*
