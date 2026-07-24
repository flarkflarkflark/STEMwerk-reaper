# SLICE-1 scope

OFFICIAL_NAME=Read-only catalog and component validation

ONE_SENTENCE_GOAL=Valideer caller-supplied catalogus- en componentbytes en produceer een deterministische, machine-leesbare ResolutionPreview die iedere keuze en afwijzing verklaart, zonder netwerk, writes, persistent state of trustbeslissingen.

STATUS=PROPOSED_FOR_OWNER_APPROVAL

IMPLEMENTATION_AUTHORIZED=no

## Vertical demonstration

VERTICAL_DEMO=caller-supplied catalog bytes -> catalogschema and structural validation -> select exactly one component via caller-supplied selector -> project and validate identity, version, kind, artifacts and provenance -> detect duplicate identity and same-version/different-digest -> parse signature envelope structurally only -> evaluate declarative compatibility facts against caller-supplied context -> unknown compatibility fails closed as NotRunnable -> produce canonical ResolutionPreview -> derive resolution_preview_digest -> explain every rejection with an existing typed contract error -> no network -> no paths or product-filesystem reads -> no writes -> no time/random -> no trust decision

## Inputs and outputs

INPUTS=caller-supplied catalog bytes; caller-supplied selector; caller-supplied compatibility context; explicit input-size limit

OUTPUTS=ResolutionPreview; resolution_preview_digest; typed contract error on rejection

`ResolutionPreview` contains the selected component identity, kind and version;
artifact descriptors; provenance facts; structural signature presence as
`UNVERIFIED`; compatibility result (`Runnable`, `NotRunnable` or explained
rejection); canonicalization metadata; deterministic diagnostics. It contains no
installation instruction, local path, mutable state reference or trusted decision.

## Requirement boundary

IN_SCOPE_REQUIREMENTS=CMV1-CORE-001; CMV1-CATALOG-001; CMV1-PROVENANCE-001; CMV1-FAIL-001 policy; CMV1-FAIL-003 compatibility input; CMV1-FAIL-004 compatibility input; CMV1-FAIL-009 provenance/signature structure; CMV1-FAIL-010 parser regression; CMV1-FAIL-011 preview policy/regression; CMV1-FAIL-012 catalog-level policy

SPLIT_REQUIREMENTS=CMV1-FAIL-001 type SLICE-0/policy SLICE-1; CMV1-FAIL-003 input SLICE-1/generation decision SLICE-3; CMV1-FAIL-004 input SLICE-1/generation fail-closed SLICE-3; CMV1-FAIL-009 structure SLICE-1/trust decision SLICE-6; CMV1-FAIL-010 SLICE-0 plus parser regressions; CMV1-FAIL-011 catalog SLICE-0 plus preview SLICE-1; CMV1-FAIL-012 catalog SLICE-0/1 plus generation SLICE-3

OUT_OF_SCOPE_REQUIREMENTS=CMV1-STATE-001 capability; CMV1-FAIL-002; CMV1-FAIL-005; CMV1-FAIL-006; CMV1-FAIL-007; CMV1-FAIL-008; trust/signature capability requirements; receipt; generation construction; activation/rollback/recovery; leases/run pins/GC; helper/installer/consumer capability requirements

## Allowed code surface

ALLOWED_PACKAGES=future pkg/artifact; future pkg/provenance; future pkg/compatibility; future pkg/resolution; existing pkg/catalog; existing pkg/component; existing pkg/identity; existing pkg/version; existing pkg/digest; existing pkg/platform; existing pkg/schemaversion; existing pkg/contract; existing internal/canonicaljson; existing internal/schemavalidation; existing schemas

ALLOWED_TYPES=future artifact.Artifact; future artifact.ArtifactSet; future provenance.Provenance; future compatibility.Context; future compatibility.Result; future compatibility.Status; future resolution.Selector; future resolution.ResolutionPreview; future resolution.TrustRepresentation; existing catalog.Catalog; existing catalog.Component; existing component.ComponentKind; existing identity.ComponentID; existing identity.ArtifactID; existing version.CatalogVersion; existing digest.Digest; existing schemaversion.Version; existing contract.Category; existing contract.Error

ALLOWED_FUNCTIONS=future artifact.Parse; future provenance.Parse; future compatibility.Evaluate; future resolution.Preview; future resolution.CanonicalizePreview; future resolution.DerivePreviewDigest; existing catalog.ParseBytes; existing catalog.ParseReader; existing identity.ParseComponentID; existing identity.ParseArtifactID; existing component.ParseKind; existing digest.Parse; existing contract.ValidateJSON; existing canonicaljson.Canonicalize

The future symbols above are normative names for SLICE-1. No other exported symbol,
service interface or effect abstraction is authorized. `ResolutionPreview` trust is
represented by a closed domain type whose only constructible SLICE-1 value is
`UNVERIFIED`.

FORBIDDEN_APIS=CatalogService.Refresh; any Store; Install; VerifySignature; Trust; Revocation; Activate; filesystem APIs; network APIs; database/sql; clock/time reads; random sources; platform probes

ALLOWED_PATHS=component-manager/pkg/artifact/**; component-manager/pkg/provenance/**; component-manager/pkg/compatibility/**; component-manager/pkg/resolution/**; component-manager/pkg/catalog/**; component-manager/pkg/component/**; component-manager/pkg/identity/**; component-manager/pkg/version/**; component-manager/pkg/digest/**; component-manager/pkg/platform/**; component-manager/pkg/schemaversion/**; component-manager/pkg/contract/**; component-manager/internal/canonicaljson/**; component-manager/internal/schemavalidation/**; component-manager/testdata/slice1/**; component-manager/docs/SLICE_1_SCOPE.md; component-manager/docs/CONTRACT_TRACEABILITY.md; component-manager/scripts/**; .github/workflows/component-manager-slice1-cross-platform.yml

FORBIDDEN_PATHS=component-manager/go.mod; component-manager/go.sum; component-manager/schemas/**; experiments/component-manager-poa0/contract-v1/**; experiments/component-manager-poa0/fixtures/**; experiments/component-manager-poa0/go/**; experiments/component-manager-poa0/rust/**; experiments/component-manager-poa0/harness/**; experiments/component-manager-poa0/reports/**; component-manager/internal/store/**; component-manager/internal/platform/**; component-manager/internal/helper/**; runtime/**; models/**; installer/**; REAPER/**

Allowed and forbidden patterns are evaluated against repository-relative paths;
unknown paths fail closed. Existing schemas may be read and tested through the
embedded API, but their paths and bytes are frozen.

## Dependency policy

DEPENDENCY_POLICY=no new external dependency; retain exactly the approved pinned direct dependencies github.com/santhosh-tekuri/jsonschema/v6@v6.0.2 and github.com/gowebpki/jcs@v1.0.1; CGO disabled; no SQLite; no network after bootstrap

## Entry gates

ENTRY_GATES=approved documentation-closure head; SLICE-0 exit PASS; GATE-P2 PASS; GATE-P4 PASS; GATE-P5 Contract-v1 unchanged; GATE-P6 POA/evidence unchanged; GATE-P7 existing dependencies reviewed and no new dependency; GATE-P8 PASS; XPG-001 closed; XPG-002 closed; four-platform baseline PASS; clean implementation worktree; explicit SLICE-1 implementation authorization

## Exit gates and evidence

EXIT_GATES=four native jobs PASS; artifacts 4/4 valid; all positive, negative and fault fixtures PASS; 100 identical repetitions per positive preview fixture; canonical bytes, preview digests and result sets equal across platforms; forbidden findings 0; no new dependency; 0 reachable or blocking new advisories; clean worktrees; Contract-v1 and schemas unchanged; SLICE1_EXIT=PASS

POSITIVE_FIXTURES=seven-flow catalog; runtime.main; runtime.drumsep; model component; artifact descriptor; provenance; structurally valid signature envelope; runnable compatibility context; multiple valid artifact selections

NEGATIVE_FIXTURES=malformed JSON; oversized input; unsupported schema major; duplicate component identity; same version/different digest; digest mismatch; missing selector target; malformed signature envelope; unknown compatibility; incompatible backend; incompatible platform; incompatible architecture; malformed provenance; missing required fields; unknown enums; canonicalization/digest mismatch

FAULT_INJECTION=truncation; reader errors; limit boundary; duplicate JSON members under an explicit reject policy; Unicode/normalization; malformed nested objects; empty arrays; deterministic serialization; machine-readable summary-write failure outside product code; artifact-upload failure classified as CI infrastructure failure

ARTIFACT_CONTENTS=test summary; fixture matrix; preview digest list; determinism table; import-graph result; forbidden-behavior report; security summary; worktree hygiene; machine-readable gate summary

MACHINE_READABLE_SUMMARY=checkout_head; platform; architecture; Go version; CGO status; fixture counts/results; repetition count; preview digests; import graph result; forbidden finding count; dependency/security result; Contract-v1/schema equality; worktree hygiene; SLICE1_EXIT

Security requires the always-deny schema loader, license audit, isolated
`govulncheck`, forbidden-import scan and import-graph guard. Required native targets
are Linux x86_64, Windows x86_64, macOS Intel x86_64 and macOS Apple Silicon arm64.

## Governance

BRANCH_POLICY=slice/1-read-only-resolution-preview based on the approved documentation-closure head

COMMIT_BUDGET=maximum 5 content commits; checkpoint commits allowed within that total; staged-diff review before every commit

PUSH_POLICY=local fast gates before every push; unknown changed paths fail closed; no force-push after CI evidence exists

DISPATCH_POLICY=owner review before exactly one final native exit gate on the pinned candidate head; targeted diagnostics allowed; same-head rerun only for evidenced infrastructure failure; content failure requires a new commit

IMMEDIATE_GOVERNANCE=branch/head pin; path allowlist and denylist; staged-diff review; five-commit budget; local fast gates; owner review; exact final native dispatch; machine-readable artifacts; fail-closed unknown paths

DURING_SLICE1_GOVERNANCE=the slice-specific workflow and read-only policy/consistency checks may be added within allowed paths without changing unrelated product-gate semantics

BEFORE_SLICE2_GOVERNANCE=central ci/change-policy.yaml; reusable workflows; generic diagnostic mode; no incident SHA logic; matrix-job cap; unknown modes fail closed; PR fast gate; full native exit matrix; frozen-path guards; machine-readable evidence

## Stop conditions

STOP_CONDITIONS=head mismatch; dirty preflight; missing explicit implementation authorization; changed unknown/forbidden path; Contract-v1 or schema drift; new dependency; CGO or SQLite; network/filesystem/time/random/effect import; trust/cryptographic verification; state mutation; unsupported error category; non-determinism; cross-platform divergence; missing or invalid artifact; failed security or hygiene gate; exhausted commit/push/dispatch budget

Malformed signature material always returns a typed fail-closed error. A valid
structural envelope is `UNVERIFIED`; malformed is never a successful preview state.
No implementation may invent an error category beyond the existing binding set.
