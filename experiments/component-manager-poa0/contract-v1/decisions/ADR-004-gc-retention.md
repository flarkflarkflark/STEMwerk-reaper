# ADR-004: Garbage-collection retention

Status: ACCEPTED

## Context

GC must reclaim bounded inactive data without losing active, rollback, shared or uncertain content.

## Decision

Retain at least two proven rollback generations and the three newest otherwise eligible
inactive generations. Normal automatic deletion requires both count excess and at least
30 days inactive. Failed incomplete installs may be considered after 7 days. Revoked
generations remain 90 days after a validated replacement; critical-deny material is
preserved for audit. Active, pinned, leased, suspected, user-retained, unknown-owned,
referenced or operational content is never auto-deleted. Shared content needs exact zero
references. Dry-run, candidate disclosure, durable journal and tombstone evidence are
mandatory; deletion audit records remain 365 days.

## Alternatives

Age-only and count-only policies were rejected. Disk-pressure bypass and best-effort
reference counting were rejected. Permanent retention of everything was rejected as
operationally unbounded.

## Consequences

Storage planning must accommodate protected and audit retention. User pins override defaults.

## Security implications

Conservative keep-on-unknown prevents GC-induced data loss and attacker-triggered cleanup.

## Failure behavior

Any uncertain eligibility returns gc_not_safe and preserves data.

## Migration impact

Existing items begin with unknown eligibility and remain until indexed and audited.

## Testing requirements

Test count/age conjunction, leases, ownership, shared references, dry-run and ancestors.

## Evidence boundary

Chosen values are conservative policy, not measured capacity guarantees.

## Supersession policy

Changes require accepted ADR, migration analysis and no weakening of protected classes.
