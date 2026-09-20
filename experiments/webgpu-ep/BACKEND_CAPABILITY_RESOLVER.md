# Backend Capability Matrix & Experimental Resolver — Phase L11

Status date: 2026-09-20. Starting HEAD `df1f4fe26` (L10, pushed and verified before this
phase began). Moves from isolated WebGPU hardware tests (L1–L10) to a working,
model-aware **backend resolver** prototype: something that decides, for a given
(model, platform, physical GPU) combination, whether STEMwerk's shared WebGPU
inference route should be offered at all — not just whether it technically runs.

**Not a replacement for CUDA/ROCm/MPS/DirectML.** The goal, per the brief, is to offer
WebGPU only where it is demonstrably correct, stable, and practically useful for that
exact model/GPU pair — supplementing existing vendor backends, never silently
replacing a proven-faster one.

**Headline result**: a working resolver prototype (`backend_resolver.py`), backed by a
machine-readable capability matrix (`capability_matrix.py`/`.json`) built entirely from
L1–L10 and N1's already-gathered evidence, plus a Linux-specific device-isolation adapter
(`linux_vulkan_isolation.py`, formalizing L10's proven `VK_LOADER_DEVICE_ID_FILTER`
mechanism). After controlled N1 integration, 22/22 automated policy tests pass. On real Linux/AMD hardware: **RX 9070 +
MDX-Net** and **Radeon 780M + MDX-Net** were both resolver-selected, actually executed,
and independently kernel-verified in this phase; **RX 9070 + Demucs** was
resolver-selected (execution reuses L9's already-live-verified run, not re-run here);
**Radeon 780M + Demucs** was exercised as a required *negative* policy test only — the
resolver correctly refuses it (BLOCKED) without attempting execution, causing no new
GPU hang.

The later N1 integration adds two distinct Linux/NVIDIA/Vulkan rows for the RTX 3060
Laptop GPU. They preserve N1's independent physical-execution proof while explicitly
not treating per-process `nvidia-smi` evidence as proof that the requested PCI selector
caused Dawn's device choice. L10 loader isolation remains the separate, proven Linux
enforcement mechanism. Linux RTX Demucs is compatible and 2.02x faster than ONNX CPU,
but Auto retains the established PyTorch/CUDA route because it was measured about 5.9x
faster than WebGPU.

## Phase 0: L10 publication

Already completed in the immediately preceding session (not repeated in this report):
local HEAD `df1f4fe26`, previous origin HEAD `9faca2881`, fetch confirmed no concurrent
changes, fast-forward push succeeded, local HEAD == origin HEAD verified, worktree
clean, canonical checkout and other worktrees untouched. This phase's own git
preflight (Section "Git" below) re-confirms the branch is still exactly at `df1f4fe26`
before any L11 work began.

## Section 1: Evidence studied

All of L1–L10, M1, L8, W1, and N1's sections in `README.md`, plus
`RADEON_780M_IGPU_VALIDATION.md` and `RADEON_780M_DEVICE_ISOLATION.md` in full, were
re-read before writing the capability matrix — not just the brief's own summary table.
This surfaced detail the brief's own table doesn't carry (needed for the matrix's
required fields), in particular:
- Exact numerical figures per platform/model (correlations, max_abs_diff, node counts).
- That STEMwerk's own source (`README.md` Section 2) only ever wires
  `CPUExecutionProvider`/`DmlExecutionProvider` for ONNX models directly — the
  CUDA/ROCm/MPS-accelerated paths for the Demucs family go through PyTorch
  (`torch.cuda`/HIP/MPS), not an onnxruntime GPU EP — this matters for the matrix's
  `vendor_alternative_available` field (M1/Demucs and W1/Demucs's vendor backends are
  PyTorch/MPS and PyTorch/CUDA specifically, already proven faster; MDX-Net has no
  established production-accelerated route in STEMwerk's own code on any platform
  today, so WebGPU is a genuine addition there, not a competitor to an existing route).
- That W1 (Windows) never ran L9/L10's own independent kernel-level physical-GPU
  verification (`nvidia-smi`-equivalent) — only onnxruntime/D3D12 module-load proof.
  This is carried into the matrix honestly as `physical_gpu_verification: "NOT
  INDEPENDENTLY VERIFIED"` for both Windows rows, and into
  `device_selection_enforceable: "UNKNOWN / NOT PROVEN"` — a real, disclosed gap, not
  glossed over. Re-verifying this was explicitly excluded from this L11 slice.

N1's complete `DEMUCS_LINUX_NVIDIA.md` report was used for the Linux RTX rows,
including its exact MDX and Demucs artifact hashes, runtime versions, placement,
numerical, pipeline, performance, and selection-causality evidence. No assumptions
were made about untested Intel or Windows-AMD
configurations — they simply have no matrix entries, and the resolver treats "no
entry" as `UNKNOWN`, never as an implicit pass (Section 3/5).

## Section 2: Capability matrix (`capability_matrix.py` / `capability_matrix.json`)

Ten `CapabilityEntry` records (2 models × 5 tested platform/GPU configurations), each
independently loaded with:

- Identity: `os_arch`, `gpu_vendor`/`gpu_model`/`gpu_device_id_hex`/`gpu_pci_bus_id`,
  `model_name`/`model_sha256`.
- Runtime: `inference_backend`, `underlying_graphics_backend`, `runtime_version`.
- Four explicitly distinct evidence levels, exactly as the brief required
  ("theoretische ondersteuning, daadwerkelijk getest, correct bevonden en geschikt
  voor Auto" are NOT collapsed into one flag):
  - `theoretically_supported` — the EP registers/enumerates this device at all.
  - `actually_tested` — a real model was actually run on real input on this exact
    combination, with independent physical-execution evidence (not just a session
    log).
  - `found_correct` — numerically/functionally correct AND stable (no crash). This
    gates whether ANY execution attempt (explicit or Auto) is even permitted.
  - `suitable_for_auto` — `found_correct` AND at least as fast as plain CPU on the
    same input. **This is the brief's own explicit litmus** ("a model that technically
    works but is 114× slower than CPU may not be marked a practically usable Auto
    route") — applied consistently: it disqualifies Radeon 780M + Demucs (crashes) AND
    Apple M1 + Demucs (49.08s WebGPU vs 28.14s plain CPU-ONNX on the same machine —
    slower than CPU itself, a fact easy to miss if only compared against MPS).
- Detail fields backing each of the above: `actual_gpu_execution`,
  `physical_gpu_verification`, `graph_placement`, `numerical_correctness`,
  `end_to_end_audio_correctness`, `stability`, `practical_performance`.
- Policy inputs: `vendor_alternative_available` (tracked separately from
  `suitable_for_auto` — WebGPU can be "suitable" as a fallback while a proven-better
  vendor backend still exists and should still be preferred by Auto; see Section 3),
  `device_selection_enforceable`.
- `evidence` — a pointer to the exact source report/section for every entry, so no
  figure in the matrix is asserted without a traceable source.

`python capability_matrix.py` regenerates `capability_matrix.json` (the genuinely
machine-readable artifact) from the single Python source of truth. Both are committed.

## Section 3: The resolver (`backend_resolver.py`)

`resolve(ResolveRequest) -> ResolveResult`. Input: `model_name`, `os_arch`,
`available_gpus` (tuple of `GpuInfo`), `desired_backend`
(`"Auto"`/`"CPU"`/`"WebGPU"`/`"Vendor"`), optional `explicit_gpu`, `allow_fallback`,
`webgpu_ep_available` (a runtime signal, separate from historical evidence — did the
plugin actually register on THIS machine right now), and an injectable
`capability_matrix` (defaults to the real one; overridable for testing, see Section 5's
contradictory-evidence test). Output (`ResolveResult`): `selected_backend`,
`selected_gpu`, `device_selection_enforceable`, `required_process_isolation` (an env
dict for the caller's own fresh subprocess — this module never starts one itself, see
Section 4), `model_gpu_suitability`, `fallback_decision`, `reason`, `evidence`,
`status` (`PASS`/`FAIL`/`BLOCKED`/`UNKNOWN`).

Key policy rules, each directly traceable to a brief requirement:

1. **Never silently substitute a different physical GPU.** An explicit GPU request
   that isn't in `available_gpus` → `FAIL`. An explicit GPU request that IS present but
   proven unstable/incorrect (e.g. 780M + Demucs) → `BLOCKED`, and the fallback (if
   permitted) is CPU, never a silent swap to a different GPU the caller didn't ask for.
2. **No evidence ⇒ `UNKNOWN`, never a claimed `PASS`.** Unknown GPU vendor, unknown
   model, or a combination simply never tested all resolve to `UNKNOWN` (or `BLOCKED`
   if evidence for a *sibling* GPU on the same request shows a known failure) — the
   resolver never reports a successful GPU selection it cannot back with evidence.
3. **Device-selection enforceability is checked separately from correctness.** A
   GPU/model pair can be `found_correct=True` on some other machine's single-GPU
   system and still resolve to `BLOCKED` here if this system has multiple GPUs and no
   proven mechanism exists to force the right one (Section 4) — this is exactly the
   Windows multi-GPU case in the matrix (`device_selection_enforceable: "UNKNOWN / NOT
   PROVEN"`).
4. **Auto prefers an already-proven-superior vendor backend over WebGPU**, per the
   brief's own "Doel" — even where WebGPU itself is `suitable_for_auto`. This is why
   Apple M1 + Demucs and RTX 3060 + Demucs resolve Auto requests to
   `Vendor:PyTorch/MPS` / `Vendor:PyTorch/CUDA` respectively, not to WebGPU, matching
   the brief's explicit "known MPS/CUDA performance advantage must be preserved" test
   requirement.
5. **An explicit WebGPU request is honored even when `suitable_for_auto` is False**,
   as long as `found_correct` is True — e.g. Apple M1 + Demucs explicitly requested
   returns `PASS` with a clear performance caveat in `model_gpu_suitability`, since the
   user asked for it specifically; only Auto (the automatic default) is barred from
   picking it unprompted. A combination that is NOT `found_correct` (780M + Demucs) is
   refused regardless of Auto vs. explicit — correctness/stability is a hard gate, not
   a preference.
6. **Multiple GPUs present, none `suitable_for_auto`** → `BLOCKED`, distinguishing this
   from **no GPUs matched at all** → `UNKNOWN` (different failure modes, per the
   brief's own distinct test cases).

## Section 4: Linux Vulkan-Loader isolation adapter (`linux_vulkan_isolation.py`)

Wraps exactly L10's proven mechanism — `VK_LOADER_DEVICE_ID_FILTER` set on a **fresh
subprocess's environment**, never on the calling process, never globally.
`build_isolation_plan(target_device_id_hex)` raises `IsolationNotAvailableError`
immediately on any non-Linux platform — the shared resolver calls this only behind a
`sys.platform.startswith("linux")` check (`backend_resolver._isolation_for`) and
otherwise reports `device_selection_enforceable=False` rather than assuming the
mechanism generalizes, exactly per L10 Section 12's no-portability claim. No global
environment changes, no driver changes, no GPU disabling — verified again by direct
use in Section 6 below (the isolation env dict is only ever passed to
`subprocess.run(..., env=...)`, never applied to the calling process's own
`os.environ`).

## Section 5: Automated policy tests (`test_backend_resolver.py`)

22/22 pass. Covers every original case plus focused N1 Linux RTX cases, each directly exercising one of the
rules in Section 3:

| # | Case | Result |
|---|---|---|
| 1 | RX 9070 + MDX-Net | Auto → WebGPU/RX 9070 |
| 2 | RX 9070 + Demucs | Auto → WebGPU/RX 9070 |
| 3 | Radeon 780M + MDX-Net | Auto → WebGPU/780M |
| 3b | Radeon 780M + MDX-Net, RX 9070 also present, explicit | Isolation env correctly targets `0x15bf` |
| 4 | Radeon 780M + Demucs | Auto **refused** (`BLOCKED`) — the brief's own required test |
| 4b | Radeon 780M + Demucs, explicit | Also `BLOCKED`, no silent swap to RX 9070 |
| 5 | Apple M1 + Demucs | Auto prefers `Vendor:PyTorch/MPS` (known advantage preserved) |
| 6 | RTX 3060 + Demucs | Auto prefers `Vendor:PyTorch/CUDA` (known advantage preserved) |
| 6b | Linux RTX 3060 + MDX-Net | Auto → the distinct Vulkan/WebGPU row |
| 6c | Linux RTX 3060 + MDX-Net, Renoir also present, explicit | L10 isolation env targets `0x2520`; N1's selector causality is not assumed |
| 6d | Linux RTX 3060 + Demucs, explicit | WebGPU remains available from N1 correctness evidence |
| 6e | Linux RTX 3060 + Demucs, Auto | Preserves the proven ~5.9x-faster `Vendor:PyTorch/CUDA` route |
| 6f/g | Linux/Windows RTX evidence and selector semantics | Vulkan and D3D12 remain distinct; physical execution and causal selection remain separate |
| 7 | Unknown Intel GPU | `UNKNOWN`, not `PASS` |
| 8 | Unknown ONNX model | `UNKNOWN`, not `PASS` |
| 9 | Nonexistent GPU (explicit) | `FAIL`, no substitute picked |
| 10 | Multiple GPUs, no enforceable selection (Windows) | `BLOCKED`, not a guess |
| 11 | WebGPU EP missing at runtime | `FAIL` |
| 12a/b | CPU fallback allowed / forbidden | Honored exactly, on the same unknown combination |
| 13 | Contradictory/outdated evidence | Swapping in a modified matrix changes the resolver's own decision (proves it reads its evidence input rather than hardcoding conclusions) |

Cases built on Apple M1/Windows RTX 3060 data (#5, #6, #10) verify the resolver's **reasoning**
against evidence M1/L8/W1 already gathered — they are explicitly **not** new hardware
validation, per the brief's own instruction, and are labeled as such in the test file's
own docstring. Cases #6b–#6g are focused assertions over N1's genuine Linux RTX 3060
evidence; they do not rerun its already-preserved GPU benchmark.

## Section 6: Real Linux/AMD hardware validation (`l11_hardware_validation.py`)

Run live on this machine (RX 9070 + Radeon 780M), reusing `end_to_end_pipeline_test.py`
for actual execution and `kernel_gpu_monitor.py` (this project's `DualCardMonitor`,
promoted from L9/L10's own scratch tooling into a reusable module) for independent
kernel-level verification — same standard of evidence as L9/L10, not weakened for this
phase.

**A genuine methodological correction made live during this phase, disclosed rather
than hidden**: this session's desktop background load (Firefox + `kwin_wayland`
compositing) is measurably noisier than L9/L10's own session — idle RX 9070 busy-%
reached avg 7–9%, max up to 85% from ordinary desktop activity alone, confirmed
independently via `fuser -v /dev/dri/card1`. A first pass at this script asserted a
fixed elevation threshold and failed on false positives caused by this noise, not by
any real isolation problem. Fixed properly, not by loosening the bar arbitrarily: every
test now measures a **fresh idle baseline immediately before it runs** (never reused
across runs, never assumed from L9/L10's own quieter session) and verifies execution
via two independent signals together — a max-busy jump clearly beyond that fresh
baseline (>30 points), and a nonzero fraction of samples sustained ≥70% busy that the
concurrently-measured idle baseline did not show. `kernel_gpu_monitor.py`'s own
docstring documents why the fraction metric was added.

### Scenario 1: RX 9070 + MDX-Net (resolver-selected)

Resolver: `Auto`, both GPUs present → `PASS`, `WebGPU`/RX 9070, no isolation needed
(preferred as the non-integrated candidate). Actually executed via
`end_to_end_pipeline_test.py`:

| Check | Result |
|---|---|
| Exit code | 0 |
| Graph placement | `All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 185` |
| Numeric parity (raw) | Vocals corr=1.00000000 max_abs_diff=7.08e-08; Instrumental corr=1.00000000 max_abs_diff=6.61e-08 |
| File parity | 3.05e-05 = exactly 1.00× PCM16 LSB, both stems |
| Stem routing | same-stem corr=1.000000 vs other-stem corr=0.998906 |
| Kernel evidence | idle baseline card1 max=50%/frac≥70%=0.00 → during-test card1 max=100%/frac≥70%=0.034, card0 (780M) stayed at 0% throughout |

### Scenario 2: Radeon 780M + MDX-Net (resolver-selected, isolated)

Resolver: explicit 780M request, RX 9070 also present → `PASS`,
`required_process_isolation={"VK_LOADER_DEVICE_ID_FILTER": "0x15bf"}`. Actually
executed in a fresh subprocess with that env:

| Check | Result |
|---|---|
| Exit code | 0 |
| Graph placement | `All nodes placed on [WebGpuExecutionProvider]. Number of nodes: 185` |
| Numeric parity (raw) | identical to Scenario 1's figures — bit-for-bit the same as every prior phase |
| Kernel evidence | 780M (card0): idle max=0%/frac≥70%=0.00 → during-test max=88%/frac≥70%=0.15 (genuine-execution signature). RX 9070 (card1): idle max=85%/frac≥70%=0.013 → during-test max=72%/frac≥70%=0.003 — **no** genuine-execution signature; if anything, lower than its own noisy idle sample |

Independently confirmed: the 780M did the work, the RX 9070 did not, exactly matching
L10's own conclusion — now reached via the resolver's own decision, not a hand-run
script.

### Scenario 3: RX 9070 + Demucs

Resolver: `Auto`, both GPUs present → `PASS`, `WebGPU`/RX 9070. **Execution was not
re-run in this phase** — it reuses the exact `demucs_shift_wrapper.py` +
`ORT_ENABLE_BASIC` route, last live-re-verified end-to-end in L9 Section 3 (1594/1594
nodes, 0 CPU fallback, corr≥0.99999 all 4 stems), to keep this phase's own runtime
bounded rather than re-running an already-proven ~2-minute Demucs pass for no new
information.

### Scenario 4: Radeon 780M + Demucs — negative policy test only, per the brief

**No execution was attempted.** L10 already proved the practical limitation
(`VK_ERROR_DEVICE_LOST` on the realistic-length clip); this phase's job was only to
confirm the resolver itself refuses this combination automatically, without a human
having to know the history:

| Check | Result |
|---|---|
| `Auto` request | `BLOCKED`, `selected_backend != "WebGPU"` |
| Explicit 780M request (RX 9070 also present) | `BLOCKED`, `selected_gpu is None` — no silent swap to the RX 9070 |
| GPU busy before the two resolver calls | card0 (780M) max=23% avg=20.8% (residual from Scenario 2's just-finished subprocess winding down), card1 (RX 9070) max=6% avg=5.8% |
| GPU busy after the two resolver calls | card0 max=18% avg=16.0%, card1 max=9% avg=7.0% — no new elevation attributable to the policy check itself |

Confirmed: the resolver's own decision-making triggers zero GPU activity — refusing a
known-bad combination is a pure data lookup, not an execution attempt, and no new GPU
hang was caused to re-obtain a conclusion L10 already established.

## Architecture question, answered directly

**Can a future STEMwerk runtime use one shared inference implementation, with limited
platform-specific code only for device selection, packaging, and monitoring? Can
existing vendor backends stay available without duplicating the whole inference and
audio pipeline?**

**Technically feasible: yes, and L1–L11 collectively demonstrate it, not just argue
for it.** The actual evidence:
- The shared inference code (`webgpu_adapter.py`, `demucs_shift_wrapper.py`,
  `demucs_onnx`) ran byte-identical or same-precision graphs across Linux/AMD,
  macOS/Apple Silicon, and Windows/NVIDIA with **zero changes to the audio pipeline
  itself** (STFT/iSTFT/chunking/overlap-add/export — traced in `README.md` Section
  2a — are backend-agnostic already, since STEMwerk's real production code already
  delegates the execution-provider choice to `audio-separator`'s own injection point,
  not something this experiment introduced).
- Every genuine platform-specific change needed across the whole project was small and
  isolated: macOS needed an RSS-reader branch and two CLI default changes (M1.11);
  Windows needed three small, previously-latent adapter bugfixes (fflush, log
  decoding, memory-info signature — W1); Linux now needs this phase's own device-
  isolation adapter (`linux_vulkan_isolation.py`). None of these touched the shared
  inference or audio code.
- This phase's resolver formalizes exactly the "device selection, packaging,
  monitoring" boundary the question describes: `backend_resolver.py` is the shared
  decision logic, `linux_vulkan_isolation.py` is the one platform-specific piece it
  calls out to, and `capability_matrix.py` is the (also platform-agnostic) evidence
  store.
- Vendor backends can remain available at the SAME existing injection point
  (`onnx_execution_provider`/`torch_device` in `audio-separator`'s own config) — adding
  WebGPU as one more selectable backend there, rather than as a parallel pipeline,
  requires no duplication of the surrounding pipeline code. This resolver's actual job
  in that future design would be exactly to choose which backend string reaches that
  one injection point.

**This is technical feasibility, not proven production readiness — the two are kept
explicitly distinct, per the brief's own instruction:**
1. Device-selection enforceability is proven on Linux only; Windows/macOS remain
   `UNKNOWN`/`N/A` in the matrix, not assumed safe.
2. The underlying `onnxruntime-ep-webgpu` plugin's own device-selection bug (L9) is
   real and unresolved upstream — this project's isolation adapter works around it on
   Linux specifically; there is no equivalent workaround demonstrated for Windows/macOS.
3. The capability matrix currently covers exactly 2 models × 5 platform/GPU
   combinations — a small fraction of STEMwerk's actual supported model set. Models
   that are PyTorch `.ckpt` files (MDXC/Roformer, per `README.md` Section 2) are
   outside this ONNX/WebGPU route's scope entirely and would need their own
   feasibility work, not covered by this resolver at all.
4. The resolver is experimental Python, not wired into STEMwerk's actual Lua
   configuration/production separator code, with no installer/packaging work done —
   exactly per the brief's "no production integration" instruction.
5. Keeping the capability matrix accurate over time (new onnxruntime/Dawn/driver
   versions, new hardware) is real, ongoing maintenance surface this phase has not
   designed a process for — it built one honest snapshot, not a self-updating system.

## Deliverables

- `capability_matrix.py` / `capability_matrix.json` — the machine-readable matrix.
- `backend_resolver.py` — the experimental resolver.
- `linux_vulkan_isolation.py` — the Linux device-isolation adapter.
- `kernel_gpu_monitor.py` — the independent kernel-level verification tool, promoted
  from L9/L10's own scratch tooling to a reusable, committed module in this phase.
- `test_backend_resolver.py` — 22 automated policy tests (all passing).
- `l11_hardware_validation.py` — real Linux/AMD hardware validation script (all 4
  required scenarios; reproducible via `python l11_hardware_validation.py` with the
  webgpu venv active from `experiments/webgpu-ep/`).
- This report; `README.md` updated with a concise L11 summary.

## Known limitations (not glossed over)

- `capability_matrix.py`'s data is a manually-curated snapshot of L1–L11 plus N1's findings,
  not automatically derived from raw test output — a transcription error is possible
  in principle, though every figure was checked against its cited source section while
  writing this report.
- The resolver's "prefer non-integrated GPU" tie-break (used when more than one
  available GPU is technically suitable) is a simple heuristic (string match on
  "igpu"/"integrated" in the GPU model name), not a general performance-ranking
  system — sufficient for this project's current two-GPU-class evidence base, not
  validated against a three-or-more-GPU system.
- `vendor_alternative_available`'s "proven better" detection
  (`backend_resolver._vendor_alternative_is_proven_better`) is a simple substring
  check (`"proven" in ...`) on a human-written matrix field, not a structured
  comparison of benchmark numbers — adequate for this phase's 10 entries, would need a
  more structured representation before scaling further.
- No attempt was made to test what happens if `available_gpus` reports a GPU whose
  `device_id_hex` doesn't match any known hex format, or other malformed-input cases
  beyond what the 22 policy tests already cover.

## Git

- Starting HEAD: `df1f4fe26` (L10, already published in the prior turn). `git fetch
  origin` re-checked before writing this report and again before committing (Section
  below) — no changes found either time; no reconciliation needed.
- This phase's own commit: `capability_matrix.py`, `capability_matrix.json`,
  `backend_resolver.py`, `linux_vulkan_isolation.py`, `kernel_gpu_monitor.py`,
  `test_backend_resolver.py`, `l11_hardware_validation.py`,
  `BACKEND_CAPABILITY_RESOLVER.md`, `README.md` update. No production STEMwerk code,
  installer, REAPER UI, model registry, or venv touched.
- Not pushed automatically, per instructions.
