# ADR-003: Revocation, rotation, offline trust and rollback

Status: ACCEPTED

## Context

Compromise recovery must work offline without making stale or rolled-back trust invisible.

## Decision

Keys have active, retiring, revoked, expired or unknown state. Rotation is old-valid-key
signed or delivered through an already trusted root channel, overlaps at least 30 days,
and is audited. Signed trust snapshots are monotonic, valid at most 30 days, and carry
keys, revocations, rotations and minimum catalog sequence. Expiry blocks official
install, repair, activation and rollback without grace; existing valid active use may
continue unless a critical deny applies. Catalog sequence/digest chains are monotonic
per channel; lower sequence, equal sequence/different digest and chain breaks fail closed.
Clock rollback is detected against persisted trusted time. Manual catalog rollback is
an explicit audited recovery action and does not mutate active state.

## Alternatives

Online-only revocation was rejected for offline failure. Indefinite snapshots were
rejected for compromise exposure. Immediate deletion on revocation was rejected because
it destroys recovery/forensic evidence. Silent catalog rollback was rejected.

## Consequences

Clients persist validated snapshot, trusted time, catalog sequence/digest and rotation chain.

## Security implications

New install/activation and rollback to revoked content are forbidden. Critical deny can
refuse already-active processing; it never auto-deletes bytes.

## Failure behavior

Unknown status, expired snapshot, broken chain, clock rollback or sequence rollback blocks
state-changing operations with explicit diagnostics.

## Migration impact

The first snapshot and catalog state must be bootstrapped by ADR-001 trust.

## Testing requirements

Test rotation, revocation states, offline expiry, clock rollback and catalog monotonicity.

## Evidence boundary

Availability under long offline periods and emergency operations require runbooks and later testing.

## Supersession policy

Only a signed newer snapshot plus accepted ADR may relax timing or revocation behavior.
