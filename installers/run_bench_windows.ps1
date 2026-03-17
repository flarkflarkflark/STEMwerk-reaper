# Run bench_full.py on a remote Windows laptop (NVIDIA)
# Usage: copy this file into the repo root and run from PowerShell (Admin if installing system deps)
set -e

# Change to repository directory (script location)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

# Create venv if missing
if (-Not (Test-Path .venv)) {
    python -m venv .venv
}

# Activate venv for this session



















Write-Output "Done. Results are in tests\bench_results\bench_full.json and bench_full.csv"python tools/bench_full.py# Run benchmarkif (Test-Path requirements-ci.txt) { pip install -r requirements-ci.txt }# Install project requirements if present (best-effort)}    pip install --upgrade torch torchvision torchaudio    Write-Output "Failed to install CUDA wheels from PyTorch index; falling back to CPU torch."
# fallback to CPU-only torchpip install --index-url https://download.pytorch.org/whl/cu118 --trusted-host download.pytorch.org --upgrade torch torchvision torchaudio || {Write-Output "Installing CUDA-enabled PyTorch (cu118). This may take several minutes..."# Attempt to install CUDA-enabled PyTorch (common choice: cu118 for CUDA 11.8)
# Trusted host to avoid index issuespython -m pip install --upgrade pip setuptools wheel# Upgrade pip and install basic requirements& ".\.venv\Scripts\Activate.ps1"