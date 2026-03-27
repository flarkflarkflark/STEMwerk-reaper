#!/usr/bin/env bash
# Run bench_full.py on Arch Linux (NVIDIA 3060)
# Usage: chmod +x tools/bench/run_bench_arch.sh && ./tools/bench/run_bench_arch.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_DIR"

if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
. .venv/bin/activate

python -m pip install --upgrade pip setuptools wheel

echo "Installing CUDA-enabled PyTorch (cu118). This may take several minutes..."
if ! pip install --index-url https://download.pytorch.org/whl/cu118 --trusted-host download.pytorch.org --upgrade torch torchvision torchaudio; then
  echo "CUDA wheel install failed; falling back to CPU wheels"
  pip install --upgrade torch torchvision torchaudio
fi

if [ -f requirements-ci.txt ]; then
  pip install -r requirements-ci.txt || true
fi

python tools/bench_full.py

echo "Done. Results: tests/bench_results/bench_full.json and bench_full.csv"
