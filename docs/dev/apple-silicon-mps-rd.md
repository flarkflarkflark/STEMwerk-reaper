# Apple Silicon MPS R&D

Status: experimental prototype only. Default Apple Silicon behavior is unchanged: CPU fallback.

This document records the audit, the experimental opt-in, and the open
test matrix for evaluating whether PyTorch's MPS backend can ever become
a supported device for STEMwerk on Apple Silicon. It is not user-facing
documentation. Branch: `rd/apple-silicon-mps-backend`.

## Why this exists

PyTorch 2.5 on Apple Silicon advertises MPS as available, but the
Demucs family of models (the STEMwerk default) hits a hard PyTorch
limit when separation runs on MPS:

```
NotImplementedError: Output channels > 65536 not supported at the MPS device.
As a temporary fix, you can set the environment variable
PYTORCH_ENABLE_MPS_FALLBACK=1 to use the CPU as a fallback for this op.
```

`PYTORCH_ENABLE_MPS_FALLBACK=1` is already set unconditionally for any
`resolved_device == "mps"` ([audio_separator_process.py:537-545](../../scripts/reaper/audio_separator_process.py#L537-L545)),
but the affected operator does not actually fall back per-op for this
shape — the entire run aborts. The current shipping policy
([commit 95160c3](#)) therefore forces CPU for Demucs on Apple Silicon
at every layer, with a friendly UI message keyed off the marker
`STEMWERK_MPS_UNSUPPORTED_OP output_channels_gt_65536`.

The open question is whether *any* combination of model family, model
size, torch version, or dtype lets MPS deliver real speedup without
hitting this or another unsupported-op cliff. Until we have hardware
data, MPS stays hidden.

## Current MPS gates (after baseline commit)

There are seven sites that together implement the "MPS disabled on
Apple Silicon for Demucs" baseline. The experimental flag toggles all of
them off in one place.

| # | File | Site | Behavior when flag off |
|---|------|------|-----------------------|
| 1 | `scripts/reaper/_internal/STEMwerk_Devices.lua` | `applyRuntimeDevicesFromParsed` filter | Strip `mps` from device list |
| 2 | `scripts/reaper/_internal/STEMwerk_Devices.lua` | `applyRuntimeDevicesFromParsed` post-normalize | Persisted `SETTINGS.device == "mps"` → `"cpu"` |
| 3 | `scripts/reaper/_internal/STEMwerk_Devices.lua` | `normalizeRequestedDeviceForRuntime` | Requested `"mps"` → `"cpu"` |
| 4 | `scripts/reaper/_internal/STEMwerk_Settings.lua` | `SETTINGS_MOD.load()` | Persisted `mps` → `cpu` on load |
| 5 | `scripts/reaper/_internal/STEMwerk_Settings.lua` | `SETTINGS_MOD.save()` | `mps` → `cpu` before write |
| 6 | `scripts/reaper/STEMwerk.lua` | `drawDeviceColumn` filter | Strip `mps` from drawn device list |
| 7 | `scripts/reaper/audio_separator_process.py` | `_enforce_mps_demucs_cpu_policy` | Final backend guard; if Demucs + arm64 + mps requested → cpu |

`vendor/stemwerk-core/.../devices.py` also has Apple Silicon auto-select
logic ([devices.py:237-244](../../scripts/reaper/vendor/stemwerk-core/src/stemwerk_core/devices.py#L237-L244))
that returns `"cpu"` from `select_device("auto")` even when MPS is
available. This is intentional and is **not** gated by the experimental
flag — auto remains conservative; the user must pick MPS explicitly
in experimental mode.

## The experimental opt-in

Set `STEMWERK_EXPERIMENTAL_MPS=1` in the environment that launches
REAPER (or the test harness). Accepted truthy values:
`1`, `true`, `yes`, `on` (case-insensitive).

When the flag is on:

- Sites 1-6 stop rewriting requests/settings/devices. The user can pick
  MPS from the device dropdown.
- Site 7 emits `STEMWERK_DIAG experimental_mps_enabled=1
  demucs_mps_policy=bypassed` and returns the requested device
  unchanged, so MPS reaches torch.
- `PYTORCH_ENABLE_MPS_FALLBACK=1` is still set unconditionally for
  MPS runs.
- The existing failure classifier ([audio_separator_process.py:548-586](../../scripts/reaper/audio_separator_process.py#L548-L586))
  still emits the marker and the friendly Lua-side UI message on the
  known output-channels failure.
- New diagnostic key `experimental_mps_enabled` appears in
  `STEMWERK_ENV_JSON` and in the `STEMWERK_DIAG` stderr stream.

When the flag is off (default), behavior is byte-for-byte identical to
the release/2.2.2.2 baseline.

## Stack versions on Apple Silicon

From [`scripts/reaper/STEMwerk_Bootstrap_macOS.sh:13-15`](../../scripts/reaper/STEMwerk_Bootstrap_macOS.sh#L13-L15):

| Package | Pinned version (arm64) |
|---------|-----------------------|
| Python | 3.10–3.12 |
| torch | 2.5.1 |
| torchvision | 0.20.1 |
| torchaudio | 2.5.1 |
| audio-separator | 0.23.0 |
| numpy | 1.26.4 |

The pinned `torch==2.5.1` does have MPS built (`torch.backends.mps.is_built()`
returns true on Apple Silicon machines with macOS 12+). The
`output channels > 65536` limit is a PyTorch operator-implementation
issue, not a build/installation issue, and is present in 2.5.x. There
is no evidence it is fixed in torch 2.6/2.7 either — the upstream
issue tracker indicates it is a known MPS device limitation.

## What you'd need to verify on real hardware

The test matrix below is **empty** by design — these rows must be
filled in by running on an actual Apple Silicon Mac with the
experimental flag enabled. The smoke test at
`tests/test_apple_silicon_mps_smoke.py` provides scaffolding:

```sh
# On an Apple Silicon Mac inside the STEMwerk venv:
STEMWERK_EXPERIMENTAL_MPS=1 PYTORCH_ENABLE_MPS_FALLBACK=1 \
  pytest tests/test_apple_silicon_mps_smoke.py -v
```

The three Apple-only tests will run; on Linux/Intel they skip with a
clear reason. The tiny matmul probe (`test_torch_mps_tensor_allocation_and_matmul`)
isolates whether MPS works at all on this machine. The load-only probe
(`test_demucs_on_mps_load_only`) is intentionally `xfail` on failure
since it is the known-broken path.

### Running the GitHub-hosted MPS R&D workflow

If you don't have a local Apple Silicon Mac, the workflow
`.github/workflows/apple-silicon-mps-rd.yml` runs the same probe on a
GitHub-hosted `macos-14` arm64 runner. It is `workflow_dispatch` only —
it never runs on push or pull_request, never tags, never releases.

To trigger it:

1. Go to the **Actions** tab, pick **Apple Silicon MPS R&D**, click
   **Run workflow**.
2. Pick a target branch (typically `rd/apple-silicon-mps-backend`).
3. Inputs:
   - `model`: `all` (Demucs matrix), or one of `htdemucs`,
     `htdemucs_ft`, `htdemucs_6s`.
   - `duration_seconds`: length of the synthetic stereo WAV the job
     generates as input. Default `10`.
4. The job installs the macOS Apple Silicon pinned stack
   (`torch==2.5.1`, `audio-separator==0.23.0`, etc.), generates a
   synthetic stereo sine-tone WAV, then for each selected model runs:
   ```
   STEMWERK_EXPERIMENTAL_MPS=1 PYTORCH_ENABLE_MPS_FALLBACK=1 \
     python scripts/reaper/audio_separator_process.py \
       <input.wav> <output_dir> --model <model> --device mps
   ```
   capturing exit code, elapsed time, stdout, and stderr.
5. Each model's run is classified as `PASS`,
   `FAIL_MPS_UNSUPPORTED_OP` (matched by the
   `STEMWERK_MPS_UNSUPPORTED_OP output_channels_gt_65536` marker or the
   raw `Output channels > 65536` torch message), or `FAIL_OTHER`. A
   classified failure does **not** fail the job — the workflow is for
   data collection.
6. Artifacts are uploaded as `apple-silicon-mps-rd-<run_id>` and
   include `rd_results/summary.md`, `rd_results/summary.json`, per-model
   `stdout.log` / `stderr.log`, the `phase_events.jsonl` /
   `separation_log.txt` emitted by `audio_separator_process.py`, and the
   generated input WAV.

Use the artifact summary to fill in the model matrix above. Do **not**
commit results back into this document automatically — review them
first.

### Model matrix (to fill in)

| Model | Family | Requested device | Effective device | Result | Failure message | Elapsed | Output validity |
|-------|--------|------------------|------------------|--------|-----------------|---------|-----------------|
| `htdemucs` | Demucs 4-stem | mps | ? | ? | ? | ? | ? |
| `htdemucs_ft` | Demucs 4-stem | mps | ? | ? | ? | ? | ? |
| `htdemucs_6s` | Demucs 6-stem | mps | ? | ? | ? | ? | ? |
| `UVR-MDX-NET-Voc_FT` | MDX-NET | mps | ? | ? | ? | ? | ? |
| `Kim_Vocal_2` | MDX-NET | mps | ? | ? | ? | ? | ? |

The MDX-NET rows are the interesting comparison: they use ONNX Runtime
under the hood rather than torch's Demucs path, so the
`output channels > 65536` failure may not apply to them. If any MDX-NET
model runs cleanly on MPS with a real speedup over CPU, that is
evidence for selectively enabling MPS for MDX-NET only — which is
recommendation D below.

### Diagnostic checklist after each run

Capture from `STEMWERK_ENV_JSON` and `STEMWERK_DIAG` lines in
`separation_log.txt`:

- `platform`, `platform_machine`
- `python_version`, `torch_version`, `torchaudio_version`, `onnxruntime_version`
- `mps_built`, `mps_available`, `mps_fallback_env`
- `experimental_mps_enabled` (must be `True` for an MPS run)
- `requested_device`, `selected_device`
- On failure: the full traceback and whether the marker
  `STEMWERK_MPS_UNSUPPORTED_OP output_channels_gt_65536` appeared

## Recommendation

**Option B: keep MPS hidden in production; experimental opt-in for
testers only.** Until the model matrix above has at least one row
showing a real-world MPS run that produces correct stems faster than
CPU on the same machine, MPS must not be visible to end users.

Why not the other options:

- **A (CPU only, no flag).** Defensible but blocks discovery — we
  cannot find out which models *do* work on MPS without an opt-in
  path. The flag is cheap and the default is unchanged.
- **C (visible "experimental" device).** Premature — visible
  experimental options carry a documentation/translation cost and
  imply some level of expected reliability. Until we have data, the
  flag should be undocumented in the UI.
- **D (auto-enable for specific model families).** A possible future
  state if the MDX-NET path turns out to work cleanly. Decision
  requires hardware data first.
- **E (never).** Too final. The PyTorch MPS backend is improving each
  release, and Apple Silicon Macs are a significant user segment.

## How to commit promotion B → C or B → D

The promotion path is small and local:

1. Fill in the model matrix from hardware runs.
2. If at least one model+device combination meets the bar (works
   end-to-end, output validates, runtime ≤ CPU runtime), introduce a
   per-family allowlist in `_enforce_mps_demucs_cpu_policy` or
   `select_device` so MPS is allowed for those families even without
   the experimental flag.
3. Add a translated `device_mps_experimental_desc` (or similar) and
   swap the descKey in `STEMwerk_Devices.lua` only for confirmed-safe
   model selections.
4. Drop `STEMWERK_EXPERIMENTAL_MPS` only when option C/D is shipped;
   keeping the flag as a tester-only escape valve is fine indefinitely.

## Scope / non-goals

- Intel Mac, Windows CUDA/DirectML, Linux CUDA/ROCm paths are
  unmodified.
- No UI strings or translations changed.
- No bootstrap/version pinning changed (torch 2.5.1 stays).
- No silent fallback added; the existing failure classifier remains
  the only mechanism that converts an MPS exception into a CPU re-run
  decision (currently it surfaces the error to the user; it does not
  retry on its own).

## Verifying this branch doesn't change release behavior

Run the existing macOS MPS fallback tests without the flag:

```sh
pytest tests/test_macos_mps_fallback.py tests/test_apple_silicon_mps_smoke.py -v
```

All 5 tests in `test_macos_mps_fallback.py` and the 14
platform-independent tests in `test_apple_silicon_mps_smoke.py` should
pass; the 3 Apple-only probes should skip with explicit reasons. The
gating diff (`backend: gate experimental mps on apple silicon`) is
+28/-6 lines across four files and does not touch any non-MPS code
path.
