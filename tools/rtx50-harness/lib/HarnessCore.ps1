# HarnessCore.ps1
#
# Shared orchestration for STEMwerk-RTX50-cu128-test.ps1 (v2). Both the
# public tester entry script and the dev-only simulated-Blackwell wrapper
# call Invoke-RTX50Harness - the ONLY difference between them is the
# $SimulatedTarget parameter, which the public entry script never sets
# (it has no CLI switch or environment variable that could ever produce a
# non-null value here). See dev\STEMwerk-RTX50-cu128-test-SIMULATED.ps1
# for the only code path that can ever pass a non-null $SimulatedTarget,
# and note it still requires its own double opt-in (switch + env var
# acknowledgement) before doing so.

Set-StrictMode -Version Latest

$PSScriptRootLib = $PSScriptRoot
. (Join-Path $PSScriptRootLib 'Invoke-NativeProcess.ps1')
. (Join-Path $PSScriptRootLib 'Reporting.ps1')
. (Join-Path $PSScriptRootLib 'GpuDetect.ps1')
. (Join-Path $PSScriptRootLib 'VenvSafety.ps1')
. (Join-Path $PSScriptRootLib 'RuntimeState.ps1')
. (Join-Path $PSScriptRootLib 'Rollback.ps1')

$Script:ProbeScript = Join-Path $PSScriptRootLib 'probe_env.py'
$Script:SmokeScript = Join-Path $PSScriptRootLib 'smoke_test.py'
$Script:Cu128IndexUrl = 'https://download.pytorch.org/whl/cu128'

function Write-TransactionSection {
    param([string]$ReportPath, $TxRead, [string]$CurrentCoherence)
    $body = "CURRENT_RUNTIME_STATE=$CurrentCoherence`n"
    $body += "TRANSACTION_RECORD_EXISTS=$($TxRead.Exists)`n"
    if ($TxRead.Exists) {
        $body += "TRANSACTION_RECORD_CORRUPT=$($TxRead.Corrupt)`n"
        if (-not $TxRead.Corrupt) {
            $body += "TRANSACTION_PHASE=$($TxRead.Data.phase)`n"
            $body += "TRANSACTION_ID=$($TxRead.Data.transaction_id)`n"
            $body += "TRANSACTION_STARTED_UTC=$($TxRead.Data.started_utc)`n"
        }
    }
    $body += "TRANSACTION_STATE_FILE=$(Get-TransactionStatePath)`n"
    Write-ReportSection -ReportPath $ReportPath -Title 'Transaction / runtime coherence state' -Body $body
}

function Invoke-RTX50Harness {
    param(
        [Parameter(Mandatory = $true)][string]$ReportsDir,
        [switch]$Yes,
        [switch]$PrecheckOnly,
        $SimulatedTarget = $null
    )

    $reportInfo = New-HarnessReport -ReportsDirectory $ReportsDir -RunName 'rtx50-cu128-test'
    $ReportPath = $reportInfo.ReportPath
    $StatePath = $reportInfo.StatePath

    Write-Host "STEMwerk #118 RTX 50-series test harness (v2)"
    Write-Host "Report:  $ReportPath"
    Write-Host ""

    try {
        Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'STARTED'

        # 1. Windows / PowerShell environment check.
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

        # 2. Verify STEMwerk venv identity before running anything else in it.
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

        # 3. Read durable transaction record + classify current runtime.
        $txRead = Read-TransactionState
        $currentTrio = Get-InstalledTorchTrio -PythonExe $venvPython
        $currentCoherence = Get-RuntimeCoherenceState -InstalledTrio $currentTrio
        Write-TransactionSection -ReportPath $ReportPath -TxRead $txRead -CurrentCoherence $currentCoherence
        Write-ReportKeyValues -ReportPath $ReportPath -Pairs ([ordered]@{
            'installed torch'       = $currentTrio.Packages['torch']
            'installed torchvision' = $currentTrio.Packages['torchvision']
            'installed torchaudio'  = $currentTrio.Packages['torchaudio']
        })

        # ---------------------------------------------------------------
        # RULE 1: current state is the known-coherent release baseline ->
        # always safe to (re)start a fresh transaction from it, regardless
        # of any stale/older transaction record.
        # ---------------------------------------------------------------
        if ($currentCoherence -eq 'RELEASE_BASELINE') {
            $baseline = ConvertTo-BaselineObject -InstalledTrio $currentTrio
            $target = Get-KnownTrio 'EXPERIMENTAL_CU128'
            $tx = New-TransactionRecord -Phase 'BASELINE_CAPTURED' -Baseline $baseline -Target $target -ReportPath $ReportPath
            Write-TransactionStateAtomic -Record $tx
            Write-ReportSection -ReportPath $ReportPath -Title 'Baseline' -Body ("Coherent RELEASE_BASELINE confirmed and captured as the trusted transaction baseline:`n" + '```' + "`n" + ($baseline | ConvertTo-Json -Depth 4) + "`n" + '```')
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'BASELINE_CAPTURED'
            return Invoke-NormalFlow -ReportPath $ReportPath -StatePath $StatePath -VenvPython $venvPython -Transaction $tx -Yes:$Yes -PrecheckOnly:$PrecheckOnly -SimulatedTarget $SimulatedTarget
        }

        # ---------------------------------------------------------------
        # RULE 2: an interrupted transaction is on record (baseline was
        # captured by an earlier run) and the environment is now mixed ->
        # recover using the REAL captured baseline. Never re-derive a
        # baseline from the current mixed state.
        # ---------------------------------------------------------------
        if ($txRead.Exists -and -not $txRead.Corrupt -and $txRead.Data.baseline -and $currentCoherence -eq 'MIXED_OR_UNKNOWN') {
            Write-ReportSection -ReportPath $ReportPath -Title 'INTERRUPTED TRANSACTION DETECTED' -Body (
                "A previous run captured a trusted baseline and reached phase '$($txRead.Data.phase)' " +
                "but did not complete (the process was likely closed or killed mid-mutation). The current " +
                "installed trio (torch $($currentTrio.Packages['torch']) / torchvision $($currentTrio.Packages['torchvision']) / " +
                "torchaudio $($currentTrio.Packages['torchaudio'])) is MIXED_OR_UNKNOWN and is being treated strictly as " +
                "an interrupted mutation - NOT as a new baseline. Recovering automatically using the baseline captured " +
                "at $($txRead.Data.baseline.captured_utc)."
            )
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'ROLLBACK_REQUIRED'
            $tx = Set-TransactionPhase -Record $txRead.Data -NewPhase 'ROLLBACK_REQUIRED' -Note 'interrupted transaction detected on a later run'
            $rb = Invoke-RollbackFlow -PythonExe $venvPython -Baseline $tx.baseline -ProbeScriptPath $Script:ProbeScript -SmokeScriptPath $Script:SmokeScript -ReportPath $ReportPath -StatePath $StatePath -Transaction $tx
            $finalResult = if ($rb.Verified) { 'PASS' } else { 'FAIL' }
            Complete-HarnessState -StatePath $StatePath -FinalResult $finalResult -RollbackRequired $true -RollbackAttempted $true -RollbackVerified $rb.Verified
            Write-FinalBanner -ReportPath $ReportPath -Result $finalResult -RollbackResult $rb
            return $(if ($rb.Verified) { 0 } else { 1 })
        }

        # ---------------------------------------------------------------
        # RULE 3: a transaction record exists and the current runtime is
        # already the exact coherent experimental target -> verify only,
        # never blindly reinstall, and never destroy the recorded baseline.
        # ---------------------------------------------------------------
        if ($txRead.Exists -and -not $txRead.Corrupt -and $currentCoherence -eq 'EXPERIMENTAL_CU128') {
            Write-ReportSection -ReportPath $ReportPath -Title 'Already at experimental target' -Body (
                "A trusted baseline is on record (captured $($txRead.Data.baseline.captured_utc)) and the environment is " +
                "already the exact coherent experimental cu128 trio. Skipping reinstall; running verification only."
            )
            return Invoke-VerifyOnlyFlow -ReportPath $ReportPath -StatePath $StatePath -VenvPython $venvPython -SimulatedTarget $SimulatedTarget -Baseline $txRead.Data.baseline
        }

        # ---------------------------------------------------------------
        # RULE 4: a transaction record exists but could not be parsed, and
        # the environment is mixed -> do NOT guess. Fail closed.
        # ---------------------------------------------------------------
        if ($txRead.Exists -and $txRead.Corrupt -and $currentCoherence -ne 'RELEASE_BASELINE') {
            Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body (
                "FAIL (closed): a durable transaction record exists at $($txRead.Path) but could not be parsed, and the " +
                "current runtime ($currentCoherence) is not the known release baseline. Refusing to guess a recovery " +
                "target from an unreadable record. **MANUAL ATTENTION REQUIRED.** Inspect and, if appropriate, remove " +
                "that file by hand only after confirming the real installed torch/torchvision/torchaudio versions."
            )
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'PRECHECK_FAIL'
            Complete-HarnessState -StatePath $StatePath -FinalResult 'FAIL'
            return 2
        }

        # ---------------------------------------------------------------
        # RULE 5: no transaction on record and the runtime is already the
        # coherent experimental target -> verify only, note there is no
        # captured pre-upgrade baseline available on this machine.
        # ---------------------------------------------------------------
        if (-not $txRead.Exists -and $currentCoherence -eq 'EXPERIMENTAL_CU128') {
            Write-ReportSection -ReportPath $ReportPath -Title 'Already at experimental target (no recorded baseline)' -Body (
                'The environment is already the exact coherent experimental cu128 trio, but this machine has no ' +
                'durable transaction record (no v2 run has ever captured a pre-upgrade baseline here - e.g. an older ' +
                'tester version was used previously). Skipping reinstall; running verification only. Rollback cannot ' +
                'be offered automatically until a trusted baseline exists.'
            )
            return Invoke-VerifyOnlyFlow -ReportPath $ReportPath -StatePath $StatePath -VenvPython $venvPython -SimulatedTarget $SimulatedTarget -Baseline $null
        }

        # ---------------------------------------------------------------
        # RULE 6: no trusted baseline exists (no transaction, or a corrupt
        # one) and the runtime is mixed. The ONLY remaining option is the
        # documented-release-fallback recovery path, gated by independent
        # identity corroboration, or FAIL CLOSED.
        # ---------------------------------------------------------------
        Write-ReportSection -ReportPath $ReportPath -Title 'MIXED_OR_UNKNOWN runtime with no trusted baseline' -Body (
            "No usable transaction record exists (Exists=$($txRead.Exists), Corrupt=$($txRead.Corrupt)) and the current " +
            "trio is MIXED_OR_UNKNOWN. Checking whether this still looks like the documented STEMwerk 2.3.1.1 release " +
            "environment closely enough to offer its known trio as an assumed recovery target."
        )
        $corroboration = Test-LooksLikeKnownStemwerkReleaseEnvironment -PythonExe $venvPython
        Write-ReportKeyValues -ReportPath $ReportPath -Pairs ([ordered]@{
            'looks like documented STEMwerk 2.3.1.1 environment' = $corroboration.Ok
            'reasons'                                              = $(if ($corroboration.Reasons.Count -gt 0) { $corroboration.Reasons -join '; ' } else { '(all corroborating checks passed)' })
        })

        if (-not $corroboration.Ok) {
            Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body (
                'FAIL (closed): no trusted baseline exists and this environment does not sufficiently corroborate as ' +
                'the documented STEMwerk 2.3.1.1 release. Refusing to invent a rollback target. **MANUAL ATTENTION ' +
                'REQUIRED** - please attach this report and a support bundle rather than re-running the tester.'
            )
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'PRECHECK_FAIL'
            Complete-HarnessState -StatePath $StatePath -FinalResult 'FAIL'
            return 2
        }

        Write-Host ""
        Write-Host "No trusted baseline is on record, but this still looks like a genuine STEMwerk 2.3.1.1 install with a" -ForegroundColor Yellow
        Write-Host "mixed/broken torch stack. The documented release trio (torch 2.4.1+cu121 / torchvision 0.19.1+cu121 /" -ForegroundColor Yellow
        Write-Host "torchaudio 2.4.1+cu121) can be restored as a best-effort recovery." -ForegroundColor Yellow
        $proceedRecovery = $Yes.IsPresent
        if (-not $proceedRecovery) {
            $answer = Read-Host "Type RESTORE-DOCUMENTED-BASELINE to proceed with this assumed recovery"
            $proceedRecovery = ($answer -eq 'RESTORE-DOCUMENTED-BASELINE')
        }
        if (-not $proceedRecovery) {
            Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body 'ABORTED by user at the assumed-recovery confirmation prompt. Nothing was touched.'
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'ABORTED_BY_USER'
            Complete-HarnessState -StatePath $StatePath -FinalResult 'ABORTED'
            return 3
        }

        $assumedBaseline = ConvertTo-BaselineObjectFromKnownTrio -KnownTrio (Get-KnownTrio 'RELEASE_BASELINE')
        $tx = New-TransactionRecord -Phase 'BASELINE_CAPTURED' -Baseline $assumedBaseline -Target (Get-KnownTrio 'EXPERIMENTAL_CU128') -ReportPath $ReportPath
        $tx = Set-TransactionPhase -Record $tx -NewPhase 'ROLLBACK_REQUIRED' -Note 'assumed documented-release recovery, no captured baseline was available'
        $rb = Invoke-RollbackFlow -PythonExe $venvPython -Baseline $assumedBaseline -ProbeScriptPath $Script:ProbeScript -SmokeScriptPath $Script:SmokeScript -ReportPath $ReportPath -StatePath $StatePath -Transaction $tx
        $finalResult = if ($rb.Verified) { 'PASS' } else { 'FAIL' }
        Complete-HarnessState -StatePath $StatePath -FinalResult $finalResult -RollbackRequired $true -RollbackAttempted $true -RollbackVerified $rb.Verified
        Write-FinalBanner -ReportPath $ReportPath -Result $finalResult -RollbackResult $rb
        return $(if ($rb.Verified) { 0 } else { 1 })
    }
    catch {
        $errText = $_ | Out-String
        try {
            Write-ReportSection -ReportPath $ReportPath -Title 'UNEXPECTED EXCEPTION' -Body ('```' + "`n" + $errText + "`n" + '```' + "`n`n**Runtime state after an unexpected error cannot be assumed safe. If a transaction record exists, it is preserved for recovery on the next run. Run ROLLBACK-STEMwerk-RTX50.cmd or re-run the tester and verify manually.**")
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'UNEXPECTED_EXCEPTION'
            Complete-HarnessState -StatePath $StatePath -FinalResult 'UNKNOWN'
        }
        catch {
            Write-Host "FATAL: unexpected error AND failed to write to report: $errText" -ForegroundColor Red
        }
        Write-Host "UNEXPECTED ERROR - see report: $ReportPath" -ForegroundColor Red
        return 4
    }
}

function Invoke-VerifyOnlyFlow {
    param(
        [string]$ReportPath, [string]$StatePath, [string]$VenvPython, $SimulatedTarget, $Baseline
    )
    $info = Get-PhysicalGpuInfo -PythonPath $VenvPython -ProbeScriptPath $Script:ProbeScript
    Write-ReportNativeResult -ReportPath $ReportPath -Title 'Verification: version/arch probe' -NativeResult $info.Native
    $smoke = Invoke-NativeProcess -FilePath $VenvPython -ArgumentList @($Script:SmokeScript)
    Write-ReportNativeResult -ReportPath $ReportPath -Title 'Verification: CUDA smoke test + STEMwerk imports' -NativeResult $smoke

    $target = if ($SimulatedTarget) { $SimulatedTarget } else { [PSCustomObject]@{ GpuName = $info.DeviceName; ComputeCapability = $info.ComputeCapability } }
    Write-BlackwellIdentitySection -ReportPath $ReportPath -PhysicalInfo $info -SimulatedTarget $SimulatedTarget

    $expected = Get-KnownTrio 'EXPERIMENTAL_CU128'
    $versionsOk = ($info.TorchVersion -eq "$($expected.torch)") -and ($info.TorchvisionVersion -eq "$($expected.torchvision)") -and ($info.TorchaudioVersion -eq "$($expected.torchaudio)")
    $verified = $versionsOk -and $info.CudaAvailable -and $smoke.Success
    Write-ReportKeyValues -ReportPath $ReportPath -Pairs ([ordered]@{
        'versions match experimental target' = $versionsOk
        'cuda available'                     = $info.CudaAvailable
        'smoke test + imports success'       = $smoke.Success
        'VERIFIED'                           = $verified
    })
    Write-RealBlackwellVerdict -ReportPath $ReportPath -PhysicalInfo $info -SimulatedTarget $SimulatedTarget -SmokeSuccess $smoke.Success

    $result = if ($verified) { 'PASS' } else { 'FAIL' }
    Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState $(if ($verified) { 'VERIFICATION_COMPLETE' } else { 'VERIFICATION_FAILED' })
    Complete-HarnessState -StatePath $StatePath -FinalResult $result
    Write-FinalBanner -ReportPath $ReportPath -Result $result -RollbackResult $null
    return $(if ($verified) { 0 } else { 1 })
}

function Write-BlackwellIdentitySection {
    param([string]$ReportPath, $PhysicalInfo, $SimulatedTarget)
    $body = "SIMULATED_BLACKWELL=$(if ($SimulatedTarget) { 'yes' } else { 'no' })`n"
    if ($SimulatedTarget) {
        $body += "SIMULATED_GPU=$($SimulatedTarget.GpuName)`nSIMULATED_CAPABILITY=$($SimulatedTarget.ComputeCapability)`n"
    }
    $body += "PHYSICAL_GPU=$($PhysicalInfo.DeviceName)`nPHYSICAL_CAPABILITY=$($PhysicalInfo.ComputeCapability)`n"
    Write-ReportSection -ReportPath $ReportPath -Title 'Hardware identity (physical vs. simulated - never to be confused)' -Body $body
}

function Write-RealBlackwellVerdict {
    <#
        .SYNOPSIS
        v2 fix: v1's report wording (written for simulated dev testing)
        could read as "this never proves real Blackwell" even when run on
        REAL RTX 50-series hardware with no simulation active. This makes
        the distinction explicit and correct in both directions.
    #>
    param([string]$ReportPath, $PhysicalInfo, $SimulatedTarget, [bool]$SmokeSuccess)

    if ($SimulatedTarget) {
        Write-ReportSection -ReportPath $ReportPath -Title 'IMPORTANT: simulation disclaimer' -Body (
            "REAL_BLACKWELL_VALIDATION=no`n`nSIMULATED_BLACKWELL=yes was active for this run. Hardware GATING used the " +
            "simulated target ($($SimulatedTarget.GpuName), capability $($SimulatedTarget.ComputeCapability)); all real " +
            "CUDA execution above still ran on the physical GPU ($($PhysicalInfo.DeviceName), capability " +
            "$($PhysicalInfo.ComputeCapability)). This is development-only testing and is NOT real Blackwell hardware validation."
        )
        return
    }

    $isBlackwellCapability = Test-IsBlackwellCapability -ComputeCapability $PhysicalInfo.ComputeCapability
    $archSupportsBlackwell = Test-ArchListSupportsCapability -ArchList $PhysicalInfo.ArchList -ComputeCapability '12.0'

    if ($isBlackwellCapability -and $archSupportsBlackwell -and $SmokeSuccess) {
        Write-ReportSection -ReportPath $ReportPath -Title 'REAL BLACKWELL VALIDATION' -Body (
            "REAL_BLACKWELL_VALIDATION=yes`n`n" +
            "No simulation was active. The PHYSICAL GPU in this machine reports RTX 50-series-class compute capability " +
            "($($PhysicalInfo.ComputeCapability)), the installed torch build's real arch_list includes sm_120 " +
            "($($PhysicalInfo.ArchList -join ', ')), and the real CUDA smoke test operations above (tensor allocation, " +
            "elementwise op, matmul, reduction, synchronize) succeeded on this device: $($PhysicalInfo.DeviceName).`n`n" +
            "This IS real evidence of sm_120/Blackwell CUDA execution on physical hardware. It does **not** by itself " +
            "constitute full STEMwerk application validation - a real REAPER 'Normal Stems' separation on this machine " +
            "is a separate, additional check (see the harness README / separate real-separation evidence, where run)."
        )
    }
    else {
        Write-ReportSection -ReportPath $ReportPath -Title 'Blackwell validation status' -Body (
            "REAL_BLACKWELL_VALIDATION=no`n`nNo simulation was active, but this machine's physical GPU " +
            "($($PhysicalInfo.DeviceName), capability $($PhysicalInfo.ComputeCapability)) is not RTX 50-series/Blackwell-" +
            "class hardware, so this run cannot and does not constitute Blackwell validation."
        )
    }
}

function Write-FinalBanner {
    param([string]$ReportPath, [string]$Result, $RollbackResult)
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

function Invoke-NormalFlow {
    <#
        .SYNOPSIS
        The "everything is coherent, decide whether to test Blackwell and
        possibly install the experimental runtime" flow - what v1's main
        script body did, now transaction-safe throughout.
    #>
    param(
        [string]$ReportPath, [string]$StatePath, [string]$VenvPython, $Transaction,
        [switch]$Yes, [switch]$PrecheckOnly, $SimulatedTarget
    )

    $baseline = Get-PhysicalGpuInfo -PythonPath $VenvPython -ProbeScriptPath $Script:ProbeScript
    Write-ReportSection -ReportPath $ReportPath -Title 'Baseline: current STEMwerk PyTorch/CUDA environment' -Body ('```' + "`n" + $(if ($baseline.RawJson) { $baseline.RawJson } else { "probe failed: $($baseline.ParseError)" }) + "`n" + '```')
    Write-ReportNativeResult -ReportPath $ReportPath -Title 'Baseline probe: raw native process result' -NativeResult $baseline.Native
    $nvidiaSmi = Invoke-NativeProcess -FilePath 'nvidia-smi' -ArgumentList @('--query-gpu=name,driver_version,compute_cap,memory.total', '--format=csv')
    Write-ReportNativeResult -ReportPath $ReportPath -Title 'nvidia-smi (driver / physical GPU cross-check)' -NativeResult $nvidiaSmi

    if (-not $baseline.Ok) {
        Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body "FAIL: could not read baseline torch/CUDA state ($($baseline.ParseError)). Nothing was touched."
        Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'PRECHECK_FAIL'
        Complete-HarnessState -StatePath $StatePath -FinalResult 'FAIL'
        return 2
    }

    $simConfig = $null
    if ($SimulatedTarget) { $simConfig = [PSCustomObject]@{ Active = $true } }
    Write-BlackwellIdentitySection -ReportPath $ReportPath -PhysicalInfo $baseline -SimulatedTarget $SimulatedTarget

    $target = if ($SimulatedTarget) { $SimulatedTarget } else { [PSCustomObject]@{ GpuName = $baseline.DeviceName; ComputeCapability = $baseline.ComputeCapability } }
    $isBlackwellTarget = Test-IsBlackwellCapability -ComputeCapability $target.ComputeCapability

    if (-not $isBlackwellTarget) {
        Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body (
            "PASS (expected outcome): active target (physical GPU, no simulation) has compute capability " +
            "$($target.ComputeCapability), which is NOT Blackwell-class (>= 12.0 / sm_120). This is not an RTX 50-series " +
            "machine. No package mutation was performed."
        )
        Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'PRECHECK_PASS_NON_BLACKWELL'
        Complete-HarnessState -StatePath $StatePath -FinalResult 'PASS'
        return 0
    }

    $baselineSupportsTarget = Test-ArchListSupportsCapability -ArchList $baseline.ArchList -ComputeCapability $target.ComputeCapability
    Write-ReportSection -ReportPath $ReportPath -Title 'Baseline runtime vs. Blackwell target requirement' -Body (
        "Target capability: $($target.ComputeCapability)`nBaseline torch build's real arch_list: $($baseline.ArchList -join ', ')`n" +
        "Baseline build advertises support for target: $baselineSupportsTarget"
    )

    if ($PrecheckOnly) {
        Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body 'PrecheckOnly requested: stopping before any mutation, as instructed.'
        Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'PRECHECK_PASS'
        Complete-HarnessState -StatePath $StatePath -FinalResult 'PASS'
        return 0
    }

    if (-not $Yes) {
        Write-Host ""
        Write-Host "This will install the EXPERIMENTAL torch 2.7.1 / torchvision 0.22.1 / torchaudio 2.7.1 (cu128) build" -ForegroundColor Yellow
        Write-Host "into: $(Get-ExpectedStemwerkVenvPath)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Do not close this window while the runtime update is in progress. If it IS interrupted (window" -ForegroundColor Yellow
        Write-Host "closed, power loss, forced kill), simply run this tester again: it will detect the interrupted" -ForegroundColor Yellow
        Write-Host "transaction using the baseline already saved to disk and recover safely - it will NOT treat the" -ForegroundColor Yellow
        Write-Host "broken in-between state as a new baseline." -ForegroundColor Yellow
        $answer = Read-Host "Type YES to proceed"
        if ($answer -ne 'YES') {
            Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body 'ABORTED by user at confirmation prompt. Nothing was touched.'
            Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'ABORTED_BY_USER'
            Complete-HarnessState -StatePath $StatePath -FinalResult 'ABORTED'
            return 3
        }
    }

    $Transaction = Set-TransactionPhase -Record $Transaction -NewPhase 'MUTATION_STARTED' -Note 'about to install experimental cu128 trio'
    Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'MUTATION_STARTED'

    Write-Host ""
    Write-Host "Installing PyTorch CUDA 12.8 packages - this can take several minutes depending on your internet connection..." -ForegroundColor Cyan
    $expected = Get-KnownTrio 'EXPERIMENTAL_CU128'

    $Transaction = Set-TransactionPhase -Record $Transaction -NewPhase 'TORCH_INSTALL_IN_PROGRESS'
    $install = $null
    try {
        $install = Invoke-TorchStackInstall -PythonExe $VenvPython -TorchSpec "torch==$($expected.torch)" -TorchvisionSpec "torchvision==$($expected.torchvision)" -TorchaudioSpec "torchaudio==$($expected.torchaudio)" -IndexUrl $Script:Cu128IndexUrl -TimeoutSeconds 1800 -HeartbeatSeconds 20 -HeartbeatAction { param($s) Write-Host "  ... still installing ($s s elapsed) - this is normal for a multi-GB download, please wait" }
    }
    finally {
        # Ctrl+C during the pip call unwinds through here (Windows
        # PowerShell console Ctrl+C stops the pipeline, which runs
        # finally blocks). A hard kill (window close, taskkill) does NOT
        # run this - the durable transaction record written above
        # (TORCH_INSTALL_IN_PROGRESS) is what protects against that case:
        # the next run will detect it as an interrupted transaction.
        if (-not $install) {
            $Transaction = Set-TransactionPhase -Record $Transaction -NewPhase 'INTERRUPTED_UNKNOWN' -Note 'pip install call did not return normally (likely Ctrl+C) - recoverable on next run via saved baseline'
        }
    }

    Write-ReportNativeResult -ReportPath $ReportPath -Title 'Experimental cu128 install' -NativeResult $install

    if (-not $install.Success) {
        Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'INSTALL_FAILED'
        $Transaction = Set-TransactionPhase -Record $Transaction -NewPhase 'ROLLBACK_REQUIRED' -Note 'install failed'
        Write-ReportSection -ReportPath $ReportPath -Title 'Result so far' -Body 'Experimental install FAILED. Attempting automatic rollback to the saved baseline.'
        $rollbackResult = Invoke-RollbackFlow -PythonExe $VenvPython -Baseline $Transaction.baseline -ProbeScriptPath $Script:ProbeScript -SmokeScriptPath $Script:SmokeScript -ReportPath $ReportPath -StatePath $StatePath -Transaction $Transaction
        $finalResult = if ($rollbackResult.Verified) { 'FAIL' } else { 'FAIL' }
        Complete-HarnessState -StatePath $StatePath -FinalResult $finalResult -RollbackRequired $true -RollbackAttempted $true -RollbackVerified $rollbackResult.Verified
        Write-FinalBanner -ReportPath $ReportPath -Result $finalResult -RollbackResult $rollbackResult
        return 1
    }

    # Inspect exact trio immediately - pip returning success does not by
    # itself mean the runtime is coherent.
    $postTrio = Get-InstalledTorchTrio -PythonExe $VenvPython
    $postCoherence = Get-RuntimeCoherenceState -InstalledTrio $postTrio
    if ($postCoherence -ne 'EXPERIMENTAL_CU128') {
        Write-ReportSection -ReportPath $ReportPath -Title 'Result so far' -Body (
            "pip reported success but the resulting trio is NOT the exact coherent experimental target " +
            "(classified as ${postCoherence}: torch=$($postTrio.Packages['torch']) torchvision=$($postTrio.Packages['torchvision']) " +
            "torchaudio=$($postTrio.Packages['torchaudio'])). Treating this as a failed install and rolling back."
        )
        $Transaction = Set-TransactionPhase -Record $Transaction -NewPhase 'ROLLBACK_REQUIRED' -Note 'post-install trio not coherent'
        $rollbackResult = Invoke-RollbackFlow -PythonExe $VenvPython -Baseline $Transaction.baseline -ProbeScriptPath $Script:ProbeScript -SmokeScriptPath $Script:SmokeScript -ReportPath $ReportPath -StatePath $StatePath -Transaction $Transaction
        Complete-HarnessState -StatePath $StatePath -FinalResult 'FAIL' -RollbackRequired $true -RollbackAttempted $true -RollbackVerified $rollbackResult.Verified
        Write-FinalBanner -ReportPath $ReportPath -Result 'FAIL' -RollbackResult $rollbackResult
        return 1
    }
    $Transaction = Set-TransactionPhase -Record $Transaction -NewPhase 'EXPERIMENTAL_INSTALLED' -Note 'exact coherent trio confirmed'
    Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'INSTALL_COMPLETE'

    $postInfo = Get-PhysicalGpuInfo -PythonPath $VenvPython -ProbeScriptPath $Script:ProbeScript
    Write-ReportSection -ReportPath $ReportPath -Title 'Post-install: experimental environment' -Body ('```' + "`n" + $(if ($postInfo.RawJson) { $postInfo.RawJson } else { "probe failed: $($postInfo.ParseError)" }) + "`n" + '```')
    Write-ReportNativeResult -ReportPath $ReportPath -Title 'Post-install probe: raw native process result' -NativeResult $postInfo.Native

    $advertisesTarget = Test-ArchListSupportsCapability -ArchList $postInfo.ArchList -ComputeCapability $target.ComputeCapability
    $smoke = Invoke-NativeProcess -FilePath $VenvPython -ArgumentList @($Script:SmokeScript)
    Write-ReportNativeResult -ReportPath $ReportPath -Title 'CUDA smoke tests + STEMwerk imports (experimental runtime)' -NativeResult $smoke

    Write-ReportKeyValues -ReportPath $ReportPath -Pairs ([ordered]@{
        'torch/vision/audio'                                          = "$($postInfo.TorchVersion) / $($postInfo.TorchvisionVersion) / $($postInfo.TorchaudioVersion)"
        'torch.version.cuda'                                          = $postInfo.TorchVersionCuda
        'arch_list'                                                   = ($postInfo.ArchList -join ', ')
        "advertises target capability $($target.ComputeCapability)" = $advertisesTarget
        'CUDA smoke test + imports success'                           = $smoke.Success
    })
    Write-RealBlackwellVerdict -ReportPath $ReportPath -PhysicalInfo $postInfo -SimulatedTarget $SimulatedTarget -SmokeSuccess $smoke.Success

    $verificationOk = $smoke.Success -and $postInfo.CudaAvailable

    if (-not $verificationOk) {
        Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'VERIFICATION_FAILED'
        $Transaction = Set-TransactionPhase -Record $Transaction -NewPhase 'ROLLBACK_REQUIRED' -Note 'post-install verification failed'
        Write-ReportSection -ReportPath $ReportPath -Title 'Result so far' -Body 'Post-install verification FAILED. Invoking automatic rollback.'
        $rollbackResult = Invoke-RollbackFlow -PythonExe $VenvPython -Baseline $Transaction.baseline -ProbeScriptPath $Script:ProbeScript -SmokeScriptPath $Script:SmokeScript -ReportPath $ReportPath -StatePath $StatePath -Transaction $Transaction
        Complete-HarnessState -StatePath $StatePath -FinalResult 'FAIL' -RollbackRequired $true -RollbackAttempted $true -RollbackVerified $rollbackResult.Verified
        Write-FinalBanner -ReportPath $ReportPath -Result 'FAIL' -RollbackResult $rollbackResult
        return 1
    }

    $Transaction = Set-TransactionPhase -Record $Transaction -NewPhase 'EXPERIMENTAL_VERIFIED' -Note 'verification passed; baseline preserved for future rollback'
    Set-HarnessState -StatePath $StatePath -ReportPath $ReportPath -NewState 'VERIFICATION_COMPLETE'
    Write-ReportSection -ReportPath $ReportPath -Title 'Result' -Body (
        "PASS: experimental cu128 runtime installed and verified on this machine.`n`nThe experimental runtime is now " +
        "ACTIVE in $(Get-ExpectedStemwerkVenvPath). Use ROLLBACK-STEMwerk-RTX50.cmd to restore the original runtime at " +
        "any time - the trusted baseline remains saved at $(Get-TransactionStatePath)."
    )
    Complete-HarnessState -StatePath $StatePath -FinalResult 'PASS'
    Write-FinalBanner -ReportPath $ReportPath -Result 'PASS' -RollbackResult $null
    return 0
}
