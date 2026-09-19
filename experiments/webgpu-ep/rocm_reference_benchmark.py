"""
Phase L2 section 6, ROCm reference: SAME ONNX graph (UVR_MDXNET_KARA_2.onnx), SAME
audio-separator pipeline, SAME input audio, but ROCMExecutionProvider instead of
CPU/WebGPU. This is a genuine same-model backend comparison (not the broader
pipeline reference the brief allows as a fallback) -- ROCMExecutionProvider loaded
and 139/139 graph nodes placed on it in a preflight check.

Runs in a SEPARATE, isolated venv (/home/flark/stemwerk-rnd/venvs/webgpu-ep-rocmref/)
with `onnxruntime-rocm` installed instead of the base `onnxruntime` +
`onnxruntime-ep-webgpu` used by the main WebGPU experiment venv, specifically so this
never risks destabilizing the already-verified WebGPU setup. Nothing in either
production STEMwerk venv is touched.

Usage:
    python rocm_reference_benchmark.py <input.wav> [--model-cache DIR] [--out-dir DIR] [--runs N]
"""
import argparse
import json
import os
import re
import sys
import time

import numpy as np
import onnxruntime as ort
import soundfile as sf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from resource_sampler import ResourceSampler  # noqa: E402

MODEL_FILENAME = "UVR_MDXNET_KARA_2.onnx"
_NODE_PLACEMENT_RE = re.compile(r"All nodes placed on \[(?P<ep>[^\]]+)\]\. Number of nodes: (?P<n>\d+)")


def verify_rocm_session(model_path):
    """Same verification standard as webgpu_adapter.py: log-capture, not just get_providers()."""
    import contextlib
    import ctypes
    import tempfile

    @contextlib.contextmanager
    def capture_stderr_fd():
        tmp = tempfile.NamedTemporaryFile(mode="w+", suffix=".ortlog", delete=False)
        saved_fd = os.dup(2)
        try:
            os.dup2(tmp.fileno(), 2)
            yield tmp.name
        finally:
            ctypes.CDLL(None).fflush(None)
            os.dup2(saved_fd, 2)
            os.close(saved_fd)
            tmp.close()

    so = ort.SessionOptions()
    so.log_severity_level = 0
    with capture_stderr_fd() as log_path:
        session = ort.InferenceSession(model_path, providers=["ROCMExecutionProvider", "CPUExecutionProvider"], sess_options=so)
    with open(log_path, "r", errors="replace") as f:
        log_text = f.read()
    os.unlink(log_path)

    match = _NODE_PLACEMENT_RE.search(log_text)
    if "ROCMExecutionProvider" not in session.get_providers():
        raise RuntimeError(f"ROCMExecutionProvider not active: {session.get_providers()}")
    if not match or match.group("ep") != "ROCMExecutionProvider":
        raise RuntimeError(f"Could not prove all-nodes-on-ROCm placement. Log excerpt around placement: "
                            f"{[l for l in log_text.splitlines() if 'placed on' in l or 'Node placements' in l]}")
    return session, {"all_nodes_placed_line": match.group(0), "all_nodes_count": int(match.group("n")),
                      "session_providers": session.get_providers()}


def run(input_wav, model_cache, out_dir, runs):
    from audio_separator.separator import Separator
    import audio_separator.separator.common_separator as common_separator_module
    import audio_separator.separator.architectures.mdx_separator as mdx_separator_module

    # Preflight: prove ROCm actually executes the real model before timing anything.
    probe_session, placement_report = verify_rocm_session(os.path.join(model_cache, MODEL_FILENAME))
    print(f"ROCm placement proof: {placement_report['all_nodes_placed_line']}")
    del probe_session

    captured = {}
    original_final_process = common_separator_module.CommonSeparator.final_process

    def capturing_final_process(self, stem_path, source, stem_name):
        captured[stem_name] = np.array(source, copy=True)
        return original_final_process(self, stem_path, source, stem_name)

    os.makedirs(out_dir, exist_ok=True)
    sep = Separator(log_level=100, model_file_dir=model_cache, output_dir=out_dir,
                     sample_rate=44100, use_soundfile=True)
    sep.onnx_execution_provider = ["ROCMExecutionProvider", "CPUExecutionProvider"]

    t_load0 = time.time()
    sep.load_model(MODEL_FILENAME)
    t_load1 = time.time()

    common_separator_module.CommonSeparator.final_process = capturing_final_process
    times = []
    run_samplers = []
    output_files = None
    try:
        for i in range(runs):
            with ResourceSampler(card_key="card0") as sampler:
                t0 = time.time()
                output_files = sep.separate(input_wav)
                t1 = time.time()
            times.append(t1 - t0)
            run_samplers.append(sampler.summary())
    finally:
        common_separator_module.CommonSeparator.final_process = original_final_process

    warm_times = times[1:] if len(times) > 1 else times
    return {
        "placement_report": placement_report,
        "load_time_s": t_load1 - t_load0,
        "run_times_s": times,
        "first_run_s": times[0],
        "warm_avg_s": sum(warm_times) / len(warm_times),
        "output_files": output_files,
        "raw_by_stem": {k: v.tolist() for k, v in captured.items()},
        "run_resources": run_samplers,
        "peak_vram_attributable_delta_mb": max(
            (s["vram"]["attributable_delta_mb"] for s in run_samplers if s["vram"]["attributable_delta_mb"] is not None),
            default=None,
        ),
        "peak_rss_mb": max((s["rss"]["peak_mb"] for s in run_samplers if s["rss"]["peak_mb"] is not None), default=None),
    }


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("input_wav")
    ap.add_argument("--model-cache", default="/home/flark/stemwerk-rnd/venvs/webgpu-ep/model-cache")
    ap.add_argument("--out-dir", default="/tmp/stemwerk-webgpu-l2/rocm")
    ap.add_argument("--runs", type=int, default=4)
    args = ap.parse_args()

    result = run(args.input_wav, args.model_cache, args.out_dir, args.runs)
    # raw_by_stem can be large; write it to its own file, keep the summary readable.
    raw = result.pop("raw_by_stem")
    print(json.dumps(result, indent=2, default=str))
    os.makedirs(args.out_dir, exist_ok=True)
    with open(os.path.join(args.out_dir, "rocm_result.json"), "w") as f:
        json.dump({**result, "raw_by_stem_note": "see rocm_raw_arrays.npz"}, f, indent=2, default=str)
    np.savez(os.path.join(args.out_dir, "rocm_raw_arrays.npz"), **{k: np.array(v) for k, v in raw.items()})
    print(f"Wrote {args.out_dir}/rocm_result.json and rocm_raw_arrays.npz")
