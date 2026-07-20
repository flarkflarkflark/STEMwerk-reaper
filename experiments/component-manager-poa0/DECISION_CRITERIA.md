# Decision criteria

Hard gates are contract correctness, fail-closed hashing, crash recovery,
generation-level activation, rebuildable SQLite state, JSONL-only stdout,
run-generation pinning, cancellation, and zero mixed component visibility.

Practical comparison covers build/test cycle, platform tooling, dependency
surface, maintenance and review ergonomics, diagnostics, and platform-specific
workarounds. Source-line count is informational only. No final language choice
is permitted before native Windows, macOS Intel, and macOS arm64 runs.
