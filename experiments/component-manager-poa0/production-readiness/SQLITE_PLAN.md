# Rebuildable SQLite plan

SQLite is a disposable query/coordination index. Durable immutable files, selectors and trust material can reconstruct it. It must never be the only source of immutable receipt content, generation manifests, active selector, artifact digests or durable trust-root public material.

## Logical records

1. schema_metadata
2. desired_state
3. operations
4. operation_events
5. ownership
6. receipt_index
7. generation_index
8. catalog_cache
9. trust_enrollment_metadata
10. revocation_cache
11. retained_generations
12. user_pins
13. gc_decisions
14. migration_history

SQLITE_TABLE_OR_RECORD_COUNT=14

SQLITE_AUTHORITATIVE_DATA=operation idempotency/coordination facts and desired-state intent only when paired with durable journal; never immutable content, selector or root public material

SQLITE_REBUILDABLE_DATA=receipt/generation/artifact indexes, ownership graph derived from receipts/generations, catalog cache, revocation cache, retained-generation projection, pins reconciled with durable records, diagnostics search projection

SQLITE_TRANSACTION_MODEL=one application-service unit of work per command: begin immediate, validate expected version/idempotency, write index and operation events, commit; filesystem publication is coordinated by durable write-ahead TransactionJournal and recovered before new mutation

SQLITE_JOURNAL_MODE=TO_BE_VALIDATED

SQLITE_SINGLE_WRITER_POLICY=one manager application writer per storage scope; readers use bounded read transactions; helper and consumer never open the database

SQLITE_CORRUPTION_RECOVERY=detect integrity/open/version failure, preserve the corrupt file for diagnostics, create a fresh database beside it, scan and validate durable authorities, atomically replace only after complete rebuild; ambiguity fails closed

SQLITE_MIGRATION_STRATEGY=forward-only numbered transactional migrations with schema major/minor metadata, backup before irreversible index migration, downgrade capability precheck and full rebuild fallback; immutable formats are never migrated in place

SQLITE_PLAN_STATUS=RESOLVED

SLICE-2 chooses the driver after native/CGO evaluation. WAL is preferred only if locking, crash and network/removable-filesystem behavior pass tests; otherwise rollback journal is selected per adapter configuration. Busy handling uses bounded jitter-free testable backoff and typed busy errors, never infinite waits. Backup is an online-consistent index copy plus durable authorities, and restoration always verifies/rebuilds. Crash recovery replays or rolls back the external transaction journal before serving mutation.
