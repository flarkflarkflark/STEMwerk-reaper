# RuntimeState.ps1
#
# Transaction-safety core for #118 harness v2.
#
# WHY THIS EXISTS (v1 flaw, found via a real RTX 5070 tester's reports):
#   v1 captured its "baseline to roll back to" fresh on every run, from
#   whatever pip currently reported, and stored it only inside that run's
#   own reports\ folder. When a first run appeared to hang (a long pip
#   install, not actually stuck) and was killed after ~10 minutes, the
#   venv was left in a MIXED state (torch upgraded, torchvision/torchaudio
#   not yet). The next run then captured *that mixed state* as its new
#   "baseline" - so a later rollback would have restored a broken,
#   incoherent runtime instead of the real original STEMwerk release.
#
# THE FIX:
#   - A durable transaction record lives OUTSIDE the venv, at a fixed
#     per-machine path (Get-TransactionStatePath), independent of which
#     folder any particular tester ZIP was extracted to or which run's
#     reports\ folder exists.
#   - A baseline is captured into that record ONLY when the environment is
#     currently in the known-coherent RELEASE_BASELINE state, and once
#     captured it is NEVER overwritten by a later run - not even if that
#     later run also starts from a mixed/interrupted state. It is only
#     cleared once a rollback to it has been independently verified.
#   - Every run, before doing anything else, reads this record and
#     classifies the CURRENT installed trio as RELEASE_BASELINE,
#     EXPERIMENTAL_CU128, or MIXED_OR_UNKNOWN, and only then decides what
#     is safe to do.

Set-StrictMode -Version Latest

$Script:KnownTrios = @{
    RELEASE_BASELINE   = [ordered]@{ torch = '2.4.1+cu121'; torchvision = '0.19.1+cu121'; torchaudio = '2.4.1+cu121'; cuda_tag = 'cu121' }
    EXPERIMENTAL_CU128 = [ordered]@{ torch = '2.7.1+cu128'; torchvision = '0.22.1+cu128'; torchaudio = '2.7.1+cu128'; cuda_tag = 'cu128' }
}

function Get-KnownTrio {
    param([Parameter(Mandatory = $true)][ValidateSet('RELEASE_BASELINE', 'EXPERIMENTAL_CU128')][string]$Name)
    return $Script:KnownTrios[$Name]
}

function Get-TransactionStatePath {
    $root = [System.Environment]::GetFolderPath('LocalApplicationData')
    return (Join-Path $root 'STEMwerk\rtx50-test-state\transaction.json')
}

function Get-InstalledTorchTrio {
    <#
        .SYNOPSIS
        Reads the ACTUAL currently-installed torch/torchvision/torchaudio
        versions from the given venv via its own pip. Never assumes.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PythonExe
    )

    $native = Invoke-NativeProcess -FilePath $PythonExe -ArgumentList @('-m', 'pip', 'list', '--format=freeze')
    $packages = [ordered]@{}
    if ($native.Success) {
        foreach ($line in ($native.StdOut -split "`r?`n")) {
            if ($line -match '^(torch|torchvision|torchaudio)==(.+)$') {
                $packages[$Matches[1]] = $Matches[2]
            }
        }
    }

    $cudaTag = $null
    if ($packages.Contains('torch') -and $packages['torch'] -match '\+cu(\d+)$') {
        $cudaTag = "cu$($Matches[1])"
    }

    return [PSCustomObject]@{
        Ok       = $native.Success
        Packages = $packages
        CudaTag  = $cudaTag
        Native   = $native
    }
}

function Get-RuntimeCoherenceState {
    <#
        .SYNOPSIS
        Classifies an installed trio (as returned by Get-InstalledTorchTrio)
        as exactly RELEASE_BASELINE, exactly EXPERIMENTAL_CU128, or
        MIXED_OR_UNKNOWN (anything else at all - partial, mismatched,
        unrecognized versions, or a failed read).
    #>
    param(
        [Parameter(Mandatory = $true)]$InstalledTrio
    )

    if (-not $InstalledTrio.Ok) { return 'MIXED_OR_UNKNOWN' }

    foreach ($name in @('RELEASE_BASELINE', 'EXPERIMENTAL_CU128')) {
        $known = $Script:KnownTrios[$name]
        $isMatch = $true
        foreach ($pkg in @('torch', 'torchvision', 'torchaudio')) {
            if (-not $InstalledTrio.Packages.Contains($pkg)) { $isMatch = $false; break }
            if ($InstalledTrio.Packages[$pkg] -ne $known[$pkg]) { $isMatch = $false; break }
        }
        # Extra packages beyond the trio don't disqualify a match, but a
        # missing or mismatched trio member does.
        if ($isMatch -and $InstalledTrio.Packages.Count -lt 3) { $isMatch = $false }
        if ($isMatch) { return $name }
    }

    return 'MIXED_OR_UNKNOWN'
}

function Read-TransactionState {
    <#
        .SYNOPSIS
        Reads the durable transaction record. Returns an object with
        Exists / Corrupt / Data so callers can tell "no transaction ever
        started" apart from "a transaction record exists but could not be
        parsed" - the two must NOT be treated the same way, because the
        latter might be hiding a real trusted baseline.
    #>
    $path = Get-TransactionStatePath
    if (-not (Test-Path -LiteralPath $path)) {
        return [PSCustomObject]@{ Exists = $false; Corrupt = $false; Data = $null; Path = $path }
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        if (-not $data.PSObject.Properties.Name -contains 'schema') {
            return [PSCustomObject]@{ Exists = $true; Corrupt = $true; Data = $null; Path = $path }
        }
        return [PSCustomObject]@{ Exists = $true; Corrupt = $false; Data = $data; Path = $path }
    }
    catch {
        return [PSCustomObject]@{ Exists = $true; Corrupt = $true; Data = $null; Path = $path }
    }
}

function Write-TransactionStateAtomic {
    <#
        .SYNOPSIS
        Writes the transaction record via write-to-temp + rename, which is
        atomic on the same NTFS volume - a reader never observes a
        half-written file.
    #>
    param(
        [Parameter(Mandatory = $true)]$Record
    )
    $path = Get-TransactionStatePath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tmpPath = "$path.tmp-$PID-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $Record | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tmpPath -Encoding UTF8
    Move-Item -LiteralPath $tmpPath -Destination $path -Force
}

function New-TransactionRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Phase,
        $Baseline = $null,
        $Target = $null,
        [string]$ReportPath = ''
    )
    $now = (Get-Date).ToUniversalTime().ToString('o')
    return [PSCustomObject]@{
        schema         = 2
        transaction_id = [guid]::NewGuid().ToString()
        phase          = $Phase
        phase_history  = @([PSCustomObject]@{ phase = $Phase; utc = $now; note = 'transaction created' })
        baseline       = $Baseline
        target         = $Target
        started_utc    = $now
        updated_utc    = $now
        pid            = $PID
        host           = $env:COMPUTERNAME
        report_path    = $ReportPath
    }
}

function Set-TransactionPhase {
    <#
        .SYNOPSIS
        Advances a transaction record to a new phase, appends history, and
        persists it atomically. Returns the updated record.
    #>
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$NewPhase,
        [string]$Note = ''
    )
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $Record.phase = $NewPhase
    $Record.updated_utc = $now
    $newHistory = @()
    if ($Record.phase_history) { $newHistory += $Record.phase_history }
    $newHistory += [PSCustomObject]@{ phase = $NewPhase; utc = $now; note = $Note }
    $Record.phase_history = $newHistory
    Write-TransactionStateAtomic -Record $Record
    return $Record
}

function Clear-TransactionState {
    <#
        .SYNOPSIS
        Removes the durable transaction record. Only call this once a
        rollback to the recorded baseline has been independently verified
        - this marks the experiment as fully closed out.
    #>
    $path = Get-TransactionStatePath
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
}

function Test-LooksLikeKnownStemwerkReleaseEnvironment {
    <#
        .SYNOPSIS
        Corroborating identity evidence used ONLY to decide whether it is
        safe to offer the documented STEMwerk 2.3.1.1 release trio as an
        assumed recovery target when NO trusted captured baseline exists
        (see the #118 v2 design notes at the top of this file, and spec
        section 4: "acceptable to recognize the known STEMwerk 2.3.1.1
        release baseline as a recovery target only if all surrounding
        runtime identity checks prove this is the expected STEMwerk
        2.3.1.1 Windows CUDA environment").

        This deliberately does NOT look at torch/torchvision/torchaudio
        versions - those are exactly what might be broken/mixed in the
        scenario this function exists for. It checks independent identity
        signals instead: Python version, and the audio-separator pin that
        has shipped unchanged across the 2.3.1.x release line.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$PythonExe
    )

    $reasons = New-Object System.Collections.Generic.List[string]
    $ok = $true

    $verResult = Invoke-NativeProcess -FilePath $PythonExe -ArgumentList @('--version')
    $pyVersionText = "$($verResult.StdOut)$($verResult.StdErr)".Trim()
    if (-not $verResult.Success -or $pyVersionText -notmatch 'Python 3\.11\.') {
        $ok = $false
        $reasons.Add("python version does not look like the documented 3.11.x runtime (got: '$pyVersionText')")
    }

    $pipList = Invoke-NativeProcess -FilePath $PythonExe -ArgumentList @('-m', 'pip', 'list', '--format=freeze')
    if (-not $pipList.Success) {
        $ok = $false
        $reasons.Add('unable to run pip list to check audio-separator pin')
    }
    else {
        # Split into lines first (as Get-InstalledTorchTrio does) rather
        # than matching ^...$ against the whole raw string - pip's output
        # uses \r\n, and .NET multiline "$" matches before \n, leaving a
        # trailing \r inside the match and silently failing an exact-line
        # comparison. Found by this harness's own Scenario C regression
        # test, which left a real venv in a mixed state until fixed.
        $hasAudioSeparatorPin = $false
        foreach ($line in ($pipList.StdOut -split "`r?`n")) {
            if ($line -eq 'audio-separator==0.24.4') { $hasAudioSeparatorPin = $true; break }
        }
        if (-not $hasAudioSeparatorPin) {
            $ok = $false
            $reasons.Add('audio-separator==0.24.4 (the documented 2.3.1.1 release pin) was not found')
        }
    }

    return [PSCustomObject]@{ Ok = $ok; Reasons = $reasons.ToArray() }
}

function ConvertTo-BaselineObject {
    <#
        .SYNOPSIS
        Normalizes an installed trio (from Get-InstalledTorchTrio) into the
        plain {packages;cuda_tag} shape used both by the transaction record
        and by VenvSafety's Invoke-BaselineRestore.
    #>
    param([Parameter(Mandatory = $true)]$InstalledTrio, [switch]$Assumed)
    return [PSCustomObject]@{
        captured_utc = (Get-Date).ToUniversalTime().ToString('o')
        packages     = $InstalledTrio.Packages
        cuda_tag     = $InstalledTrio.CudaTag
        assumed      = [bool]$Assumed
    }
}

function ConvertTo-BaselineObjectFromKnownTrio {
    <#
        .SYNOPSIS
        Builds a baseline object directly from a known-good trio
        definition (Get-KnownTrio), for the documented-release-fallback
        recovery path where nothing was actually captured from a live
        environment. Always marked assumed=$true.
    #>
    param([Parameter(Mandatory = $true)]$KnownTrio)
    $packages = [ordered]@{ torch = $KnownTrio.torch; torchvision = $KnownTrio.torchvision; torchaudio = $KnownTrio.torchaudio }
    return [PSCustomObject]@{
        captured_utc = (Get-Date).ToUniversalTime().ToString('o')
        packages     = $packages
        cuda_tag     = $KnownTrio.cuda_tag
        assumed      = $true
    }
}
