# Schema bindings and cryptographic boundaries

## Binding decision

JSON Schema remains the normative wire/storage source. Use a hybrid binding: hand-written strong scalars, enums and security policy; reproducibly generated mechanical record structs; runtime validation before decoding at every external/storage boundary. Generated files carry schema digest, generator identity/version and a generated warning, are committed, and may never broaden constraints.

SCHEMA_BINDING_STRATEGY=hybrid

SCHEMA_GENERATOR=TO_BE_SELECTED

GENERATOR_PINNING_POLICY=SLICE-0 compares bounded candidates offline, records exact module/tool version and checksum, vendors or uses go:generate with a repository-pinned executable, and CI regenerates without network access

GENERATED_CODE_COMMITTED=yes

RUNTIME_SCHEMA_VALIDATION_REQUIRED=yes

CANONICAL_JSON_IMPLEMENTATION_PLAN=SLICE-0 proves RFC 8785 JCS against official/contract vectors, then pins a reviewed library or a narrowly audited serialization dependency; standard encoding/json is not accepted as canonicalization

UNKNOWN_FIELD_POLICY=reject unknown fields for signed, persisted and command records; permit only schema-declared extension maps; newer minor is accepted only after advertised capability negotiation; unknown major always fails closed

CUSTOM_SCALAR_TYPES=ComponentID, GenerationID, ReceiptID, ArtifactID, CatalogID, OperationID, LeaseID, RunPinID, KeyID, DigestSHA256, SemVer, PackageRevision, ModelRevision, SchemaVersion, CatalogSequence, UTCInstant, RelativePath

SCHEMA_BINDING_STATUS=RESOLVED

The generator choice and canonicalizer proof are bounded SLICE-0 deliverables, not open architecture decisions. Generation must be byte-reproducible, offline and drift-checked. Enum decoding retains no unknown security value: security and behavior enums fail closed; presentation-only enums may retain an explicit Unknown value if the schema allows it. Version negotiation reads major first and decodes only a supported minor window. Content-derived identifiers hash the exact RFC 8785 canonical UTF-8 bytes with SHA-256.

## Crypto plan

The signature package verifies bytes and returns cryptographic validity; trust/revocation packages independently evaluate scope, time, chain, sequence and policy. No policy is inferred from a successful signature.

CRYPTO_STANDARD_LIBRARY_SUFFICIENCY=crypto/ed25519, crypto/ecdsa with P-256, crypto/sha256, crypto/rand and subtle comparisons cover required cryptographic primitives; RFC 8785 canonicalization and JSON Schema validation are not supplied by the standard library

REQUIRED_EXTERNAL_CRYPTO_DEPENDENCIES=none

CANONICALIZATION_DEPENDENCY=spike_required

TRUST_STORE_INTERFACE=trust.RootStore.Get/List plus explicit scoped enrollment metadata; official public material has durable file authority and development roots are isolated

SIGNATURE_VERIFICATION_INTERFACE=signature.Verifier.Verify(Envelope,CanonicalPayload) error with an algorithm allowlist and no policy/network dependency

REVOCATION_POLICY_INTERFACE=revocation.Provider.Current(Scope) and Evaluator.Evaluate(KeyID,At), backed by durable monotone snapshot/sequence evidence

PRIVATE_KEY_HANDLING_IN_CORE=forbidden

CRYPTO_PLAN_STATUS=RESOLVED

Test vectors contain only public keys and deterministic messages. Clock is injected. Private keys, signing and official root distribution remain external. Platform codesigning is an adapter/helper identity prerequisite, not a substitute for Contract-v1 content signatures.
