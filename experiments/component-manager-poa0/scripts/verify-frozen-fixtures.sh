#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
manifest="$base/FROZEN_FIXTURE_MANIFEST.json"
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
tree_hash() {
  local dir=$1 list
  list=$(mktemp)
  trap 'rm -f "$list"' RETURN
  while IFS= read -r file; do rel=${file#"$dir/"}; printf '%s  %s\n' "$(sha "$file")" "$rel"; done < <(find "$dir" -type f ! -name Cargo.lock -print | LC_ALL=C sort) >"$list"
  sha "$list"
  rm -f "$list"
  trap - RETURN
}
verify_entries() { jq -r ".$1[]|[.path,.sha256]|@tsv" "$manifest" | while IFS=$'\t' read -r path expected; do test -f "$base/$path"; test "$(sha "$base/$path")" = "$expected"; done; }
verify_entries fixture_files
verify_entries schemas
test "$(tree_hash "$base/rust")" = "$(jq -r .rust_source_tree_hash "$manifest")"
test "$(tree_hash "$base/go")" = "$(jq -r .go_source_tree_hash "$manifest")"
test "$(tree_hash "$base/harness")" = "$(jq -r .harness_tree_hash "$manifest")"
test "$(tree_hash "$base/fixtures/expected")" = "$(jq -r .expected_result_tree_hash "$manifest")"
expected_manifest=$(awk '{print $1}' "$base/reports/FROZEN_FIXTURE_MANIFEST.sha256")
test "$(sha "$manifest")" = "$expected_manifest"
printf 'FROZEN_FIXTURE_VERIFY=PASS\n'
