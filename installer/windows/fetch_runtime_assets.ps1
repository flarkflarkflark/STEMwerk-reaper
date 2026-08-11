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
$pythonSha256 = "fd3428eb6c80901b877d036ffa2be127ccad9bbe036a43f00fc96a48b724f9c7"

# The plain "ffmpeg-release-essentials.zip" alias is a rolling redirect to
# whatever gyan.dev currently considers the latest release build, so it is
# not a stable input on its own. Fetch from the exact versioned package URL
# it currently resolves to (release 9.0) instead, pinned with the SHA256
# gyan.dev itself publishes for that package
# (https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0-essentials_build.zip.sha256).
# The local cache/staged filename stays "ffmpeg-release-essentials.zip" so
# STEMwerk.iss's payload\ffmpeg\ffmpeg-release-essentials.zip reference does
# not need to change every time this pin is bumped.
$ffmpegFile = "ffmpeg-release-essentials.zip"
$ffmpegUrl = "https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0-essentials_build.zip"
$ffmpegSha256 = "e6b54767a6065919048f1a098eb27211ca4e12b4348a05d88777a5855d0b6e71"

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

function Verify-Sha256([string]$Path, [string]$Expected) {
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Expected) {
        Write-Host "ERROR: SHA256 mismatch for $Path" -ForegroundColor Red
        Write-Host "  expected: $Expected" -ForegroundColor Red
        Write-Host "  actual:   $actual" -ForegroundColor Red
        return $false
    }
    return $true
}

function Download-IfMissing([string]$Url, [string]$OutPath, [string]$ExpectedSha256) {
    if (Test-Path $OutPath) {
        if (Verify-Sha256 $OutPath $ExpectedSha256) {
            Write-Host "Already present and verified: $OutPath"
            return
        }
        Write-Host "Cached file failed checksum verification, re-downloading: $OutPath"
        Remove-Item -Force $OutPath
    }
    Write-Host "Downloading $Url"
    Invoke-WebRequest -Uri $Url -OutFile $OutPath -UseBasicParsing
    if (-not (Verify-Sha256 $OutPath $ExpectedSha256)) {
        Remove-Item -Force -ErrorAction SilentlyContinue $OutPath
        throw "Downloaded file failed checksum verification, refusing to use it: $OutPath"
    }
}

New-Item -ItemType Directory -Force -Path $pythonDir | Out-Null
New-Item -ItemType Directory -Force -Path $ffmpegDir | Out-Null
if ($skipWheelhouse -eq 0) {
    New-Item -ItemType Directory -Force -Path $wheelsDir | Out-Null
}

Download-IfMissing $pythonUrl (Join-Path $pythonDir $pythonFile) $pythonSha256
Download-IfMissing $ffmpegUrl (Join-Path $ffmpegDir $ffmpegFile) $ffmpegSha256

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
