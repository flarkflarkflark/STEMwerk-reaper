param(
    [string]$RuntimeBase = "",
    [string]$StateFile = "",
    [string]$LogFile = "",
    [string]$Mode = "repair"
)

$ErrorActionPreference = "SilentlyContinue"

function LogLine([string]$Message) {
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        Add-Content -Path $LogFile -Value $Message -Encoding ascii
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

if ([string]::IsNullOrWhiteSpace($RuntimeBase)) {
    Write-Error "Missing runtime base"
    exit 1
}

$RuntimeBase = Normalize-WindowsPath $RuntimeBase

if ([string]::IsNullOrWhiteSpace($StateFile)) {
    $StateFile = Join-NormalizedWindowsPath $RuntimeBase @("state", "bootstrap.env")
}
if ([string]::IsNullOrWhiteSpace($LogFile)) {
    $LogFile = Join-NormalizedWindowsPath $RuntimeBase @("logs", "bootstrap.log")
}

$StateFile = Normalize-WindowsPath $StateFile
$LogFile = Normalize-WindowsPath $LogFile

New-Item -ItemType Directory -Force -Path (Join-NormalizedWindowsPath $RuntimeBase @("state")) | Out-Null
New-Item -ItemType Directory -Force -Path (Join-NormalizedWindowsPath $RuntimeBase @("logs")) | Out-Null
New-Item -ItemType Directory -Force -Path (Join-NormalizedWindowsPath $RuntimeBase @("bin")) | Out-Null
New-Item -ItemType Directory -Force -Path (Join-NormalizedWindowsPath $RuntimeBase @("ffmpeg")) | Out-Null
New-Item -ItemType Directory -Force -Path (Join-NormalizedWindowsPath $RuntimeBase @("python")) | Out-Null

$status = "ok"
$statusReason = ""
$audioSeparatorVersion = "0.24.4"
$drumsepAudioSeparatorVersion = "0.34.1"
$drumsepNumpyVersion = "2.4.6"
$drumsepOnnxRuntimeVersion = "1.26.0"
$drumsepOnnxVersion = "1.21.0"
$drumsepOnnx2TorchVersion = "1.5.15"
$drumsepOnnx2TorchPy313Version = "1.6.0"
$drumsepTorchVersion = "2.12.0"
$drumsepTorchVisionVersion = "0.27.0"
$drumsepLlvmliteVersion = "0.47.0"
$drumsepNumbaVersion = "0.65.1"
$drumsepDirectMlLibrosaVersion = "0.11.0"
$drumsepDirectMlSamplerateVersion = "0.1.0"
$drumsepDirectMlSoundFileVersion = "0.14.0"
$drumsepModelEntryName = "MDX23C Model: DrumSep 6stem | (by aufr33 & jarredou)"
$drumsepModelFileName = "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt"
$drumsepModelYamlName = "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
$drumsepModelCkptUrl = "https://huggingface.co/KitsuneX07/Music_Source_Sepetration_Models/resolve/8309883c6b3fecc360fff24c932dcc588f8c23c2/multi_stem_models/aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt?download=true"
$drumsepModelYamlUrl = "https://raw.githubusercontent.com/TRvlvr/application_data/main/mdx_model_data/mdx_c_configs/aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
$drumsepModelCkptMinimumBytes = 104857600
$drumsepModelYamlMinimumBytes = 128
$torchVersion = "2.4.1"
$torchVisionVersion = "0.19.1"
$torchAudioVersion = "2.4.1"
$torchCudaSuffix = "+cu121"
$torchDirectMlVersion = "0.2.5.dev240914"
$onnxRuntimeGpuVersion = "1.24.4"
$onnxRuntimeDirectMlVersion = "1.24.4"
$audioSeparatorOk = $false
$stemwerkCoreOk = $false
$samplerateOk = $false
$juliusOk = $false
$pytorchCudaIndex = "https://download.pytorch.org/whl/cu121"
$package = "audio-separator==$audioSeparatorVersion"
$coreExtra = ""
$profile = "windows-cpu"
$backend = "cpu"
$backendReason = ""
$python = $null
$ffmpeg = $null
$venvPy = Join-NormalizedWindowsPath $RuntimeBase @(".venv", "Scripts", "python.exe")
$installerMode = ($env:STEMWERK_INSTALLER -eq "1")
$offlineBundledAllmodelsMode = ($env:STEMWERK_OFFLINE_BUNDLED_ALLMODELS -eq "1")
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$bundledRuntimeDir = Join-NormalizedWindowsPath $scriptRoot @("_bundled")
$pythonInstallerFileName = "python-3.11.8-amd64.exe"
$pythonInstallerUrl = "https://www.python.org/ftp/python/3.11.8/$pythonInstallerFileName"
$ffmpegArchiveFileName = "ffmpeg-release-essentials.zip"
$ffmpegArchiveUrl = "https://www.gyan.dev/ffmpeg/builds/$ffmpegArchiveFileName"
$bundledPythonInstaller = Join-NormalizedWindowsPath $bundledRuntimeDir @("python", $pythonInstallerFileName)
$bundledFfmpegZip = Join-NormalizedWindowsPath $bundledRuntimeDir @("ffmpeg", $ffmpegArchiveFileName)
$script:FfmpegSource = "missing"
$bundledWheelsDir = Join-NormalizedWindowsPath $bundledRuntimeDir @("wheels")
$bundledDrumsepWheelsDir = Join-NormalizedWindowsPath $bundledRuntimeDir @("drumsep-wheels")
$bundledDrumsepModelsDir = Join-NormalizedWindowsPath $bundledRuntimeDir @("drumsep-models")
$bundledCoreDir = Join-NormalizedWindowsPath $scriptRoot @("vendor", "stemwerk-core")
$bundledJuliusDir = Join-NormalizedWindowsPath $scriptRoot @("vendor", "julius")
$constraintsDir = Join-NormalizedWindowsPath $scriptRoot @("constraints")
$baseConstraints = Join-NormalizedWindowsPath $constraintsDir @("base.txt")
$cudaConstraints = Join-NormalizedWindowsPath $constraintsDir @("cuda.txt")
$directmlConstraints = Join-NormalizedWindowsPath $constraintsDir @("directml.txt")
$allowPypiCore = ($env:STEMWERK_ALLOW_PYPI_CORE -eq "1")
$supportedPythonText = "3.11 or 3.12"
$script:DrumsepOfflinePayloadStatus = if ($offlineBundledAllmodelsMode) { "pending" } else { "" }
$script:DrumsepOfflinePayloadSource = if ($offlineBundledAllmodelsMode) { "bundled" } else { "" }
$script:DrumsepOfflinePayloadReason = ""
$script:DrumsepModelSource = ""
$script:DrumsepRuntimeWheelSource = ""

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

function WriteBootstrapGuard([string]$GuardStatus, [string]$GuardReason, [string]$GuardPid) {
    if ([string]::IsNullOrWhiteSpace($RuntimeBase)) { return }
    $guardPath = Join-NormalizedWindowsPath $RuntimeBase @("state", "bootstrap.guard")
    $timestamp = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $scriptPath = $PSCommandPath
    $pidValue = if ($PSBoundParameters.ContainsKey("GuardPid")) { $GuardPid } else { [string]$PID }
    $lines = @(
        "STATUS=$GuardStatus",
        "REASON=$GuardReason",
        "SCRIPT_PATH=$scriptPath",
        "UPDATED_AT=$timestamp",
        "PID=$pidValue"
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
    $effective = "Unknown"
    try {
        $effective = [string](Get-ExecutionPolicy)
        if ([string]::IsNullOrWhiteSpace($effective)) { $effective = "Unknown" }
        LogProgress ("PowerShell execution policy (effective): " + $effective)
    } catch {
        LogLine "Execution policy effective-value probe failed"
        return
    }

    try {
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
    } catch {
        LogLine "Execution policy scope-list probe unavailable; effective policy remains authoritative"
    }

    if ($effective -eq "Restricted" -or $effective -eq "AllSigned") {
        LogProgress "EXECUTION_POLICY_STATUS=failed"
        LogStatusDetail ("PowerShell policy is restrictive (" + $effective + "). Manual script runs may need CurrentUser RemoteSigned.")
        Set-Status "failed" "execution_policy_restricted"
    } else {
        LogProgress "EXECUTION_POLICY_STATUS=ok"
    }
}

function WriteCapabilities([string]$Path, [string]$ProfileValue, [string]$BackendValue, [string]$BackendReasonValue, [string]$PythonPathValue, [string]$FfmpegPathValue, [string]$RuntimeBaseValue, [string]$BootstrapStatusValue, [string]$BootstrapReasonValue, [string]$VerificationValue, [string]$AudioSeparatorValue, [string]$StemwerkCoreValue, [string]$SamplerateValue, [string]$JuliusValue) {
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
    $lines += "SAMPLERATE=$SamplerateValue"
    $lines += "JULIUS=$JuliusValue"
    $lines += "DEVICE_NAMES="
    $tmpPath = $Path + ".tmp"
    $lastErrorMessage = ""
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $parent = Split-Path -Parent $Path
            if (-not [string]::IsNullOrWhiteSpace($parent)) {
                New-Item -ItemType Directory -Force -Path $parent | Out-Null
            }
            $lines | Out-File -FilePath $tmpPath -Encoding ascii
            if (Test-Path $Path) {
                [System.IO.File]::Copy($tmpPath, $Path, $true)
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            } else {
                Move-Item -Force -Path $tmpPath -Destination $Path
            }
            return $true
        } catch {
            $lastErrorMessage = $_.Exception.Message
            Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            if ($attempt -lt 3) {
                Start-Sleep -Milliseconds (100 * $attempt)
            }
        }
    }
    LogLine ("WARN: failed to write capabilities file: " + $Path + " (" + $lastErrorMessage + ")")
    return $false
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
$script:StepTotal = 5
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
    $pyInstaller = Join-NormalizedWindowsPath $RuntimeBase @("bin", "python-installer.exe")
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
    $p11 = Join-NormalizedWindowsPath $localAppData @("Programs", "Python", "Python311", "python.exe")
    if (TestPython $p11) { return $p11 }
    return $null
}

function InstallFfmpegDirect {
    $zipPath = Join-NormalizedWindowsPath $RuntimeBase @("ffmpeg", "ffmpeg.zip")
    if (Test-Path $bundledFfmpegZip) {
        $script:FfmpegSource = "bundled"
        try {
            LogStatusDetail "Installing bundled FFmpeg..."
            LogProgress "FFMPEG_SOURCE=bundled"
            LogProgress ("Using bundled FFmpeg archive: " + $bundledFfmpegZip)
            Copy-Item -Path $bundledFfmpegZip -Destination $zipPath -Force
        } catch {
            LogLine "Bundled FFmpeg archive copy failed"
            return $null
        }
    } else {
        $script:FfmpegSource = "download"
        try {
            LogStatusDetail "Downloading FFmpeg..."
            LogProgress "FFMPEG_SOURCE=download"
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
        if ($script:FfmpegSource -eq "bundled") {
            LogProgress ("Bundled FFmpeg archive ready: " + $zipMb + " MB")
        } else {
            LogProgress ("Downloaded FFmpeg archive: " + $zipMb + " MB")
        }
    }
    try {
        if ($script:FfmpegSource -eq "bundled") {
            LogStatusDetail "Extracting bundled FFmpeg..."
            LogProgress "Extracting bundled FFmpeg archive (this can take a moment)"
        } else {
            LogStatusDetail "Extracting FFmpeg..."
            LogProgress "Extracting FFmpeg archive (this can take a moment)"
        }
        Expand-Archive -Path $zipPath -DestinationPath (Join-NormalizedWindowsPath $RuntimeBase @("ffmpeg")) -Force
    } catch {
        LogLine "FFmpeg extract failed"
        return $null
    }
    LogProgress "Searching extracted files for ffmpeg.exe"
    $ff = Get-ChildItem -Path (Join-NormalizedWindowsPath $RuntimeBase @("ffmpeg")) -Filter "ffmpeg.exe" -Recurse | Select-Object -First 1
    if ($ff) { return $ff.FullName }
    LogLine "FFmpeg binary not found after extract"
    return $null
}

function ResolveWindowsFfmpegPath([switch]$AllowInstall) {
    $ffmpegCandidates = @(
        (Join-NormalizedWindowsPath $RuntimeBase @("bin", "ffmpeg.exe")),
        (Join-NormalizedWindowsPath $RuntimeBase @("ffmpeg", "bin", "ffmpeg.exe")),
        (Join-NormalizedWindowsPath $localAppData @("Programs", "ffmpeg", "bin", "ffmpeg.exe")),
        (Join-NormalizedWindowsPath $localAppData @("ffmpeg", "bin", "ffmpeg.exe")),
        "C:\ffmpeg\bin\ffmpeg.exe",
        (Join-NormalizedWindowsPath $programFiles @("FFmpeg", "bin", "ffmpeg.exe")),
        (Join-NormalizedWindowsPath $programFiles @("ffmpeg", "bin", "ffmpeg.exe")),
        (Join-NormalizedWindowsPath $programFilesX86 @("FFmpeg", "bin", "ffmpeg.exe"))
    )

    foreach ($p in $ffmpegCandidates) {
        if ($p -and (Test-Path $p)) {
            if (IsFfmpegShim $p) {
                LogProgress ("Ignoring shim FFmpeg path: " + $p)
            } else {
                return $p
            }
        }
    }

    $runtimeFfmpegRoot = Join-NormalizedWindowsPath $RuntimeBase @("ffmpeg")
    if (Test-Path $runtimeFfmpegRoot) {
        try {
            $runtimeFfmpeg = Get-ChildItem -Path $runtimeFfmpegRoot -Filter "ffmpeg.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($runtimeFfmpeg -and $runtimeFfmpeg.FullName) {
                if (IsFfmpegShim $runtimeFfmpeg.FullName) {
                    LogProgress ("Ignoring shim FFmpeg path: " + $runtimeFfmpeg.FullName)
                } else {
                    return $runtimeFfmpeg.FullName
                }
            }
        } catch {
        }
    }

    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) {
        if (IsFfmpegShim $cmd.Source) {
            LogProgress ("Ignoring shim FFmpeg path: " + $cmd.Source)
        } else {
            return $cmd.Source
        }
    }

    if ($AllowInstall) {
        LogProgress "FFmpeg not found; preparing install"
        $installedFfmpeg = InstallFfmpegDirect
        if ($installedFfmpeg -and (Test-Path $installedFfmpeg) -and -not (IsFfmpegShim $installedFfmpeg)) {
            return $installedFfmpeg
        }
        if ($installedFfmpeg) {
            LogProgress ("FFmpeg path missing after install: " + $installedFfmpeg)
        }
    }

    return $null
}

function InvokeWithResolvedFfmpegEnvironment([string]$FfmpegPath, [scriptblock]$Action) {
    if ([string]::IsNullOrWhiteSpace($FfmpegPath)) {
        return (& $Action)
    }

    $ffmpegDir = Split-Path -Parent $FfmpegPath
    $previousStemwerkFfmpeg = $env:STEMWERK_FFMPEG_PATH
    $previousFfmpeg = $env:FFMPEG_PATH
    $previousImageio = $env:IMAGEIO_FFMPEG_EXE
    $previousPath = $env:PATH

    try {
        $env:STEMWERK_FFMPEG_PATH = $FfmpegPath
        $env:FFMPEG_PATH = $FfmpegPath
        $env:IMAGEIO_FFMPEG_EXE = $FfmpegPath
        if (-not [string]::IsNullOrWhiteSpace($ffmpegDir)) {
            $pathParts = @()
            if (-not [string]::IsNullOrWhiteSpace($env:PATH)) {
                $pathParts = @($env:PATH -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }
            $alreadyPresent = $false
            foreach ($part in $pathParts) {
                if ($part.TrimEnd('\') -ieq $ffmpegDir.TrimEnd('\')) {
                    $alreadyPresent = $true
                    break
                }
            }
            if (-not $alreadyPresent) {
                $env:PATH = $ffmpegDir + ";" + $env:PATH
            }
        }
        return (& $Action)
    } finally {
        $env:STEMWERK_FFMPEG_PATH = $previousStemwerkFfmpeg
        $env:FFMPEG_PATH = $previousFfmpeg
        $env:IMAGEIO_FFMPEG_EXE = $previousImageio
        $env:PATH = $previousPath
    }
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

function HasBundledDrumsepWheels {
    if ([string]::IsNullOrWhiteSpace($bundledDrumsepWheelsDir)) { return $false }
    if (-not (Test-Path $bundledDrumsepWheelsDir)) { return $false }
    $wheel = Get-ChildItem -Path $bundledDrumsepWheelsDir -Filter "*.whl" -Recurse | Select-Object -First 1
    return ($null -ne $wheel)
}

function GetPipOfflineArgsForDirs([string[]]$FindLinksDirs) {
    $args = @()
    $existing = @()
    foreach ($dir in $FindLinksDirs) {
        if (-not [string]::IsNullOrWhiteSpace($dir) -and (Test-Path $dir)) {
            $existing += $dir
        }
    }
    if ($existing.Count -eq 0) {
        return $args
    }
    $args += "--no-index"
    foreach ($dir in $existing) {
        $args += @("--find-links", $dir)
    }
    return $args
}

function GetPipOfflineArgs {
    return (GetPipOfflineArgsForDirs @($bundledWheelsDir))
}

function InstallWithPip([string]$PythonPath, [string[]]$InstallArgs, [string]$Description) {
    $args = @("-m", "pip", "install")
    $args += GetPipOfflineArgs
    $args += $InstallArgs
    RunHidden $PythonPath $args $Description | Out-Null
}

function InstallWithPipOfflineSources([string]$PythonPath, [string[]]$InstallArgs, [string]$Description, [string[]]$FindLinksDirs) {
    $args = @("-m", "pip", "install")
    $args += GetPipOfflineArgsForDirs $FindLinksDirs
    $args += $InstallArgs
    RunHidden $PythonPath $args $Description | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function InstallWithPipAllowOnlineFallback([string]$PythonPath, [string[]]$InstallArgs, [string]$Description) {
    InstallWithPip $PythonPath $InstallArgs $Description
    if ($LASTEXITCODE -eq 0) {
        return $true
    }

    if (-not (HasBundledWheels)) {
        return $false
    }

    $label = if (-not [string]::IsNullOrWhiteSpace($Description)) { $Description } else { "pip install" }
    LogProgress ($label + " failed with bundled wheels; retrying online")
    $args = @("-m", "pip", "install")
    $args += $InstallArgs
    RunHidden $PythonPath $args ($label + " (online fallback)") | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function SetDrumsepOfflinePayloadState([string]$Status, [string]$Reason, [string]$ModelSource = "", [string]$WheelSource = "") {
    $script:DrumsepOfflinePayloadStatus = $Status
    $script:DrumsepOfflinePayloadReason = $Reason
    if (-not [string]::IsNullOrWhiteSpace($ModelSource)) { $script:DrumsepModelSource = $ModelSource }
    if (-not [string]::IsNullOrWhiteSpace($WheelSource)) { $script:DrumsepRuntimeWheelSource = $WheelSource }
}

function TestBundledDrumsepModelsAvailable {
    foreach ($name in @($drumsepModelFileName, $drumsepModelYamlName)) {
        if (-not (Test-Path (Join-Path $bundledDrumsepModelsDir $name))) {
            return $false
        }
    }
    return $true
}

function CopyBundledDrumsepAssets([string]$ModelDir) {
    if (-not (TestBundledDrumsepModelsAvailable)) {
        SetDrumsepOfflinePayloadState "missing" "missing_bundled_drumsep_models"
        LogLine "Offline installer is missing bundled DrumSep model assets."
        return $false
    }
    try {
        New-Item -ItemType Directory -Force -Path $ModelDir | Out-Null
        foreach ($name in @($drumsepModelFileName, $drumsepModelYamlName)) {
            $src = Join-Path $bundledDrumsepModelsDir $name
            $dest = Join-Path $ModelDir $name
            Copy-Item -Path $src -Destination $dest -Force
        }
        SetDrumsepOfflinePayloadState "ok" "bundled" "bundled" $script:DrumsepRuntimeWheelSource
        return $true
    } catch {
        SetDrumsepOfflinePayloadState "missing" "bundled_model_copy_failed"
        LogLine ("Bundled DrumSep model copy failed: " + $_.Exception.Message)
        return $false
    }
}

function InstallBundledDrumsepPackages([string]$PythonPath, [string[]]$InstallArgs, [string]$Description) {
    if (-not (HasBundledDrumsepWheels)) {
        SetDrumsepOfflinePayloadState "missing" "missing_bundled_drumsep_wheels" "" "missing"
        LogLine "Offline installer is missing bundled DrumSep wheel payload."
        return $false
    }
    SetDrumsepOfflinePayloadState "ok" "bundled" $script:DrumsepModelSource "bundled"
    return (InstallWithPipOfflineSources $PythonPath $InstallArgs $Description @($bundledWheelsDir, $bundledDrumsepWheelsDir))
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

function GetReadyToGoStatePath {
    return Join-Path $RuntimeBase "state\\ready_to_go.env"
}

function VerifyCoreModelCache([string]$ModelDir) {
    $specs = [ordered]@{
        fast = @("htdemucs.yaml", "955717e8-8726e21a.th")
        quality = @("htdemucs_ft.yaml", "f7e0c4bc-ba3fe64a.th", "d12395a8-e57c48e6.th", "92cfc3b6-ef3bcb9c.th", "04573f0d-f3cf25b2.th")
        sixstem = @("htdemucs_6s.yaml", "5c90dfd2-34c22ccb.th")
    }
    $result = [ordered]@{
        model_dir = $ModelDir
        fast = "missing"
        quality = "missing"
        sixstem = "missing"
    }
    foreach ($entry in $specs.GetEnumerator()) {
        $ok = $true
        foreach ($name in $entry.Value) {
            if (-not (Test-Path (Join-Path $ModelDir $name))) {
                $ok = $false
                break
            }
        }
        $result[$entry.Key] = if ($ok) { "ok" } else { "missing" }
    }
    return $result
}

function EnsureCoreModelCache([string]$PythonPath, [string]$ModelDir) {
    if ([string]::IsNullOrWhiteSpace($PythonPath) -or -not (Test-Path $PythonPath)) { return $false }
    if ([string]::IsNullOrWhiteSpace($ModelDir)) { return $false }
    try {
        New-Item -ItemType Directory -Force -Path $ModelDir | Out-Null
    } catch {
        LogLine ("Core model directory create failed: " + $_.Exception.Message)
        return $false
    }
    $before = VerifyCoreModelCache $ModelDir
    if ($before.fast -eq "ok" -and $before.quality -eq "ok" -and $before.sixstem -eq "ok") {
        LogProgress ("Core model cache already present: " + $ModelDir)
        return $true
    }
    if (-not (EnsureSharedModelDownloadChecks $ModelDir)) {
        LogLine "Core model prefetch could not prepare download_checks.json"
        return $false
    }
    $resolvedFfmpeg = ResolveWindowsFfmpegPath -AllowInstall
    if ([string]::IsNullOrWhiteSpace($resolvedFfmpeg) -or -not (Test-Path $resolvedFfmpeg)) {
        LogLine "Core model prefetch could not resolve FFmpeg"
        return $false
    }
    LogProgress ("Core model prefetch using FFmpeg: " + $resolvedFfmpeg)
    $prefetchCode = @"
import os
from audio_separator.separator import Separator
from stemwerk_core.models import resolve_audio_separator_model_id

model_dir = r"$ModelDir"
def demucs_contract(separator):
    supported = separator.list_supported_model_files()
    demucs = supported.get("Demucs", {}) if isinstance(supported, dict) else {}
    names = []
    for entry in demucs.values():
        if isinstance(entry, dict):
            names.extend(str(name) for name in entry.keys() if "demucs" in str(name).lower())
    print("STEMWERK_CORE_MODEL_SUPPORTED_DEMUCS=" + ",".join(sorted(set(names))))
for model_name in ("htdemucs", "htdemucs_ft", "htdemucs_6s"):
    sep = Separator(model_file_dir=model_dir, output_dir=".", output_format="wav")
    demucs_contract(sep)
    sep.load_model(resolve_audio_separator_model_id(model_name))
print("STEMWERK_CORE_MODEL_PREFETCH ok")
"@
    InvokeWithResolvedFfmpegEnvironment $resolvedFfmpeg {
        RunHidden $PythonPath @("-c", $prefetchCode) "Prefetch core model cache" | Out-Null
    } | Out-Null
    if ($LASTEXITCODE -ne 0) {
        LogLine ("Core model prefetch failed for cache: " + $ModelDir)
        return $false
    }
    $after = VerifyCoreModelCache $ModelDir
    return ($after.fast -eq "ok" -and $after.quality -eq "ok" -and $after.sixstem -eq "ok")
}

function WriteReadyToGoState([string]$RuntimeKind, [string]$RuntimeStatus, [string]$DrumsepModelStatus, [hashtable]$CoreStatus, [string]$Detail, [string]$MainRuntimeStatus = "") {
    $readyPath = GetReadyToGoStatePath
    $modelDir = if ($CoreStatus -and $CoreStatus.Contains("model_dir")) { [string]$CoreStatus["model_dir"] } else { Join-Path $RuntimeBase "models" }
    $fastStatus = if ($CoreStatus -and $CoreStatus.Contains("fast")) { [string]$CoreStatus["fast"] } else { "missing" }
    $qualityStatus = if ($CoreStatus -and $CoreStatus.Contains("quality")) { [string]$CoreStatus["quality"] } else { "missing" }
    $sixStemStatus = if ($CoreStatus -and $CoreStatus.Contains("sixstem")) { [string]$CoreStatus["sixstem"] } else { "missing" }
    $runtimeKindValue = if ([string]::IsNullOrWhiteSpace($RuntimeKind)) { "unknown" } else { $RuntimeKind }
    $runtimeStatusValue = if ([string]::IsNullOrWhiteSpace($RuntimeStatus)) { "missing" } else { $RuntimeStatus }
    $drumsepModelValue = if ([string]::IsNullOrWhiteSpace($DrumsepModelStatus)) { "missing" } else { $DrumsepModelStatus }
    $detailValue = if ([string]::IsNullOrWhiteSpace($Detail)) { "" } else { $Detail }
    $mainRuntimeStatus = if ([string]::IsNullOrWhiteSpace($MainRuntimeStatus)) { $runtimeStatusValue } else { $MainRuntimeStatus }
    $readyStatus = "ok"
    if ($fastStatus -ne "ok" -or $qualityStatus -ne "ok" -or $sixStemStatus -ne "ok" -or $drumsepModelValue -ne "ok") {
        $readyStatus = "missing"
    }
    if ($runtimeStatusValue -eq "broken") {
        $readyStatus = "broken"
    } elseif ($runtimeStatusValue -ne "ok" -and $runtimeStatusValue -ne "skipped") {
        $readyStatus = "missing"
    }
    $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    @(
        "READY_TO_GO_STATUS=$readyStatus",
        "READY_TO_GO_DETAIL=$detailValue",
        "READY_TO_GO_LAST_CHECK_UTC=$timestamp",
        "MAIN_RUNTIME_STATUS=$mainRuntimeStatus",
        "CORE_MODEL_CACHE_DIR=$modelDir",
        "CORE_MODEL_FAST_STATUS=$fastStatus",
        "CORE_MODEL_QUALITY_STATUS=$qualityStatus",
        "CORE_MODEL_6STEM_STATUS=$sixStemStatus",
        "DRUMSEP_READY_RUNTIME=$runtimeKindValue",
        "DRUMSEP_READY_RUNTIME_STATUS=$runtimeStatusValue",
        "DRUMSEP_READY_MODEL_STATUS=$drumsepModelValue"
    ) | Out-File -FilePath $readyPath -Encoding ascii
}

function GetReadyToGoRuntimeState([string]$BackendName) {
    $result = @{
        RuntimeKind = if ([string]::IsNullOrWhiteSpace($BackendName)) { "cpu" } else { $BackendName }
        RuntimeStatus = "missing"
        DrumsepModelStatus = "missing"
        Detail = ""
    }
    $statePath = switch ($BackendName) {
        "cuda" { Join-Path $RuntimeBase "state\drumsep_runtime_cuda.env" }
        "directml" { Join-Path $RuntimeBase "state\drumsep_runtime_directml.env" }
        default { Join-Path $RuntimeBase "state\drumsep_runtime.env" }
    }
    if (-not (Test-Path $statePath)) {
        return $result
    }
    foreach ($line in Get-Content $statePath -ErrorAction SilentlyContinue) {
        if ($line -match "^([^=]+)=(.*)$") {
            $key = $matches[1]
            $value = $matches[2]
            switch ($BackendName) {
                "cuda" {
                    if ($key -eq "DRUMSEP_CUDA_RUNTIME_STATUS") { $result.RuntimeStatus = $value }
                    elseif ($key -eq "DRUMSEP_CUDA_MODEL_STATUS") { $result.DrumsepModelStatus = $value }
                    elseif ($key -eq "DRUMSEP_CUDA_RUNTIME_DETAIL") { $result.Detail = $value }
                }
                "directml" {
                    if ($key -eq "DRUMSEP_DIRECTML_RUNTIME_STATUS") { $result.RuntimeStatus = $value }
                    elseif ($key -eq "DRUMSEP_DIRECTML_MODEL_STATUS") { $result.DrumsepModelStatus = $value }
                    elseif ($key -eq "DRUMSEP_DIRECTML_RUNTIME_DETAIL") { $result.Detail = $value }
                }
                default {
                    if ($key -eq "DRUMSEP_RUNTIME_STATUS") { $result.RuntimeStatus = $value }
                    elseif ($key -eq "DRUMSEP_MODEL_STATUS") { $result.DrumsepModelStatus = $value }
                    elseif ($key -eq "DRUMSEP_RUNTIME_DETAIL") { $result.Detail = $value }
                }
            }
        }
    }
    return $result
}

function ReadEnvMap([string]$Path) {
    $result = @{}
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $result
    }
    foreach ($line in Get-Content $Path -ErrorAction SilentlyContinue) {
        if ($line -match "^([^=]+)=(.*)$") {
            $result[$matches[1]] = $matches[2]
        }
    }
    return $result
}

function GetMainRuntimePythonPath {
    $capPath = Join-Path $RuntimeBase "state\\capabilities.env"
    $capState = ReadEnvMap $capPath
    $pythonPath = [string]$capState["PYTHON_PATH"]
    if (-not [string]::IsNullOrWhiteSpace($pythonPath) -and (Test-Path $pythonPath)) {
        return $pythonPath
    }
    if (Test-Path $venvPy) {
        return $venvPy
    }
    return $null
}

function ProbeMainRuntimeReady([string]$PythonPath, [string]$BackendName) {
    if ([string]::IsNullOrWhiteSpace($PythonPath) -or -not (Test-Path $PythonPath)) {
        return @{ Status = "missing"; Detail = "python_missing" }
    }
    $probeBackend = if ([string]::IsNullOrWhiteSpace($BackendName)) { "cpu" } else { $BackendName }
    $probeResultPath = Join-Path $RuntimeBase "state\\main_runtime_ready_probe.txt"
    if (Test-Path $probeResultPath) {
        Remove-Item -Path $probeResultPath -Force -ErrorAction SilentlyContinue
    }
    $probeCode = @'
import os
from pathlib import Path

result_path = Path(os.environ["STEMWERK_MAIN_READY_RESULT"])
backend = os.environ.get("STEMWERK_BACKEND", "cpu")
errors = []
for mod_name in ("audio_separator", "onnxruntime", "stemwerk_core"):
    try:
        __import__(mod_name)
    except Exception as exc:
        errors.append(mod_name + "_import_failed:" + str(exc))
try:
    import torch
    if backend == "cuda":
        if not bool(torch.cuda.is_available()) or int(torch.cuda.device_count()) <= 0:
            errors.append("cuda_runtime_probe_failed")
except Exception as exc:
    errors.append("torch_import_failed:" + str(exc))
if errors:
    result_path.write_text("broken|" + ";".join(errors), encoding="utf-8")
else:
    result_path.write_text("ok", encoding="utf-8")
'@
    $previousBackend = $env:STEMWERK_BACKEND
    $previousResultPath = $env:STEMWERK_MAIN_READY_RESULT
    try {
        $env:STEMWERK_BACKEND = $probeBackend
        $env:STEMWERK_MAIN_READY_RESULT = $probeResultPath
        RunHidden $PythonPath @("-c", $probeCode) "Probe main runtime ready" | Out-Null
    } finally {
        $env:STEMWERK_BACKEND = $previousBackend
        $env:STEMWERK_MAIN_READY_RESULT = $previousResultPath
    }
    $probeText = ""
    if (Test-Path $probeResultPath) {
        $probeText = ([string](Get-Content $probeResultPath -ErrorAction SilentlyContinue | Select-Object -First 1)).Trim()
    }
    if ($LASTEXITCODE -eq 0 -and $probeText -eq "ok") {
        LogProgress ("Main runtime ready probe passed: " + $PythonPath)
        return @{ Status = "ok"; Detail = "main_runtime_ok" }
    }
    if ($probeText -like "broken|*") {
        $detail = $probeText.Substring(7)
        LogProgress ("Main runtime ready probe failed: " + $detail)
        return @{ Status = "broken"; Detail = $detail }
    }
    LogProgress "Main runtime ready probe could not determine status"
    return @{ Status = "broken"; Detail = "probe_failed" }
}

function VerifyExistingReadyRuntime([string]$PreferredBackend) {
    $preferred = if ([string]::IsNullOrWhiteSpace($PreferredBackend)) { "cpu" } else { $PreferredBackend }
    if ($preferred -eq "cuda") {
        $cudaStatus = VerifyDrumsepCudaRuntime (GetDrumsepCudaRuntimePythonPath)
        if ($cudaStatus.Status -eq "ok") {
            return GetReadyToGoRuntimeState "cuda"
        }
        $directmlStatus = VerifyDrumsepDirectmlRuntime (GetDrumsepDirectmlRuntimePythonPath)
        if ($directmlStatus -eq "ok") {
            return GetReadyToGoRuntimeState "directml"
        }
        $cpuStatus = VerifyDrumsepRuntime (GetDrumsepRuntimePythonPath)
        if ($cpuStatus -eq "ok") {
            return GetReadyToGoRuntimeState "cpu"
        }
        $existing = GetReadyToGoRuntimeState "cuda"
        if ($existing.RuntimeStatus -ne "missing") { return $existing }
        $existing = GetReadyToGoRuntimeState "directml"
        if ($existing.RuntimeStatus -ne "missing") { return $existing }
        return GetReadyToGoRuntimeState "cpu"
    }
    if ($preferred -eq "directml") {
        $directmlStatus = VerifyDrumsepDirectmlRuntime (GetDrumsepDirectmlRuntimePythonPath)
        if ($directmlStatus -eq "ok") {
            return GetReadyToGoRuntimeState "directml"
        }
        $cpuStatus = VerifyDrumsepRuntime (GetDrumsepRuntimePythonPath)
        if ($cpuStatus -eq "ok") {
            return GetReadyToGoRuntimeState "cpu"
        }
        $cudaStatus = VerifyDrumsepCudaRuntime (GetDrumsepCudaRuntimePythonPath)
        if ($cudaStatus.Status -eq "ok") {
            return GetReadyToGoRuntimeState "cuda"
        }
        $existing = GetReadyToGoRuntimeState "directml"
        if ($existing.RuntimeStatus -ne "missing") { return $existing }
        $existing = GetReadyToGoRuntimeState "cpu"
        if ($existing.RuntimeStatus -ne "missing") { return $existing }
        return GetReadyToGoRuntimeState "cuda"
    }
    $cpuStatus = VerifyDrumsepRuntime (GetDrumsepRuntimePythonPath)
    if ($cpuStatus -eq "ok") {
        return GetReadyToGoRuntimeState "cpu"
    }
    $cudaStatus = VerifyDrumsepCudaRuntime (GetDrumsepCudaRuntimePythonPath)
    if ($cudaStatus.Status -eq "ok") {
        return GetReadyToGoRuntimeState "cuda"
    }
    $directmlStatus = VerifyDrumsepDirectmlRuntime (GetDrumsepDirectmlRuntimePythonPath)
    if ($directmlStatus -eq "ok") {
        return GetReadyToGoRuntimeState "directml"
    }
    $existing = GetReadyToGoRuntimeState "cpu"
    if ($existing.RuntimeStatus -ne "missing") { return $existing }
    $existing = GetReadyToGoRuntimeState "cuda"
    if ($existing.RuntimeStatus -ne "missing") { return $existing }
    return GetReadyToGoRuntimeState "directml"
}

function RunReadyToGoVerifyOnly {
    WriteBootstrapGuard "running" "ready_to_go_verify"
    $script:StepIndex = 0
    $script:StepTotal = 3
    Step "ready_to_go_prepare" "Preparing ready-to-go verify"

    $capPath = Join-Path $RuntimeBase "state\\capabilities.env"
    $capState = ReadEnvMap $capPath
    $readyBackend = [string]$capState["BACKEND"]
    if ([string]::IsNullOrWhiteSpace($readyBackend)) { $readyBackend = $backend }
    if ([string]::IsNullOrWhiteSpace($readyBackend)) { $readyBackend = "cpu" }
    $mainPython = GetMainRuntimePythonPath

    Step "ready_to_go_verify" "Verifying existing runtimes"
    $mainProbe = ProbeMainRuntimeReady $mainPython $readyBackend
    $mainReadyStatus = [string]$mainProbe.Status
    $mainReadyDetail = [string]$mainProbe.Detail

    $resolvedFfmpeg = ResolveWindowsFfmpegPath
    if ($resolvedFfmpeg -and (Test-Path $resolvedFfmpeg)) {
        LogProgress ("ffmpeg_existing_ok=" + $resolvedFfmpeg)
        LogProgress "ffmpeg_download_skipped=existing_ok"
    } else {
        LogProgress "ffmpeg_existing_ok=missing"
    }

    $readyRuntimeState = VerifyExistingReadyRuntime $readyBackend
    $readyRuntime = [string]$readyRuntimeState.RuntimeKind
    $readyRuntimeStatus = [string]$readyRuntimeState.RuntimeStatus
    $readyDrumsepModelStatus = [string]$readyRuntimeState.DrumsepModelStatus
    $readyDetail = [string]$readyRuntimeState.Detail
    if ([string]::IsNullOrWhiteSpace($readyDetail)) {
        $readyDetail = $mainReadyDetail
    } elseif ($mainReadyStatus -ne "ok") {
        $readyDetail = "main_runtime_${mainReadyStatus}:$mainReadyDetail;drumsep:$readyDetail"
    }
    $readyCoreStatus = VerifyCoreModelCache (GetDrumsepModelDir)

    Step "ready_to_go_write" "Writing ready-to-go state"
    if ($mainReadyStatus -eq "ok" -and $readyRuntimeStatus -eq "ok") {
        $status = "ok"
        $statusReason = ""
    } else {
        $status = "deps_failed"
        $statusReason = "ready_to_go_verify_only"
    }
    WriteReadyToGoState $readyRuntime $readyRuntimeStatus $readyDrumsepModelStatus $readyCoreStatus $readyDetail $mainReadyStatus
    $readyStatePath = GetReadyToGoStatePath
    $normalizedReadyStatePath = [System.IO.Path]::GetFullPath($readyStatePath)
    $normalizedStateFile = if ([string]::IsNullOrWhiteSpace($StateFile)) { "" } else { [System.IO.Path]::GetFullPath($StateFile) }
    LogProgress ("ready_to_go_state_file=" + $readyStatePath)
    LogProgress "ready_to_go_state_written=1"
    $readyState = ReadEnvMap $readyStatePath
    LogProgress ("ready_to_go_status=" + [string]$readyState["READY_TO_GO_STATUS"])
    if ($normalizedStateFile -and ($normalizedStateFile -ieq $normalizedReadyStatePath)) {
        LogProgress "ready_to_go_state_persists_in_state_file=1"
    } else {
        WriteState $status $statusReason
    }
    if ($status -eq "ok") {
        WriteBootstrapGuard "ok" "completed"
        LogProgress "Ready-to-go verify finished successfully"
        exit 0
    }
    WriteBootstrapGuard "failed" $statusReason
    LogProgress ("Ready-to-go verify finished with status=" + $mainReadyStatus + " detail=" + $readyDetail)
    exit 1
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
        $script:juliusOk = $true
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
    $script:juliusOk = ($LASTEXITCODE -eq 0)
    return $script:juliusOk
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

function GetDrumsepRuntimePythonPath {
    return Join-Path $RuntimeBase ".venv-drumsep\\Scripts\\python.exe"
}

function GetDrumsepDirectmlRuntimePythonPath {
    return Join-Path $RuntimeBase ".venv-drumsep-directml\\Scripts\\python.exe"
}

function GetDrumsepCudaRuntimePythonPath {
    return Join-Path $RuntimeBase ".venv-drumsep-cuda\\Scripts\\python.exe"
}

function GetDrumsepModelDir {
    return Join-Path $RuntimeBase "models"
}

function GetDrumsepModelFilePath {
    return Join-Path (GetDrumsepModelDir) $drumsepModelFileName
}

function GetDrumsepModelYamlPath {
    return Join-Path (GetDrumsepModelDir) $drumsepModelYamlName
}

function GetDrumsepRuntimeStatePath {
    return Join-Path $RuntimeBase "state\\drumsep_runtime.env"
}

function GetDrumsepDirectmlRuntimeStatePath {
    return Join-Path $RuntimeBase "state\\drumsep_runtime_directml.env"
}

function GetDrumsepCudaRuntimeStatePath {
    return Join-Path $RuntimeBase "state\\drumsep_runtime_cuda.env"
}

function WriteDrumsepState([string]$State, [string]$ModelStatus, [string]$Reason) {
    $drumsepPython = GetDrumsepRuntimePythonPath
    $modelFile = GetDrumsepModelFilePath
    $modelYaml = GetDrumsepModelYamlPath
    if ($ModelStatus -eq "missing" -and (Test-Path $modelFile) -and (Test-Path $modelYaml)) {
        $ModelStatus = "ok"
    }
    $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $lines = @(
        "STATUS=$State",
        "STATUS_REASON=$Reason",
        "DRUMSEP_RUNTIME_STATUS=$State",
        "DRUMSEP_RUNTIME_DETAIL=$Reason",
        "DRUMSEP_PYTHON=$drumsepPython",
        "DRUMSEP_LAST_CHECK_UTC=$timestamp",
        "DRUMSEP_MODEL_STATUS=$ModelStatus",
        "DRUMSEP_MODEL_FILE=$modelFile",
        "DRUMSEP_MODEL_YAML=$modelYaml",
        "DRUMSEP_OFFLINE_PAYLOAD_STATUS=$script:DrumsepOfflinePayloadStatus",
        "DRUMSEP_OFFLINE_PAYLOAD_SOURCE=$script:DrumsepOfflinePayloadSource",
        "DRUMSEP_OFFLINE_PAYLOAD_REASON=$script:DrumsepOfflinePayloadReason",
        "DRUMSEP_MODEL_SOURCE=$script:DrumsepModelSource",
        "DRUMSEP_RUNTIME_WHEEL_SOURCE=$script:DrumsepRuntimeWheelSource",
        "DRUMSEP_AUDIO_SEPARATOR_VERSION=",
        "DRUMSEP_NUMPY_VERSION=",
        "DRUMSEP_TORCH_VERSION=",
        "DRUMSEP_ONNX_VERSION=",
        "DRUMSEP_ONNXRUNTIME_VERSION=",
        "DRUMSEP_ONNX2TORCH_VERSION=",
        "DRUMSEP_ONNX2TORCH_PY313_VERSION="
    )

    if (Test-Path $drumsepPython) {
        try {
            $versionCode = @'
import importlib.metadata as metadata
for env_key, dist_name in (
    ("DRUMSEP_AUDIO_SEPARATOR_VERSION", "audio-separator"),
    ("DRUMSEP_NUMPY_VERSION", "numpy"),
    ("DRUMSEP_TORCH_VERSION", "torch"),
    ("DRUMSEP_ONNX_VERSION", "onnx"),
    ("DRUMSEP_ONNXRUNTIME_VERSION", "onnxruntime"),
    ("DRUMSEP_ONNX2TORCH_VERSION", "onnx2torch"),
    ("DRUMSEP_ONNX2TORCH_PY313_VERSION", "onnx2torch-py313"),
):
    try:
        value = metadata.version(dist_name)
    except Exception:
        value = ""
    print(f"{env_key}={value}")
'@
            $versionOut = & $drumsepPython -c $versionCode 2>$null
            if ($LASTEXITCODE -eq 0 -and $versionOut) {
                $lines = @($lines | Where-Object { $_ -notmatch "^DRUMSEP_(AUDIO_SEPARATOR|NUMPY|TORCH|ONNX|ONNXRUNTIME|ONNX2TORCH|ONNX2TORCH_PY313)_VERSION=" })
                $lines += $versionOut
            }
        } catch {
        }
    }

    $lines | Out-File -FilePath (GetDrumsepRuntimeStatePath) -Encoding ascii
}

function WriteDrumsepDirectmlState([string]$State, [string]$ModelStatus, [string]$Reason) {
    $drumsepPython = GetDrumsepDirectmlRuntimePythonPath
    $modelFile = GetDrumsepModelFilePath
    $modelYaml = GetDrumsepModelYamlPath
    if ($ModelStatus -eq "missing" -and (Test-Path $modelFile) -and (Test-Path $modelYaml)) {
        $ModelStatus = "ok"
    }
    $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $audioSeparatorVersionValue = ""
    $numpyVersionValue = ""
    $torchVersionValue = ""
    $torchVisionVersionValue = ""
    $torchDirectMlVersionValue = ""
    $onnxVersionValue = ""
    $onnxRuntimeDirectMlVersionValue = ""
    $onnx2TorchVersionValue = ""
    $librosaVersionValue = ""
    $samplerateVersionValue = ""
    $soundFileVersionValue = ""
    $torchDirectmlStatusValue = ""
    $directmlDeviceValue = ""
    $directmlDeviceCountValue = ""
    $ortDirectmlProviderValue = ""
    $ortAvailableProvidersValue = ""
    if ($State -eq "ok") {
        $audioSeparatorVersionValue = $drumsepAudioSeparatorVersion
        $numpyVersionValue = $drumsepNumpyVersion
        $torchVersionValue = $torchVersion
        $torchVisionVersionValue = $torchVisionVersion
        $torchDirectMlVersionValue = $torchDirectMlVersion
        $onnxVersionValue = $drumsepOnnxVersion
        $onnxRuntimeDirectMlVersionValue = $onnxRuntimeDirectMlVersion
        $onnx2TorchVersionValue = $drumsepOnnx2TorchVersion
        $librosaVersionValue = $drumsepDirectMlLibrosaVersion
        $samplerateVersionValue = $drumsepDirectMlSamplerateVersion
        $soundFileVersionValue = $drumsepDirectMlSoundFileVersion
        $torchDirectmlStatusValue = "ok"
        $directmlDeviceValue = "privateuseone:0"
        $ortDirectmlProviderValue = "ok"
        $ortAvailableProvidersValue = "DmlExecutionProvider,CPUExecutionProvider"
    }
    $lines = @(
        "STATUS=$State",
        "STATUS_REASON=$Reason",
        "DRUMSEP_DIRECTML_RUNTIME_STATUS=$State",
        "DRUMSEP_DIRECTML_RUNTIME_DETAIL=$Reason",
        "DRUMSEP_DIRECTML_PYTHON=$drumsepPython",
        "DRUMSEP_DIRECTML_LAST_CHECK_UTC=$timestamp",
        "DRUMSEP_DIRECTML_MODEL_STATUS=$ModelStatus",
        "DRUMSEP_DIRECTML_MODEL_FILE=$modelFile",
        "DRUMSEP_DIRECTML_MODEL_YAML=$modelYaml",
        "DRUMSEP_OFFLINE_PAYLOAD_STATUS=$script:DrumsepOfflinePayloadStatus",
        "DRUMSEP_OFFLINE_PAYLOAD_SOURCE=$script:DrumsepOfflinePayloadSource",
        "DRUMSEP_OFFLINE_PAYLOAD_REASON=$script:DrumsepOfflinePayloadReason",
        "DRUMSEP_MODEL_SOURCE=$script:DrumsepModelSource",
        "DRUMSEP_RUNTIME_WHEEL_SOURCE=$script:DrumsepRuntimeWheelSource",
        "DRUMSEP_DIRECTML_AUDIO_SEPARATOR_VERSION=$audioSeparatorVersionValue",
        "DRUMSEP_DIRECTML_NUMPY_VERSION=$numpyVersionValue",
        "DRUMSEP_DIRECTML_TORCH_VERSION=$torchVersionValue",
        "DRUMSEP_DIRECTML_TORCHVISION_VERSION=$torchVisionVersionValue",
        "DRUMSEP_DIRECTML_TORCH_DIRECTML_VERSION=$torchDirectMlVersionValue",
        "DRUMSEP_DIRECTML_ONNX_VERSION=$onnxVersionValue",
        "DRUMSEP_DIRECTML_ONNXRUNTIME_DIRECTML_VERSION=$onnxRuntimeDirectMlVersionValue",
        "DRUMSEP_DIRECTML_ONNX2TORCH_VERSION=$onnx2TorchVersionValue",
        "DRUMSEP_DIRECTML_LIBROSA_VERSION=$librosaVersionValue",
        "DRUMSEP_DIRECTML_SAMPLERATE_VERSION=$samplerateVersionValue",
        "DRUMSEP_DIRECTML_SOUNDFILE_VERSION=$soundFileVersionValue",
        "TORCH_DIRECTML_STATUS=$torchDirectmlStatusValue",
        "DIRECTML_DEVICE=$directmlDeviceValue",
        "DIRECTML_DEVICE_COUNT=$directmlDeviceCountValue",
        "ORT_DIRECTML_PROVIDER=$ortDirectmlProviderValue",
        "ORT_AVAILABLE_PROVIDERS=$ortAvailableProvidersValue"
    )

    $lines | Out-File -FilePath (GetDrumsepDirectmlRuntimeStatePath) -Encoding ascii
}

function WriteDrumsepCudaState([string]$State, [string]$ModelStatus, [string]$Reason, [hashtable]$Probe = $null, [string]$FfmpegPath = "") {
    $drumsepPython = GetDrumsepCudaRuntimePythonPath
    $modelFile = GetDrumsepModelFilePath
    $modelYaml = GetDrumsepModelYamlPath
    if ($ModelStatus -eq "missing" -and (Test-Path $modelFile) -and (Test-Path $modelYaml)) {
        $ModelStatus = "ok"
    }
    $timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $probe = if ($Probe) { $Probe } else { @{} }
    $statusValue = if ($State -eq "running") { "running" } elseif ($State -eq "ok") { "ok" } else { "error" }
    $audioSeparatorVersionValue = [string]($probe["DRUMSEP_CUDA_AUDIO_SEPARATOR_VERSION"])
    $torchVersionValue = [string]($probe["DRUMSEP_CUDA_TORCH_VERSION"])
    $torchVisionVersionValue = [string]($probe["DRUMSEP_CUDA_TORCHVISION_VERSION"])
    $torchAudioVersionValue = [string]($probe["DRUMSEP_CUDA_TORCHAUDIO_VERSION"])
    $onnxRuntimeGpuVersionValue = [string]($probe["DRUMSEP_CUDA_ONNXRUNTIME_GPU_VERSION"])
    $cudaDeviceValue = [string]($probe["CUDA_DEVICE"])
    $cudaDeviceIdValue = [string]($probe["CUDA_DEVICE_ID"])
    $ortAvailableProvidersValue = [string]($probe["ORT_AVAILABLE_PROVIDERS"])
    $ffmpegStatusValue = [string]($probe["FFMPEG_STATUS"])
    $torchCudaStatusValue = [string]($probe["TORCH_CUDA_STATUS"])
    $ortCudaProviderValue = [string]($probe["ORT_CUDA_PROVIDER"])
    if ($State -eq "ok") {
        if ([string]::IsNullOrWhiteSpace($audioSeparatorVersionValue)) { $audioSeparatorVersionValue = $drumsepAudioSeparatorVersion }
        if ([string]::IsNullOrWhiteSpace($torchVersionValue)) { $torchVersionValue = "$torchVersion$torchCudaSuffix" }
        if ([string]::IsNullOrWhiteSpace($torchVisionVersionValue)) { $torchVisionVersionValue = "$torchVisionVersion$torchCudaSuffix" }
        if ([string]::IsNullOrWhiteSpace($torchAudioVersionValue)) { $torchAudioVersionValue = "$torchAudioVersion$torchCudaSuffix" }
        if ([string]::IsNullOrWhiteSpace($onnxRuntimeGpuVersionValue)) { $onnxRuntimeGpuVersionValue = $onnxRuntimeGpuVersion }
        if ([string]::IsNullOrWhiteSpace($cudaDeviceIdValue)) { $cudaDeviceIdValue = "cuda:0" }
        if ([string]::IsNullOrWhiteSpace($ffmpegStatusValue)) { $ffmpegStatusValue = "ok" }
        if ([string]::IsNullOrWhiteSpace($torchCudaStatusValue)) { $torchCudaStatusValue = "ok" }
        if ([string]::IsNullOrWhiteSpace($ortCudaProviderValue)) { $ortCudaProviderValue = "ok" }
    }
    $lines = @(
        "STATUS=$statusValue",
        "STATUS_REASON=$Reason",
        "DRUMSEP_CUDA_RUNTIME_STATUS=$statusValue",
        "DRUMSEP_CUDA_RUNTIME_DETAIL=$Reason",
        "DRUMSEP_CUDA_PYTHON=$drumsepPython",
        "DRUMSEP_CUDA_LAST_CHECK_UTC=$timestamp",
        "DRUMSEP_CUDA_MODEL_STATUS=$ModelStatus",
        "DRUMSEP_CUDA_MODEL_FILE=$modelFile",
        "DRUMSEP_CUDA_MODEL_YAML=$modelYaml",
        "DRUMSEP_OFFLINE_PAYLOAD_STATUS=$script:DrumsepOfflinePayloadStatus",
        "DRUMSEP_OFFLINE_PAYLOAD_SOURCE=$script:DrumsepOfflinePayloadSource",
        "DRUMSEP_OFFLINE_PAYLOAD_REASON=$script:DrumsepOfflinePayloadReason",
        "DRUMSEP_MODEL_SOURCE=$script:DrumsepModelSource",
        "DRUMSEP_RUNTIME_WHEEL_SOURCE=$script:DrumsepRuntimeWheelSource",
        "DRUMSEP_CUDA_AUDIO_SEPARATOR_VERSION=$audioSeparatorVersionValue",
        "DRUMSEP_CUDA_TORCH_VERSION=$torchVersionValue",
        "DRUMSEP_CUDA_TORCHVISION_VERSION=$torchVisionVersionValue",
        "DRUMSEP_CUDA_TORCHAUDIO_VERSION=$torchAudioVersionValue",
        "DRUMSEP_CUDA_ONNXRUNTIME_GPU_VERSION=$onnxRuntimeGpuVersionValue",
        "TORCH_CUDA_STATUS=$torchCudaStatusValue",
        "ORT_CUDA_PROVIDER=$ortCudaProviderValue",
        "CUDA_DEVICE=$cudaDeviceValue",
        "CUDA_DEVICE_ID=$cudaDeviceIdValue",
        "ORT_AVAILABLE_PROVIDERS=$ortAvailableProvidersValue",
        "FFMPEG_STATUS=$ffmpegStatusValue",
        "FFMPEG_PATH=$FfmpegPath"
    )
    $lines | Out-File -FilePath (GetDrumsepCudaRuntimeStatePath) -Encoding ascii
}

function TestWindowsCudaCapableHost {
    $gpuNames = @()
    try {
        $gpuNames = @(Get-CimInstance Win32_VideoController | Select-Object -ExpandProperty Name)
    } catch {
        $gpuNames = @()
    }
    foreach ($name in $gpuNames) {
        if ([string]$name -match "NVIDIA") {
            return $true
        }
    }
    $nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if ($nvidiaSmi) {
        & $nvidiaSmi.Source -L | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
    }
    return $false
}

function ResolveSupportedWindowsPython([string[]]$Candidates) {
    $resolved = $null
    foreach ($candidate in ($Candidates | Where-Object { $_ })) {
        if ((Test-Path $candidate) -and -not (IsWindowsStorePython $candidate)) {
            if (TestSupportedPython $candidate) {
                $resolved = $candidate
                break
            }
            LogUnsupportedPython $candidate
        }
    }

    if (-not $resolved) {
        $cmd = Get-Command python -ErrorAction SilentlyContinue
        if ($cmd -and -not (IsWindowsStorePython $cmd.Source)) {
            if (TestSupportedPython $cmd.Source) {
                $resolved = $cmd.Source
            } else {
                LogUnsupportedPython $cmd.Source
            }
        }
    }

    if ($resolved -and -not (TestSupportedPython $resolved)) {
        LogUnsupportedPython $resolved
        $resolved = $null
    }

    if (-not $resolved) {
        LogProgress "Python not found; attempting direct install"
        $resolved = InstallPythonDirect
        if ($resolved -and -not (TestSupportedPython $resolved)) {
            LogUnsupportedPython $resolved
            $resolved = $null
        }
    }

    return $resolved
}

function EnsureSharedModelDownloadChecks([string]$ModelDir) {
    if ([string]::IsNullOrWhiteSpace($ModelDir)) { return $false }
    try {
        New-Item -ItemType Directory -Force -Path $ModelDir | Out-Null
        $checksPath = Join-Path $ModelDir "download_checks.json"
        $checks = @{
            current_version = ""
            current_version_ocl = ""
            current_version_mac = ""
            current_version_linux = ""
            vr_download_list = @{}
            mdx_download_list = @{}
            demucs_download_list = @{
                "Demucs v4: htdemucs" = @{
                    "955717e8-8726e21a.th" = "https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/955717e8-8726e21a.th"
                    "htdemucs.yaml" = "https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/htdemucs.yaml"
                }
                "Demucs v4: htdemucs_ft" = @{
                    "f7e0c4bc-ba3fe64a.th" = "https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/f7e0c4bc-ba3fe64a.th"
                    "d12395a8-e57c48e6.th" = "https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/d12395a8-e57c48e6.th"
                    "92cfc3b6-ef3bcb9c.th" = "https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/92cfc3b6-ef3bcb9c.th"
                    "04573f0d-f3cf25b2.th" = "https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/04573f0d-f3cf25b2.th"
                    "htdemucs_ft.yaml" = "https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/htdemucs_ft.yaml"
                }
                "Demucs v4: htdemucs_6s" = @{
                    "5c90dfd2-34c22ccb.th" = "https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/5c90dfd2-34c22ccb.th"
                    "htdemucs_6s.yaml" = "https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/htdemucs_6s.yaml"
                }
            }
            mdx_download_vip_list = @{}
            mdx23_download_list = @{}
            mdx23c_download_list = @{
                $drumsepModelEntryName = @{
                    $drumsepModelFileName = $drumsepModelYamlName
                }
            }
            mdx23c_download_vip_list = @{}
            roformer_download_list = @{}
            other_network_list_new = @{
                $drumsepModelEntryName = @{
                    $drumsepModelFileName = $drumsepModelCkptUrl
                    $drumsepModelYamlName = $drumsepModelYamlUrl
                }
            }
        }
        $json = $checks | ConvertTo-Json -Depth 8
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($checksPath, $json, $utf8NoBom)
        return $true
    } catch {
        LogLine ("Shared download_checks.json write failed: " + $_.Exception.Message)
        return $false
    }
}

function DownloadFileWithRetry([string]$Url, [string]$TargetPath, [string]$Label, [long]$MinimumBytes = 1) {
    if ([string]::IsNullOrWhiteSpace($Url) -or [string]::IsNullOrWhiteSpace($TargetPath)) { return $false }
    $tmpPath = $TargetPath + ".part"
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    $preferCurl = ($curl -and $MinimumBytes -ge 104857600)

    if ($preferCurl) {
        try {
            Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            LogProgress ("Downloading " + $Label + " with curl (preferred for large assets): " + $Url)
            $curlExit = RunHidden $curl.Source @(
                "-L",
                "--fail",
                "--retry", "3",
                "--retry-delay", "5",
                "--retry-all-errors",
                "--connect-timeout", "30",
                "--max-time", "1800",
                "-o", $tmpPath,
                $Url
            ) ("Download " + $Label + " via curl")
            if ($curlExit -ne 0) {
                LogLine ("curl download failed for " + $Label + " exit=" + $curlExit + " url=" + $Url)
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
                return $false
            }
            if (-not (Test-Path $tmpPath)) {
                LogLine ("curl download missing output for " + $Label + " url=" + $Url)
                return $false
            }
            $curlBytes = (Get-Item $tmpPath).Length
            if ($curlBytes -lt $MinimumBytes) {
                LogLine ("curl download too small for " + $Label + " bytes=" + $curlBytes + " minimum=" + $MinimumBytes + " url=" + $Url)
                Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
                return $false
            }
            Move-Item -Path $tmpPath -Destination $TargetPath -Force
            return $true
        } catch {
            LogLine ("curl download exception for " + $Label + ": " + $_.Exception.Message + " url=" + $Url)
            Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            return $false
        }
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            LogProgress ("Downloading " + $Label + " (attempt " + $attempt + "/3): " + $Url)
            Invoke-WebRequest -Uri $Url -OutFile $tmpPath -UseBasicParsing | Out-Null
            if ((Get-Item $tmpPath).Length -lt $MinimumBytes) {
                throw ("download_too_small:" + (Get-Item $tmpPath).Length)
            }
            Move-Item -Path $tmpPath -Destination $TargetPath -Force
            return $true
        } catch {
            LogLine ("Invoke-WebRequest failed for " + $Label + " attempt " + $attempt + ": " + $_.Exception.Message + " url=" + $Url)
            Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds ([Math]::Min(5 * $attempt, 15))
        }
    }

    if ($curl) {
        try {
            Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
            LogProgress ("Retrying " + $Label + " with curl: " + $Url)
            $curlExit = RunHidden $curl.Source @(
                "-L",
                "--fail",
                "--retry", "3",
                "--retry-delay", "5",
                "--retry-all-errors",
                "--connect-timeout", "30",
                "--max-time", "300",
                "-o", $tmpPath,
                $Url
            ) ("Download " + $Label + " via curl")
            if ($curlExit -eq 0 -and (Test-Path $tmpPath) -and ((Get-Item $tmpPath).Length -ge $MinimumBytes)) {
                Move-Item -Path $tmpPath -Destination $TargetPath -Force
                return $true
            }
            if ($curlExit -ne 0) {
                LogLine ("curl download failed for " + $Label + " exit=" + $curlExit + " url=" + $Url)
            } elseif (Test-Path $tmpPath) {
                LogLine ("curl download too small for " + $Label + " bytes=" + (Get-Item $tmpPath).Length + " minimum=" + $MinimumBytes + " url=" + $Url)
            } else {
                LogLine ("curl download missing output for " + $Label + " url=" + $Url)
            }
        } catch {
            LogLine ("curl download exception for " + $Label + ": " + $_.Exception.Message + " url=" + $Url)
        }
        Remove-Item -Path $tmpPath -Force -ErrorAction SilentlyContinue
    }

    return $false
}

function EnsureDrumsepAssets([string]$ModelDir) {
    if ([string]::IsNullOrWhiteSpace($ModelDir)) { return $false }
    if ($offlineBundledAllmodelsMode) {
        LogProgress "Installing bundled Drum Kit model assets..."
        return (CopyBundledDrumsepAssets $ModelDir)
    }
    try {
        New-Item -ItemType Directory -Force -Path $ModelDir | Out-Null
    } catch {
        LogLine ("DrumSep model directory create failed: " + $_.Exception.Message)
        return $false
    }

    $assets = @(
        @{ Path = (Join-Path $ModelDir $drumsepModelFileName); Url = $drumsepModelCkptUrl; Label = "DrumSep model checkpoint"; MinimumBytes = $drumsepModelCkptMinimumBytes },
        @{ Path = (Join-Path $ModelDir $drumsepModelYamlName); Url = $drumsepModelYamlUrl; Label = "DrumSep model YAML"; MinimumBytes = $drumsepModelYamlMinimumBytes }
    )
    foreach ($asset in $assets) {
        if (Test-Path $asset.Path) {
            $existingSize = (Get-Item $asset.Path).Length
            if ($existingSize -ge $asset.MinimumBytes) {
                LogProgress ($asset.Label + " already present: " + $asset.Path)
                continue
            }
            LogProgress ($asset.Label + " is incomplete and will be re-downloaded: " + $asset.Path)
            Remove-Item -Path $asset.Path -Force -ErrorAction SilentlyContinue
        }
        if (-not (DownloadFileWithRetry $asset.Url $asset.Path $asset.Label $asset.MinimumBytes)) {
            LogLine ("DrumSep asset download failed: " + $asset.Url)
            return $false
        }
    }

    return (EnsureSharedModelDownloadChecks $ModelDir)
}

function VerifyDrumsepRuntime([string]$PythonPath) {
    if ([string]::IsNullOrWhiteSpace($PythonPath)) { return "python_missing" }
    if (-not (Test-Path $PythonPath)) { return "python_missing" }

    $modelDir = GetDrumsepModelDir
    $modelFile = GetDrumsepModelFilePath
    $modelYaml = GetDrumsepModelYamlPath
    if (-not (Test-Path $modelFile) -or -not (Test-Path $modelYaml)) {
        return "model_missing"
    }

    $verifyCode = @"
import importlib
import importlib.metadata as metadata
import os
import sys

expected = {
    "audio-separator": "$drumsepAudioSeparatorVersion",
    "numpy": "$drumsepNumpyVersion",
    "torch": "$drumsepTorchVersion",
    "onnx": "$drumsepOnnxVersion",
    "onnxruntime": "$drumsepOnnxRuntimeVersion",
    "onnx2torch": "$drumsepOnnx2TorchVersion",
    "onnx2torch-py313": "$drumsepOnnx2TorchPy313Version",
    "numba": "$drumsepNumbaVersion",
    "torchvision": "$drumsepTorchVisionVersion",
}
modules = ["audio_separator", "numpy", "torch", "onnx", "onnxruntime", "onnx2torch"]
errors = []
for module_name in modules:
    try:
        importlib.import_module(module_name)
    except Exception as exc:
        errors.append(f"import_failed:{module_name}:{type(exc).__name__}:{exc}")
for dist_name, wanted in expected.items():
    try:
        found = metadata.version(dist_name).split("+", 1)[0]
    except Exception as exc:
        errors.append(f"version_missing:{dist_name}:{type(exc).__name__}:{exc}")
        continue
    if found != wanted:
        errors.append(f"version_mismatch:{dist_name}:expected={wanted}:found={found}")
if errors:
    print("DRUMSEP_VERIFY broken " + ";".join(errors))
    raise SystemExit(1)
import torch
torch.cuda.is_available = lambda: False
from audio_separator.separator import Separator
sep = Separator(model_file_dir=r"$modelDir", output_dir=".", output_format="wav")
sep.load_model("$drumsepModelFileName")
print("DRUMSEP_VERIFY ok")
"@
    RunHidden $PythonPath @("-c", $verifyCode) "Verify DrumSep runtime" | Out-Null
    if ($LASTEXITCODE -eq 0) { return "ok" }
    return "verify_failed"
}

function VerifyDrumsepDirectmlRuntime([string]$PythonPath) {
    if ([string]::IsNullOrWhiteSpace($PythonPath)) { return "python_missing" }
    if (-not (Test-Path $PythonPath)) { return "python_missing" }

    $modelDir = GetDrumsepModelDir
    $modelFile = GetDrumsepModelFilePath
    $modelYaml = GetDrumsepModelYamlPath
    if (-not (Test-Path $modelFile) -or -not (Test-Path $modelYaml)) {
        return "model_missing"
    }

    $resolvedFfmpeg = ResolveWindowsFfmpegPath -AllowInstall
    if ([string]::IsNullOrWhiteSpace($resolvedFfmpeg) -or -not (Test-Path $resolvedFfmpeg)) {
        LogLine "DrumSep DirectML verify could not resolve FFmpeg"
        return "ffmpeg_missing"
    }
    LogProgress ("DrumSep DirectML verify using FFmpeg: " + $resolvedFfmpeg)

    $verifyCode = @"
import importlib
import importlib.metadata as metadata
import torch
import torch.nn.functional as F

expected = {
    "audio-separator": "$drumsepAudioSeparatorVersion",
    "torch": "$torchVersion",
    "torchvision": "$torchVisionVersion",
    "torch-directml": "$torchDirectMlVersion",
    "onnxruntime-directml": "$onnxRuntimeDirectMlVersion",
    "samplerate": "$drumsepDirectMlSamplerateVersion",
}
modules = ["audio_separator", "numpy", "torch", "torch_directml", "onnxruntime", "onnx2torch", "librosa", "samplerate", "soundfile"]
errors = []
for module_name in modules:
    try:
        importlib.import_module(module_name)
    except Exception as exc:
        errors.append(f"import_failed:{module_name}:{type(exc).__name__}:{exc}")
for dist_name, wanted in expected.items():
    try:
        found = metadata.version(dist_name).split("+", 1)[0]
    except Exception as exc:
        errors.append(f"version_missing:{dist_name}:{type(exc).__name__}:{exc}")
        continue
    if found != wanted:
        errors.append(f"version_mismatch:{dist_name}:expected={wanted}:found={found}")
if errors:
    print("DRUMSEP_DIRECTML_VERIFY broken " + ";".join(errors))
    raise SystemExit(1)
import torch_directml
device = torch_directml.device()
device_count = int(torch_directml.device_count())
if device_count <= 0:
    print("DRUMSEP_DIRECTML_VERIFY directml_device_count=0")
    raise SystemExit(2)
try:
    x = torch.ones((1, 1, 8, 8), dtype=torch.float32, device=device)
except Exception as exc:
    print(f"DRUMSEP_DIRECTML_VERIFY directml_tensor_failed:{type(exc).__name__}:{exc}")
    raise SystemExit(3)
try:
    weight = torch.ones((1, 1, 3, 3), dtype=torch.float32, device=device)
    y = F.conv2d(x, weight)
    _ = float(y.detach().cpu().sum().item())
except Exception as exc:
    print(f"DRUMSEP_DIRECTML_VERIFY directml_conv_failed:{type(exc).__name__}:{exc}")
    raise SystemExit(4)
import onnxruntime as ort
providers = ort.get_available_providers() or []
if "DmlExecutionProvider" not in providers:
    print("DRUMSEP_DIRECTML_VERIFY dml_provider_missing providers=" + ",".join(str(x) for x in providers))
    raise SystemExit(5)
from audio_separator.separator import Separator
sep = Separator(model_file_dir=r"$modelDir", output_dir=".", output_format="wav")
sep.load_model("$drumsepModelFileName")
print("DRUMSEP_DIRECTML_VERIFY ok device=" + str(device) + " provider=DmlExecutionProvider")
"@
    InvokeWithResolvedFfmpegEnvironment $resolvedFfmpeg {
        RunHidden $PythonPath @("-c", $verifyCode) "Verify DrumSep DirectML runtime" | Out-Null
    } | Out-Null
    if ($LASTEXITCODE -eq 0) { return "ok" }
    if ($LASTEXITCODE -eq 2) { return "torch_directml_no_device" }
    if ($LASTEXITCODE -eq 3) { return "directml_tensor_failed" }
    if ($LASTEXITCODE -eq 4) { return "directml_conv_failed" }
    if ($LASTEXITCODE -eq 5) { return "dml_provider_missing" }
    if ($LASTEXITCODE -eq 9009) { return "ffmpeg_missing" }
    return "verify_failed"
}

function VerifyDrumsepCudaRuntime([string]$PythonPath) {
    if ([string]::IsNullOrWhiteSpace($PythonPath)) { return @{ Status = "python_missing"; Probe = @{}; FfmpegPath = "" } }
    if (-not (Test-Path $PythonPath)) { return @{ Status = "python_missing"; Probe = @{}; FfmpegPath = "" } }

    $modelDir = GetDrumsepModelDir
    $modelFile = GetDrumsepModelFilePath
    $modelYaml = GetDrumsepModelYamlPath
    if (-not (Test-Path $modelFile) -or -not (Test-Path $modelYaml)) {
        return @{ Status = "model_missing"; Probe = @{}; FfmpegPath = "" }
    }

    $resolvedFfmpeg = ResolveWindowsFfmpegPath -AllowInstall
    if ([string]::IsNullOrWhiteSpace($resolvedFfmpeg) -or -not (Test-Path $resolvedFfmpeg)) {
        LogLine "DrumSep CUDA verify could not resolve FFmpeg"
        return @{ Status = "ffmpeg_missing"; Probe = @{}; FfmpegPath = "" }
    }
    LogProgress ("DrumSep CUDA verify using FFmpeg: " + $resolvedFfmpeg)
    $resultPath = Join-Path $RuntimeBase "state\\drumsep_cuda_verify.json"
    if (Test-Path $resultPath) {
        Remove-Item -Path $resultPath -Force -ErrorAction SilentlyContinue
    }

    $verifyCode = @"
import importlib
import importlib.metadata as metadata
import json
from pathlib import Path
import onnxruntime as ort
import torch
from audio_separator.separator import Separator

expected = {
    "audio-separator": "$drumsepAudioSeparatorVersion",
    "torch": "$torchVersion",
    "torchvision": "$torchVisionVersion",
    "torchaudio": "$torchAudioVersion",
    "onnxruntime-gpu": "$onnxRuntimeGpuVersion",
}
modules = ["audio_separator", "torch", "torchvision", "torchaudio", "onnxruntime"]
errors = []
for module_name in modules:
    try:
        importlib.import_module(module_name)
    except Exception as exc:
        errors.append(f"import_failed:{module_name}:{type(exc).__name__}:{exc}")
for dist_name, wanted in expected.items():
    try:
        found = metadata.version(dist_name)
    except Exception as exc:
        errors.append(f"version_missing:{dist_name}:{type(exc).__name__}:{exc}")
        continue
    if found != wanted and found.split("+", 1)[0] != wanted:
        errors.append(f"version_mismatch:{dist_name}:expected={wanted}:found={found}")
providers = [str(item) for item in (ort.get_available_providers() or [])]
if not bool(torch.cuda.is_available()):
    errors.append("torch_cuda_unavailable")
cuda_device_name = ""
cuda_device_id = ""
if bool(torch.cuda.is_available()):
    cuda_device_name = str(torch.cuda.get_device_name(0))
    cuda_device_id = "cuda:0"
    tensor = torch.ones((1, 1, 8, 8), dtype=torch.float32, device="cuda:0")
    weight = torch.ones((1, 1, 3, 3), dtype=torch.float32, device="cuda:0")
    out = torch.nn.functional.conv2d(tensor, weight)
    torch.cuda.synchronize()
    _ = float(out.detach().cpu().sum().item())
if "CUDAExecutionProvider" not in providers:
    errors.append("cuda_provider_missing")
sep = Separator(model_file_dir=r"$modelDir", output_dir=".", output_format="wav")
sep.load_model("$drumsepModelFileName")
payload = {
    "status": "ok" if not errors else "verify_failed",
    "DRUMSEP_CUDA_AUDIO_SEPARATOR_VERSION": metadata.version("audio-separator"),
    "DRUMSEP_CUDA_TORCH_VERSION": metadata.version("torch"),
    "DRUMSEP_CUDA_TORCHVISION_VERSION": metadata.version("torchvision"),
    "DRUMSEP_CUDA_TORCHAUDIO_VERSION": metadata.version("torchaudio"),
    "DRUMSEP_CUDA_ONNXRUNTIME_GPU_VERSION": metadata.version("onnxruntime-gpu"),
    "TORCH_CUDA_STATUS": "ok" if bool(torch.cuda.is_available()) else "error",
    "ORT_CUDA_PROVIDER": "ok" if "CUDAExecutionProvider" in providers else "error",
    "CUDA_DEVICE": cuda_device_name,
    "CUDA_DEVICE_ID": cuda_device_id,
    "ORT_AVAILABLE_PROVIDERS": ",".join(providers),
    "FFMPEG_STATUS": "ok",
    "errors": errors,
}
Path(r"$resultPath").write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
if errors:
    print("DRUMSEP_CUDA_VERIFY broken " + ";".join(errors))
    raise SystemExit(1)
print("DRUMSEP_CUDA_VERIFY ok device=" + cuda_device_name + " provider=CUDAExecutionProvider")
"@
    InvokeWithResolvedFfmpegEnvironment $resolvedFfmpeg {
        RunHidden $PythonPath @("-c", $verifyCode) "Verify DrumSep CUDA runtime" | Out-Null
    } | Out-Null
    $probe = @{}
    if (Test-Path $resultPath) {
        try {
            $probe = Get-Content -Raw $resultPath | ConvertFrom-Json -AsHashtable
        } catch {
            $probe = @{}
        }
    }
    $status = if ($LASTEXITCODE -eq 0) { "ok" } elseif ($LASTEXITCODE -eq 9009) { "ffmpeg_missing" } else { "verify_failed" }
    return @{ Status = $status; Probe = $probe; FfmpegPath = $resolvedFfmpeg }
}

function InstallDrumsepRuntime([string]$BasePythonPath) {
    $drumsepPython = GetDrumsepRuntimePythonPath
    $modelDir = GetDrumsepModelDir

    WriteDrumsepState "running" "missing" "creating_venv"
    LogProgress ("DrumSep runtime path: " + (Join-Path $RuntimeBase ".venv-drumsep"))
    Remove-Item -Path (Join-Path $RuntimeBase ".venv-drumsep") -Recurse -Force -ErrorAction SilentlyContinue
    RunHidden $BasePythonPath @("-m", "venv", (Join-Path $RuntimeBase ".venv-drumsep")) "Create DrumSep virtual environment" | Out-Null
    if (-not (Test-Path $drumsepPython)) {
        WriteDrumsepState "install_failed" "missing" "venv_create_failed"
        return $false
    }

    WriteDrumsepState "running" "missing" "pip_upgrade"
    InstallWithPip $drumsepPython @("--upgrade", "pip", "setuptools", "wheel") "Upgrade DrumSep pip"
    if ($LASTEXITCODE -ne 0) {
        WriteDrumsepState "install_failed" "missing" "pip_upgrade_failed"
        return $false
    }

    WriteDrumsepState "running" "missing" "package_install"
    $drumsepCpuInstallArgs = @(
        "--upgrade",
        "audio-separator==$drumsepAudioSeparatorVersion",
        "numpy==$drumsepNumpyVersion",
        "onnxruntime==$drumsepOnnxRuntimeVersion",
        "onnx==$drumsepOnnxVersion",
        "onnx2torch==$drumsepOnnx2TorchVersion",
        "onnx2torch-py313==$drumsepOnnx2TorchPy313Version",
        "torch==$drumsepTorchVersion",
        "torchvision==$drumsepTorchVisionVersion",
        "llvmlite==$drumsepLlvmliteVersion",
        "numba==$drumsepNumbaVersion"
    )
    $installOk = $false
    if ($offlineBundledAllmodelsMode) {
        LogProgress "Installing bundled Drum Kit runtime..."
        $installOk = InstallBundledDrumsepPackages $drumsepPython $drumsepCpuInstallArgs "Installing bundled Drum Kit runtime..."
    } else {
        $installOk = InstallWithPipAllowOnlineFallback $drumsepPython $drumsepCpuInstallArgs "Install DrumSep packages"
    }
    if (-not $installOk) {
        WriteDrumsepState "install_failed" "missing" "package_install_failed"
        return $false
    }

    WriteDrumsepState "running" "missing" "model_download"
    if (-not (EnsureDrumsepAssets $modelDir)) {
        WriteDrumsepState "install_failed" "missing" "model_download_failed"
        return $false
    }

    WriteDrumsepState "running" "ok" "verify_runtime"
    if ($offlineBundledAllmodelsMode) {
        LogProgress "Verifying bundled Drum Kit runtime..."
    }
    $verifyResult = VerifyDrumsepRuntime $drumsepPython
    if ($verifyResult -ne "ok") {
        if ($verifyResult -eq "model_missing") {
            WriteDrumsepState "install_failed" "missing" "model_missing"
        } elseif ($verifyResult -eq "python_missing") {
            WriteDrumsepState "install_failed" "missing" "python_missing"
        } else {
            WriteDrumsepState "broken" "load_failed" "verify_failed"
        }
        return $false
    }

    WriteDrumsepState "ok" "ok" "ok"
    if ($offlineBundledAllmodelsMode) {
        LogProgress "Drum Kit Splitter ready."
    }
    return $true
}

function InstallDrumsepDirectmlRuntime([string]$BasePythonPath) {
    $drumsepPython = GetDrumsepDirectmlRuntimePythonPath
    $modelDir = GetDrumsepModelDir

    if (Test-Path $drumsepPython) {
        WriteDrumsepDirectmlState "running" "missing" "verify_existing_runtime"
        LogProgress "Verifying existing DrumSep DirectML runtime"
        if (EnsureDrumsepAssets $modelDir) {
            $existingVerifyResult = VerifyDrumsepDirectmlRuntime $drumsepPython
            if ($existingVerifyResult -eq "ok") {
                WriteDrumsepDirectmlState "ok" "ok" "ok"
                LogProgress "Existing DrumSep DirectML runtime verified"
                return $true
            }
            LogLine ("Existing DrumSep DirectML runtime verify failed: " + $existingVerifyResult + "; rebuilding runtime")
        } else {
            LogLine "Existing DrumSep DirectML runtime assets could not be verified; rebuilding runtime"
        }
    }

    WriteDrumsepDirectmlState "running" "missing" "creating_venv"
    LogProgress ("DrumSep DirectML runtime path: " + (Join-Path $RuntimeBase ".venv-drumsep-directml"))
    Remove-Item -Path (Join-Path $RuntimeBase ".venv-drumsep-directml") -Recurse -Force -ErrorAction SilentlyContinue
    RunHidden $BasePythonPath @("-m", "venv", (Join-Path $RuntimeBase ".venv-drumsep-directml")) "Create DrumSep DirectML virtual environment" | Out-Null
    if (-not (Test-Path $drumsepPython)) {
        WriteDrumsepDirectmlState "install_failed" "missing" "venv_create_failed"
        return $false
    }

    WriteDrumsepDirectmlState "running" "missing" "pip_upgrade"
    InstallWithPip $drumsepPython @("--upgrade", "pip", "setuptools", "wheel") "Upgrade DrumSep DirectML pip"
    if ($LASTEXITCODE -ne 0) {
        WriteDrumsepDirectmlState "install_failed" "missing" "pip_upgrade_failed"
        return $false
    }

    WriteDrumsepDirectmlState "running" "missing" "package_install"
    $drumsepDirectmlInstallArgs = @(
        "--upgrade",
        "--prefer-binary",
        "-c", $directmlConstraints,
        "audio-separator==$drumsepAudioSeparatorVersion",
        "librosa==$drumsepDirectMlLibrosaVersion",
        "samplerate==$drumsepDirectMlSamplerateVersion",
        "soundfile==$drumsepDirectMlSoundFileVersion",
        "onnx==$drumsepOnnxVersion",
        "onnx2torch==$drumsepOnnx2TorchVersion",
        "torch==$torchVersion",
        "torchvision==$torchVisionVersion",
        "torch-directml==$torchDirectMlVersion",
        "onnxruntime-directml==$onnxRuntimeDirectMlVersion"
    )
    $installOk = $false
    if ($offlineBundledAllmodelsMode) {
        LogProgress "Installing bundled Drum Kit runtime..."
        $installOk = InstallBundledDrumsepPackages $drumsepPython $drumsepDirectmlInstallArgs "Installing bundled Drum Kit runtime..."
    } else {
        $installOk = InstallWithPipAllowOnlineFallback $drumsepPython $drumsepDirectmlInstallArgs "Install DrumSep DirectML packages"
    }
    if (-not $installOk) {
        WriteDrumsepDirectmlState "install_failed" "missing" "package_install_failed"
        return $false
    }

    WriteDrumsepDirectmlState "running" "missing" "model_download"
    if (-not (EnsureDrumsepAssets $modelDir)) {
        WriteDrumsepDirectmlState "install_failed" "missing" "model_download_failed"
        return $false
    }

    WriteDrumsepDirectmlState "running" "ok" "verify_runtime"
    if ($offlineBundledAllmodelsMode) {
        LogProgress "Verifying bundled Drum Kit runtime..."
    }
    $verifyResult = VerifyDrumsepDirectmlRuntime $drumsepPython
    if ($verifyResult -ne "ok") {
        if ($verifyResult -eq "model_missing") {
            WriteDrumsepDirectmlState "error" "missing" "model_missing"
        } elseif ($verifyResult -eq "python_missing") {
            WriteDrumsepDirectmlState "error" "missing" "python_missing"
        } elseif ($verifyResult -eq "ffmpeg_missing") {
            WriteDrumsepDirectmlState "error" "ok" "ffmpeg_missing"
        } elseif ($verifyResult -eq "torch_directml_no_device") {
            WriteDrumsepDirectmlState "error" "ok" "torch_directml_no_device"
        } elseif ($verifyResult -eq "directml_tensor_failed") {
            WriteDrumsepDirectmlState "error" "ok" "directml_tensor_failed"
        } elseif ($verifyResult -eq "directml_conv_failed") {
            WriteDrumsepDirectmlState "error" "ok" "directml_conv_failed"
        } elseif ($verifyResult -eq "dml_provider_missing") {
            WriteDrumsepDirectmlState "error" "ok" "dml_provider_missing"
        } else {
            WriteDrumsepDirectmlState "error" "load_failed" "probe_failed:$verifyResult"
        }
        return $false
    }

    WriteDrumsepDirectmlState "ok" "ok" "ok"
    if ($offlineBundledAllmodelsMode) {
        LogProgress "Drum Kit Splitter ready."
    }
    return $true
}

function InstallDrumsepCudaRuntime([string]$BasePythonPath) {
    if (-not (TestWindowsCudaCapableHost)) {
        WriteDrumsepCudaState "error" "missing" "cuda_host_missing"
        return $false
    }

    $drumsepPython = GetDrumsepCudaRuntimePythonPath
    $modelDir = GetDrumsepModelDir

    if (Test-Path $drumsepPython) {
        WriteDrumsepCudaState "running" "missing" "verify_existing_runtime"
        LogProgress "Verifying existing DrumSep CUDA runtime"
        if (EnsureDrumsepAssets $modelDir) {
            $existingVerify = VerifyDrumsepCudaRuntime $drumsepPython
            if ($existingVerify.Status -eq "ok") {
                WriteDrumsepCudaState "ok" "ok" "ok" $existingVerify.Probe $existingVerify.FfmpegPath
                LogProgress "Existing DrumSep CUDA runtime verified"
                return $true
            }
            LogLine ("Existing DrumSep CUDA runtime verify failed: " + $existingVerify.Status + "; rebuilding runtime")
        } else {
            LogLine "Existing DrumSep CUDA runtime assets could not be verified; rebuilding runtime"
        }
    }

    WriteDrumsepCudaState "running" "missing" "creating_venv"
    LogProgress ("DrumSep CUDA runtime path: " + (Join-Path $RuntimeBase ".venv-drumsep-cuda"))
    Remove-Item -Path (Join-Path $RuntimeBase ".venv-drumsep-cuda") -Recurse -Force -ErrorAction SilentlyContinue
    RunHidden $BasePythonPath @("-m", "venv", (Join-Path $RuntimeBase ".venv-drumsep-cuda")) "Create DrumSep CUDA virtual environment" | Out-Null
    if (-not (Test-Path $drumsepPython)) {
        WriteDrumsepCudaState "error" "missing" "venv_create_failed"
        return $false
    }

    WriteDrumsepCudaState "running" "missing" "pip_upgrade"
    InstallWithPip $drumsepPython @("--upgrade", "pip", "setuptools", "wheel") "Upgrade DrumSep CUDA pip"
    if ($LASTEXITCODE -ne 0) {
        WriteDrumsepCudaState "error" "missing" "pip_upgrade_failed"
        return $false
    }

    WriteDrumsepCudaState "running" "missing" "package_install"
    $drumsepCudaInstallArgs = @(
        "--upgrade",
        "--prefer-binary",
        "audio-separator==$drumsepAudioSeparatorVersion",
        "torch==$torchVersion$torchCudaSuffix",
        "torchvision==$torchVisionVersion$torchCudaSuffix",
        "torchaudio==$torchAudioVersion$torchCudaSuffix",
        "onnxruntime-gpu==$onnxRuntimeGpuVersion"
    )
    $installOk = $false
    if ($offlineBundledAllmodelsMode) {
        LogProgress "Installing bundled Drum Kit runtime..."
        $installOk = InstallBundledDrumsepPackages $drumsepPython $drumsepCudaInstallArgs "Installing bundled Drum Kit runtime..."
    } else {
        $drumsepCudaInstallArgs = @(
            "--upgrade",
            "--prefer-binary",
            "--extra-index-url", $pytorchCudaIndex,
            "audio-separator==$drumsepAudioSeparatorVersion",
            "torch==$torchVersion$torchCudaSuffix",
            "torchvision==$torchVisionVersion$torchCudaSuffix",
            "torchaudio==$torchAudioVersion$torchCudaSuffix",
            "onnxruntime-gpu==$onnxRuntimeGpuVersion"
        )
        $installOk = InstallWithPipAllowOnlineFallback $drumsepPython $drumsepCudaInstallArgs "Install DrumSep CUDA packages"
    }
    if (-not $installOk) {
        WriteDrumsepCudaState "error" "missing" "package_install_failed"
        return $false
    }

    WriteDrumsepCudaState "running" "missing" "model_download"
    if (-not (EnsureDrumsepAssets $modelDir)) {
        WriteDrumsepCudaState "error" "missing" "model_download_failed"
        return $false
    }

    WriteDrumsepCudaState "running" "ok" "verify_runtime"
    if ($offlineBundledAllmodelsMode) {
        LogProgress "Verifying bundled Drum Kit runtime..."
    }
    $verifyResult = VerifyDrumsepCudaRuntime $drumsepPython
    if ($verifyResult.Status -ne "ok") {
        WriteDrumsepCudaState "error" "ok" ("probe_failed:" + $verifyResult.Status) $verifyResult.Probe $verifyResult.FfmpegPath
        return $false
    }

    WriteDrumsepCudaState "ok" "ok" "ok" $verifyResult.Probe $verifyResult.FfmpegPath
    if ($offlineBundledAllmodelsMode) {
        LogProgress "Drum Kit Splitter ready."
    }
    return $true
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

if ($Mode -eq "drumsep-runtime" -or $Mode -eq "drumsep-cuda-runtime" -or $Mode -eq "drumsep-directml-runtime") {
    $isCudaDrumsepRuntime = ($Mode -eq "drumsep-cuda-runtime")
    $isDirectmlDrumsepRuntime = ($Mode -eq "drumsep-directml-runtime")
    $runtimeLabel = "Drum Kit Split runtime"
    $bootstrapReason = "drumsep_runtime_bootstrap"
    if ($isCudaDrumsepRuntime) {
        $runtimeLabel = "Drum Kit Split CUDA runtime"
        $bootstrapReason = "drumsep_cuda_runtime_bootstrap"
    }
    if ($isDirectmlDrumsepRuntime) {
        $runtimeLabel = "Drum Kit Split DirectML runtime"
        $bootstrapReason = "drumsep_directml_runtime_bootstrap"
    }
    WriteBootstrapGuard "running" $bootstrapReason
    if (-not (TestRuntimeWritable $RuntimeBase)) {
        LogLine ("Runtime base is not writable: " + $RuntimeBase)
        if ($isDirectmlDrumsepRuntime) {
            WriteDrumsepDirectmlState "error" "missing" "runtime_write_test_failed"
        } elseif ($isCudaDrumsepRuntime) {
            WriteDrumsepCudaState "error" "missing" "runtime_write_test_failed"
        } else {
            WriteDrumsepState "install_failed" "missing" "runtime_write_test_failed"
        }
        WriteBootstrapGuard "failed" "runtime_write_test_failed"
        exit 1
    }
    if (-not (TestRuntimeWritable (Join-Path $RuntimeBase "state"))) {
        LogLine ("Runtime state directory is not writable: " + (Join-Path $RuntimeBase "state"))
        if ($isDirectmlDrumsepRuntime) {
            WriteDrumsepDirectmlState "error" "missing" "runtime_write_test_failed"
        } elseif ($isCudaDrumsepRuntime) {
            WriteDrumsepCudaState "error" "missing" "runtime_write_test_failed"
        } else {
            WriteDrumsepState "install_failed" "missing" "runtime_write_test_failed"
        }
        WriteBootstrapGuard "failed" "runtime_write_test_failed"
        exit 1
    }
    if (-not (TestRuntimeWritable (Join-Path $RuntimeBase "logs"))) {
        LogLine ("Runtime logs directory is not writable: " + (Join-Path $RuntimeBase "logs"))
        if ($isDirectmlDrumsepRuntime) {
            WriteDrumsepDirectmlState "error" "missing" "runtime_write_test_failed"
        } elseif ($isCudaDrumsepRuntime) {
            WriteDrumsepCudaState "error" "missing" "runtime_write_test_failed"
        } else {
            WriteDrumsepState "install_failed" "missing" "runtime_write_test_failed"
        }
        WriteBootstrapGuard "failed" "runtime_write_test_failed"
        exit 1
    }

    LogProgress ("Preparing " + $runtimeLabel)
    $basePython = ResolveSupportedWindowsPython $candidates
    if (-not $basePython) {
        if ($isDirectmlDrumsepRuntime) {
            WriteDrumsepDirectmlState "error" "missing" "python_missing"
        } elseif ($isCudaDrumsepRuntime) {
            WriteDrumsepCudaState "error" "missing" "python_missing"
        } else {
            WriteDrumsepState "install_failed" "missing" "python_missing"
        }
        WriteBootstrapGuard "failed" "python_missing"
        exit 1
    }

    $runtimeInstalled = $false
    if ($isCudaDrumsepRuntime) {
        $runtimeInstalled = InstallDrumsepCudaRuntime $basePython
    } elseif ($isDirectmlDrumsepRuntime) {
        $runtimeInstalled = InstallDrumsepDirectmlRuntime $basePython
    } else {
        $runtimeInstalled = InstallDrumsepRuntime $basePython
    }
    if (-not $runtimeInstalled) {
        $installFailedReason = "drumsep_runtime_install_failed"
        if ($isCudaDrumsepRuntime) {
            $installFailedReason = "drumsep_cuda_runtime_install_failed"
        } elseif ($isDirectmlDrumsepRuntime) {
            $installFailedReason = "drumsep_directml_runtime_install_failed"
        }
        WriteBootstrapGuard "failed" $installFailedReason
        exit 1
    }

    WriteBootstrapGuard "ok" "completed"
    LogProgress ($runtimeLabel + " install finished")
    exit 0
}

if ($Mode -eq "ready-to-go-verify") {
    RunReadyToGoVerifyOnly
}

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
$ffmpeg = ResolveWindowsFfmpegPath
if ($ffmpeg -and (Test-Path $ffmpeg)) {
    $script:FfmpegSource = "existing"
    LogStatusDetail "FFmpeg already installed"
    LogProgress "FFMPEG_SOURCE=existing"
    LogProgress ("ffmpeg_existing_ok=" + $ffmpeg)
    LogProgress "ffmpeg_download_skipped=existing_ok"
} else {
    $ffmpeg = ResolveWindowsFfmpegPath -AllowInstall
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

    $readyModelDir = GetDrumsepModelDir
    $readyCoreStatus = VerifyCoreModelCache $readyModelDir
    $readyRuntime = if ($backend -eq "cuda") { "cuda" } elseif ($backend -eq "directml") { "directml" } else { "cpu" }
    $readyRuntimeStatus = "missing"
    $readyDrumsepModelStatus = "missing"
    $readyDetail = ""
    if ($status -eq "ok") {
        if (-not (EnsureCoreModelCache $python $readyModelDir)) {
            Set-Status "deps_failed" "core_model_prefetch_failed"
        } else {
            $readyCoreStatus = VerifyCoreModelCache $readyModelDir
        }
    }
    if ($status -eq "ok") {
        Step "step_5_drumkit" "drum kit runtime and offline models"
        LogStatusDetail "Preparing Drum Kit separation runtime and offline models. This can take several minutes..."
        $drumsepReadyOk = switch ($readyRuntime) {
            "cuda" { InstallDrumsepCudaRuntime $python }
            "directml" { InstallDrumsepDirectmlRuntime $python }
            default { InstallDrumsepRuntime $python }
        }
        if (-not $drumsepReadyOk) {
            Set-Status "deps_failed" "drumsep_ready_runtime_failed"
        }
    }
    $readyRuntimeState = GetReadyToGoRuntimeState $readyRuntime
    $readyRuntimeStatus = [string]$readyRuntimeState.RuntimeStatus
    $readyDrumsepModelStatus = [string]$readyRuntimeState.DrumsepModelStatus
    $readyDetail = [string]$readyRuntimeState.Detail
    if ($status -ne "ok" -and [string]::IsNullOrWhiteSpace($readyDetail)) {
        $readyDetail = $statusReason
    }
    $mainRuntimeStatus = if ($status -eq "ok") { "ok" } else { "broken" }
    WriteReadyToGoState $readyRuntime $readyRuntimeStatus $readyDrumsepModelStatus $readyCoreStatus $readyDetail $mainRuntimeStatus
} else {
    LogProgress "Skipping core install (Python venv unavailable)"
    WriteReadyToGoState $backend "missing" "missing" (VerifyCoreModelCache (GetDrumsepModelDir)) "python_unavailable" "missing"
}

if ($RuntimeBase) {
    $capPath = Join-Path $RuntimeBase "state\\capabilities.env"
    $bootstrapStatusValue = $status
    $bootstrapReasonValue = $statusReason
    $verificationValue = if (($status -eq "ok") -and $audioSeparatorOk -and $stemwerkCoreOk -and $samplerateOk) { "ok" } else { "failed" }
    $audioSeparatorValue = if ($audioSeparatorOk) { "ok" } else { "missing" }
    $stemwerkCoreValue = if ($stemwerkCoreOk) { "ok" } else { "missing" }
    $samplerateValue = if ($samplerateOk) { "ok" } else { "not_checked" }
    $juliusValue = if ($juliusOk) { "ok" } else { "not_checked" }
    $pythonValue = if ($python) { $python } else { "" }
    $ffmpegValue = if ($ffmpeg) { $ffmpeg } else { "" }
    $wroteCapabilities = WriteCapabilities $capPath $profile $backend $backendReason $pythonValue $ffmpegValue $RuntimeBase $bootstrapStatusValue $bootstrapReasonValue $verificationValue $audioSeparatorValue $stemwerkCoreValue $samplerateValue $juliusValue
    if (-not $wroteCapabilities) {
        Set-Status "deps_failed" "capabilities_write_failed"
    }
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
if ($script:FfmpegSource) { $lines += "FFMPEG_SOURCE=$script:FfmpegSource" }
if ($installerMode) { $lines += "INSTALLER=1" }
if ($RuntimeBase) { $lines += "RUNTIME_BASE=$RuntimeBase" }

$lines | Out-File -FilePath $StateFile -Encoding ascii

if ($RuntimeBase) {
    $pidPath = Join-NormalizedWindowsPath $RuntimeBase @("state", "bootstrap.pid")
    Remove-Item -Path $pidPath -Force -ErrorAction SilentlyContinue
    $guardStatus = if ($status -eq "ok") { "ok" } else { "failed" }
    $guardReason = if ($status -eq "ok") { "ok" } else { $statusReason }
    WriteBootstrapGuard $guardStatus $guardReason ""
}

if ($status -ne "ok") {
    exit 1
}
LogProgress "Bootstrap complete"
exit 0
