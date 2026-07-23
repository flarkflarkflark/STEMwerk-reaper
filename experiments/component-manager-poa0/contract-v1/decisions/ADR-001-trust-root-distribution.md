# ADR-001: Trust-root distribution and enrollment

Status: ACCEPTED

## Context

Official, user-added, helper and development trust must not collapse into one authority.

## Decision

Use five scoped domains: official.catalog, official.artifact, official.helper,
user.catalog and development.local. Official public roots arrive only through an
already trusted installer/release channel; official TOFU and catalog self-authorization
are forbidden. User enrollment is explicit, fingerprint- and source-visible,
scope-minimal, confirmed, audited and disabled until verification. A key may have
multiple scopes only through separate explicit enrollments. Development state and
roots are isolated and never inherit official scope.

## Alternatives

A single global root was rejected for excessive blast radius. Official TOFU was
rejected because first contact is attacker-controlled. Cloud-only enrollment was
rejected because offline operation is required.

## Consequences

Public root records and enrollment audit records become contract data. Operational
distribution must preserve a pre-established fingerprint.

## Security implications

Scope separation limits escalation; unknown roots fail closed. Records contain no
private keys.

## Failure behavior

Missing, unknown, self-authorized or scope-mismatched roots block verification and
state-changing operations without deleting existing active content.

## Migration impact

Existing roots require explicit scope mapping and trusted redistribution.

## Testing requirements

Test scope isolation, official no-TOFU, explicit enrollment and auditable removal.

## Evidence boundary

This is a policy decision, not proof of cryptographic implementation or distribution.

## Supersession policy

Only a later accepted ADR may change domains or enrollment; it must retain an audited
migration and no weaker bootstrap.
