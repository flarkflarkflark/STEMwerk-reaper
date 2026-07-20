# Component Manager POA-0

`EXPERIMENTAL_DISPOSABLE_POA_ONLY`

This is a disposable proof of architecture, not product code. It provides no
API stability, compatibility promise, product security claim, real catalog
signing, model-license claim, installer integration, runtime integration, or
release artifact. Schemas require explicit review and a reimplementation
decision before any production use.

Both native implementations consume the same fixture catalog and expose only:
`plan`, `install`, `verify`, `state-rebuild`, `status`, `rollback`, `run-pin`,
and `recover`. Operational stdout is JSONL; human diagnostics use stderr.

Use `scripts/verify-frozen-fixtures.sh`, then
`scripts/run-native-matrix.sh <linux|macos> <x86_64|arm64>`. Windows uses
`scripts/run-native-matrix.ps1`. All mutable test state and language caches
remain inside this directory. The experimental GitHub workflow performs no
product, installer, runtime, model, release, or publication action.
