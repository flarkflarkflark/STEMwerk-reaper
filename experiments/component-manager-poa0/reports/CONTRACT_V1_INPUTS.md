# Component Manager Contract v1 input freeze

## Purpose and authority

This is a frozen input inventory for a future normative Contract v1 design
task. It is not Contract v1 and contains no final production schemas. Evidence
authority is run `29976687812` at head
`7519ca21dba57f01c9b3b6b0cae046e511bb8f6c`, with 326/326 concrete selected
completed results and `CONTRACT_V1_NATIVE_GATE=READY`.
The evidence has 486 raw result rows, excludes 160 counterpart aliases to
produce 326 selected rows, excludes 64 non-case timeline/probe events, and
contains 470 valid artifact files. Formal architecture approval is
`APPROVED_WITH_NON_BLOCKING_CONTRACT_FOLLOWUPS`.

Status meanings:

- `POA_VALIDATED`: behavior is supported by corrected native evidence.
- `CONTRACT_DEFINITION_REQUIRED`: normative wording/interface remains needed.
- `POLICY_DECISION_REQUIRED`: a value or policy remains `TO_BE_DEFINED`.
- `OUT_OF_SCOPE_V1`: explicitly excluded from v1.

## Frozen topic inventory

| # | Topic | Status | Frozen input or required definition |
|---:|---|---|---|
| 1 | Goals | CONTRACT_DEFINITION_REQUIRED | Define safe independent install and generation-level activation |
| 2 | Non-goals | CONTRACT_DEFINITION_REQUIRED | Include no OS-crash/power-loss claim without new evidence |
| 3 | Terminology | CONTRACT_DEFINITION_REQUIRED | Define component, artifact, receipt, generation, selector, lease and run |
| 4 | Component identity | POA_VALIDATED | Stable logical identity participates in manifests and receipts |
| 5 | Component versions | POLICY_DECISION_REQUIRED | Version syntax and ordering `TO_BE_DEFINED` |
| 6 | Artifact identity | POA_VALIDATED | Identity is content-addressed and receipt-linked |
| 7 | Checksums | POA_VALIDATED | Verify before materialization and on later integrity checks |
| 8 | Provenance | POLICY_DECISION_REQUIRED | Trust roots and provenance requirements `TO_BE_DEFINED` |
| 9 | Receipts | POA_VALIDATED | Immutable persistent content/install evidence |
| 10 | Generation manifest | POA_VALIDATED | One complete component set and immutable identity |
| 11 | Generation compatibility | POLICY_DECISION_REQUIRED | Compatibility vocabulary and resolution `TO_BE_DEFINED` |
| 12 | Desired state | POA_VALIDATED | External durable input, separate from rebuildable SQLite |
| 13 | Installed state | POA_VALIDATED | Derivable from receipts and immutable generations |
| 14 | Active generation | POA_VALIDATED | One generation selector; no component-level active pointers |
| 15 | Selector publication | POA_VALIDATED | Atomic replacement plus explicit platform durability contract |
| 16 | Activation transaction | POA_VALIDATED | Build/validate before one generation-atomic publication |
| 17 | Rollback | POA_VALIDATED | Select a previously valid complete generation |
| 18 | Recovery | POA_VALIDATED | Reconcile deterministic interrupted states and fail closed |
| 19 | SQLite rebuild | POA_VALIDATED | SQLite is rebuildable state/index, not content authority |
| 20 | Leases | POA_VALIDATED | Protect pinned generations and govern safe reclamation |
| 21 | Process identity | POA_VALIDATED | PID plus native process-start identity; unknown is fail closed |
| 22 | Run pinning | POA_VALIDATED | Resolve exactly one generation for the entire run |
| 23 | Garbage collection | POLICY_DECISION_REQUIRED | Eligibility, retention and suspected-lease policy `TO_BE_DEFINED` |
| 24 | Platform durability | CONTRACT_DEFINITION_REQUIRED | Specify separate Windows, macOS and Linux publication rules |
| 25 | Errors and fail closed | POA_VALIDATED | Structured errors; no silent fallback or suppression |
| 26 | Catalog | CONTRACT_DEFINITION_REQUIRED | Define source, schema, update and compatibility contract |
| 27 | Viewmodel | CONTRACT_DEFINITION_REQUIRED | Define manager-owned consumer projection |
| 28 | REAPER consumer contract | CONTRACT_DEFINITION_REQUIRED | Read/render viewmodel only; integration API needed |
| 29 | Helper/installer boundaries | CONTRACT_DEFINITION_REQUIRED | Privilege, packaging and ownership per platform needed |
| 30 | Diagnostics | POA_VALIDATED | Structured timelines, expected/actual, failures and artifact references |
| 31 | Schema/version migration | POLICY_DECISION_REQUIRED | Compatibility and migration policy `TO_BE_DEFINED` |
| 32 | Security/trust | POLICY_DECISION_REQUIRED | Signing, trust roots and revocation `TO_BE_DEFINED` |
| 33 | Testability | POA_VALIDATED | Deterministic faults and concrete selected result records |
| 34 | Guarantee boundaries | CONTRACT_DEFINITION_REQUIRED | State process-crash evidence and explicit non-claims |
| 35 | Concrete case-record evidence | POA_VALIDATED | Own selected completed record required for conformance |

Counts: 35 topics; 20 `POA_VALIDATED`; 9
`CONTRACT_DEFINITION_REQUIRED`; 6 `POLICY_DECISION_REQUIRED`; 0
`OUT_OF_SCOPE_V1`.

## Required policy decisions

The future contract task must resolve, without inventing values here:

1. component version syntax and ordering;
2. provenance requirements and trust roots;
3. generation/component/model compatibility vocabulary and resolution;
4. garbage-collection eligibility, retention and suspected-lease handling;
5. schema/version migration and compatibility;
6. security signing, trust and revocation policy.

Each remains `TO_BE_DEFINED`. The precise `runtime.main`, optional
`runtime.drumsep`, model-component, catalog/viewmodel, REAPER and
installer/helper boundaries also require normative contract text even where
the architectural direction is approved.

## Frozen architecture inputs

- One shared Go production core/CLI; no dual core.
- Immutable generations and receipts.
- Generation-atomic activation and rollback.
- Independent installation; compatible complete-generation activation.
- Exactly one pinned generation per processing run.
- Lease identity is PID plus process-start identity; unknown fails closed.
- `runtime.main` is logically required.
- `runtime.drumsep` is logically optional and required for Direct Kit and Kit
  Split; exact normative capability mapping is `TO_BE_DEFINED`.
- Model artifacts require identity, provenance, checksum and compatibility
  metadata; policy values are `TO_BE_DEFINED`.
- REAPER consumes a manager-owned viewmodel only.
- Concrete cases require their own selected completed result records.

## Evidence and claim boundary

Run `29976687812` provides 8/8 native jobs, 326/326 cases and 470 valid files.
It proves tested process-crash, recovery, rollback, lease, pinning, integrity
and platform-publication behavior. It does not prove OS-crash or power-loss
durability, production packaging, security policy, model provenance, REAPER
integration or production performance. Those limits must remain explicit in
Contract v1.
