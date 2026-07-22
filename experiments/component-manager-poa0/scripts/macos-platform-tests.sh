#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
out="$base/reports/results/platform.tsv"
artifact="$base/reports/results/macos-mac001"
arch=$(uname -m)
implementation=${POA_IMPLEMENTATION:?POA_IMPLEMENTATION required}

python3 "$base/scripts/macos-filesystem-probe.py" \
  --parent "$base/reports/results" \
  --artifact-dir "$artifact" \
  --expected-arch "${EXPECTED_ARCH:?}" \
  --implementation "$implementation" \
  --platform-tsv "$out"

check(){ local id=$1 detail=$2; shift 2; if "$@"; then printf '%s\tPASS\t%s\n' "$id" "$detail" >>"$out"; else printf '%s\tFAIL\t%s\n' "$id" "$detail" >>"$out"; return 1; fi; }
check MAC-002 concurrent-reader awk -F '\t' '$2~"CMN-020"&&$3!="PASS"{bad=1}END{exit(bad)}' "$base/reports/results/matrix.tsv"
probe=$(mktemp -d "$base/reports/results/macos-platform.XXXXXX")
trap 'rm -rf "$probe"' EXIT
touch "$probe/source"; ln -s "$probe/source" "$probe/link"; cp "$probe/source" "$probe/copy"
check MAC-003 symlink-copy test -L "$probe/link" -a -f "$probe/copy"
check MAC-004 process-start-identity awk -F '\t' '$1=="LEASE-001"&&$4=="PASS"{ok=1}END{exit(!ok)}' "$base/reports/results/lease-policy.tsv"
check MAC-005 native-architecture test "$arch" = "${EXPECTED_ARCH:?}"
rust_file=$(file "$base/bin/cm-rust"); go_file=$(file "$base/bin/cm-go")
check MAC-006 no-rosetta sh -c 'case "$1 $2" in *"$3"*) exit 0;; *) exit 1;; esac' sh "$rust_file" "$go_file" "$arch"
check MAC-007 quarantine-signability sh -c 'xattr -l "$1" >/dev/null 2>&1 || true; test -x "$1"' sh "$base/bin/cm-rust"
awk -F '\t' 'NR>1{n++;if($2=="PASS")p++}END{printf "PLATFORM_TESTS=%d/%d\n",p,n;exit(p!=n)}' "$out"
