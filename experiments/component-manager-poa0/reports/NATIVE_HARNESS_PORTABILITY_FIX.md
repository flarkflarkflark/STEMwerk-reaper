# POA-0 native harness portability fix

## Scope and evidence

This POA-only change follows explicitly dispatched native run
[29763370995](https://github.com/flarkflarkflark/STEMwerk-reaper/actions/runs/29763370995)
at `b178f631f7bbac456c38569601f9ccc19e28b499`. It changes only harness
portability and failure diagnostics. Production code, test IDs, expected
results, fixtures, schemas, fault injection definitions, and Rust/Go
implementation sources are unchanged.

## Root causes and fixes

- macOS stopped in the parityguard because BSD `wc -l` pads numeric output.
  `count_lines_portable` now strips whitespace, rejects empty or non-numeric
  output, and callers use numeric comparison. No GNU-only option is used.
- Windows passed MSYS `/d/...` values through to native executables. A single
  boundary layer now converts only values for the actual POA path options
  `--root` and `--catalog`, explicit native `jq` file operands, and the native
  `sqlite3` database operand. It uses `cygpath -m` only on
  MSYS/MINGW/CYGWIN; already-native paths and non-path arguments are preserved.
  Both Rust and Go wrappers use the same `invoke_native_poa` implementation.
- CMN-016 waited without a deadline for a regular file under
  `state/leases`. `wait_for_lease_file` now uses Bash's monotonic `SECONDS`
  counter with a five-second default POA test budget. Timeout is exit 124 and
  remains a failed case. The child is terminated and reaped.

The timeout diagnostic records case ID, implementation, OS/architecture,
safely quoted command, POSIX/native root mapping, active generation,
generation manifests, leases, journal and desired/status files, PID/process
state, elapsed time, the last wait condition, and the output tail. These small
text files are already covered by the workflow's `reports/results/` artifact
upload.

## Semantic freeze evidence

| Evidence | Before | After |
|---|---|---|
| Sorted frozen case IDs | `240a6b041f6a3724fb20899b3609a9542588d6595da84360a7076401273e0173` | same |
| Test-case source | `2b888952b9374d17c7527d135cf7d5866722b6b7ddddaa6533a2bdc79fc99b21` | same |
| Expected-results tree | `803a1a9e283a8cd0162cbd5a3dd643096ea0e5f1293000a7f5787701c98302ae` | same |
| Fixture tree | `6f5c0882cdcdee08635c974f1e759784fdb09c31980c835a463e06636a639b88` | same |
| Schema tree | `147ae76dea9a4cb28a329da9b2fdfc651a0087bc77d2ef5f72663eb2278a00e9` | same |
| Rust source tree | `8c4386505b3295fdd1ebbfad3c323382a83226e11d9eac0c1c7628628e6e3f2a` | same |
| Go source tree | `3eaf606e84dff94edf685c53fcec3fe6b2543532bba7174e9f931a7273ae5389` | same |
| Fault-token set | `0ec444c68bdd76a611391375e62614c301a415c4531c8bb0469bb6a2e201d20e` | same |
| Frozen manifest | `2e924b3b74bbd2b654d6caa7982062c738c37bf6d207fa0fc8787452f4b5b783` | same |

The historical manifest's whole-harness hash describes its original
orchestration snapshot. Frozen verification now accepts either that exact hash
or the exact approved portability-harness hash
`77d5d21231a020559f50e75eda0e46c73cc9ba035e447561ac6bdef947ac6e9d`;
any other harness drift fails closed. The separate parityguard additionally
pins the exact case/mode mapping and shared outcome rule.

CMN-016 remains `active run generation switch` / `active_run`. Its success
condition remains one pinned generation across emitted run stages, equal to
the generation active before the switch. Only its lease-file wait is bounded.

## Local proof

- Frozen fixture verification: PASS.
- Rust selected matrix: 20/20; summary gate 24/24.
- Go selected matrix: 20/20; summary gate 24/24.
- Lease policy: 10/10 for both selected binaries.
- Linux platform cases: 4/4 for both selected binaries.
- Mixed-generation visibility: 0.
- Portable-count tests: 6/6, including padded and invalid output.
- Windows boundary tests: 9/9, including spaces, Unicode, native slash and
  backslash paths, preserved non-path arguments, missing-file failure, and
  non-Windows no-op behavior.
- CMN-016 normal route: PASS for both selected binaries.
- Forced CMN-016 timeout: PASS; bounded failure, diagnostic present, child
  reaped.

This remains experimental POA infrastructure. It is not production runtime
policy and authorizes no product-code promotion.
