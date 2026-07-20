#!/usr/bin/env bash
set -uo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
source "$base/scripts/harness-portability.sh"
results="$base/reports/results"
mkdir -p "$results" "$base/poa-roots"
summary="$results/matrix.tsv"
: >"$summary"
printf 'implementation\tcase\tresult\texitcode\terror_code\tjsonl_valid\tactive_generation\tjournal_status\treceipt_status\texpected_state\n' >>"$summary"

record() {
  local impl=$1 case_name=$2 outcome=$3 code=$4 output=$5 expected=$6 root=$7
  local json=PASS error_code active receipt journal
  invoke_native_jq_file "$output" -e -s 'all(.[];type=="object")' >/dev/null 2>&1 || json=FAIL
  error_code=$(invoke_native_jq_file "$output" -rs '[.[]|select(.error_code != null and .error_code != "")|.error_code][-1] // ""' 2>/dev/null)
  active=$(invoke_native_jq_file "$root/state/active" -r '.generation_id // ""' 2>/dev/null)
  receipt=valid
  for id in runtime.fixture model.fixture; do test -f "$root/store/components/$id/1.0.0/.stemwerk-component.json" || receipt=missing; done
  journal=missing
  test -s "$root/state/journal/operations.jsonl" && invoke_native_jq_file "$root/state/journal/operations.jsonl" -e -s 'all(.[];type=="object")' >/dev/null 2>&1 && journal=valid
  test "$journal" = valid || outcome=FAIL
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$impl" "$case_name" "$outcome" "$code" "$error_code" "$json" "$active" "$journal" "$receipt" "$expected" >>"$summary"
}
run_case() {
  local impl=$1 n=$2 name=$3 mode=$4
  local root output code=0 outcome=PASS first second pinned stages
  root=$(mktemp -d "$base/poa-roots/${impl}-${n}.XXXXXX")
  output="$results/${impl}-${n}.jsonl"
  case "$mode" in
    clean) "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >"$output" 2>/dev/null || code=$? ;;
    idem) "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >/dev/null 2>/dev/null; "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >"$output" 2>/dev/null || code=$?; receipt_count=$(find "$root/store/components" -name .stemwerk-component.json | count_lines_portable); test "$receipt_count" -eq 2 || outcome=FAIL ;;
    checksum) mkdir -p "$root/fixtures/artifacts"; cp "$base/fixtures/catalog.json" "$root/fixtures/catalog.json"; cp "$base/fixtures/artifacts/model-fixture.txt" "$root/fixtures/artifacts/runtime-fixture.txt"; cp "$base/fixtures/artifacts/model-fixture.txt" "$root/fixtures/artifacts/model-fixture.txt"; "$base/bin/cm-$impl" install --root "$root" --catalog "$root/fixtures/catalog.json" >"$output" 2>/dev/null && outcome=FAIL || code=$?; test ! -e "$root/state/active" || outcome=FAIL ;;
    cancel) POA_CANCEL=during_staging "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >"$output" 2>/dev/null && outcome=FAIL || code=$?; test ! -e "$root/state/active" || outcome=FAIL ;;
    fault_receipt) POA_FAULT=fail_after_receipt "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >"$output" 2>/dev/null && outcome=FAIL || code=$? ;;
    fault_generation) POA_FAULT=fail_after_generation_build "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >"$output" 2>/dev/null && outcome=FAIL || code=$?; test ! -e "$root/state/active" || outcome=FAIL ;;
    kill_stage) POA_FAULT=kill_during_staging "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >"$output" 2>/dev/null && outcome=FAIL || code=$?; test ! -e "$root/state/active" || outcome=FAIL ;;
    kill_swap) "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >/dev/null 2>/dev/null; first=$(invoke_native_jq_file "$root/state/active" -r .generation_id); POA_FAULT=kill_after_active_swap "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >"$output" 2>/dev/null && outcome=FAIL || code=$?; second=$(invoke_native_jq_file "$root/state/active" -r .generation_id); test "$first" != "$second" || outcome=FAIL ;;
    recover) "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >/dev/null 2>/dev/null; POA_FAULT=fail_after_active_swap_before_db_commit "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >/dev/null 2>/dev/null || true; "$base/bin/cm-$impl" recover --root "$root" >"$output" 2>/dev/null || code=$? ;;
    rollback) "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >/dev/null 2>/dev/null; first=$(invoke_native_jq_file "$root/state/active" -r .generation_id); "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >/dev/null 2>/dev/null; "$base/bin/cm-$impl" rollback --root "$root" >"$output" 2>/dev/null || code=$?; test "$(invoke_native_jq_file "$root/state/active" -r .generation_id)" = "$first" || outcome=FAIL ;;
    rebuild) "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >/dev/null 2>/dev/null; mv "$root/state/state.db" "$root/state/state.db.quarantine"; "$base/bin/cm-$impl" state-rebuild --root "$root" >"$output" 2>/dev/null || code=$?; invoke_native_sqlite3 "$root/state/state.db" 'select count(*) from inventory' | grep -qx 2 || outcome=FAIL ;;
    receipt_missing) "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >/dev/null 2>/dev/null; chmod u+w "$root/store/components/model.fixture/1.0.0"; mv "$root/store/components/model.fixture/1.0.0/.stemwerk-component.json" "$root/store/components/model.fixture/1.0.0/receipt.quarantine"; "$base/bin/cm-$impl" verify --root "$root" >"$output" 2>/dev/null && outcome=FAIL || code=$? ;;
    receipt_mutated) "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >/dev/null 2>/dev/null; chmod u+w "$root/store/components/model.fixture/1.0.0/.stemwerk-component.json"; cp "$base/fixtures/artifacts/model-fixture.txt" "$root/store/components/model.fixture/1.0.0/.stemwerk-component.json"; "$base/bin/cm-$impl" verify --root "$root" >"$output" 2>/dev/null && outcome=FAIL || code=$? ;;
    artifact_mutated) "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >/dev/null 2>/dev/null; chmod u+w "$root/store/components/model.fixture/1.0.0/model-fixture.txt"; cp "$base/fixtures/artifacts/runtime-fixture.txt" "$root/store/components/model.fixture/1.0.0/model-fixture.txt"; "$base/bin/cm-$impl" verify --root "$root" >"$output" 2>/dev/null && outcome=FAIL || code=$? ;;
    desired_missing) "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >/dev/null 2>/dev/null; mv "$root/state/desired.json" "$root/state/desired.json.quarantine"; "$base/bin/cm-$impl" status --root "$root" >"$output" 2>/dev/null && outcome=FAIL || code=$? ;;
    active_run|two_stage) "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >/dev/null 2>/dev/null; first=$(invoke_native_jq_file "$root/state/active" -r .generation_id); command=("$base/bin/cm-$impl" run-pin --root "$root" --run-id matrix --duration-ms 500); "${command[@]}" >"$output" 2>&1 & pid=$!; diagnostic="$results/diagnostic-$impl-$n.txt"; wait_rc=0; wait_for_lease_file "CMN-$(printf '%03d' "$n")" "$impl" "$root" "$pid" "$output" "$diagnostic" "${command[@]}" || wait_rc=$?; if test "$wait_rc" -ne 0; then code=$wait_rc; outcome=FAIL; else "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >/dev/null 2>/dev/null; wait "$pid" || code=$?; stages=$(invoke_native_jq_file "$output" -r 'select(.event=="run_stage")|.generation_id' | sort -u | count_lines_portable); test "$stages" -eq 1 || outcome=FAIL; test "$(invoke_native_jq_file "$output" -r 'select(.event=="run_stage")|.generation_id' | head -1)" = "$first" || outcome=FAIL; fi ;;
    lease_gc) "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >/dev/null 2>/dev/null; command=("$base/bin/cm-$impl" run-pin --root "$root" --run-id gc --duration-ms 300); "${command[@]}" >"$output" 2>&1 & pid=$!; diagnostic="$results/diagnostic-$impl-$n.txt"; wait_rc=0; wait_for_lease_file CMN-018 "$impl" "$root" "$pid" "$output" "$diagnostic" "${command[@]}" || wait_rc=$?; if test "$wait_rc" -ne 0; then code=$wait_rc; outcome=FAIL; else test -n "$(find "$root/state/leases" -type f -print -quit)" || outcome=FAIL; wait "$pid" || code=$?; fi ;;
    concurrent) "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >/dev/null 2>/dev/null; mkdir "$root/state/mutation.lock"; "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >"$output" 2>/dev/null && outcome=FAIL || code=$? ;;
    reader) "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >/dev/null 2>/dev/null; "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >"$output" 2>/dev/null & pid=$!; while kill -0 "$pid" 2>/dev/null; do a=$(invoke_native_jq_file "$root/state/active" -r .generation_id 2>/dev/null); test -z "$a" || invoke_native_jq_file "$root/generations/$a/generation.json" -e '.components|length==2' >/dev/null || outcome=FAIL; done; wait "$pid" || code=$? ;;
  esac
  test "$code" = 0 || case "$mode" in checksum|cancel|fault_receipt|fault_generation|kill_stage|kill_swap|receipt_missing|receipt_mutated|artifact_mutated|desired_missing|concurrent) :;; *) outcome=FAIL;; esac
  record "$impl" "$name" "$outcome" "$code" "$output" "$mode" "$root"
}

names=("CMN-001 clean install" "CMN-002 idempotent second install" "CMN-003 checksum mismatch" "CMN-004 cancellation during staging" "CMN-005 failure after first receipt" "CMN-006 failure after generation build" "CMN-007 kill during staging" "CMN-008 kill after active swap" "CMN-009 recovery after kill" "CMN-010 rollback" "CMN-011 state rebuild" "CMN-012 receipt missing" "CMN-013 receipt mutated" "CMN-014 artifact mutated" "CMN-015 desired missing" "CMN-016 active run generation switch" "CMN-017 two-stage generation switch" "CMN-018 GC active lease" "CMN-019 concurrent mutations" "CMN-020 no mixed component set")
modes=(clean idem checksum cancel fault_receipt fault_generation kill_stage kill_swap recover rollback rebuild receipt_missing receipt_mutated artifact_mutated desired_missing active_run two_stage lease_gc concurrent reader)
for impl in rust go; do for i in "${!names[@]}"; do run_case "$impl" "$((i+1))" "${names[$i]}" "${modes[$i]}"; done; done
awk -F '\t' 'NR>1 && $3!="PASS"{bad++} END{print "MATRIX_CASES=" NR-1; print "MATRIX_FAILURES=" bad+0; exit(bad!=0)}' "$summary"
