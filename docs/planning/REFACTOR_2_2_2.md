# STEMwerk 2.2.2 Route B Plan

Working plan for `refactor/2.2.2-dev`. `main` remains the 2.2.1.x maintenance line.

## Release target

Target release date: **1 May 2026**

This date is a real boundary. If an item is not ready by 1 May 2026, it moves to 2.2.3.  
2.2.2 scope does not expand after this plan is agreed.

## Release theme (Route B)

2.2.2 is a focused cleanup release:
- cleaner UI primitives structure
- theming Pass A with controlled visual polish
- safer platform groundwork (phase 1 only)
- better setup/install feedback UX
- cross-platform consistency groundwork, not full cross-platform resolution

2.2.2 is **not** blocked on the macOS async-spawn fix.  
That fix is planned for 2.2.3 unless it is proven separately first.

## Why this scope exists

Earlier 2.2.2 planning mixed two different releases:
- a UI/theming/refactor release
- a cross-platform runtime-fix release (including macOS async-spawn)

Route B deliberately splits these.  
Reason: safer delivery, lower regression risk, and clearer release truthfulness.

## In scope for 2.2.2

1. Finish `STEMwerk_UI_Draw.lua` extraction.
What this means: complete remaining stubbed primitives and stabilize the extraction without behavior drift.

2. Land theming Pass A only.
What this means: controlled, token-level polish and theme consistency improvements; no broad redesign.

3. Add `STEMwerk_Platform.lua` phase 1 as passthrough groundwork.
What this means: introduce the module and clean loading boundaries, with no risky behavior rewrite.

4. Land additive setup/install UX feedback improvements.
What this means:
- clearer error-code to human-message mapping
- live "last log line" feedback during install
- runtime-dir write test before expensive setup steps
- Windows execution-policy check only if presented clearly and safely

## Explicitly NOT in 2.2.2

- macOS async spawn fix: cut for 2.2.2 because it is higher-risk runtime behavior work; moved to 2.2.3 unless proven separately first.
- Python 3.13 support: cut because validation surface is too large for this release window.
- generic ROCm auto-detection improvements: cut because hardware detection broadening is not validated enough for Route B.
- CUDA version auto-detection: cut because backend-selection logic changes are too risky for a polish-groundwork release.
- bootstrap convergence (three scripts to one flow): cut because it is too large and belongs to 2.2.3 design work.
- runtime/setup redesign: cut because it is structural and outside Route B.
- resumable install: cut because it needs state-model changes not central to Route B.
- offline installer system: cut because packaging/distribution scope is too large for 2.2.2.
- Windows embedded Python: cut because it requires distribution and support model changes.
- vague "maybe" items: cut by rule; if not explicitly listed in this document, it is out of 2.2.2.

## Execution order (strict)

1. Finish `STEMwerk_UI_Draw.lua` extraction.
2. Land theming Pass A.
3. Add `STEMwerk_Platform.lua` phase 1.
4. Land setup/install UX feedback improvements.

No macOS async-fix work is part of the 2.2.2 execution order.

## 2.2.2 is done when

Technical minimums:
- UI_Draw extraction is finished and stable.
- theming Pass A is landed without obvious regressions.
- Platform phase 1 exists and loads cleanly.

UX minimums:
- setup/install UX feedback improvements are working (error mapping, live log line, runtime-dir write test, and any included Windows policy check).

Validation minimums:
- Windows smoke tests pass.
- Linux smoke tests pass.
- no obvious regressions in the current validation matrix.
- release notes can describe the release honestly without claiming the macOS async fix landed.

## 2.2.3 begins here

- macOS async prototype/fix
- bootstrap convergence
- runtime/setup cleanup
- resumable install
- runtime/version mismatch handling
- offline installer strategy
- Windows embedded Python exploration
- stronger `STEMwerk_Platform.lua` phase 2

## Release-discipline rule

If an item is not clearly in this document, it is not in 2.2.2.  
Unfinished work moves forward to 2.2.3.  
2.2.2 must not grow into a monster release.
