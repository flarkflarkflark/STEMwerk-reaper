# POA-0 frozen verifier domain separation v2

This is a disposable POA-0-only verification-policy change. It does not alter
production code, choose an implementation language, or advance Contract v1.

## Evidence and previous fail-closed stop

Targeted Windows Rust run
[29781582351](https://github.com/flarkflarkflark/STEMwerk-reaper/actions/runs/29781582351)
correctly stopped before build at `verify-frozen-fixtures.ps1:21` with
`Rust tree drift`. The prior follow-up then correctly stopped before mutation
because its Rust-only allowlist could not classify the already authorized
workflow and fix-report paths.

The v2 policy classifies the complete feature diff from baseline
`9bf06029f2c1b24db0fd4e680f8d8e2e289dcd6b` to target
`ec14fdf523524bbd9aec34d429f0b6a5b673a701` exactly once:

- `IMPLEMENTATION_SOURCE_RUST`: `rust/Cargo.toml`, `rust/Cargo.lock`, and
  `rust/src/main.rs` beneath the POA root;
- `TEST_ORCHESTRATION`: `.github/workflows/component-manager-poa0-native.yml`;
- `DOCUMENTATION`: `WINDOWS_RUST_IN_PROCESS_SHA256_FIX.md`.

There are no unauthorized feature paths. Review of the feature workflow diff
shows only the exact push-skip guard for the bounded fix flow. It does not
change normal matrix content, expectations, provisioning, or PASS/FAIL rules.

## Domain policy

Strict mode remains the default and continues to require the frozen Rust and
Go source hashes plus the existing frozen fixtures, schemas, expected results,
harness and authoritative manifest SHA. The explicit
`rust-implementation-fix` mode keeps every immutable check and accepts only the
three exact feature-diff allowlists above. Unknown, sibling, other workflow,
other report, Go, fixture, expected, schema, fault/harness, and doubly
classified paths fail closed.

The workflow head is later than the feature target, so the policy separately
checks `target..workflow-head`. That range may contain only the exact verifier,
routing, verifier-test, workflow-input and this report paths authorized by this
task. It cannot contain Rust, Go, frozen assets, harness core, other workflows,
other documentation, or product paths.

Both Bash and PowerShell frozen verifiers call the same Python policy engine.
The workflow passes the explicit mode, baseline, target and checked-out head
only to the bounded Windows Rust diagnostic. Normal jobs retain strict mode.

## Regression evidence

Twenty verifier-level guards cover strict no-drift and strict drift rejection;
the three authorized feature classes; rejection of fixture, expected, schema,
fault, Go, other workflow, other documentation, harness core and unknown Rust
paths; double classification; invalid mode; authoritative manifest mismatch;
and a forbidden post-target path. The frozen manifest was not regenerated or
modified. Its authoritative SHA-256 remains
`2e924b3b74bbd2b654d6caa7982062c738c37bf6d207fa0fc8787452f4b5b783`.
