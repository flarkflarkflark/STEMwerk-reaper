Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$rootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Resolve-Path (Join-Path $rootDir "..\\..")
$issPath = Join-Path $repoDir "installer\\windows\\STEMwerk_Offline_Patch.iss"

$version = (Get-Content (Join-Path $repoDir "VERSION") -Raw).Trim()
$env:STEMWERK_VERSION = $version

$candidates = @()
if ($env:INNO_EXE) { $candidates += $env:INNO_EXE }
$cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
if ($cmd) { $candidates += $cmd.Source }
$candidates += @(
    (Join-Path $env:LOCALAPPDATA "Programs\\Inno Setup 6\\ISCC.exe"),
    (Join-Path $env:ProgramFiles "Inno Setup 6\\ISCC.exe"),
    (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\\ISCC.exe")
)

$iscc = $null
foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path $candidate)) {
        $iscc = $candidate
        break
    }
}

if (-not $iscc) {
    throw "ISCC.exe not found. Install Inno Setup or set INNO_EXE."
}

& $iscc $issPath
