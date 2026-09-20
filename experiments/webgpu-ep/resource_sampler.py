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

Platform isolation: RSS reading is the one piece with a real per-platform branch
(Linux: /proc/self/status; macOS: resource.getrusage, no /proc) -- see _read_rss_kb().
`rocm-smi` doesn't exist on macOS at all; `_rocm_smi_json()`'s existing blanket
`except Exception` already degrades VRAM/GPU-util to "not reliable" there with no
macOS-specific code needed -- this was true before any macOS work and remains
unchanged.
"""
import json
import subprocess
import sys
import threading
import time


def _read_rss_kb():
    if sys.platform == "win32":
        # No /proc, no `resource` module on Windows. GetProcessMemoryInfo's
        # WorkingSetSize is the closest live, per-process, instantaneous analogue to
        # Linux's /proc/self/status VmRSS (both are the OS's live-resident-set
        # reading, not a peak-since-start value like macOS's ru_maxrss) -- repeatedly
        # sampled by this same class exactly like the Linux path, so "peak_mb" here is
        # genuinely max-over-samples of a point-in-time metric, matching Linux's
        # semantics, not macOS's monotonic-peak one. ctypes-only, no new dependency.
        try:
            import ctypes
            import ctypes.wintypes as wintypes

            class PROCESS_MEMORY_COUNTERS(ctypes.Structure):
                _fields_ = [
                    ("cb", wintypes.DWORD),
                    ("PageFaultCount", wintypes.DWORD),
                    ("PeakWorkingSetSize", ctypes.c_size_t),
                    ("WorkingSetSize", ctypes.c_size_t),
                    ("QuotaPeakPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t),
                    ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                    ("PagefileUsage", ctypes.c_size_t),
                    ("PeakPagefileUsage", ctypes.c_size_t),
                ]

            # Explicit argtypes/restype are load-bearing here, not decoration: bare
            # `ctypes.windll.psapi.GetProcessMemoryInfo(...)` (no declared signature)
            # silently returns a falsy 0/success-looking value without raising on this
            # exact Windows 11 / Python 3.11 combination -- confirmed directly, not
            # assumed -- while ctypes guesses a default argument marshaling that
            # doesn't match this function's real (HANDLE, POINTER(struct), DWORD)
            # signature. Declaring them explicitly is the fix, not a preference.
            psapi = ctypes.WinDLL("psapi", use_last_error=True)
            kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel32.GetCurrentProcess.restype = wintypes.HANDLE
            psapi.GetProcessMemoryInfo.argtypes = [
                wintypes.HANDLE, ctypes.POINTER(PROCESS_MEMORY_COUNTERS), wintypes.DWORD,
            ]
            psapi.GetProcessMemoryInfo.restype = wintypes.BOOL

            counters = PROCESS_MEMORY_COUNTERS()
            counters.cb = ctypes.sizeof(PROCESS_MEMORY_COUNTERS)
            handle = kernel32.GetCurrentProcess()
            ok = psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb)
            if not ok:
                return None
            return counters.WorkingSetSize // 1024
        except Exception:
            return None
    if sys.platform == "darwin":
        # No /proc on macOS. resource.getrusage(RUSAGE_SELF).ru_maxrss is the
        # process's own peak-RSS-so-far (monotonically non-decreasing across the
        # process lifetime, not a live/instantaneous reading like /proc/self/status
        # below) -- still correct for this sampler's only reported RSS metric,
        # "peak_mb" (max() over samples), and per-process reliable (unlike the
        # rocm-smi-based VRAM/GPU-util metrics below, which stay macOS-unavailable).
        # BSD/macOS reports ru_maxrss in bytes; Linux reports it in KB -- this
        # platform branch only ever runs on macOS, so no KB/bytes ambiguity here.
        try:
            import resource
            return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // 1024
        except Exception:
            return None
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


def _nvidia_smi_query(gpu_index, timeout=2):
    """
    Windows/NVIDIA counterpart to _rocm_smi_json(), added for the Windows W1 phase.
    Same honesty class as rocm-smi above: nvidia-smi's memory.used/utilization.gpu are
    also WHOLE-GPU (every process + the desktop compositor), not per-process -- callers
    must still present any delta as best-effort attributable, never a clean per-process
    peak. Explicit --id=<gpu_index> because this experiment's actual laptop has two
    GPUs (NVIDIA discrete + an AMD iGPU); nothing here guesses which one to query.
    """
    try:
        out = subprocess.run(
            ["nvidia-smi", f"--id={gpu_index}", "--query-gpu=memory.used,utilization.gpu",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=timeout,
        )
        used_mb, util_pct = (p.strip() for p in out.stdout.strip().split(","))
        return int(used_mb) * 1024 * 1024, float(util_pct)
    except Exception:
        return None, None


class ResourceSampler:
    """
    Usage:
        with ResourceSampler(card_key="card0") as sampler:                  # Linux/ROCm
            do_the_timed_work()
        with ResourceSampler(gpu_backend="nvidia", nvidia_gpu_index=0) as sampler:  # Windows/NVIDIA
            do_the_timed_work()
        print(sampler.summary())
    """

    def __init__(self, interval_s=0.05, card_key="card0", gpu_backend="rocm", nvidia_gpu_index=0):
        self.interval_s = interval_s
        self.card_key = card_key
        self.gpu_backend = gpu_backend  # "rocm" (unchanged default) or "nvidia" (new, Windows W1)
        self.nvidia_gpu_index = nvidia_gpu_index
        self.samples = []
        self._stop = threading.Event()
        self._thread = None
        if self.gpu_backend == "nvidia":
            used_b, _ = _nvidia_smi_query(self.nvidia_gpu_index)
            self._gpu_tool_available = used_b is not None
            self._tool_name = "nvidia-smi"
        else:
            self._gpu_tool_available = _rocm_smi_json(["--showuse"]) is not None
            self._tool_name = "rocm-smi"
        self._rocm_smi_available = self._gpu_tool_available  # kept for any external reader of this attribute

    def _read_gpu_sample(self):
        if not self._gpu_tool_available:
            return None, None
        if self.gpu_backend == "nvidia":
            return _nvidia_smi_query(self.nvidia_gpu_index)
        return _read_vram_used_bytes(self.card_key), _read_gpu_util_pct(self.card_key)

    def _loop(self):
        while not self._stop.is_set():
            vram, util = self._read_gpu_sample()
            self.samples.append({
                "t": time.time(),
                "rss_kb": _read_rss_kb(),
                "vram_used_b": vram,
                "gpu_util_pct": util,
            })
            time.sleep(self.interval_s)

    def __enter__(self):
        # One synchronous sample before starting the thread, to get a clean baseline.
        baseline_vram, _ = self._read_gpu_sample()
        self.baseline = {
            "rss_kb": _read_rss_kb(),
            "vram_used_b": baseline_vram,
        }
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *exc_info):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=2)

    def summary(self):
        if not self._gpu_tool_available:
            gpu_reliable_note = f"{self._tool_name} produced no output/unparseable output on this system"
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
                "reliable": bool(vram) and self._gpu_tool_available,
                "reliability_note": f"Whole-GPU total ({self._tool_name} has no per-process VRAM accounting for "
                                     "this backend); baseline already includes desktop compositor + any other GPU "
                                     "clients. 'attributable_delta_mb' is peak-minus-pre-run-baseline as a "
                                     "best-effort estimate only, not a validated per-process peak."
                                     + (f" UNAVAILABLE: {gpu_reliable_note}" if gpu_reliable_note else ""),
                "baseline_mb": (self.baseline["vram_used_b"] / 1024 / 1024) if self.baseline.get("vram_used_b") else None,
                "peak_mb": (max(vram) / 1024 / 1024) if vram else None,
                "attributable_delta_mb": ((max(vram) - self.baseline["vram_used_b"]) / 1024 / 1024)
                if vram and self.baseline.get("vram_used_b") is not None else None,
            },
            "gpu_util_pct": {
                "reliable": bool(util) and self._gpu_tool_available,
                "reliability_note": "Whole-GPU (includes desktop compositor activity), sampled at "
                                     f"{self.interval_s}s intervals -- short spikes between samples are missed.",
                "avg": (sum(util) / len(util)) if util else None,
                "max": max(util) if util else None,
            },
        }
        return result
