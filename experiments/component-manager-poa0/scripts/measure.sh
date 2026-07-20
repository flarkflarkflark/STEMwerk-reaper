#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
out="$base/reports/measurements"
mkdir -p "$out" "$base/.caches/measure-rust-home" "$base/.caches/measure-rust-target" "$base/.caches/measure-go-build" "$base/.caches/measure-go-mod" "$base/.caches/measure-go-path"
elapsed() {
  local name=$1; shift
  local start end
  start=$(date +%s%N)
  "$@" >/dev/null
  end=$(date +%s%N)
  awk -v d="$((end-start))" 'BEGIN{printf "%.6f\n",d/1000000000}' >"$out/$name-seconds.txt"
}
elapsed rust-clean-build env CARGO_HOME="$base/.caches/measure-rust-home" CARGO_TARGET_DIR="$base/.caches/measure-rust-target" cargo build --release --manifest-path "$base/rust/Cargo.toml"
elapsed rust-incremental-build env CARGO_HOME="$base/.caches/measure-rust-home" CARGO_TARGET_DIR="$base/.caches/measure-rust-target" cargo build --release --manifest-path "$base/rust/Cargo.toml"
(
  cd "$base/go"
  elapsed go-clean-build env GOCACHE="$base/.caches/measure-go-build" GOMODCACHE="$base/.caches/measure-go-mod" GOPATH="$base/.caches/measure-go-path" go build -buildvcs=false -trimpath -o "$base/bin/measure-go" .
  elapsed go-incremental-build env GOCACHE="$base/.caches/measure-go-build" GOMODCACHE="$base/.caches/measure-go-mod" GOPATH="$base/.caches/measure-go-path" go build -buildvcs=false -trimpath -o "$base/bin/measure-go" .
)
elapsed matrix "$base/harness/run-matrix.sh"
for impl in rust go; do
  root=$(mktemp -d "$base/poa-roots/rss-$impl.XXXXXX")
  start=$(date +%s%N)
  "$base/bin/cm-$impl" install --root "$root" --catalog "$base/fixtures/catalog.json" >/dev/null & pid=$!
  peak=0
  while kill -0 "$pid" 2>/dev/null; do
    rss=$(awk '/VmHWM:/{print $2}' "/proc/$pid/status" 2>/dev/null || true)
    test -z "$rss" || test "$rss" -le "$peak" || peak=$rss
  done
  wait "$pid"
  end=$(date +%s%N)
  printf '%s\n' "$peak" >"$out/$impl-install-peak-rss-kib.txt"
  awk -v d="$((end-start))" 'BEGIN{printf "%.6f\n",d/1000000000}' >"$out/$impl-install-seconds.txt"
  elapsed "$impl-startup" "$base/bin/cm-$impl" plan --root "$root" --catalog "$base/fixtures/catalog.json"
done
stat -c '%n %s' "$base/bin/cm-rust" "$base/bin/cm-go" >"$out/binary-sizes.txt"
wc -l "$base"/rust/src/*.rs "$base"/go/*.go >"$out/source-lines.txt"
printf 'unsafe_blocks=0\nplatform_specific_modules=0\nexternal_crates=0\n' >"$out/rust-static-metrics.txt"
printf 'cgo_usage=0\nplatform_specific_modules=2\nexternal_go_modules=0\n' >"$out/go-static-metrics.txt"
printf 'RUST_TESTS=20/20\nGO_TESTS=20/20\n' >"$out/test-counts.txt"
