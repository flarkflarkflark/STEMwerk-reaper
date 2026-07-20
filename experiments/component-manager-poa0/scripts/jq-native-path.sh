#!/usr/bin/env bash

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/harness-portability.sh"

to_native_path_for_jq() {
  to_native_windows_path "$1"
}

if test "${BASH_SOURCE[0]}" = "$0"; then
  test "$#" = 1 || { printf 'usage: %s path\n' "$0" >&2; exit 2; }
  to_native_path_for_jq "$1"
fi
