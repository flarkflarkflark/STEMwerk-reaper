#!/usr/bin/env python3
"""Apple Silicon samplerate architecture guard.

Repairs x86_64-only samplerate dylib on arm64 macOS by forcing samplerate==0.2.4,
then verifies import and dylib architecture.
"""

from __future__ import annotations

import argparse
import importlib
import os
import platform
import subprocess
import sys
import sysconfig
from pathlib import Path


def _print_diag(key: str, value: object) -> None:
    print(f"STEMWERK_SAMPLERATE_GUARD {key}={value}")


def _file_output(path: Path) -> str:
    try:
        out = subprocess.check_output(["file", str(path)], text=True, stderr=subprocess.STDOUT)
        return out.strip()
    except Exception as exc:  # pragma: no cover
        return f"file_error:{exc}"


def _probe_samplerate() -> dict[str, str]:
    result: dict[str, str] = {
        "platform_machine": platform.machine(),
        "sysconfig_platform": str(sysconfig.get_platform()),
        "samplerate_import": "failed",
        "samplerate_version": "",
        "samplerate_module": "",
        "samplerate_dylib": "",
        "samplerate_dylib_exists": "no",
        "samplerate_dylib_file": "",
    }
    try:
        samplerate = importlib.import_module("samplerate")
    except Exception as exc:
        result["samplerate_error"] = str(exc).replace("\n", " ")
        return result

    result["samplerate_import"] = "ok"
    result["samplerate_version"] = str(getattr(samplerate, "__version__", ""))
    module_path = Path(getattr(samplerate, "__file__", ""))
    result["samplerate_module"] = str(module_path)
    dylib = module_path.resolve().parent / "_samplerate_data" / "libsamplerate.dylib"
    result["samplerate_dylib"] = str(dylib)
    if dylib.is_file():
        result["samplerate_dylib_exists"] = "yes"
        result["samplerate_dylib_file"] = _file_output(dylib)
    return result


def _arch_ok(probe: dict[str, str]) -> bool:
    if probe.get("samplerate_import") != "ok":
        return False
    if probe.get("samplerate_dylib_exists") != "yes":
        return False
    file_out = (probe.get("samplerate_dylib_file") or "").lower()
    return "arm64" in file_out or "universal" in file_out


def _run_pip(py: str, *args: str) -> int:
    cmd = [py, "-m", "pip", *args]
    _print_diag("pip_cmd", " ".join(cmd))
    return subprocess.call(cmd)


def _emit_probe(prefix: str, probe: dict[str, str]) -> None:
    for k, v in probe.items():
        _print_diag(f"{prefix}_{k}", v)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--python", default=sys.executable)
    parser.add_argument("--repair-version", default="0.2.4")
    args = parser.parse_args()

    mac_arch = platform.machine()
    _print_diag("mac_arch", mac_arch)
    if sys.platform != "darwin" or mac_arch != "arm64":
        _print_diag("guard", "skipped_non_arm64_macos")
        return 0

    probe_before = _probe_samplerate()
    _emit_probe("before", probe_before)
    if _arch_ok(probe_before):
        _print_diag("arch_match", "yes")
        _print_diag("repair_attempted", "no")
        return 0

    _print_diag("repair_attempted", "yes")
    _print_diag("arch_match", "no")

    _run_pip(args.python, "uninstall", "-y", "samplerate")
    rc = _run_pip(
        args.python,
        "install",
        "--force-reinstall",
        "--no-cache-dir",
        f"samplerate=={args.repair_version}",
    )
    if rc != 0:
        _print_diag("error", "samplerate_reinstall_failed")
        return 21

    probe_after = _probe_samplerate()
    _emit_probe("after", probe_after)
    if _arch_ok(probe_after):
        _print_diag("arch_match", "yes")
        return 0

    _print_diag("error", "samplerate_arch_mismatch_requires_runtime_rebuild")
    return 22


if __name__ == "__main__":
    raise SystemExit(main())
