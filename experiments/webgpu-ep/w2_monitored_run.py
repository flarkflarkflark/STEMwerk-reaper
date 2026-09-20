"""
Phase W2 harness: runs an existing experiment script (end_to_end_pipeline_test.py,
benchmark_resources.py, demucs_validation.py, ...) as a fresh child process while
independently monitoring BOTH physical GPUs on this Windows machine via:
  1. windows_gpu_monitor.GpuEngineMonitor -- OS-level \\GPU Engine(*) performance
     counters, keyed by (pid, DXGI adapter LUID) -- covers both the NVIDIA RTX 3060
     AND the AMD integrated GPU, independent of onnxruntime/Dawn's own self-reporting.
  2. nvidia-smi --query-compute-apps -- NVIDIA's own per-process compute-app list,
     polled repeatedly during the child process's lifetime -- an independent
     second source specifically for the NVIDIA side (same tool class N1/W1 already
     used for whole-GPU sampling, used here for its per-process attribution instead).

This does NOT modify webgpu_adapter.py, end_to_end_pipeline_test.py, or any other
existing script -- it wraps them from the outside, exactly like L9/L10's kernel
monitor wrapped Linux runs without any onnxruntime/Dawn code changes.

Usage:
    python w2_monitored_run.py --idle-baseline-s 5 -- <python.exe path> <script.py> [args...]

Everything after the bare `--` is the exact child-process command line to run and
monitor. A fresh idle baseline is sampled for `--idle-baseline-s` seconds immediately
before launching the child (per the brief: "L11 found stale baselines cause false
positives -- capture a fresh idle baseline immediately before every workload").
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
import threading
import time

from windows_gpu_monitor import GpuEngineMonitor, enumerate_dxgi_adapters


def poll_nvidia_compute_apps(stop_event, results, interval_s=0.5):
    """Independent NVIDIA-only cross-check: which PIDs does nvidia-smi's own
    per-process compute-app list show during the window, and with how much memory."""
    while not stop_event.is_set():
        try:
            out = subprocess.run(
                ["nvidia-smi", "--query-compute-apps=pid,process_name,used_memory",
                 "--format=csv,noheader,nounits"],
                capture_output=True, text=True, timeout=2,
            )
            ts = time.time()
            for line in out.stdout.strip().splitlines():
                if not line.strip():
                    continue
                parts = [p.strip() for p in line.split(",")]
                if len(parts) != 3:
                    continue
                pid_s, pname, mem_s = parts
                try:
                    results.append({"t": ts, "pid": int(pid_s), "process_name": pname, "used_memory_mib": int(mem_s)})
                except ValueError:
                    continue
        except Exception:
            pass
        time.sleep(interval_s)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--idle-baseline-s", type=float, default=5.0)
    ap.add_argument("--report", default=None, help="Path to write the JSON monitoring report")
    ap.add_argument("--interval-ms", type=int, default=0)
    ap.add_argument("cmd", nargs=argparse.REMAINDER, help="-- <command to run and monitor>")
    args = ap.parse_args()

    cmd = args.cmd
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        print("ERROR: no command given after --", file=sys.stderr)
        sys.exit(2)

    adapters = enumerate_dxgi_adapters()
    print("=== DXGI adapters (independent, from HKLM\\SOFTWARE\\Microsoft\\DirectX) ===")
    for luid, info in adapters.items():
        print(f"  luid_lo=0x{luid} {info}")

    nvidia_samples = []
    nvidia_stop = threading.Event()
    nvidia_thread = threading.Thread(target=poll_nvidia_compute_apps, args=(nvidia_stop, nvidia_samples), daemon=True)

    report = {"adapters": adapters, "cmd": cmd}

    with GpuEngineMonitor(interval_ms=args.interval_ms) as mon:
        print(f"=== Capturing FRESH idle baseline for {args.idle_baseline_s:.1f}s before launching child ===")
        idle_t0 = time.time()
        time.sleep(args.idle_baseline_s)
        idle_t1 = time.time()

        nvidia_thread.start()

        print(f"=== Launching monitored child: {' '.join(cmd)} ===")
        t0 = time.time()
        proc = subprocess.Popen(cmd)
        target_pid = proc.pid
        print(f"=== Child PID: {target_pid} ===")
        exit_code = proc.wait()
        t1 = time.time()

        nvidia_stop.set()
        nvidia_thread.join(timeout=3)

        # brief settle window so any tail-end counter samples land before we stop the monitor
        time.sleep(1.0)

    idle_summary = {}
    for s in mon.samples:
        if idle_t0 * 1000 <= s["t_ms"] <= idle_t1 * 1000:
            idle_summary.setdefault(s["luid_lo"], []).append(s["value"])
    report["idle_baseline"] = {
        luid: {"max_pct": max(vals), "n_nonzero": len(vals), **adapters.get(luid, {})}
        for luid, vals in idle_summary.items()
    }

    target_summary = mon.summary_for_pid(target_pid, adapters=adapters)
    report["target_pid"] = target_pid
    report["target_window_s"] = {"start": t0, "end": t1, "duration_s": t1 - t0}
    report["target_gpu_engine_summary"] = target_summary
    report["exit_code"] = exit_code

    nvidia_hits = [s for s in nvidia_samples if s["pid"] == target_pid]
    report["nvidia_smi_compute_apps_hits_for_target_pid"] = nvidia_hits
    report["nvidia_smi_all_samples_n"] = len(nvidia_samples)

    print("\n=== Idle baseline (per adapter, max % during idle window) ===")
    for luid, info in report["idle_baseline"].items():
        print(f"  {info.get('description', luid)}: max={info['max_pct']:.2f}% n_nonzero={info['n_nonzero']}")

    print(f"\n=== Target PID {target_pid} GPU engine activity during its {t1-t0:.2f}s window ===")
    if not target_summary["adapters"]:
        print("  NO GPU engine activity attributed to this PID on ANY adapter.")
    for luid, info in target_summary["adapters"].items():
        print(f"  {info.get('description', luid)}: max={info['max_utilization_pct']:.2f}% "
              f"n_nonzero_samples={info['n_nonzero_samples']} engines={info['engine_types_active']}")

    print(f"\n=== nvidia-smi --query-compute-apps hits for PID {target_pid}: {len(nvidia_hits)} sample(s) ===")
    for h in nvidia_hits[:5]:
        print(f"  {h}")

    if args.report:
        with open(args.report, "w") as f:
            json.dump(report, f, indent=2, default=str)
        print(f"\n=== Full monitoring report written to {args.report} ===")

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
