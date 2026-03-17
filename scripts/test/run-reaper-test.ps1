#!/usr/bin/env pwsh
# Windows REAPER test launcher for STEMwerk

$ErrorActionPreference = "Stop"

Write-Host "=== STEMwerk REAPER Test (Windows) ===" -ForegroundColor Cyan

# Detect REAPER
$reaperPaths = @(
    "C:\Program Files\REAPER\reaper.exe",
    "C:\Program Files (x86)\REAPER\reaper.exe",
    "$env:LOCALAPPDATA\REAPER\reaper.exe"
)

$reaperExe = $null
foreach ($path in $reaperPaths) {
    if (Test-Path $path) {
        $reaperExe = $path
        break
    }
}

if (-not $reaperExe) {
    Write-Host "Error: REAPER not found. Please install REAPER or specify --reaper-path" -ForegroundColor Red
    exit 1
}

Write-Host "Found REAPER: $reaperExe" -ForegroundColor Green

# Activate venv if exists
$venvPath = "$PSScriptRoot\..\..\..\.venv"
if (Test-Path "$venvPath\Scripts\Activate.ps1") {
    Write-Host "Activating Python venv..." -ForegroundColor Yellow
    & "$venvPath\Scripts\Activate.ps1"
}

# Check ffmpeg
if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Host "Warning: ffmpeg not found in PATH" -ForegroundColor Yellow
}

# Run test harness
$testScript = "$PSScriptRoot\..\..\tests\reaper\run_reaper_test.py"
$filter = if ($args.Count -gt 0) { $args[0] } else { "quick" }

Write-Host "Running test suite (filter: $filter)..." -ForegroundColor Cyan
python $testScript --reaper-path $reaperExe --filter $filter
