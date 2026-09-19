"""
Phase L2, sections 2/4/5/7: real end-to-end audio separation through the SAME
audio-separator pipeline STEMwerk uses in production (UVR_MDXNET_KARA_2.onnx),
CPU EP vs WebGPU EP, with:
  - genuine per-node GPU-execution proof (via webgpu_adapter, not just "EP loaded")
  - output validation (stem count/sr/channels/duration/NaN/silence/clipping/routing)
  - TWO numeric comparisons, kept explicitly separate:
      1. "raw" -- in-memory float32 model output, captured before any export/
         quantization step. Isolates true inference differences (backend/kernel/
         accumulation-order) from anything the audio export path does.
      2. "file" -- the actual exported WAV files a user would get. Dominated by
         PCM_16 quantization noise (1 LSB = 1/32767 = 3.0518e-5) for a 16-bit
         input, which is NOT a WebGPU-vs-CPU difference -- it is present even
         when comparing a provider against itself, run to run. Reported anyway
         because it's what actually ships, but must not be conflated with (1).

Pre-declared tolerances (see README.md "Numerical tolerances" for the rationale):
  raw:  correlation >= 0.999,  max_abs_diff <= 5e-3   (float32 cross-backend conv/matmul)
  file: correlation >= 0.999,  max_abs_diff <= 1.5e-4 (~5x one PCM_16 LSB)

Usage:
    python end_to_end_pipeline_test.py <input.wav> [--model-cache DIR] [--out-dir DIR]
                                        [--pci-bus-id 0000:03:00.0]
"""
import argparse
import json
import os
import sys
import time

import numpy as np
import soundfile as sf

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from webgpu_adapter import patch_inference_session_for_provider_swap, select_device, GpuExecutionNotProvenError  # noqa: E402

import onnxruntime as ort  # noqa: E402

MODEL_FILENAME = "UVR_MDXNET_KARA_2.onnx"
RAW_TOLERANCE = {"min_correlation": 0.999, "max_abs_diff": 5e-3}
FILE_TOLERANCE = {"min_correlation": 0.999, "max_abs_diff": 1.5e-4}
PCM16_LSB = 1.0 / 32767.0


class ValidationError(RuntimeError):
    pass


def run_provider(label, providers, input_wav, model_cache, out_dir, pci_bus_id):
    from audio_separator.separator import Separator
    import audio_separator.separator.common_separator as common_separator_module

    # Separator.separate()'s outer wrapper calls model_instance.clear_file_specific_paths()
    # in a cleanup step immediately after model_instance.separate() returns, which resets
    # primary_source/secondary_source to None -- so they can't be read after the fact.
    # final_process(self, stem_path, source, stem_name) is called once per stem, with the
    # raw pre-export array, before that cleanup runs -- intercept there instead. This is a
    # runtime patch of the class method (restored immediately after), not an on-disk edit
    # of the installed package.
    captured = {}
    original_final_process = common_separator_module.CommonSeparator.final_process

    def capturing_final_process(self, stem_path, source, stem_name):
        captured[stem_name] = np.array(source, copy=True)
        return original_final_process(self, stem_path, source, stem_name)

    provider_out_dir = os.path.join(out_dir, label)
    os.makedirs(provider_out_dir, exist_ok=True)

    sep = Separator(
        log_level=100,
        model_file_dir=model_cache,
        output_dir=provider_out_dir,
        sample_rate=44100,
        use_soundfile=True,  # single quantization step (float->target subtype), no pydub/ffmpeg int16 pre-stage
    )
    sep.onnx_execution_provider = providers

    t_load0 = time.time()
    sep.load_model(MODEL_FILENAME)
    t_load1 = time.time()

    common_separator_module.CommonSeparator.final_process = capturing_final_process
    try:
        t_run0 = time.time()
        output_files = sep.separate(input_wav)
        t_run1 = time.time()
    finally:
        common_separator_module.CommonSeparator.final_process = original_final_process

    return {
        "label": label,
        "output_files": [os.path.join(provider_out_dir, os.path.basename(f)) for f in output_files],
        "load_time_s": t_load1 - t_load0,
        "run_time_s": t_run1 - t_run0,
        "raw_by_stem": captured,
    }


def validate_output_file(path, expected_duration_s, expected_sr=44100, expected_channels=2,
                          duration_tolerance_s=0.05, clip_ceiling=0.999):
    data, sr = sf.read(path)
    issues = []
    if sr != expected_sr:
        issues.append(f"sample_rate mismatch: got {sr}, expected {expected_sr}")
    channels = 1 if data.ndim == 1 else data.shape[1]
    if channels != expected_channels:
        issues.append(f"channel count mismatch: got {channels}, expected {expected_channels}")
    duration = len(data) / sr
    if abs(duration - expected_duration_s) > duration_tolerance_s:
        issues.append(f"duration mismatch: got {duration:.3f}s, expected {expected_duration_s:.3f}s (+/-{duration_tolerance_s}s)")
    if not np.isfinite(data).all():
        issues.append("output contains NaN or Inf samples")
    rms = float(np.sqrt(np.mean(data.astype(np.float64) ** 2)))
    if rms < 1e-6:
        issues.append(f"output is unexpectedly silent (RMS={rms:.2e})")
    peak = float(np.max(np.abs(data)))
    if peak > clip_ceiling:
        issues.append(f"output exceeds clipping ceiling: peak={peak:.4f} > {clip_ceiling}")
    return {"path": path, "sr": sr, "channels": channels, "duration_s": duration, "rms": rms, "peak": peak, "issues": issues}


def compare_arrays(a, b, label):
    n = min(len(a), len(b))
    a64 = np.asarray(a[:n], dtype=np.float64)
    b64 = np.asarray(b[:n], dtype=np.float64)
    diff = a64 - b64
    abs_diff = np.abs(diff)
    corr = float(np.corrcoef(a64.flatten(), b64.flatten())[0, 1])
    rms_a = float(np.sqrt(np.mean(a64**2)))
    rms_b = float(np.sqrt(np.mean(b64**2)))
    peak_a = float(np.max(np.abs(a64)))
    peak_b = float(np.max(np.abs(b64)))
    return {
        "label": label,
        "n_samples_compared": int(n),
        "length_diff_samples": int(abs(len(a) - len(b))),
        "rms_a": rms_a, "rms_b": rms_b, "rms_diff_pct": 100 * abs(rms_a - rms_b) / rms_a if rms_a else float("nan"),
        "peak_a": peak_a, "peak_b": peak_b,
        "correlation": corr,
        "mae": float(np.mean(abs_diff)),
        "rmse": float(np.sqrt(np.mean(diff**2))),
        "max_abs_diff": float(abs_diff.max()),
    }


def check_stem_routing(cpu_raw, gpu_raw):
    """
    Cross-correlation sanity check: each CPU stem should correlate far more with
    the SAME-named GPU stem than with the OTHER GPU stem. Catches an accidental
    vocals<->instrumental swap between runs, which a naive filename-only check
    would miss if both routes happened to still produce two files.
    """
    results = {}
    ok = True
    for stem_name, cpu_arr in cpu_raw.items():
        same = compare_arrays(cpu_arr, gpu_raw[stem_name], f"{stem_name}:same")["correlation"]
        other_name = [k for k in gpu_raw if k != stem_name][0]
        other = compare_arrays(cpu_arr, gpu_raw[other_name], f"{stem_name}:other")["correlation"]
        results[stem_name] = {"same_stem_corr": same, "other_stem_corr": other, "routed_correctly": same > other}
        ok = ok and (same > other)
    return ok, results


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("input_wav")
    ap.add_argument("--model-cache", default="/home/flark/stemwerk-rnd/venvs/webgpu-ep/model-cache")
    ap.add_argument("--out-dir", default="/tmp/stemwerk-webgpu-l2/e2e")
    ap.add_argument("--pci-bus-id", default="0000:03:00.0")
    args = ap.parse_args()

    input_info = sf.info(args.input_wav)
    expected_duration = input_info.duration
    print(f"Input: {args.input_wav} ({input_info.samplerate} Hz, {input_info.channels}ch, {expected_duration:.2f}s)")

    original_cls, gpu_reports = patch_inference_session_for_provider_swap(
        lambda: select_device(pci_bus_id=args.pci_bus_id)
    )

    report = {"tolerances": {"raw": RAW_TOLERANCE, "file": FILE_TOLERANCE, "pcm16_lsb": PCM16_LSB}}
    results = {}
    validations = {}
    exit_code = 0

    try:
        for label, providers in [("cpu", ["CPUExecutionProvider"]), ("webgpu", ["WebGpuExecutionProvider"])]:
            print(f"=== Running {label} ===")
            results[label] = run_provider(label, providers, args.input_wav, args.model_cache, args.out_dir, args.pci_bus_id)
            print(f"  load={results[label]['load_time_s']:.2f}s run={results[label]['run_time_s']:.2f}s "
                  f"files={[os.path.basename(f) for f in results[label]['output_files']]}")

            print(f"  Validating {label} output files...")
            validations[label] = []
            for f in results[label]["output_files"]:
                v = validate_output_file(f, expected_duration)
                validations[label].append(v)
                status = "OK" if not v["issues"] else "ISSUES: " + "; ".join(v["issues"])
                print(f"    {os.path.basename(f)}: sr={v['sr']} ch={v['channels']} dur={v['duration_s']:.2f}s "
                      f"rms={v['rms']:.4f} peak={v['peak']:.4f} -- {status}")
                if v["issues"]:
                    exit_code = 1

        if len(gpu_reports) != 1:
            raise GpuExecutionNotProvenError(f"Expected exactly 1 verified WebGPU session, got {len(gpu_reports)}: {gpu_reports}")
        report["gpu_execution_proof"] = gpu_reports[0]
        print(f"=== GPU execution proof: {gpu_reports[0]['all_nodes_placed_line']} ===")

        cpu_raw = results["cpu"]["raw_by_stem"]
        gpu_raw = results["webgpu"]["raw_by_stem"]

        routing_ok, routing_report = check_stem_routing(cpu_raw, gpu_raw)
        report["stem_routing"] = routing_report
        print(f"=== Stem routing check: {'PASS' if routing_ok else 'FAIL'} ===")
        for stem, r in routing_report.items():
            print(f"  {stem}: same-stem corr={r['same_stem_corr']:.6f} vs other-stem corr={r['other_stem_corr']:.6f}")
        if not routing_ok:
            exit_code = 1

        print("=== Raw (pre-export, in-memory) numeric comparison ===")
        report["raw_comparison"] = {}
        for stem_name in cpu_raw:
            cmp = compare_arrays(cpu_raw[stem_name], gpu_raw[stem_name], f"raw:{stem_name}")
            report["raw_comparison"][stem_name] = cmp
            passed = cmp["correlation"] >= RAW_TOLERANCE["min_correlation"] and cmp["max_abs_diff"] <= RAW_TOLERANCE["max_abs_diff"]
            print(f"  {stem_name}: corr={cmp['correlation']:.8f} max_abs_diff={cmp['max_abs_diff']:.2e} "
                  f"mae={cmp['mae']:.2e} rmse={cmp['rmse']:.2e} rms_diff%={cmp['rms_diff_pct']:.4f}% "
                  f"-- {'PASS' if passed else 'FAIL'}")
            if not passed:
                exit_code = 1

        print("=== File (exported WAV) numeric comparison ===")
        report["file_comparison"] = {}
        cpu_files = {os.path.basename(f).split("_(")[1].split(")")[0]: f for f in results["cpu"]["output_files"]}
        gpu_files = {os.path.basename(f).split("_(")[1].split(")")[0]: f for f in results["webgpu"]["output_files"]}
        for stem_name in cpu_files:
            a, _ = sf.read(cpu_files[stem_name])
            b, _ = sf.read(gpu_files[stem_name])
            cmp = compare_arrays(a, b, f"file:{stem_name}")
            report["file_comparison"][stem_name] = cmp
            passed = cmp["correlation"] >= FILE_TOLERANCE["min_correlation"] and cmp["max_abs_diff"] <= FILE_TOLERANCE["max_abs_diff"]
            print(f"  {stem_name}: corr={cmp['correlation']:.8f} max_abs_diff={cmp['max_abs_diff']:.2e} "
                  f"({cmp['max_abs_diff']/PCM16_LSB:.2f}x PCM16 LSB) mae={cmp['mae']:.2e} "
                  f"rms_diff%={cmp['rms_diff_pct']:.4f}% -- {'PASS' if passed else 'FAIL'}")
            if not passed:
                exit_code = 1

    except GpuExecutionNotProvenError as e:
        print(f"FAIL: GPU execution not proven -- {e}")
        exit_code = 2
    finally:
        ort.InferenceSession = original_cls

    report["timing"] = {k: {"load_time_s": v["load_time_s"], "run_time_s": v["run_time_s"]} for k, v in results.items()}
    report["file_validation"] = {
        label: [{k: v[k] for k in v if k != "path"} for v in vs] for label, vs in validations.items()
    }

    out_json = os.path.join(args.out_dir, "e2e_report.json")
    os.makedirs(args.out_dir, exist_ok=True)
    with open(out_json, "w") as f:
        json.dump(report, f, indent=2, default=str)
    print(f"=== Full report written to {out_json} ===")
    print(f"=== EXIT CODE: {exit_code} ({'PASS' if exit_code == 0 else 'FAIL'}) ===")
    sys.exit(exit_code)
