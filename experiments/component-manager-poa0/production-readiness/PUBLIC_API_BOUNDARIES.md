# Public API boundaries and application model

Signatures are design contracts without implementations. Every method receives context.Context as its first parameter in production; it is omitted below only where the operation is pure. Typed errors carry stable codes: invalid, unauthorized, not-found, conflict, incompatible, untrusted, revoked, stale, busy, unavailable, corrupt and internal. Unknown security, compatibility, ownership or process identity always returns a fail-closed typed error.

## Interfaces

| Interface / owner | Methods | Inputs; outputs | Idempotency and transaction | Fail closed / mockability |
|---|---|---|---|---|
| CatalogService / catalog | Get(CatalogID) (Catalog,error); Refresh(RefreshRequest) (Catalog,error) | strong catalog types | Get read-only; Refresh key+journal, one acceptance transaction | reject invalid signature/sequence; yes |
| ComponentStore / component | Get(ComponentID,Version) (Component,error); List() ([]Component,error) | component values | read-only snapshot | malformed/duplicate is error; yes |
| ReceiptStore / receipt | Get(ReceiptID) (Receipt,error); Put(Receipt,OperationID) error | immutable receipt | content-idempotent atomic publish | mismatch never overwrites; yes |
| GenerationStore / generation | Get(GenerationID) (Generation,error); Put(Generation,OperationID) error | immutable generation | content-idempotent atomic publish | mixed/invalid generation rejected; yes |
| DesiredStateStore / state | Get() (DesiredState,error); CompareAndSwap(StateVersion,DesiredState,OperationID) error | state/version | CAS transaction | stale/unknown version rejected; yes |
| SelectorPublisher / state | Read() (Selector,error); Publish(Selector,ExpectedSelector,OperationID) error | selector values | durable compare-and-replace | uncertain durability is failure; yes |
| CompatibilityResolver / compatibility | Resolve(Target,Generation) (CompatibilityResult,error) | declarative facts | pure/read-only | unknown is non-runnable; yes |
| TrustVerifier / trust | Evaluate(TrustInput) (TrustDecision,error) | root/scope/time | read-only policy decision | any unknown/expired scope rejects; yes |
| SignatureVerifier / signature | Verify(Envelope,CanonicalPayload) error | bytes/envelope | pure | unlisted algorithm/signature rejects; yes |
| RevocationProvider / revocation | Current(Scope) (Snapshot,error); Evaluate(KeyID,At) (RevocationDecision,error) | scope/time | monotone state read | stale/rollback/critical deny rejects mutation; yes |
| LeaseStore / lease | Acquire(Lease,OperationID) error; Release(LeaseID,OperationID) error; List() ([]Lease,error) | lease identities | keyed, journaled atomic | unknown/suspected identity protects data; yes |
| RunPinStore / runpin | Acquire(RunPin,OperationID) error; Release(RunPinID,OperationID) error; List() ([]RunPin,error) | exact generation | keyed, journaled atomic | invalid identity/pin blocks processing/GC; yes |
| GarbageCollector / gc | Preview(GCRequest) (GCPlan,error); Execute(GCPlan,OperationID) (GCResult,error) | immutable plan | execute plan digest once, journaled | unknown reference means keep; yes |
| RecoveryService / lifecycle | Inspect(OperationID) (RecoveryPlan,error); Recover(RecoveryPlan,OperationID) error | journal/selector state | keyed recovery transaction | ambiguity preserves bytes and selector; yes |
| ViewModelService / viewmodel | Snapshot(ViewRequest) (ViewSnapshot,error); Changes(ChangeToken) (ViewChanges,error) | consumer-neutral projection | read-only versioned snapshot | unavailable/stale explicit; yes |
| HelperClient / helperprotocol | Handshake(Capabilities) (Capabilities,error); Execute(HelperRequest) (HelperResult,error) | bounded schema messages | request nonce and operation key | untrusted/version mismatch rejects; yes |
| DiagnosticSink / diagnostics | Emit(Event) error | redacted structured event | append-idempotent event ID | sink failure never becomes silent success; yes |
| Clock / clock | Now() time.Time; MonotonicElapsed(Token) Duration | no external input | read-only | rollback detectable; yes |
| Filesystem / internal/platform | Stat(Path) (Metadata,error); ReadFile(Path,Limit) ([]byte,error); AtomicPublish(PublishRequest) error; SyncParent(Path) error | confined paths | publish atomic and journal-coordinated | traversal/link/durability uncertainty rejects; yes |
| TransactionJournal / journal | Begin(OperationID,Kind) (Txn,error); Append(Txn,Entry) error; Commit(Txn) error; Incomplete() ([]Txn,error) | operation/event records | append-only transaction | first failure retained; yes |

PUBLIC_INTERFACE_COUNT=20

PUBLIC_TYPE_COUNT=68

PUBLIC_FUNCTION_COUNT=42

INTERFACE_SEGREGATION_REVIEW=PASS

OVER_ABSTRACTION_FINDINGS=none

API_BOUNDARY_STATUS=RESOLVED

## SLICE-1 pure API subset

SLICE-1 adds no service interface and implements neither `CatalogService.Refresh`
nor any store. Its exact concrete pure surface is:

- `artifact.Parse`, producing `artifact.Artifact`/`ArtifactSet`;
- `provenance.Parse`, producing untrusted provenance facts;
- `compatibility.Evaluate`, producing `compatibility.Result` from caller facts and
  importing no generation or platform probe;
- `resolution.Preview`, `resolution.CanonicalizePreview` and
  `resolution.DerivePreviewDigest`, producing `ResolutionPreview` whose closed trust
  representation can only be `UNVERIFIED`;
- the existing parsers listed in `component-manager/docs/SLICE_1_SCOPE.md`.

The names are normative future SLICE-1 symbols. No `Refresh`, store, installation,
signature verification, trust, activation or platform-probe API belongs to SLICE-1.

## Commands

All fifteen commands use a validated request, OperationID idempotency key, explicit authorization descriptor, context cancellation between atomic boundaries, bounded retry only for busy/transient errors, journal begin/events/terminal result, and structured progress events. Reuse of a key with different request digest is conflict. Each command fails closed before effects on invalid schema, privilege, trust or state.

| Command | Request → response | Privilege | Retry / error focus |
|---|---|---|---|
| InstallComponent | InstallRequest → Operation | machine/user scope write | resume same key; invalid/untrusted/conflict |
| VerifyComponent | VerifyRequest → Verification | read | repeatable; corrupt/untrusted |
| BuildGeneration | BuildRequest → Generation | state write | repeat same manifest; incompatible |
| ActivateGeneration | ActivateRequest → Selector | privileged publish where needed | recover journal; stale/conflict |
| RollbackGeneration | RollbackRequest → Selector | privileged publish where needed | recover journal; revoked/incompatible |
| RepairState | RepairRequest → RepairResult | scoped write | deterministic plan; corrupt/ambiguous |
| AcquireRunPin | PinRequest → RunPin | process identity | same key/pin; unknown identity |
| ReleaseRunPin | ReleasePinRequest → Empty | pin owner | absent is success; unauthorized |
| AcquireLease | LeaseRequest → Lease | process identity | same key/lease; suspected identity |
| ReleaseLease | ReleaseLeaseRequest → Empty | lease owner | absent is success; unauthorized |
| GarbageCollect | GCRequest → GCResult | destructive machine/user scope | plan digest once; protected/changed-state |
| EnrollTrustRoot | EnrollRequest → TrustRoot | explicit admin/user confirmation | same root+scope; scope conflict |
| RemoveTrustRoot | RemoveRequest → Empty | explicit admin/user confirmation | absent is success; would-orphan/unauthorized |
| RefreshCatalog | RefreshRequest → Catalog | catalog scope write | monotone sequence; stale/fork/untrusted |
| ImportOfflineTrustSnapshot | SnapshotRequest → Snapshot | trust state write | monotone digest; expired/rollback/untrusted |

## Queries

Queries are validated, authorized read-only snapshots with cancellation, no idempotency key, no mutation journal, and diagnostic events only on failure: GetStatus, GetActiveGeneration, GetInstalledComponents, GetAvailableComponents, GetFlowReadiness, GetOperation, GetDiagnostics, GetViewModel, ExplainCompatibility and PreviewGarbageCollection. Responses are respectively Status, Generation, ComponentPage, ComponentPage, FlowReadiness, Operation, DiagnosticPage, ViewSnapshot, CompatibilityExplanation and GCPlan. Pagination is mandatory for lists. Unknown state is returned as an explicit blocked/unknown result, never guessed.

COMMAND_COUNT=15

QUERY_COUNT=10

IDEMPOTENT_COMMAND_COUNT=15

JOURNALED_COMMAND_COUNT=15

READ_ONLY_QUERY_COUNT=10

COMMAND_MODEL_STATUS=RESOLVED
