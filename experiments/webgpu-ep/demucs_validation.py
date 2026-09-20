"""Validate the established htdemucs ONNX artifact on CPU and native WebGPU.

This runner deliberately uses the existing ``demucs_shift_wrapper`` and the
``ORT_ENABLE_BASIC`` workaround documented since Phase L4.  It does not download or
modify a model: callers pass the SHA-verified ONNX path explicitly.  Machine-specific
audio, stems, logs, and JSON output must be directed outside the repository.
"""
import argparse
import contextlib
import hashlib
import json
import math
import os
import statistics
import sys
import time

import numpy as np
import onnxruntime as ort
import soundfile as sf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from demucs_shift_wrapper import run_with_seed  # noqa: E402
from resource_sampler import ResourceSampler  # noqa: E402
from webgpu_adapter import (  # noqa: E402
    GpuExecutionNotProvenError,
    _libc_for_fflush,
    patch_inference_session_for_provider_swap,
    select_device,
)

EXPECTED_MODEL_SHA256 = "68d0bf16428ef66e692cdff8a9ccf28f1ef3f69440d57e58605a4cc55fcc5e74"
SOURCES = ("drums", "bass", "other", "vocals")
MIN_CORRELATION = 0.999
MAX_ABS_DIFF = 5e-3


@contextlib.contextmanager
def suppress_native_stderr():
    """Discard verbose per-dispatch ORT logs after placement has been captured."""
    saved = os.dup(2)
    null_fd = os.open(os.devnull, os.O_WRONLY)
    try:
        os.dup2(null_fd, 2)
        yield
    finally:
        _libc_for_fflush().fflush(None)
        os.dup2(saved, 2)
        os.close(saved)
        os.close(null_fd)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def compare(a, b):
    a64 = np.asarray(a, dtype=np.float64)
    b64 = np.asarray(b, dtype=np.float64)
    diff = a64 - b64
    rms_a = float(np.sqrt(np.mean(a64 * a64)))
    return {
        "correlation": float(np.corrcoef(a64.ravel(), b64.ravel())[0, 1]),
        "max_abs_diff": float(np.max(np.abs(diff))),
        "mae": float(np.mean(np.abs(diff))),
        "rmse": float(np.sqrt(np.mean(diff * diff))),
        "relative_rms_pct": float(100 * np.sqrt(np.mean(diff * diff)) / rms_a) if rms_a else math.nan,
    }


def validate_stems(stems, sample_rate, expected_samples):
    result = {}
    for name in SOURCES:
        data = stems[name]
        result[name] = {
            "shape": list(data.shape),
            "sample_rate": sample_rate,
            "duration_s": data.shape[1] / sample_rate,
            "rms": float(np.sqrt(np.mean(data.astype(np.float64) ** 2))),
            "peak": float(np.max(np.abs(data))),
            "finite": bool(np.isfinite(data).all()),
            "non_silent": bool(np.sqrt(np.mean(data.astype(np.float64) ** 2)) > 1e-6),
            "expected_shape": bool(data.shape == (2, expected_samples)),
        }
    return result


def validate_wav(path, expected_samples, expected_sample_rate):
    data, sample_rate = sf.read(path, always_2d=True)
    rms = float(np.sqrt(np.mean(data.astype(np.float64) ** 2)))
    peak = float(np.max(np.abs(data)))
    issues = []
    if sample_rate != expected_sample_rate:
        issues.append(f"sample rate {sample_rate} != {expected_sample_rate}")
    if data.shape != (expected_samples, 2):
        issues.append(f"shape {data.shape} != ({expected_samples}, 2)")
    if not np.isfinite(data).all():
        issues.append("NaN or Inf")
    if rms <= 1e-6:
        issues.append(f"unexpected silence (RMS {rms})")
    if peak > 0.999:
        issues.append(f"clipping (peak {peak})")
    return {"path": path, "sample_rate": sample_rate, "shape": list(data.shape),
            "rms": rms, "peak": peak, "issues": issues}


def run_once(session, mix, shifts, seed, sampler_kwargs):
    with ResourceSampler(interval_s=0.2, **sampler_kwargs) as sampler:
        cpu_start = time.process_time()
        wall_start = time.perf_counter()
        with suppress_native_stderr():
            stems, offsets = run_with_seed(
                session, SOURCES, mix, shifts=shifts, seed=seed, progress=False, verbose=False
            )
        wall_s = time.perf_counter() - wall_start
        cpu_s = time.process_time() - cpu_start
    return stems, {
        "wall_s": wall_s,
        "process_cpu_s": cpu_s,
        "process_cpu_util_core_pct": 100 * cpu_s / wall_s if wall_s else None,
        "offsets": offsets,
        "resources": sampler.summary(),
    }


def routing_matrix(cpu_stems, gpu_stems):
    matrix = {}
    passed = True
    for expected in SOURCES:
        row = {candidate: compare(cpu_stems[expected], gpu_stems[candidate])["correlation"]
               for candidate in SOURCES}
        matrix[expected] = row
        passed = passed and row[expected] > max(v for k, v in row.items() if k != expected)
    return passed, matrix


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input_wav")
    parser.add_argument("model_onnx")
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--pci-bus-id", default=None)
    parser.add_argument("--device-id", type=int, default=None)
    parser.add_argument("--seeds", type=int, nargs="+", default=[111, 222, 333])
    parser.add_argument("--shifts", type=int, default=2)
    parser.add_argument("--nvidia-gpu-index", type=int, default=0)
    args = parser.parse_args()

    model_hash = sha256_file(args.model_onnx)
    if model_hash != EXPECTED_MODEL_SHA256:
        raise RuntimeError(f"unexpected model SHA-256: {model_hash}")

    from demucs_onnx._audio import load_audio, write_wav

    mix, native_sr = load_audio(args.input_wav, target_sr=44100)
    if native_sr != 44100:
        raise RuntimeError(f"this controlled validation expects 44100 Hz input, got {native_sr}")
    sampler_kwargs = {"gpu_backend": "nvidia", "nvidia_gpu_index": args.nvidia_gpu_index}

    cpu_options = ort.SessionOptions()
    cpu_options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
    cpu_init_start = time.perf_counter()
    cpu_session = ort.InferenceSession(
        args.model_onnx, sess_options=cpu_options, providers=["CPUExecutionProvider"]
    )
    cpu_init_s = time.perf_counter() - cpu_init_start

    original_class, placement_reports = patch_inference_session_for_provider_swap(
        lambda: select_device(pci_bus_id=args.pci_bus_id, device_id=args.device_id),
        graph_optimization_level=ort.GraphOptimizationLevel.ORT_ENABLE_BASIC,
    )
    try:
        gpu_init_start = time.perf_counter()
        gpu_session = ort.InferenceSession(args.model_onnx, providers=["WebGpuExecutionProvider"])
        gpu_init_s = time.perf_counter() - gpu_init_start
    finally:
        ort.InferenceSession = original_class
    if len(placement_reports) != 1:
        raise GpuExecutionNotProvenError(f"expected one placement report, got {len(placement_reports)}")

    # A deterministic no-shift run establishes first-inference and raw backend parity.
    cpu_zero, cpu_zero_metrics = run_once(cpu_session, mix, 0, 0, sampler_kwargs)
    gpu_zero, gpu_zero_metrics = run_once(gpu_session, mix, 0, 0, sampler_kwargs)

    seeded = []
    last_cpu = last_gpu = None
    for seed in args.seeds:
        cpu_stems, cpu_metrics = run_once(cpu_session, mix, args.shifts, seed, sampler_kwargs)
        gpu_stems, gpu_metrics = run_once(gpu_session, mix, args.shifts, seed, sampler_kwargs)
        seeded.append({
            "seed": seed,
            "cpu": cpu_metrics,
            "webgpu": gpu_metrics,
            "comparison": {name: compare(cpu_stems[name], gpu_stems[name]) for name in SOURCES},
        })
        last_cpu, last_gpu = cpu_stems, gpu_stems

    routing_ok, routing = routing_matrix(last_cpu, last_gpu)
    os.makedirs(args.out_dir, exist_ok=True)
    wav_validation = {"cpu": {}, "webgpu": {}}
    for provider, stems in (("cpu", last_cpu), ("webgpu", last_gpu)):
        provider_dir = os.path.join(args.out_dir, provider)
        os.makedirs(provider_dir, exist_ok=True)
        for name in SOURCES:
            wav_path = os.path.join(provider_dir, f"{name}.wav")
            write_wav(wav_path, stems[name], native_sr)
            wav_validation[provider][name] = validate_wav(wav_path, mix.shape[1], native_sr)

    array_validation = {
        "cpu": validate_stems(last_cpu, native_sr, mix.shape[1]),
        "webgpu": validate_stems(last_gpu, native_sr, mix.shape[1]),
    }
    comparisons = [
        comparison
        for run in seeded
        for comparison in run["comparison"].values()
    ] + [compare(cpu_zero[name], gpu_zero[name]) for name in SOURCES]
    numerical_ok = all(
        item["correlation"] >= MIN_CORRELATION and item["max_abs_diff"] <= MAX_ABS_DIFF
        for item in comparisons
    )
    arrays_ok = all(
        item["finite"] and item["non_silent"] and item["expected_shape"]
        for provider in array_validation.values() for item in provider.values()
    )
    wavs_ok = all(
        not item["issues"] for provider in wav_validation.values() for item in provider.values()
    )

    report = {
        "model": {"path": os.path.abspath(args.model_onnx), "sha256": model_hash,
                  "size_bytes": os.path.getsize(args.model_onnx)},
        "input": {"path": os.path.abspath(args.input_wav), "sample_rate": native_sr,
                  "samples": int(mix.shape[1]), "duration_s": mix.shape[1] / native_sr},
        "settings": {"graph_optimization_level": "ORT_ENABLE_BASIC", "shifts": args.shifts,
                     "seeds": args.seeds, "sources": list(SOURCES),
                     "tolerances": {"min_correlation": MIN_CORRELATION,
                                    "max_abs_diff": MAX_ABS_DIFF}},
        "session_init_s": {"cpu": cpu_init_s, "webgpu": gpu_init_s},
        "providers": {"cpu": cpu_session.get_providers(), "webgpu": gpu_session.get_providers()},
        "gpu_execution_proof": placement_reports[0],
        "shifts_zero": {
            "cpu": cpu_zero_metrics,
            "webgpu": gpu_zero_metrics,
            "comparison": {name: compare(cpu_zero[name], gpu_zero[name]) for name in SOURCES},
        },
        "seeded_runs": seeded,
        "routing": {"passed": routing_ok, "matrix": routing},
        "validation": {"arrays": array_validation, "wav_files": wav_validation},
        "performance": {
            "cpu_warm_median_s": statistics.median(x["cpu"]["wall_s"] for x in seeded),
            "webgpu_warm_median_s": statistics.median(x["webgpu"]["wall_s"] for x in seeded),
        },
    }
    report["performance"]["cpu_rtf"] = report["input"]["duration_s"] / report["performance"]["cpu_warm_median_s"]
    report["performance"]["webgpu_rtf"] = report["input"]["duration_s"] / report["performance"]["webgpu_warm_median_s"]
    report["performance"]["speedup_vs_cpu"] = (
        report["performance"]["cpu_warm_median_s"] / report["performance"]["webgpu_warm_median_s"]
    )
    report["passed"] = bool(routing_ok and numerical_ok and arrays_ok and wavs_ok)

    report_path = os.path.join(args.out_dir, "demucs_validation.json")
    with open(report_path, "w") as handle:
        json.dump(report, handle, indent=2)
    print(json.dumps({
        "report": report_path,
        "placement": placement_reports[0]["all_nodes_placed_line"],
        "routing_passed": routing_ok,
        "passed": report["passed"],
        "performance": report["performance"],
        "shifts_zero_comparison": report["shifts_zero"]["comparison"],
    }, indent=2))
    if not report["passed"]:
        raise RuntimeError(f"Demucs validation failed; inspect {report_path}")


if __name__ == "__main__":
    main()
