#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
matrix="$base/harness/run-matrix.sh"
source "$base/scripts/jq-native-path.sh"
source "$base/scripts/harness-portability.sh"
hash_stdin() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi; }
case_count=$(grep -oE 'CMN-[0-9]{3}' "$matrix" | sort -u | count_lines_portable)
names_count=$(normalize_numeric_count "$(grep -c '^names=(' "$matrix")")
modes_count=$(normalize_numeric_count "$(grep -c '^modes=(' "$matrix")")
runner_count=$(normalize_numeric_count "$(grep -c '^run_case()' "$matrix")")
loop_count=$(normalize_numeric_count "$(grep -c '^for impl in rust go;' "$matrix")")
test "$case_count" -eq 20
test "$names_count" -eq 1
test "$modes_count" -eq 1
test "$runner_count" -eq 1
test "$loop_count" -eq 1
test "$(grep -E '^(names|modes)=' "$matrix" | hash_stdin)" = c25c64568e03df4ac993c251ae3651e4e2349b8aed8e154bb2a09cf63c5b5034
test "$(grep -E 'test "\$code"|record "\$impl"' "$matrix" | hash_stdin)" = 40b7804a27a25e13413725d2c4de67d83dbab8e2f216dd52a4cedacb273ed323
manifest_for_jq=$(to_native_path_for_jq "$base/FROZEN_FIXTURE_MANIFEST.json")
test "$(jq '.test_case_ids | length' "$manifest_for_jq")" = 24
printf 'SHARED_CASE_SOURCE=yes\nSHARED_EXPECTED_RESULTS=yes\nSHARED_FIXTURES=yes\n'
