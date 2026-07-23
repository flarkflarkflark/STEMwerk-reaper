# ADR-002: Signature algorithm policy

Status: ACCEPTED

## Context

Official metadata needs portable authenticated origin without algorithm confusion.

## Decision

Use versioned envelope 1, RFC 8785 JCS, SHA-256 content digests and Ed25519 as primary.
ECDSA-P256-SHA256 is the sole transition algorithm with strict DER, low-S and named
curve validation. Official catalogs, artifact metadata, trust snapshots, rotation and
revocation statements are signed. Payload bytes bind to signed digests. Platform
helpers/installers require native code signing plus manager metadata. Local receipts
and generation manifests may remain unsigned because they are content-addressed and
receipt-bound. Unsigned development content is permitted only in isolated visible
development.local mode.

## Alternatives

RSA was rejected for larger keys/signatures and unnecessary legacy surface.
Algorithm-from-key inference and unrestricted algorithm lists were rejected for
confusion/downgrade risk. Signing every local record remotely was rejected because it
would create a hidden online dependency.

## Consequences

Implementations need JCS and two well-supported verification algorithms across Go,
Windows, macOS and Linux.

## Security implications

Unknown profile/algorithm, invalid signatures and unsigned official objects fail closed.

## Failure behavior

Verification failure blocks download trust, install and activation; existing active
state is not silently replaced.

## Migration impact

Transition uses dual policy acceptance, not ambiguous multi-signature success.

## Testing requirements

Test envelope shape, allowlist, canonical binding, invalid signatures and unsigned official objects.

## Evidence boundary

No keys, signatures, verification code or production certificates are created here.

## Supersession policy

A later accepted ADR and versioned policy profile are required to add or retire algorithms.
