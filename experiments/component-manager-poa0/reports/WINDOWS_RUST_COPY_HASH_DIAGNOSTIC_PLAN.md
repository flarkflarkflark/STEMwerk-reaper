# Windows Rust Copy/Hash Narrow Diagnostic Plan

## Basis

This disposable POA-only diagnostic is based on workflow run `29768720356`, Windows Rust job `88441644613`, and read-only audit SHA256 `6be4da697bf4d106dd19c6f21ddf87569ab74d92b509e5eb78c862ed681996b6`. The observed Rust lifecycle stops after `staging_started` and before the first `artifact_verified`.

## Hypotheses and cases

CMN-001 is the minimal clean-install reproduction. CMN-008 is included only to confirm that its prerequisite install fails at the same early primitive. The diagnostic distinguishes fixture copy, external PowerShell lookup/command, path syntax, quoting, SHA output parsing, encoding, parent creation, and raw Rust error propagation.

## Instrumentation and probes

The normal product-like JSONL event stream is unchanged. A separate Windows-only script captures stdout and stderr and writes POA-only `diag_copy_begin`, `diag_copy_result`, `diag_hash_begin`, `diag_hash_result`, and `diag_failure_context` records. Probes cover native forward- and backslash paths, spaces, Unicode, NTFS and same-volume paths, newline parsing, missing input, and invalid destination parent.

## Artifacts and proof criteria

Each selected case produces one artifact containing `summary.json`, `commands.jsonl`, `stdout.log`, `stderr.log`, `jsonl.log`, `tree.tsv`, `hashes.tsv`, `environment.txt`, probe logs, and a preserved `case-root/`. A root cause is proven only when the exact command, exit code or stderr, filesystem state, and matching primitive probe agree.

## Scope declaration

This commit adds diagnostic orchestration only. It contains no functional Rust fix, changes no expectation, fixture, schema, frozen manifest, Go source, generation/durability contract, or production code, and makes no language decision.
