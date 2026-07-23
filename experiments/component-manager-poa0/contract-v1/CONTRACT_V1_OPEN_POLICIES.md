# Contract v1 open policies

## Blocking before implementation

1. Trusted-root distribution and enrollment.
2. Approved signing algorithms and which objects require signatures.
3. Revocation distribution, freshness, compromised-content response, key rotation,
   offline verification, expired-signature handling, and catalog rollback protection.
4. Garbage-collection retention count and retention age.
5. Supported schema-version windows and downgrade matrix.

These values are `TO_BE_DEFINED`. They are not guessed by this contract. A separate
policy/security architecture decision MUST resolve or explicitly accept each blocker
before production implementation starts.

## Deferred non-blocking

- Presentation wording and localization of viewmodel messages.
- Optional heartbeat transport; correctness does not depend on heartbeat age.
- Diagnostic retention and aggregation beyond stable event shape.

## Out of scope

Production packaging, package-manager integration, remote fleet management, complete
UI design, release mechanics, and cryptographic infrastructure implementation.
