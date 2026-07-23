# ADR-005: Schema support and downgrade

Status: ACCEPTED

## Context

Strict immutable records require a deterministic support window and safe downgrade gate.

## Decision

Contract v1 schema families use major 1, minimum readable 1.0.0 and current writable
1.0.0. Readers accept supported 1.x versions no newer than their advertised minor;
strict unknown fields or feature gates fail closed unless an explicit compatible adapter
exists. Writers emit exactly their current version. Unknown majors fail closed.
Immutable evidence is never rewritten in place. Migration derives a new audited record.
Downgrade requires proof that active objects and two rollback generations fit the target
read window; lossy downgrade is forbidden. Helper/core handshake exchanges contract,
per-family read/write ranges and feature gates and requires an intersection.

## Alternatives

Read-any-1.x was rejected because schemas are strict. In-place migration and best-effort
lossy downgrade were rejected. Supporting only current objects without rollback checking
was rejected.

## Consequences

Version capabilities become explicit contract data. Newer minor adoption requires feature gates or adapters.

## Security implications

Unknown structure cannot be smuggled through permissive reads; downgrade cannot erase policy data.

## Failure behavior

Unsupported major/minor, handshake mismatch or failed downgrade precheck blocks the operation.

## Migration impact

Migrations preserve source/result digests, tool identity, time and journal evidence.

## Testing requirements

Test major rejection, newer-minor behavior, writer version, migration immutability,
downgrade preflight and helper/core handshake.

## Evidence boundary

This policy does not implement adapters or prove future-version compatibility.

## Supersession policy

A later accepted ADR defines any wider window or major migration.
