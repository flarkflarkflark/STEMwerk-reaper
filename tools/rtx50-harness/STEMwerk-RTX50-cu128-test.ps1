#Requires -Version 5.1
<#
    STEMwerk-RTX50-cu128-test.ps1

    Third-generation #118 (RTX 50-series / NVIDIA Blackwell) test harness.

    PURPOSE
      Checks whether this machine's GPU is Blackwell-class (compute
      capability 12.x / sm_120). If it is NOT (the normal case for every
      machine except an actual RTX 50-series card), this script safely
      stops after reporting that fact - no packages are touched.

      If it IS Blackwell-class hardware (a real RTX 5070 / RTX 5060 Ti, or
      this machine running with -SimulateBlackwell for development testing
      only), it captures the exact current STEMwerk PyTorch/CUDA
      environment, installs the experimental cu128 runtime (torch 2.7.1 /
      torchvision 0.22.1 / torchaudio 2.7.1), verifies it, and - if
      verification fails for any reason - automatically rolls back to the
      exact original baseline.

    SAFETY
      Only ever touches %LOCALAPPDATA%\STEMwerk\.venv, and only after
      rigorously verifying that path's identity. No admin rights are
      used or required. See lib\VenvSafety.ps1.

    DEVELOPMENT-ONLY SIMULATION
      -SimulateBlackwell makes ONLY this harness's own hardware gating
      logic behave as though the GPU were an NVIDIA GeForce RTX 5070
      (compute capability 12.0 / sm_120). It requires the environment
      variable STEMWERK_RTX50_DEV_SIMULATION_ACK to also be set to the
      exact acknowledgement string below, so it can never engage by
      accident. It NEVER changes torch.version.cuda, installed package
      versions, torch.cuda.get_arch_list(), real CUDA execution, or the
      physical GPU identity reported anywhere in this script. All real
      CUDA execution still happens on the real physical GPU in this
      machine. A simulated run NEVER proves real Blackwell hardware
      compatibility - only a real RTX 50-series machine can prove that.

    EXIT CODES
      0  - PASS (includes the normal "non-Blackwell hardware, nothing to
           do" outcome)
      1  - FAIL (install/verification failed; rollback was attempted -
           check the report for ROLLBACK STATUS)
      2  - precheck could not run safely (venv identity check failed,
           etc.) - fail closed, nothing was touched
      3  - aborted by user at the confirmation prompt - nothing was
           touched
#>
param(
    [switch]$SimulateBlackwell,
    [switch]$Yes,
    [switch]$PrecheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'lib\Invoke-NativeProcess.ps1')
. (Join-Path $ScriptRoot 'lib\Reporting.ps1')
. (Join-Path $ScriptRoot 'lib\GpuDetect.ps1')
. (Join-Path $ScriptRoot 'lib\VenvSafety.ps1')
. (Join-Path $ScriptRoot 'lib\Rollback.ps1')

$ProbeScript = Join-Path $ScriptRoot 'lib\probe_env.py'
$SmokeScript = Join-Path $ScriptRoot 'lib\smoke_test.py'

$Cu128IndexUrl = 'https://download.pytorch.org/whl/cu128'
$ExperimentalTorch = 'torch==2.7.1'
$ExperimentalTorchvision = 'torchvision==0.22.1'
$ExperimentalTorchaudio = 'torchaudio==2.7.1'

function Main {
    $reportsDir = Join-Path $ScriptRoot 'reports'
    $reportInfo = New-HarnessReport -ReportsDirectory $reportsDir -RunName 'rtx50-cu128-test'
    $ReportPath = $reportInfo.ReportPath
    $StatePath = $reportInfo.StatePath

    Write-Host "STEMwerk #118 RTX 50-series test harness"
    Write-Host "Report:  $ReportPath"
    Write-Host ""

    try {
        Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'STARTED'

        # ---------------------------------------------------------------
        # 1. Windows / PowerShell environment check (PS 5.1-safe: no
        #    $IsWindows, no PS7-only syntax anywhere in this file).
        # ---------------------------------------------------------------
        $isWindows = ($env:OS -eq 'Windows_NT')
        Write-ReportKeyValues -ReportPath $ReportPath -Pairs ([ordered]@{
            'Detected Windows'   = $isWindows
            'PowerShell version' = $PSVersionTable.PSVersion.ToString()
            'PowerShell edition' = $PSVersionTable.PSEdition
            'Elevated (admin)'   = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        })

        if (-not $isWindows) {
            Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body 'FAIL: this harness must be run on Windows.'
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'PRECHECK_FAIL'
            Complete-HarnessState -StatePath $StatePath -FinalResult 'FAIL'
            return 2
        }

        # ---------------------------------------------------------------
        # 2. Verify STEMwerk venv identity BEFORE running anything else
        #    inside it. Fail closed on any doubt.
        # ---------------------------------------------------------------
        $venvPath = Get-ExpectedStemwerkVenvPath
        $identity = Test-StemwerkVenvIdentity -VenvPath $venvPath
        Write-ReportSection -ReportPath $ReportPath -Title 'STEMwerk venv identity check' -Body ("Target path: $venvPath`n`nOk: $($identity.Ok)`n`nReasons:`n- " + ($(if ($identity.Reasons.Count -gt 0) { $identity.Reasons -join "`n- " } else { '(all checks passed)' })))

        if (-not $identity.Ok) {
            Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body 'FAIL (closed): could not rigorously verify the STEMwerk venv identity. Refusing to proceed. Nothing was touched.'
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'PRECHECK_FAIL'
            Complete-HarnessState -StatePath $StatePath -FinalResult 'FAIL'
            return 2
        }
        $venvPython = $identity.PythonExe

        # ---------------------------------------------------------------
        # 3. Capture real baseline (never assumed).
        # ---------------------------------------------------------------
        $baseline = Get-PhysicalGpuInfo -PythonPath $venvPython -ProbeScriptPath $ProbeScript
        Write-ReportSection -ReportPath $ReportPath -Title 'Baseline: current STEMwerk PyTorch/CUDA environment' -Body ('```' + "`n" + $(if ($baseline.RawJson) { $baseline.RawJson } else { "probe failed: $($baseline.ParseError)" }) + "`n" + '```')
        Write-ReportNativeResult -ReportPath $ReportPath -Title 'Baseline probe: raw native process result (proves stderr warnings do not break this harness)' -NativeResult $baseline.Native

        $nvidiaSmi = Invoke-NativeProcess -FilePath 'nvidia-smi' -ArgumentList @('--query-gpu=name,driver_version,compute_cap,memory.total', '--format=csv')
        Write-ReportNativeResult -ReportPath $ReportPath -Title 'nvidia-smi (driver / physical GPU cross-check)' -NativeResult $nvidiaSmi

        if (-not $baseline.Ok) {
            Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body "FAIL: could not read baseline torch/CUDA state ($($baseline.ParseError)). Nothing was touched."
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'PRECHECK_FAIL'
            Complete-HarnessState -StatePath $StatePath -FinalResult 'FAIL'
            return 2
        }
        Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'BASELINE_CAPTURED'

        # ---------------------------------------------------------------
        # 4. Hardware gating: physical vs. simulated, kept strictly
        #    separate and both always shown.
        # ---------------------------------------------------------------
        $simConfig = Get-SimulationConfig -SimulateSwitch $SimulateBlackwell.IsPresent
        $target = Get-EffectiveTargetRequirement -SimulationConfig $simConfig -PhysicalInfo $baseline

        Write-ReportSection -ReportPath $ReportPath -Title 'Hardware identity (physical vs. simulated - never to be confused)' -Body (
            "SIMULATED_BLACKWELL=$(if ($simConfig.Active) { 'yes' } else { 'no' })`n" +
            "$(if ($simConfig.Active) { "SIMULATED_GPU=$($simConfig.SimulatedGpuName)`nSIMULATED_CAPABILITY=$($simConfig.SimulatedCapability)`n" } else { "(simulation reason: $($simConfig.Reason))`n" })" +
            "PHYSICAL_GPU=$($baseline.DeviceName)`n" +
            "PHYSICAL_CAPABILITY=$($baseline.ComputeCapability)`n"
        )

        $isBlackwellTarget = Test-IsBlackwellCapability -ComputeCapability $target.ComputeCapability

        if (-not $isBlackwellTarget) {
            Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body (
                "PASS (expected outcome): active target (physical GPU, no simulation) has compute capability " +
                "$($target.ComputeCapability), which is NOT Blackwell-class (>= 12.0 / sm_120). " +
                "This is not an RTX 50-series machine. No package mutation was performed."
            )
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'PRECHECK_PASS_NON_BLACKWELL'
            Complete-HarnessState -StatePath $StatePath -FinalResult 'PASS'
            return 0
        }

        # ---------------------------------------------------------------
        # 5. Target is Blackwell-class (real hardware, or simulated dev
        #    mode). Evaluate the CURRENT/baseline runtime against it -
        #    an honest arch_list check, no faking.
        # ---------------------------------------------------------------
        $baselineSupportsTarget = Test-ArchListSupportsCapability -ArchList $baseline.ArchList -ComputeCapability $target.ComputeCapability
        Write-ReportSection -ReportPath $ReportPath -Title 'Baseline runtime vs. Blackwell target requirement' -Body (
            "Target capability: $($target.ComputeCapability) (sm_$($target.ComputeCapability -replace '\.',''))`n" +
            "Baseline torch build's real arch_list: $($baseline.ArchList -join ', ')`n" +
            "Baseline build advertises support for target: $baselineSupportsTarget`n" +
            "$(if (-not $baselineSupportsTarget) { 'This matches the reported #118 failure mode: "CUDA error: no kernel image is available for execution on the device".' })"
        )

        if ($PrecheckOnly) {
            Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body 'PrecheckOnly requested: stopping before any mutation, as instructed.'
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'PRECHECK_PASS'
            Complete-HarnessState -StatePath $StatePath -FinalResult 'PASS'
            return 0
        }

        if (-not $Yes) {
            Write-Host ""
            Write-Host "This will install the EXPERIMENTAL torch 2.7.1 / torchvision 0.22.1 / torchaudio 2.7.1 (cu128)" -ForegroundColor Yellow
            Write-Host "build into: $venvPath" -ForegroundColor Yellow
            Write-Host "The current environment will be backed up and can be restored with ROLLBACK-STEMwerk-RTX50.cmd." -ForegroundColor Yellow
            $answer = Read-Host "Type YES to proceed"
            if ($answer -ne 'YES') {
                Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body 'ABORTED by user at confirmation prompt. Nothing was touched.'
                Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'ABORTED_BY_USER'
                Complete-HarnessState -StatePath $StatePath -FinalResult 'ABORTED'
                return 3
            }
        }

        # ---------------------------------------------------------------
        # 6. Capture baseline manifest (exact versions) before touching
        #    anything, so rollback restores precisely what was there.
        # ---------------------------------------------------------------
        $manifestPath = [System.IO.Path]::ChangeExtension($ReportPath, '.baseline.json')
        $manifestResult = New-BaselineManifest -PythonExe $venvPython -ManifestPath $manifestPath
        if (-not $manifestResult.Ok) {
            Write-ReportNativeResult -ReportPath $ReportPath -Title 'Baseline manifest capture (failed)' -NativeResult $manifestResult.Native
            Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body 'FAIL (closed): could not capture an exact baseline manifest. Refusing to mutate without a way to roll back. Nothing was touched.'
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'PRECHECK_FAIL'
            Complete-HarnessState -StatePath $StatePath -FinalResult 'FAIL'
            return 2
        }
        Write-ReportSection -ReportPath $ReportPath -Title 'Baseline manifest captured' -Body ('```' + "`n" + ($manifestResult.Manifest | ConvertTo-Json -Depth 6) + "`n" + '```' + "`nSaved to: $manifestPath")

        # ---------------------------------------------------------------
        # 7. Install experimental cu128 runtime.
        # ---------------------------------------------------------------
        Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'MUTATION_STARTED' -Note "installing $ExperimentalTorch $ExperimentalTorchvision $ExperimentalTorchaudio from $Cu128IndexUrl"
        $install = Invoke-TorchStackInstall -PythonExe $venvPython -TorchSpec $ExperimentalTorch -TorchvisionSpec $ExperimentalTorchvision -TorchaudioSpec $ExperimentalTorchaudio -IndexUrl $Cu128IndexUrl
        Write-ReportNativeResult -ReportPath $ReportPath -Title 'Experimental cu128 install' -NativeResult $install

        $rollbackRequired = $false
        $rollbackResult = $null

        if (-not $install.Success) {
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'INSTALL_FAILED'
            $rollbackRequired = $true
            Write-ReportSection -ReportPath $ReportPath -Title 'Result so far' -Body 'Experimental install FAILED. Attempting automatic rollback as a safety net (pip may have partially modified packages during dependency resolution).'
            $rollbackResult = Invoke-RollbackFlow -PythonExe $venvPython -ManifestPath $manifestPath -ProbeScriptPath $ProbeScript -SmokeScriptPath $SmokeScript -ReportPath $ReportPath -StatePath $StatePath
            Complete-HarnessState -StatePath $StatePath -FinalResult 'FAIL' -RollbackRequired $true -RollbackAttempted $true -RollbackVerified $rollbackResult.Verified
            Write-FinalBanner -ReportPath $ReportPath -Result 'FAIL' -RollbackResult $rollbackResult
            return 1
        }
        Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'INSTALL_COMPLETE'

        # ---------------------------------------------------------------
        # 8. Verify the experimental runtime.
        # ---------------------------------------------------------------
        $postInfo = Get-PhysicalGpuInfo -PythonPath $venvPython -ProbeScriptPath $ProbeScript
        Write-ReportSection -ReportPath $ReportPath -Title 'Post-install: experimental environment' -Body ('```' + "`n" + $(if ($postInfo.RawJson) { $postInfo.RawJson } else { "probe failed: $($postInfo.ParseError)" }) + "`n" + '```')
        Write-ReportNativeResult -ReportPath $ReportPath -Title 'Post-install probe: raw native process result' -NativeResult $postInfo.Native

        $expectedTorch = '2.7.1+cu128'
        $expectedTorchvision = '0.22.1+cu128'
        $expectedTorchaudio = '2.7.1+cu128'
        $versionsOk = ($postInfo.TorchVersion -eq $expectedTorch) -and ($postInfo.TorchvisionVersion -eq $expectedTorchvision) -and ($postInfo.TorchaudioVersion -eq $expectedTorchaudio) -and ($postInfo.TorchVersionCuda -eq '12.8')

        $advertisesTarget = Test-ArchListSupportsCapability -ArchList $postInfo.ArchList -ComputeCapability $target.ComputeCapability

        $smoke = Invoke-NativeProcess -FilePath $venvPython -ArgumentList @($SmokeScript)
        Write-ReportNativeResult -ReportPath $ReportPath -Title 'CUDA smoke tests + STEMwerk imports (experimental runtime)' -NativeResult $smoke

        Write-ReportKeyValues -ReportPath $ReportPath -Pairs ([ordered]@{
            'expected torch/vision/audio' = "$expectedTorch / $expectedTorchvision / $expectedTorchaudio"
            'actual torch/vision/audio'   = "$($postInfo.TorchVersion) / $($postInfo.TorchvisionVersion) / $($postInfo.TorchaudioVersion)"
            'torch.version.cuda'          = $postInfo.TorchVersionCuda
            'versions match expected'     = $versionsOk
            'arch_list'                   = ($postInfo.ArchList -join ', ')
            "advertises target capability $($target.ComputeCapability)" = $advertisesTarget
            'CUDA smoke test + imports success' = $smoke.Success
        })

        Write-ReportSection -ReportPath $ReportPath -Title 'IMPORTANT: what this verification does and does not prove' -Body (
            "These CUDA smoke tests ran on the PHYSICAL GPU actually installed in this machine " +
            "(PHYSICAL_GPU=$($baseline.DeviceName), PHYSICAL_CAPABILITY=$($baseline.ComputeCapability))" +
            "$(if ($simConfig.Active) { ", while hardware GATING used the SIMULATED target SIMULATED_GPU=$($simConfig.SimulatedGpuName) / SIMULATED_CAPABILITY=$($simConfig.SimulatedCapability)." } else { '.' })`n`n" +
            "A pass here proves the cu128 torch/torchvision/torchaudio runtime installs and runs correctly on THIS Windows/NVIDIA machine.`n`n" +
            "**It does NOT prove real sm_120 / Blackwell execution.** Real Blackwell validation still requires running this " +
            "(or the production runtime) on an actual RTX 5070 or RTX 5060 Ti."
        )

        $verificationOk = $versionsOk -and $smoke.Success

        if (-not $verificationOk) {
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'VERIFICATION_FAILED'
            $rollbackRequired = $true
            Write-ReportSection -ReportPath $ReportPath -Title 'Result so far' -Body 'Post-install verification FAILED. Invoking automatic rollback.'
            $rollbackResult = Invoke-RollbackFlow -PythonExe $venvPython -ManifestPath $manifestPath -ProbeScriptPath $ProbeScript -SmokeScriptPath $SmokeScript -ReportPath $ReportPath -StatePath $StatePath
            Complete-HarnessState -StatePath $StatePath -FinalResult 'FAIL' -RollbackRequired $true -RollbackAttempted $true -RollbackVerified $rollbackResult.Verified
            Write-FinalBanner -ReportPath $ReportPath -Result 'FAIL' -RollbackResult $rollbackResult
            return 1
        }

        Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'VERIFICATION_COMPLETE'
        Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body (
            "PASS: experimental cu128 runtime installed and verified on this machine." +
            "$(if ($simConfig.Active) { ' NOTE: this was a DEVELOPMENT SIMULATION run (SIMULATED_BLACKWELL=yes) - it does NOT constitute real Blackwell hardware validation.' } else { '' })`n`n" +
            "The experimental runtime is now ACTIVE in $venvPath. Use ROLLBACK-STEMwerk-RTX50.cmd to restore the original runtime at any time; the baseline manifest is saved at $manifestPath."
        )
        Complete-HarnessState -StatePath $StatePath -FinalResult 'PASS' -RollbackRequired $false -RollbackAttempted $false -RollbackVerified $null
        Write-FinalBanner -ReportPath $ReportPath -Result 'PASS' -RollbackResult $null
        return 0
    }
    catch {
        # Unexpected PowerShell-level exception anywhere above. Never let
        # this fall through silently - record it and mark state unknown.
        $errText = $_ | Out-String
        try {
            Write-ReportSection -ReportPath $ReportPath -Title 'UNEXPECTED EXCEPTION' -Body ('```' + "`n" + $errText + "`n" + '```' + "`n`n**Runtime state after an unexpected error cannot be assumed safe. Run ROLLBACK-STEMwerk-RTX50.cmd and verify manually.**")
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'UNEXPECTED_EXCEPTION'
            Complete-HarnessState -StatePath $StatePath -FinalResult 'UNKNOWN'
        }
        catch {
            # Even report writing failed; last-resort console output.
            Write-Host "FATAL: unexpected error AND failed to write to report: $errText" -ForegroundColor Red
        }
        Write-Host "UNEXPECTED ERROR - see report: $ReportPath" -ForegroundColor Red
        return 4
    }
}

function Write-FinalBanner {
    param(
        [string]$ReportPath,
        [string]$Result,
        $RollbackResult
    )
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host " RESULT: $Result" -ForegroundColor Cyan
    if ($RollbackResult) {
        $rbText = if ($RollbackResult.Verified) { 'VERIFIED' } elseif ($RollbackResult.Verified -eq $false) { 'FAILED - ROLLBACK STATUS UNKNOWN / MANUAL ATTENTION REQUIRED' } else { 'NOT ATTEMPTED' }
        Write-Host " Rollback: $rbText" -ForegroundColor Cyan
    }
    Write-Host " Full report: $ReportPath" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
}

exit (Main)
