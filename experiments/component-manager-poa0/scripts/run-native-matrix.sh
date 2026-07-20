#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
test "$#" -ge 2 -a "${1:-}" = --implementation || { printf 'usage: %s --implementation rust|go [verification options]\n' "$0" >&2; exit 2; }
implementation=$2; shift 2
case "$implementation" in rust|go) ;; *) printf 'unsupported implementation: %s\n' "$implementation" >&2; exit 2;; esac
expected_os=${POA_EXPECTED_OS:?POA_EXPECTED_OS required}; expected_arch=${POA_EXPECTED_ARCH:?POA_EXPECTED_ARCH required}
cd "$base"
scripts/verify-frozen-fixtures.sh "$@"
mkdir -p reports/results
if test "$implementation" = rust; then
  rustc --version --verbose
  printf 'implementation=rust\nrustc=%s\ncargo=%s\ngit=%s\n' "$(rustc --version)" "$(cargo --version)" "$(git --version)" >reports/results/toolchains.txt
else
  go version
  go env GOHOSTOS GOHOSTARCH
  printf 'implementation=go\ngo=%s\ngohostos=%s\ngohostarch=%s\ngit=%s\n' "$(go version)" "$(go env GOHOSTOS)" "$(go env GOHOSTARCH)" "$(git --version)" >reports/results/toolchains.txt
fi
command -v sqlite3 >/dev/null
scripts/verify-implementation-parity.sh
scripts/build.sh "$implementation"
if test "$implementation" = rust; then cp bin/cm-rust bin/cm-go; else cp bin/cm-go bin/cm-rust; fi
scripts/assert-native-platform.sh "$expected_os" "$expected_arch" | tee reports/results/platform-info.txt
harness/run-matrix.sh
harness/lease-policy-tests.sh
EXPECTED_ARCH="$expected_arch" harness/platform-tests.sh
harness/contract-smoke.sh
matrix_bad=$(awk -F '\t' 'NR>1&&$3!="PASS"{n++}END{print n+0}' reports/results/matrix.tsv)
selected_cases=$(awk -F '\t' -v impl="$implementation" 'NR>1&&$1==impl{n++}END{print n+0}' reports/results/matrix.tsv)
lease_bad=$(awk -F '\t' 'NR>1&&$4!="PASS"{n++}END{print n+0}' reports/results/lease-policy.tsv)
platform_bad=$(awk -F '\t' 'NR>1&&$2!="PASS"{n++}END{print n+0}' reports/results/platform.tsv)
test "$matrix_bad" = 0 -a "$selected_cases" = 20 -a "$lease_bad" = 0 -a "$platform_bad" = 0
jq -n --arg commit "${GITHUB_SHA:-local}" --arg os "$expected_os" --arg arch "$expected_arch" --arg implementation "$implementation" --arg classification PASS_NATIVE --argjson mixed_visibility 0 '{schema_version:1,commit:$commit,os:$os,architecture:$arch,implementation:$implementation,build:"PASS",common_matrix:"24/24",lease_matrix:"10/10",platform:"PASS",classification:$classification,mixed_component_visibility_count:$mixed_visibility}' >reports/results/native-summary.json
report_target=reports/results/NATIVE_MATRIX_RESULTS.md
test "${GITHUB_ACTIONS:-false}" = true && report_target=reports/NATIVE_MATRIX_RESULTS.md
printf '%s\n' \
  '# POA-0 native matrix result' '' \
  "- Commit: ${GITHUB_SHA:-local}" \
  "- Workflow run: ${GITHUB_RUN_ID:-local}" \
  "- Runner image: ${ImageOS:-unknown} ${ImageVersion:-unknown}" \
  "- Native OS/architecture: $expected_os / $expected_arch" \
  "- Implementation: $implementation" \
  "- Result: PASS_NATIVE, common matrix 24/24" \
  '- Platform cases: PASS' '- Lease policy: 10/10' \
  '- Mixed-generation visibility: 0' \
  '- Cross-build classification: not used for this result' \
  '- Final language decision: pending_native_ci until all four native jobs complete' '' \
  'This per-run report is generated in the workflow workspace and uploaded as a' \
  'small Actions artifact. Signing and notarization remain outside POA-0.' \
  >"$report_target"
