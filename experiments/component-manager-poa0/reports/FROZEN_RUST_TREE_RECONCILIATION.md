# POA-0 frozen Rust-tree reconciliation

## Scope and trigger

Full normal native matrix run `29839224241` expanded all eight workload jobs
at `40fac56be402514ed28bcacb96837f75b79f6db0`. Every job stopped before build
and cases at the strict Rust-tree assertion. The checked-in manifest expected
`18c0cf3221df7a6420a60c4df711b1ee84aeacbfbba2b1c7373d7800ef602610`;
the current tree reproducibly hashes to
`71161596dcd8eed558c9107a1c8f373ab1b1e8b54a0df4c02dfc04edc3bf124a`.
The verifier correctly failed closed and is not weakened by this change.

## Generator contract

The authoritative generator is `scripts/generate-frozen-manifest.sh`, version
`freeze-manifest-v1`. Its Rust root is `rust/`. It recursively includes regular
files, excludes files named `Cargo.lock`, sorts native paths with `LC_ALL=C`,
hashes each file's exact bytes with SHA-256, writes `<hash><two spaces><relative
path><LF>` for every entry, and hashes that list. Unix relative paths use `/`;
the PowerShell verifier explicitly normalizes `\` to `/`. File modes and
symlinks are not included (`find -type f`). Manual hash edits are forbidden.

The original manifest was created by freeze commit
`8753d484a7a618ed8b9a36429102a2570a2645a7`; its Rust tree reproduces the old
hash exactly. The same algorithm at current head reproduces the new hash
exactly. Only `rust/Cargo.toml` and `rust/src/main.rs` contribute changed bytes;
`rust/Cargo.lock` changed at the first fix but is explicitly excluded.

## Authorized drift and evidence chain

| Commit | Parent | Included Rust paths | Purpose | Local validation | Targeted native evidence |
|---|---|---|---|---|---|
| `ec14fdf523524bbd9aec34d429f0b6a5b673a701` | `9bf06029f2c1b24db0fd4e680f8d8e2e289dcd6b` | `Cargo.toml`, `src/main.rs` | in-process SHA-256 | Rust/Go regressions PASS | `29788593883`: hash path observed PASS; downstream durability failure |
| `c39fccea75cbf59ce1d06dfe7a3ef72e602b116c` | `8a90aee67518e423bc34bd6079b61e0f29f39c2b` | `src/main.rs` | locate Windows activation failure | focused diagnostics PASS | `29789679479`: directory-open root cause isolated |
| `71e32f358b317da1153fdfbf9e59303ed0afb1fb` | `c39fccea75cbf59ce1d06dfe7a3ef72e602b116c` | `src/main.rs` | Windows directory-handle semantics | native helper 22/23 with expected downstream sync failure | `29791206769`: open PASS, sync root cause isolated |
| `adac9e37b76f374dd39fb67d41b3f73b70231e49` | `71e32f358b317da1153fdfbf9e59303ed0afb1fb` | `src/main.rs` | probe selector durability primitives | probe suite PASS | `29794395506`: 18 probes completed; write-capable flush candidate PASS |
| `46f18ae8331b84e180bd00e29b9fcb882c8a25c0` | `adac9e37b76f374dd39fb67d41b3f73b70231e49` | `src/main.rs` | implement bounded Windows selector durability | Rust format/check/test/clippy PASS | `29799444700`, `29829519155`, `29831975430`: durability and recovery PASS; extended Rust regression PASS |
| `40fac56be402514ed28bcacb96837f75b79f6db0` | `a28dea9393296621ab3297a689be0e0920d13609` | `src/main.rs` | native macOS process-start identity | Rust 26/26 and shared lease regressions PASS | `29836548918`: LEASE-001..010 PASS including LEASE-004 |

The history is linear. The first invalidating hash change is `ec14fdf…`.
Every current included byte is the result of these reviewed commits; there are
zero unauthorized paths and zero unexplained byte differences. The missing
evidence is only the full matrix that this reconciliation is intended to
unblock; changed paths already have targeted native evidence.

## Decision and validation

Classification:
`LEGITIMATE_AUTHORIZED_POST_FREEZE_DRIFT`, confidence `HIGH`. Regeneration is
authorized because both hashes reproduce, all drift is authorized and
reviewed, the generator and strict verifier are unchanged, and cases,
expectations, fixtures, schemas, fault injections, and contracts retain their
semantics. The existing generator regenerates the expected tree fields and
top-manifest SHA from the current authorized head; no hash is entered manually.

The regenerated manifest records Rust hash
`71161596dcd8eed558c9107a1c8f373ab1b1e8b54a0df4c02dfc04edc3bf124a`
and top-manifest hash
`ea98424ac9350b835c8a3509046baf54a45d43e27c2252fd482a49b179b22b37`.
The generator also refreshed the Go and harness expected hashes directly from
their already-authorized HEAD bytes; neither source tree was edited during
reconciliation. Fixtures, schemas, case IDs and expected-result hash remained
byte-identical.

The complete strict verifier passed on the current tree. Fifteen of fifteen
reconciliation guards passed: Rust byte/new/deleted-file drift, Go drift,
fixture, expectation, schema, fault, harness, unknown path, and the old Rust
hash were rejected; filemode remained excluded as specified; and two immediate
generator executions produced byte-identical manifest and SHA output. The
policy regression suite passed 20/20.

Both implementations built locally. The unchanged common matrix passed 24/24
per implementation (20 executable common cases plus the four lease-backed
common contract IDs), the shared lease suite passed 10/10, Linux platform
checks passed 4/4, Rust unit tests passed 26/26, Go tests passed, and
mixed-generation visibility failures were zero. The normal eight-job matrix
remains required after this governance commit; this report does not itself
claim full-matrix validation.

The push classifier is changed only for a push whose parent is exactly
`40fac56be402514ed28bcacb96837f75b79f6db0` and whose non-empty path set is a
subset of this workflow, the generated manifest, its generated SHA file, and
this report. Any other parent or path expands the normal push matrix. Manual
dispatch and PR behavior are unchanged.
