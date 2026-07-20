# POA-0 native matrix results

This checked-in file defines the result location and pre-dispatch state.
Workflow jobs overwrite it only inside their ephemeral checkout and upload the
job-specific report with the exact `GITHUB_SHA`, run ID, runner image, native
architecture, Rust/Go 24-case result, platform result, lease result, and mixed
visibility count.

Transport branch: `experiment/component-manager-poa0`.
Frozen manifest: `FROZEN_FIXTURE_MANIFEST.json` with its adjacent SHA256 file.
Pre-dispatch classifications: Linux, Windows, macOS Intel, and macOS arm64 are
`NOT_RUN`. Go's earlier cross-builds remain `CROSS_BUILD_ONLY`; Rust cross
targets were unavailable. Neither is native evidence.

The definitive language decision remains `pending_native_ci`. Remaining
Contract v1 blockers are complete native results, review of platform failures,
production dependency selection, and explicit schema/transaction review.
