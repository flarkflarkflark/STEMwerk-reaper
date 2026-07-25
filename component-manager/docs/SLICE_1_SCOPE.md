# SLICE-1 scope

OFFICIAL_NAME=Read-only catalog and component validation

ONE_SENTENCE_GOAL=Valideer caller-supplied catalogus- en componentbytes en produceer een deterministische, machine-leesbare ResolutionPreview die iedere keuze en afwijzing verklaart, zonder netwerk, writes, persistent state of trustbeslissingen.

STATUS=APPROVED_BY_OWNER

IMPLEMENTATION_AUTHORIZED=no

## Vertical demonstration

VERTICAL_DEMO=caller-supplied catalog bytes -> catalogschema and structural validation -> select exactly one component via caller-supplied selector -> project and validate identity, version, kind, artifacts and provenance -> detect duplicate identity and same-version/different-digest -> parse signature envelope structurally only -> evaluate declarative compatibility facts against caller-supplied context -> unknown compatibility fails closed as NotRunnable -> produce canonical ResolutionPreview -> derive resolution_preview_digest -> explain every rejection with an existing typed contract error -> no network -> no paths or product-filesystem reads -> no writes -> no time/random -> no trust decision

## Inputs and outputs

INPUTS=caller-supplied catalog bytes; caller-supplied ComponentSelector; caller-supplied compatibility Context; explicit input-size limit

OUTPUTS=ResolutionPreview; resolution_preview_digest; typed contract error on rejection

`ResolutionPreview` contains the selected component identity, kind and version;
artifact descriptors; provenance facts; structural signature presence as
`UNVERIFIED`; compatibility `ContractStatus`, `Runnable` and ordered typed reasons;
canonicalization metadata; deterministic diagnostics. It contains no
installation instruction, local path, mutable state reference or trusted decision.

## Component selection

SELECTOR_TYPE=resolution.ComponentSelector

SELECTOR_FIELDS=ComponentID identity.ComponentID; Version resolution.VersionSelector

`VersionSelector` is a closed discriminated union with exactly one active variant
chosen from these two variants:

| Variant | Fields | Exact comparison |
|---|---|---|
| Software | `SoftwareVersion version.SoftwareVersion` | exact SemVer text including build metadata and exact non-negative package revision; case-sensitive |
| Model | `ModelRevision version.ModelRevision`; `ArtifactDigest digest.Digest` | exact case-sensitive publisher revision and exact SHA-256 digest |

`version.SoftwareVersion` is the existing composite value containing SemVer and
package revision; no new generic component-version scalar is introduced. Model
digest is required because publisher revision alone does not provide immutable-byte
identity. Selection occurs only within the supplied catalog: exactly one match is
required. Zero or multiple matches fail closed. Duplicate identity/version and
same-version/different-digest checks run before selection. This is not the Contract-v1
generation selector, active-generation selector or desired-state selector, and it
does no filesystem lookup.

## Compatibility boundary

COMPATIBILITY_STATUS_MODEL=Compatible|Incompatible|Unknown

RUNNABLE_MAPPING=Compatible:true; Incompatible:false; Unknown:false

`compatibility.Result` contains `ContractStatus compatibility.ContractStatus`,
`Runnable bool`, and `Reasons []compatibility.Reason`. `Unknown` remains distinct
from `Incompatible`; neither is runnable. An empty, structurally valid compatibility
predicate object produces `Compatible`, `Runnable=true`, and an empty reason list.
A field required by a declared predicate but absent from caller context produces
`Unknown`, `Runnable=false`, and its typed unknown reason.

UNKNOWN_CONTEXT_FIELD_POLICY=typed Go Context is closed and cannot represent unknown fields; JSON context fixtures reject unknown properties; generic map[string]any is forbidden

The production boundary is the closed typed Go `compatibility.Context`; it does not
accept a generic property map. JSON exists only at contract-test or transport-fixture
boundaries, where decoding is strict and every unknown property fails closed.

| CONTEXT_FIELD | TYPE | SOURCE_REQUIREMENT | REQUIRED_OR_OPTIONAL | UNKNOWN_BEHAVIOR | COMPARISON_RULE | REASON_CODE |
|---|---|---|---|---|---|---|
| Platform | `platform.Platform` | Contract v1 §15 platform | required when predicate declared | Unknown | exact validated enum equality | `platform_unknown` when absent; `platform_mismatch` when unequal |
| Architecture | `platform.Architecture` | Contract v1 §15 architecture | required when predicate declared | Unknown | exact validated enum equality | `architecture_unknown` when absent; `architecture_mismatch` when unequal |
| Backend | `platform.Backend` | Contract v1 §15 backend | required when predicate declared | Unknown | exact validated enum equality | `backend_unknown` when absent; `backend_mismatch` when unequal |
| ComponentKind | `component.ComponentKind` | Contract v1 §§10,15 components | required when predicate declared | Unknown | exact seven-kind enum equality | `component_kind_unknown` when absent; `component_kind_mismatch` when unequal |
| SchemaVersion | `schemaversion.Version` | Contract v1 §§15,37 catalog schema | required when predicate declared | Unknown | supported major/minor window via existing value semantics | `schema_capability_unknown` |

| §15 predicate domain | SLICE-1 classification | Rationale |
|---|---|---|
| platform; architecture; backend; component kind; catalog schema | SLICE1_EVALUATED | caller and selected-component facts have existing value types |
| runtime/Python capability; component relations | SLICE1_PARSED_ONLY | preserve declared facts; closure needs a generation candidate |
| models; flows | SLICE1_PARSED_ONLY | preserve catalog facts; multi-component/flow readiness is SLICE-3 or later |
| helper contract | DEFERRED_TO_SLICE3_OR_LATER | helper capability and negotiation are later slices |

| COMPATIBILITY_FACT_FIELD | SOURCE | PROJECTED_IN_SLICE1 | EVALUATED_IN_SLICE1 | DEFERRED_SLICE | RATIONALE |
|---|---|---|---|---|---|
| ComponentID | component schema | yes | no | none | selection identity, not a compatibility predicate |
| ComponentKind | component schema | yes | yes | none | existing closed enum |
| SoftwareVersion or ModelRevision | component schema/Contract §§7,12 | yes | no | none | exact selection identity |
| ArtifactID and Digest | artifact schema | yes | no | none | immutable selection evidence |
| Provenance facts | provenance schema | yes | no | SLICE-6 policy | structure only; always unverified |
| Platform/Architecture/Backend predicates | component compatibility | yes | yes | none | caller context has existing values |
| SchemaVersion predicate | component/catalog schema | yes | yes | none | existing schema-version semantics |
| Runtime/Python/component/model/flow relations | component compatibility | yes | no | SLICE-3 | requires generation-level closure |

REASON_PRIORITY_ORDER=platform_unknown; platform_mismatch; architecture_unknown; architecture_mismatch; backend_unknown; backend_mismatch; component_kind_unknown; component_kind_mismatch; schema_capability_unknown; required_relation_unknown; incompatible_declared_constraint

Reasons are closed typed codes, ordered first by the above normative priority and
then lexically by code as a stable tie-break. Map iteration order and free-form
strings never define semantics. Compatibility results are domain outcomes, not
automatically `contract.Error`.

## Requirement boundary

IN_SCOPE_REQUIREMENTS=CMV1-CORE-001; CMV1-CATALOG-001; CMV1-PROVENANCE-001; CMV1-FAIL-001 policy; CMV1-FAIL-003 compatibility input; CMV1-FAIL-004 compatibility input; CMV1-FAIL-009 provenance/signature structure; CMV1-FAIL-010 parser regression; CMV1-FAIL-011 preview policy/regression; CMV1-FAIL-012 catalog-level policy

SPLIT_REQUIREMENTS=CMV1-FAIL-001 type SLICE-0/policy SLICE-1; CMV1-FAIL-003 input SLICE-1/generation decision SLICE-3; CMV1-FAIL-004 input SLICE-1/generation fail-closed SLICE-3; CMV1-FAIL-009 structure SLICE-1/trust decision SLICE-6; CMV1-FAIL-010 SLICE-0 plus parser regressions; CMV1-FAIL-011 catalog SLICE-0 plus preview SLICE-1; CMV1-FAIL-012 catalog SLICE-0/1 plus generation SLICE-3

OUT_OF_SCOPE_REQUIREMENTS=CMV1-STATE-001 capability; CMV1-FAIL-002; CMV1-FAIL-005; CMV1-FAIL-006; CMV1-FAIL-007; CMV1-FAIL-008; trust/signature capability requirements; receipt; generation construction; activation/rollback/recovery; leases/run pins/GC; helper/installer/consumer capability requirements

## Allowed code surface

ALLOWED_PACKAGES=future pkg/artifact; future pkg/provenance; future pkg/compatibility; future pkg/resolution; existing pkg/catalog; existing pkg/component; existing pkg/identity; existing pkg/version; existing pkg/digest; existing pkg/platform; existing pkg/schemaversion; existing pkg/contract; existing internal/canonicaljson; existing internal/schemavalidation; existing schemas

ALLOWED_TYPES=future artifact.Artifact; future artifact.ArtifactSet; future provenance.Provenance; future compatibility.Facts; future compatibility.Context; future compatibility.Result; future compatibility.ContractStatus; future compatibility.Reason; future resolution.ComponentSelector; future resolution.VersionSelector; future resolution.ResolutionPreview; future resolution.TrustRepresentation; existing catalog.Catalog; existing catalog.Component; existing component.ComponentKind; existing identity.ComponentID; existing identity.ArtifactID; existing version.SoftwareVersion; existing version.ModelRevision; existing version.CatalogVersion; existing digest.Digest; existing schemaversion.Version; existing contract.Category; existing contract.Error

ALLOWED_FUNCTIONS=future artifact.Parse; future provenance.Parse; future compatibility.Evaluate; future resolution.Preview; future resolution.CanonicalizePreview; future resolution.DerivePreviewDigest; existing catalog.ParseBytes; existing catalog.ParseReader; existing identity.ParseComponentID; existing identity.ParseArtifactID; existing component.ParseKind; existing digest.Parse; existing contract.ValidateJSON; existing canonicaljson.Canonicalize

The future symbols above are normative names for SLICE-1. No other exported symbol,
service interface or effect abstraction is authorized. `ResolutionPreview` trust is
represented by a closed domain type whose only constructible SLICE-1 value is
`UNVERIFIED`.

FUTURE_ALLOWED_PATHS=component-manager/pkg/artifact/**; component-manager/pkg/provenance/**; component-manager/pkg/compatibility/**; component-manager/pkg/resolution/**; component-manager/testdata/slice1/**; .github/workflows/component-manager-slice1-cross-platform.yml

FORBIDDEN_APIS=CatalogService.Refresh; any Store; Install; VerifySignature; Trust; Revocation; Activate; filesystem APIs; network APIs; database/sql; clock/time reads; random sources; platform probes

ALLOWED_PATHS=component-manager/pkg/artifact/**; component-manager/pkg/provenance/**; component-manager/pkg/compatibility/**; component-manager/pkg/resolution/**; component-manager/pkg/catalog/**; component-manager/pkg/component/**; component-manager/pkg/identity/**; component-manager/pkg/version/**; component-manager/pkg/digest/**; component-manager/pkg/platform/**; component-manager/pkg/schemaversion/**; component-manager/pkg/contract/**; component-manager/internal/canonicaljson/**; component-manager/internal/schemavalidation/**; component-manager/testdata/slice1/**; component-manager/docs/SLICE_1_SCOPE.md; component-manager/docs/CONTRACT_TRACEABILITY.md; component-manager/scripts/**; .github/workflows/component-manager-slice1-cross-platform.yml

FORBIDDEN_PATHS=component-manager/go.mod; component-manager/go.sum; component-manager/schemas/**; experiments/component-manager-poa0/contract-v1/**; experiments/component-manager-poa0/fixtures/**; experiments/component-manager-poa0/go/**; experiments/component-manager-poa0/rust/**; experiments/component-manager-poa0/harness/**; experiments/component-manager-poa0/reports/**; component-manager/internal/store/**; component-manager/internal/platform/**; component-manager/internal/helper/**

Allowed and forbidden patterns are evaluated against repository-relative paths;
unknown paths fail closed. Existing schemas may be read and tested through the
embedded API, but their paths and bytes are frozen.

Contract-v1 examples and negative fixtures are read directly from the frozen
authority whenever possible. A `testdata/slice1` copy is allowed only for a
slice-specific transformation or fixture with no authority equivalent; every copied
authority fixture records its source path and SHA-256 and has a byte-drift guard.

## Dependency policy

DEPENDENCY_POLICY=no new external dependency; retain exactly the approved pinned direct dependencies github.com/santhosh-tekuri/jsonschema/v6@v6.0.2 and github.com/gowebpki/jcs@v1.0.1; CGO disabled; no SQLite; no network after bootstrap

## Entry gates

ENTRY_GATES=approved documentation-closure head; SLICE-0 exit PASS; GATE-P2 PASS; GATE-P4 PASS; GATE-P5 Contract-v1 unchanged; GATE-P6 POA/evidence unchanged; GATE-P7 existing dependencies reviewed and no new dependency; GATE-P8 PASS; XPG-001 closed; XPG-002 closed; four-platform baseline PASS; clean implementation worktree; explicit SLICE-1 implementation authorization

## Exit gates and evidence

EXIT_GATES=four native jobs PASS; artifacts 4/4 valid; all positive, negative and fault fixtures PASS; 100 identical repetitions per positive preview fixture; canonical bytes, preview digests and result sets equal across platforms; forbidden findings 0; no new dependency; 0 reachable or blocking new advisories; clean worktrees; Contract-v1 and schemas unchanged; SLICE1_EXIT=PASS

POSITIVE_FIXTURES=seven-flow catalog; runtime.main; runtime.drumsep; model component; artifact descriptor; provenance; structurally valid signature envelope; runnable compatibility context; multiple valid artifact selections

NEGATIVE_FIXTURES=malformed JSON; oversized input; unsupported schema major; duplicate component identity before selection; same version/different digest before selection; digest mismatch; missing selector target; ambiguous selector target; malformed signature envelope; unknown compatibility; incompatible backend; incompatible platform; incompatible architecture; malformed provenance; missing required fields; unknown enums; canonicalization/digest mismatch

SELECTOR_FIXTURES=software component exact match; model component exact revision-plus-digest match; missing target; ambiguous target; duplicate rejected before selection; same-version/different-digest rejected before selection

| FAILURE_OR_RESULT | CATEGORY_OR_STATUS | ERROR_OR_DOMAIN_RESULT | SOURCE | STABLE_REASON | NOTES |
|---|---|---|---|---|---|
| malformed JSON | `schema_invalid` | contract error | `contract.ValidateJSON` and Contract v1 §36 | `schema_invalid` | malformed input never reaches projection |
| oversized input | `schema_invalid` | contract error | schema/parse input boundary and `contract.MaxJSONInputSize` | `schema_invalid` | the SLICE-1 boundary normalizes the existing catalog parser's current `catalog_invalid` oversize result to the schema-boundary category before implementation |
| unsupported schema major | `schema_invalid` | contract error | `schemaversion.Parse`, schema validator and Contract v1 §37 | `schema_version_unsupported` | unknown major fails closed |
| invalid identity | `identity_invalid` | contract error | `pkg/identity` and Contract v1 §6 | `identity_invalid` | component and artifact identities use their existing validators |
| duplicate identity | `catalog_invalid` | contract error | catalog semantic validation and Contract v1 §§28,36 | `catalog_invalid` | rejected before selection |
| same-version/different-digest | `artifact_digest_mismatch` | contract error | Contract v1 §§7,36 and catalog binding | `artifact_digest_mismatch` | rejected before selection |
| artifact digest mismatch | `artifact_digest_mismatch` | contract error | Contract v1 §§7,8,36 | `artifact_digest_mismatch` | applies only to artifact identity/integrity |
| missing selector | `catalog_invalid` | contract error | SLICE-1 selector contract | `catalog_invalid` | zero match fails closed |
| multiple selector matches | `catalog_invalid` | contract error | SLICE-1 selector contract | `catalog_invalid` | ambiguity fails closed |
| malformed provenance | `schema_invalid` | contract error | provenance schema and Contract v1 §§9,36 | `schema_invalid` | structural failure, not a trust decision |
| malformed signature | `schema_invalid` | contract error | signature-envelope schema and Contract v1 §§36,38 | `schema_invalid` | malformed is never a successful preview |
| compatibility Compatible | `Compatible` | domain result | Contract v1 §15 | none | runnable is true |
| compatibility Incompatible | `Incompatible` | domain result | Contract v1 §15 | ordered typed compatibility reasons | runnable is false; not a contract error |
| compatibility Unknown | `Unknown` | domain result | Contract v1 §§15,36 | ordered typed unknown reasons | runnable is false and status remains distinct |
| canonicalization failure | `schema_invalid or internal_error` | contract error | canonical JSON boundary and existing binding categories | `schema_invalid` for invalid input; `internal_error` for unexpected canonicalizer failure | classification is based on cause, never fallback |
| resolution-preview digest mismatch | `CI/gate failure; no product category` | evidence failure | deterministic exit gate | stable gate diagnostic | derivation is a pure return value; no expected digest is a SLICE-1 API input and `artifact_digest_mismatch` is forbidden here |

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

## Local verification gates

These read-only governance scripts close the SLICE-1 implementation entry
gates. They contain no product semantics and write nothing into the
repository. This section records usage only; it does not authorize
implementation, which remains NOT_AUTHORIZED until a separate explicit owner
decision.

### Documentation checker lifecycle modes

`component-manager/scripts/verify_slice1_documentation.py` requires an
explicit `--mode`:

- `--mode review` validates the immutable proposed documentation closure:
  proposed decision and scope status, exactly 0/8 owner controls checked, and
  no approval overclaim. It is used against the approved review head recorded
  in the architecture decision and its semantics are frozen.
- `--mode approved` validates the approved documentation closure: decision,
  scope and closure status APPROVED_BY_OWNER, exactly 8 owner controls with
  exactly 7/8 checked, the implementation control unchecked, implementation
  status NOT_AUTHORIZED, a valid approved review head and ISO approval date,
  plus every architecture, path, packagegraph, compatibility, selector, error
  and frozen-tree check that review mode performs.

A missing or unknown mode fails closed with one machine-readable JSON result
and a nonzero exit. No check is disabled in approved mode.

### Changed-path gate

`component-manager/scripts/verify_slice1_changed_paths.py` enforces the exact
path sets above for the future branch `slice/1-read-only-resolution-preview`.
The allowed, future and forbidden patterns are parsed from this document; the
script never invents its own allowlist. Usage:

    python3 component-manager/scripts/verify_slice1_changed_paths.py \
      --base-ref <approved-base> --head-ref HEAD --phase pre-commit

Phases: `pre-commit` inspects committed, staged, unstaged and untracked paths;
`pre-push` additionally requires a clean worktree; `exit` additionally
requires the four new package path classes and the exact named SLICE-1 exit
workflow. Unknown phase, unknown path, forbidden path, allowed/forbidden
overlap, malformed path sets, invalid refs and non-ancestor bases all fail
closed with one machine-readable JSON result and a nonzero exit.

### Local fast gate

`component-manager/scripts/run_slice1_fast_gate.py` orchestrates the existing
read-only checks in fixed fail-fast order: preflight, documentation checker in
the given mode, changed-path gate, gofmt list-only check, go vet, go test,
module integrity, schema and Contract-v1 drift guard, SLICE-1 import and
package graph guards, and worktree hygiene. Usage:

    python3 component-manager/scripts/run_slice1_fast_gate.py \
      --base-ref <approved-base> --documentation-mode approved --phase pre-push

For `pre-commit`, staged review is allowed and open changes may exist; module
integrity then defers to `pre-push`, which always requires a clean worktree
and runs the full compare. The gate uses read-only module policy (no tidy, no
downloads) and redirects every helper summary to a temporary directory outside
the repository. Unknown modes or phases fail closed; the first failing step
stops all later steps, reported as NOT_RUN in one machine-readable JSON
summary.

### Base-ref policy

The base ref for both gates is the approved documentation-closure head pinned
by the owner implementation authorization (currently the governance head on
`experiment/component-manager-poa0`). The gates verify that the base is an
ancestor of the compared head; anything else fails closed.
