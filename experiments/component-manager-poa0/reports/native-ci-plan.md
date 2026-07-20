# Native CI plan

Native runners are the sole source of truth. The local Go PE/Mach-O outputs
prove compilation only; they do not prove smoke behavior, filesystem
atomicity, signing, notarization, Defender, or Gatekeeper behavior.

The proposed, inactive matrix is in `ci/native-matrix.yaml`. No workflow was
originally added. The transport workflow now uses explicit hosted labels
documented by GitHub: `macos-15-intel` for x64 and `macos-15` for arm64; see
<https://docs.github.com/en/actions/reference/runners/github-hosted-runners>
and <https://github.com/actions/runner-images>. Each runner checks out only this experiment, configures caches inside
its job workspace, runs `scripts/build.sh`, and executes the same 20-case
harness for Rust and Go. Artifacts are named
`cm-poa0-<language>-<os>-<arch>` and are disposable unsigned test outputs.

Required native selections:

- Linux x86_64: full matrix on ext4, including same-volume active rename.
- Windows x86_64: MSVC Rust and native Go builds; full matrix on NTFS; repeat
  cancellation, activation, recovery, rebuild, and JSONL tests with Defender
  enabled. Confirm the Windows crashhook produces a genuinely abrupt boundary.
- macOS Intel and arm64: native build and full matrix on APFS, separately;
  inspect dynamic dependencies and whether the output shape is signable.

Every runner must assert that `state/active.tmp` and `state/active` share a
volume, parse every stdout line as JSON, observe zero mixed generation views,
and preserve an active generation on pre-swap failures. Signing/notarization
are out of POA-0, but `file`, dependency inspection, and standard executable
layout are retained as inputs to later signing work.

Cross-build status from Linux:

- Rust Windows/macOS: NOT_AVAILABLE (targets/toolchains not installed).
- Go Windows amd64: PASS compilation only.
- Go macOS amd64 and arm64: PASS compilation only.
