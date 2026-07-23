# SLICE-0 scope

Included: a standalone module, minimal pure package boundaries, strong Contract-v1 values, typed errors, byte-exact schema resources, bounded offline validation, RFC 8785/JCS, pure content-ID derivation, and immutable read-only catalog projection.

Excluded: SQLite/databases, filesystem state, downloads/network, caches, installation, generation workflows, selectors, activation/rollback/recovery, receipts, leases/pins/GC, trust mutation or live signature verification, helpers/transports, installers, REAPER/UI/runtime/models, and SLICE-1.

Package responsibilities are `pkg/identity` (IDs), `pkg/digest`, `pkg/version`, `pkg/schemaversion`, `pkg/platform`, `pkg/component`, `pkg/contract` (errors and schema boundary), `pkg/catalog` (read-only projection), `schemas` (embedded resources), `internal/schemavalidation` (offline compiler), and `internal/canonicaljson` (JCS wrapper). No repository, service, or manager abstraction exists.
