# First production slice scope

HISTORICAL_SCOPE_RECORD=yes

CURRENT_STATUS=SLICE_0_IMPLEMENTED_AND_GATED

FIRST_SLICE_ID=SLICE-0

FIRST_SLICE_TITLE=Production skeleton and contract bindings

FIRST_SLICE_ALLOWED_PATHS=component-manager/go.mod; component-manager/go.sum only for the approved pinned dependencies; component-manager/pkg/contract/**; component-manager/pkg/identity/**; component-manager/pkg/version/**; component-manager/pkg/digest/**; component-manager/pkg/schemaversion/**; component-manager/pkg/platform/**; component-manager/pkg/component/**; component-manager/pkg/catalog/**; component-manager/internal/canonicaljson/**; component-manager/internal/schemavalidation/**; component-manager/schemas/**; component-manager/scripts/**; component-manager/docs/**; component-manager/README.md; .github/workflows/component-manager-slice0-cross-platform.yml

FIRST_SLICE_FORBIDDEN_PATHS=all experiments/component-manager-poa0 POA/evidence/contract-v1 paths; runtime/model/consumer/installer/release paths; component-manager/internal/store/**; component-manager/internal/platform/**; component-manager/internal/helper/**; component-manager/internal/app mutation handlers

FIRST_SLICE_ALLOWED_DEPENDENCIES=Go standard library by default; one pinned offline-capable JSON Schema tool and one RFC 8785 implementation only after GATE-P7 review; no SQLite, CLI, logging, syscall, network or crypto dependency

FIRST_SLICE_PRODUCTION_BEHAVIOR=read-only validation/parsing of caller-supplied bytes into strong contract types; no filesystem mutation outside test temporary directories, no network and no persistent state

FIRST_SLICE_TEST_REQUIREMENTS=gofmt/vet/test, static analysis, all relevant positive/negative schemas, RFC 8785 vectors, strong scalar property tests, generated drift, cross-platform compile, dependency/license review and proof of zero effects

FIRST_SLICE_EXIT_CRITERIA=module builds on Linux/Windows/macOS targets; selected generator/canonicalizer are pinned and reproducible offline; schema major/unknown fields/digest/ID/version fail closed; package graph acyclic; tests green; Contract v1 unchanged; no state mutation

FIRST_SLICE_MAX_COMMIT_COUNT=3

FIRST_SLICE_MAX_PUSH_COUNT=1

FIRST_SLICE_IMPLEMENTATION_AUTHORIZATION_REQUIRED=yes

FIRST_SLICE_SCOPE_STATUS=RESOLVED

FIRST_SLICE_PATH_RECORD_CORRECTED_AT_SLICE1_CLOSURE=yes; this correction records the approved SLICE-0 repository reality and grants no new implementation scope

FIRST_SLICE_READY_FOR_SEPARATE_IMPLEMENTATION_TASK=no

This file preserves the approved historical SLICE-0 scope. Implementation began at
`ea4184e6b17c7cf2e94233ccacf05bd5c8487e38`; later corrections and full-gate run
`30092525685` delivered the corrected exit evidence. GATE-P8 is PASS and XPG-001 and
XPG-002 are closed. These facts grant no SLICE-1 owner approval or implementation
authorization; no second slice may begin without its separate gates and authority.
