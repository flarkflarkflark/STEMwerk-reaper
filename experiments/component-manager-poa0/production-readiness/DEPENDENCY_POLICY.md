# Dependency budget

No dependency is added by this readiness gate. Standard library is mandatory for crypto primitives, IDs, hashing, time interfaces and simple CLI/log formatting until a demonstrated need exists.

| Category | Budget/decision | Owner and acceptance |
|---|---|---|
| Standard library | required baseline | Go maintainer; pinned Go toolchain |
| SQLite driver | one, spike required before SLICE-2 | storage/platform owners; CGO, license, native builds, crash behavior |
| JSON Schema validator/generator | at most one runtime validator plus one build tool, spike in SLICE-0 | schema owner; offline reproducibility, strictness, maintenance |
| Canonical JSON | at most one narrow RFC 8785 package, spike in SLICE-0 | security owner; vectors, dependency graph, auditability |
| CLI parser | none initially; optional one only after command surface warrants it | app owner |
| Logging | none; structured diagnostics interface plus standard encoding initially | observability owner |
| Platform syscall support | standard syscall/x packages only per adapter need | platform owner |
| Test tooling | standard testing initially; optional property/fault tools are dev-only | test owner |

EXTERNAL_DEPENDENCY_CANDIDATE_COUNT=3

REQUIRED_DEPENDENCIES=none for SLICE-0 entry; candidates become required only after their bounded gate passes

OPTIONAL_DEPENDENCIES=CLI parser, structured logging, platform syscall support and test helpers, each defaulting to standard library/no package

SPIKE_REQUIRED_DEPENDENCIES=JSON Schema validator/generator; RFC 8785 canonical JSON; SQLite driver

CGO_POLICY=TO_BE_DECIDED

SQLITE_DRIVER_DECISION=spike_required

DEPENDENCY_BUDGET_STATUS=RESOLVED

Every accepted module gets an owner, rationale, exact version/checksum, license, source/provenance/maintenance review, transitive graph and reachable-advisory assessment. Builds use go.sum and a frozen/pinned toolchain with network disabled after bootstrap. Install/generate scripts are denied unless source-reviewed and explicitly allowlisted. Trivial helpers do not justify dependencies. The SQLite spike decides pure-Go versus CGO per platform as one coherent supported policy, not accidental local behavior.
