#!/usr/bin/env bash

to_native_path_for_jq() {
  local input=${1:?path required}
  local kernel=${POA_UNAME_OVERRIDE:-$(uname -s)}
  case "$kernel" in
    MINGW*|MSYS*|CYGWIN*) cygpath -m "$input" ;;
    *) printf '%s\n' "$input" ;;
  esac
}

if test "${BASH_SOURCE[0]}" = "$0"; then
  test "$#" = 1 || { printf 'usage: %s path\n' "$0" >&2; exit 2; }
  to_native_path_for_jq "$1"
fi
