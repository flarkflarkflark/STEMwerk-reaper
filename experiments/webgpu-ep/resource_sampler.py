"""
Lightweight background resource sampler (process RSS, GPU VRAM, GPU utilization)
used by the L2 benchmark scripts. Pure stdlib + subprocess calls to `rocm-smi`
(already installed on this system, part of the existing ROCm stack -- nothing new
installed or configured to make this work, per the "no system changes just to get
measurement tools working" constraint).

Honesty note (see README.md "RAM/VRAM measurement reliability"): `rocm-smi`'s VRAM
and utilization figures are WHOLE-GPU, not per-process. On a desktop system the
baseline already includes the compositor and any other GPU clients. This sampler
reports both the raw peak AND a delta against the pre-run baseline as a best-effort
attribution estimate, and callers/reports must present the delta as "attributable
(best-effort)", never as a clean per-process peak.
"""
import json
import subprocess
import threading
import time


def _read_rss_kb():
    try:
        with open("/proc/self/status") as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return None


def _rocm_smi_json(args, timeout=2):
    try:
        out = subprocess.run(["rocm-smi", *args, "--json"], capture_output=True, text=True, timeout=timeout)
        return json.loads(out.stdout)
    except Exception:
        return None


def _read_vram_used_bytes(card_key):
    data = _rocm_smi_json(["--showmeminfo", "vram"])
    if not data or card_key not in data:
        return None
    try:
        return int(data[card_key]["VRAM Total Used Memory (B)"])
    except (KeyError, ValueError, TypeError):
        return None


def _read_gpu_util_pct(card_key):
    data = _rocm_smi_json(["--showuse"])
    if not data or card_key not in data:
        return None
    try:
        return float(data[card_key]["GPU use (%)"])
    except (KeyError, ValueError, TypeError):
        return None


class ResourceSampler:
    """
    Usage:
        with ResourceSampler(card_key="card0") as sampler:
            do_the_timed_work()
        print(sampler.summary())
    """

    def __init__(self, interval_s=0.05, card_key="card0"):
        self.interval_s = interval_s
        self.card_key = card_key
        self.samples = []
        self._stop = threading.Event()
        self._thread = None
        self._rocm_smi_available = _rocm_smi_json(["--showuse"]) is not None

    def _loop(self):
        while not self._stop.is_set():
            self.samples.append({
                "t": time.time(),
                "rss_kb": _read_rss_kb(),
                "vram_used_b": _read_vram_used_bytes(self.card_key) if self._rocm_smi_available else None,
                "gpu_util_pct": _read_gpu_util_pct(self.card_key) if self._rocm_smi_available else None,
            })
            time.sleep(self.interval_s)

    def __enter__(self):
        # One synchronous sample before starting the thread, to get a clean baseline.
        self.baseline = {
            "rss_kb": _read_rss_kb(),
            "vram_used_b": _read_vram_used_bytes(self.card_key) if self._rocm_smi_available else None,
        }
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *exc_info):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)

    def summary(self):
        if not self._rocm_smi_available:
            gpu_reliable_note = "rocm-smi --json produced no output/unparseable output on this system"
        else:
            gpu_reliable_note = None

        rss = [s["rss_kb"] for s in self.samples if s["rss_kb"] is not None]
        vram = [s["vram_used_b"] for s in self.samples if s["vram_used_b"] is not None]
        util = [s["gpu_util_pct"] for s in self.samples if s["gpu_util_pct"] is not None]

        result = {
            "n_samples": len(self.samples),
            "sample_interval_s": self.interval_s,
            "rss": {
                "reliable": bool(rss),
                "baseline_mb": (self.baseline["rss_kb"] / 1024) if self.baseline.get("rss_kb") else None,
                "peak_mb": (max(rss) / 1024) if rss else None,
            },
            "vram": {
                "reliable": bool(vram) and self._rocm_smi_available,
                "reliability_note": "Whole-GPU total (rocm-smi has no per-process VRAM accounting for this "
                                     "backend); baseline already includes desktop compositor + any other GPU "
                                     "clients. 'attributable_delta_mb' is peak-minus-pre-run-baseline as a "
                                     "best-effort estimate only, not a validated per-process peak."
                                     + (f" UNAVAILABLE: {gpu_reliable_note}" if gpu_reliable_note else ""),
                "baseline_mb": (self.baseline["vram_used_b"] / 1024 / 1024) if self.baseline.get("vram_used_b") else None,
                "peak_mb": (max(vram) / 1024 / 1024) if vram else None,
                "attributable_delta_mb": ((max(vram) - self.baseline["vram_used_b"]) / 1024 / 1024)
                if vram and self.baseline.get("vram_used_b") is not None else None,
            },
            "gpu_util_pct": {
                "reliable": bool(util) and self._rocm_smi_available,
                "reliability_note": "Whole-GPU (includes desktop compositor activity), sampled at "
                                     f"{self.interval_s}s intervals -- short spikes between samples are missed.",
                "avg": (sum(util) / len(util)) if util else None,
                "max": max(util) if util else None,
            },
        }
        return result
