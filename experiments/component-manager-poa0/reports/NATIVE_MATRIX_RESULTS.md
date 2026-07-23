# POA-0 corrected native matrix results

## Authoritative result

The sole authoritative full native matrix is workflow-dispatch run
`29976687812`, attempt 1, on branch `experiment/component-manager-poa0` at
head `7519ca21dba57f01c9b3b6b0cae046e511bb8f6c`. Diagnostic mode was `normal`.
All eight native jobs and all eight strict verifiers passed.

| Platform | Implementation | Job ID | Common | Lease | Platform | Concrete total | Artifact files |
|---|---|---:|---:|---:|---:|---:|---:|
| Linux x86_64 | Rust | `89109864046` | 24 | 10 | 4 | 38 | 55 |
| Linux x86_64 | Go | `89109864080` | 24 | 10 | 4 | 38 | 55 |
| Windows x86_64 | Rust | `89109864031` | 24 | 10 | 9 | 43 | 54 |
| Windows x86_64 | Go | `89109864048` | 24 | 10 | 9 | 43 | 54 |
| macOS Intel x86_64 | Rust | `89109864033` | 24 | 10 | 7 | 41 | 63 |
| macOS Intel x86_64 | Go | `89109864037` | 24 | 10 | 7 | 41 | 63 |
| macOS arm64 | Rust | `89109864059` | 24 | 10 | 7 | 41 | 63 |
| macOS arm64 | Go | `89109864030` | 24 | 10 | 7 | 41 | 63 |

The authoritative metric is the sum of concrete, unique, selected and
completed case-result records per job. Three independent reconstructions give
`38+38+43+43+41+41+41+41 = 326`; all 326 results are PASS, with zero FAIL or
NOT_RUN. Raw tables contain 486 rows. Exactly 160 counterpart-alias rows are
excluded, leaving 326 selected result rows. The 64 common-case timeline events
are non-case evidence and are not counted.

CMN-001..024 are exact in every job. Common set equality and record-derived
24/24 summaries pass 8/8; missing, extra and duplicate records are zero.
CMN-021..024 each pass 8/8. Targeted run `29941607856` remains closure evidence
only and is not the full baseline.

Durability, process-crash recovery, rollback, leases, run pinning, fail-closed
behavior and mixed-generation visibility pass on all eight combinations.
macOS MAC-001 and LEASE-004 pass 4/4. Intel uses `statfs$INODE64`; arm64 uses
`statfs`; both use statfs layout size 2168, alignment 8 and offsets 72/88/1112.
Rust and Go have no case-result divergence. The eight archives contain 470
valid files, with zero missing or invalid files.

## Erratum

- `328` was a manual arithmetic error.
- The pre-closure apparent `326` included hardcoded phantom common-summary
  cases and was not a concrete record total.
- `294` was the correct concrete total for historical pre-closure run
  `29934682382`; it is not current evidence.
- The current `326` is the validated concrete selected completed total from
  run `29976687812` after CMN-021..024 gained independent result records.

## Governance outcome and limits

Go is approved with HIGH confidence under the fifteen-criterion scorecard;
Rust remains functionally viable reference evidence. Formal architecture
approval is `APPROVED_WITH_NON_BLOCKING_CONTRACT_FOLLOWUPS`, and
`CONTRACT_V1_NATIVE_GATE=READY` with no blockers.

The matrix proves process-crash behavior under the tested filesystems and
runner environments. It does not prove OS-crash or power-loss durability,
production packaging, installer behavior, REAPER integration or final model
policy. Contract v1 and production code remain unwritten.
