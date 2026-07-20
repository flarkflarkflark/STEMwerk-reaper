# Stale lease policy (POA-0)

Status: frozen experimental contract; no production implementation.

Each lease contains `schema_version`, `lease_id`, `run_id`, `pid`,
`process_start_identity`, `generation_id`, `host_id`, `created_at`,
`last_heartbeat`, `manager_version`, `executable_identity`, and `state`. Valid
states are `active`, `releasing`, `released`, `suspected_stale`, and
`confirmed_stale`.

PID alone is never identity: PIDs are reusable. A local lease is `ACTIVE` only
when host identity matches, the process exists, and its start identity matches.
It is `CONFIRMED_STALE` only when the process is absent, or its PID has a
different start identity, and an explicit recovery probe completed
successfully. Permission/API failures, host mismatch, unknown lease formats,
and otherwise unreliable probes yield `SUSPECTED_STALE`.

Suspected leases are never automatically collected. They produce diagnostics,
retain the generation, and include the lease plus probe result in a support
bundle. False-positive collection is worse than retaining an old generation.
TTL and heartbeat age are indicators only; they cannot establish staleness
without reliable identity evidence. Leases from another host are not
automatically removed in 2.4.

An active or uncertain lease blocks only generation GC, never activation of a
new generation. Stale recovery is an explicit, journaled manager operation.
Processing resolves one generation once, retains one lease for its entire run,
and both stages of a two-stage run use that generation.

## Native process identity

- Linux: PID plus `/proc/<pid>/stat` starttime; include boot ID when available.
- Windows: PID plus process creation time, executable path/identity, and machine
  identity using native process APIs.
- macOS: PID plus native process start time, executable identity, and host
  identity.

## Frozen policy cases

`LEASE-001` active lease; `LEASE-002` normal release; `LEASE-003` missing PID;
`LEASE-004` PID reuse; `LEASE-005` host mismatch; `LEASE-006` probe unknown;
`LEASE-007` old heartbeat with active matching process; `LEASE-008` two-stage
run; `LEASE-009` recovery after hard kill; `LEASE-010` GC with suspected lease.

Expected decisions are respectively: ACTIVE, RELEASED, CONFIRMED_STALE,
CONFIRMED_STALE, SUSPECTED_STALE, SUSPECTED_STALE, ACTIVE, ACTIVE,
CONFIRMED_STALE, and GC_BLOCKED. Confirmed stale leases may be transitioned and
removed only by the explicit recovery action after its successful identity
probe is durably journaled.
