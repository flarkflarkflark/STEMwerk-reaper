#!/usr/bin/env python3
"""Apple Silicon samplerate architecture guard.

Repairs x86_64-only samplerate runtime on arm64 macOS by forcing samplerate==0.2.4,
then verifies imports and architecture evidence.
"""

from __future__ import annotations

import argparse
import importlib
import platform
import subprocess
import sys
import sysconfig
from pathlib import Path
from typing import Iterable


def _print_diag(key: str, value: object) -> None:
    print(f"STEMWERK_SAMPLERATE_GUARD {key}={value}")


def _file_output(path: Path) -> str:
    try:
        out = subprocess.check_output(["file", str(path)], text=True, stderr=subprocess.STDOUT)
        return out.strip()
    except Exception as exc:  # pragma: no cover
        return f"file_error:{exc}"


def _is_x86_only(file_out: str) -> bool:
    lower = (file_out or "").lower()
    return "x86_64" in lower and "arm64" not in lower and "universal" not in lower


def _is_arm_or_universal(file_out: str) -> bool:
    lower = (file_out or "").lower()
    return "arm64" in lower or "universal" in lower


def _module_search_roots(module: object) -> list[Path]:
    roots: list[Path] = []
    module_file = Path(getattr(module, "__file__", "") or "")
    if module_file:
        parent = module_file.resolve().parent
        # samplerate 0.1.x layout
        roots.append(parent / "samplerate" / "_samplerate_data")
        # samplerate 0.2.x layout (extension module + sibling data dir)
        roots.append(parent / "_samplerate_data")
        # keep module package root for package-style installs
        roots.append(parent / "samplerate")
    module_path = getattr(module, "__path__", None)
    if module_path:
        for p in module_path:
            try:
                roots.append(Path(p).resolve())
            except Exception:
                continue

    dedup: list[Path] = []
    seen: set[str] = set()
    for root in roots:
        key = str(root)
        if key not in seen:
            seen.add(key)
            dedup.append(root)
    return dedup


def _discover_dylibs(roots: Iterable[Path]) -> list[Path]:
    candidates: list[Path] = []
    for root in roots:
        if not root.exists():
            continue
        try:
            for path in root.rglob("*.dylib"):
                if path.is_file():
                    candidates.append(path.resolve())
        except Exception:
            continue
    dedup: list[Path] = []
    seen: set[str] = set()
    for path in sorted(candidates):
        key = str(path)
        if key not in seen:
            seen.add(key)
            dedup.append(path)
    return dedup


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
        "samplerate_dylib_candidate_count": "0",
        "samplerate_dylib_arm_or_universal_count": "0",
        "samplerate_dylib_x86_only_count": "0",
        "audio_separator_import": "not_checked",
        "audio_separator_error": "",
    }
    try:
        samplerate = importlib.import_module("samplerate")
    except Exception as exc:
        result["samplerate_error"] = str(exc).replace("\n", " ")
        return result

    result["samplerate_import"] = "ok"
    result["samplerate_version"] = str(getattr(samplerate, "__version__", ""))
    module_path = Path(getattr(samplerate, "__file__", "") or "")
    result["samplerate_module"] = str(module_path.resolve()) if module_path else ""

    roots = _module_search_roots(samplerate)
    result["samplerate_search_roots"] = "|".join(str(p) for p in roots)
    dylibs = _discover_dylibs(roots)
    result["samplerate_dylib_candidate_count"] = str(len(dylibs))

    arm_universal_count = 0
    x86_only_count = 0
    for idx, dylib in enumerate(dylibs):
        out = _file_output(dylib)
        result[f"samplerate_dylib_candidate_{idx}"] = str(dylib)
        result[f"samplerate_dylib_candidate_{idx}_file"] = out
        if _is_arm_or_universal(out):
            arm_universal_count += 1
        if _is_x86_only(out):
            x86_only_count += 1

    result["samplerate_dylib_arm_or_universal_count"] = str(arm_universal_count)
    result["samplerate_dylib_x86_only_count"] = str(x86_only_count)

    if dylibs:
        preferred = None
        for idx, dylib in enumerate(dylibs):
            out = result.get(f"samplerate_dylib_candidate_{idx}_file", "")
            if _is_arm_or_universal(out):
                preferred = (dylib, out)
                break
        if preferred is None:
            preferred = (dylibs[0], result.get("samplerate_dylib_candidate_0_file", ""))
        result["samplerate_dylib"] = str(preferred[0])
        result["samplerate_dylib_exists"] = "yes"
        result["samplerate_dylib_file"] = preferred[1]

    return result


def _repair_needed(probe: dict[str, str]) -> bool:
    if probe.get("samplerate_import") != "ok":
        return True
    x86_only = int(probe.get("samplerate_dylib_x86_only_count") or "0")
    arm_ok = int(probe.get("samplerate_dylib_arm_or_universal_count") or "0")
    if x86_only > 0 and arm_ok == 0:
        return True
    return False


def _run_pip(py: str, *args: str) -> int:
    cmd = [py, "-m", "pip", *args]
    _print_diag("pip_cmd", " ".join(cmd))
    return subprocess.call(cmd)


def _emit_probe(prefix: str, probe: dict[str, str]) -> None:
    for k, v in probe.items():
        _print_diag(f"{prefix}_{k}", v)


def _check_audio_separator_import() -> tuple[bool, str]:
    try:
        importlib.import_module("audio_separator")
        return True, ""
    except Exception as exc:
        return False, str(exc).replace("\n", " ")


def _is_samplerate_arch_failure(text: str) -> bool:
    lower = (text or "").lower()
    return "samplerate" in lower and "incompatible architecture" in lower


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
    if not _repair_needed(probe_before):
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
        "--no-deps",
        f"samplerate=={args.repair_version}",
    )
    if rc != 0:
        _print_diag("error", "samplerate_reinstall_failed")
        return 21

    probe_after = _probe_samplerate()
    _emit_probe("after", probe_after)
    if probe_after.get("samplerate_import") != "ok":
        _print_diag("error", "samplerate_import_failed_after_repair")
        return 22

    audio_ok, audio_err = _check_audio_separator_import()
    _print_diag("after_audio_separator_import", "ok" if audio_ok else "failed")
    if audio_err:
        _print_diag("after_audio_separator_error", audio_err)

    x86_only = int(probe_after.get("samplerate_dylib_x86_only_count") or "0")
    arm_ok = int(probe_after.get("samplerate_dylib_arm_or_universal_count") or "0")
    dylib_count = int(probe_after.get("samplerate_dylib_candidate_count") or "0")

    if dylib_count == 0:
        _print_diag("note", "samplerate_dylib_not_found_after_repair_but_import_ok")
    elif x86_only > 0 and arm_ok == 0:
        _print_diag("error", "samplerate_arch_mismatch_requires_runtime_rebuild")
        return 22

    if not audio_ok:
        if _is_samplerate_arch_failure(audio_err):
            _print_diag("error", "samplerate_arch_mismatch_requires_runtime_rebuild")
        else:
            _print_diag("error", "audio_separator_import_failed_after_samplerate_repair")
        return 22

    _print_diag("arch_match", "yes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
