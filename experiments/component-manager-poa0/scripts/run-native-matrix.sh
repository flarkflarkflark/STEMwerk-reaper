#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
test "$#" -ge 2 -a "${1:-}" = --implementation || { printf 'usage: %s --implementation rust|go [verification options]\n' "$0" >&2; exit 2; }
implementation=$2; shift 2
case "$implementation" in rust|go) ;; *) printf 'unsupported implementation: %s\n' "$implementation" >&2; exit 2;; esac
case_selection=normal
if test "${1:-}" = --case-selection; then case_selection=${2:?case selection required}; shift 2; fi
case "$case_selection" in normal|cmn-021-024) ;; *) printf 'unsupported case selection: %s\n' "$case_selection" >&2; exit 2;; esac
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
if test "$case_selection" = normal; then
  harness/run-matrix.sh
else
  printf 'implementation\tcase\tresult\texitcode\terror_code\tjsonl_valid\tactive_generation\tjournal_status\treceipt_status\texpected_state\n' >reports/results/matrix.tsv
fi
scripts/common-gate-cases.sh "$implementation"
if test "$case_selection" = normal; then
  harness/lease-policy-tests.sh
  if test "$expected_os" = macos; then
    EXPECTED_ARCH="$expected_arch" POA_IMPLEMENTATION="$implementation" scripts/macos-platform-tests.sh
  else
    EXPECTED_ARCH="$expected_arch" harness/platform-tests.sh
  fi
  harness/contract-smoke.sh
fi
matrix_bad=$(awk -F '\t' 'NR>1&&$3!="PASS"{n++}END{print n+0}' reports/results/matrix.tsv)
selected_cases=$(awk -F '\t' -v impl="$implementation" 'NR>1&&$1==impl{n++}END{print n+0}' reports/results/matrix.tsv)
expected_ids=$(seq -f 'CMN-%03g' 1 24 | paste -sd, -)
test "$case_selection" = normal || expected_ids=CMN-021,CMN-022,CMN-023,CMN-024
common_summary=$(python3 scripts/common_case_contract.py --matrix reports/results/matrix.tsv --implementation "$implementation" --expected "$expected_ids" --output reports/results/common-summary.json)
test "$matrix_bad" = 0 -a "$selected_cases" = "${common_summary%/*}"
lease_summary=not_run; platform_summary=not_run
if test "$case_selection" = normal; then
  lease_bad=$(awk -F '\t' 'NR>1&&$4!="PASS"{n++}END{print n+0}' reports/results/lease-policy.tsv)
  platform_bad=$(awk -F '\t' 'NR>1&&$2!="PASS"{n++}END{print n+0}' reports/results/platform.tsv)
  test "$lease_bad" = 0 -a "$platform_bad" = 0
  lease_summary=10/10; platform_summary=PASS
fi
jq -n --arg commit "${GITHUB_SHA:-local}" --arg os "$expected_os" --arg arch "$expected_arch" --arg implementation "$implementation" --arg classification PASS_NATIVE --arg common "$common_summary" --arg lease "$lease_summary" --arg platform "$platform_summary" --argjson mixed_visibility 0 '{schema_version:1,commit:$commit,os:$os,architecture:$arch,implementation:$implementation,build:"PASS",common_matrix:$common,lease_matrix:$lease,platform:$platform,classification:$classification,mixed_component_visibility_count:$mixed_visibility}' >reports/results/native-summary.json
report_target=reports/results/NATIVE_MATRIX_RESULTS.md
test "${GITHUB_ACTIONS:-false}" = true && report_target=reports/NATIVE_MATRIX_RESULTS.md
printf '%s\n' \
  '# POA-0 native matrix result' '' \
  "- Commit: ${GITHUB_SHA:-local}" \
  "- Workflow run: ${GITHUB_RUN_ID:-local}" \
  "- Runner image: ${ImageOS:-unknown} ${ImageVersion:-unknown}" \
  "- Native OS/architecture: $expected_os / $expected_arch" \
  "- Implementation: $implementation" \
  "- Result: PASS_NATIVE, common matrix $common_summary" \
  "- Platform cases: $platform_summary" "- Lease policy: $lease_summary" \
  '- Mixed-generation visibility: 0' \
  '- Cross-build classification: not used for this result' \
  '- Final language decision: pending_native_ci until all four native jobs complete' '' \
  'This per-run report is generated in the workflow workspace and uploaded as a' \
  'small Actions artifact. Signing and notarization remain outside POA-0.' \
  >"$report_target"
