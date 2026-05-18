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
$audioSeparatorVersion = "0.24.4"
$torchVersion = "2.4.1"
$torchVisionVersion = "0.19.1"
$torchCudaSuffix = "+cu121"
$torchDirectMlVersion = "0.2.5.dev240914"
$onnxRuntimeDirectMlVersion = "1.24.4"
$audioSeparatorOk = $false
$stemwerkCoreOk = $false
$samplerateOk = $false
$pytorchCudaIndex = "https://download.pytorch.org/whl/cu121"
$package = "audio-separator==$audioSeparatorVersion"
$coreExtra = ""
$profile = "windows-cpu"
$backend = "cpu"
$backendReason = ""
$python = $null
$ffmpeg = $null
$venvPy = Join-Path $RuntimeBase ".venv\\Scripts\\python.exe"
$installerMode = ($env:STEMWERK_INSTALLER -eq "1")
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$bundledRuntimeDir = Join-Path $scriptRoot "_bundled"
$pythonInstallerFileName = "python-3.11.8-amd64.exe"
$pythonInstallerUrl = "https://www.python.org/ftp/python/3.11.8/$pythonInstallerFileName"
$ffmpegArchiveFileName = "ffmpeg-release-essentials.zip"
$ffmpegArchiveUrl = "https://www.gyan.dev/ffmpeg/builds/$ffmpegArchiveFileName"
$bundledPythonInstaller = Join-Path $bundledRuntimeDir ("python\\" + $pythonInstallerFileName)
$bundledFfmpegZip = Join-Path $bundledRuntimeDir ("ffmpeg\\" + $ffmpegArchiveFileName)
$bundledWheelsDir = Join-Path $bundledRuntimeDir "wheels"
$bundledCoreDir = Join-Path $scriptRoot "vendor\\stemwerk-core"
$bundledJuliusDir = Join-Path $scriptRoot "vendor\\julius"
$constraintsDir = Join-Path $scriptRoot "constraints"
$baseConstraints = Join-Path $constraintsDir "base.txt"
$cudaConstraints = Join-Path $constraintsDir "cuda.txt"
$directmlConstraints = Join-Path $constraintsDir "directml.txt"
$allowPypiCore = ($env:STEMWERK_ALLOW_PYPI_CORE -eq "1")
$supportedPythonText = "3.11 or 3.12"

function TestCoreSourceBundle([string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
    if (-not (Test-Path $Root)) { return $false }
    return (
        (Test-Path (Join-Path $Root "pyproject.toml")) -and
        (Test-Path (Join-Path $Root "src\\stemwerk_core\\__init__.py")) -and
        (Test-Path (Join-Path $Root "src\\stemwerk_core\\separator.py"))
    )
}

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

function LogStatusDetail([string]$Message) {
    if ([string]::IsNullOrWhiteSpace($Message)) { return }
    LogProgress ("STEMWERK_STATUS detail=" + $Message)
}

function WriteBootstrapGuard([string]$GuardStatus, [string]$GuardReason) {
    if ([string]::IsNullOrWhiteSpace($RuntimeBase)) { return }
    $guardPath = Join-Path $RuntimeBase "state\\bootstrap.guard"
    $timestamp = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $scriptPath = $PSCommandPath
    $lines = @(
        "STATUS=$GuardStatus",
        "REASON=$GuardReason",
        "SCRIPT_PATH=$scriptPath",
        "UPDATED_AT=$timestamp",
        "PID=$PID"
    )
    $lines | Out-File -FilePath $guardPath -Encoding ascii
}

function TestRuntimeWritable([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
        $probe = Join-Path $Path ".stemwerk_write_test"
        Set-Content -Path $probe -Value "ok" -Encoding ascii -Force
        Remove-Item -Path $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function LogExecutionPolicyStatus {
    try {
        $effective = [string](Get-ExecutionPolicy)
        if ([string]::IsNullOrWhiteSpace($effective)) { $effective = "Unknown" }
        LogProgress ("PowerShell execution policy (effective): " + $effective)

        $policyList = Get-ExecutionPolicy -List
        if ($policyList) {
            $parts = @()
            foreach ($entry in $policyList) {
                if ($entry -and $entry.Scope -and $entry.ExecutionPolicy) {
                    $parts += ($entry.Scope + "=" + $entry.ExecutionPolicy)
                }
            }
            if ($parts.Count -gt 0) {
                LogLine ("Execution policy list: " + ($parts -join "; "))
            }
        }

        if ($effective -eq "Restricted" -or $effective -eq "AllSigned") {
            LogStatusDetail ("PowerShell policy is restrictive (" + $effective + "). Manual script runs may need CurrentUser RemoteSigned.")
        }
    } catch {
        LogLine "Execution policy check failed"
    }
}

function WriteCapabilities([string]$Path, [string]$ProfileValue, [string]$BackendValue, [string]$BackendReasonValue, [string]$PythonPathValue, [string]$FfmpegPathValue, [string]$RuntimeBaseValue, [string]$BootstrapStatusValue, [string]$BootstrapReasonValue, [string]$VerificationValue, [string]$AudioSeparatorValue, [string]$StemwerkCoreValue) {
    $lines = @()
    $lines += "CAP_VERSION=1"
    $lines += "PROFILE=$ProfileValue"
    $lines += "BACKEND=$BackendValue"
    $lines += "BACKEND_REASON=$BackendReasonValue"
    $lines += "PYTHON_PATH=$PythonPathValue"
    $lines += "FFMPEG_PATH=$FfmpegPathValue"
    $lines += "RUNTIME_BASE=$RuntimeBaseValue"
    $lines += "BOOTSTRAP_STATUS=$BootstrapStatusValue"
    $lines += "BOOTSTRAP_REASON=$BootstrapReasonValue"
    $lines += "VERIFICATION=$VerificationValue"
    $lines += "AUDIO_SEPARATOR=$AudioSeparatorValue"
    $lines += "STEMWERK_CORE=$StemwerkCoreValue"
    $lines += "DEVICE_NAMES="
    $lines | Out-File -FilePath $Path -Encoding ascii
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

function GetTaskDetailMessage([string]$Description, [double]$ElapsedSeconds) {
    if ([string]::IsNullOrWhiteSpace($Description)) { return "" }

    if ($Description -like "Install audio-separator*") {
        if ($ElapsedSeconds -ge 45) {
            return "Installing audio-separator into the venv. Pip may still be resolving dependencies or unpacking wheels."
        }
        return "Installing audio-separator into the venv. This can take several minutes on slower systems or VMs."
    }
    if ($Description -eq "Install DirectML runtime") {
        return "Installing DirectML runtime packages (torch-directml and onnxruntime-directml)."
    }
    if ($Description -eq "Install PyTorch CUDA runtime") {
        return "Installing CUDA-enabled PyTorch packages into the venv."
    }
    if ($Description -eq "Install ONNX Runtime") {
        return "Installing the ONNX Runtime package required by the separator backend."
    }
    if ($Description -like "Install stemwerk-core*") {
        return "Installing the bundled stemwerk-core package into the Python environment."
    }
    if ($Description -eq "Create virtual environment") {
        return "Creating the Python virtual environment used by STEMwerk."
    }
    if ($Description -eq "Python installer") {
        return "Installing Python for the STEMwerk runtime."
    }
    if ($Description -eq "Install audio-separator runtime") {
        return "Installing separator runtime packages."
    }
    return ""
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
            $initialTaskDetail = GetTaskDetailMessage $Description 0
            if (-not [string]::IsNullOrWhiteSpace($initialTaskDetail)) {
                LogStatusDetail $initialTaskDetail
            }
        }
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        $null = $p.Start()
        $lastBeat = [DateTime]::UtcNow
        $startedAt = [DateTime]::UtcNow
        $stdoutSourceId = "stemwerk.stdout." + [Guid]::NewGuid().ToString()
        $stderrSourceId = "stemwerk.stderr." + [Guid]::NewGuid().ToString()

        $stdoutAction = {
            param($sender, $eventArgs)
            if ($null -ne $eventArgs.Data) {
                Add-Content -Path $Event.MessageData -Value $eventArgs.Data -Encoding ascii
            }
        }
        $stderrAction = {
            param($sender, $eventArgs)
            if ($null -ne $eventArgs.Data) {
                Add-Content -Path $Event.MessageData -Value $eventArgs.Data -Encoding ascii
            }
        }

        $stdoutHandler = Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -SourceIdentifier $stdoutSourceId -Action $stdoutAction -MessageData $LogFile
        $stderrHandler = Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived -SourceIdentifier $stderrSourceId -Action $stderrAction -MessageData $LogFile

        $p.BeginOutputReadLine()
        $p.BeginErrorReadLine()

        try {
            while (-not $p.WaitForExit(1000)) {
                if (-not [string]::IsNullOrWhiteSpace($Description)) {
                    $elapsed = [DateTime]::UtcNow - $lastBeat
                    if ($elapsed.TotalSeconds -ge 15) {
                        $totalElapsed = [DateTime]::UtcNow - $startedAt
                        LogProgress ("Still running (" + [int]$totalElapsed.TotalSeconds + "s): " + $Description + "...")
                        $taskDetail = GetTaskDetailMessage $Description $totalElapsed.TotalSeconds
                        if (-not [string]::IsNullOrWhiteSpace($taskDetail)) {
                            LogStatusDetail $taskDetail
                        }
                        $lastBeat = [DateTime]::UtcNow
                    }
                }
            }
            $p.WaitForExit()
        } finally {
            try { $p.CancelOutputRead() } catch {}
            try { $p.CancelErrorRead() } catch {}
            if ($stdoutHandler) { Unregister-Event -SourceIdentifier $stdoutSourceId -ErrorAction SilentlyContinue }
            if ($stderrHandler) { Unregister-Event -SourceIdentifier $stderrSourceId -ErrorAction SilentlyContinue }
            if ($stdoutHandler) { Remove-Job -Id $stdoutHandler.Id -Force -ErrorAction SilentlyContinue }
            if ($stderrHandler) { Remove-Job -Id $stderrHandler.Id -Force -ErrorAction SilentlyContinue }
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

function GetPythonVersionInfo([string]$Path) {
    $result = [ordered]@{
        Major = 0
        Minor = 0
        Text = ""
    }
    if (-not (TestPython $Path)) { return $result }
    try {
        $out = & $Path -c "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')" 2>&1
        if ($LASTEXITCODE -ne 0) { return $result }
        $text = [string]($out | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($text)) { return $result }
        $text = $text.Trim()
        if ($text -match "^(\d+)\.(\d+)") {
            $result.Major = [int]$matches[1]
            $result.Minor = [int]$matches[2]
            $result.Text = "$($result.Major).$($result.Minor)"
        }
    } catch {
    }
    return $result
}

function IsSupportedPythonVersion($VersionInfo) {
    if (-not $VersionInfo) { return $false }
    return ($VersionInfo.Major -eq 3 -and $VersionInfo.Minor -ge 11 -and $VersionInfo.Minor -le 12)
}

function TestSupportedPython([string]$Path) {
    if (-not (TestPython $Path)) { return $false }
    return (IsSupportedPythonVersion (GetPythonVersionInfo $Path))
}

function LogUnsupportedPython([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $info = GetPythonVersionInfo $Path
    if ($info.Text -ne "") {
        LogProgress ("Ignoring unsupported Python " + $info.Text + " at " + $Path + " (need " + $supportedPythonText + ")")
    } else {
        LogProgress ("Ignoring unusable Python at " + $Path)
    }
}

function InstallPythonDirect {
    $pyInstaller = Join-Path $RuntimeBase "bin\\python-installer.exe"
    if (Test-Path $bundledPythonInstaller) {
        try {
            LogProgress ("Using bundled Python installer: " + $bundledPythonInstaller)
            Copy-Item -Path $bundledPythonInstaller -Destination $pyInstaller -Force
        } catch {
            LogLine "Bundled Python installer copy failed"
            return $null
        }
    } else {
        try {
            LogProgress ("Downloading Python installer: " + $pythonInstallerUrl)
            Invoke-WebRequest -Uri $pythonInstallerUrl -OutFile $pyInstaller -UseBasicParsing | Out-Null
        } catch {
            LogLine "Python download failed"
            return $null
        }
    }
    LogProgress "Installing Python silently (per-user)"
    RunHidden $pyInstaller @("/quiet","InstallAllUsers=0","Include_test=0","Include_pip=1","PrependPath=0","Shortcuts=0") "Python installer" | Out-Null
    $p11 = Join-Path $localAppData "Programs\\Python\\Python311\\python.exe"
    if (TestPython $p11) { return $p11 }
    return $null
}

function InstallFfmpegDirect {
    $zipPath = Join-Path $RuntimeBase "ffmpeg\\ffmpeg.zip"
    if (Test-Path $bundledFfmpegZip) {
        try {
            LogProgress ("Using bundled FFmpeg archive: " + $bundledFfmpegZip)
            Copy-Item -Path $bundledFfmpegZip -Destination $zipPath -Force
        } catch {
            LogLine "Bundled FFmpeg archive copy failed"
            return $null
        }
    } else {
        try {
            LogProgress ("Downloading FFmpeg (gyan.dev release): " + $ffmpegArchiveUrl)
            Invoke-WebRequest -Uri $ffmpegArchiveUrl -OutFile $zipPath -UseBasicParsing | Out-Null
        } catch {
            LogLine "FFmpeg download failed"
            return $null
        }
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
    if ($p.Contains("\winget\links\ffmpeg.exe") -or $p.Contains("\windowsapps\ffmpeg")) { return $true }
    if ($p.Contains("\microsoft\winget\packages\") -and $p.Contains("\ffmpeg")) { return $true }
    return $false
}

function ResolveCoreInstallTarget([string]$Extra) {
    $result = [ordered]@{ Target = $null; Description = ""; SupportsExtras = $false }

    if ($env:STEMWERK_CORE_PATH) {
        $candidate = $env:STEMWERK_CORE_PATH
        if ($candidate -and (Test-Path $candidate)) {
            if (TestCoreSourceBundle $candidate) {
                $result.Target = $candidate
                $result.Description = "STEMWERK_CORE_PATH source"
                $result.SupportsExtras = $true
                return $result
            }
            LogLine "STEMWERK_CORE_PATH is set but incomplete: $candidate"
            LogLine "Required: pyproject.toml, src\\stemwerk_core\\__init__.py, src\\stemwerk_core\\separator.py"
        } else {
            LogLine "STEMWERK_CORE_PATH is set but missing: $candidate"
        }
    }

    $bundleDir = $env:STEMWERK_CORE_BUNDLE_DIR
    if (-not $bundleDir -or $bundleDir -eq "") { $bundleDir = $bundledCoreDir }
    if ($bundleDir -and (Test-Path $bundleDir)) {
        if (TestCoreSourceBundle $bundleDir) {
            $result.Target = $bundleDir
            $result.Description = "bundled source"
            $result.SupportsExtras = $true
            return $result
        }
        LogLine "Bundled stemwerk-core source is incomplete: $bundleDir"
        LogLine "Required: pyproject.toml, src\\stemwerk_core\\__init__.py, src\\stemwerk_core\\separator.py"
    }

    return $result
}

function HasBundledWheels {
    if ([string]::IsNullOrWhiteSpace($bundledWheelsDir)) { return $false }
    if (-not (Test-Path $bundledWheelsDir)) { return $false }
    $wheel = Get-ChildItem -Path $bundledWheelsDir -Filter "*.whl" -Recurse | Select-Object -First 1
    return ($null -ne $wheel)
}

function GetPipOfflineArgs {
    if (HasBundledWheels) {
        return @("--no-index", "--find-links", $bundledWheelsDir)
    }
    return @()
}

function InstallWithPip([string]$PythonPath, [string[]]$InstallArgs, [string]$Description) {
    $args = @("-m", "pip", "install")
    $args += GetPipOfflineArgs
    $args += $InstallArgs
    RunHidden $PythonPath $args $Description | Out-Null
}

function InstallBackendRuntime([string]$PythonPath, [string]$BackendName) {
    if ([string]::IsNullOrWhiteSpace($PythonPath)) { return $false }
    if ([string]::IsNullOrWhiteSpace($BackendName) -or $BackendName -eq "cpu") { return $true }

    if ($BackendName -eq "cuda") {
        LogProgress "Installing PyTorch CUDA runtime"
        $torchCudaReq = "torch==$torchVersion$torchCudaSuffix"
        $torchVisionCudaReq = "torchvision==$torchVisionVersion$torchCudaSuffix"
        $installArgs = @(
            "--upgrade","--force-reinstall",
            "--index-url",$pytorchCudaIndex,
            "-c",$baseConstraints,
            "-c",$cudaConstraints,
            "numpy<2",
            $torchCudaReq,
            $torchVisionCudaReq
        )
        # Offline bundle mode cannot satisfy CUDA index installs unless explicit wheels are bundled.
        if (HasBundledWheels) {
            $installArgs = @(
                "--upgrade","--force-reinstall",
                "-c",$baseConstraints,
                "-c",$cudaConstraints,
                "numpy<2",
                $torchCudaReq,
                $torchVisionCudaReq
            )
        }
        InstallWithPip $PythonPath $installArgs "Install PyTorch CUDA runtime"
        return ($LASTEXITCODE -eq 0)
    }

    if ($BackendName -eq "directml") {
        LogProgress "Installing DirectML runtime packages"
        InstallWithPip $PythonPath @(
            "--upgrade",
            "-c",$baseConstraints,
            "-c",$directmlConstraints,
            "numpy<2",
            "torch==$torchVersion",
            "torchvision==$torchVisionVersion",
            "torch-directml==$torchDirectMlVersion",
            "onnxruntime-directml==$onnxRuntimeDirectMlVersion"
        ) "Install DirectML runtime"
        return ($LASTEXITCODE -eq 0)
    }

    return $false
}

function VerifyBackendRuntime([string]$PythonPath, [string]$BackendName) {
    if ([string]::IsNullOrWhiteSpace($PythonPath)) { return $false }
    if ([string]::IsNullOrWhiteSpace($BackendName) -or $BackendName -eq "cpu") { return $true }

    if ($BackendName -eq "cuda") {
        $code = 'import sys, torch; avail=bool(torch.cuda.is_available()); count=int(torch.cuda.device_count()) if avail else 0; ver=getattr(torch.version,"cuda",None); print(f"STEMWERK_CUDA_CHECK avail={avail} count={count} version={ver}"); sys.exit(0 if (avail and count > 0 and ver) else 1)'
        RunHidden $PythonPath @("-c", $code) "Verify CUDA runtime" | Out-Null
        return ($LASTEXITCODE -eq 0)
    }

    if ($BackendName -eq "directml") {
        $code = 'import sys, torch, torch_directml, onnxruntime as ort; count=int(torch_directml.device_count()); providers=ort.get_available_providers() or []; has_dml="DmlExecutionProvider" in providers; print(f"STEMWERK_DIRECTML_CHECK count={count} torch={getattr(torch, ''__version__'', '''')} has_dml={has_dml} providers={providers}"); sys.exit(0 if (count > 0 and has_dml) else 1)'
        RunHidden $PythonPath @("-c", $code) "Verify DirectML runtime" | Out-Null
        return ($LASTEXITCODE -eq 0)
    }

    return $false
}

function GetAudioConstraints([string]$BackendName) {
    $args = @("-c", $baseConstraints)
    if ($BackendName -eq "directml") {
        $args += @("-c", $directmlConstraints)
    }
    return $args
}

function GetOnnxRuntimePackage([string]$BackendName) {
    if ($BackendName -eq "directml") {
        return "onnxruntime-directml==$onnxRuntimeDirectMlVersion"
    }
    return "onnxruntime"
}

function GetAudioRuntimeDependencyList([string]$BackendName) {
    $deps = @(
        "beartype>=0.18.5,<0.19.0",
        "diffq-fixed>=0.2",
        "einops>=0.7",
        "librosa>=0.10",
        "ml_collections",
        "numpy<2",
        "onnx>=1.14",
        "onnx2torch>=1.5",
        "pydub>=0.25",
        "pyyaml",
        "requests>=2",
        "resampy>=0.4",
        "rotary-embedding-torch>=0.6.1,<0.7.0",
        "scipy>=1.13.0,<2.0.0",
        "six>=1.16",
        "tqdm",
        "soundfile>=0.12.1"
    )

    if ($BackendName -eq "directml") {
        $deps += @("torch==$torchVersion", "torchvision==$torchVisionVersion", "torch-directml==$torchDirectMlVersion", "onnxruntime-directml==$onnxRuntimeDirectMlVersion")
    } elseif ($BackendName -eq "cuda") {
        $deps += @("torch==$torchVersion$torchCudaSuffix", "torchvision==$torchVisionVersion$torchCudaSuffix", "onnxruntime")
    } else {
        $deps += @("torch==$torchVersion", "torchvision==$torchVisionVersion", "onnxruntime")
    }
    return $deps
}

function InstallAudioRuntimeDependencies([string]$PythonPath, [string]$BackendName) {
    if ([string]::IsNullOrWhiteSpace($PythonPath)) { return $false }
    $deps = GetAudioRuntimeDependencyList $BackendName
    $args = @("--upgrade")
    if ($BackendName -eq "cuda" -and -not (HasBundledWheels)) {
        $args += @("--extra-index-url", $pytorchCudaIndex)
    }
    $args += GetAudioConstraints $BackendName
    $args += $deps
    LogProgress "Installing curated audio runtime dependencies"
    InstallWithPip $PythonPath $args "Install audio runtime dependencies"
    return ($LASTEXITCODE -eq 0)
}

function EnsureJuliusRuntime([string]$PythonPath) {
    if ([string]::IsNullOrWhiteSpace($PythonPath)) { return $false }

    RunHidden $PythonPath @("-c", "import julius") "Verify julius runtime" | Out-Null
    if ($LASTEXITCODE -eq 0) {
        return $true
    }

    if (-not (Test-Path (Join-Path $bundledJuliusDir "pyproject.toml"))) {
        LogLine ("Bundled julius fallback is missing: " + $bundledJuliusDir)
        return $false
    }

    LogProgress "Installing bundled julius fallback"
    InstallWithPip $PythonPath @("--upgrade", "--force-reinstall", "--no-build-isolation", "--no-deps", $bundledJuliusDir) "Install julius fallback"
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    RunHidden $PythonPath @("-c", "import julius") "Verify julius runtime" | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function EnsureSamplerateRuntime([string]$PythonPath, [string]$BackendName) {
    if ([string]::IsNullOrWhiteSpace($PythonPath)) { return $false }

    RunHidden $PythonPath @("-c", "import samplerate") "Verify samplerate runtime" | Out-Null
    if ($LASTEXITCODE -eq 0) {
        return $true
    }

    LogStatusDetail "samplerate dependency is missing. Attempting automatic repair."
    $samplerateArgs = @("--upgrade")
    $samplerateArgs += GetAudioConstraints $BackendName
    $samplerateArgs += "samplerate==0.1.0"
    InstallWithPip $PythonPath $samplerateArgs "Install samplerate runtime"

    RunHidden $PythonPath @("-c", "import samplerate") "Verify samplerate runtime" | Out-Null
    if ($LASTEXITCODE -eq 0) {
        return $true
    }

    LogLine "samplerate runtime is still missing after repair attempt."
    LogStatusDetail "samplerate is still missing after repair. Offline/bundled setup cannot continue as OK; run SETUP/Repair."
    return $false
}

function EnsureOnnxRuntime([string]$PythonPath, [string]$BackendName) {
    if ([string]::IsNullOrWhiteSpace($PythonPath)) { return $false }

    if ($BackendName -eq "directml") {
        $verifyCode = 'import sys, onnxruntime as ort; providers=ort.get_available_providers() or []; has_dml="DmlExecutionProvider" in providers; print(f"STEMWERK_ONNX_CHECK backend=directml has_dml={has_dml} providers={providers}"); sys.exit(0 if has_dml else 1)'
    } else {
        $verifyCode = 'import onnxruntime as ort; print(f"STEMWERK_ONNX_CHECK backend=cpu version={getattr(ort, ''__version__'', '''')}")'
    }

    RunHidden $PythonPath @("-c", $verifyCode) "Verify ONNX Runtime" | Out-Null
    if ($LASTEXITCODE -eq 0) {
        return $true
    }

    $onnxPackage = GetOnnxRuntimePackage $BackendName
    $onnxArgs = @("--upgrade")
    $onnxArgs += GetAudioConstraints $BackendName
    $onnxArgs += $onnxPackage
    LogProgress ("Installing " + $onnxPackage)
    InstallWithPip $PythonPath $onnxArgs "Install ONNX Runtime"
    if ($LASTEXITCODE -ne 0) {
        return $false
    }

    RunHidden $PythonPath @("-c", $verifyCode) "Verify ONNX Runtime" | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function VerifyAudioSeparatorRuntime([string]$PythonPath, [string]$BackendName) {
    if ([string]::IsNullOrWhiteSpace($PythonPath)) { return $false }

    $verifyCode = 'import audio_separator, onnxruntime; from audio_separator.separator import Separator; print("STEMWERK_AUDIO_SEPARATOR_CHECK ok=1")'
    RunHidden $PythonPath @("-c", $verifyCode) "Verify audio-separator runtime" | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function InstallAndVerifyAudioSeparator([string]$PythonPath, [string]$BackendName, [string]$PackageName, [string]$Description) {
    if ([string]::IsNullOrWhiteSpace($PythonPath)) { return "audio_separator_install_failed" }
    if ([string]::IsNullOrWhiteSpace($PackageName)) { return "audio_separator_install_failed" }

    $audioConstraints = GetAudioConstraints $BackendName
    $audioArgs = @()
    if ($BackendName -ne "directml") {
        $audioArgs += "--upgrade"
    }
    $audioArgs += $audioConstraints
    $audioArgs += "--no-deps"
    $audioArgs += $PackageName

    LogProgress ("Installing " + $PackageName)
    LogLine ("Installing " + $PackageName)
    InstallWithPip $PythonPath $audioArgs $Description
    if ($LASTEXITCODE -ne 0) {
        return "audio_separator_install_failed"
    }

    if (-not (InstallAudioRuntimeDependencies $PythonPath $BackendName)) {
        return "audio_runtime_deps_install_failed"
    }

    if (-not (EnsureJuliusRuntime $PythonPath)) {
        return "julius_install_failed"
    }

    $script:samplerateOk = EnsureSamplerateRuntime $PythonPath $BackendName
    if (-not $script:samplerateOk) {
        return "samplerate_install_failed"
    }

    if (-not (EnsureOnnxRuntime $PythonPath $BackendName)) {
        return "onnxruntime_install_failed"
    }

    if (-not (VerifyAudioSeparatorRuntime $PythonPath $BackendName)) {
        return "audio_separator_runtime_check_failed"
    }

    return "ok"
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
WriteBootstrapGuard "running" "bootstrap_running"
if (-not (TestRuntimeWritable $RuntimeBase)) {
    LogLine ("Runtime base is not writable: " + $RuntimeBase)
    Set-Status "deps_failed" "runtime_write_test_failed"
    WriteBootstrapGuard "failed" "runtime_write_test_failed"
    exit 1
}
if (-not (TestRuntimeWritable (Join-Path $RuntimeBase "state"))) {
    LogLine ("Runtime state directory is not writable: " + (Join-Path $RuntimeBase "state"))
    Set-Status "deps_failed" "runtime_write_test_failed"
    WriteBootstrapGuard "failed" "runtime_write_test_failed"
    exit 1
}
if (-not (TestRuntimeWritable (Join-Path $RuntimeBase "logs"))) {
    LogLine ("Runtime logs directory is not writable: " + (Join-Path $RuntimeBase "logs"))
    Set-Status "deps_failed" "runtime_write_test_failed"
    WriteBootstrapGuard "failed" "runtime_write_test_failed"
    exit 1
}
LogProgress ("Runtime write test passed: " + $RuntimeBase)
LogExecutionPolicyStatus

Step "step_2_python" "python + venv"
LogProgress "Looking for existing Python installations"
if ((Test-Path $venvPy) -and -not (TestSupportedPython $venvPy)) {
    LogUnsupportedPython $venvPy
    LogProgress "Removing incompatible virtual environment"
    Remove-Item -Path (Join-Path $RuntimeBase ".venv") -Recurse -Force -ErrorAction SilentlyContinue
}
foreach ($p in $candidates) {
    if ($p -and (Test-Path $p) -and -not (IsWindowsStorePython $p)) {
        if (TestSupportedPython $p) {
            $python = $p
            break
        }
        LogUnsupportedPython $p
    }
}

if (-not $python) {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($cmd -and -not (IsWindowsStorePython $cmd.Source)) {
        if (TestSupportedPython $cmd.Source) {
            $python = $cmd.Source
        } else {
            LogUnsupportedPython $cmd.Source
        }
    }
}

if ($python -and -not (TestSupportedPython $python)) {
    LogUnsupportedPython $python
    $python = $null
}

if (-not $python) {
    LogProgress "Python not found; attempting direct install"
    $python = InstallPythonDirect
    if ($python -and -not (TestSupportedPython $python)) {
        LogUnsupportedPython $python
        $python = $null
    }
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
    $package = "audio-separator[gpu]==$audioSeparatorVersion"
    $coreExtra = "[gpu]"
} elseif ($hasAmd -or $hasIntel) {
    $profile = "windows-directml"
    $backend = "directml"
    $package = "audio-separator==$audioSeparatorVersion"
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
        $pipBootstrap = @("--upgrade", "pip", "setuptools", "wheel")
        InstallWithPip $python $pipBootstrap "Upgrade pip"
        if ($LASTEXITCODE -ne 0) {
            Set-Status "pip_failed" "pip_upgrade_failed"
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
        LogLine "stemwerk-core source bundle is missing or incomplete."
        LogLine ("Expected bundle directory: " + $bundledCoreDir)
        LogLine "Required files: pyproject.toml, src\\stemwerk_core\\__init__.py, src\\stemwerk_core\\separator.py"
        LogLine "Recovery: re-run the Windows installer to repair or reinstall STEMwerk."
        if ($allowPypiCore) {
            LogLine "Note: STEMWERK_ALLOW_PYPI_CORE is ignored for release safety; bundled source is required."
        }
        Set-Status "deps_failed" "stemwerk_core_bundle_incomplete"
        WriteBootstrapGuard "failed" "stemwerk_core_bundle_incomplete"
        exit 1
    } else {
        $installTarget = $coreTarget.Target
        if ($coreTarget.SupportsExtras -and $coreExtra -ne "") {
            $installTarget = "$installTarget$coreExtra"
        }
        LogProgress ("Installing stemwerk-core from " + $coreTarget.Description)
        LogLine ("Installing stemwerk-core from " + $coreTarget.Description + ": " + $installTarget)
        InstallWithPip $python @(
            "--upgrade",
            "--force-reinstall",
            "--no-build-isolation",
            "-c",$baseConstraints,
            $installTarget
        ) "Install stemwerk-core"
        if ($LASTEXITCODE -ne 0 -and $coreExtra -ne "" -and $coreTarget.SupportsExtras) {
            LogLine "GPU/DirectML stemwerk-core install failed; falling back to CPU"
            $coreExtra = ""
            $profile = "windows-cpu"
            $backend = "cpu"
            $backendReason = "backend_install_failed"
            $installTarget = $coreTarget.Target
            LogLine ("Installing stemwerk-core from " + $coreTarget.Description + ": " + $installTarget)
            InstallWithPip $python @(
                "--upgrade",
                "--force-reinstall",
                "--no-build-isolation",
                "-c",$baseConstraints,
                $installTarget
            ) "Install stemwerk-core (CPU fallback)"
        }
        if ($LASTEXITCODE -ne 0) {
            Set-Status "deps_failed" "stemwerk_core_install_failed"
        }
    }

    if ($status -eq "ok" -and $backend -ne "cpu" -and $backend -ne "cuda") {
        $requestedBackend = $backend
        if (-not (InstallBackendRuntime $python $requestedBackend)) {
            LogLine ("Backend runtime install failed for " + $requestedBackend + "; falling back to CPU")
            $profile = "windows-cpu"
            $backend = "cpu"
            $package = "audio-separator==$audioSeparatorVersion"
            $backendReason = "backend_runtime_install_failed"
        } elseif (-not (VerifyBackendRuntime $python $requestedBackend)) {
            LogLine ("Backend runtime verify failed for " + $requestedBackend + "; falling back to CPU")
            $profile = "windows-cpu"
            $backend = "cpu"
            $package = "audio-separator==$audioSeparatorVersion"
            $backendReason = "backend_runtime_verify_failed"
        }
    }

    $audioInstallResult = InstallAndVerifyAudioSeparator $python $backend $package "Install audio-separator"
    $audioSeparatorOk = ($audioInstallResult -eq "ok")
    if (-not $audioSeparatorOk) {
        if ($package -ne ("audio-separator==$audioSeparatorVersion")) {
            LogLine "GPU audio-separator install failed; falling back to CPU"
            $package = "audio-separator==$audioSeparatorVersion"
            $profile = "windows-cpu"
            $backend = "cpu"
            if (-not $backendReason) { $backendReason = "backend_install_failed" }
            $audioInstallResult = InstallAndVerifyAudioSeparator $python $backend $package "Install audio-separator (CPU fallback)"
            $audioSeparatorOk = ($audioInstallResult -eq "ok")
        }
        if (-not $audioSeparatorOk) {
            Set-Status "deps_failed" $audioInstallResult
        }
    }

    if ($status -eq "ok" -and $backend -eq "cuda") {
        $requestedBackend = $backend
        if (-not (InstallBackendRuntime $python $requestedBackend)) {
            LogLine ("Backend runtime install failed for " + $requestedBackend + "; falling back to CPU")
            $profile = "windows-cpu"
            $backend = "cpu"
            $backendReason = "backend_runtime_install_failed"
        } elseif (-not (VerifyBackendRuntime $python $requestedBackend)) {
            LogLine ("Backend runtime verify failed for " + $requestedBackend + "; falling back to CPU")
            $profile = "windows-cpu"
            $backend = "cpu"
            $backendReason = "backend_runtime_verify_failed"
        }
    }

    RunHidden $python @("-c","import stemwerk_core") "Verify stemwerk-core" | Out-Null
    $stemwerkCoreOk = ($LASTEXITCODE -eq 0)
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
if (Test-Path $venvPy) { $lines += "VENV_PYTHON=$venvPy" }
if ($ffmpeg) { $lines += "FFMPEG_PATH=$ffmpeg" }
if ($installerMode) { $lines += "INSTALLER=1" }
if ($RuntimeBase) { $lines += "RUNTIME_BASE=$RuntimeBase" }

$lines | Out-File -FilePath $StateFile -Encoding ascii

if ($RuntimeBase) {
    $capPath = Join-Path $RuntimeBase "state\\capabilities.env"
    $bootstrapStatusValue = $status
    $bootstrapReasonValue = $statusReason
    $verificationValue = if (($status -eq "ok") -and $audioSeparatorOk -and $stemwerkCoreOk -and $samplerateOk) { "ok" } else { "failed" }
    $audioSeparatorValue = if ($audioSeparatorOk) { "ok" } else { "missing" }
    $stemwerkCoreValue = if ($stemwerkCoreOk) { "ok" } else { "missing" }
    $pythonValue = if ($python) { $python } else { "" }
    $ffmpegValue = if ($ffmpeg) { $ffmpeg } else { "" }
    WriteCapabilities $capPath $profile $backend $backendReason $pythonValue $ffmpegValue $RuntimeBase $bootstrapStatusValue $bootstrapReasonValue $verificationValue $audioSeparatorValue $stemwerkCoreValue

    $guardStatus = if ($status -eq "ok") { "ok" } else { "failed" }
    $guardReason = if ($status -eq "ok") { "completed" } else { $statusReason }
    WriteBootstrapGuard $guardStatus $guardReason
}

if ($status -ne "ok") {
    exit 1
}
LogProgress "Bootstrap complete"
exit 0
