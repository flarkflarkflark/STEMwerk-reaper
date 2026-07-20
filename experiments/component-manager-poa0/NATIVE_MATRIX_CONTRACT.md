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
