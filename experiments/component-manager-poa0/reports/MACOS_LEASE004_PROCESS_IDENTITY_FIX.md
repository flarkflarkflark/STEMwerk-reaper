# macOS LEASE-004 process-start identity fix

Native matrix run `29768720356` failed LEASE-004 in all four macOS jobs after
the common matrix passed. The shared Unix lease adapter obtained macOS process
start time from locale-dependent `ps -o lstart` output. LEASE-004 preserves its
PID and deliberately changes the stored identity by one, but shell arithmetic
received a value beginning with a weekday/month token and stopped with
`Jul: unbound variable`. The case, expectation, lease schema, serialization,
classification, and GC policy were not at fault and remain unchanged.

The macOS adapters now use Rust FFI and build-tagged Go cgo respectively to
call `proc_pidinfo` with `PROC_PIDTBSDINFO`. Both read `pbi_start_tvsec` and
`pbi_start_tvusec` and emit one checked unsigned integer: microseconds since the
Unix epoch. This is a native, locale-independent, microsecond-resolution kernel
value. No process name, PID-only fallback, shell-output parser, rounding,
retry, error suppression, or external dependency was added. Missing,
API-invalid, or overflow results are errors, which the unchanged classifier
treats as unknown rather than confirmed stale.

The existing lease harness uses this adapter only on Darwin; its Linux `/proc`
route is byte-for-byte unchanged. LEASE-004 still compares the same PID with a
stored identity differing by exactly one microsecond, so reliable mismatch
remains confirmed stale PID reuse. Identity match remains active, missing
process remains confirmed stale, and host/API uncertainty remains suspected
and GC-blocking. Confirmed-stale GC is exercised without changing policy.

Local Rust formatting, build, 26/26 unit tests, the existing 40/40 common
matrix, both 10/10 Linux lease runs, both 4/4 Linux platform runs, verifier
policy 20/20, and 20/20 process-identity/GC checks pass. A macOS Rust target is
not installed locally, so native compilation and API execution remain assigned
to the isolated runner. Equality guards pass for Windows Rust and Go durability,
contracts, frozen case lines/expectations/fixtures/schemas/faults, generation,
selector, recovery, run-pinning, the normal matrix, and verifier policy.

Manual mode `macos-lease004` creates one macOS arm64 Rust job with fixed
LEASE-001 through LEASE-010, native process metadata, per-case summaries,
identity comparison, GC, stderr, and timeline evidence. A successful native
rerun is required before closure. No durability or product behavior changes.
