#!/usr/bin/env bash
set -euo pipefail

bin_dir=$(cd "$(dirname "$0")" && pwd)
base=$(cd "$bin_dir/.." && pwd)
implementation=$(basename "$0")
source "$base/scripts/harness-portability.sh"
invoke_native_poa "$bin_dir/$implementation.exe" "$@"
