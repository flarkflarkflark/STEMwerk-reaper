# POA-0 corrected evidence baseline

## Scope and authority

This document freezes the native POA-0 evidence needed to design Component
Manager Contract v1. It does not define that contract or authorize production
implementation. The only authoritative full matrix is run `29976687812`,
attempt 1, event `workflow_dispatch`, diagnostic mode `normal`, branch
`experiment/component-manager-poa0`, head
`7519ca21dba57f01c9b3b6b0cae046e511bb8f6c`.

Strict verification used feature baseline
`9bf06029f2c1b24db0fd4e680f8d8e2e289dcd6b` and target
`ec14fdf523524bbd9aec34d429f0b6a5b673a701`. All eight jobs, builds and strict
verifiers passed.

## Native matrix inventory

| Platform | Implementation | Runner | Job ID | Common | Lease | Platform | Total | Files |
|---|---|---|---:|---:|---:|---:|---:|---:|
| Linux x86_64 | Rust | `ubuntu-latest` | `89109864046` | 24 | 10 | 4 | 38 | 55 |
| Linux x86_64 | Go | `ubuntu-latest` | `89109864080` | 24 | 10 | 4 | 38 | 55 |
| Windows x86_64 | Rust | `windows-latest` | `89109864031` | 24 | 10 | 9 | 43 | 54 |
| Windows x86_64 | Go | `windows-latest` | `89109864048` | 24 | 10 | 9 | 43 | 54 |
| macOS Intel x86_64 | Rust | `macos-15-intel` | `89109864033` | 24 | 10 | 7 | 41 | 63 |
| macOS Intel x86_64 | Go | `macos-15-intel` | `89109864037` | 24 | 10 | 7 | 41 | 63 |
| macOS arm64 | Rust | `macos-15` | `89109864059` | 24 | 10 | 7 | 41 | 63 |
| macOS arm64 | Go | `macos-15` | `89109864030` | 24 | 10 | 7 | 41 | 63 |

## Concrete case-count contract

`matrix_case_executions_total` is the sum across jobs of concrete, unique,
selected, completed case-result records. The same case ID in another native
job is a separate execution. Verifier gates, summary-only checks, aliases and
timeline/probe events are excluded.

Three independent methods agree:

1. completed selected sum: `38+38+43+43+41+41+41+41 = 326`;
2. unique PASS case IDs per job: 326;
3. selected per-case artifact records: 326.

The raw tables contain 486 result rows. Removing 160 counterpart aliases gives
326 selected records. Separately, 64 timeline/probe rows provide event evidence
but are not cases. Therefore 326/326 selected completed executions PASS, with
zero FAIL, NOT_RUN, missing, extra or duplicate records.

CMN-001..024 are selected exactly once per job. Each common summary is derived
from selected records and exact set equality; hardcoded success occurrences
are zero. CMN-021..024 each pass 8/8 with their own start, completion,
expected/actual state, failure fields and artifact. Run `29941607856` proved
their bounded closure; run `29976687812` proves their normal-matrix integration.

## Behavioral evidence

- Durability: activation, selector flush/replace and required parent-directory
  operations pass on all eight combinations under their platform contracts.
- Recovery: deterministic process-kill and recovery cases pass 8/8.
- Rollback: generation-level rollback passes 8/8 without per-component active
  pointers.
- Leases: LEASE-001..010 pass in every job; PID plus process-start identity is
  enforced, PID reuse is stale and unknown identity remains fail closed.
- Run pinning: every processing run resolves and retains one generation; all
  combinations pass with zero mixed-generation references.
- Integrity: receipt, artifact, desired-state and generation drift cases fail
  closed without silent fallback or error suppression.
- SQLite: the database is proven rebuildable state/index; durable content
  identity resides in immutable receipts and generations.

## Platform evidence

Linux uses its native durable-publication contract and passes four platform
cases per implementation. Windows uses write-capable selector file flush,
replace and parent-directory durability primitives and passes nine platform
cases per implementation. These are explicit, non-interchangeable contracts.

All four macOS jobs pass MAC-001 on APFS with same-volume replacement, file
flushes, parent-directory open/flush, observation and cleanup. Intel resolves
`statfs$INODE64`; arm64 resolves `statfs`. Both layouts report size 2168,
alignment 8 and field offsets 72, 88 and 1112. LEASE-004 passes 4/4 and proves
native process-start identity comparison and PID-reuse handling.

Rust and Go case sets, results and artifact semantics match on Linux, Windows,
macOS Intel and macOS arm64. Cross-implementation and cross-platform semantic
divergences are zero; platform-specific syscall/symbol differences are expected
contract details, not semantic divergence.

## Artifact archive audit

| Artifact | Artifact ID | Zip bytes | Zip SHA256 | Files |
|---|---:|---:|---|---:|
| `component-manager-poa0-linux-x86_64-rust` | `8551682412` | 20759 | `b56b29a2f0f4e2bb7e3f35910f7c96b6b6edb093d55d37a2e880242d53ff9421` | 55 |
| `component-manager-poa0-linux-x86_64-go` | `8551682282` | 20343 | `b609333a0c211dc893356394e6cb8bc75dbe299e04741adefd847bc173526ab7` | 55 |
| `component-manager-poa0-windows-x86_64-rust` | `8551703379` | 20364 | `f2e6ca8af8afa4db3c945d90cd614f84c8602cd8d39ece75055b1605f14396d4` | 54 |
| `component-manager-poa0-windows-x86_64-go` | `8551710347` | 19933 | `0e2ea059092f0d96e9eac90b22175ce82f95e756ab1559d4ae3cbbced28808f3` | 54 |
| `component-manager-poa0-macos-x86_64-rust` | `8551692336` | 24104 | `412e33298022a805ae4579b62ad79fc5b8575da949c175a947be33e36033ddde` | 63 |
| `component-manager-poa0-macos-x86_64-go` | `8551690194` | 23634 | `e57af5880ad0621f6f06df681ef52374178c99dda033e7bdec71d844bde05282` | 63 |
| `component-manager-poa0-macos-arm64-rust` | `8551684671` | 24033 | `2cebdf82d800ba744e1ee8760106dcde2929d0c2064ec3aad8692dd9e6284d9f` | 63 |
| `component-manager-poa0-macos-arm64-go` | `8551685154` | 23596 | `05bc1b0ab3e12b23648ea6c7f6a3917ff1ea92fe1efc4302e132aab6e6e3a146` | 63 |

All eight archives were downloaded anew outside Git. All 470 extracted files
parse or validate according to their format; missing and invalid counts are
zero. Temporary download paths are intentionally not part of frozen evidence.

## Erratum: previous totals

`PREVIOUS_INCORRECT_TOTALS`:

- 328: manual arithmetic error.
- 326 before CMN-021..024 closure: based on a hardcoded phantom summary, not
  concrete completed records.
- 294: correct concrete count for older pre-closure run `29934682382`, but not
  the current baseline.

`CURRENT_AUTHORITATIVE_TOTAL`: 326 concrete selected completed case-result
records from run `29976687812`. This corrected 326 is independently
reconstructed after all 24 common cases gained concrete record standing; it is
not the earlier apparent 326.

## Formal outcome

Go is approved with HIGH confidence. Rust and Go are functionally equivalent;
Go wins the predetermined complexity/dependency/build/maintenance tie-break.
Rust remains reference evidence and is not disqualified.

Architecture approval is `APPROVED_WITH_NON_BLOCKING_CONTRACT_FOLLOWUPS`, with
zero blocking or rejected criteria. `CONTRACT_V1_NATIVE_GATE=READY`, blockers
none. Non-blocking work is generation compatibility policy, precise
`runtime.main` and optional `runtime.drumsep` boundaries, model-component
policy, catalog/viewmodel boundary, REAPER consumer integration and
installer/helper boundaries.

## Guarantee boundaries and non-claims

This baseline proves behavior only for the tested native runners, filesystems,
fault boundaries and POA implementation. It makes no OS-crash or power-loss
guarantee; no production performance, security, signing, notarization,
installer, helper deployment, REAPER UX, model provenance or offline model-set
claim. Contract v1, normative production schemas and the production Go core do
not yet exist.
