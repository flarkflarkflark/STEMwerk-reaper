# STEMwerk Component Manager Contract v1

Status: **APPROVED** with all five implementation-policy blockers closed. This is a normative design,
not production code. Authority is the corrected POA-0 evidence freeze at
`be0a34a628064aebb8936120d8b23f3846589a0d`, evidence run `29976687812`, and
evidence-index SHA-256 `18aa77c30eab9fd3874730c55da3e6b16883971443a20f3917b7181186c34b23`.

## 1. Status and scope

This contract specifies interoperable Component Manager records, boundaries,
transactions, and conformance. A conforming implementation MUST use one shared
Go core for contract decisions. Platform helpers MAY execute bounded privileged
filesystem operations but MUST NOT decide compatibility or trust.

## 2. Goals

The manager SHALL install components independently, construct immutable compatible
generations, activate exactly one generation atomically, pin each processing run,
recover conservatively, and expose a manager-owned consumer viewmodel.

## 3. Non-goals

This version does not implement a runtime, CLI, daemon, helper, installer, UI, or
REAPER integration. It MUST NOT claim OS-crash or power-loss durability, choose
production signing infrastructure, or infer model trust from a filename.

## 4. Normative language

MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, and MAY have their
RFC 2119 meanings. Schema validity is necessary but not sufficient: semantic
rules in this document remain normative.

## 5. Terminology

A component is a logical installable unit; an artifact is immutable bytes; a
receipt is immutable installation evidence; a generation is an immutable compatible
component set; the selector names one active generation; a lease proves a live
consumer identity; a run pin binds one processing run to one generation.

## 6. Identity model

`component_id`, `model_id`, and other logical IDs MUST be lowercase ASCII, MUST
match `[a-z0-9]+(?:[._-][a-z0-9]+)*`, and are case-sensitive after validation.
Display names, filenames, and paths MUST NOT serve as identities. Generic IDs
SHALL NOT contain a platform unless the component is inherently platform-specific.
Absolute local paths MUST NOT occur in an ID.

`artifact_id` is `artifact.sha256.<hex>`. `generation_id` is
`generation.sha256.<hex>` derived from canonical UTF-8 JSON of the generation
manifest with `generation_id` omitted. `receipt_id` is `receipt.sha256.<hex>`
derived equivalently from immutable receipt fields. SHA-256 is REQUIRED.

## 7. Version model

Runtime, config, catalog, helper, integration, and metadata components MUST use
SemVer 2.0.0 without an epoch. Ordering follows SemVer precedence; prereleases
sort below their associated release; build metadata is identity metadata but
does not affect precedence. `package_revision` is a non-negative integer tie-break
after SemVer precedence. Downgrades MAY occur only through explicit desired state
or rollback and MUST be journaled. Model revisions use an opaque, case-sensitive
publisher revision plus digest and MUST NOT be treated as SemVer. The same
component/version/revision with a different digest MUST be rejected as
`artifact_digest_mismatch`, never silently substituted.

## 8. Artifact model

An artifact MUST declare stable identity, SHA-256 digest, byte size, provenance,
and optional expected filename. Bytes MUST be verified before materialization and
again before activation when integrity is unknown.

## 9. Provenance and trust

Provenance MUST include source type, stable locator, publisher/owner, retrieved
digest, license evidence when available, trust decision, and revocation state.
Five isolated trust scopes are REQUIRED: `official.catalog`, `official.artifact`,
`official.helper`, `user.catalog`, and `development.local`. Official roots MUST arrive
through an already trusted installer/release channel with an authenticated algorithm,
fingerprint, and scope; official TOFU is forbidden. A catalog MUST NOT authorize its
own root. User roots require explicit informed confirmation, displayed fingerprint,
source and least scope, a durable audit record, and remain disabled until verified.
One public key MAY hold multiple scopes only when every scope is explicitly enrolled
and audited. User/development scope MUST NOT imply official scope. Root removal and
revocation MUST be audited; root records MUST NOT contain private key material.
Unknown, untrusted, or revoked provenance MUST fail closed for activation.

## 10. Component model

The seven kinds are `runtime`, `model`, `config`, `catalog`, `helper`,
`integration`, and `metadata`. Every component MUST declare identity, version,
artifact, size, provenance, compatibility, dependencies, conflicts, required
status, receipt, payload layout, validation, ownership, and lifecycle state.
Dependency closure MUST be present; conflicts MUST reject generation construction.

## 11. Runtime components

Every operational generation MUST contain exactly one `runtime.main` capability.
`runtime.drumsep` is OPTIONAL for a general generation but REQUIRED for Direct Kit
and Kit Split. It MUST NOT be required by the other five flows.

## 12. Model components

A model MUST declare `model_id`, display name, engine, family, digest, expected
filename/size, provenance, license metadata, flows, stems, I/O semantics, runtime
constraints, backends, platforms, capability constraints, visibility, deprecation,
and trust status. Filename alone MUST NOT establish identity or trust.

## 13. Configuration components

Configuration MUST be immutable, digested, versioned, receipt-backed, compatible
with its consumers, and selected through a generation rather than mutable global state.

## 14. Generation model

A generation manifest MUST contain schema version, generation ID, manifest digest,
component/receipt references, resolved compatibility result, and creation provenance.
It MUST reference `runtime.main`, required models/config/catalog, optional
`runtime.drumsep`, and relevant helper/integration components. Published generation
content SHALL NOT change; every change creates a new generation. There MUST NOT be
per-component active pointers.

## 15. Compatibility model

Compatibility rules are declarative predicates over platform, architecture,
backend, runtime/Python capability, components, models, flows, catalog schema, and
helper contract. Evaluation yields `compatible`, `incompatible`, or `unknown`.
Unknown MUST fail closed for activation. The generation manifest MUST record the
resolved result and diagnostics for every rejected or unknown constraint.

## 16. Desired state

Desired state SHALL declare desired components/channels or versions, allowed
backends, retained generations, requested flows, overrides, and policy constraints.
It MUST NOT directly publish active state.

## 17. Installed state

Installed state MUST be derivable from immutable receipts, generation manifests,
and payload verification. Partially installed components MAY exist outside the
active generation and MUST NOT become visible to processing implicitly.

## 18. Receipts

Receipts are append-only and immutable. Each MUST contain schema/receipt identity,
component/version, artifact and payload digest or file manifest, location reference,
provenance, installation time, installer identity, validation, platform,
architecture, backend, and ownership. Correction creates a new receipt; supersession
is separate history. Missing or damaged receipts MUST block activation but MUST NOT
trigger automatic payload deletion.

## 19. SQLite state and rebuild

SQLite MAY authoritatively hold desired state, ownership assertions, and operation
history. Cached catalog, receipt index, generation index, and UI state are rebuildable.
SQLite MUST NOT be the sole authority for payload integrity, receipts, selector, or
generation manifests. Corruption SHALL enter recovery, preserve immutable evidence,
rebuild indexes, and fail closed if desired state or ownership cannot be recovered.

## 20. Generation construction

Construction MUST validate schemas, identities, digests, receipts, dependency
closure, conflicts, flow requirements, trust, and compatibility before computing
the manifest digest. Only a complete `compatible` generation is activation-eligible.

## 21. Activation

Activation has thirteen phases: load manifest; validate schema; validate receipts;
verify payload; evaluate compatibility; assess leases/pins; write temporary selector;
flush selector; atomically replace; perform parent durability action; observe
publication; update journal; classify failure. Failure before publication MUST leave
the old selector; ambiguous publication MUST enter recovery without guessing.

## 22. Selector publication

The selector is strict JSON containing schema version, generation ID, and manifest
digest. It MUST be written on the same filesystem and atomically replace the prior
selector. Readers MUST validate it and resolve exactly once per run.

## 23. Rollback

Rollback is a new activation transaction selecting a previously valid complete
generation. It MUST revalidate current integrity, trust, compatibility, and retention;
it MUST NOT mutate the previous generation.

## 24. Recovery

Recovery MUST reconcile temporary selectors, active selector, immutable manifests,
receipts, and journal evidence. It MUST prefer the last fully validated observable
selector and MUST fail closed when publication state cannot be established.

## 25. Run pinning

Every processing run MUST create one run-pin binding `run_id` to exactly one
`generation_id` and lease. Activation after pin acquisition MUST NOT change that
run's inputs. Mixed-generation processing is forbidden.

## 26. Leases and process identity

A lease MUST include lease/run/generation IDs, PID, native process-start identity,
acquisition time, and state. PID alone is insufficient. PID reuse is live only when
PID and process-start identity match. Unknown identity becomes `suspected`; it MUST
block GC. Age alone MUST NOT prove staleness. A lease MAY be removed only after
positive non-liveness, explicit release, or audited administrative resolution.

## 27. Garbage collection

GC eligibility requires: not active, not pinned, no active/suspected lease, not
retained for rollback, not desired, no install/repair/recovery operation, known
ownership, and sufficient integrity knowledge. Shared components MUST use complete
receipt/generation reference accounting. Unknown ownership defaults to KEEP.
Automatic GC MUST retain the active generation, every pinned/leased/suspected or
user-retained generation, at least two proven rollback generations, and the three
newest otherwise eligible inactive generations. A normal candidate MUST be inactive
for at least 30 days and exceed the count threshold; both conditions are REQUIRED.
Failed incomplete installs MAY be cleaned after 7 days only when unreferenced,
ownership is known, and no operation or suspected lease exists. Revoked generations
MUST be retained for 90 days after a validated replacement exists; critical-deny
content MUST NOT be auto-deleted before forensic/audit preservation. Shared content
requires exact zero references. Every deletion requires a dry run, explicit candidate
list, durable journal entry and receipt/tombstone evidence retained for 365 days.
Disk pressure MUST NOT bypass safety rules.

## 28. Catalog

The catalog is a declarative, versioned, trust-validated source of components,
flows, dependencies, compatibility, artifact locators, provenance, presentation,
installability, deprecation, and channels. Unknown or untrusted catalogs MUST NOT
drive installation or activation. Each channel has a monotonic unsigned 64-bit
sequence, catalog digest, previous accepted digest, minimum accepted sequence,
publication time, signature envelope, and `official.catalog` or `user.catalog` scope.
A lower sequence, equal sequence with another digest, or chain break MUST fail closed.
A channel switch creates a distinct audited sequence namespace and MUST NOT reset the
prior namespace. Manual rollback requires an explicit recovery authorization naming
the target digest/sequence and creates an audit record; it MUST NOT alter active state.
The durable last-accepted sequence/digest record is content-addressed evidence outside
SQLite; SQLite MAY index it.

## 29. Viewmodel

The manager-owned viewmodel MUST expose availability, active generation, installed
and missing components, updates, flow readiness, blocked reason, repairability,
backend/platform, progress, diagnostics reference, and permitted actions.

## 30. REAPER consumer contract

REAPER MAY read/render the viewmodel, request explicit manager actions, and start
processing against a manager-issued run pin. It MUST NOT mutate SQLite or receipts,
write the selector, combine loose component pointers, or duplicate installation logic.

## 31. Platform helper boundaries

Helpers accept only validated `helper-request` records and return `helper-result`.
They MUST authenticate/authorize the caller in production, constrain paths to an
approved root, verify digests, apply least privilege, and provide auditable results.
The core owns compatibility, trust, and lifecycle decisions.

## 32. Installer boundaries

Windows MAY use an elevated Setup/helper; macOS MAY use a signed/notarized helper or
pkg with explicit arm64/Intel artifacts; Linux MAY use user or system helpers without
assuming root. Package-manager integration is OUT_OF_SCOPE_V1.

## 33. Platform durability

Linux requires file flush, atomic same-filesystem rename/replace, and proven parent
directory open/flush. macOS requires the same plus architecture-correct statfs ABI.
Windows requires file flush, native replacement, a write-capable parent directory
handle, and `FlushFileBuffers`. These are bounded publication primitives; no OS-crash
or power-loss guarantee is claimed.

## 34. Diagnostics

Operations MUST emit structured diagnostic events with operation, phase, severity,
message, expected/actual where relevant, structured error, and stable artifact/log
references. Diagnostics MUST NOT contain secrets or unrestricted local paths.

## 35. Error taxonomy

The 27 stable categories are defined by `error.schema.json`. Every error MUST include
code, category, operation, phase, human message, diagnostic detail, retryability,
recoverability, affected identity, and log reference.

## 36. Fail-closed rules

Schema, identity, version, digest, provenance, signature, receipt, payload,
compatibility, selector, lease identity, run pin, ownership, catalog trust, helper,
and platform uncertainty each MUST prevent the unsafe transition. Silent fallback is
forbidden. Existing active state SHOULD remain untouched when safety is uncertain.

## 37. Schema evolution

Schema versions use SemVer independently from Contract v1. All v1 schema families
support major 1 with minimum readable `1.0.0` and current writable `1.0.0`. Readers
MUST accept supported 1.x versions no newer than their advertised minor; because v1
schemas are strict, an unknown newer minor or feature gate MUST fail closed unless an
explicit compatible adapter exists. Writers MUST emit exactly their current advertised
version. Unknown majors MUST fail closed. Immutable receipts/manifests MUST NOT be
migrated in place. Migration creates a new record/artifact with source digest, target
version, tool identity, timestamp, result digest, and journal entry. Before any write,
migration, activation, or downgrade the core MUST prove that all active persistent
objects and at least two rollback generations are readable by the target. Lossy
downgrade is forbidden. Helper and core MUST exchange contract version, schema-family
read/write ranges, feature gates, and fail closed on no compatible intersection.

## 38. Security

Catalogs, artifacts, models, helpers, receipts, manifests, and channels cross trust
boundaries and MUST be validated before use. Digests protect integrity, not publisher
identity. Signature envelope version `1` uses RFC 8785 JCS canonical JSON, SHA-256
payload digests, and primary algorithm `Ed25519`. `ECDSA-P256-SHA256` is the sole
transition algorithm and MUST use strict DER, low-S and named-curve validation. The
algorithm-policy profile is versioned; unknown algorithms or profiles fail closed.
The envelope MUST carry version, key fingerprint, algorithm, payload digest,
canonicalization, signature bytes, trust scope, signer metadata, and optional signing
and expiry time. Official catalogs, artifact metadata, trust snapshots, rotation and
revocation statements MUST be signed. Artifact bytes MUST match the signed digest.
Helpers/installers require platform-native code signing plus manager trust metadata.
Receipts and generation manifests MAY be unsigned because they are locally
content-addressed and bound to validated receipts. Unsigned official objects fail
closed. Unsigned development objects require explicit, visible, isolated
`development.local` mode and MUST NOT enter an official generation.

## 39. Trust revocation

Key status is `active`, `retiring`, `revoked`, `expired`, or `unknown`, with effective
time, reason, replacement fingerprint, scope and signed statement. Rotation requires
either an old-valid-key signature over the replacement or a new root delivered through
an already trusted channel, with a minimum 30-day overlap, audit chain, and explicit
old-key termination. Unknown chains fail closed for install and activation.

Revoked keys/artifacts MUST block download, installation, new activation and rollback.
An already active, locally valid generation MAY continue in controlled recovery with
an explicit diagnostic until replacement exists, unless a signed `critical_deny`
requires immediate processing refusal. Emergency deny MUST NOT silently delete bytes.

Offline verification MUST use the last locally persisted and validated signed trust
snapshot containing version, monotonic sequence, issued/expiry times, scoped trusted
and revoked keys, artifact revocations, minimum catalog sequence, rotations and
signature. Maximum trust age is 30 days; no grace period applies to official install,
repair, activation or rollback after expiry. Existing locally valid active use remains
available unless the last valid snapshot contains a critical deny. Network absence
MUST NOT skip verification. Unknown revocation status blocks state-changing operations.
Persisted last-trusted wall time and snapshot sequence MUST detect clock or sequence
rollback; either ambiguity fails closed.

## 40. Testing and conformance

Profiles are core, catalog producer, platform helper, installer, REAPER consumer, and
diagnostic producer. Each MUST advertise contract/schema versions, validate boundary
records, exercise its MUST rules, and fail closed on unsupported inputs. A native claim
requires a concrete selected completed case-result record; aliases and probes do not count.

## 41. Guarantee boundaries

POA evidence covers tested process crash, recovery, rollback, leases, pinning,
integrity, and platform primitives. It does not prove OS-crash, power-loss, production
packaging, cryptographic policy, model provenance, REAPER integration, or performance.

## 42. Version-1 exclusions

Package-manager integration, automatic key enrollment, cross-major in-place migration,
remote management, multi-host coordination, production UX, and release mechanics are
OUT_OF_SCOPE_V1.

## 43. Open policy decisions

The five former implementation blockers are resolved by ADR-001 through ADR-005.
Residual non-blocking work is implementation planning, operational runbooks, and
platform validation of the specified interfaces. Contract policy gate is READY, but
production implementation remains unauthorized until a separate Production Readiness
Gate approves package boundaries, bindings, storage layout and vertical slices.

## 44. Appendices and examples

Schemas are under `schemas/`, valid examples under `examples/`, rejection cases under
`negative-fixtures/`, and traceability in `CONTRACT_V1_TRACEABILITY.md`. The seven
flows are Normal Stems, 6-Stem, Direct Kit, Kit Split, Vocals HQ, De-Reverb, and Vocal
De-Reverb; their exact component requirements are represented in the catalog example.
