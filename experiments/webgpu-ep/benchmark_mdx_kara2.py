"""
Step 2 of the WebGPU EP experiment: real end-to-end audio separation with
UVR_MDXNET_KARA_2.onnx (a genuine ONNX MDX-Net model from STEMwerk's model
catalog, downloaded through the same `audio-separator` library STEMwerk uses
in production) on CPUExecutionProvider vs the native WebGPU EP (AMD RX 9070).

This script runs entirely OUTSIDE the STEMwerk production code path. It does
not modify, import, or depend on any STEMwerk-core/stemwerk-reaper module. It
reuses audio-separator's own MDXSeparator unchanged -- preprocessing (STFT,
chunking) and postprocessing (overlap-add, inverse STFT) are byte-identical
between the CPU and WebGPU runs. The ONLY thing that differs is how the
underlying onnxruntime.InferenceSession is constructed, via a monkeypatch of
onnxruntime.InferenceSession that intercepts the "WebGpuExecutionProvider"
provider name and routes it through the new plugin-EP device-targeted API
(`add_provider_for_devices`), since the classic string-based `providers=[...]`
argument audio-separator's MDXSeparator.load_model() uses does NOT activate a
plugin EP (see README.md, "onbekende valkuil" section) -- it silently falls
back to CPU with a misleading warning about missing CUDA/cuDNN.

Usage:
    python benchmark_mdx_kara2.py <input.wav> [--model-cache DIR] [--out-dir DIR] [--runs N]

Requires an existing, real audio file as input (not included in this repo --
see README.md for how a suitable short WAV was sourced for the original run).
"""
import argparse
import json
import logging
import os
import time

import numpy as np
import onnxruntime as ort
import onnxruntime_ep_webgpu as webgpu_ep
import soundfile as sf

logging.disable(logging.CRITICAL)

ort.register_execution_provider_library("webgpu", webgpu_ep.get_library_path())
_OrigInferenceSession = ort.InferenceSession
_rx9070_device = None


def _get_target_device(pci_bus_id):
    global _rx9070_device
    if _rx9070_device is None:
        devices = ort.get_ep_devices()
        _rx9070_device = next(
            d for d in devices
            if d.ep_name == webgpu_ep.get_ep_name() and d.device.metadata.get("pci_bus_id") == pci_bus_id
        )
    return _rx9070_device


NODE_PLACEMENT_LOG = []
TARGET_PCI_BUS_ID = os.environ.get("WEBGPU_EP_TARGET_PCI_BUS_ID", "0000:03:00.0")


class PatchedInferenceSession(_OrigInferenceSession):
    def __init__(self, path_or_bytes, sess_options=None, providers=None, provider_options=None, **kwargs):
        if providers and "WebGpuExecutionProvider" in providers:
            so = sess_options or ort.SessionOptions()
            so.log_severity_level = 0  # verbose: capture per-node placement / fallback warnings
            so.add_provider_for_devices([_get_target_device(TARGET_PCI_BUS_ID)], {})
            super().__init__(path_or_bytes, sess_options=so, **kwargs)
        else:
            super().__init__(path_or_bytes, sess_options=sess_options, providers=providers, provider_options=provider_options, **kwargs)
        NODE_PLACEMENT_LOG.append((providers, self.get_providers()))


ort.InferenceSession = PatchedInferenceSession

from audio_separator.separator import Separator  # noqa: E402 (must import after the patch above)

MODEL_FILENAME = "UVR_MDXNET_KARA_2.onnx"


def run(provider_list, input_wav, model_cache, out_dir, warm_runs=1):
    os.makedirs(out_dir, exist_ok=True)
    sep = Separator(log_level=100, model_file_dir=model_cache, output_dir=out_dir, sample_rate=44100)
    # Must be set BEFORE load_model(): Separator.load_model() bakes onnx_execution_provider
    # into the MDXSeparator constructor's common_params, which triggers session creation
    # inside __init__. This mirrors STEMwerk production's own pattern of setting
    # separator.onnx_execution_provider before running separation (see architecture notes
    # in README.md re: stemwerk_core/separator.py and stemwerk_drumsep_process.py).
    sep.onnx_execution_provider = provider_list

    t_load0 = time.time()
    sep.load_model(MODEL_FILENAME)
    t_load1 = time.time()

    times = []
    output_files = None
    for _ in range(warm_runs):
        t0 = time.time()
        output_files = sep.separate(input_wav)
        t1 = time.time()
        times.append(t1 - t0)

    return {
        "output_files": output_files,
        "load_time_s": t_load1 - t_load0,
        "run_times_s": times,
        "first_run_s": times[0],
        "warm_avg_s": (sum(times[1:]) / len(times[1:])) if len(times) > 1 else times[0],
    }


def compare_outputs(cpu_dir, gpu_dir, filenames):
    print("=== Numerical comparison (CPU EP vs WebGPU EP) ===")
    for name in filenames:
        a, sr_a = sf.read(os.path.join(cpu_dir, name))
        b, sr_b = sf.read(os.path.join(gpu_dir, name))
        n = min(len(a), len(b))
        a, b = a[:n].astype(np.float64), b[:n].astype(np.float64)
        diff = np.abs(a - b)
        corr = np.corrcoef(a.flatten(), b.flatten())[0, 1]
        rms_a, rms_b = np.sqrt(np.mean(a**2)), np.sqrt(np.mean(b**2))
        print(f"{name}: max_abs_diff={diff.max():.8f} mean_abs_diff={diff.mean():.8f} "
              f"RMS_diff%={100*abs(rms_a-rms_b)/rms_a:.4f}% correlation={corr:.10f}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("input_wav")
    ap.add_argument("--model-cache", default="/tmp/stemwerk-webgpu-experiment/model-cache")
    ap.add_argument("--out-dir", default="/tmp/stemwerk-webgpu-experiment/out")
    ap.add_argument("--runs", type=int, default=4, help="separate() calls per provider (first = cold, rest = warm avg)")
    args = ap.parse_args()

    results = {}
    for label, providers in [("cpu", ["CPUExecutionProvider"]), ("webgpu", ["WebGpuExecutionProvider"])]:
        print(f"=== {label} EP run ===")
        out_dir = os.path.join(args.out_dir, label)
        results[label] = run(providers, args.input_wav, args.model_cache, out_dir, warm_runs=args.runs)
        print(json.dumps(results[label], indent=2, default=str))

    print("=== NODE_PLACEMENT_LOG (requested -> actual session providers) ===")
    for req, actual in NODE_PLACEMENT_LOG:
        print(req, "->", actual)

    filenames = [os.path.basename(f) for f in results["cpu"]["output_files"]]
    compare_outputs(os.path.join(args.out_dir, "cpu"), os.path.join(args.out_dir, "webgpu"), filenames)
