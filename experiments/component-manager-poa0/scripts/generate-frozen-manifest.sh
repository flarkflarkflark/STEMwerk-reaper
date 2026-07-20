#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
manifest="$base/FROZEN_FIXTURE_MANIFEST.json"
report="$base/reports/FROZEN_FIXTURE_MANIFEST.sha256"
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
tree_hash() {
  local dir=$1 pattern=${2:-'*'} list
  list=$(mktemp)
  while IFS= read -r file; do rel=${file#"$dir/"}; printf '%s  %s\n' "$(sha "$file")" "$rel"; done < <(find "$dir" -type f -name "$pattern" ! -name Cargo.lock -print | LC_ALL=C sort) >"$list"
  value=$(sha "$list"); rm -f "$list"; printf '%s' "$value"
}
fixtures=$(for f in "$base/fixtures/catalog.json" "$base"/fixtures/artifacts/*; do jq -n --arg path "${f#"$base/"}" --arg sha256 "$(sha "$f")" '{path:$path,sha256:$sha256}'; done | jq -s .)
schemas=$(for f in "$base"/schemas/*.json; do jq -n --arg path "${f#"$base/"}" --arg sha256 "$(sha "$f")" '{path:$path,sha256:$sha256}'; done | jq -s .)
cases=$(jq '.common_case_ids' "$base/fixtures/expected/test-cases.json")
tmp=$(mktemp)
jq -n --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson fixtures "$fixtures" --argjson schemas "$schemas" --argjson cases "$cases" --arg rust "$(tree_hash "$base/rust")" --arg go "$(tree_hash "$base/go")" --arg harness "$(tree_hash "$base/harness")" --arg expected "$(tree_hash "$base/fixtures/expected")" '{schema_version:1,source_base_sha:"bfe9076f90cd9b4982fabf765e0c779a65e74c74",poa_version:"POA-0-native-transport-v1",fixture_files:$fixtures,schemas:$schemas,rust_source_tree_hash:$rust,go_source_tree_hash:$go,harness_tree_hash:$harness,test_case_ids:$cases,expected_result_tree_hash:$expected,generated_at:$generated_at,generator_version:"freeze-manifest-v1",normalization_note:"Timestamps, temporary directories, PIDs, operation IDs, generation IDs, run IDs, and log paths are normalized before semantic comparison."}' >"$tmp"
mv "$tmp" "$manifest"
printf '%s  FROZEN_FIXTURE_MANIFEST.json\n' "$(sha "$manifest")" >"$report"
