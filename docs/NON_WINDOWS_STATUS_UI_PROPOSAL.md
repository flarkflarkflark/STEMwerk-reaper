# Non-Windows Status UI Proposal

## Goal

Improve setup progress and failure visibility on macOS and Linux without
copying the Windows installer model, which depends on an interactive
platform-specific installer shell and runs fully in user context.

## Constraints

- Keep runtime bootstrap per-user.
- Do not run Python/venv/pip setup from Linux package manager hooks.
- Do not run full runtime bootstrap from macOS `postinstall` as root.
- Preserve the REAPER-first setup flow.

## Recommended model

### Shared contract

Use the existing REAPER setup UI as the primary progress surface on macOS and
Linux, backed by the bootstrap state and log files.

Standardize these fields in `bootstrap.env` while a run is active:

- `STATUS=running|ok|deps_failed|...`
- `STATUS_REASON=<machine-readable reason>`
- `PROFILE=<backend profile>`
- `BACKEND=<cpu|cuda|rocm|...>`
- `BACKEND_REASON=<machine-readable explanation>`
- `STEP_INDEX=<n>`
- `STEP_TOTAL=<n>`
- `STEP_LABEL=<human-readable stage>`

Keep the log file as the detailed stream and the env file as the stable status
surface.

### Linux

Keep the current model:

- package/AppImage installs scripts only
- first run in REAPER performs bootstrap in the user session

Improve the setup screen with:

- a stage label driven by `STEP_INDEX`, `STEP_TOTAL`, and `STEP_LABEL`
- a compact summary block for Python path, FFmpeg path, profile, backend, and
  backend reason
- action buttons for `Open Log`, `Open Runtime Folder`, and `Retry Setup`
- a clearer split between bootstrap failure and post-bootstrap verification

Do not move GPU detection or dependency installation into `.deb`, `.rpm`, Arch,
or AppImage install-time hooks.

### macOS

Keep `pkgbuild` + `postinstall` focused on copying scripts into the user's
REAPER Scripts folder.

Improve the user handoff with:

- postinstall message that explicitly says `Run STEMwerk_First_Run_Setup.lua`
- optional creation of a small marker file that the REAPER setup UI can read to
  show `Installed successfully, runtime setup still required`
- the same REAPER-side progress/status UI contract as Linux

Do not let `postinstall` create venvs or install Python packages as root.

## Why not reuse the Windows model directly

Windows succeeds because the installer:

- installs directly into the user REAPER script path
- runs bootstrap in the user context
- owns the installer UI lifecycle

macOS and Linux package installers generally do not provide that same safe,
interactive, per-user runtime setup context. Reusing the exact Windows model
would add permission and ownership risk without improving reliability.

## Recommended implementation order

1. Add stable step metadata to `bootstrap.env`
2. Teach the REAPER setup UI to show step progress from env + log
3. Add direct buttons for logs/runtime folder/retry
4. Improve failure summaries so `bootstrap_failed` and verification issues are
   visually distinct

## Non-goals

- cross-platform installer unification
- root-level runtime bootstrap
- major redesign of the existing REAPER setup flow