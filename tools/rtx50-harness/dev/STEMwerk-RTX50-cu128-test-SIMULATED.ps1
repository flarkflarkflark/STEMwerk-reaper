#Requires -Version 5.1
<#
    STEMwerk-RTX50-cu128-test-SIMULATED.ps1  (DEV-ONLY, excluded from tester ZIP)

    v2 change from v1: simulation support has been REMOVED ENTIRELY from
    the public STEMwerk-RTX50-cu128-test.ps1 / lib\HarnessCore.ps1 call
    site used by ordinary testers - there is no switch or environment
    variable in the public path that can ever activate it. This script is
    the ONLY place a simulated Blackwell target can be constructed, and it
    still requires its own double opt-in (switch + explicit environment
    acknowledgement) before doing so, so it can never engage by accident
    even here.

    Makes ONLY this harness's own hardware-gating decision behave as if
    the GPU were an NVIDIA GeForce RTX 5070 (compute capability 12.0 /
    sm_120). Never changes torch.version.cuda, installed package versions,
    torch.cuda.get_arch_list(), real CUDA execution, or the physical GPU
    identity reported anywhere in the output - all real CUDA execution
    still happens on the real physical GPU. A run using this script is
    NEVER real Blackwell hardware validation; the report says so
    explicitly (REAL_BLACKWELL_VALIDATION=no whenever this is used).
#>
param(
    [switch]$SimulateBlackwell,
    [switch]$Yes,
    [switch]$PrecheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$HarnessRoot = Split-Path -Parent $ScriptRoot
. (Join-Path $HarnessRoot 'lib\HarnessCore.ps1')

$ackVar = 'STEMWERK_RTX50_DEV_SIMULATION_ACK'
$requiredAckValue = 'I-UNDERSTAND-THIS-IS-NOT-REAL-BLACKWELL-HARDWARE'
$ackValue = [System.Environment]::GetEnvironmentVariable($ackVar)

if (-not $SimulateBlackwell) {
    Write-Host "Pass -SimulateBlackwell to use this dev-only script; without it, it behaves identically to the public tester (physical detection only)." -ForegroundColor Yellow
    exit (Invoke-RTX50Harness -ReportsDir (Join-Path $HarnessRoot 'reports') -Yes:$Yes -PrecheckOnly:$PrecheckOnly)
}

if ($ackValue -ne $requiredAckValue) {
    Write-Host "-SimulateBlackwell was passed but `$env:$ackVar is not set to the required acknowledgement value." -ForegroundColor Red
    Write-Host "Simulation will NOT be activated (fail closed). Set:" -ForegroundColor Red
    Write-Host "  `$env:$ackVar = '$requiredAckValue'" -ForegroundColor Red
    exit 2
}

$simulatedTarget = [PSCustomObject]@{ GpuName = 'NVIDIA GeForce RTX 5070'; ComputeCapability = '12.0' }
Write-Host "DEVELOPMENT SIMULATION ACTIVE: hardware gating will behave as $($simulatedTarget.GpuName) (capability $($simulatedTarget.ComputeCapability))." -ForegroundColor Magenta
Write-Host "Real CUDA execution still uses the physical GPU in this machine. This is NOT real Blackwell validation." -ForegroundColor Magenta

exit (Invoke-RTX50Harness -ReportsDir (Join-Path $HarnessRoot 'reports') -Yes:$Yes -PrecheckOnly:$PrecheckOnly -SimulatedTarget $simulatedTarget)
