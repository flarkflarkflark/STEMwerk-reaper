param(
    [string]$RuntimeBase = ""
)

$ErrorActionPreference = "SilentlyContinue"

function LogLine([string]$Message, [string]$Path) {
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        Add-Content -Path $Path -Value $Message -Encoding ascii
    }
}

if ([string]::IsNullOrWhiteSpace($RuntimeBase)) {
    $localAppData = $env:LOCALAPPDATA
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        $RuntimeBase = Join-Path $localAppData "STEMwerk"
    }
}

if ([string]::IsNullOrWhiteSpace($RuntimeBase)) {
    exit 1
}

$stateDir = Join-Path $RuntimeBase "state"
$logDir = Join-Path $RuntimeBase "logs"
$stateFile = Join-Path $stateDir "bootstrap.env"
$logFile = Join-Path $logDir "bootstrap.log"

New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

# Clear previous run artifacts so UI log shows the current run only.
if (Test-Path $stateFile) { Remove-Item $stateFile -Force -ErrorAction SilentlyContinue }
if (Test-Path $logFile) { Remove-Item $logFile -Force -ErrorAction SilentlyContinue }

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$bootstrap = Join-Path $scriptRoot "STEMwerk_Bootstrap_Windows.ps1"

if (-not (Test-Path $bootstrap)) {
    LogLine "STATUS=failed" $logFile
    LogLine "STATUS_REASON=missing_bootstrap" $logFile
    exit 2
}

$env:STEMWERK_INSTALLER = "1"

LogLine "Installer bootstrap started" $logFile
LogLine ("RUNTIME_BASE=" + $RuntimeBase) $logFile
LogLine ("Installer progress log: " + $logFile) $logFile
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
