# Contract v1 open policies

## Implementation blockers

None. The five prior implementation-policy blockers are resolved by ADR-001 through
ADR-005 and normative Contract v1 sections 9, 27, 28, 37, 38, 39 and 43.

## Deferred non-blocking

- Presentation wording and localization of viewmodel messages.
- Optional heartbeat transport; correctness does not depend on heartbeat age.
- Diagnostic retention and aggregation beyond the stable event shape.
- Operational key ceremonies, incident runbooks and concrete trusted public keys.
- Exact library selection for JCS and signature verification.

These items MUST NOT weaken the accepted policy. They do not authorize production
implementation; a separate Production Readiness Gate remains REQUIRED.

## Out of scope

Production packaging, package-manager integration, remote fleet management, complete
UI design, release mechanics, cryptographic infrastructure, private-key management,
signing services, and production certificate issuance.
