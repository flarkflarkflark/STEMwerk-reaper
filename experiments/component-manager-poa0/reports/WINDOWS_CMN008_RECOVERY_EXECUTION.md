# Windows CMN-008 recovery execution

## Evidence and scope

Targeted run `29824784990` proved pinned SQLite `3.53.3`, full CMN-001 success, and the CMN-008 prerequisite through selector file flush, selector replacement, write-capable parent-directory open/flush, generation activation, and injected `kill_after_active_swap`. The child aborted as intended, but the bounded diagnostic stopped without invoking recovery.

This change is diagnostic orchestration only. It does not change Rust or Go source, the durability contract, CMN-008 case/expectation, fixtures, schemas, fault injection, selector logic, recovery implementation, or SQLite query semantics used by the product and existing matrix. The existing Rust entrypoint remains `component-manager-poa0.exe recover --root <same-case-root>`, which routes to the existing state rebuild implementation.

## Execution and validation sequence

For CMN-008 only, the diagnostic now captures pre-kill state, runs the unchanged injected kill, requires the child to have terminated with a non-zero exit, captures post-kill state, and invokes `recover` exactly once against the same case root. It requires exit zero and a structured successful result with `state=rebuilt`.

Post-recovery validation fails closed unless the selector is valid, names an existing complete generation, the generation manifest and both component receipts match their artifacts, SQLite contains exactly that active generation and two inventory rows, the recovery journal ends in `op_completed`, no incomplete generation is active, no mixed component generation is visible, no lease blocks recovery, and no stale `active.tmp` remains.

## Artifacts and push suppression

The workflow uploads `windows-rust-CMN-008-recovery-validation`, containing `summary.json`, `timeline.jsonl`, pre-kill/post-kill/post-recovery snapshots, recovery stdout/stderr and result envelope, selector/generation/journal/SQLite validations, full tree/hash evidence, and `errors.tsv`. Existing pinned-SQLite provisioning remains mandatory.

The one-use push classifier now requires parent `fa02db07a2c738c44e386bf2e13e1c4ed632a256` and permits only the workflow, the two exact diagnostic wrappers, and this report. Every other parent/path retains normal matrix semantics. A targeted native Windows Rust CMN-008 rerun is required.
