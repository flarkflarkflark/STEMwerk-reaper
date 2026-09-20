"""
Phase L2 section 6: fair CPU EP vs WebGPU EP benchmark on the real end-to-end
audio-separator pipeline (same ONNX model, same audio, same pre/post-processing --
see webgpu_adapter.py and README.md for why that's true here). Separates:
  1. session/environment init (load_model)
  2. first ("cold") separate() call, which for WebGPU includes first-dispatch
     shader compilation
  3. warm separate() calls (session + shaders already compiled/cached)
and reports median + min/max spread across repeats, plus RAM/VRAM/GPU-utilization
via resource_sampler.py (with its built-in reliability caveats).

Usage:
    python benchmark_resources.py <input.wav> [--model-cache DIR] [--out-dir DIR] [--runs N]
"""
import argparse
import json
import os
import statistics
import sys
import time

import soundfile as sf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from webgpu_adapter import patch_inference_session_for_provider_swap, select_device, GpuExecutionNotProvenError  # noqa: E402
from resource_sampler import ResourceSampler  # noqa: E402

import onnxruntime as ort  # noqa: E402

MODEL_FILENAME = "UVR_MDXNET_KARA_2.onnx"

def bench_provider(label, providers, input_wav, model_cache, out_dir, runs, sampler_kwargs, torch_device=None):
    from audio_separator.separator import Separator

    provider_out_dir = os.path.join(out_dir, label)
    os.makedirs(provider_out_dir, exist_ok=True)
    sep = Separator(log_level=100, model_file_dir=model_cache, output_dir=provider_out_dir,
                     sample_rate=44100, use_soundfile=True)
    if torch_device is not None:
        import torch
        sep.torch_device = torch.device(torch_device)
        sep.torch_device_cpu = torch.device("cpu")
    sep.onnx_execution_provider = providers

    with ResourceSampler(**sampler_kwargs) as load_sampler:
        t0 = time.time()
        sep.load_model(MODEL_FILENAME)
        t1 = time.time()
    load_time_s = t1 - t0

    run_times = []
    run_samplers = []
    for i in range(runs):
        with ResourceSampler(**sampler_kwargs) as sampler:
            t0 = time.time()
            sep.separate(input_wav)
            t1 = time.time()
        run_times.append(t1 - t0)
        run_samplers.append(sampler.summary())

    warm_times = run_times[1:] if len(run_times) > 1 else run_times
    return {
        "label": label,
        "torch_device": str(sep.model_instance.torch_device),
        "load_time_s": load_time_s,
        "load_resources": load_sampler.summary(),
        "run_times_s": run_times,
        "first_run_s": run_times[0],
        "warm_median_s": statistics.median(warm_times),
        "warm_min_s": min(warm_times),
        "warm_max_s": max(warm_times),
        "warm_stdev_s": statistics.stdev(warm_times) if len(warm_times) > 1 else 0.0,
        "run_resources": run_samplers,
        # peak across all runs for this provider, for a single headline VRAM number
        "peak_vram_attributable_delta_mb": max(
            (s["vram"]["attributable_delta_mb"] for s in run_samplers if s["vram"]["attributable_delta_mb"] is not None),
            default=None,
        ),
        "peak_rss_mb": max((s["rss"]["peak_mb"] for s in run_samplers if s["rss"]["peak_mb"] is not None), default=None),
        "avg_gpu_util_pct": statistics.mean(
            [s["gpu_util_pct"]["avg"] for s in run_samplers if s["gpu_util_pct"]["avg"] is not None]
        ) if any(s["gpu_util_pct"]["avg"] is not None for s in run_samplers) else None,
    }


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("input_wav")
    ap.add_argument("--model-cache", default="/home/flark/stemwerk-rnd/venvs/webgpu-ep/model-cache")
    ap.add_argument("--out-dir", default="/tmp/stemwerk-webgpu-l2/resources")
    ap.add_argument("--runs", type=int, default=4)
    ap.add_argument("--pci-bus-id", default=None, help="Linux/multi-GPU only; omit on macOS/single-GPU systems")
    ap.add_argument("--device-id", type=int, default=None,
                     help="Windows/multi-GPU only (no pci_bus_id metadata under Dawn/D3D12); "
                          "omit on macOS/single-GPU systems")
    ap.add_argument(
        "--gpu-monitor-backend", choices=("auto", "rocm", "nvidia"), default="auto",
        help="Whole-GPU resource monitor. 'auto' preserves the historical behavior: "
             "nvidia-smi on Windows, rocm-smi elsewhere. Use 'nvidia' explicitly on Linux/NVIDIA.",
    )
    ap.add_argument("--nvidia-gpu-index", type=int, default=0,
                    help="nvidia-smi GPU index when --gpu-monitor-backend=nvidia (default: 0)")
    ap.add_argument("--rocm-card-key", default="card0",
                    help="rocm-smi JSON card key when --gpu-monitor-backend=rocm (default: card0)")
    ap.add_argument("--torch-device", default=None,
                    help="Optional explicit PyTorch device for MDX STFT/iSTFT (for example 'cpu'); "
                         "the ONNX inference provider is selected independently")
    args = ap.parse_args()

    monitor_backend = args.gpu_monitor_backend
    if monitor_backend == "auto":
        monitor_backend = "nvidia" if sys.platform == "win32" else "rocm"
    sampler_kwargs = (
        {"gpu_backend": "nvidia", "nvidia_gpu_index": args.nvidia_gpu_index}
        if monitor_backend == "nvidia"
        else {"gpu_backend": "rocm", "card_key": args.rocm_card_key}
    )

    original_cls, gpu_reports = patch_inference_session_for_provider_swap(
        lambda: select_device(pci_bus_id=args.pci_bus_id, device_id=args.device_id)
    )

    results = {}
    try:
        for label, providers in [("cpu", ["CPUExecutionProvider"]), ("webgpu", ["WebGpuExecutionProvider"])]:
            print(f"=== Benchmarking {label} ({args.runs} runs) ===")
            results[label] = bench_provider(
                label, providers, args.input_wav, args.model_cache, args.out_dir, args.runs,
                sampler_kwargs, args.torch_device,
            )
            r = results[label]
            print(f"  load={r['load_time_s']:.2f}s first_run={r['first_run_s']:.2f}s "
                  f"warm_median={r['warm_median_s']:.2f}s (min={r['warm_min_s']:.2f} max={r['warm_max_s']:.2f} "
                  f"stdev={r['warm_stdev_s']:.3f}) torch_device={r['torch_device']}")
            print(f"  peak_rss={r['peak_rss_mb']:.1f}MB peak_vram_delta={r['peak_vram_attributable_delta_mb']}"
                  f"{'MB' if r['peak_vram_attributable_delta_mb'] is not None else ''} "
                  f"avg_gpu_util={r['avg_gpu_util_pct']}%")

        if len(gpu_reports) != 1:
            raise GpuExecutionNotProvenError(f"Expected exactly 1 verified WebGPU session for the whole benchmark "
                                              f"(session should be created once in load_model and reused across all "
                                              f"{args.runs} separate() calls), got {len(gpu_reports)}.")
        print(f"=== GPU execution proof (one session, reused across all {args.runs} runs): "
              f"{gpu_reports[0]['all_nodes_placed_line']} ===")
        results["gpu_execution_proof"] = gpu_reports[0]

        clip_duration_s = sf.info(args.input_wav).duration
        cpu_rtf = clip_duration_s / results["cpu"]["warm_median_s"]
        gpu_rtf = clip_duration_s / results["webgpu"]["warm_median_s"]
        print(f"=== Real-time factor ({clip_duration_s:.2f}s test clip): CPU={cpu_rtf:.1f}x  WebGPU={gpu_rtf:.1f}x "
              f"({gpu_rtf/cpu_rtf:.2f}x speedup) ===")
        results["speedup_warm_median"] = results["cpu"]["warm_median_s"] / results["webgpu"]["warm_median_s"]

    finally:
        ort.InferenceSession = original_cls

    os.makedirs(args.out_dir, exist_ok=True)
    out_path = os.path.join(args.out_dir, "resource_benchmark.json")
    with open(out_path, "w") as f:
        json.dump(results, f, indent=2, default=str)
    print(f"=== Full report: {out_path} ===")
