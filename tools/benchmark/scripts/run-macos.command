#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BENCH_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PORTABLE_ROOT=${STEMWERK_BENCHMARK_ROOT:-$BENCH_DIR}
PRESET=${STEMWERK_BENCHMARK_PRESET:-smoke}
RUNNER="$BENCH_DIR/stemwerk_benchmark.py"
if [ -f "$BENCH_DIR/runner/stemwerk_benchmark.py" ]; then
  RUNNER="$BENCH_DIR/runner/stemwerk_benchmark.py"
fi

exec python3 "$RUNNER" \
  --input-dir "$PORTABLE_ROOT/audio" \
  --preset "$BENCH_DIR/presets/$PRESET.json" \
  --output-dir "$PORTABLE_ROOT/results" \
  "$@"
