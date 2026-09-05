# STEMwerk #118 - RTX 50-series / NVIDIA Blackwell test harness (v2)

**If you were given an older tester ZIP (v1), please delete it and use this
one instead.** A real RTX 5070 tester's v1 run appeared to hang during a
long PyTorch download and was closed after ~10 minutes; v1 then could not
tell the difference between that interrupted state and a real baseline, so
its rollback could have restored an already-broken environment. v2 fixes
this - see "Interruption safety" below - and is confirmed to still let
real Blackwell separation succeed (a real RTX 5070 completed a Normal
Stems `htdemucs_ft`/Auto separation on the cu128 runtime this tester
installs).

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
include `sm_120`, and which a real RTX 5070 has already used to complete a
real STEMwerk separation successfully.

## What this tester does

1. Detects your GPU and current STEMwerk PyTorch/CUDA environment.
2. If your GPU is **not** RTX 50-series / Blackwell, it stops immediately
   and reports that - it changes nothing.
3. If your GPU **is** RTX 50-series / Blackwell, after your confirmation
   it backs up your current environment (to a durable, machine-level
   location - see below), installs the experimental cu128 runtime, and
   verifies it (package versions, `torch.cuda.get_arch_list()`, real CUDA
   tensor/matmul/reduction operations, and STEMwerk's Python imports).
4. If anything about the verification fails, it automatically restores
   your original environment and tells you so clearly in the report.

## How to use it

1. Extract this folder somewhere on your machine.
2. **Close REAPER.**
3. Double-click **`TEST-STEMwerk-RTX50.cmd`**.
4. A console window opens and runs the tester. Follow the on-screen
   prompt (type `YES` to proceed with the experimental install, or
   anything else to abort with no changes made).
5. **Do not close the window while the runtime update is in progress.**
   A PyTorch CUDA download is several GB and can take minutes - the
   tester prints a heartbeat line periodically so it never looks frozen.
   If it IS interrupted anyway (window closed, power loss, forced kill),
   **just run the tester again** - see "Interruption safety" below.
6. When it finishes, a report is saved under `reports\` next to this
   README (also printed on screen). Please attach this report file to
   your reply.
7. If the tester reports **PASS**: open REAPER and test Normal Stems /
   `htdemucs_ft` / Auto separation. **Do not run STEMwerk Setup/Repair** -
   that would reinstall the old runtime over the experimental one.
8. If you want to go back to the original STEMwerk runtime at any time
   (whether the tester passed or failed), double-click
   **`ROLLBACK-STEMwerk-RTX50.cmd`**.
9. Attach the harness report **and** a fresh STEMwerk support bundle to
   your reply.

No administrator rights are required. Nothing outside your normal
STEMwerk installation folder (`%LOCALAPPDATA%\STEMwerk\.venv`) is ever
touched.

## Interruption safety (new in v2)

Before touching any package, the tester writes a durable record of your
exact current package versions to
`%LOCALAPPDATA%\STEMwerk\rtx50-test-state\transaction.json` - a location
independent of wherever you extracted this ZIP, so it survives even if
you re-extract to a different folder. That record is treated as trusted
and is **never overwritten by a broken/partial install** - if the tester
is interrupted mid-update, the *next* run detects the leftover
inconsistent state, recognizes it as an interrupted transaction, and
automatically restores the exact original baseline it saved before -
never the broken in-between state. The record is only cleared once a
restore has been independently re-verified.

If you ever see **"MANUAL ATTENTION REQUIRED"** or **"ROLLBACK STATUS
UNKNOWN"** in a report, stop and reply with that report and a support
bundle rather than re-running the tester or REAPER.

## What a PASS here does and does not prove

A PASS proves the cu128 runtime installs correctly and runs real CUDA
operations successfully on your machine. Because you are running real
RTX 50-series hardware, a PASS from this tester on your machine, together
with STEMwerk actually separating a track in REAPER, **is** real Blackwell
validation - the report will say `REAL_BLACKWELL_VALIDATION=yes`. (There
is no development-simulation mode reachable from this tester package at
all - see "Development-only simulation" below.)

## Files

| File | Purpose |
|---|---|
| `TEST-STEMwerk-RTX50.cmd` | Double-click entry point. Runs the tester under Windows PowerShell 5.1. |
| `STEMwerk-RTX50-cu128-test.ps1` | Main tester entry script (thin - see `lib\HarnessCore.ps1`). |
| `ROLLBACK-STEMwerk-RTX50.cmd` | Double-click entry point for restoring your original environment. |
| `STEMwerk-RTX50-rollback.ps1` | Rollback entry script (also invoked automatically on failure). |
| `lib\` | Shared PowerShell/Python modules used by both scripts. |
| `reports\` | Created automatically; holds every run's human-readable report and machine-readable state file. |

## Safety design

- The tester verifies, before touching anything, that
  `%LOCALAPPDATA%\STEMwerk\.venv` really is your STEMwerk installation
  (checks its structure and installed packages) - it refuses to proceed
  if it cannot confirm this ("fail closed").
- It never touches `.venv-drumsep*`, your model cache, REAPER
  scripts/ReaPack files, installer files, the registry, system Python, or
  any other virtual environment or user file.
- Your exact current package versions are captured to a durable,
  machine-level transaction record (see "Interruption safety") before any
  mutation - never assumed, and never replaced by a later broken state.
- Every meaningful outcome (pass, fail, aborted, precheck rejection,
  install failure, verification failure, interrupted-transaction
  recovery, rollback attempted/verified/unknown) writes a full report - a
  run can never finish with "nothing saved in the report folder".
- If rollback itself cannot be verified, the report says so in the
  clearest possible terms: **ROLLBACK STATUS UNKNOWN / MANUAL ATTENTION
  REQUIRED**.

## Known related issue (not fixed by this tester)

STEMwerk's diagnostics can sometimes misclassify this exact CUDA failure
as a model-download/VPN/firewall problem, because an earlier, harmless log
line containing wording like "skipping download" gets matched by the
error classifier before the real CUDA error is seen. That classifier bug
is tracked separately and is not addressed by this tester.

## Development-only simulation

There is no simulation switch, parameter, or environment variable
reachable from `STEMwerk-RTX50-cu128-test.ps1`, `TEST-STEMwerk-RTX50.cmd`,
or anything else in this tester package - hardware gating here always
reflects your real physical GPU. Development-only Blackwell simulation
(used only to test this harness itself on non-Blackwell machines) lives
entirely in a separate script that is deliberately **not included** in
this ZIP; see the project repository's `tools/rtx50-harness/dev/` folder
if you are a developer working on the harness itself.
