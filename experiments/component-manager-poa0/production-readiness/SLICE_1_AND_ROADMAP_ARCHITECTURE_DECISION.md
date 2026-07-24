# SLICE-1 and roadmap architecture decision

Status: PROPOSED_FOR_OWNER_APPROVAL

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
  callers migrate. Independent duplicate artifact domain types are forbidden.
- `pkg/provenance` owns parsed provenance facts without deciding trust.
- `pkg/compatibility` evaluates caller-supplied declarative facts and MUST NOT import
  `pkg/generation` or probe a platform.
- `pkg/resolution` composes only pure read-only domain packages and owns
  `ResolutionPreview` and `resolution_preview_digest` derivation.
- `pkg/catalog` MUST NOT import concrete trust or revocation packages before
  SLICE-6.
- No new service interface is introduced. SLICE-1 uses concrete pure functions;
  `Refresh`, stores, installation, signature verification, trust and activation are
  excluded.

## Signature and trust boundary

SLICE-1 may validate and project a signature envelope, canonicalize the signed
payload where Contract v1 requires it, and report structurally valid material as
`UNVERIFIED`. A malformed envelope returns a typed fail-closed error and is never a
successful preview status. Absence succeeds only where the frozen Contract v1 allows
unsigned input.

The domain representation has one constructible state: `UNVERIFIED`. Caller-supplied
`trust_status` is input data, never a policy decision. SLICE-1 cannot construct
`trusted` or `verified`.

## Error decision

No Contract-v1 category is added. `error.schema.json` permits non-empty category
strings, but the existing binding freezes these usable categories:
`schema_invalid`, `identity_invalid`, `version_invalid`,
`artifact_digest_mismatch`, `catalog_invalid`, and `internal_error`.
SLICE-1 must use the demonstrably applicable member. A required rejection without
such a member blocks implementation and requires a separately authorized Contract-v1
decision; it may not invent a category.

## Governance

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
