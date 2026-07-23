# Contract v1 decisions

| Decision | Status | Normative resolution |
|---|---|---|
| ID-001 | RESOLVED_IN_CONTRACT_V1 | Lowercase ASCII segmented identifiers; case-sensitive after validation |
| VER-001 | RESOLVED_IN_CONTRACT_V1 | SemVer plus package revision for software; opaque revision plus digest for models |
| COMPAT-001 | RESOLVED_IN_CONTRACT_V1 | Declarative rules yield compatible/incompatible/unknown; unknown fails closed |
| LEASE-001 | RESOLVED_IN_CONTRACT_V1 | PID plus process-start identity; suspected identity blocks collection |
| GC-001 | RESOLVED_IN_CONTRACT_V1 | Conservative eligibility and reference accounting; unknown means keep |
| MIG-001 | RESOLVED_IN_CONTRACT_V1 | No in-place immutable migration; auditable derived records only |
| HELP-001 | RESOLVED_IN_CONTRACT_V1 | Core decides; least-privilege helper executes bounded validated requests |
| TRUST-001 | BLOCKING_BEFORE_IMPLEMENTATION | Trusted-root distribution is TO_BE_DEFINED |
| SIGN-001 | BLOCKING_BEFORE_IMPLEMENTATION | Signing algorithms and signature requirements are TO_BE_DEFINED |
| REVOKE-001 | BLOCKING_BEFORE_IMPLEMENTATION | Revocation, rotation, freshness, and offline policy are TO_BE_DEFINED |
| GC-002 | BLOCKING_BEFORE_IMPLEMENTATION | Retention count and age are TO_BE_DEFINED |
| MIG-002 | BLOCKING_BEFORE_IMPLEMENTATION | Supported schema/downgrade windows are TO_BE_DEFINED |
| PKG-001 | OUT_OF_SCOPE_V1 | OS package-manager integration |
| UX-001 | OUT_OF_SCOPE_V1 | Production UI and REAPER implementation |

No dual core, per-component active pointer, mixed generation, silent fallback, or
filename-derived model trust is approved.
