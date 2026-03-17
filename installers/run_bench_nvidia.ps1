<#
PowerShell runner for NVIDIA laptop
Usage (copy to repo root and run from repo root):
  .\installers\run_bench_nvidia.ps1 -Sizes 2048,4096,8192,16384 -Iterations 20 -Reps 3 -Push

What it does:
- Creates/activates a venv at .venv
- Tries to install a matching CUDA PyTorch wheel (tries cu121, cu118, cu117, then cpu)
- Installs other deps (matplotlib)
- Runs a small CUDA inspect, then `tools/warmup.py` and `tools/stress_bench.py` for each size
- Stashes results in `tests/bench_results/` and optionally commits & pushes them
#>
param(
    [string]$Sizes = "2048,4096,8192,16384",
    [int]$Iterations = 20,
    [int]$Reps = 3,
    [switch]$Push
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $ScriptDir
$RepoRoot = Split-Path -Parent $ScriptDir
Set-Location $RepoRoot

Write-Host "Repo root: $RepoRoot"

# Ensure Python available
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    Write-Error "python not found in PATH. Install Python 3.9+ and re-run."
    exit 1
}

# Create venv
if (-not (Test-Path -Path ".venv")) {
    Write-Host "Creating venv..."
    python -m venv .venv
}

# Activate venv for this session
$activate = Join-Path $RepoRoot ".venv\Scripts\Activate.ps1"
if (Test-Path $activate) {
    Write-Host "Activating venv..."
    . $activate
} else {
    Write-Error "Activation script not found: $activate"
    exit 1
}

# Upgrade pip
Write-Host "Upgrading pip, setuptools, wheel..."
python -m pip install --upgrade pip setuptools wheel

# Try to install a CUDA-enabled torch wheel; fall back gracefully
function Try-InstallTorch([string]$index) {
    try {
        Write-Host "Attempting pip install torch torchvision (index: $index)"
        if ($index -ne '') {
            python -m pip install --upgrade --index-url $index torch torchvision
        } else {
            python -m pip install --upgrade torch torchvision
        }
        return $true
    } catch {
        Write-Warning ("Install failed for index ${index}: " + $Error[0].Exception.Message)
        return $false
    }
}

$indices = @("https://download.pytorch.org/whl/cu121", "https://download.pytorch.org/whl/cu118", "https://download.pytorch.org/whl/cu117", "")
$installed = $false
foreach ($i in $indices) {
    if (Try-InstallTorch $i) { $installed = $true; break }
}
if (-not $installed) {
    Write-Warning "Could not install torch via known indexes. You may need to install a wheel manually."
}

# Other deps
python -m pip install --upgrade matplotlib

# Small CUDA inspect (prints to console and writes to tests/bench_results/nvidia_inspect.json)
$tempPy = [System.IO.Path]::GetTempFileName() + ".py"
Set-Content -Path $tempPy -Value $inspect
python $tempPy
Remove-Item $tempPy

# Ensure bench_results directory exists
$br = Join-Path $RepoRoot 'tests\bench_results'
if (-not (Test-Path $br)) { New-Item -ItemType Directory -Path $br | Out-Null }

# Run warmup + stress for each size
# Fix: Accept both comma and space separated values for $Sizes
$sizesArr = $Sizes -replace ',', ' ' -split '\s+' | ForEach-Object { [int]$_ }
foreach ($s in $sizesArr) {
    Write-Host "Running warmup size=$s"
    python tools/warmup.py --iterations 5 --size $s
    Write-Host "Running stress size=$s iterations=$Iterations reps=$Reps"
    python tools/stress_bench.py --iterations $Iterations --size $s --reps $Reps
}

# Regenerate labeled plot if mapping present
$mapf = Join-Path $br 'device_mapping.json'
$plotData = Join-Path $br 'stress_plot_data.csv'
if (Test-Path $mapf -and (Test-Path $plotData)) {
    Write-Host "Generating labeled plot..."
    python tools/plot_with_labels.py
} elseif (Test-Path $plotData) {
    Write-Host "No device mapping found; generating default plot..."
    python tools/plot_stress_results.py
} else {
    Write-Warning "Plot data not found: $plotData. Skipping plot generation."
}

# Commit & push results if requested
if ($Push) {
    Write-Host "Staging bench results and pushing to origin..."
    git add tests/bench_results
    if ($LASTEXITCODE -ne 0) { Write-Warning "git add failed" }
    $msg = "bench: add nvidia laptop results $(Get-Date -Format o)"
    git commit -m $msg
    if ($LASTEXITCODE -ne 0) { Write-Warning "git commit likely had nothing to commit" }
    git push origin HEAD
}

Write-Host "Done. Results are in tests/bench_results/"
