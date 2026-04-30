# ROADMAP After v2.2.2.0

Conservative planning document for the phase after the public `v2.2.2.0` release.

## Immediate post-2.2.2 priority

- Treat `v2.2.2` as the architecture/refactor release.
- Keep the next normal branch boring: stabilization and hardening only.
- Do not add big new features immediately after `v2.2.2`.
- Do not start a C++ rewrite immediately after `v2.2.2`.
- Preserve current user workflows across Windows, Linux, and macOS.

## Proposed branch: `stabilize/2.2.3-post-refactor`

Purpose of this branch:

- Fix regressions introduced by the refactor.
- Harden startup and setup flows.
- Verify behavior parity with `main` user expectations.
- Keep ReaPack and installer behavior stable.
- Improve diagnostics and lightweight tests.
- Reduce remaining global-state risks gradually.

## Suggested 2.2.3 hardening checklist

- [ ] Startup works on Windows, Linux, and macOS.
- [ ] Main UI opens without nil-index or nil-call errors.
- [ ] Window geometry persists correctly.
- [ ] Language/i18n still works.
- [ ] Settings and ExtState migration are safe.
- [ ] Python detection works.
- [ ] FFmpeg detection works.
- [ ] Missing Python shows a useful message.
- [ ] Missing FFmpeg shows a useful message.
- [ ] CPU fallback works.
- [ ] GPU/device labels still make sense.
- [ ] 4-stem workflow works.
- [ ] 6-stem workflow works.
- [ ] Selected items workflow works.
- [ ] Time selection workflow works.
- [ ] New tracks/take insertion behavior matches the previous stable release.
- [ ] Cancel/stop behavior works.
- [ ] Logs are written to expected locations.
- [ ] ReaPack index payload does not contain junk files.
- [ ] No `.DS_Store`, `._*` resource forks, temp files, or local artifacts are included.
- [ ] `VERSION`, `README`, ReaPack index, installer metadata, and release notes agree.

## Module hardening TODO

- Audit remaining globals in internal modules.
- Prefer explicit `configure(ctx)` injection where practical.
- Do not convert everything at once.
- Start with low-risk dependencies: `OS`, `PATH_SEP`, `SETTINGS`, `LOG`, `HELPERS`, runtime/system helpers.
- Keep compatibility wrappers where needed during migration.
- Add small tests around System, Settings, Devices, ExtState, and path helpers.

## Testing path (lightweight first)

- Lua syntax/load smoke checks.
- Module load-order checks.
- Path quoting/path join tests.
- Settings roundtrip tests with fake ExtState.
- Device normalization tests.
- Runtime setup dry-run tests.
- ReaPack payload validation.
- Release asset naming validation.

## Optional Native Bridge - Future Spike

Recommended experimental branch: `feature/native-bridge-spike`

Boundaries:

- C++ must not replace Lua.
- C++ must not replace Python/Demucs/audio-separator.
- C++ must be optional.
- Lua must always fall back to the current legacy route if the native extension is missing.
- Start as a small REAPER extension experiment only.

Possible first native API surface:

- `Stemwerk_GetNativeVersion()`
- `Stemwerk_GetPlatformInfo()`
- `Stemwerk_ResolveRuntimePaths()`
- `Stemwerk_StartProcess(json)`
- `Stemwerk_GetProcessStatus(job_id)`
- `Stemwerk_CancelProcess(job_id)`

First C++ goal (and only goal for the spike):

- Better process control.
- Better path handling.
- Cleaner job status/cancel behavior.
- Less Lua polling complexity.
- Fewer Windows process/window quirks.
- No ML/model rewrite.

## Architecture principle

Lua = REAPER UI and user workflow  
Python = AI/separation backend  
Optional C++ = native reliability bridge

## Merge policy

- Do not merge native bridge work into `main` until it is optional and fully fallback-safe.
- Do not make native bridge required for ReaPack installs.
- Keep stable releases boring.
- Prefer small, reviewable PRs after `v2.2.2`.

