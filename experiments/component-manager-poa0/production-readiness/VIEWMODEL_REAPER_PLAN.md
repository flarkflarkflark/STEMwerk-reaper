# Viewmodel and consumer plan

The consumer boundary is a versioned, immutable snapshot plus change token. A future subscription may only signal that a newer snapshot exists. It does not stream mutable database rows.

VIEWMODEL_DELIVERY_MODEL=versioned read-only snapshot with monotone revision/change token and optional invalidation subscription

VIEWMODEL_VERSIONING=schema major 1 with advertised minor capability; unknown major fails closed and stale/unavailable are explicit top-level states

REAPER_COMMAND_TRANSPORT=TO_BE_SELECTED

GENERATION_PIN_HANDOFF=consumer requests AcquireRunPin for one GenerationID and receives an opaque PinToken bound to process-start identity, expiry/heartbeat policy and exact generation; processing cannot start or mix components without it

STALE_VIEWMODEL_POLICY=compare snapshot revision/generated-at/manager-instance and change token; stale snapshots disable state-changing actions and processing start, while manager unavailable is displayed explicitly

LOCALIZATION_BOUNDARY=stable IDs, enums, parameters and action capabilities cross the boundary; user-facing localized text is rendered outside machine identity and never parsed as a command

REAPER_INTEGRATION_PLAN_STATUS=RESOLVED

Snapshot fields include schema/capabilities, manager status, operations/progress, flow readiness for seven flows, blocked reason IDs, stable action IDs, active GenerationID, pin capability, diagnostic references and staleness metadata. The consumer reads only this viewmodel and invokes explicit manager commands. It never opens SQLite, writes selectors or assembles component pointers. Transport selection occurs before SLICE-8 and must preserve request/response types, authentication, cancellation and unavailable semantics. No consumer code is changed here.

## Diagnostics and observability

DIAGNOSTIC_EVENT_MODEL=validated JSONL/schema events with EventID, correlation/operation IDs, phase, severity, stable code, component/generation references, platform detail, causal chain, retryable/recoverable flags and a redacted human message

OPERATION_JOURNAL_MODEL=durable append-only state-machine facts for mutation/recovery, separate from diagnostic events; begin, phase boundaries, external effects, first failure and terminal state

CORRELATION_ID_MODEL=one opaque random correlation ID per external request propagated to commands, helper calls, journal and diagnostics; child span IDs may be derived but are not identities

REDACTION_POLICY=never record secrets/private material/nonces/auth tokens; replace user path prefixes and account names with stable redacted labels; allow public artifact digests and stable contract IDs

SUPPORT_BUNDLE_PLAN=deterministic manifest plus selected redacted events, capability/schema versions and integrity results; sorted entries, content digests, size/time bounds and explicit omissions; no raw managed payloads by default

FIRST_FAILURE_PRESERVATION=yes

OBSERVABILITY_PLAN_STATUS=RESOLVED

Diagnostic sink failure is surfaced without replacing the original error. No silent fallback is allowed. The viewmodel links DiagnosticReference values and never embeds full logs.
