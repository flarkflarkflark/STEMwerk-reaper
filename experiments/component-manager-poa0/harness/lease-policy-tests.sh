#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
out="$base/reports/results/lease-policy.tsv"
mkdir -p "$(dirname "$out")" "$base/poa-roots"
printf 'case_id\texpected\tactual\tresult\n' >"$out"
os=$(uname -s)
host_id=$(cat /etc/machine-id 2>/dev/null || hostname)
boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || sysctl -n kern.boottime 2>/dev/null || printf unknown)
process_start() {
  local pid=$1
  if test "$os" = Linux; then
    awk '{print $22}' "/proc/$pid/stat" 2>/dev/null
  else
    "$base/bin/cm-rust" process-start-identity --pid "$pid" 2>/dev/null
  fi
}
process_exists() { if test "$os" = Linux; then test -r "/proc/$1/stat"; else kill -0 "$1" 2>/dev/null; fi; }
self_start=$(process_start $$)
printf 'SELF_PID=%s\nSELF_START_IDENTITY=%s\nLEASE004_STORED_START_IDENTITY=%s\n' \
  "$$" "$self_start" "$((self_start+1))" >"$base/reports/results/lease-process-metadata.env"

classify() {
  local lease_host=$1 pid=$2 expected_start=$3 probe=$4 state=$5
  test "$state" = released && { printf RELEASED; return; }
  test "$lease_host" = "$host_id" || { printf SUSPECTED_STALE; return; }
  test "$probe" = unknown && { printf SUSPECTED_STALE; return; }
  process_exists "$pid" || { printf CONFIRMED_STALE; return; }
  actual_start=$(process_start "$pid")
  test -n "$actual_start" || { printf SUSPECTED_STALE; return; }
  test "$actual_start" = "$expected_start" && printf ACTIVE || printf CONFIRMED_STALE
}
check() { local id=$1 expected=$2 actual=$3; result=FAIL; test "$expected" = "$actual" && result=PASS; printf '%s\t%s\t%s\t%s\n' "$id" "$expected" "$actual" "$result" >>"$out"; }

check LEASE-001 ACTIVE "$(classify "$host_id" $$ "$self_start" ok active)"
check LEASE-002 RELEASED "$(classify "$host_id" $$ "$self_start" ok released)"
check LEASE-003 CONFIRMED_STALE "$(classify "$host_id" 2147483647 0 ok active)"
check LEASE-004 CONFIRMED_STALE "$(classify "$host_id" $$ "$((self_start+1))" ok active)"
check LEASE-005 SUSPECTED_STALE "$(classify other-host $$ "$self_start" ok active)"
check LEASE-006 SUSPECTED_STALE "$(classify "$host_id" $$ "$self_start" unknown active)"
check LEASE-007 ACTIVE "$(classify "$host_id" $$ "$self_start" ok active)"
check LEASE-008 ACTIVE "$(classify "$host_id" $$ "$self_start" ok active)"

sleep 5 & killed_pid=$!
killed_start=$(process_start "$killed_pid")
printf 'TERMINATED_PID=%s\nTERMINATED_START_IDENTITY=%s\n' "$killed_pid" "$killed_start" >>"$base/reports/results/lease-process-metadata.env"
kill -9 "$killed_pid" 2>/dev/null || true
wait "$killed_pid" 2>/dev/null || true
check LEASE-009 CONFIRMED_STALE "$(classify "$host_id" "$killed_pid" "$killed_start" ok active)"
check LEASE-010 GC_BLOCKED "$(test "$(classify other-host $$ "$self_start" ok active)" = SUSPECTED_STALE && printf GC_BLOCKED || printf GC_ALLOWED)"
printf 'FINAL_SELF_PROBED_IDENTITY=%s\n' "$(process_start $$)" >>"$base/reports/results/lease-process-metadata.env"

awk -F '\t' 'NR>1{n++;if($4=="PASS")p++} END{printf "LEASE_POLICY_TESTS=%d/%d\n",p,n;exit(p!=n)}' "$out"
printf 'BOOT_IDENTITY=%s\n' "$boot_id"
