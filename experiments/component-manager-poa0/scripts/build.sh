#!/usr/bin/env bash
set -euo pipefail
base=$(cd "$(dirname "$0")/.." && pwd)
implementation=${1:?implementation required}
case "$implementation" in rust|go) ;; *) printf 'unsupported implementation: %s\n' "$implementation" >&2; exit 2;; esac
mkdir -p "$base/bin" "$base/.caches/cargo-home" "$base/.caches/cargo-target" "$base/.caches/go-build" "$base/.caches/go-mod" "$base/.caches/go-path"
if test "$implementation" = rust; then (
  cd "$base/rust"
  env CARGO_HOME="$base/.caches/cargo-home" CARGO_TARGET_DIR="$base/.caches/cargo-target" cargo test
  env CARGO_HOME="$base/.caches/cargo-home" CARGO_TARGET_DIR="$base/.caches/cargo-target" cargo build --release
  cp "$base/.caches/cargo-target/release/component-manager-poa0" "$base/bin/cm-rust"
); else (
  cd "$base/go"
  env GOCACHE="$base/.caches/go-build" GOMODCACHE="$base/.caches/go-mod" GOPATH="$base/.caches/go-path" go test ./...
  env GOCACHE="$base/.caches/go-build" GOMODCACHE="$base/.caches/go-mod" GOPATH="$base/.caches/go-path" go build -buildvcs=false -trimpath -o "$base/bin/cm-go" .
); fi
