param(
  [switch] $Force
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repo = Split-Path -Parent (Split-Path -Parent $ScriptDir)
Set-Location $repo

$mapPath = Join-Path $repo 'tests\bench_results\device_mapping.json'
$readmePath = Join-Path $repo 'tests\bench_results\README.md'

$mapContent = @'
{
  "directml:0": "AMD Radeon RX 9070",
  "directml:1": "AMD Radeon 780M",
  "privateuseone:0": "AMD Radeon RX 9070",
  "privateuseone:1": "AMD Radeon 780M"
}
'@

$readmeContent = @'
# Bench results — device mapping

This folder contains benchmark outputs and plots.

Device mapping:
- directml:0 / privateuseone:0 — AMD Radeon RX 9070 (external)
- directml:1 / privateuseone:1 — AMD Radeon 780M (integrated)

Files:
- `*.csv` : merged benchmark CSVs
- `*_summary_*.json` : run summaries
- `*_plot*.png` : plots generated from runs

Usage:
- Inspect CSV/JSON for per-run medians and times.
- Use `tools/plot_with_labels.py` to regenerate plots if needed.
'@

if (-not (Test-Path (Split-Path $mapPath -Parent))) {
    New-Item -ItemType Directory -Path (Split-Path $mapPath -Parent) | Out-Null
}

if ((-not (Test-Path $mapPath)) -or $Force) {
    Write-Host "Writing device mapping to $mapPath"
    $mapContent | Set-Content -Path $mapPath -Encoding UTF8
} else {
    Write-Host "Device mapping already exists at $mapPath (use -Force to overwrite)"
}

if ((-not (Test-Path $readmePath)) -or $Force) {
    Write-Host "Writing README to $readmePath"
    $readmeContent | Set-Content -Path $readmePath -Encoding UTF8
} else {
    Write-Host "README already exists at $readmePath (use -Force to overwrite)"
}

# Ensure gh is installed and authenticated
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Error "GitHub CLI (gh) not found. Install from https://github.com/cli/cli and re-run."
    exit 1
}

try {
    gh auth status --hostname github.com | Out-Null
} catch {
    Write-Host "Not authenticated with gh — launching web login..."
    gh auth login --web
}

# Determine current branch
$branch = (git rev-parse --abbrev-ref HEAD).Trim()
Write-Host "Current branch: $branch"

git add $mapPath $readmePath
try {
    git commit -m "bench: add device mapping and bench README (RX 9070, 780M)" -q
} catch {
    Write-Host "Nothing to commit or commit failed: $_"
}

Write-Host "Pushing to origin/$branch..."
git push origin $branch

Write-Host "Done. Files written and pushed (if authenticated)."
