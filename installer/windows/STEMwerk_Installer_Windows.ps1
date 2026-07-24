param(
    [string]$RuntimeBase = "",
    [switch]$CleanRuntime,
    [switch]$CleanModels,
    [switch]$BundledRuntime,
    [switch]$OfflineBundledAllmodels
)

$ErrorActionPreference = "SilentlyContinue"

function LogLine([string]$Message, [string]$Path) {
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        Add-Content -Path $Path -Value $Message -Encoding ascii
    }
}

function Normalize-WindowsPath([string]$Path, [switch]$PreserveTrailingSeparator) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }

    $value = $Path.Trim().Replace('/', '\')
    $hadTrailing = $value.EndsWith('\')
    $prefix = ""
    $rest = $value

    if ($value.StartsWith('\\?\UNC\')) {
        $prefix = '\\?\UNC\'
        $rest = $value.Substring($prefix.Length)
    } elseif ($value.StartsWith('\\?\')) {
        $prefix = '\\?\'
        $rest = $value.Substring($prefix.Length)
    } elseif ($value.StartsWith('\\')) {
        $prefix = '\\'
        $rest = $value.Substring(2)
    }

    $segments = @()
    foreach ($segment in ($rest -split '\\+')) {
        if ($segment -ne "") {
            $segments += $segment
        }
    }
    $normalized = $prefix + ($segments -join '\')

    if ($PreserveTrailingSeparator.IsPresent) {
        if ($hadTrailing -and -not $normalized.EndsWith('\')) {
            $normalized += '\'
        }
    } elseif ($normalized.Length -gt 3) {
        $normalized = $normalized.TrimEnd('\')
    }

    return $normalized
}

function Join-NormalizedWindowsPath([string]$BasePath, [string[]]$ChildParts) {
    $current = $BasePath
    foreach ($child in $ChildParts) {
        if ([string]::IsNullOrWhiteSpace($child)) { continue }
        if ([string]::IsNullOrWhiteSpace($current)) {
            $current = $child
        } else {
            $current = Join-Path $current $child
        }
    }
    return Normalize-WindowsPath $current
}

function Remove-ChildDirectory([string]$BasePath, [string]$ChildName) {
    if ([string]::IsNullOrWhiteSpace($BasePath)) { return $false }
    if ([string]::IsNullOrWhiteSpace($ChildName)) { return $false }
    $target = Join-Path $BasePath $ChildName
    if (-not (Test-Path $target)) { return $false }
    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
    return (-not (Test-Path $target))
}

if ([string]::IsNullOrWhiteSpace($RuntimeBase)) {
    $localAppData = $env:LOCALAPPDATA
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        $RuntimeBase = Join-NormalizedWindowsPath $localAppData @("STEMwerk")
    }
}

if ([string]::IsNullOrWhiteSpace($RuntimeBase)) {
    exit 1
}

$RuntimeBase = Normalize-WindowsPath $RuntimeBase

$cleanRuntimeRequested = $CleanRuntime.IsPresent -or ($env:STEMWERK_CLEAN_RUNTIME -eq "1")
$cleanModelsRequested = $CleanModels.IsPresent -or ($env:STEMWERK_CLEAN_MODELS -eq "1")

$stateDir = Join-NormalizedWindowsPath $RuntimeBase @("state")
$logDir = Join-NormalizedWindowsPath $RuntimeBase @("logs")
$stateFile = Join-NormalizedWindowsPath $stateDir @("bootstrap.env")
$logFile = Join-NormalizedWindowsPath $logDir @("bootstrap.log")

if ($cleanRuntimeRequested) {
    $runtimeTargets = @("state", "logs", ".venv", ".venv-gpu", "cache", "tmp", "temp", "bin", "ffmpeg", "python")
    foreach ($target in $runtimeTargets) {
        Remove-ChildDirectory -BasePath $RuntimeBase -ChildName $target | Out-Null
    }
}
if ($cleanModelsRequested) {
    Remove-ChildDirectory -BasePath $RuntimeBase -ChildName "models" | Out-Null
}

New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

# Clear previous run artifacts so UI log shows the current run only.
if (Test-Path $stateFile) { Remove-Item $stateFile -Force -ErrorAction SilentlyContinue }
if (Test-Path $logFile) { Remove-Item $logFile -Force -ErrorAction SilentlyContinue }

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$bootstrap = Join-NormalizedWindowsPath $scriptRoot @("STEMwerk_Bootstrap_Windows.ps1")

if (-not (Test-Path $bootstrap)) {
    LogLine "STATUS=failed" $logFile
    LogLine "STATUS_REASON=missing_bootstrap" $logFile
    exit 2
}

$env:STEMWERK_INSTALLER = "1"
if ($BundledRuntime.IsPresent) {
    $env:STEMWERK_BUNDLED_RUNTIME = "1"
} else {
    Remove-Item Env:STEMWERK_BUNDLED_RUNTIME -ErrorAction SilentlyContinue
}
if ($OfflineBundledAllmodels.IsPresent) {
    $env:STEMWERK_OFFLINE_BUNDLED_ALLMODELS = "1"
}

LogLine "Installer bootstrap started" $logFile
LogLine ("RUNTIME_BASE=" + $RuntimeBase) $logFile
LogLine ("Installer progress log: " + $logFile) $logFile
if ($cleanRuntimeRequested -or $cleanModelsRequested) {
    LogLine "STEMWERK_STATUS detail=Applying requested pre-setup cleanup." $logFile
    if ($cleanRuntimeRequested) {
        LogLine "STEMWERK_STATUS detail=Removed previous runtime state/logs/venv/cache folders." $logFile
    }
    if ($cleanModelsRequested) {
        LogLine "STEMWERK_STATUS detail=Removed cached models folder (%LOCALAPPDATA%\\STEMwerk\\models)." $logFile
    }
} else {
    LogLine "STEMWERK_STATUS detail=Keeping existing runtime cache and model folders." $logFile
}
LogLine "Bootstrap will report step-by-step progress below." $logFile

$argList = @(
    "-ExecutionPolicy", "Bypass",
    "-NoProfile",
    "-File", $bootstrap,
    "-RuntimeBase", $RuntimeBase,
    "-StateFile", $stateFile,
    "-LogFile", $logFile
)

$quoted = $argList | ForEach-Object {
    if ($_ -match "\s") { '"' + ($_ -replace '"', '""') + '"' } else { $_ }
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = "powershell.exe"
$psi.Arguments = ($quoted -join " ")
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
$psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden

$p = New-Object System.Diagnostics.Process
$p.StartInfo = $psi
$null = $p.Start()
$p.WaitForExit()

exit $p.ExitCode
