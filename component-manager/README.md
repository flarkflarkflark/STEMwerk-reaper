# STEMwerk Component Manager — SLICE-0

This standalone Go module is the production skeleton and Contract-v1 binding slice. It provides strong domain values, embedded schemas, offline read-only validation, RFC 8785 canonicalization, pure generation identity helpers, and read-only catalog parsing.

It is not a complete Component Manager. It performs no SQLite or other state mutation, activation, installation, receipt writing, network access, signature/trust-state verification, helper work, REAPER integration, runtime use, or model handling. A next slice is not automatically authorized.

The owner-approved and implementation-authorized, not-yet-started SLICE-1
boundary is documented in `docs/SLICE_1_SCOPE.md`.

Run `go test ./...` from this directory. `schemas/drift_test.go` compares all 21 embedded resources byte-for-byte and by `schemas/SHA256SUMS` against `experiments/component-manager-poa0/contract-v1/schemas`.
