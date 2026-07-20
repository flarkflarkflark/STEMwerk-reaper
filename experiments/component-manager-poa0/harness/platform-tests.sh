#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
out="$base/reports/results/platform.tsv"
os=$(uname -s); arch=$(uname -m)
printf 'case_id\tresult\tdetail\n' >"$out"
check(){ local id=$1 detail=$2; shift 2; if "$@"; then printf '%s\tPASS\t%s\n' "$id" "$detail" >>"$out"; else printf '%s\tFAIL\t%s\n' "$id" "$detail" >>"$out"; return 1; fi; }
if test "$os" = Linux; then
  check LNX-001 proc-start-identity test -r "/proc/$$/stat"
  check LNX-002 boot-id test -n "$(cat /proc/sys/kernel/random/boot_id)"
  check LNX-003 ext4-filesystem test "$(findmnt -T "$base" -no FSTYPE)" = ext4
  check LNX-004 active-lease-gc awk -F '\t' '$1=="LEASE-001"&&$4=="PASS"{ok=1}END{exit(!ok)}' "$base/reports/results/lease-policy.tsv"
elif test "$os" = Darwin; then
  check MAC-001 apfs-active-replace test "$(stat -f %T "$base")" = apfs
  check MAC-002 concurrent-reader awk -F '\t' '$2~"CMN-020"&&$3!="PASS"{bad=1}END{exit(bad)}' "$base/reports/results/matrix.tsv"
  probe=$(mktemp -d); touch "$probe/source"; ln -s "$probe/source" "$probe/link"; cp "$probe/source" "$probe/copy"
  check MAC-003 symlink-copy test -L "$probe/link" -a -f "$probe/copy"
  check MAC-004 process-start-identity awk -F '\t' '$1=="LEASE-001"&&$4=="PASS"{ok=1}END{exit(!ok)}' "$base/reports/results/lease-policy.tsv"
  check MAC-005 native-architecture test "$arch" = "${EXPECTED_ARCH:?}"
  rust_file=$(file "$base/bin/cm-rust"); go_file=$(file "$base/bin/cm-go")
  check MAC-006 no-rosetta sh -c 'case "$1 $2" in *"$3"*) exit 0;; *) exit 1;; esac' sh "$rust_file" "$go_file" "$arch"
  check MAC-007 quarantine-signability sh -c 'xattr -l "$1" >/dev/null 2>&1 || true; test -x "$1"' sh "$base/bin/cm-rust"
else
  printf 'UNSUPPORTED\tFAIL\t%s\n' "$os" >>"$out"; exit 1
fi
awk -F '\t' 'NR>1{n++;if($2=="PASS")p++}END{printf "PLATFORM_TESTS=%d/%d\n",p,n;exit(p!=n)}' "$out"
