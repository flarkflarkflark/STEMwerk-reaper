# STEMwerk #118 - RTX 50-series / NVIDIA Blackwell test harness

This folder is a self-contained tester for STEMwerk issue #118: STEMwerk
fails on RTX 50-series (Blackwell, compute capability 12.0 / sm_120) GPUs
with:

```
CUDA error: no kernel image is available for execution on the device
```

Root cause: STEMwerk 2.3.1.1 ships PyTorch/CUDA built for cu121, whose real
compiled architecture list on this baseline is
`sm_50, sm_60, sm_61, sm_70, sm_75, sm_80, sm_86, sm_90` - there is no
`sm_120` entry, so it has no usable GPU kernels at all on Blackwell
hardware. This harness evaluates an experimental cu128 runtime (torch
2.7.1 / torchvision 0.22.1 / torchaudio 2.7.1), whose arch list does
include `sm_120`.

## What this tester does

1. Detects your GPU and current STEMwerk PyTorch/CUDA environment.
2. If your GPU is **not** RTX 50-series / Blackwell, it stops immediately
   and reports that - it changes nothing.
3. If your GPU **is** RTX 50-series / Blackwell, after your confirmation
   it backs up your current environment, installs the experimental cu128
   runtime, and verifies it (package versions, `torch.cuda.get_arch_list()`,
   real CUDA tensor/matmul/reduction operations, and STEMwerk's Python
   imports).
4. If anything about the verification fails, it automatically restores
   your original environment and tells you so clearly in the report.

## How to use it

1. Extract this folder somewhere on your machine.
2. **Close REAPER.**
3. Double-click **`TEST-STEMwerk-RTX50.cmd`**.
4. A console window opens and runs the tester. Follow the on-screen
   prompt (type `YES` to proceed with the experimental install, or
   anything else to abort with no changes made).
5. When it finishes, a report is saved under `reports\` next to this
   README (also printed on screen). Please attach this report file to
   your reply.
6. If the tester reports **PASS**: open REAPER and test Normal Stems /
   `htdemucs_ft` / Auto separation. **Do not run STEMwerk Setup/Repair** -
   that would reinstall the old runtime over the experimental one.
7. If you want to go back to the original STEMwerk runtime at any time
   (whether the tester passed or failed), double-click
   **`ROLLBACK-STEMwerk-RTX50.cmd`**. It restores the exact packages you
   had before, using the backup the tester made automatically.
8. Attach the harness report **and** a fresh STEMwerk support bundle to
   your reply.

No administrator rights are required. Nothing outside your normal
STEMwerk installation folder (`%LOCALAPPDATA%\STEMwerk\.venv`) is ever
touched.

## What a PASS here does and does not prove

A PASS proves the cu128 runtime installs correctly and runs real CUDA
operations successfully on your machine. Because you are running real
RTX 50-series hardware, a PASS from this tester on your machine, together
with STEMwerk actually separating a track in REAPER, **is** the real
Blackwell validation STEMwerk needs. (The distinction called out below
about "simulated" runs only applies to development testing on non-Blackwell
machines - it does not apply to you.)

## Files

| File | Purpose |
|---|---|
| `TEST-STEMwerk-RTX50.cmd` | Double-click entry point. Runs the tester under Windows PowerShell 5.1. |
| `STEMwerk-RTX50-cu128-test.ps1` | Main tester logic. |
| `ROLLBACK-STEMwerk-RTX50.cmd` | Double-click entry point for restoring your original environment. |
| `STEMwerk-RTX50-rollback.ps1` | Rollback logic (also invoked automatically on failure). |
| `lib\` | Shared PowerShell/Python modules used by both scripts. |
| `reports\` | Created automatically; holds every run's report, state file, and baseline backup manifest. |

## Safety design

- The tester verifies, before touching anything, that
  `%LOCALAPPDATA%\STEMwerk\.venv` really is your STEMwerk installation
  (checks its structure and installed packages) - it refuses to proceed
  if it cannot confirm this ("fail closed").
- It never touches `.venv-drumsep*`, your model cache, REAPER
  scripts/ReaPack files, installer files, the registry, system Python, or
  any other virtual environment or user file.
- Before installing anything, it records your exact current package
  versions to a backup file (`reports\*.baseline.json`). Rollback always
  restores from that exact recorded backup, never an assumed version.
- Every meaningful outcome (pass, fail, aborted, precheck rejection,
  install failure, verification failure, rollback attempted/verified/
  unknown) writes a full report - a run can never finish with "nothing
  saved in the report folder".
- If rollback itself cannot be verified, the report says so in the
  clearest possible terms: **ROLLBACK STATUS UNKNOWN / MANUAL ATTENTION
  REQUIRED**. If you ever see that, stop and get in touch rather than
  running STEMwerk further.

## Known related issue (not fixed by this tester)

STEMwerk's diagnostics can sometimes misclassify this exact CUDA failure
as a model-download/VPN/firewall problem, because an earlier, harmless log
line containing wording like "skipping download" gets matched by the
error classifier before the real CUDA error is seen. That classifier bug
is tracked separately and is not addressed by this tester.

## Development-only Blackwell simulation

`STEMwerk-RTX50-cu128-test.ps1` has a hidden `-SimulateBlackwell` switch
used only to test this harness itself on non-Blackwell development
machines. It requires the environment variable
`STEMWERK_RTX50_DEV_SIMULATION_ACK` to also be set to an exact
acknowledgement string, so it can never engage by accident, and it is not
needed or mentioned anywhere in the normal tester workflow above. When
active, it makes only this harness's own "is this Blackwell hardware?"
decision behave as if the GPU were an RTX 5070 (compute capability 12.0);
it never changes `torch.version.cuda`, installed package versions,
`torch.cuda.get_arch_list()`, real CUDA execution, or the physical GPU
identity reported anywhere in the tester's output - real CUDA execution
always happens on the real physical GPU. Every report is explicit about
whether `SIMULATED_BLACKWELL` was `yes` or `no`, and a simulated run is
never real Blackwell hardware validation. Real validation can only come
from an actual RTX 50-series machine.

See `dev\` for the harness's own regression/test suite (not part of the
tester package; development use only).
