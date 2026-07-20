#!/usr/bin/env bash

normalize_numeric_count() {
  local compact
  compact=$(printf '%s' "${1-}" | tr -d '[:space:]')
  case "$compact" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%d\n' "$((10#$compact))"
}

count_lines_portable() {
  local raw
  raw=$(wc -l)
  normalize_numeric_count "$raw"
}

poa_kernel_name() {
  printf '%s\n' "${POA_UNAME_OVERRIDE:-$(uname -s)}"
}

to_native_windows_path() {
  local input=${1:?path required} kernel
  kernel=$(poa_kernel_name)
  case "$kernel" in
    MINGW*|MSYS*|CYGWIN*)
      case "$input" in
        [A-Za-z]:/*|[A-Za-z]:\\*) printf '%s\n' "$input" ;;
        *)
          command -v cygpath >/dev/null 2>&1 || {
            printf 'cygpath is required for native Windows path conversion: %s\n' "$input" >&2
            return 1
          }
          cygpath -m "$input"
          ;;
      esac
      ;;
    *) printf '%s\n' "$input" ;;
  esac
}

invoke_native_poa() {
  local executable=${1:?executable required} argument converted
  local expect_path=no
  shift
  local -a native_arguments=()
  for argument in "$@"; do
    if test "$expect_path" = yes; then
      converted=$(to_native_windows_path "$argument") || return
      native_arguments+=("$converted")
      expect_path=no
      continue
    fi
    native_arguments+=("$argument")
    case "$argument" in --root|--catalog) expect_path=yes ;; esac
  done
  test "$expect_path" = no || {
    printf 'missing path value after native POA path option\n' >&2
    return 2
  }
  MSYS_NO_PATHCONV=1 "$executable" "${native_arguments[@]}"
}

invoke_native_jq_file() {
  local path=${1:?jq file path required} native_path
  shift
  native_path=$(to_native_windows_path "$path") || return
  MSYS_NO_PATHCONV=1 jq "$@" "$native_path"
}

invoke_native_sqlite3() {
  local path=${1:?sqlite database path required} native_path
  shift
  native_path=$(to_native_windows_path "$path") || return
  MSYS_NO_PATHCONV=1 sqlite3 "$native_path" "$@"
}

write_case_wait_diagnostics() {
  local reason=$1 case_id=$2 implementation=$3 root=$4 pid=$5 output=$6 diagnostic=$7 elapsed=$8
  shift 8
  mkdir -p "$(dirname "$diagnostic")"
  {
    printf 'case_id=%s\nimplementation=%s\nreason=%s\n' "$case_id" "$implementation" "$reason"
    printf 'os=%s\narchitecture=%s\npid=%s\nelapsed_seconds=%s\n' "$(uname -s)" "$(uname -m)" "$pid" "$elapsed"
    printf 'command='
    printf '%q ' "$@"
    printf '\nroot_posix=%s\nroot_native=%s\n' "$root" "$(to_native_windows_path "$root" 2>/dev/null || printf conversion_failed)"
    printf 'last_wait_condition=regular file under state/leases\n'
    printf 'active_generation='; invoke_native_jq_file "$root/state/active" -r '.generation_id // "missing"' 2>/dev/null || printf 'missing\n'
    printf 'process_status='; ps -p "$pid" -o pid=,stat=,etime=,command= 2>/dev/null || printf 'not_running\n'
    printf '%s\n' 'generation_manifests:'
    while IFS= read -r file; do printf '%s\n' "--- $file"; tail -40 "$file"; done < <(find "$root/generations" -name generation.json -type f -print 2>/dev/null)
    printf '%s\n' 'lease_files:'
    while IFS= read -r file; do printf '%s\n' "--- $file"; tail -40 "$file"; done < <(find "$root/state/leases" -type f -print 2>/dev/null)
    printf '%s\n' 'journal_files:'
    while IFS= read -r file; do printf '%s\n' "--- $file"; tail -40 "$file"; done < <(find "$root/state/journal" -type f -print 2>/dev/null)
    printf '%s\n' 'desired_status_state:'
    for file in "$root/state/active" "$root/state/desired.json" "$root/state/status.json"; do test ! -f "$file" || { printf '%s\n' "--- $file"; tail -40 "$file"; }; done
    printf '%s\n' 'stdout_stderr_tail:'
    tail -40 "$output" 2>/dev/null || true
  } >"$diagnostic"
}

wait_for_lease_file() {
  local case_id=$1 implementation=$2 root=$3 pid=$4 output=$5 diagnostic=$6
  shift 6
  local timeout=${POA_CASE16_TIMEOUT_SECONDS:-5} started=$SECONDS elapsed
  case "$timeout" in ''|*[!0-9]*) printf 'invalid POA case wait timeout: %s\n' "$timeout" >&2; return 2 ;; esac
  test "$timeout" -gt 0 || { printf 'POA case wait timeout must be positive\n' >&2; return 2; }
  while ! find "$root/state/leases" -type f -print -quit 2>/dev/null | grep -q .; do
    elapsed=$((SECONDS - started))
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      write_case_wait_diagnostics child_exited "$case_id" "$implementation" "$root" "$pid" "$output" "$diagnostic" "$elapsed" "$@"
      return 1
    fi
    if test "$elapsed" -ge "$timeout"; then
      write_case_wait_diagnostics timeout "$case_id" "$implementation" "$root" "$pid" "$output" "$diagnostic" "$elapsed" "$@"
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.05
  done
}
