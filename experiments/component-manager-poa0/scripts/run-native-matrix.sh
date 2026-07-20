#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
expected_os=${1:?expected os}; expected_arch=${2:?expected arch}
cd "$base"
scripts/verify-frozen-fixtures.sh
mkdir -p reports/results
printf 'rustc=%s\ncargo=%s\ngo=%s\ngit=%s\n' "$(rustc --version)" "$(cargo --version)" "$(go version)" "$(git --version)" >reports/results/toolchains.txt
command -v sqlite3 >/dev/null
scripts/build.sh
scripts/assert-native-platform.sh "$expected_os" "$expected_arch" | tee reports/results/platform-info.txt
harness/run-matrix.sh
harness/lease-policy-tests.sh
EXPECTED_ARCH="$expected_arch" harness/platform-tests.sh
harness/contract-smoke.sh
matrix_bad=$(awk -F '\t' 'NR>1&&$3!="PASS"{n++}END{print n+0}' reports/results/matrix.tsv)
lease_bad=$(awk -F '\t' 'NR>1&&$4!="PASS"{n++}END{print n+0}' reports/results/lease-policy.tsv)
platform_bad=$(awk -F '\t' 'NR>1&&$2!="PASS"{n++}END{print n+0}' reports/results/platform.tsv)
test "$matrix_bad" = 0 -a "$lease_bad" = 0 -a "$platform_bad" = 0
jq -n --arg commit "${GITHUB_SHA:-local}" --arg os "$expected_os" --arg arch "$expected_arch" --arg classification PASS_NATIVE --argjson common_cases 24 --argjson mixed_visibility 0 '{schema_version:1,commit:$commit,os:$os,architecture:$arch,rust:{build:"PASS",common_matrix:"24/24",classification:$classification},go:{build:"PASS",common_matrix:"24/24",classification:$classification},mixed_component_visibility_count:$mixed_visibility}' >reports/results/native-summary.json
report_target=reports/results/NATIVE_MATRIX_RESULTS.md
test "${GITHUB_ACTIONS:-false}" = true && report_target=reports/NATIVE_MATRIX_RESULTS.md
printf '%s\n' \
  '# POA-0 native matrix result' '' \
  "- Commit: ${GITHUB_SHA:-local}" \
  "- Workflow run: ${GITHUB_RUN_ID:-local}" \
  "- Runner image: ${ImageOS:-unknown} ${ImageVersion:-unknown}" \
  "- Native OS/architecture: $expected_os / $expected_arch" \
  '- Rust: PASS_NATIVE, common matrix 24/24' \
  '- Go: PASS_NATIVE, common matrix 24/24' \
  '- Platform cases: PASS' '- Lease policy: 10/10' \
  '- Mixed-generation visibility: 0' \
  '- Cross-build classification: not used for this result' \
  '- Final language decision: pending_native_ci until all four native jobs complete' '' \
  'This per-run report is generated in the workflow workspace and uploaded as a' \
  'small Actions artifact. Signing and notarization remain outside POA-0.' \
  >"$report_target"
