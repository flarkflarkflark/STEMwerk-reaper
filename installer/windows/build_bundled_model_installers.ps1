param(
    [string]$Variants = ""
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

if ([string]::IsNullOrWhiteSpace($Variants)) {
    $Variants = $env:STEMWERK_VARIANTS
}
if ([string]::IsNullOrWhiteSpace($Variants)) {
    $Variants = "all"
}

function Should-BuildVariant([string]$Name) {
    if ($Variants -eq "all") { return $true }
    $requested = $Variants.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    return $requested -contains $Name
}

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

function Copy-VariantFiles([string]$SourceDir, [string]$DestDir, [string[]]$Files) {
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    foreach ($rel in $Files) {
        $src = Join-Path $SourceDir $rel
        Require-File $src
        Copy-Item -Path $src -Destination $DestDir -Force
    }
}

function Resolve-ModelStamp {
    $modelCache = $env:STEMWERK_MODEL_CACHE_DIR
    if ([string]::IsNullOrWhiteSpace($modelCache)) {
        $modelCache = Join-Path $env:LOCALAPPDATA "STEMwerk\\models"
    }
    $stamp = (Get-Date -Format "yyyyMMdd_HHmmss")

    $requiredFast = @("htdemucs.yaml", "955717e8-8726e21a.th", "download_checks.json")
    $requiredQuality = @(
        "htdemucs_ft.yaml",
        "f7e0c4bc-ba3fe64a.th",
        "d12395a8-e57c48e6.th",
        "92cfc3b6-ef3bcb9c.th",
        "04573f0d-f3cf25b2.th",
        "download_checks.json"
    )
    $requiredSix = @("htdemucs_6s.yaml", "5c90dfd2-34c22ccb.th", "download_checks.json")
    $requiredAll = @(
        "htdemucs.yaml",
        "htdemucs_ft.yaml",
        "htdemucs_6s.yaml",
        "955717e8-8726e21a.th",
        "f7e0c4bc-ba3fe64a.th",
        "d12395a8-e57c48e6.th",
        "92cfc3b6-ef3bcb9c.th",
        "04573f0d-f3cf25b2.th",
        "5c90dfd2-34c22ccb.th",
        "download_checks.json"
    )

    if ($modelCache -and (Test-Path $modelCache)) {
        Write-Host "Copying models from: $modelCache"
        Copy-VariantFiles $modelCache (Join-Path $payloadDir "models-$stamp-fast") $requiredFast
        Copy-VariantFiles $modelCache (Join-Path $payloadDir "models-$stamp-quality") $requiredQuality
        Copy-VariantFiles $modelCache (Join-Path $payloadDir "models-$stamp-6stem") $requiredSix
        Copy-VariantFiles $modelCache (Join-Path $payloadDir "models-$stamp-allmodels") $requiredAll
        return $stamp
    }

    $existing = Get-ChildItem -Path $payloadDir -Directory -Filter "models-*-allmodels" | Sort-Object Name | Select-Object -Last 1
    if (-not $existing) {
        throw "No model payloads found. Set STEMWERK_MODEL_CACHE_DIR or populate installer/windows/payload."
    }
    if ($existing.Name -match '^models-(.+)-allmodels$') {
        $stamp = $matches[1]
    } else {
        throw "Unexpected model payload name: $($existing.Name)"
    }

    foreach ($suffix in @("fast", "quality", "6stem", "allmodels")) {
        $dir = Join-Path $payloadDir ("models-$stamp-$suffix")
        if (-not (Test-Path $dir)) {
            throw "Missing payload directory: $dir"
        }
    }
    Write-Host "Using existing model payload stamp: $stamp"
    return $stamp
}

function Build-Variant([string]$IsccPath, [string]$PayloadSubdir, [string]$VariantName, [string]$WheelSubdir, [string]$OfflineTag) {
    $baseName = "STEMwerk-Setup-$version"
    $tempOutDir = Join-Path $payloadDir ("_tmp-out-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tempOutDir | Out-Null

    $env:STEMWERK_BUNDLE_RUNTIME = "1"
    $env:STEMWERK_VERSION = $version
    $env:STEMWERK_MODEL_PAYLOAD_SUBDIR = $PayloadSubdir
    $env:STEMWERK_WHEEL_PAYLOAD_SUBDIR = $WheelSubdir

    Write-Host "Building variant: $VariantName (payload: $PayloadSubdir)"
    & $IsccPath "/O$($tempOutDir)" "/F$($baseName)" $issPath | Out-Null

    if ($VariantName -eq "allmodels") {
        $variantTag = "$OfflineTag-allmodels"
    } else {
        $variantTag = "$OfflineTag-model-$VariantName"
    }
    $variantOut = Join-Path $distDir ("STEMwerk-Setup-$version-$variantTag.exe")
    $baseOut = Join-Path $tempOutDir ("$baseName.exe")
    Require-File $baseOut
    Move-Item -Path $baseOut -Destination $variantOut -Force
    Remove-Item -Path $tempOutDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Build-Flavor([string]$Name, [string]$WheelSubdir, [string]$OfflineTag, [string]$IncludeCuda, [string]$IncludeDirectml, [string]$Stamp) {
    Write-Host "Preparing offline wheelhouse for $Name..."
    $env:STEMWERK_WHEELHOUSE_SUBDIR = $WheelSubdir
    $env:STEMWERK_INCLUDE_CUDA_WHEELS = $IncludeCuda
    $env:STEMWERK_INCLUDE_DIRECTML_WHEELS = $IncludeDirectml
    & (Join-Path $rootDir "fetch_runtime_assets.ps1")

    if (Should-BuildVariant "fast") {
        Build-Variant $isccPath "models-$Stamp-fast" "fast" $WheelSubdir $OfflineTag
    }
    if (Should-BuildVariant "quality") {
        Build-Variant $isccPath "models-$Stamp-quality" "quality" $WheelSubdir $OfflineTag
    }
    if (Should-BuildVariant "6stem") {
        Build-Variant $isccPath "models-$Stamp-6stem" "6stem" $WheelSubdir $OfflineTag
    }
    if (Should-BuildVariant "allmodels") {
        Build-Variant $isccPath "models-$Stamp-allmodels" "allmodels" $WheelSubdir $OfflineTag
    }
}

New-Item -ItemType Directory -Force -Path $distDir | Out-Null
$isccPath = Resolve-IsccPath
$stampValue = Resolve-ModelStamp

Build-Flavor "nvidia" "wheels-nvidia" "offline-bundled-nvidia-gpu" "1" "0" $stampValue
Build-Flavor "amd" "wheels-directml" "offline-bundled-amd-gpu" "0" "1" $stampValue
Build-Flavor "cpu" "wheels-cpu" "offline-bundled-cpu" "0" "0" $stampValue

Write-Host ""
Write-Host "Build complete. Generated installers in: $distDir"
Get-ChildItem -Path $distDir -Filter ("STEMwerk-Setup-$version-offline-bundled-*.exe") | Select-Object Name, Length, LastWriteTime
