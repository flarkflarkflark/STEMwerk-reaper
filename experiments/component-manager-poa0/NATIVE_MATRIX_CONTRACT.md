# Native matrix contract

Result classes are `PASS_NATIVE`, `FAIL_NATIVE`, `NOT_RUN`,
`CROSS_BUILD_ONLY`, and `UNSUPPORTED_ENVIRONMENT`. A cross-build can never
produce `PASS_NATIVE`.

## Common cases (24 per language/platform)

The canonical IDs are stored in `fixtures/expected/test-cases.json`:
CMN-001 through CMN-020 are the original lifecycle/crash/concurrency matrix;
CMN-021 is missing-process stale recovery; CMN-022 is PID-reuse detection;
CMN-023 is unknown/suspected-stale GC blocking; CMN-024 verifies the frozen
fixture manifest. Rust and Go must execute the same IDs and expected outcomes.

## Platform additions

Windows/NTFS has nine cases: atomic temp-write/replace, concurrent reader,
open old-generation handles, hardlink/copy fallback, Unicode paths, long paths,
readonly failure, Defender-enabled plan, and process-creation-time identity.
Pending reboot must not be the normal path.

Each macOS/APFS architecture has seven cases: active replace, concurrent reader,
symlink/copy materialization, process-start identity, native architecture,
absence of architecture emulation confusion, and quarantine/signability
inspection. Intel success requires native x86_64; arm64 success requires native
arm64.

Linux/ext4 has four additions: `/proc` start identity, boot ID, native active
replace, and active-lease GC blocking.

Every result records commit, runner image, OS, architecture, filesystem,
language, case ID, classification, exit code, error code, JSONL validity,
journal status, and mixed-generation count.

## Selector publication durability

### Platform-neutral requirements

1. A generation is completely built and verified before activation.
2. The selector temporary file is completely written and flushed before
   publication.
3. Publication uses one platform-native same-volume replacement.
4. A partial or invalid selector is never accepted.
5. Open, write, flush, and replacement failures are fatal.
6. A processing run pins exactly one complete generation, and every stage of
   that run uses the same generation.
7. Rollback selects one complete previous generation.
8. Startup and recovery revalidate both the selector and its generation.

### POSIX durability

The selector file flush, same-filesystem rename or replacement, and parent
directory `fsync` are required. Every failure is fatal.

### Windows durability

The following primitives and validations are required, not optional:

| Property | Evidence classification | Requirement |
| --- | --- | --- |
| Selector file flush | `required_and_documented` | Flush the completely written selector temporary file through a write-capable handle with `FlushFileBuffers` before publication. |
| Native selector replacement | `required_and_native_validated` | Publish with one native same-volume replacement; any replacement failure is fatal. |
| Write-capable parent-directory flush | `required_and_native_validated` | Open the parent directory with `GENERIC_WRITE` and `FILE_FLAG_BACKUP_SEMANTICS`, call `FlushFileBuffers`, and treat open or flush failure as fatal. |
| Process-crash selector consistency | `required_and_native_validated` | Native tests must show a valid old selector before replacement and a valid new selector after replacement. |
| POSIX-equivalent parent-directory-entry OS-crash durability | `not_claimed` | Microsoft documentation does not establish equivalence for this directory-handle use. |
| Power-loss durability | `not_claimed` | Native process-crash probes do not establish power-loss behavior. |

Startup and recovery validation of the selector and generation remain required.
The required Windows operations may not be skipped, retried into success, or
have their failures suppressed. Successful native process-crash probes do not
establish OS-crash or power-loss safety. `MOVEFILE_WRITE_THROUGH` is not treated
as a general same-volume rename durability guarantee, and `ReplaceFileW` is not
treated as a durability guarantee.
