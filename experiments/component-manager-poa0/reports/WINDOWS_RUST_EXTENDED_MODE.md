# Isolated extended Windows Rust mode

The previous bounded task stopped before dispatch because the workflow had no
isolated extended Windows Rust route: `normal` expanded all eight native jobs,
while `windows-rust-copy-hash` exposed only CMN-001/CMN-008 diagnostics.

The authoritative normal Windows Rust job is `Windows x86_64 rust native`.
Its ordered fixed pool is the existing CMN-001 through CMN-024 catalog order,
followed by existing LEASE-001 through LEASE-010 and WIN-001 through WIN-009
checks. Sources are the frozen expected-case catalog, shared matrix harness,
lease-policy harness, and Windows platform harness. No case, expectation,
fixture, fault injection, or ordering was added or changed.

Manual mode `windows-rust-extended` creates one `windows-latest` Rust job. It
reuses the normal Windows PowerShell runner for the complete fixed pool, exact
SQLite 3.53.3 provisioning and new-process PATH validation, the targeted frozen
verifier, and the existing CMN-008 recovery diagnostic. A fixed sentinel input
rejects free-form, partial, extra, or reordered case overrides.

The existing normal eight-job matrix and both copy/hash selections remain
unchanged. The one-use push classifier is bounded to parent
`002ddfc1514c429039efe9c763e290b4766b23ac` and the exact workflow, two
orchestration-helper, and report paths. Rust, Go, harness, contract, cases,
expectations, fixtures, schemas, recovery implementation, and frozen manifest
remain unchanged. A single targeted native dispatch is required.
