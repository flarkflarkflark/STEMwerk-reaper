#!/usr/bin/env python3
"""Inventory and enforce the target-platform contract for macOS packages."""

from __future__ import annotations

import argparse
import json
import os
import stat
import subprocess
from pathlib import Path


WINDOWS_SUFFIXES = {".exe", ".dll", ".bat", ".cmd", ".ps1"}
WINDOWS_WHEEL_MARKERS = ("win32", "win_amd64", "win_arm64")
LINUX_WHEEL_MARKERS = ("linux_", "manylinux", "musllinux")
FORBIDDEN_NAMES = {"STEMwerk_Bootstrap_Linux.sh", "STEMwerk_Bootstrap_Linux_Launcher.sh"}


def wheel_platform(name: str) -> str:
    lower = name.lower()
    if any(marker in lower for marker in WINDOWS_WHEEL_MARKERS):
        return "windows"
    if any(marker in lower for marker in LINUX_WHEEL_MARKERS):
        return "linux"
    if "macosx" in lower:
        return "macos"
    if lower.endswith("-any.whl"):
        return "shared-runtime"
    return "unknown"


def file_description(path: Path) -> str:
    result = subprocess.run(["file", "-b", str(path)], check=True, text=True, capture_output=True)
    return result.stdout.strip()


def classify(relative: str, description: str) -> str:
    path = Path(relative)
    lower = relative.lower()
    if path.suffix.lower() in WINDOWS_SUFFIXES or "bootstrap_windows" in lower:
        return "windows"
    if path.name in FORBIDDEN_NAMES or "bootstrap_linux" in lower or "linux_setup_guide" in lower:
        return "linux"
    if path.suffix.lower() == ".whl":
        return wheel_platform(path.name)
    if description.startswith("ELF"):
        return "linux"
    if relative.startswith("_bundled/macos/apple-silicon/"):
        return "apple-silicon-only"
    if path.suffix.lower() in {".lua", ".py", ".json", ".txt", ".md", ".svg", ".png"}:
        return "shared-runtime"
    if "Mach-O" in description:
        return "macos"
    if path.name == "STEMwerk_Bootstrap_macOS.sh" or relative.startswith("constraints/macos"):
        return "macos"
    return "unknown"


def inventory(root: Path) -> tuple[list[dict[str, object]], dict[str, int]]:
    records: list[dict[str, object]] = []
    counts = {key: 0 for key in ("windows", "linux", "linux_wheels", "windows_wheels", "elf", "unknown_native", "appledouble")}
    seen: set[str] = set()
    for path in sorted(root.rglob("*")):
        if path.is_dir():
            continue
        relative = path.relative_to(root).as_posix()
        if relative in seen:
            raise RuntimeError(f"duplicate payload destination: {relative}")
        seen.add(relative)
        description = file_description(path)
        classification = classify(relative, description)
        if path.name.startswith("._"):
            counts["appledouble"] += 1
        platform = wheel_platform(path.name) if path.suffix.lower() == ".whl" else None
        if classification == "windows":
            counts["windows"] += 1
        if classification == "linux":
            counts["linux"] += 1
        if platform == "linux":
            counts["linux_wheels"] += 1
        if platform == "windows":
            counts["windows_wheels"] += 1
        if description.startswith("ELF"):
            counts["elf"] += 1
        if ("executable" in description or path.suffix.lower() == ".whl") and classification == "unknown":
            counts["unknown_native"] += 1
        mode = path.lstat().st_mode
        records.append({
            "path": relative,
            "type": "symlink" if stat.S_ISLNK(mode) else "file",
            "size": path.lstat().st_size,
            "architecture": description if "Mach-O" in description else None,
            "wheel_platform": platform,
            "classification": classification,
        })
    return records, counts


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--variant", required=True)
    parser.add_argument("--inventory", type=Path, required=True)
    args = parser.parse_args()
    records, counts = inventory(args.root)
    required = ["STEMwerk_Bootstrap_macOS.sh", "STEMwerk.lua", "_internal/STEMwerk_Helpers.lua", "_internal/STEMwerk_Managed_Python.lua"]
    missing = [path for path in required if not (args.root / path).is_file()]
    if args.variant == "online" and (args.root / "_bundled/macos/apple-silicon").exists():
        raise SystemExit("ERROR: online payload contains bundled Apple Silicon runtime")
    if args.variant != "online":
        for path in ("manifest.json", "python", "wheels", "models", "drumsep", "ffmpeg"):
            if not (args.root / "_bundled/macos/apple-silicon" / path).exists():
                missing.append(f"_bundled/macos/apple-silicon/{path}")
    args.inventory.parent.mkdir(parents=True, exist_ok=True)
    args.inventory.write_text(json.dumps({"variant": args.variant, "counts": counts, "files": records}, indent=2) + "\n")
    if missing:
        raise SystemExit("ERROR: required payload missing: " + ", ".join(missing))
    if any(counts.values()):
        raise SystemExit("ERROR: forbidden or unknown native payload: " + json.dumps(counts, sort_keys=True))
    print(json.dumps(counts, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
