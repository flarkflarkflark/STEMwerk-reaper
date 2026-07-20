#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
matrix="$base/harness/run-matrix.sh"
test "$(grep -oE 'CMN-[0-9]{3}' "$matrix" | sort -u | wc -l)" = 20
test "$(grep -c '^names=(' "$matrix")" = 1
test "$(grep -c '^modes=(' "$matrix")" = 1
test "$(grep -c '^run_case()' "$matrix")" = 1
test "$(grep -c '^for impl in rust go;' "$matrix")" = 1
test "$(jq '.test_case_ids | length' "$base/FROZEN_FIXTURE_MANIFEST.json")" = 24
printf 'SHARED_CASE_SOURCE=yes\nSHARED_EXPECTED_RESULTS=yes\nSHARED_FIXTURES=yes\n'
