# VenvSafety.ps1
#
# Safety-invariant enforcement for the #118 harness. The experimental
# harness may mutate ONLY the normal STEMwerk python environment at
# %LOCALAPPDATA%\STEMwerk\.venv. This module verifies that identity
# rigorously and FAILS CLOSED (refuses to proceed) on any doubt.
#
# Explicitly never touched by this harness, enforced by the checks below:
#   - .venv-drumsep* (any path segment containing "drumsep")
#   - model cache, REAPER scripts, ReaPack files, installer files, registry,
#     system Python, unrelated virtual environments, other user files
#
# No admin rights are required or used anywhere in this module.

Set-StrictMode -Version Latest

function Get-ExpectedStemwerkVenvPath {
    $root = [System.Environment]::GetFolderPath('LocalApplicationData')
    return (Join-Path $root 'STEMwerk\.venv')
}

function Test-StemwerkVenvIdentity {
    <#
        .SYNOPSIS
        Rigorously verifies that the given path is really the normal
        STEMwerk venv before anything is allowed to mutate it.
        Returns an object with Ok=$true only when every check passes;
        any ambiguity or error results in Ok=$false (fail closed).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$VenvPath
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    $ok = $true

    try {
        $resolved = (Resolve-Path -LiteralPath $VenvPath -ErrorAction Stop).Path
    }
    catch {
        return [PSCustomObject]@{ Ok = $false; Reasons = @("path does not exist or is not resolvable: $VenvPath") ; ResolvedPath = $null }
    }

    $expected = Get-ExpectedStemwerkVenvPath
    try {
        $expectedResolved = (Resolve-Path -LiteralPath $expected -ErrorAction Stop).Path
    }
    catch {
        return [PSCustomObject]@{ Ok = $false; Reasons = @("expected STEMwerk venv path does not exist: $expected") ; ResolvedPath = $null }
    }

    if ($resolved -ne $expectedResolved) {
        $ok = $false
        $reasons.Add("resolved path '$resolved' does not exactly match expected STEMwerk venv path '$expectedResolved'")
    }

    if ($resolved -match '(?i)drumsep') {
        $ok = $false
        $reasons.Add('path contains "drumsep" - this looks like the separate drumsep venv, which must never be touched')
    }

    $pyvenvCfg = Join-Path $resolved 'pyvenv.cfg'
    if (-not (Test-Path -LiteralPath $pyvenvCfg)) {
        $ok = $false
        $reasons.Add('pyvenv.cfg not found - this does not look like a real virtualenv')
    }

    $pythonExe = Join-Path $resolved 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $pythonExe)) {
        $ok = $false
        $reasons.Add('Scripts\python.exe not found')
    }

    # Confirm this venv sits inside a real STEMwerk installation root
    # (sibling directories that a genuine STEMwerk install always has),
    # not some unrelated .venv that happens to live at the same path.
    $stemwerkRoot = Split-Path -Parent $resolved
    $expectedSiblings = @('models', 'ffmpeg', 'logs')
    $missingSiblings = @()
    foreach ($sib in $expectedSiblings) {
        if (-not (Test-Path -LiteralPath (Join-Path $stemwerkRoot $sib))) {
            $missingSiblings += $sib
        }
    }
    if ($missingSiblings.Count -eq $expectedSiblings.Count) {
        $ok = $false
        $reasons.Add("none of the expected STEMwerk sibling directories were found next to .venv ($($expectedSiblings -join ', ')) - refusing to treat this as a real STEMwerk installation")
    }

    # Confirm a STEMwerk-relevant package is actually installed, using the
    # venv's own pip - a real STEMwerk venv will have torch and
    # audio-separator; an unrelated empty venv will not.
    if ($ok) {
        $pipList = Invoke-NativeProcess -FilePath $pythonExe -ArgumentList @('-m', 'pip', 'list', '--format=freeze')
        if (-not $pipList.Success) {
            $ok = $false
            $reasons.Add('unable to run pip list against this venv to confirm package identity')
        }
        else {
            $hasTorch = $pipList.StdOut -match '(?im)^torch=='
            $hasAudioSeparator = $pipList.StdOut -match '(?im)^audio-separator=='
            if (-not ($hasTorch -and $hasAudioSeparator)) {
                $ok = $false
                $reasons.Add('venv does not have both torch and audio-separator installed - does not look like the real STEMwerk runtime venv')
            }
        }
    }

    return [PSCustomObject]@{
        Ok           = $ok
        Reasons      = $reasons.ToArray()
        ResolvedPath = $resolved
        PythonExe    = $pythonExe
    }
}

function New-BaselineManifest {
    <#
        .SYNOPSIS
        Captures the exact installed torch/torchvision/torchaudio
        versions (and torch.version.cuda) from the verified venv, so
        rollback restores precisely what was there - not an assumed
        release baseline.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PythonExe,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $pipShow = Invoke-NativeProcess -FilePath $PythonExe -ArgumentList @('-m', 'pip', 'list', '--format=freeze')
    if (-not $pipShow.Success) {
        return [PSCustomObject]@{ Ok = $false; Reason = 'pip list failed while capturing baseline manifest'; Native = $pipShow }
    }

    $packages = [ordered]@{}
    foreach ($line in ($pipShow.StdOut -split "`r?`n")) {
        if ($line -match '^(torch|torchvision|torchaudio)==(.+)$') {
            $packages[$Matches[1]] = $Matches[2]
        }
    }

    foreach ($required in @('torch', 'torchvision', 'torchaudio')) {
        if (-not $packages.Contains($required)) {
            return [PSCustomObject]@{ Ok = $false; Reason = "could not find installed version of '$required' in pip freeze output"; Native = $pipShow }
        }
    }

    # Determine which CUDA wheel index tag (e.g. cu121) the currently
    # installed torch was built against, so rollback can pull from the
    # exact same index rather than guessing.
    $cudaTag = $null
    if ($packages['torch'] -match '\+cu(\d+)$') {
        $cudaTag = "cu$($Matches[1])"
    }

    $manifest = [ordered]@{
        captured_utc = (Get-Date).ToUniversalTime().ToString('o')
        packages     = $packages
        cuda_tag     = $cudaTag
    }

    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8
    return [PSCustomObject]@{ Ok = $true; Manifest = $manifest; ManifestPath = $ManifestPath }
}

function Invoke-TorchStackInstall {
    <#
        .SYNOPSIS
        Installs a specific torch/torchvision/torchaudio combination from
        a specific CUDA wheel index into the verified venv.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PythonExe,
        [Parameter(Mandatory = $true)][string]$TorchSpec,
        [Parameter(Mandatory = $true)][string]$TorchvisionSpec,
        [Parameter(Mandatory = $true)][string]$TorchaudioSpec,
        [Parameter(Mandatory = $true)][string]$IndexUrl,
        [int]$TimeoutSeconds = 1800
    )

    $args = @('-m', 'pip', 'install', '--index-url', $IndexUrl, $TorchSpec, $TorchvisionSpec, $TorchaudioSpec)
    return Invoke-NativeProcess -FilePath $PythonExe -ArgumentList $args -TimeoutSeconds $TimeoutSeconds
}

function Invoke-BaselineRestore {
    <#
        .SYNOPSIS
        Restores the exact package versions recorded in a baseline
        manifest (produced by New-BaselineManifest), pulling from the
        same CUDA wheel index the baseline was originally built from.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PythonExe,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [int]$TimeoutSeconds = 1800
    )

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return [PSCustomObject]@{ Ok = $false; Reason = "baseline manifest not found at $ManifestPath" }
    }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json

    $cudaTag = $manifest.cuda_tag
    if (-not $cudaTag) {
        return [PSCustomObject]@{ Ok = $false; Reason = 'baseline manifest has no recorded cuda_tag; refusing to guess an index URL' }
    }
    $indexUrl = "https://download.pytorch.org/whl/$cudaTag"

    $torchSpec = "torch==$($manifest.packages.torch)"
    $torchvisionSpec = "torchvision==$($manifest.packages.torchvision)"
    $torchaudioSpec = "torchaudio==$($manifest.packages.torchaudio)"

    $native = Invoke-TorchStackInstall -PythonExe $PythonExe -TorchSpec $torchSpec -TorchvisionSpec $torchvisionSpec -TorchaudioSpec $torchaudioSpec -IndexUrl $indexUrl -TimeoutSeconds $TimeoutSeconds

    return [PSCustomObject]@{ Ok = $native.Success; Native = $native; IndexUrl = $indexUrl; TorchSpec = $torchSpec; TorchvisionSpec = $torchvisionSpec; TorchaudioSpec = $torchaudioSpec }
}
