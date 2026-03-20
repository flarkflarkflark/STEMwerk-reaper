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
    $StateFile = Join-Path $RuntimeBase "state\\bootstrap.env"
}
if ([string]::IsNullOrWhiteSpace($LogFile)) {
    $LogFile = Join-Path $RuntimeBase "logs\\bootstrap.log"
}

New-Item -ItemType Directory -Force -Path (Join-Path $RuntimeBase "state") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $RuntimeBase "logs") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $RuntimeBase "bin") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $RuntimeBase "ffmpeg") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $RuntimeBase "python") | Out-Null

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
$installerMode = ($env:STEMWERK_INSTALLER -eq "1")
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$bundledCoreDir = Join-Path $scriptRoot "vendor\\stemwerk-core"
$allowPypiCore = ($env:STEMWERK_ALLOW_PYPI_CORE -eq "1")

function WriteState([string]$State, [string]$Reason) {
    $lines = @()
    $lines += "STATUS=$State"
    if (-not [string]::IsNullOrWhiteSpace($Reason)) { $lines += "STATUS_REASON=$Reason" }
    if ($installerMode) { $lines += "INSTALLER=1" }
    if (-not [string]::IsNullOrWhiteSpace($RuntimeBase)) { $lines += "RUNTIME_BASE=$RuntimeBase" }
    $lines | Out-File -FilePath $StateFile -Encoding ascii
}

function Set-Status([string]$State, [string]$Reason) {
    if ($status -eq "ok") {
        $status = $State
        $statusReason = $Reason
        LogLine "STATUS=$status REASON=$statusReason"
        WriteState $status $statusReason
    }
}

function LogProgress([string]$Message) {
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    LogLine $Message
    if ($installerMode) { Write-Host $Message }
}

function Set-Progress([string]$Reason, [string]$Message) {
    if ($status -ne "ok") { return }
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        LogProgress $Message
    } elseif (-not [string]::IsNullOrWhiteSpace($Reason)) {
        LogProgress ("Progress: " + $Reason)
    }
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        WriteState "running" $Reason
    } else {
        WriteState "running" ""
    }
}

$script:StepIndex = 0
$script:StepTotal = 4
function Step([string]$Reason, [string]$Label) {
    $script:StepIndex = $script:StepIndex + 1
    if ($script:StepIndex -gt $script:StepTotal) { $script:StepIndex = $script:StepTotal }
    $prefix = "[" + $script:StepIndex + "/" + $script:StepTotal + "] "
    Set-Progress $Reason ($prefix + $Label)
}

function RunHidden([string]$File, [string[]]$Arguments, [string]$Description) {
    if ([string]::IsNullOrWhiteSpace($File)) { return 1 }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $File
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        if ($Arguments) {
            $quoted = $Arguments | ForEach-Object {
                if ($_ -match "\s") { '"' + ($_ -replace '"', '""') + '"' } else { $_ }
            }
            $psi.Arguments = ($quoted -join " ")
        }
        if (-not [string]::IsNullOrWhiteSpace($Description)) {
            LogProgress ("Starting: " + $Description)
        }
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        $null = $p.Start()
        $stdout = $p.StandardOutput.ReadToEnd()
        $stderr = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            LogLine $stdout
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            LogLine $stderr
        }
        if (-not [string]::IsNullOrWhiteSpace($Description)) {
            LogProgress ("Finished: " + $Description + " (exit=" + $p.ExitCode + ")")
        }
        $global:LASTEXITCODE = $p.ExitCode
        return $p.ExitCode
    } catch {
        $global:LASTEXITCODE = 1
        return 1
    }
    return 1
}

function IsWindowsStorePython([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = $Path.ToLowerInvariant()
    return ($p -like "*\\microsoft\\windowsapps\\python.exe" -or $p -like "*\\microsoft\\windowsapps\\python3.exe")
}

function TestPython([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if (-not (Test-Path $Path)) { return $false }
    if (IsWindowsStorePython $Path) { return $false }
    try {
        $out = & $Path --version 2>&1
        return ($LASTEXITCODE -eq 0 -and ($out -match "Python"))
    } catch {
        return $false
    }
}

function InstallPythonDirect {
    $pyUrl = "https://www.python.org/ftp/python/3.11.8/python-3.11.8-amd64.exe"
    $pyInstaller = Join-Path $RuntimeBase "bin\\python-installer.exe"
    try {
        LogProgress ("Downloading Python installer: " + $pyUrl)
        Invoke-WebRequest -Uri $pyUrl -OutFile $pyInstaller -UseBasicParsing | Out-Null
    } catch {
        LogLine "Python download failed"
        return $null
    }
    LogProgress "Installing Python silently (per-user)"
    RunHidden $pyInstaller @("/quiet","InstallAllUsers=0","Include_test=0","Include_pip=1","PrependPath=0","Shortcuts=0") "Python installer" | Out-Null
    $p11 = Join-Path $localAppData "Programs\\Python\\Python311\\python.exe"
    if (TestPython $p11) { return $p11 }
    return $null
}

function InstallFfmpegDirect {
    $zipUrl = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
    $zipPath = Join-Path $RuntimeBase "ffmpeg\\ffmpeg.zip"
    try {
        LogProgress ("Downloading FFmpeg (gyan.dev release): " + $zipUrl)
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing | Out-Null
    } catch {
        LogLine "FFmpeg download failed"
        return $null
    }
    if (Test-Path $zipPath) {
        $zipSize = (Get-Item $zipPath).Length
        $zipMb = [Math]::Round($zipSize / 1MB, 1)
        LogProgress ("Downloaded FFmpeg archive: " + $zipMb + " MB")
    }
    try {
        LogProgress "Extracting FFmpeg archive (this can take a moment)"
        Expand-Archive -Path $zipPath -DestinationPath (Join-Path $RuntimeBase "ffmpeg") -Force
    } catch {
        LogLine "FFmpeg extract failed"
        return $null
    }
    LogProgress "Searching extracted files for ffmpeg.exe"
    $ff = Get-ChildItem -Path (Join-Path $RuntimeBase "ffmpeg") -Filter "ffmpeg.exe" -Recurse | Select-Object -First 1
    if ($ff) { return $ff.FullName }
    LogLine "FFmpeg binary not found after extract"
    return $null
}

function IsFfmpegShim([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = $Path.ToLowerInvariant().Trim().Trim('"').Trim("'").Replace("/", "\")
    return ($p.Contains("\winget\links\ffmpeg.exe") -or $p.Contains("\windowsapps\ffmpeg"))
}

function ResolveCoreInstallTarget([string]$Extra) {
    $result = [ordered]@{ Target = $null; Description = ""; SupportsExtras = $false }

    if ($env:STEMWERK_CORE_PATH) {
        $candidate = $env:STEMWERK_CORE_PATH
        if ($candidate -and (Test-Path $candidate)) {
            if ((Test-Path (Join-Path $candidate "pyproject.toml")) -and (Test-Path (Join-Path $candidate "src\\stemwerk_core"))) {
                $result.Target = $candidate
                $result.Description = "STEMWERK_CORE_PATH source"
                $result.SupportsExtras = $true
                return $result
            }
            if ($candidate -match "\\.(whl|zip|tar\\.gz)$") {
                $result.Target = $candidate
                $result.Description = "STEMWERK_CORE_PATH artifact"
                $result.SupportsExtras = $false
                return $result
            }
            LogLine "STEMWERK_CORE_PATH is set but invalid: $candidate"
        } else {
            LogLine "STEMWERK_CORE_PATH is set but missing: $candidate"
        }
    }

    $bundleDir = $env:STEMWERK_CORE_BUNDLE_DIR
    if (-not $bundleDir -or $bundleDir -eq "") { $bundleDir = $bundledCoreDir }
    if ($bundleDir -and (Test-Path $bundleDir)) {
        $wheel = Get-ChildItem -Path $bundleDir -File -Filter "*.whl" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($wheel) {
            $result.Target = $wheel.FullName
            $result.Description = "bundled wheel"
            $result.SupportsExtras = $false
            return $result
        }
        $sdist = Get-ChildItem -Path $bundleDir -File -Filter "*.tar.gz" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($sdist) {
            $result.Target = $sdist.FullName
            $result.Description = "bundled sdist"
            $result.SupportsExtras = $false
            return $result
        }
        $zip = Get-ChildItem -Path $bundleDir -File -Filter "*.zip" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($zip) {
            $result.Target = $zip.FullName
            $result.Description = "bundled zip"
            $result.SupportsExtras = $false
            return $result
        }
    }

    if ($allowPypiCore) {
        $result.Target = "stemwerk-core"
        $result.Description = "PyPI"
        $result.SupportsExtras = $true
        return $result
    }

    return $result
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

Step "step_1_runtime" "runtime initialization"
LogProgress "Runtime directories prepared"

Step "step_2_python" "python + venv"
LogProgress "Looking for existing Python installations"
foreach ($p in $candidates) {
    if ($p -and (Test-Path $p) -and -not (IsWindowsStorePython $p)) {
        $python = $p
        break
    }
}

if (-not $python) {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd -and -not (IsWindowsStorePython $cmd.Source)) { $python = $cmd.Source }
}

if ($python -and -not (TestPython $python)) {
    $python = $null
}

if (-not $python) {
    LogProgress "Python not found; attempting direct install"
    $python = InstallPythonDirect
}

LogProgress "Detecting GPU devices for backend selection"
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
    Set-Status "missing_python" "python_install_failed"
} else {
    if (-not (Test-Path $venvPy)) {
        LogProgress "Creating virtual environment"
        RunHidden $python @("-m","venv",(Join-Path $RuntimeBase ".venv")) "Create virtual environment" | Out-Null
        if (-not (Test-Path $venvPy)) {
            Set-Status "venv_failed" "venv_create_failed"
        }
    }
    if (Test-Path $venvPy) {
        $python = $venvPy
        RunHidden $python @("-m","pip","install","--upgrade","pip") "Upgrade pip" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Set-Status "pip_failed" "pip_upgrade_failed"
        }
        RunHidden $python @("-m","pip","install","numpy<2.4") "Install numpy" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Set-Status "deps_failed" "numpy_install_failed"
        }
    }
}

Step "step_3_ffmpeg" "ffmpeg detection/install"
LogProgress "Searching for FFmpeg"
$ffmpegCandidates = @(
    (Join-Path $RuntimeBase "bin\\ffmpeg.exe"),
    (Join-Path $RuntimeBase "ffmpeg\\bin\\ffmpeg.exe"),
    (Join-Path $localAppData "Programs\\ffmpeg\\bin\\ffmpeg.exe"),
    (Join-Path $localAppData "ffmpeg\\bin\\ffmpeg.exe"),
    "C:\\ffmpeg\\bin\\ffmpeg.exe",
    (Join-Path $programFiles "FFmpeg\\bin\\ffmpeg.exe"),
    (Join-Path $programFiles "ffmpeg\\bin\\ffmpeg.exe"),
    (Join-Path $programFilesX86 "FFmpeg\\bin\\ffmpeg.exe")
)

foreach ($p in $ffmpegCandidates) {
    if ($p -and (Test-Path $p)) {
        if (IsFfmpegShim $p) {
            LogProgress ("Ignoring shim FFmpeg path: " + $p)
        } else {
            $ffmpeg = $p
            break
        }
    }
}

if (-not $ffmpeg) {
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) {
        if (IsFfmpegShim $cmd.Source) {
            LogProgress ("Ignoring shim FFmpeg path: " + $cmd.Source)
        } else {
            $ffmpeg = $cmd.Source
        }
    }
}

if (-not $ffmpeg) {
    LogProgress "FFmpeg not found; downloading and installing"
    $ffmpeg = InstallFfmpegDirect
}

if ($ffmpeg -and (IsFfmpegShim $ffmpeg)) {
    LogProgress ("Ignoring shim FFmpeg path: " + $ffmpeg)
    $ffmpeg = $null
}
if ($ffmpeg -and -not (Test-Path $ffmpeg)) {
    LogProgress ("FFmpeg path missing after install: " + $ffmpeg)
    $ffmpeg = $null
}

if ($ffmpeg) {
    LogProgress ("FFmpeg ready: " + $ffmpeg)
} else {
    Set-Status "missing_ffmpeg" "ffmpeg_install_failed"
}

Step "step_4_core" "stemwerk core packages"
if (Test-Path $venvPy) {
    $python = $venvPy
    $coreTarget = ResolveCoreInstallTarget $coreExtra
    if (-not $coreTarget.Target) {
        LogLine "stemwerk-core bundle missing from installer payload."
        LogLine ("Expected bundle directory: " + $bundledCoreDir)
        LogLine "Provide a bundled wheel/sdist or set STEMWERK_CORE_PATH."
        Set-Status "deps_failed" "stemwerk_core_install_failed"
    } else {
        $installTarget = $coreTarget.Target
        if ($coreTarget.SupportsExtras -and $coreExtra -ne "") {
            $installTarget = "$installTarget$coreExtra"
        }
        LogProgress ("Installing stemwerk-core from " + $coreTarget.Description)
        LogLine ("Installing stemwerk-core from " + $coreTarget.Description + ": " + $installTarget)
        RunHidden $python @("-m","pip","install",$installTarget) "Install stemwerk-core" | Out-Null
        if ($LASTEXITCODE -ne 0 -and $coreExtra -ne "" -and $coreTarget.SupportsExtras) {
            LogLine "GPU/DirectML stemwerk-core install failed; falling back to CPU"
            $coreExtra = ""
            $profile = "windows-cpu"
            $backend = "cpu"
            $backendReason = "backend_install_failed"
            $installTarget = $coreTarget.Target
            LogLine ("Installing stemwerk-core from " + $coreTarget.Description + ": " + $installTarget)
            RunHidden $python @("-m","pip","install",$installTarget) "Install stemwerk-core (CPU fallback)" | Out-Null
        }
        if ($LASTEXITCODE -ne 0) {
            Set-Status "deps_failed" "stemwerk_core_install_failed"
        }
    }

    RunHidden $python @("-c","import audio_separator") "Check audio-separator" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        LogProgress ("Installing " + $package)
        LogLine "Installing $package"
        RunHidden $python @("-m","pip","install",$package) "Install audio-separator" | Out-Null
        RunHidden $python @("-c","import audio_separator") "Verify audio-separator" | Out-Null
        if ($LASTEXITCODE -ne 0) {
            if ($package -ne "audio-separator") {
                LogLine "GPU audio-separator install failed; falling back to CPU"
                $package = "audio-separator"
                $profile = "windows-cpu"
                $backend = "cpu"
                if (-not $backendReason) { $backendReason = "backend_install_failed" }
                RunHidden $python @("-m","pip","install",$package) "Install audio-separator (CPU fallback)" | Out-Null
                RunHidden $python @("-c","import audio_separator") "Verify audio-separator (CPU fallback)" | Out-Null
            }
            if ($LASTEXITCODE -ne 0) {
                Set-Status "deps_failed" "audio_separator_install_failed"
            }
        }
    }

    RunHidden $python @("-c","import stemwerk_core") "Verify stemwerk-core" | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Set-Status "deps_failed" "stemwerk_core_missing"
    }
} else {
    LogProgress "Skipping core install (Python venv unavailable)"
}

$lines = @()
$lines += "STATUS=$status"
$lines += "STATUS_REASON=$statusReason"
$lines += "PROFILE=$profile"
$lines += "BACKEND=$backend"
if ($backendReason) { $lines += "BACKEND_REASON=$backendReason" }
if ($python) { $lines += "PYTHON_PATH=$python" }
if ($ffmpeg) { $lines += "FFMPEG_PATH=$ffmpeg" }
if ($installerMode) { $lines += "INSTALLER=1" }
if ($RuntimeBase) { $lines += "RUNTIME_BASE=$RuntimeBase" }

$lines | Out-File -FilePath $StateFile -Encoding ascii

if ($status -ne "ok") {
    exit 1
}
exit 0
