"""
Independent, kernel-level (amdgpu sysfs) per-GPU busy-percent sampler -- promoted to a
reusable module in L11 from L9/L10's own scratch tooling (`/tmp/l9_gpu_monitor.py`).

Completely outside onnxruntime/Dawn/Vulkan's own self-reported device metadata -- this
is the standard of evidence this project has used since L9 to distinguish "onnxruntime
claims a device was used" from "the physical GPU was actually busy". Linux/amdgpu only;
not a claim of portability to other platforms or vendors.
"""
from __future__ import annotations

import threading
import time


def read_busy(card: str):
    try:
        with open(f"/sys/class/drm/{card}/device/gpu_busy_percent") as f:
            return int(f.read().strip())
    except Exception:
        return None


def card_pci_slot(card: str):
    """Reads the PCI_SLOT_NAME from a card's uevent -- use this to confirm which
    /sys/class/drm/cardN corresponds to which physical GPU before trusting any
    busy-percent reading (identifiers can change across reboots/driver reloads;
    never assume cardN==GPU without checking, per L9/L10's own discipline)."""
    try:
        with open(f"/sys/class/drm/{card}/device/uevent") as f:
            for line in f:
                if line.startswith("PCI_SLOT_NAME="):
                    return line.strip().split("=", 1)[1]
    except Exception:
        return None
    return None


class DualCardMonitor:
    """Samples two cards' busy-percent at a fixed interval on a background thread for
    the duration of a `with` block. `card_a`/`card_b` are DRM card names (e.g. "card0",
    "card1") -- callers must confirm the mapping via `card_pci_slot()` first."""

    def __init__(self, card_a="card0", card_b="card1", interval_s=0.05):
        self.card_a = card_a
        self.card_b = card_b
        self.interval_s = interval_s
        self.samples = []
        self._stop = threading.Event()
        self._thread = None

    def _loop(self):
        while not self._stop.is_set():
            self.samples.append((time.time(), read_busy(self.card_a), read_busy(self.card_b)))
            time.sleep(self.interval_s)

    def __enter__(self):
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *a):
        self._stop.set()
        self._thread.join(timeout=2)

    def summary(self, high_threshold=70):
        """`*_frac_above_<threshold>` is included because on a machine with real
        background desktop/compositor load, plain averages over a full subprocess's
        wall-clock time (which includes non-GPU-bound model loading and audio I/O, not
        just the GPU-bound session.run() window) can be diluted enough that idle noise
        and genuine execution look similar in the mean alone -- the FRACTION of samples
        sustained above a high threshold separates them far more reliably than the mean
        or a single max sample does (found necessary during L11's own hardware
        validation, when this machine's idle load was noisier than in L9/L10)."""
        a = [s[1] for s in self.samples if s[1] is not None]
        b = [s[2] for s in self.samples if s[2] is not None]
        return {
            "n_samples": len(self.samples),
            f"{self.card_a}_max_busy_pct": max(a) if a else None,
            f"{self.card_a}_avg_busy_pct": sum(a) / len(a) if a else None,
            f"{self.card_a}_frac_above_{high_threshold}": (sum(1 for v in a if v >= high_threshold) / len(a)) if a else None,
            f"{self.card_b}_max_busy_pct": max(b) if b else None,
            f"{self.card_b}_avg_busy_pct": sum(b) / len(b) if b else None,
            f"{self.card_b}_frac_above_{high_threshold}": (sum(1 for v in b if v >= high_threshold) / len(b)) if b else None,
        }
