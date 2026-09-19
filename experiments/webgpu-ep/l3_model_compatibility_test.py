"""
Phase L3 section 5: model compatibility testing for additional real ONNX models,
reusing the existing L1/L2 verification framework (webgpu_adapter.py) and the
existing end-to-end pipeline harness (end_to_end_pipeline_test.py) -- no second
implementation, per the brief's explicit instruction.

Runs, for each candidate model, in order:
  A. ONNX model inspection (onnx.checker, opset, op-type histogram, shapes) --
     already partly done ahead-of-time during model selection (see README.md
     "Phase L3" section for the selection rationale); re-verified here so the
     test script and the report can never silently drift apart.
  B. CPU baseline: real end-to-end audio-separator pipeline run.
  C. WebGPU session init: explicit RX 9070 selection (never guesses).
  D. Graph placement: real per-node proof via webgpu_adapter's stderr-fd log
     capture (same standard as L1/L2/M1 -- not get_providers() alone).
  E. Actual inference + F. end-to-end audio validation + stem routing + raw/file
     numeric comparison: reuses end_to_end_pipeline_test.py's functions directly.

Usage:
    python l3_model_compatibility_test.py <input.wav> [--model-cache DIR] [--out-dir DIR]
"""
import argparse
import json
import os
import sys
from collections import Counter

import numpy as np
import onnx
import soundfile as sf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from webgpu_adapter import patch_inference_session_for_provider_swap, select_device, GpuExecutionNotProvenError  # noqa: E402
from end_to_end_pipeline_test import (  # noqa: E402
    run_provider, validate_output_file, compare_arrays, check_stem_routing,
    RAW_TOLERANCE, FILE_TOLERANCE, PCM16_LSB,
)

import onnxruntime as ort  # noqa: E402

CANDIDATES = [
    "Reverb_HQ_By_FoxJoy.onnx",   # distinct task (reverb removal, not vocal/instrumental split)
    "kuielab_a_bass.onnx",        # distinct training lineage (kuielab, not UVR), largest n_fft (16384)
    "UVR-MDX-NET-Inst_HQ_5.onnx",  # latest general-purpose instrumental/vocals HQ model
]


def inspect_model(path):
    model = onnx.load(path)
    onnx.checker.check_model(model)
    op_counts = Counter(n.op_type for n in model.graph.node)
    inp = model.graph.input[0]
    out = model.graph.output[0]
    return {
        "total_nodes": sum(op_counts.values()),
        "distinct_op_types": len(op_counts),
        "op_type_histogram": dict(sorted(op_counts.items())),
        "input_shape": [d.dim_value or d.dim_param for d in inp.type.tensor_type.shape.dim],
        "output_shape": [d.dim_value or d.dim_param for d in out.type.tensor_type.shape.dim],
        "opset": [op.version for op in model.opset_import],
        "ir_version": model.ir_version,
        "file_size_bytes": os.path.getsize(path),
    }


def detect_required_segment_size(model_filename, model_cache):
    """
    audio-separator's MDXSeparator silently routes inference through onnx2torch/
    PyTorch instead of onnxruntime whenever `segment_size != model.dim_t` (see
    README.md Phase L3 "segment_size / dim_t routing trap" -- discovered exactly
    this way, by a real test run silently taking the PyTorch path with zero error).
    Cheap CPU-only probe load (no audio, no real inference) to read the model's
    native `dim_t` and decide whether the default segment_size=256 will reach
    onnxruntime at all, or whether it needs to be set to match dim_t explicitly.
    Returns None if the default is fine (no override needed).
    """
    import logging
    logging.disable(logging.CRITICAL)
    from audio_separator.separator import Separator
    probe = Separator(log_level=100, model_file_dir=model_cache, sample_rate=44100)
    probe.onnx_execution_provider = ["CPUExecutionProvider"]
    probe.load_model(model_filename)
    dim_t = probe.model_instance.dim_t
    default_segment_size = probe.model_instance.segment_size
    logging.disable(logging.NOTSET)
    return None if dim_t == default_segment_size else dim_t


def test_model(model_filename, input_wav, model_cache, out_dir, gpu_reports):
    result = {"model": model_filename, "checks": {}}

    # A. Model inspection
    model_path = os.path.join(model_cache, model_filename)
    try:
        result["inspection"] = inspect_model(model_path)
        result["checks"]["A_model_inspection"] = "PASS"
    except Exception as e:
        result["checks"]["A_model_inspection"] = f"FAIL: {e}"
        return result

    required_segment_size = detect_required_segment_size(model_filename, model_cache)
    result["required_segment_size_override"] = required_segment_size
    if required_segment_size is not None:
        print(f"  [segment_size/dim_t mismatch detected: default 256 would route this model through "
              f"onnx2torch/PyTorch, bypassing onnxruntime entirely -- overriding segment_size={required_segment_size} "
              f"to match this model's dim_t and reach the actual ONNX Runtime code path]")

    # B. CPU baseline (full real pipeline) + C/D/E via WebGPU (same call, both providers)
    model_out_dir = os.path.join(out_dir, model_filename.replace(".onnx", ""))
    gpu_reports_before = len(gpu_reports)
    try:
        cpu_result = run_provider("cpu", ["CPUExecutionProvider"], input_wav, model_cache, model_out_dir, None,
                                   model_filename=model_filename, mdx_segment_size=required_segment_size)
        result["checks"]["B_cpu_baseline"] = "PASS"
        result["cpu_uses_pytorch_inference"] = cpu_result["uses_pytorch_inference"]
    except Exception as e:
        result["checks"]["B_cpu_baseline"] = f"FAIL: {type(e).__name__}: {e}"
        return result

    try:
        webgpu_result = run_provider("webgpu", ["WebGpuExecutionProvider"], input_wav, model_cache, model_out_dir, None,
                                      model_filename=model_filename, mdx_segment_size=required_segment_size)
        result["webgpu_uses_pytorch_inference"] = webgpu_result["uses_pytorch_inference"]
        if webgpu_result["uses_pytorch_inference"]:
            # Session "succeeded" only in the sense that separate() completed -- it never
            # touched onnxruntime or WebGPU at all. Report this as its own explicit
            # classification (per the brief's failure taxonomy), not a silent WebGPU PASS.
            result["checks"]["C_webgpu_session_init"] = "N/A: ran via onnx2torch/PyTorch, onnxruntime never invoked"
            result["checks"]["D_graph_placement"] = "N/A: no onnxruntime session was created (not a WebGPU failure -- WebGPU was never reached)"
            result["checks"]["E_actual_inference"] = "PASS (via PyTorch, not WebGPU)"
        else:
            result["checks"]["C_webgpu_session_init"] = "PASS"
    except GpuExecutionNotProvenError as e:
        result["checks"]["C_webgpu_session_init"] = f"FAIL: {e}"
        result["checks"]["D_graph_placement"] = "FAIL: session init failed, no placement to check"
        return result
    except Exception as e:
        result["checks"]["C_webgpu_session_init"] = f"FAIL: {type(e).__name__}: {e}"
        return result

    if not webgpu_result["uses_pytorch_inference"]:
        new_reports = gpu_reports[gpu_reports_before:]
        if not new_reports:
            result["checks"]["D_graph_placement"] = "FAIL: no verified session report captured"
            return result
        placement = new_reports[-1]
        result["placement"] = placement
        # NOTE: onnxruntime's own optimized/fused graph node count (placement["all_nodes_count"])
        # is NOT expected to equal the raw .onnx file's node count from onnx.checker
        # (result["inspection"]["total_nodes"]) -- onnxruntime applies EP-specific graph
        # transformations (fusion, layout changes) that change node counts. The only thing
        # that matters here is that 100% of whatever nodes onnxruntime DID end up with are on
        # WebGPU, with zero on CPU -- which is exactly what the "All nodes placed on [...]"
        # line (not a per-EP count comparison) proves.
        if placement["all_nodes_ep"] == "WebGpuExecutionProvider":
            result["checks"]["D_graph_placement"] = f"PASS: {placement['all_nodes_placed_line']}"
        else:
            result["checks"]["D_graph_placement"] = f"FAIL: {placement}"

        # E already proven by D (a session that only creates but never runs a single
        # inference would not reach final_process -- run_provider() only returns after
        # separate() completes, which requires >=1 real session.run() call per chunk).
        result["checks"]["E_actual_inference"] = "PASS" if result["checks"]["D_graph_placement"].startswith("PASS") else "SKIPPED"

    # F. End-to-end audio validation
    try:
        cpu_files = {os.path.basename(f).split("_(")[1].split(")")[0]: f for f in cpu_result["output_files"]}
        gpu_files = {os.path.basename(f).split("_(")[1].split(")")[0]: f for f in webgpu_result["output_files"]}
        input_duration = sf.info(input_wav).duration

        validations = {}
        for label, files in [("cpu", cpu_files), ("webgpu", gpu_files)]:
            validations[label] = {}
            for stem, path in files.items():
                v = validate_output_file(path, input_duration)
                validations[label][stem] = v
        result["output_validation"] = validations
        any_issue = any(v["issues"] for label_v in validations.values() for v in label_v.values())
        result["checks"]["F1_output_validation"] = "PASS" if not any_issue else "FAIL"

        routing_ok, routing_report = check_stem_routing(cpu_result["raw_by_stem"], webgpu_result["raw_by_stem"])
        result["stem_routing"] = routing_report
        result["checks"]["F2_stem_routing"] = "PASS" if routing_ok else "FAIL"

        raw_cmp, file_cmp = {}, {}
        for stem_name in cpu_result["raw_by_stem"]:
            c = compare_arrays(cpu_result["raw_by_stem"][stem_name], webgpu_result["raw_by_stem"][stem_name], f"raw:{stem_name}")
            raw_cmp[stem_name] = c
        for stem_name in cpu_files:
            a, _ = sf.read(cpu_files[stem_name])
            b, _ = sf.read(gpu_files[stem_name])
            c = compare_arrays(a, b, f"file:{stem_name}")
            file_cmp[stem_name] = c
        result["raw_comparison"] = raw_cmp
        result["file_comparison"] = file_cmp

        raw_pass = all(c["correlation"] >= RAW_TOLERANCE["min_correlation"] and c["max_abs_diff"] <= RAW_TOLERANCE["max_abs_diff"] for c in raw_cmp.values())
        file_pass = all(c["correlation"] >= FILE_TOLERANCE["min_correlation"] and c["max_abs_diff"] <= FILE_TOLERANCE["max_abs_diff"] for c in file_cmp.values())
        result["checks"]["F3_raw_numeric"] = "PASS" if raw_pass else "FAIL"
        result["checks"]["F4_file_numeric"] = "PASS" if file_pass else "FAIL"
    except Exception as e:
        result["checks"]["F_end_to_end_audio"] = f"FAIL: {type(e).__name__}: {e}"

    result["timing"] = {
        "cpu_load_s": cpu_result["load_time_s"], "cpu_run_s": cpu_result["run_time_s"],
        "webgpu_load_s": webgpu_result["load_time_s"], "webgpu_run_s": webgpu_result["run_time_s"],
    }
    return result


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("input_wav")
    ap.add_argument("--model-cache", default="/home/flark/stemwerk-rnd/venvs/webgpu-ep/model-cache")
    ap.add_argument("--out-dir", default="/tmp/stemwerk-webgpu-l3")
    ap.add_argument("--pci-bus-id", default="0000:03:00.0")
    ap.add_argument("--models", nargs="*", default=CANDIDATES)
    args = ap.parse_args()

    original_cls, gpu_reports = patch_inference_session_for_provider_swap(
        lambda: select_device(pci_bus_id=args.pci_bus_id)
    )

    all_results = {}
    try:
        for model_filename in args.models:
            print(f"\n{'='*20} {model_filename} {'='*20}")
            r = test_model(model_filename, args.input_wav, args.model_cache, args.out_dir, gpu_reports)
            all_results[model_filename] = r
            for check, status in r["checks"].items():
                print(f"  {check}: {status}")
            if "raw_comparison" in r:
                for stem, c in r["raw_comparison"].items():
                    print(f"    raw:{stem} corr={c['correlation']:.8f} max_abs_diff={c['max_abs_diff']:.2e}")
    finally:
        ort.InferenceSession = original_cls

    os.makedirs(args.out_dir, exist_ok=True)
    out_path = os.path.join(args.out_dir, "l3_model_compatibility_report.json")
    with open(out_path, "w") as f:
        json.dump(all_results, f, indent=2, default=str)
    print(f"\n=== Full report: {out_path} ===")

    print("\n=== SUMMARY ===")
    for model_filename, r in all_results.items():
        overall = "PASS" if all(str(v).startswith("PASS") for v in r["checks"].values()) else "SEE DETAIL"
        print(f"{model_filename}: {overall}")
