param(
    [string]$RuntimeBase = "",
    [string]$StateFile = "",
    [string]$LogFile = ""
)

$ErrorActionPreference = "SilentlyContinue"

function LogLine([string]$Message) {
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        Add-Content -Path $LogFile -Value $Message -Encoding ascii
    }
}

if ([string]::IsNullOrWhiteSpace($RuntimeBase)) {
    Write-Error "Missing runtime base"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($StateFile)) {
    $StateFile = Join-Path $RuntimeBase "runtime\\state\\bootstrap.env"
}
if ([string]::IsNullOrWhiteSpace($LogFile)) {
    $LogFile = Join-Path $RuntimeBase "runtime\\state\\bootstrap.log"
}

New-Item -ItemType Directory -Force -Path (Join-Path $RuntimeBase "runtime\\state") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $RuntimeBase "runtime\\bin") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $RuntimeBase "runtime\\ffmpeg") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $RuntimeBase "runtime\\python") | Out-Null

$status = "ok"
$statusReason = ""
$package = "audio-separator"
$coreExtra = ""
$profile = "windows-cpu"
$backend = "cpu"
$backendReason = ""
$python = $null
$ffmpeg = $null
$venvPy = Join-Path $RuntimeBase ".venv\\Scripts\\python.exe"

function Set-Status([string]$State, [string]$Reason) {
    if ($status -eq "ok") {
        $status = $State
        $statusReason = $Reason
        LogLine "STATUS=$status REASON=$statusReason"
    }
}

$candidates = @()
if ($env:CONDA_PREFIX) {
    $candidates += (Join-Path $env:CONDA_PREFIX "python.exe")
}
$localAppData = $env:LOCALAPPDATA
$programFiles = $env:ProgramFiles
$programFilesX86 = ${env:ProgramFiles(x86)}
if (-not $programFilesX86) { $programFilesX86 = "C:\\Program Files (x86)" }

$candidates += $venvPy
$candidates += (Join-Path $RuntimeBase ".venv-gpu\\Scripts\\python.exe")
$candidates += (Join-Path $localAppData "Programs\\Python\\Python311\\python.exe")
$candidates += (Join-Path $localAppData "Programs\\Python\\Python312\\python.exe")
$candidates += (Join-Path $localAppData "Programs\\Python\\Python310\\python.exe")
$candidates += (Join-Path $programFiles "Python311\\python.exe")
$candidates += (Join-Path $programFiles "Python310\\python.exe")
$candidates += (Join-Path $programFilesX86 "Python311\\python.exe")
$candidates += (Join-Path $programFilesX86 "Python310\\python.exe")
$candidates += (Join-Path $localAppData "Microsoft\\WindowsApps\\python.exe")
$candidates += (Join-Path $localAppData "Microsoft\\WindowsApps\\python3.exe")

foreach ($p in $candidates) {
    if ($p -and (Test-Path $p)) {
        $python = $p
        break
    }
}

if (-not $python) {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd) { $python = $cmd.Source }
}

if (-not $python) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        LogLine "Installing Python 3.11 via winget"
        & $winget.Source install --id Python.Python.3.11 -e | Out-Null
        $p11 = Join-Path $localAppData "Programs\\Python\\Python311\\python.exe"
        if (Test-Path $p11) { $python = $p11 }
    }
}

try {
    $gpuNames = (Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name)
} catch {
    $gpuNames = @()
}
if (-not $gpuNames) { $gpuNames = @() }
$hasNvidia = ($gpuNames | Where-Object { $_ -match "NVIDIA" }) -ne $null
$hasAmd = ($gpuNames | Where-Object { $_ -match "AMD|Radeon" }) -ne $null
$hasIntel = ($gpuNames | Where-Object { $_ -match "Intel" }) -ne $null

$nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($nvidiaSmi) {
    & $nvidiaSmi.Source -L | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $hasNvidia = $true
    }
}

if ($hasNvidia) {
    $profile = "windows-cuda"
    $backend = "cuda"
    $package = "audio-separator[gpu]"
    $coreExtra = "[gpu]"
} elseif ($hasAmd -or $hasIntel) {
    $profile = "windows-directml"
    $backend = "directml"
    $coreExtra = "[directml]"
}

if (-not $python) {
    Set-Status "missing_python" "python_not_found"
} else {
    if (-not (Test-Path $venvPy)) {
        LogLine "Creating venv"
        & $python -m venv (Join-Path $RuntimeBase ".venv") | Out-Null
        if (-not (Test-Path $venvPy)) {
            Set-Status "venv_failed" "venv_create_failed"
        }
    }
    if (Test-Path $venvPy) {
        $python = $venvPy
        & $python -m pip install --upgrade pip | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Set-Status "pip_failed" "pip_upgrade_failed"
        }
        & $python -m pip install "numpy<2.4" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Set-Status "deps_failed" "numpy_install_failed"
        }

        $coreCandidates = @(
            "C:\\mnt\\PRODUCTION\\GIT\\STEMwerk-core",
            (Join-Path (Split-Path $RuntimeBase -Parent) "STEMwerk-core"),
            (Join-Path (Split-Path (Split-Path $RuntimeBase -Parent) -Parent) "STEMwerk-core")
        )
        $corePath = $null
        foreach ($p in $coreCandidates) {
            if ($p -and (Test-Path (Join-Path $p "pyproject.toml")) -and (Test-Path (Join-Path $p "src\\stemwerk_core"))) {
                $corePath = $p
                break
            }
        }
        if ($corePath) {
            LogLine "Installing stemwerk-core from $corePath$coreExtra"
            & $python -m pip install "$corePath$coreExtra" | Out-Null
        } else {
            LogLine "Installing stemwerk-core$coreExtra"
            & $python -m pip install "stemwerk-core$coreExtra" | Out-Null
        }
        if ($LASTEXITCODE -ne 0 -and $coreExtra -ne "") {
            LogLine "GPU/DirectML stemwerk-core install failed; falling back to CPU"
            $coreExtra = ""
            $profile = "windows-cpu"
            $backend = "cpu"
            $backendReason = "backend_install_failed"
            if ($corePath) {
                & $python -m pip install "$corePath" | Out-Null
            } else {
                & $python -m pip install "stemwerk-core" | Out-Null
            }
        }
        if ($LASTEXITCODE -ne 0) {
            Set-Status "deps_failed" "stemwerk_core_install_failed"
        }

        & $python -c "import audio_separator" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            LogLine "Installing $package"
            & $python -m pip install $package | Out-Null
            & $python -c "import audio_separator" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                if ($package -ne "audio-separator") {
                    LogLine "GPU audio-separator install failed; falling back to CPU"
                    $package = "audio-separator"
                    $profile = "windows-cpu"
                    $backend = "cpu"
                    if (-not $backendReason) { $backendReason = "backend_install_failed" }
                    & $python -m pip install $package | Out-Null
                    & $python -c "import audio_separator" | Out-Null
                }
                if ($LASTEXITCODE -ne 0) {
                    Set-Status "deps_failed" "audio_separator_install_failed"
                }
            }
        }

        & $python -c "import stemwerk_core" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Set-Status "deps_failed" "stemwerk_core_missing"
        }
    }
}

$ffmpegCandidates = @(
    (Join-Path $RuntimeBase "runtime\\bin\\ffmpeg.exe"),
    (Join-Path $RuntimeBase "runtime\\ffmpeg\\bin\\ffmpeg.exe"),
    (Join-Path $localAppData "Programs\\ffmpeg\\bin\\ffmpeg.exe"),
    (Join-Path $localAppData "ffmpeg\\bin\\ffmpeg.exe"),
    "C:\\ffmpeg\\bin\\ffmpeg.exe",
    (Join-Path $programFiles "FFmpeg\\bin\\ffmpeg.exe"),
    (Join-Path $programFiles "ffmpeg\\bin\\ffmpeg.exe"),
    (Join-Path $programFilesX86 "FFmpeg\\bin\\ffmpeg.exe")
)

foreach ($p in $ffmpegCandidates) {
    if ($p -and (Test-Path $p)) {
        $ffmpeg = $p
        break
    }
}

if (-not $ffmpeg) {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { $ffmpeg = $cmd.Source }
}

if (-not $ffmpeg) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        LogLine "Installing FFmpeg via winget"
        & $winget.Source install --id Gyan.FFmpeg -e | Out-Null
        $wg = Join-Path $localAppData "Microsoft\\WinGet\\Links\\ffmpeg.exe"
        if (Test-Path $wg) { $ffmpeg = $wg }
    }
}

if (-not $ffmpeg) {
    Set-Status "missing_ffmpeg" "ffmpeg_not_found"
}

$lines = @()
$lines += "STATUS=$status"
$lines += "STATUS_REASON=$statusReason"
$lines += "PROFILE=$profile"
$lines += "BACKEND=$backend"
if ($backendReason) { $lines += "BACKEND_REASON=$backendReason" }
if ($python) { $lines += "PYTHON_PATH=$python" }
if ($ffmpeg) { $lines += "FFMPEG_PATH=$ffmpeg" }

$lines | Out-File -FilePath $StateFile -Encoding ascii

if ($status -ne "ok") {
    exit 1
}
exit 0
