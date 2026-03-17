#!/usr/bin/env bash
# Run bench_full.py on Arch Linux (NVIDIA 3060)
# Usage: copy into repo root, make executable: chmod +x installers/run_bench_arch.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

# Create venv if missing
if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
. .venv/bin/activate

python -m pip install --upgrade pip setuptools wheel

# Try to install CUDA-enabled PyTorch for Linux (cu118). If it fails, fallback to CPU wheel.
echo "Installing CUDA-enabled PyTorch (cu118). This may take several minutes..."
if ! pip install --index-url https://download.pytorch.org/whl/cu118 --trusted-host download.pytorch.org --upgrade torch torchvision torchaudio; then
  echo "CUDA wheel install failed; falling back to CPU wheels"
  pip install --upgrade torch torchvision torchaudio
fi

# Install project requirements if present (best-effort)
if [ -f requirements-ci.txt ]; then
  pip install -r requirements-ci.txt || true
fi

# Run benchmark
python tools/bench_full.py

echo "Done. Results: tests/bench_results/bench_full.json and bench_full.csv"
