param(
    [string]$RootDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RootDir)) {
    $RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$payloadDir = Join-Path $RootDir "payload"
$pythonDir = Join-Path $payloadDir "python"
$ffmpegDir = Join-Path $payloadDir "ffmpeg"
$wheelhouseSubdir = $env:STEMWERK_WHEELHOUSE_SUBDIR
if ([string]::IsNullOrWhiteSpace($wheelhouseSubdir)) {
    $wheelhouseSubdir = "wheels"
}
$wheelsDir = Join-Path $payloadDir $wheelhouseSubdir
$includeCuda = if ($env:STEMWERK_INCLUDE_CUDA_WHEELS) { [int]$env:STEMWERK_INCLUDE_CUDA_WHEELS } else { 1 }
$includeDirectml = if ($env:STEMWERK_INCLUDE_DIRECTML_WHEELS) { [int]$env:STEMWERK_INCLUDE_DIRECTML_WHEELS } else { 0 }
$skipWheelhouse = if ($env:STEMWERK_SKIP_WHEELHOUSE) { [int]$env:STEMWERK_SKIP_WHEELHOUSE } else { 0 }

$pythonFile = "python-3.11.8-amd64.exe"
$pythonUrl = "https://www.python.org/ftp/python/3.11.8/$pythonFile"
$ffmpegFile = "ffmpeg-release-essentials.zip"
$ffmpegUrl = "https://www.gyan.dev/ffmpeg/builds/$ffmpegFile"

function Get-PythonCommand {
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        & $py.Source -3.11 -c "import sys; print(sys.executable)" *> $null
        if ($LASTEXITCODE -eq 0) {
            return @($py.Source, "-3.11")
        }
        & $py.Source -3.12 -c "import sys; print(sys.executable)" *> $null
        if ($LASTEXITCODE -eq 0) {
            return @($py.Source, "-3.12")
        }
    }
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        return @($python.Source)
    }
    throw "Python is required to fetch bundled wheels."
}

function Invoke-Python([string[]]$PythonArgs) {
    $prevErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    if (-not $PythonArgs -or $PythonArgs.Count -eq 0) {
        $ErrorActionPreference = $prevErrorAction
        throw "Invoke-Python called without arguments."
    }
    $cmd = Get-PythonCommand
    $fullArgs = @()
    if ($cmd.Count -gt 1) {
        $fullArgs += $cmd[1]
    }
    $fullArgs += $PythonArgs
    $output = & $cmd[0] @fullArgs 2>&1
    $ErrorActionPreference = $prevErrorAction
    if ($output) {
        $output | ForEach-Object { Write-Host $_ }
    }
}

function Ensure-Packaging {
    Invoke-Python @("-c", "import packaging") *> $null
    if ($LASTEXITCODE -ne 0) {
        Invoke-Python @("-m", "pip", "install", "--upgrade", "--user", "packaging")
    }
}

function Download-IfMissing([string]$Url, [string]$OutPath) {
    if (Test-Path $OutPath) {
        Write-Host "Already present: $OutPath"
        return
    }
    Write-Host "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $OutPath -UseBasicParsing
}

New-Item -ItemType Directory -Force -Path $pythonDir | Out-Null
New-Item -ItemType Directory -Force -Path $ffmpegDir | Out-Null
if ($skipWheelhouse -eq 0) {
    New-Item -ItemType Directory -Force -Path $wheelsDir | Out-Null
}

Download-IfMissing $pythonUrl (Join-Path $pythonDir $pythonFile)
Download-IfMissing $ffmpegUrl (Join-Path $ffmpegDir $ffmpegFile)

if ($skipWheelhouse -eq 0) {
    Ensure-Packaging
    Get-ChildItem -Path $wheelsDir -Filter "*.whl" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

    $wheelhouseScript = Join-Path $RootDir "..\\..\\tools\\build_windows_wheelhouse.py"
    Write-Host "Building wheelhouse ($wheelhouseSubdir)..."
    Invoke-Python @(
        $wheelhouseScript,
        "--output-dir", $wheelsDir,
        "--include-cuda-wheels", $includeCuda,
        "--include-directml-wheels", $includeDirectml
    )
} else {
    Write-Host "Skipping wheelhouse build (STEMWERK_SKIP_WHEELHOUSE=1)."
}

Write-Host ""
Write-Host "Bundled runtime assets ready:"
Get-Item (Join-Path $pythonDir $pythonFile), (Join-Path $ffmpegDir $ffmpegFile) | Format-Table -AutoSize
if ($skipWheelhouse -eq 0) {
    Write-Host ""
    Write-Host "Bundled wheels ready ($wheelhouseSubdir):"
    Get-ChildItem -Path $wheelsDir -File | Select-Object -First 8 | Format-Table -AutoSize
}
