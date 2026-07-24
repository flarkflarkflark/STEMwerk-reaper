# Component Manager production readiness

This directory is the implementation-ready translation of approved Contract v1. Contract v1 is approved, its policy gate is READY, and its implementation blocker count is zero.

Production readiness is READY_FOR_FIRST_VERTICAL_SLICE. The production core has not started. SLICE-0 requires a separate, explicit implementation task; this gate does not authorize it. POA code is evidence and reference material only and may not be promoted directly.

## Decision index

| Concern | Document |
|---|---|
| Gate, reviews and source freeze | PRODUCTION_READINESS_GATE.md |
| Repository and Go packages | GO_PACKAGE_PLAN.md |
| Interfaces, commands and queries | PUBLIC_API_BOUNDARIES.md |
| Schema and canonical JSON | SCHEMA_BINDINGS_PLAN.md |
| Filesystem layout | STORAGE_LAYOUT_CONTRACT.md |
| Rebuildable SQLite index | SQLITE_PLAN.md |
| Native adapters | PLATFORM_ADAPTER_PLAN.md |
| Privileged helper boundary | HELPER_PROTOCOL_PLAN.md |
| Viewmodel consumer boundary | VIEWMODEL_REAPER_PLAN.md |
| Tests and future CI | TEST_AND_CI_PLAN.md |
| Implementation sequence | VERTICAL_SLICES.md |
| Authorization gates | IMPLEMENTATION_GATES.md |
| Dependency budget | DEPENDENCY_POLICY.md |
| Risks | RISK_REGISTER.md |
| First bounded implementation task | FIRST_SLICE_SCOPE.md |
| Requirement mapping | READINESS_TRACEABILITY.md |
| HYBRID roadmap and SLICE-1 architecture decision | SLICE_1_AND_ROADMAP_ARCHITECTURE_DECISION.md |

The executable proposed scope for SLICE-1 is
`component-manager/docs/SLICE_1_SCOPE.md`. It remains subject to explicit owner
approval and separate implementation authorization.

These are design records, not runtime configuration. Provisional platform paths are adapter configuration, never identities. No functional production code, database, helper, installer, signing infrastructure, network access, runtime access or consumer integration is present.
