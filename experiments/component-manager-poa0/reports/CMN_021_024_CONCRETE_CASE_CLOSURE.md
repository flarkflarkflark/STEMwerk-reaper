# CMN-021..024 concrete case closure

## Scope and pre-fix audit

This bounded change closes only the missing concrete record boundaries for
CMN-021 through CMN-024. It does not change product code, platform adapters,
the frozen manifest, expectations, the verifier, lease cases, platform cases,
or CMN-001..020 semantics. It adds one isolated eight-job diagnostic; it does
not run or claim a new full normal matrix.

Run `29934682382` produced 294 selected concrete case executions:
`2*34 + 2*39 + 4*37`. The earlier 326 count included four catalog gates per
job without concrete records. The later 328 was a manual arithmetic error.
Unfiltered `matrix.tsv` rows plus lease and platform rows totalled 454 because
the selected binary was copied to both implementation aliases. Counterpart
alias rows are not selected implementation evidence.

## Contract reconstruction and root cause

| Case | Contract semantics | Existing implicit coverage | Root cause |
|---|---|---|---|
| CMN-021 stale-process-gone | A terminated process is `CONFIRMED_STALE` | LEASE-003/009 classify absent or terminated PIDs | `IMPLEMENTED_AS_SHARED_GATE_WITHOUT_CASE_BOUNDARY` |
| CMN-022 stale-pid-reuse | Same PID with different process-start identity is `CONFIRMED_STALE` | LEASE-004 performs the identity mismatch | `IMPLEMENTED_AS_SHARED_GATE_WITHOUT_CASE_BOUNDARY` |
| CMN-023 stale-unknown | Unknown identity remains `SUSPECTED_STALE` and blocks GC | LEASE-006/010 test unknown/suspected behavior | `IMPLEMENTED_AS_SHARED_GATE_WITHOUT_CASE_BOUNDARY` |
| CMN-024 frozen-fixture-verification | The frozen manifest must match its pinned SHA-256 | Strict verifier and parity gate validate frozen inputs | `IMPLEMENTED_ONLY_IN_PARITY_CHECK` |

All four were catalogued and summarized as 24/24, but `run-matrix.sh` emitted
only CMN-001..020. The summary value was hardcoded and therefore could pass
without set equality.

## Concrete implementation and record contract

Unix and Windows harnesses now invoke each case independently. Each invocation
captures a start event, completion event, expected state, actual state, PASS or
FAIL, failure step/message, and a dedicated JSON artifact. The selected
record key is `(implementation, case_id)`; duplicates, missing IDs, extra IDs,
wrong implementation labels and non-PASS results fail closed.

The common summary is derived from selected `matrix.tsv` records against the
exact catalog set CMN-001..024. Counterpart aliases are filtered by the job's
selected implementation. Timeline/probe events have no standing as case
records. `common_matrix=24/24` is emitted only when all 24 expected IDs are
present exactly once, completed and PASS.

## Tests and targeted validation

Pre-fix reproduction is 10/10: catalog 24, runner 20, all four absent,
hardcoded false-pass reproduced, and alias/probe masking rejected. Post-fix
contract tests are 20/20, including independent failure, missing/extra/
duplicate/wrong-label rejection, Rust/Go set equality and the future full
matrix formula `2*38 + 2*43 + 4*41 = 326`.

Local Rust and Go each pass 24/24 common cases, 10/10 lease cases and 4/4
Linux cases with zero mixed-generation visibility. Native closure additionally
requires diagnostic mode `cmn-021-024`: eight jobs, strict verification first,
four selected concrete records per job, and 32/32 total. Until that run passes,
the blocker remains open, the full matrix remains stale, the evidence baseline
is not frozen, formal architecture approval is deferred and Contract v1 is
not ready.
