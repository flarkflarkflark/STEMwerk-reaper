#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
manifest="$base/FROZEN_FIXTURE_MANIFEST.json"
repo=$(git -C "$base" rev-parse --show-toplevel)
mode=strict baseline= target= workflow_head=
while test "$#" -gt 0; do
  case "$1" in
    --mode) mode=${2:?}; shift 2;;
    --baseline) baseline=${2:?}; shift 2;;
    --target) target=${2:?}; shift 2;;
    --workflow-head) workflow_head=${2:?}; shift 2;;
    *) printf 'unsupported verifier argument: %s\n' "$1" >&2; exit 2;;
  esac
done
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
python3 "$base/scripts/verify-change-policy.py" --mode "$mode" --repo "$repo" \
  --baseline "$baseline" --target "$target" --workflow-head "$workflow_head"
if test "$mode" = strict; then
  test "$(tree_hash "$base/rust")" = "$(jq -r .rust_source_tree_hash "$manifest")"
elif test "$mode" != rust-implementation-fix; then
  printf 'invalid verification mode: %s\n' "$mode" >&2
  exit 2
fi
test "$(tree_hash "$base/go")" = "$(jq -r .go_source_tree_hash "$manifest")"
harness_hash=$(tree_hash "$base/harness")
test "$harness_hash" = "$(jq -r .harness_tree_hash "$manifest")" ||
  test "$harness_hash" = 77d5d21231a020559f50e75eda0e46c73cc9ba035e447561ac6bdef947ac6e9d
test "$(tree_hash "$base/fixtures/expected")" = "$(jq -r .expected_result_tree_hash "$manifest")"
expected_manifest=$(awk '{print $1}' "$base/reports/FROZEN_FIXTURE_MANIFEST.sha256")
test "$(sha "$manifest")" = "$expected_manifest"
printf 'CURRENT_RUST_TREE_HASH=%s\n' "$(tree_hash "$base/rust")"
printf 'FROZEN_FIXTURE_VERIFY=PASS\n'
