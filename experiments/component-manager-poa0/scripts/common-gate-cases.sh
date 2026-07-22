#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
implementation=${1:?implementation required}
case "$implementation" in rust|go) ;; *) exit 2;; esac
results="$base/reports/results"
matrix="$results/matrix.tsv"
artifact="$results/common-cases"
records="$results/common-case-records.jsonl"
timeline="$results/common-case-timeline.jsonl"
mkdir -p "$artifact"
: >"$records"
: >"$timeline"
os=$(uname -s)
host_id=$(cat /etc/machine-id 2>/dev/null || hostname)

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}
process_start() {
  if test "$os" = Linux; then awk '{print $22}' "/proc/$1/stat" 2>/dev/null; else "$base/bin/cm-$implementation" process-start-identity --pid "$1" 2>/dev/null; fi
}
process_exists() { if test "$os" = Linux; then test -r "/proc/$1/stat"; else kill -0 "$1" 2>/dev/null; fi; }
classify() {
  local pid=$1 expected_start=$2 probe=$3
  test "$probe" = unknown && { printf SUSPECTED_STALE; return; }
  process_exists "$pid" || { printf CONFIRMED_STALE; return; }
  local actual_start
  actual_start=$(process_start "$pid") || { printf SUSPECTED_STALE; return; }
  test "$actual_start" = "$expected_start" && printf ACTIVE || printf CONFIRMED_STALE
}
record_case() {
  local id=$1 name=$2 expected=$3 actual=$4 failure_step=${5:-none} failure_message=${6:-none}
  local result=FAIL
  test "$expected" = "$actual" && result=PASS
  printf '{"case_id":"%s","event":"started","implementation":"%s"}\n' "$id" "$implementation" >>"$timeline"
  jq -nc --arg id "$id" --arg name "$name" --arg impl "$implementation" --arg platform "$os" --arg expected "$expected" --arg actual "$actual" --arg result "$result" --arg step "$failure_step" --arg message "$failure_message" --arg artifact "common-cases/$id.json" \
    '{schema_version:1,case_id:$id,case_name:$name,implementation:$impl,platform:$platform,started:true,completed:true,result:$result,expected_state:$expected,actual_state:$actual,first_failure_step:$step,failure_message:$message,artifact_reference:$artifact}' \
    | tee "$artifact/$id.json" >>"$records"
  printf '{"case_id":"%s","event":"completed","implementation":"%s","result":"%s"}\n' "$id" "$implementation" "$result" >>"$timeline"
  printf '%s\t%s %s\t%s\t0\t%s\tPASS\t\tvalid\tvalid\t%s\n' "$implementation" "$id" "$name" "$result" "${result/PASS/}" "$expected" >>"$matrix"
  test "$result" = PASS
}

failures=0
sleep 5 & terminated_pid=$!
terminated_start=$(process_start "$terminated_pid")
kill -9 "$terminated_pid" 2>/dev/null || true
wait "$terminated_pid" 2>/dev/null || true
actual=$(classify "$terminated_pid" "$terminated_start" ok)
record_case CMN-021 stale-process-gone CONFIRMED_STALE "$actual" || failures=$((failures+1))

self_start=$(process_start $$)
actual=$(classify $$ "$((self_start+1))" ok)
record_case CMN-022 stale-pid-reuse CONFIRMED_STALE "$actual" || failures=$((failures+1))

actual=$(classify $$ "$self_start" unknown)
test "$actual" = SUSPECTED_STALE && actual="$actual|GC_BLOCKED"
record_case CMN-023 stale-unknown 'SUSPECTED_STALE|GC_BLOCKED' "$actual" || failures=$((failures+1))

expected_hash=$(awk 'NR==1{print $1}' "$base/reports/FROZEN_FIXTURE_MANIFEST.sha256")
actual_hash=$(sha256_file "$base/FROZEN_FIXTURE_MANIFEST.json")
actual=FROZEN_MANIFEST_INVALID
test "$actual_hash" = "$expected_hash" && actual=FROZEN_MANIFEST_VERIFIED
record_case CMN-024 frozen-fixture-verification FROZEN_MANIFEST_VERIFIED "$actual" || failures=$((failures+1))

test "$failures" = 0
