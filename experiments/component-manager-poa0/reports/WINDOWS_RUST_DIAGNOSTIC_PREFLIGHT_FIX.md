# Windows Rust Diagnostic Preflight Fix

## Failure basis

Targeted run `29774469675` selected only Windows x86_64 Rust with CMN-001 and CMN-008, but stopped at the shared runner preflight with `UNSUPPORTED_ENVIRONMENT: sqlite3 absent`. Neither diagnostic case nor its evidence capture started.

## Callgraph evidence

CMN-001 invokes a clean Rust `install`. CMN-008 first invokes the same install as its prerequisite. In Rust `install`, fixture copy and the external PowerShell SHA check occur before the first `artifact_verified`; SQLite schema/projection work is reached only after generation construction and activation. Therefore neither selected case uses SQLite before the instrumented interval.

## Capability-based split

The narrowly selected `windows-rust-copy-hash` route requires Git Bash, Windows PowerShell, Rust and Cargo, but does not require SQLite before running the diagnostic. The normal Windows matrix still fails preflight when either SQLite or Git Bash is absent. Invalid cases and use of diagnostic cases outside the one recognized mode fail closed.

The existing copy/hash instrumentation and artifact capture are unchanged. Test IDs, semantics, expectations, fixtures, schemas, frozen manifest, fault injections, Rust core and Go source are unchanged. This is diagnostic infrastructure only, not a functional copy/hash fix or language decision.
