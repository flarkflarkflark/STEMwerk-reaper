#!/usr/bin/env bash
set -euo pipefail

base=$(cd "$(dirname "$0")/.." && pwd)
source "$base/scripts/harness-portability.sh"

passed=0
check() { "$@"; passed=$((passed + 1)); }

check test "$(printf '' | count_lines_portable)" = 0
check test "$(printf 'one\n' | count_lines_portable)" = 1
check test "$(printf 'one\ntwo\nthree\n' | count_lines_portable)" = 3
check test "$(normalize_numeric_count '   20  ')" = 20
if normalize_numeric_count '2x' >/dev/null 2>&1; then exit 1; else passed=$((passed + 1)); fi
check test "$(printf 'unterminated' | count_lines_portable)" = 0
printf 'PORTABLE_COUNT_TESTS=%d/6\n' "$passed"

path_passed=0
cygpath() {
  test "$1" = -m
  case "$2" in
    /d/*) printf 'D:/%s\n' "${2#/d/}" ;;
    *) return 1 ;;
  esac
}
export -f cygpath
export POA_UNAME_OVERRIDE=MSYS_NT-10.0
check_path() { test "$1" = "$2"; path_passed=$((path_passed + 1)); }
check_path "$(to_native_windows_path 'D:/a/STEMwerk-reaper/STEMwerk-reaper')" 'D:/a/STEMwerk-reaper/STEMwerk-reaper'
check_path "$(to_native_windows_path '/d/a/STEMwerk')" 'D:/a/STEMwerk'
check_path "$(to_native_windows_path '/d/a/path with space')" 'D:/a/path with space'
check_path "$(to_native_windows_path '/d/a/unicodé-測試')" 'D:/a/unicodé-測試'
check_path "$(to_native_windows_path 'D:/a/STEMwerk')" 'D:/a/STEMwerk'
check_path "$(to_native_windows_path 'D:\a\STEMwerk')" 'D:\a\STEMwerk'

capture=$(mktemp)
fake_native() { printf '%s\n' "$@" >"$capture"; }
export -f fake_native
invoke_native_poa fake_native plan --root /d/a/root --catalog '/d/a/catalog with space.json' --run-id /d/not-a-path-option
mapfile -t captured <"$capture"
test "${captured[0]}" = plan
test "${captured[1]}" = --root
test "${captured[2]}" = D:/a/root
test "${captured[3]}" = --catalog
test "${captured[4]}" = 'D:/a/catalog with space.json'
test "${captured[5]}" = --run-id
test "${captured[6]}" = /d/not-a-path-option
path_passed=$((path_passed + 1))

jq() { test "$1" = -e; test "$2" = D:/a/missing.json; return 7; }
export -f jq
missing_rc=0
invoke_native_jq_file /d/a/missing.json -e >/dev/null 2>&1 || missing_rc=$?
test "$missing_rc" -eq 7
path_passed=$((path_passed + 1))

export POA_UNAME_OVERRIDE=Linux
check_path "$(to_native_windows_path '/d/a/STEMwerk')" '/d/a/STEMwerk'
printf 'WINDOWS_PATH_HELPER_TESTS=%d/9\n' "$path_passed"

diagnostics=$(mktemp -d)
sleep 30 & child=$!
if POA_CASE16_TIMEOUT_SECONDS=1 wait_for_lease_file CMN-016 rust "$diagnostics/root" "$child" "$diagnostics/output.jsonl" \
    "$diagnostics/diagnostic.txt" fake_native run-pin --root "$diagnostics/root"; then
  exit 1
fi
test -s "$diagnostics/diagnostic.txt"
grep -q '^case_id=CMN-016$' "$diagnostics/diagnostic.txt"
grep -q '^reason=timeout$' "$diagnostics/diagnostic.txt"
if kill -0 "$child" 2>/dev/null; then exit 1; fi
printf 'CASE16_FORCED_TIMEOUT_TEST=PASS\n'
