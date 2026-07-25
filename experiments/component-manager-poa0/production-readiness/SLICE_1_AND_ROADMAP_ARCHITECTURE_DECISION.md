# SLICE-1 and roadmap architecture decision

Status: APPROVED_BY_OWNER

OWNER_APPROVAL_DATE=2026-07-25

OWNER_APPROVED_REVIEW_HEAD=856b5bc0643fe3fc6effb824b195d15fa3abf758

DOCUMENTATION_CLOSURE_STATUS=APPROVED_BY_OWNER

SLICE1_IMPLEMENTATION_STATUS=AUTHORIZED_NOT_STARTED

SLICE1_IMPLEMENTATION_AUTHORIZED=yes

SLICE1_IMPLEMENTATION_STARTED=no

Approval of this documentation closure does not authorize implementation.
SLICE-1 implementation requires a separate explicit owner authorization after
integration and entry-gate reverification.

## Owner implementation authorization

OWNER_IMPLEMENTATION_AUTHORIZATION_DATE=2026-07-25

OWNER_IMPLEMENTATION_BASELINE=e0fe346e8f643a2643f97bcb50cd6616769e1362

OWNER_IMPLEMENTATION_BRANCH=slice/1-read-only-resolution-preview

I authorize implementation of SLICE-1 — Read-only catalog and component
validation from approved governance baseline
e0fe346e8f643a2643f97bcb50cd6616769e1362, on branch
slice/1-read-only-resolution-preview, under the exact allowed-path, API,
dependency, test, governance and stop-condition contract in
component-manager/docs/SLICE_1_SCOPE.md. This authorization does not extend to
SLICE-2 or later capabilities.

SLICE-2 and later slices are not authorized. No exit claim is permitted.
No release is permitted. Product implementation has not started. The branch
permits at most five content commits, requires the local fast gate before
every push, fails closed on unknown paths, permits no new dependency without
a new GATE-P7 review, and keeps Contract v1 and schemas frozen.

Decision basis: owner-selected HYBRID roadmap reviewed against commit
`ab59eef7d00de7e0d6e4d2467fb815a3d0975eb3`. This decision does not authorize
implementation.

## Context

The eleven-slice roadmap was sound, but the former one-column traceability mixed
type, policy and capability realization. That made FAIL-001..012, state ownership,
catalog trust dependencies and the SLICE-1 API surface appear contradictory.
SLICE-0 also left catalog-owned artifact and trust strings that require a bounded,
non-breaking migration.

## Decision

ROADMAP_OPTION=HYBRID

SLICE1_VERTICAL_OUTPUT=ResolutionPreview

SLICE_NUMBERING=SLICE-0..SLICE-10_UNCHANGED

REQUIREMENT_REALIZATION_LEVELS=TYPE_LEVEL_SLICE; POLICY_LEVEL_SLICE; CAPABILITY_LEVEL_SLICE

A requirement may span slices only when every realization level, first exercise,
reverification and rationale are explicit in `READINESS_TRACEABILITY.md`.

SLICE-1 remains **Read-only catalog and component validation**. It accepts
caller-supplied bytes and context, then performs schema and structural validation,
component selection, typed identity/version/digest/artifact/provenance projection,
structural signature-envelope processing, declarative compatibility evaluation and
a deterministic `ResolutionPreview`. It performs no network, filesystem read or
write, persistent state, clock/random access, cryptographic verification, trust or
revocation decision.

## Package and API decisions

- `pkg/artifact` is the normative owner of `Artifact` and `ArtifactSet`.
  `pkg/catalog.Artifact` may temporarily be a documented alias or adapter while
  callers migrate. It is removed before the SLICE-1 exit gate; SLICE-2 never sees
  the alias. Independent duplicate artifact domain types are forbidden.
- `pkg/provenance` owns parsed provenance facts without deciding trust.
- `pkg/compatibility` evaluates caller-supplied declarative facts and MUST NOT import
  `pkg/generation` or probe a platform.
- Later generation compatibility orchestration is owned by `pkg/generation` or a
  higher application layer. It projects a candidate to `compatibility.Facts` and
  invokes `compatibility.Evaluate(Facts, Context)`; no generation object crosses
  into `pkg/compatibility`.
- `pkg/resolution` composes only pure read-only domain packages and owns
  `ResolutionPreview`, `ComponentSelector`, its closed `VersionSelector`, and
  `resolution_preview_digest` derivation. `ComponentSelector` is catalog-local and
  cannot represent the generation selector from Contract v1 §22.
- `pkg/catalog` MUST NOT import concrete trust or revocation packages before
  SLICE-6.
- No new service interface is introduced. SLICE-1 uses concrete pure functions;
  `Refresh`, stores, installation, signature verification, trust and activation are
  excluded.

Compatibility preserves Contract v1 §15's `Compatible`, `Incompatible` and
`Unknown` as a closed `ContractStatus`. Only `Compatible` is runnable;
`Incompatible` and `Unknown` are not runnable and remain distinguishable. Reasons
are closed typed codes ordered by the fixed priority in `SLICE_1_SCOPE.md` and then
lexically by code. An empty valid predicate set is `Compatible` with no reasons;
missing context for a declared predicate is `Unknown`.

## Signature and trust boundary

SLICE-1 may validate and project a signature envelope, canonicalize the signed
payload where Contract v1 requires it, and report structurally valid material as
`UNVERIFIED`. A malformed envelope returns a typed fail-closed error and is never a
successful preview status. Absence succeeds only where the frozen Contract v1 allows
unsigned input.

The domain representation has one constructible state: `UNVERIFIED`. Caller-supplied
`trust_status` is input data, never a policy decision. SLICE-1 cannot construct
`trusted` or `verified`. During SLICE-1 the existing `catalog.TrustStatus string` is
replaced in the resolution path by the closed `TrustRepresentation`; no parallel
long-lived trust representation is permitted and the string does not cross the
`ResolutionPreview` boundary.

## Error decision

No Contract-v1 category is added. `error.schema.json` permits non-empty category
strings, but the existing binding freezes these usable categories:
`schema_invalid`, `identity_invalid`, `version_invalid`,
`artifact_digest_mismatch`, `catalog_invalid`, and `internal_error`.
SLICE-1 must use the demonstrably applicable member. A required rejection without
such a member blocks implementation and requires a separately authorized Contract-v1
decision; it may not invent a category.

## Later HYBRID phases

SLICE-6 first adds pure cryptographic verification and trust/revocation policy over
caller-supplied material. Stateful enrollment, root mutation, monotone offline
snapshots and persisted revocation/catalog sequence evidence follow within SLICE-6
only after their mutation authorization and storage gates. Slice numbering is not
changed by this internal phase boundary.

## Owner review controls

- [x] Total HYBRID roadmap approved
- [x] SLICE-1 requirements approved
- [x] SLICE-1 API subset approved
- [x] Package graph approved
- [x] Vertical ResolutionPreview demo approved
- [x] Exit evidence approved
- [x] Governance approved
- [x] Implementation may be authorized

The owner checked the first seven controls on 2026-07-25 and the eighth
control on 2026-07-25 after integration and entry-gate reverification. All
eight controls are now checked.

## Governance execution

The SLICE-1 implementation branch is `slice/1-read-only-resolution-preview`, based
on the approved documentation-closure head. It permits at most five content commits,
requires staged-diff review before each commit and local fast gates before each push,
and forbids force-push after CI evidence exists. Unknown changed paths fail closed.
Owner review precedes exactly one final native exit gate on a pinned head. Targeted
diagnostics are allowed for platform/infrastructure faults; a rerun of the same head
requires proven infrastructure failure, while content failure requires a new commit.

During SLICE-1, documentation and read-only governance checks may be added only when
they remain within the scope path set and do not obscure product review. Before
SLICE-2, governance must move to `ci/change-policy.yaml`, reusable workflows, a
generic diagnostic mode, a fail-closed mode/path classifier, a PR fast gate, a
matrix-job cap, frozen-path guards, machine-readable evidence and a full native
slice-exit matrix. Incident SHAs are forbidden in that design.

## Consequences

SLICE-1 can preview resolution but cannot authorize installation or runnable trust.
SLICE-3 retains generation compatibility decisions, SLICE-6 retains cryptographic
verification/trust/revocation, and all stateful capabilities remain in their recorded
later slices. The exact executable scope and evidence contract are in
`component-manager/docs/SLICE_1_SCOPE.md`.
