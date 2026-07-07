param(
    [switch]$SkipFetchBundledAssets,
    [string]$BundledWheelSubdir = "wheels",
    [string]$BundledModelSubdir = "models",
    [switch]$IncludeBundledWheels
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$rootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Resolve-Path (Join-Path $rootDir "..\\..")
$issPath = Join-Path $repoDir "installer\\windows\\STEMwerk.iss"
$distDir = Join-Path $rootDir "dist"
$payloadDir = Join-Path $rootDir "payload"

$rawVersion = Get-Content (Join-Path $repoDir "VERSION") -Raw
$version = $rawVersion.Trim()

function Resolve-IsccPath {
    $candidates = @()
    if ($env:INNO_EXE) { $candidates += $env:INNO_EXE }
    $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    $candidates += @(
        (Join-Path $env:LOCALAPPDATA "Programs\\Inno Setup 6\\ISCC.exe"),
        (Join-Path $env:ProgramFiles "Inno Setup 6\\ISCC.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\\ISCC.exe")
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }

    Write-Host "Inno Setup not found; installing via winget..."
    winget install --id JRSoftware.InnoSetup --silent --accept-package-agreements --accept-source-agreements
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }
    throw "ISCC.exe not found after install."
}

function Require-File([string]$Path) {
    if (-not (Test-Path $Path)) {
        throw "Missing required file: $Path"
    }
}

function Build-OnlineVariant([string]$IsccPath, [string]$Suffix, [bool]$BundleRuntime, [string]$WheelSubdir, [string]$ModelSubdir) {
    $baseName = "STEMwerk-Setup-$version"
    $tempOutDir = Join-Path $payloadDir ("_tmp-out-online-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tempOutDir | Out-Null

    $env:STEMWERK_VERSION = $version
    $env:STEMWERK_OUTPUT_SUFFIX = $Suffix
    if ($BundleRuntime) {
        $env:STEMWERK_BUNDLE_RUNTIME = "1"
        $env:STEMWERK_WHEEL_PAYLOAD_SUBDIR = $WheelSubdir
        $env:STEMWERK_MODEL_PAYLOAD_SUBDIR = $ModelSubdir
    } else {
        Remove-Item Env:STEMWERK_BUNDLE_RUNTIME -ErrorAction SilentlyContinue
        Remove-Item Env:STEMWERK_WHEEL_PAYLOAD_SUBDIR -ErrorAction SilentlyContinue
        Remove-Item Env:STEMWERK_MODEL_PAYLOAD_SUBDIR -ErrorAction SilentlyContinue
    }

    Write-Host "Building online installer $Suffix (bundleRuntime=$BundleRuntime)..."
    & $IsccPath "/O$($tempOutDir)" "/F$($baseName)" $issPath | Out-Null

    $builtPath = Join-Path $tempOutDir ("$baseName.exe")
    if (-not (Test-Path $builtPath)) {
        $fallback = Join-Path $tempOutDir ("$baseName$Suffix.exe")
        if (Test-Path $fallback) {
            $builtPath = $fallback
        }
    }
    Require-File $builtPath
    $finalPath = Join-Path $distDir ("STEMwerk-Setup-$version$Suffix.exe")
    Move-Item -Path $builtPath -Destination $finalPath -Force
    Remove-Item -Path $tempOutDir -Recurse -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Force -Path $distDir | Out-Null
$isccPath = Resolve-IsccPath
$onlineWheelPayloadSubdir = "__none__"
$onlineModelPayloadSubdir = "__none__"

if ($IncludeBundledWheels) {
    $onlineWheelPayloadSubdir = $BundledWheelSubdir
    $onlineModelPayloadSubdir = $BundledModelSubdir
}

if (-not $SkipFetchBundledAssets) {
    if ($IncludeBundledWheels) {
        $env:STEMWERK_WHEELHOUSE_SUBDIR = $BundledWheelSubdir
        Remove-Item Env:STEMWERK_SKIP_WHEELHOUSE -ErrorAction SilentlyContinue
    } else {
        $env:STEMWERK_SKIP_WHEELHOUSE = "1"
        Remove-Item Env:STEMWERK_WHEELHOUSE_SUBDIR -ErrorAction SilentlyContinue
        Remove-Item Env:STEMWERK_INCLUDE_CUDA_WHEELS -ErrorAction SilentlyContinue
        Remove-Item Env:STEMWERK_INCLUDE_DIRECTML_WHEELS -ErrorAction SilentlyContinue
    }
    & (Join-Path $rootDir "fetch_runtime_assets.ps1")
    Remove-Item Env:STEMWERK_SKIP_WHEELHOUSE -ErrorAction SilentlyContinue
}

Build-OnlineVariant $isccPath "-bundled" $true $onlineWheelPayloadSubdir $onlineModelPayloadSubdir
Build-OnlineVariant $isccPath "" $false "" ""

Write-Host ""
Write-Host "Build complete. Generated online installers in: $distDir"
Get-ChildItem -Path $distDir -Filter ("STEMwerk-Setup-$version*.exe") |
    Where-Object { $_.Name -match ("^STEMwerk-Setup-" + [regex]::Escape($version) + "(-bundled)?\\.exe$") } |
    Select-Object Name, Length, LastWriteTime
