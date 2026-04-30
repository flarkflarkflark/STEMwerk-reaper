# STEMwerk 2.2.2 — Validation Snapshot

**Branch:** `refactor/2.2.2-dev` (Route B)
**Target release date:** 1 May 2026

---

## Purpose

This is the practical validation snapshot for the 2.2.2 Route B release
line. It captures which environments have been exercised, what was
confirmed, what still needs a final check, and what known issues are
accepted as non-blockers.

This is not release notes. This is not a test lab report. This is the
working reference used during the release readiness pass.

---

## Validated environments so far

| Environment | GPU / backend | Status |
|---|---|---|
| Linux (Arch/ROCm) | AMD GPU — ROCm | Exercised — setup, processing, output confirmed |
| Linux (Bazzite) | NVIDIA RTX 3060 — CUDA | Exercised — setup, processing, output confirmed |
| Windows 11 | NVIDIA RTX 3060 — CUDA | Exercised — setup, processing, output confirmed |
| Windows 11 | AMD GPU — DirectML | Exercised — setup, processing, output confirmed; DirectML quirks documented in `docs/WIN&AMD_GPU` |
| macOS (Intel, Ventura via OCLP) | CPU only (MPS not available on Intel) | Exercised — CPU-mode processing confirmed; async-spawn behavior is a known open item, not a 2.2.2 blocker |

**Not yet validated for 2.2.2 Route B specifically:**
- macOS Apple Silicon (MPS) — no current test coverage in this release line
- Windows AMD GPU with ROCm — not applicable (DirectML is the Windows AMD path)
- Linux CPU-only path — not explicitly confirmed as a standalone run in 2.2.2 dev work

---

## What was validated at a high level

- [ ] Setup flow completes without errors on validated environments
- [ ] Runtime directory and Python path are recognized correctly
- [ ] Main UI opens and renders correctly (theme, typography, i18n)
- [ ] Processing runs and produces correct stems (at least one separation per environment)
- [ ] Output returns correctly (files written, no silent failures)
- [ ] GPU device selection works as expected (Auto, CPU fallback, explicit device)
- [ ] UI/theming sanity: gloss, shadow, rounding visually consistent across pilot themes
- [ ] i18n: no mixed-language labels, no raw keys visible in UI
- [ ] Multi-track behavior (parallel / sequential) consistent with documented behavior

Items marked above reflect exercised behaviors across the development of
this branch. A final Route B sanity pass is still required before release.

---

## Known gaps / still to confirm

- [ ] Final Route B sanity pass on Windows (setup + UI + one separation, post all 2.2.2 changes)
- [ ] Final Route B sanity pass on Linux (same)
- [ ] macOS non-regression check — confirm nothing regressed vs. 2.2.1.x; async fix is not required
- [ ] Setup/install UX feedback improvements confirmed working end-to-end (error messages, live log line, runtime-dir write test)
- [ ] Windows execution-policy check (if included) confirmed safe and clearly presented
- [ ] Release-polish: VERSION updated, index.xml consistent, release notes draft reviewed
- [ ] Working tree clean on release branch before tag

---

## Known non-blocking issues

These are accepted as non-blockers for 2.2.2 and must be called out in
release notes:

- **Windows window flicker / console flicker** — pre-existing behavior; no regression introduced in 2.2.2
- **Playback-rate alignment (in-place takes)** — fixed in 2.2.2-rc1 by restoring source take playback-state (`D_PLAYRATE`, `D_PITCH`, `B_PPITCH`) on imported stem takes
- **macOS async-spawn behavior** — known, intentionally deferred to 2.2.3; Intel CPU-mode works
- **Light-mode elevation parity** — Pass A brings improvements; full parity across all surfaces is a future pass
- **Setup edge cases on non-standard Python paths** — improved error messaging in 2.2.2 but not fully resolved

---

## How to use this note

Use this document during the final release pass to confirm:

1. All validated environments are covered before tagging
2. Known gaps are resolved or explicitly accepted
3. Non-blocking issues are reflected accurately in release notes
4. Nothing was added to scope between this snapshot and the release tag

Cross-reference with `docs/planning/RELEASE_2_2_2_CHECKLIST.md` for the
full must-have / out-of-scope / release-ready criteria.
