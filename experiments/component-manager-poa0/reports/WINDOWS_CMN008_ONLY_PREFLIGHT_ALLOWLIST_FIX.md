# Windows CMN-008-only preflight allowlist correction

## Scope

Authoritative workflow run `29827271232` failed at
`assert-windows-native-preflight.ps1:17` with
`Unsupported diagnostic case selection`. The preflight accepted only the exact
combined selection `CMN-001,CMN-008`, while the workflow correctly dispatched
the exact selection `CMN-008`.

This orchestration-only correction adds exact `CMN-008` to that allowlist and
preserves exact `CMN-001,CMN-008`. Empty, unknown, duplicate, reordered,
case-varied, whitespace-varied, and trailing-comma selections remain rejected.
No wildcard, substring, normalization, deduplication, sorting, or fallback was
introduced.

## Equality and regression evidence

The recovery execution and wrapper, recover command, artifact capture, Rust and
Go sources, durability contract, CMN-008 case and expectation, fixtures,
schemas, fault injections, and SQLite query semantics are unchanged. Local
selection-contract checks cover the two accepted exact strings and all required
negative variants. Existing Rust, Go, lease, Linux, mixed-visibility, and
verifier-policy regressions must pass before this change is committed.

## Push suppression and native rerun

The one-use push classifier is bounded to parent
`79512d128f6383a405935e0f0b4a1a4a88d2f0a2` and the exact paths for this
preflight correction, workflow classifier update, and report. It applies only
to the push event; manual dispatch and normal future push semantics remain
active.

A targeted native rerun is required for Windows, Rust, and exact `CMN-008` to
exercise the already committed injected-kill, recover, and post-recovery
validation path.
