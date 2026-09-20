"""
Machine-readable WebGPU capability matrix -- Phase L11.

One `CapabilityEntry` per (OS/arch, physical GPU, model) combination this experiment
has actually gathered evidence for. This module is the single source of truth
`backend_resolver.py` queries -- it contains no resolution logic itself, only facts
and their provenance (which report/section backs each field).

Four distinct levels are tracked explicitly per the L11 brief, because they are not
the same thing and collapsing them was exactly the trap L9 warned about (a session
"succeeding" is not the same as a node executing on the requested GPU):
  - theoretically_supported: the EP registers and lists this device at all.
  - actually_tested: a real model was actually run against real input on this exact
    (OS, GPU, model) combination, with independent physical-execution evidence.
  - found_correct: numerically/functionally correct against a CPU or reference
    baseline, AND stable (no crash) across the tested run(s).
  - suitable_for_auto: found_correct AND at least as fast as plain CPU on the same
    input. A model that "works" but is slower than CPU (the L11 brief's own litmus,
    e.g. the 780M/Demucs and M1/Demucs cases below) is never suitable_for_auto,
    regardless of how clean its numerics are.

`vendor_alternative_available` is tracked separately from `suitable_for_auto`: WebGPU
is meant to supplement CUDA/ROCm/MPS/DirectML, not replace them (L11 brief, "Doel").
`backend_resolver.py` uses it to keep Auto preferring an already-proven-superior
vendor backend even for a GPU/model pair where WebGPU itself is otherwise
`suitable_for_auto` as a fallback.
"""
from __future__ import annotations

import dataclasses
import json
import pathlib
from typing import Optional


@dataclasses.dataclass(frozen=True)
class CapabilityEntry:
    # Identity
    os_arch: str                     # e.g. "Linux x86_64 (EndeavourOS, kernel 6.18.52-lts)"
    gpu_vendor: str                  # e.g. "AMD", "NVIDIA", "Apple"
    gpu_model: str                   # e.g. "Radeon RX 9070"
    gpu_device_id_hex: Optional[str] # e.g. "0x7550"; None where not applicable (e.g. Apple Silicon)
    gpu_pci_bus_id: Optional[str]    # e.g. "0000:03:00.0"; None where not applicable
    model_name: str                  # e.g. "UVR_MDXNET_KARA_2.onnx"
    model_sha256: Optional[str]      # None if not separately hash-pinned in the source report

    # Runtime
    inference_backend: str           # e.g. "onnxruntime-ep-webgpu 0.3.0 (WebGpuExecutionProvider)"
    underlying_graphics_backend: str # "Vulkan (RADV)" / "D3D12" / "Metal"
    runtime_version: str             # e.g. "onnxruntime 1.30.0 + onnxruntime-ep-webgpu 0.3.0"

    # Evidence levels (see module docstring)
    theoretically_supported: bool
    actually_tested: bool
    found_correct: bool
    suitable_for_auto: bool

    # Detail fields backing the above
    actual_gpu_execution: str        # human-readable evidence summary
    physical_gpu_verification: str   # method + result, or explicit "NOT INDEPENDENTLY VERIFIED"
    graph_placement: str             # e.g. "185/185 nodes on WebGPU, 0 CPU fallback"
    numerical_correctness: str
    end_to_end_audio_correctness: str  # "PASS" / "FAIL" / "NOT TESTED" / "BLOCKED"
    stability: str                     # "PASS" / "BLOCKED: <cause>"
    practical_performance: str

    # Policy inputs
    vendor_alternative_available: Optional[str]  # e.g. "DirectML (unverified vs WebGPU here)", "CUDA (proven faster)", None
    device_selection_enforceable: str  # how (or whether) a specific physical GPU can be forced on this platform

    evidence: str                    # file + section pointer


MATRIX: list[CapabilityEntry] = [
    CapabilityEntry(
        os_arch="Linux x86_64 (EndeavourOS, kernel 6.18.52-lts, Mesa 26.2.2)",
        gpu_vendor="AMD", gpu_model="Radeon RX 9070", gpu_device_id_hex="0x7550",
        gpu_pci_bus_id="0000:03:00.0",
        model_name="UVR_MDXNET_KARA_2.onnx", model_sha256=None,
        inference_backend="onnxruntime-ep-webgpu 0.3.0 (WebGpuExecutionProvider)",
        underlying_graphics_backend="Vulkan (RADV)",
        runtime_version="onnxruntime 1.30.0 + onnxruntime-ep-webgpu 0.3.0",
        theoretically_supported=True, actually_tested=True, found_correct=True, suitable_for_auto=True,
        actual_gpu_execution="Confirmed via onnxruntime placement log + (L9/L10) independent kernel-level "
                              "amdgpu busy-percent monitoring during session.run()",
        physical_gpu_verification="PASS -- kernel-level (/sys/class/drm/card1/device/gpu_busy_percent), "
                                   "independent of onnxruntime/Dawn/Vulkan (L9 Section 3, L10 Experiment A)",
        graph_placement="185/185 nodes on WebGPU, 0 CPU fallback (L1-L10, unchanged across every phase)",
        numerical_correctness="corr=1.00000000, max_abs_diff=7.08e-08 (vocals) / 6.61e-08 (instrumental) vs CPU EP",
        end_to_end_audio_correctness="PASS",
        stability="PASS -- no crash across L1-L10's repeated runs",
        practical_performance="5.75x faster than CPU (L2 benchmark, 20s clip)",
        vendor_alternative_available=None,
        device_selection_enforceable="PASS -- explicit pci_bus_id via select_device(); this is the default/only "
                                      "discrete adapter, so no isolation mechanism was even required to reach it",
        evidence="README.md Phase L1/L2 sections; RADEON_780M_IGPU_VALIDATION.md Section 3 (re-verified)",
    ),
    CapabilityEntry(
        os_arch="Linux x86_64 (EndeavourOS, kernel 6.18.52-lts, Mesa 26.2.2)",
        gpu_vendor="AMD", gpu_model="Radeon RX 9070", gpu_device_id_hex="0x7550",
        gpu_pci_bus_id="0000:03:00.0",
        model_name="htdemucs.onnx (demucs-onnx)",
        model_sha256="68d0bf16428ef66e692cdff8a9ccf28f1ef3f69440d57e58605a4cc55fcc5e74",
        inference_backend="onnxruntime-ep-webgpu 0.3.0 (WebGpuExecutionProvider), ORT_ENABLE_BASIC required "
                           "(ConvActivationFusion WebGPU-EP bug on ORT_ENABLE_ALL)",
        underlying_graphics_backend="Vulkan (RADV)",
        runtime_version="onnxruntime 1.30.0 + onnxruntime-ep-webgpu 0.3.0",
        theoretically_supported=True, actually_tested=True, found_correct=True, suitable_for_auto=True,
        actual_gpu_execution="Confirmed via onnxruntime placement log across L4-L9",
        physical_gpu_verification="PASS -- kernel-level monitoring (L9 Section 3): RX 9070 avg busy 98.0% during "
                                   "Demucs session.run(), 780M 0%",
        graph_placement="1594/1594 nodes on WebGPU, 0 CPU fallback (L4-L9)",
        numerical_correctness="shifts=0: ONNX CPU vs WebGPU corr>=0.99999 all 4 stems (L4/L5); shifts=2 "
                               "(production default): within 1.0-1.7x PyTorch's own run-to-run noise floor (L6/L7)",
        end_to_end_audio_correctness="PASS",
        stability="PASS -- no crash across L4-L9's repeated runs, including full shifts=2 production settings",
        practical_performance="1.43x-2.2x faster than CPU depending on clip (L4-L7, varies by fixture)",
        vendor_alternative_available=None,
        device_selection_enforceable="PASS -- same as MDX-Net row above",
        evidence="README.md Phase L4-L7 sections; DEMUCS_ONNX_FEASIBILITY.md, DEMUCS_SHIFT_PARITY.md",
    ),
    CapabilityEntry(
        os_arch="Linux x86_64 (EndeavourOS, kernel 6.18.52-lts, Mesa 26.2.2)",
        gpu_vendor="AMD", gpu_model="Radeon 780M (iGPU, Phoenix)", gpu_device_id_hex="0x15bf",
        gpu_pci_bus_id="0000:69:00.0",
        model_name="UVR_MDXNET_KARA_2.onnx", model_sha256=None,
        inference_backend="onnxruntime-ep-webgpu 0.3.0 (WebGpuExecutionProvider), requires the "
                           "Linux Vulkan-Loader isolation adapter (Section 4 below) -- onnxruntime's own "
                           "device-selection API alone does NOT honor this device (L9)",
        underlying_graphics_backend="Vulkan (RADV) -- same single RADV driver instance as the RX 9070",
        runtime_version="onnxruntime 1.30.0 + onnxruntime-ep-webgpu 0.3.0",
        theoretically_supported=True, actually_tested=True, found_correct=True, suitable_for_auto=True,
        actual_gpu_execution="Confirmed via onnxruntime placement log AND (L10) independent kernel-level "
                              "amdgpu busy-percent monitoring: card0 (780M) avg=20.1% max=88%, "
                              "card1 (RX 9070) avg=7.1% max=45% (its ordinary idle baseline) during the full "
                              "pipeline run",
        physical_gpu_verification="PASS -- ONLY when VK_LOADER_DEVICE_ID_FILTER isolation is applied to a fresh "
                                   "subprocess before Vulkan init (L10 Section 6-9); onnxruntime's own device "
                                   "selection alone is proven NOT to honor this device (L9)",
        graph_placement="185/185 nodes on WebGPU, 0 CPU fallback -- identical to RX 9070 (L10 Section 9)",
        numerical_correctness="corr=1.00000000, max_abs_diff=7.08e-08 (vocals) / 6.61e-08 (instrumental) -- "
                               "bit-identical to every other platform's own recorded figures (L10 Section 9)",
        end_to_end_audio_correctness="PASS",
        stability="PASS (L10 Section 9) -- no crash observed for this model at this graph size",
        practical_performance="Faster than CPU on this machine (run=4.33s vs CPU run=7.91s); ~3x slower than "
                               "RX 9070 (run=1.41s, L1-L9 historical, same fixture) -- consistent with genuine, "
                               "distinct iGPU hardware (L10 Section 11)",
        vendor_alternative_available=None,
        device_selection_enforceable="PASS -- ONLY via the Linux-specific VK_LOADER_DEVICE_ID_FILTER subprocess "
                                      "isolation adapter (L10); NOT enforceable via onnxruntime's own API alone",
        evidence="RADEON_780M_DEVICE_ISOLATION.md Section 9",
    ),
    CapabilityEntry(
        os_arch="Linux x86_64 (EndeavourOS, kernel 6.18.52-lts, Mesa 26.2.2)",
        gpu_vendor="AMD", gpu_model="Radeon 780M (iGPU, Phoenix)", gpu_device_id_hex="0x15bf",
        gpu_pci_bus_id="0000:69:00.0",
        model_name="htdemucs.onnx (demucs-onnx)",
        model_sha256="68d0bf16428ef66e692cdff8a9ccf28f1ef3f69440d57e58605a4cc55fcc5e74",
        inference_backend="onnxruntime-ep-webgpu 0.3.0 (WebGpuExecutionProvider), ORT_ENABLE_BASIC, "
                           "Linux Vulkan-Loader isolation adapter",
        underlying_graphics_backend="Vulkan (RADV) -- same single RADV driver instance as the RX 9070",
        runtime_version="onnxruntime 1.30.0 + onnxruntime-ep-webgpu 0.3.0",
        theoretically_supported=True, actually_tested=True, found_correct=False, suitable_for_auto=False,
        actual_gpu_execution="Confirmed genuine, sustained 780M execution up to the crash (kernel monitor: "
                              "card0 avg=81.6% max=99% over 4,567 samples) -- isolation itself worked correctly",
        physical_gpu_verification="PASS (isolation confirmed genuine right up to the crash) -- but the run itself "
                                   "does not complete (see stability)",
        graph_placement="1594/1594 nodes on WebGPU, 0 CPU fallback -- confirmed on the 2s diagnostic clip that "
                         "did complete (L10 Section 10)",
        numerical_correctness="NOT VALID -- only a 2.0s diagnostic clip completed, far shorter than htdemucs's "
                               "expected context window; CPU-vs-WebGPU comparison on it produced NaN "
                               "correlations and abs-diffs up to 0.71, explicitly not usable as equivalence "
                               "evidence at ANY input length (L10 Section 10)",
        end_to_end_audio_correctness="NOT TESTED -- blocked by the crash below",
        stability="BLOCKED -- the full 16.7s (realistic-length) clip crashes with VK_ERROR_DEVICE_LOST "
                   "partway through genuine, correctly-isolated 780M execution. Root-caused (not left "
                   "unexplained): a 2s clip on the identical mechanism completes but takes 221.5s "
                   "(~114x slower than CPU's 1.95s on the same clip), consistent with a Vulkan/kernel "
                   "GPU-hang-watchdog timeout on an oversized single dispatch, not an isolation, "
                   "compatibility, or memory failure (L10 Section 10)",
        practical_performance="~114x SLOWER than CPU on the only workload size that completed (2s clip: "
                               "221.50s WebGPU vs 1.95s CPU) -- and the realistic-length input does not "
                               "complete at all. Explicitly disqualifying per the L11 brief's own litmus "
                               "('a model that technically works but is 114x slower than CPU is not a "
                               "practical Auto route')",
        vendor_alternative_available=None,
        device_selection_enforceable="PASS for device targeting itself (isolation works) -- but the model is "
                                      "not viable on this GPU regardless of targeting, so this is moot for Auto",
        evidence="RADEON_780M_DEVICE_ISOLATION.md Section 10",
    ),
    CapabilityEntry(
        os_arch="macOS 26.7 (build 25G229), arm64, no Rosetta",
        gpu_vendor="Apple", gpu_model="Apple M1 (integrated, unified memory)",
        gpu_device_id_hex=None, gpu_pci_bus_id=None,
        model_name="UVR_MDXNET_KARA_2.onnx", model_sha256=None,
        inference_backend="onnxruntime-ep-webgpu 0.3.0 (WebGpuExecutionProvider)",
        underlying_graphics_backend="Metal",
        runtime_version="onnxruntime 1.30.0 + onnxruntime-ep-webgpu 0.3.0",
        theoretically_supported=True, actually_tested=True, found_correct=True, suitable_for_auto=True,
        actual_gpu_execution="Confirmed via onnxruntime placement log + Dawn Metal dispatch log (named GPU "
                              "programs: Conv2dMM, Transpose, BatchNormalization, MatMul) (M1.4)",
        physical_gpu_verification="PASS -- binary-level: otool -L on libonnxruntime_providers_webgpu.dylib links "
                                   "ONLY Metal.framework (no Vulkan/MoltenVK); embedded Dawn Metal backend source "
                                   "paths present in the binary (M1.4). Single-GPU system: no multi-adapter "
                                   "selection ambiguity exists to disprove, unlike the Linux multi-GPU case",
        graph_placement="185/185 nodes on WebGPU, 0 CPU fallback -- identical node count to Linux (M1.6)",
        numerical_correctness="corr=1.00000000, max_abs_diff=3.58e-07 (vocals) / 3.28e-07 (instrumental) vs CPU EP",
        end_to_end_audio_correctness="PASS",
        stability="PASS",
        practical_performance="1.68x faster than CPU (warm median, M1.7) -- modest vs Linux's 5.75x, plausibly "
                               "clip-length/hardware-throughput related, not resolved further (M1.7)",
        vendor_alternative_available="CoreMLExecutionProvider checked informationally (M1.9): single uncontrolled "
                                      "run was SLOWER than both CPU and WebGPU here, and numerically looser "
                                      "(3 orders of magnitude); not rigorous enough to call a proven alternative "
                                      "either way -- no established production MPS/CoreML MDX-Net route found "
                                      "in STEMwerk's own source (README Section 2)",
        device_selection_enforceable="N/A -- single WebGPU-capable adapter on this hardware class; "
                                      "select_device()'s existing auto-pick-only-device path suffices, "
                                      "no isolation mechanism needed or applicable",
        evidence="README.md Phase M1 section (M1.1-M1.11)",
    ),
    CapabilityEntry(
        os_arch="macOS 26.7 (build 25G229), arm64, no Rosetta",
        gpu_vendor="Apple", gpu_model="Apple M1 (integrated, unified memory)",
        gpu_device_id_hex=None, gpu_pci_bus_id=None,
        model_name="htdemucs.onnx (demucs-onnx)",
        model_sha256="68d0bf16428ef66e692cdff8a9ccf28f1ef3f69440d57e58605a4cc55fcc5e74",
        inference_backend="onnxruntime-ep-webgpu 0.3.0 (WebGpuExecutionProvider), ORT_ENABLE_BASIC",
        underlying_graphics_backend="Metal",
        runtime_version="onnxruntime 1.30.0 + onnxruntime-ep-webgpu 0.3.0",
        theoretically_supported=True, actually_tested=True, found_correct=True, suitable_for_auto=False,
        actual_gpu_execution="Confirmed via onnxruntime placement log (L8) -- graph placement and numerics are "
                              "genuinely correct, only performance disqualifies this row",
        physical_gpu_verification="PASS -- same binary-level Metal-only-linkage proof as the MDX-Net row; "
                                   "single-GPU system",
        graph_placement="1594/1594 nodes on WebGPU, 0 CPU fallback -- identical to Linux (L8)",
        numerical_correctness="shifts=0: corr=0.9967-0.9996 vs PyTorch; shifts=2: gap below PyTorch's own "
                               "run-to-run noise floor (ratio 0.67x-0.80x) -- clean (L8)",
        end_to_end_audio_correctness="PASS",
        stability="PASS -- no crash, but see performance",
        practical_performance="WebGPU 49.08s (shifts=2, warm) is SLOWER than plain CPU-ONNX (28.14s) on this "
                               "machine, and ~5.9x slower than STEMwerk's existing production PyTorch/MPS route "
                               "(8.28s) (L8). This is the textbook case the L11 brief's litmus targets: "
                               "technically correct, but not a practical Auto route because it does not even "
                               "beat CPU, let alone the existing vendor backend",
        vendor_alternative_available="PyTorch/MPS -- STEMwerk's actual current production route on this "
                                      "platform, proven decisively faster (8.28s vs WebGPU's 49.08s) (L8)",
        device_selection_enforceable="N/A -- single adapter, not the limiting factor here",
        evidence="README.md Phase L8 section; DEMUCS_MACOS_APPLE_SILICON.md",
    ),
    CapabilityEntry(
        os_arch="Windows 11, x86_64",
        gpu_vendor="NVIDIA", gpu_model="GeForce RTX 3060 Laptop GPU",
        gpu_device_id_hex=None, gpu_pci_bus_id=None,
        model_name="UVR_MDXNET_KARA_2.onnx", model_sha256=None,
        inference_backend="onnxruntime-ep-webgpu 0.3.0 (WebGpuExecutionProvider)",
        underlying_graphics_backend="D3D12",
        runtime_version="onnxruntime 1.30.0 + onnxruntime-ep-webgpu 0.3.0",
        theoretically_supported=True, actually_tested=True, found_correct=True, suitable_for_auto=True,
        actual_gpu_execution="Confirmed via onnxruntime placement log; D3D12 backend confirmed via live "
                              "module-load evidence (W1)",
        physical_gpu_verification="NOT INDEPENDENTLY VERIFIED at the kernel/OS level -- W1 confirmed the D3D12 "
                                   "backend module-load and graph placement, but did NOT run an nvidia-smi-style "
                                   "independent per-process GPU-engine check the way L9/L10 did on Linux. This "
                                   "machine has two GPUs (NVIDIA discrete + AMD iGPU); L9 explicitly flagged this "
                                   "as an open, unaddressed question and it remains open after L11 (out of scope "
                                   "for this slice per instruction)",
        graph_placement="185/185 nodes on WebGPU, 0 CPU fallback -- identical to Linux/macOS (W1)",
        numerical_correctness="Within established tolerances (W1); not restated with exact figures here -- see "
                               "DEMUCS_WINDOWS_NVIDIA.md",
        end_to_end_audio_correctness="PASS",
        stability="PASS",
        practical_performance="5.17x faster than CPU (W1, 4-run warm benchmark)",
        vendor_alternative_available="DirectML (DmlExecutionProvider) -- referenced in STEMwerk's own source "
                                      "(README Section 2) as the existing Windows onnx GPU path, but NOT "
                                      "directly benchmarked against WebGPU in W1 (only vs CPU) -- an open "
                                      "evidence gap, not assumed either way",
        device_selection_enforceable="UNKNOWN / NOT PROVEN -- no Windows-equivalent of the Linux "
                                      "VK_LOADER_DEVICE_ID_FILTER mechanism has been investigated in this "
                                      "project; W1 only tested a scenario where the requested device already "
                                      "matched the plausible default (discrete GPU on a discrete+iGPU laptop)",
        evidence="README.md Phase W1 section; DEMUCS_WINDOWS_NVIDIA.md",
    ),
    CapabilityEntry(
        os_arch="Windows 11, x86_64",
        gpu_vendor="NVIDIA", gpu_model="GeForce RTX 3060 Laptop GPU",
        gpu_device_id_hex=None, gpu_pci_bus_id=None,
        model_name="htdemucs.onnx (demucs-onnx)",
        model_sha256="68d0bf16428ef66e692cdff8a9ccf28f1ef3f69440d57e58605a4cc55fcc5e74",
        inference_backend="onnxruntime-ep-webgpu 0.3.0 (WebGpuExecutionProvider), ORT_ENABLE_BASIC",
        underlying_graphics_backend="D3D12",
        runtime_version="onnxruntime 1.30.0 + onnxruntime-ep-webgpu 0.3.0",
        theoretically_supported=True, actually_tested=True, found_correct=True, suitable_for_auto=False,
        actual_gpu_execution="Confirmed via onnxruntime placement log (W1)",
        physical_gpu_verification="NOT INDEPENDENTLY VERIFIED at the kernel/OS level -- same caveat as the "
                                   "MDX-Net row above",
        graph_placement="1594/1594 nodes on WebGPU, 0 CPU fallback (W1)",
        numerical_correctness="Within established tolerances, with one disclosed caveat: the W1 fixture is "
                               "mostly-instrumental, so vocals/other parity numbers are dominated by "
                               "near-silence rather than export fidelity (DEMUCS_WINDOWS_NVIDIA.md Section 6e)",
        end_to_end_audio_correctness="PASS",
        stability="PASS",
        practical_performance="1.39x-1.75x faster than CPU, but ~4.8x SLOWER than STEMwerk's existing "
                               "production PyTorch/CUDA route on this hardware (W1) -- faster than CPU, "
                               "so not disqualified by the brief's strict litmus, but decisively beaten by "
                               "the already-shipping vendor backend",
        vendor_alternative_available="PyTorch/CUDA -- STEMwerk's actual current production route on this "
                                      "platform, proven decisively faster (~4.8x) (W1)",
        device_selection_enforceable="UNKNOWN / NOT PROVEN -- same caveat as the MDX-Net row above",
        evidence="README.md Phase W1 section; DEMUCS_WINDOWS_NVIDIA.md",
    ),
]


def lookup(os_arch_substr: str, gpu_model_substr: str, model_name_substr: str) -> Optional[CapabilityEntry]:
    """Case-insensitive substring match on the three identity fields. Returns None (not
    an exception, not a guess) if no matrix entry exists for this combination -- callers
    (the resolver) must treat that as genuinely UNKNOWN, not as a green light."""
    for e in MATRIX:
        if (gpu_model_substr.lower() in e.gpu_model.lower()
                and model_name_substr.lower() in e.model_name.lower()
                and os_arch_substr.lower() in e.os_arch.lower()):
            return e
    return None


def to_json_dicts() -> list[dict]:
    return [dataclasses.asdict(e) for e in MATRIX]


def write_json(path: pathlib.Path) -> None:
    path.write_text(json.dumps(to_json_dicts(), indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


if __name__ == "__main__":
    out = pathlib.Path(__file__).parent / "capability_matrix.json"
    write_json(out)
    print(f"Wrote {len(MATRIX)} entries to {out}")
