# Contract v1 decisions

| Decision | Status | Normative resolution |
|---|---|---|
| ID-001 | RESOLVED_IN_CONTRACT_V1 | Lowercase ASCII segmented identifiers; case-sensitive after validation |
| VER-001 | RESOLVED_IN_CONTRACT_V1 | SemVer plus package revision for software; opaque revision plus digest for models |
| COMPAT-001 | RESOLVED_IN_CONTRACT_V1 | Declarative rules yield compatible/incompatible/unknown; unknown fails closed |
| LEASE-001 | RESOLVED_IN_CONTRACT_V1 | PID plus process-start identity; suspected identity blocks collection |
| GC-001 | RESOLVED_IN_CONTRACT_V1 | Conservative eligibility and exact reference accounting; unknown means keep |
| MIG-001 | RESOLVED_IN_CONTRACT_V1 | No in-place immutable migration; auditable derived records only |
| HELP-001 | RESOLVED_IN_CONTRACT_V1 | Core decides; least-privilege helper executes bounded validated requests |
| TRUST-001 | RESOLVED_IN_CONTRACT_V1 | Five scoped domains; trusted distribution for official roots; explicit user enrollment |
| SIGN-001 | RESOLVED_IN_CONTRACT_V1 | Envelope v1; Ed25519 primary; ECDSA-P256-SHA256 transition; RFC 8785 JCS |
| REVOKE-001 | RESOLVED_IN_CONTRACT_V1 | Signed monotone snapshots, 30-day offline age, rotation and critical-deny semantics |
| GC-002 | RESOLVED_IN_CONTRACT_V1 | Two rollback generations; three inactive; 30-day conjunction; dry-run and audit |
| MIG-002 | RESOLVED_IN_CONTRACT_V1 | Major 1; read/write 1.0.0 baseline; strict minor gate; downgrade precheck |
| PKG-001 | OUT_OF_SCOPE_V1 | OS package-manager integration |
| UX-001 | OUT_OF_SCOPE_V1 | Production UI and REAPER implementation |

ADR-001 through ADR-005 are ACCEPTED. Implementation blocker count is zero.
No dual core, per-component active pointer, mixed generation, silent fallback,
filename-derived model trust, private-key material, or direct production authorization
is approved.
