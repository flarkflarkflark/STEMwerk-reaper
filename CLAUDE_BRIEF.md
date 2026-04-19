# CLAUDE_BRIEF.md

Branch: refactor/2.2.2-dev

This package is for refactor/dev work, not main maintenance. No repo access is available beyond this zip.

## Current status
- STEMwerk.lua is much smaller than main; now mostly orchestrator + UI/event glue
- Help/UI refactors already happened
- Semantic ACTIVE_THEME resolver exists with legacy THEME.* compatibility
- Pilot themes: studio, aurora, copper

## Claude: Please focus on
1. Best next refactor slice
2. Safest further extraction candidates in/around STEMwerk.lua
3. How to evolve theming so themes feel more distinct without destabilizing the app

## Please avoid recommending lightly
- Workflow/apply/finalize surgery
- Runtime/setup redesign
- Main branch changes

## Known direction
- Future release line: 2.2.2-dev
- Main branch: maintenance release v2.2.1.10

---

This is a curated handoff for analysis, not a release artifact. All files are from the refactor/2.2.2-dev branch.