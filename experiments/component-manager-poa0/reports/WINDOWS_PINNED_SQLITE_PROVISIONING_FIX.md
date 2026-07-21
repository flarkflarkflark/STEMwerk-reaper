# Windows pinned SQLite provisioning and push suppression

## Scope and evidence

Authoritative native run `29799444700` proved that the Windows Rust durability activation completes, including selector file flush, selector replacement, write-capable parent-directory open, and parent-directory flush. The post-activation SQLite check then failed with `program not found`. That failure disproved the assumption that `sqlite3.exe` was already present on the targeted runner. Earlier Windows matrix evidence provisioned SQLite successfully with Chocolatey at exactly `3.53.3`, resolving `C:\ProgramData\Chocolatey\bin\sqlite3.exe`.

This change is orchestration-only. SQLite CLI is a test/diagnostic dependency, not a Component Manager runtime or product dependency. It is installed only on the ephemeral Windows runner for the bounded Rust route selecting `CMN-001,CMN-008`, before the first post-activation SQLite call. Rust continues to use the unchanged `Command::new("sqlite3")` call.

## Provisioning contract

The targeted job runs `choco install sqlite --version=3.53.3 --yes --no-progress --limit-output` and requires a zero exit code. It then requires exactly the installed package record `sqlite|3.53.3`, exactly one application candidate from `Get-Command sqlite3.exe`, an absolute existing `sqlite3.exe` path below `ChocolateyInstall`, and executable version output beginning with exactly `3.53.3`. The resolved executable is exported as `STEMWERK_POA0_SQLITE_EXE`; its parent is appended to `GITHUB_PATH`.

A separate PowerShell step proves new-process visibility with `Get-Command`, `where.exe`, the explicit environment path, and the PATH-resolved command. Missing, ambiguous, non-Chocolatey, non-executable, or wrong-version results fail closed. There is no retry, latest-version resolution, fallback version, alias, wrapper, or SQLite shim. Queries and test semantics are unchanged.

## Exact push suppression

Push run `29799397516` expanded the eight-job matrix for an orchestration-only commit. A pre-matrix classification job now suppresses only a push whose parent is exactly `46f18ae8331b84e180bd00e29b9fcb882c8a25c0` and whose non-empty diff contains only:

- `.github/workflows/component-manager-poa0-native.yml`
- `experiments/component-manager-poa0/reports/WINDOWS_PINNED_SQLITE_PROVISIONING_FIX.md`

Every other parent or path requires the matrix. `workflow_dispatch` remains outside this suppression, so the bounded Windows Rust native rerun remains available. The existing PR and release workflow behavior is untouched.

## Equality and required rerun

No Rust or Go source, durability contract, harness, case ID/source, expected result, fixture, schema, fault injection, frozen manifest, verifier policy, selector serialization/replacement, generation/run-pinning/lease model, or SQLite query changed. Native validation of pinned provisioning and targeted `CMN-001`/`CMN-008` closure is still required.
