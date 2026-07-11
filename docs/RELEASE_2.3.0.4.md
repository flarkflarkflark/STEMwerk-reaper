# STEMwerk 2.3.0.4

## Scope

`2.3.0.4` is a small hotfix release on top of the `2.3.0.3` patch line.

- `2.3.0.4` supersedes the original `2.3.0.0` Windows full installers as the current recommended Windows hotfix release.
- `2.3.0.4` keeps the `2.3.0.0` full-release basis.
- The Windows update-patch asset remains retired and is not published.
- The large offline/allmodels installers remain separate and are not rebuilt here.

## Recommended users

- Recommended for ReaPack users in the `2.3.x` line who already have a working install and want the DrumSep timeout fix plus current docs/helper updates.
- Recommended for Windows users doing a fresh install or cleaning up an incomplete install that was missing REAPER Action List registration.
- macOS and Linux package users get the same updated script payload through the shared `scripts/reaper/` tree when `2.3.0.4` packages are built.

## Update guidance

- ReaPack users with a working `2.3.x` install can update via ReaPack.
- Windows users with incomplete or fresh installs should use the `2.3.0.4` installer.
- Existing Windows users should uninstall the old STEMwerk version first, then install `2.3.0.4` using the full online or bundled installer.
- Offline/allmodels installers remain on the `2.3.0.0` line and are not rebuilt for `2.3.0.4`.

## Fixes included in 2.3.0.4

- Fixed long-running DrumSep, Direct Kit, and Kit Split jobs being killed after a duplicated hard `3600` second wall-clock timeout.
- DrumSep helper monitoring now uses a progress-aware no-output stall watchdog instead of an absolute one-hour kill.
- Stall detection now reports a no-progress/no-output condition specifically and includes elapsed time plus the last known progress percentage when available.
- Windows installer and manual setup guidance now explains the REAPER Action List registration step more clearly.
- `STEMwerk_Setup_Toolbar.lua` remains the preferred one-time registration helper and also registers `Stemwerk: Drum Kit Split`.
- README/docs polish, platform screenshots, offline/allmodels links, and the full-workflow demo GIF are included in this hotfix line.

## Pre-release live smoke plan

- READY_TO_GO_SMOKE_PASS: verify `STEMwerk: Setup` reaches a healthy ready-to-go state on the supported release routes before publication.
- PRE_RELEASE_SMOKE_MATRIX_BLOCKED: full live cross-platform smoke remains a release-stage check and is not completed by this repo-only prep commit.
