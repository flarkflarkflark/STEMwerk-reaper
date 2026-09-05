#Requires -Version 5.1
<#
    STEMwerk-RTX50-cu128-test.ps1  (v2)

    Third-generation #118 (RTX 50-series / NVIDIA Blackwell) test harness,
    hardened for transaction-safe interruption/recovery after a real RTX
    5070 tester's first run appeared to hang during a long pip install and
    was killed manually, leaving a mixed/incoherent torch stack that a
    naive rollback would then have "learned" as if it were the original
    baseline. See lib\RuntimeState.ps1 for the full design notes.

    PUBLIC TESTER NOTE: this script has NO development-simulation switch
    and reads no environment variable that could activate one - hardware
    gating here always reflects the REAL physical GPU in this machine.
    (Development-only simulated-Blackwell testing lives entirely in
    dev\STEMwerk-RTX50-cu128-test-SIMULATED.ps1, which is excluded from
    the tester ZIP.)

    PURPOSE
      Checks whether this machine's GPU is Blackwell-class (compute
      capability 12.x / sm_120). If it is NOT, this script safely stops
      after reporting that fact - no packages are touched.

      If it IS Blackwell-class hardware, after your confirmation it
      captures the exact current STEMwerk PyTorch/CUDA environment,
      installs the experimental cu128 runtime (torch 2.7.1 / torchvision
      0.22.1 / torchaudio 2.7.1), verifies it, and - if verification
      fails, or if a PREVIOUS run was interrupted mid-install - safely
      recovers using the durable baseline recorded before any mutation
      began.

    SAFETY
      Only ever touches %LOCALAPPDATA%\STEMwerk\.venv, and only after
      rigorously verifying that path's identity. No admin rights are
      used or required.

    EXIT CODES
      0  - PASS
      1  - FAIL (install/verification failed or an interrupted transaction
           was detected; a recovery/rollback was attempted - check the
           report for its result)
      2  - could not run safely (venv identity check failed, no trusted
           recovery target could be established, etc.) - fail closed,
           nothing was touched
      3  - aborted by user at a confirmation prompt - nothing was touched
      4  - unexpected internal error - see the report
#>
param(
    [switch]$Yes,
    [switch]$PrecheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptRoot 'lib\HarnessCore.ps1')

exit (Invoke-RTX50Harness -ReportsDir (Join-Path $ScriptRoot 'reports') -Yes:$Yes -PrecheckOnly:$PrecheckOnly)
