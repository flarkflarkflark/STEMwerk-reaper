"""
Independent, OS-level per-GPU-engine utilization sampler for Windows -- Phase W2.

Analogous to kernel_gpu_monitor.py's DualCardMonitor (Linux amdgpu sysfs
gpu_busy_percent), but for Windows: samples the `\\GPU Engine(*)\\Utilization
Percentage` performance counter object, which Windows' graphics kernel subsystem
(dxgkrnl) populates per (process id, DXGI adapter LUID, physical-adapter index,
engine type) instance. This is populated by the OS/driver stack itself -- completely
independent of onnxruntime, Dawn, or anything this experiment's own Python process
self-reports -- the same standard of independence L9/L10 established on Linux via
/sys/class/drm/card*/device/gpu_busy_percent, and analogous to nvidia-smi's
per-process compute-apps query used for the NVIDIA side throughout N1/W1.

Adapter LUID -> vendor/device/description mapping comes from
HKLM\\SOFTWARE\\Microsoft\\DirectX (Windows' own live per-adapter registry, populated
by the OS/driver at adapter-enumeration time, NOT by this experiment or by
onnxruntime) -- so cross-checking a sampled LUID against this table is an independent
confirmation of which physical GPU (vendor_id/device_id) actually did the work,
separate from webgpu_adapter.py's own EpDevice metadata.

Known real limitation of this technique, disclosed rather than hidden: the GPU Engine
counter reports utilization per *engine* (3D, Compute N, Copy, VideoDecode, ...), not
one single number per adapter. WebGPU/Dawn/D3D12 compute dispatches typically land on
a "Compute" or "3D" engine instance depending on the exact D3D12 command list type
Dawn issues; this module sums utilization across ALL engine types for a given
(pid, LUID) pair rather than guessing which single engine type WebGPU will use, since
guessing wrong would silently under-report real activity.
"""
from __future__ import annotations

import re
import subprocess
import sys
import tempfile
import threading
import time
import winreg

_COUNTER_PATH_RE = re.compile(
    r"pid_(?P<pid>\d+)_luid_0x(?P<luid_hi>[0-9a-f]+)_0x(?P<luid_lo>[0-9a-f]+)"
    r"_phys_(?P<phys>\d+)_eng_\d+_engtype_(?P<eng>[^)]+)\)",
    re.IGNORECASE,
)

_MONITOR_PS1 = r"""
param([int]$IntervalMs = 250)
$ErrorActionPreference = 'SilentlyContinue'
# IMPORTANT, confirmed empirically during W2 development (not assumed): Get-Counter's
# `-Continuous` streaming mode resolves the `(*)` wildcard's instance list ONCE, at
# query-open time -- a process that opens its D3D12 device/GPU-engine instance AFTER
# the continuous query has already started is silently never added to the stream,
# even though real inference is happening. A direct controlled test (repeated-
# inference workload started AFTER the monitor) reproduced this: -Continuous mode
# caught zero samples for the target process, while looping independent single-shot
# Get-Counter calls (below) -- which re-resolve the wildcard fresh on every call --
# correctly captured it every time. This mirrors L10's own disclosed Linux finding
# that `list_webgpu_devices()`/enumeration metadata must not be trusted as a stand-in
# for real session-creation-time evidence; the Windows analogue here is
# "-Continuous's cached instance list must not be trusted as a stand-in for a fresh
# per-sample enumeration." Single-shot looping is therefore used despite its lower
# (~1.3-1.6s per call) resolution -- correctness over resolution.
while ($true) {
    $ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    try {
        $c = Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop
        foreach ($s in $c.CounterSamples) {
            Write-Output "$ts|$($s.Path)|$($s.CookedValue)"
        }
    } catch {}
    Write-Output "TICK|$ts"
    Start-Sleep -Milliseconds $IntervalMs
}
"""


def enumerate_dxgi_adapters():
    """
    Reads HKLM\\SOFTWARE\\Microsoft\\DirectX -- maps each adapter's LUID (as the
    lowercase 8-hex-digit low-32-bits string the GPU Engine counter path also uses)
    to vendor_id/device_id/description. This registry key is maintained by Windows
    itself at adapter enumeration time; it is not written by onnxruntime, Dawn, or
    this experiment.
    """
    adapters = {}
    key_path = r"SOFTWARE\Microsoft\DirectX"
    try:
        root = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key_path)
    except OSError:
        return adapters
    with root:
        i = 0
        while True:
            try:
                sub = winreg.EnumKey(root, i)
            except OSError:
                break
            i += 1
            try:
                with winreg.OpenKey(root, sub) as k:
                    def rd(name):
                        try:
                            return winreg.QueryValueEx(k, name)[0]
                        except OSError:
                            return None
                    desc = rd("Description")
                    luid = rd("AdapterLuid")
                    if desc is None or luid is None:
                        continue
                    vendor_id = rd("VendorId")
                    device_id = rd("DeviceId")
                    luid_lo_hex = f"{luid & 0xFFFFFFFF:08x}".lower()
                    adapters[luid_lo_hex] = {
                        "description": desc,
                        "vendor_id_hex": f"0x{vendor_id:04x}" if vendor_id is not None else None,
                        "device_id_hex": f"0x{device_id:04x}" if device_id is not None else None,
                        "adapter_luid_decimal": luid,
                    }
            except OSError:
                continue
    return adapters


class GpuEngineMonitor:
    """
    Context manager: samples \\GPU Engine(*)\\Utilization Percentage continuously via
    a single long-lived PowerShell subprocess (Get-Counter looped internally --
    avoids per-sample process-spawn overhead, and re-enumerates wildcard instances on
    every loop iteration, so engine instances that appear/disappear mid-run -- e.g.
    the target process opening a D3D12 device partway through -- are captured).
    """

    def __init__(self, interval_ms=250):
        self.interval_ms = interval_ms
        self.samples = []  # list of dict: pid, luid_lo, phys, eng, value, t_ms
        self.n_ticks = 0
        self._proc = None
        self._reader_thread = None
        self._script_path = None

    def __enter__(self):
        tmp = tempfile.NamedTemporaryFile(mode="w", suffix=".ps1", delete=False, encoding="utf-8")
        tmp.write(_MONITOR_PS1)
        tmp.close()
        self._script_path = tmp.name
        self._proc = subprocess.Popen(
            ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
             "-File", self._script_path, "-IntervalMs", str(self.interval_ms)],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1,
        )
        self._reader_thread = threading.Thread(target=self._read_loop, daemon=True)
        self._reader_thread.start()
        return self

    def _read_loop(self):
        for line in self._proc.stdout:
            line = line.strip()
            if not line:
                continue
            if line.startswith("TICK|"):
                self.n_ticks += 1
                continue
            parts = line.split("|", 2)
            if len(parts) != 3:
                continue
            ts_str, path, value_str = parts
            m = _COUNTER_PATH_RE.search(path)
            if not m:
                continue
            try:
                value = float(value_str)
            except ValueError:
                continue
            if value <= 0:
                continue
            self.samples.append({
                "t_ms": int(ts_str),
                "pid": int(m.group("pid")),
                "luid_lo": m.group("luid_lo").lower(),
                "phys": int(m.group("phys")),
                "eng": m.group("eng"),
                "value": value,
            })

    def __exit__(self, *a):
        if self._proc is not None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=3)
            except Exception:
                self._proc.kill()
        if self._reader_thread is not None:
            self._reader_thread.join(timeout=2)

    def summary_for_pid(self, pid, adapters=None):
        """
        Aggregates this monitor's captured samples for one specific process id,
        grouped by physical adapter (LUID), summed across engine types (see module
        docstring -- we don't guess which single D3D12 engine type WebGPU used).
        `adapters` (optional): enumerate_dxgi_adapters() output, used to label each
        LUID with its vendor/device identity for the report.
        """
        adapters = adapters or {}
        by_luid = {}
        for s in self.samples:
            if s["pid"] != pid:
                continue
            by_luid.setdefault(s["luid_lo"], []).append((s["t_ms"], s["eng"], s["value"]))

        result = {"pid": pid, "n_ticks_total": self.n_ticks, "adapters": {}}
        for luid_lo, entries in by_luid.items():
            values = [v for _, _, v in entries]
            engines_seen = sorted(set(e for _, e, _ in entries))
            adapter_info = adapters.get(luid_lo, {"description": "UNKNOWN (not in DirectX registry)"})
            result["adapters"][luid_lo] = {
                **adapter_info,
                "n_nonzero_samples": len(values),
                "max_utilization_pct": max(values) if values else None,
                "avg_utilization_pct_of_nonzero": (sum(values) / len(values)) if values else None,
                "engine_types_active": engines_seen,
            }
        return result


if __name__ == "__main__":
    print("DXGI adapters (from HKLM\\SOFTWARE\\Microsoft\\DirectX):")
    for luid, info in enumerate_dxgi_adapters().items():
        print(f"  luid_lo=0x{luid} {info}")

    duration = float(sys.argv[1]) if len(sys.argv) > 1 else 5.0
    print(f"\nSampling ALL processes' GPU engine activity for {duration:.1f}s (idle-baseline smoke test)...")
    with GpuEngineMonitor(interval_ms=250) as mon:
        time.sleep(duration)
    print(f"n_ticks={mon.n_ticks} n_nonzero_samples={len(mon.samples)}")
    pids_seen = sorted(set(s["pid"] for s in mon.samples))
    print(f"PIDs with any nonzero GPU engine activity during this window: {pids_seen}")
