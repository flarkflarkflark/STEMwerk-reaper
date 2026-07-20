#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
for schema in component catalog receipt generation progress-event result status; do
  jq -e . "$base/schemas/$schema.schema.json" >/dev/null
done
jq -e '.components | length == 3' "$base/fixtures/catalog.json" >/dev/null
test "$(sha "$base/fixtures/artifacts/runtime-fixture.txt")" = a159ce98c9da7498ff385b4b799e4bac64313de699878e793654929a95e1bab5
test "$(sha "$base/fixtures/artifacts/model-fixture.txt")" = d76c207e3cb3217db5350a9c8f58daeac9ff845f5a368d3583df2e05d2f36fcf
for impl in rust go; do
  test -x "$base/bin/cm-$impl"
  "$base/bin/cm-$impl" plan --root "$base/poa-roots/smoke-$impl" --catalog "$base/fixtures/catalog.json" |
    jq -e -s 'all(.[]; type == "object") and any(.[]; .event == "plan_ready") and any(.[]; has("ok"))' >/dev/null
done
