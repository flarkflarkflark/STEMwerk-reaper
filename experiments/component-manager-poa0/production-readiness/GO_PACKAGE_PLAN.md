# Go module and package plan

GO_MODULE_PATH=github.com/flarkflarkflark/STEMwerk-reaper/component-manager

The graph is layered: value packages depend only on contract; policy packages depend on value packages; application orchestration depends on interfaces; internal adapters implement those interfaces. Domain packages never import CLI, SQLite, platform or helper packages. Imports in the reverse direction are forbidden.

## Package inventory

In each row, API lists exported types/interfaces; deps are allowed internal imports; forbidden is additional to the universal ban on POA/runtime packages.

| Package | Responsibility | Public API | Internal dependencies | Forbidden dependencies | Platform | Pure | Side effect | Test boundary |
|---|---|---|---|---|---|---|---|---|
| contract | schema version and common errors | SchemaVersion, Error, ErrorCode | none | all adapters | no | yes | no | schema fixtures |
| identity | validated strong identifiers | ComponentID, GenerationID, OperationID | contract | storage, CLI | no | yes | no | property/unit |
| version | SemVer/package/model revisions | Version, Revision | contract | storage, CLI | no | yes | no | table/unit |
| digest | SHA-256 value and parsing | Digest | contract | filesystem | no | yes | no | vectors |
| canonicaljson | RFC 8785 boundary | Canonicalizer | contract | policy, storage | no | yes | no | conformance vectors |
| artifact | immutable artifact descriptions | Artifact, ArtifactSet | identity, version, digest, contract | store, CLI | no | yes | no | schema/domain |
| provenance | source and trust-domain facts | Provenance | identity, digest, contract | network, store | no | yes | no | schema/domain |
| trust | trust policy and roots | Verifier, RootStore, Decision | identity, provenance, contract | transport, SQLite | no | yes | no | policy vectors |
| signature | signature envelopes/mechanism | Verifier, Envelope | digest, canonicaljson, contract | trust policy, network | no | yes | no | crypto vectors |
| revocation | rotation/revocation policy | Provider, Evaluator, Snapshot | trust, signature, identity, contract | network transport | no | yes | no | policy matrix |
| catalog | catalog records and read-only projection; trust-aware service begins SLICE-6 | Catalog, CatalogService | component, artifact, provenance, contract; trust/revocation only from SLICE-6 | CLI, SQLite, concrete trust/revocation before SLICE-6 | no | yes | no | schema/sequence |
| component | component aggregate | Component, RuntimeRole | identity, version, artifact, provenance, contract | store, CLI | no | yes | no | invariants |
| receipt | immutable receipt aggregate | Receipt, ReceiptStore | component, artifact, digest, contract | SQLite, CLI | no | yes | no | contract store |
| generation | immutable generation aggregate | Generation, GenerationStore | component, identity, digest, contract | selector, SQLite | no | yes | no | invariants |
| compatibility | declarative compatibility over caller-supplied facts | Resolver, Result | component, contract | generation, platform probes directly | no | yes | no | target matrix |
| resolution | deterministic read-only resolution preview | ResolutionPreview, Selector, TrustRepresentation | artifact, provenance, component, catalog, compatibility, identity, digest, canonicaljson, contract | generation, trust, revocation, stores, platform, network, clock, random | no | yes | no | vertical preview |
| state | desired state and selector policy | DesiredState, Store, SelectorPublisher | generation, identity, contract | SQLite shape, CLI | no | yes | no | contract/fault |
| lifecycle | activation, rollback and recovery policy | Activator, RecoveryService | generation, state, receipt, compatibility, journal, contract | concrete adapters | no | no | no | orchestration fakes |
| lease | conservative lease policy | Lease, LeaseStore | identity, generation, clock, contract | OS calls, SQLite | no | yes | no | PID-reuse matrix |
| runpin | one-generation run pin | RunPin, RunPinStore | identity, generation, clock, contract | OS calls, SQLite | no | yes | no | lifecycle matrix |
| gc | retention and collection policy | GarbageCollector, Plan | generation, lease, runpin, receipt, clock, contract | filesystem, SQLite | no | yes | no | safety/property |
| viewmodel | stable consumer projection | Service, Snapshot, ActionID | catalog, generation, compatibility, runpin, diagnostics, contract | database rows, localization text | no | yes | no | golden contract |
| diagnostics | structured diagnostics | Sink, Event, CorrelationID | identity, contract | logger implementation | no | yes | no | redaction/golden |
| clock | injectable time boundary | Clock | none | platform/storage | no | yes | no | fake/contract |
| journal | transaction journal abstraction | TransactionJournal, Entry | identity, diagnostics, clock, contract | SQLite implementation | no | no | yes | crash contract |
| internal/app | commands, queries, orchestration | none; internal handlers | all domain interfaces | CLI details, concrete stores | no | no | yes | application fakes |
| internal/store/files | immutable file stores/selectors | none | receipt, generation, state, journal, platform | app, CLI | no | no | yes | storage contract |
| internal/store/sqlite | rebuildable index implementation | none | state, journal, diagnostics | domain policy ownership | no | no | yes | rebuild/migration |
| internal/platform | common platform contract | Filesystem, ProcessProbe | identity, contract | app policy | no | no | yes | adapter contract |
| internal/platform/linux | Linux primitives | none | internal/platform | app/store policy | yes | no | yes | Linux native |
| internal/platform/windows | Windows primitives | none | internal/platform | app/store policy | yes | no | yes | Windows native |
| internal/platform/darwin | macOS primitives | none | internal/platform | app/store policy | yes | no | yes | macOS native |
| internal/helper | versioned helper client | none | helperprotocol, internal/platform, diagnostics | policy decisions | no | no | yes | protocol fake/native |
| helperprotocol | bounded helper messages | HelperClient, Request, Result | identity, digest, contract | transport implementation | no | yes | no | schema/negative |
| internal/transport/cli | CLI decoding/rendering | none | internal/app, viewmodel, diagnostics | concrete storage | no | no | yes | command contract |

PACKAGE_COUNT=35

PURE_DOMAIN_PACKAGE_COUNT=24

SIDE_EFFECT_PACKAGE_COUNT=10

PLATFORM_PACKAGE_COUNT=3

IMPORT_CYCLE_COUNT=0

PACKAGE_PLAN_STATUS=RESOLVED

SLICE-1 also extracts `pkg/artifact` and `pkg/provenance` as the normative owners of their descriptors. Existing `pkg/catalog.Artifact` may be a temporary alias or controlled adapter only; duplicate independent artifact domain types are forbidden. SLICE-1's structural signature projection is owned by `resolution` and can represent only `UNVERIFIED`; the cryptographic `signature` package remains a SLICE-6 capability.

The apparent lifecycle package has policy composition but no I/O; all effects pass through injected interfaces. The application layer alone orders transactions. Storage implements interfaces and never owns policy. The viewmodel exposes domain projections, never database rows.
