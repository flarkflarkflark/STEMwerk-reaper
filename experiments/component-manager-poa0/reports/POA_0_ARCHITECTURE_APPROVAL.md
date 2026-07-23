# POA-0 formal architecture approval

## Decision

`FORMAL_ARCHITECTURE_APPROVAL=APPROVED_WITH_NON_BLOCKING_CONTRACT_FOLLOWUPS`

Authority is corrected full native matrix run `29976687812` at head
`7519ca21dba57f01c9b3b6b0cae046e511bb8f6c`: 8/8 jobs, 326/326 concrete
selected completed results and 470/470 artifact files pass. The common-case
record contract is validated. Go is the approved shared core language with
HIGH confidence; Rust remains functionally viable reference evidence.
The evidence tables contain 486 raw result rows, exclude 160 counterpart
aliases to reach 326 selected records, and exclude 64 non-case timeline/probe
events. `CONTRACT_V1_NATIVE_GATE=READY` with no blockers.

## Criterion review

| # | Criterion | Classification | Evidence or follow-up |
|---:|---|---|---|
| 1 | One shared Go core | APPROVED | Fifteen-criterion scorecard; no dual core |
| 2 | Immutable generations | APPROVED | Install, drift and receipt cases |
| 3 | Generation-atomic activation | APPROVED_WITH_PLATFORM_SPECIFIC_CONTRACT | Native selector publication 8/8 |
| 4 | Selector publication | APPROVED_WITH_PLATFORM_SPECIFIC_CONTRACT | File flush, replace and directory contract |
| 5 | Generation compatibility | OPEN_NON_BLOCKING_FOR_CONTRACT_V1 | Policy remains `TO_BE_DEFINED` |
| 6 | Run-generation pinning | APPROVED | Native pinning and visibility cases 8/8 |
| 7 | Leases | APPROVED | LEASE-001..010 in every job |
| 8 | Process-start identity | APPROVED | Native metadata and identity comparison |
| 9 | PID reuse | APPROVED | LEASE-004 and CMN-022 |
| 10 | Rollback | APPROVED | Generation-level rollback 8/8 |
| 11 | Process-crash recovery | APPROVED | Deterministic kill/recovery cases 8/8 |
| 12 | SQLite as rebuildable state/index | APPROVED | State rebuild without artifact reinstall |
| 13 | Immutable receipts | APPROVED | Receipt identity and mutation failures |
| 14 | Fail-closed integrity | APPROVED | Integrity failures reject without fallback |
| 15 | Component independence | APPROVED | Independent install; generation activation |
| 16 | `runtime.main` boundary | OPEN_NON_BLOCKING_FOR_CONTRACT_V1 | Exact normative boundary `TO_BE_DEFINED` |
| 17 | Optional `runtime.drumsep` boundary | OPEN_NON_BLOCKING_FOR_CONTRACT_V1 | Direct Kit/Kit Split rule to define |
| 18 | Model components | OPEN_NON_BLOCKING_FOR_CONTRACT_V1 | Identity/provenance/compatibility policy needed |
| 19 | Catalog/viewmodel | OPEN_NON_BLOCKING_FOR_CONTRACT_V1 | Normative projection boundary needed |
| 20 | REAPER consumer boundary | OPEN_NON_BLOCKING_FOR_CONTRACT_V1 | Integration contract not exercised |
| 21 | Windows helper/installer boundary | OPEN_NON_BLOCKING_FOR_CONTRACT_V1 | Packaging/privilege boundary needed |
| 22 | macOS helper/pkg boundary | OPEN_NON_BLOCKING_FOR_CONTRACT_V1 | Packaging/notarization boundary needed |
| 23 | Linux helper boundary | OPEN_NON_BLOCKING_FOR_CONTRACT_V1 | Packaging/privilege boundary needed |
| 24 | Windows durability contract | APPROVED_WITH_PLATFORM_SPECIFIC_CONTRACT | Native file and directory publication |
| 25 | macOS durability contract | APPROVED_WITH_PLATFORM_SPECIFIC_CONTRACT | APFS MAC-001 and statfs contracts |
| 26 | Linux durability contract | APPROVED_WITH_PLATFORM_SPECIFIC_CONTRACT | Native Linux publication cases |
| 27 | Concrete common-case record contract | APPROVED | CMN-001..024 exact records in 8/8 jobs |
| 28 | Artifact and diagnostics contract | APPROVED | Eight valid archives, 470 files |

Counts: 14 `APPROVED`, 5
`APPROVED_WITH_PLATFORM_SPECIFIC_CONTRACT`, 9
`OPEN_NON_BLOCKING_FOR_CONTRACT_V1`, 0 `BLOCKING`, 0 `REJECTED`.

## Approved architecture decisions

### CORE-001 — Shared Go core

Status: APPROVED. Use one shared Go Component Manager core/CLI. Native Rust/Go
parity and the scorecard support Go's predetermined tie-break; Rust remains
reference evidence. Contract v1 section: Core architecture and implementation
boundary.

### STATE-001 — Rebuildable SQLite state

Status: APPROVED. SQLite contains intent, ownership, operation history and a
rebuildable index/state projection; it is not the durable content identity.
Evidence: state rebuild and integrity cases. Contract v1 section: State model.

### RECEIPT-001 — Immutable receipts

Status: APPROVED. Immutable receipts persist content identity and installation
evidence, protected by checksum validation. Evidence: receipt missing/mutated
and state-rebuild cases. Contract v1 section: Receipts and provenance.

### GEN-001 — Generation-atomic activation and rollback

Status: APPROVED. Publication and rollback select one complete generation
atomically under the platform durability contract. Evidence: activation,
rollback and recovery 8/8. Contract v1 section: Activation transaction.

### GEN-002 — No component-level active pointers

Status: APPROVED. Active state is one generation selector; independent active
component pointers are forbidden. Evidence: zero mixed-component visibility.
Contract v1 section: Active generation.

### GEN-003 — Compatible component set

Status: APPROVED. A generation contains one internally compatible component
set. The compatibility policy values remain `TO_BE_DEFINED`. Evidence:
generation manifests and mixed-set rejection. Contract v1 section: Generation
compatibility.

### PIN-001 — One pinned generation per processing run

Status: APPROVED. A processing run resolves exactly one generation and retains
it for all stages. Evidence: run-pinning cases and zero mixed references.
Contract v1 section: Run pinning.

### LEASE-001 — PID plus process-start identity

Status: APPROVED. Lease liveness identity is PID plus native process-start
identity, not PID alone. Evidence: LEASE-001..010 and LEASE-004 on macOS.
Contract v1 section: Leases and process identity.

### LEASE-002 — Unknown identity fails closed

Status: APPROVED. Unknown process identity remains suspected stale and blocks
unsafe garbage collection. Evidence: CMN-023 and lease unknown/GC cases.
Contract v1 section: Lease expiry and garbage collection.

### COMP-001 — `runtime.main` is logically required

Status: APPROVED. Every valid processing generation requires the logical
`runtime.main` capability; exact artifact mapping remains `TO_BE_DEFINED`.
Evidence: catalog and component closure. Contract v1 section: Required runtime.

### COMP-002 — `runtime.drumsep` is conditionally optional

Status: APPROVED. `runtime.drumsep` is required only for Direct Kit and Kit
Split capability sets; exact compatibility expression remains `TO_BE_DEFINED`.
Evidence: component independence model. Contract v1 section: Optional runtime.

### COMP-003 — Independent installation, compatible activation

Status: APPROVED. Components may install independently, while activation
selects a compatible complete generation. Evidence: staged installs and
generation activation. Contract v1 section: Installation and activation.

### MODEL-001 — Explicit model metadata

Status: APPROVED. Model components require identity, provenance, checksum and
compatibility metadata; concrete policy values remain `TO_BE_DEFINED`.
Evidence: shared artifact integrity model. Contract v1 section: Model artifacts.

### UI-001 — REAPER consumes a viewmodel only

Status: APPROVED. REAPER renders a Component Manager viewmodel and does not
mutate storage or infer manager state. Integration details remain open.
Evidence: component/consumer separation. Contract v1 section: Consumer API.

### PLATFORM-001 — Explicit platform durability contracts

Status: APPROVED. Windows, macOS and Linux each implement an explicit durable
publication contract with common observable semantics. Evidence: native matrix
and platform suites. Contract v1 section: Platform durability.

### CASE-001 — Concrete record standing

Status: APPROVED. A contract case is validated only by its own concrete,
selected, completed result record with expected/actual and failure evidence.
Evidence: CMN-001..024 exact set equality. Contract v1 section: Conformance.

### CLAIM-001 — Durability claim boundary

Status: APPROVED. Process-crash evidence does not imply OS-crash or power-loss
guarantees. Evidence: tested fault model. Contract v1 section: Guarantees and
non-goals.

## Non-blocking follow-ups

Contract v1 must define generation compatibility, precise runtime boundaries,
model-component policy, catalog/viewmodel and REAPER consumer contracts, and
Windows/macOS/Linux installer-helper boundaries. None invalidates the tested
architecture or blocks the native gate. Contract v1 and production schemas are
not created by this approval.
