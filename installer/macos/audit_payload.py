#!/usr/bin/env python3
"""Inventory and enforce the target-platform contract for macOS packages."""

from __future__ import annotations

import argparse
import json
import os
import stat
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tools.macos_ffmpeg import (
    sha256_file,
    validate_macho_tree_release_contract,
    validate_macho_wheel_release_contract,
    validate_official_provenance,
)
from tools.macos_managed_python import (
    find_forbidden_python_cache_paths,
    validate_official_managed_python_provenance,
)
from tools.macos_release_hygiene import validate_macos_release_wheelhouse


WINDOWS_SUFFIXES = {".exe", ".dll", ".bat", ".cmd", ".ps1"}
WINDOWS_WHEEL_MARKERS = ("win32", "win_amd64", "win_arm64")
LINUX_WHEEL_MARKERS = ("linux_", "manylinux", "musllinux")
FORBIDDEN_NAMES = {"STEMwerk_Bootstrap_Linux.sh", "STEMwerk_Bootstrap_Linux_Launcher.sh"}


def validate_payload_cache_hygiene(root: Path) -> None:
    forbidden = find_forbidden_python_cache_paths(root)
    if forbidden:
        raise RuntimeError(
            "macOS payload contains forbidden Python cache entries: "
            + ", ".join(forbidden)
        )


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
    validate_payload_cache_hygiene(root)
    records: list[dict[str, object]] = []
    counts = {key: 0 for key in ("windows", "linux", "linux_wheels", "windows_wheels", "elf", "unknown_native", "appledouble")}
    seen: set[str] = set()
    for path in [root, *sorted(root.rglob("*"))]:
        metadata = path.lstat()
        mode = metadata.st_mode
        relative = "." if path == root else path.relative_to(root).as_posix()
        if relative in seen:
            raise RuntimeError(f"duplicate payload destination: {relative}")
        seen.add(relative)

        if stat.S_ISDIR(mode):
            entry_type = "directory"
        elif stat.S_ISLNK(mode):
            entry_type = "symlink"
        elif stat.S_ISREG(mode):
            entry_type = "file"
        else:
            entry_type = "special"

        description = file_description(path) if entry_type == "file" else entry_type
        classification = classify(relative, description) if entry_type == "file" else entry_type
        if path.name.startswith("._"):
            counts["appledouble"] += 1
        platform = wheel_platform(path.name) if entry_type == "file" and path.suffix.lower() == ".whl" else None
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
        if entry_type == "special":
            counts["unknown_native"] += 1
        records.append({
            "path": relative,
            "type": entry_type,
            "mode": format(stat.S_IMODE(mode), "04o"),
            "size": metadata.st_size if entry_type in {"file", "symlink"} else None,
            "sha256": sha256_file(path) if entry_type == "file" else None,
            "link_target": os.readlink(path) if entry_type == "symlink" else None,
            "architecture": description if "Mach-O" in description else None,
            "wheel_platform": platform,
            "classification": classification,
        })
    return records, counts


def audit_bundled_apple_silicon_payload(root: Path) -> None:
    validate_payload_cache_hygiene(root)
    bundled = root / "_bundled/macos/apple-silicon"
    ffmpeg_dir = bundled / "ffmpeg"
    manifest_path = bundled / "manifest.json"
    wheels_dir = bundled / "wheels"
    validate_macos_release_wheelhouse(wheels_dir)
    for wheel in sorted(wheels_dir.rglob("*.whl")):
        validate_macho_wheel_release_contract(wheel)
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Invalid bundled Apple Silicon manifest: {exc}") from exc
    if not isinstance(manifest, dict):
        raise RuntimeError("Bundled Apple Silicon manifest must be a JSON object")
    validate_official_provenance(ffmpeg_dir, manifest=manifest)
    validate_official_managed_python_provenance(bundled / "python", manifest)
    root_notice = root / "THIRD_PARTY_NOTICES.md"
    bundled_notice = ffmpeg_dir / "THIRD_PARTY_NOTICES.md"
    if not root_notice.is_file() or sha256_file(root_notice) != sha256_file(bundled_notice):
        raise RuntimeError("Package and bundled FFmpeg third-party notices are missing or inconsistent")
    # Uses the default maximum_deployment_target (BUNDLED_APPLE_SILICON_MACOS_
    # AUDIT_MAXIMUM, "14.0") -- the bundled Apple Silicon package's own
    # contract, not FFmpeg's build target.
    validate_macho_tree_release_contract(bundled)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--variant", required=True)
    parser.add_argument("--inventory", type=Path, required=True)
    args = parser.parse_args()
    records, counts = inventory(args.root)
    required = [
        "STEMwerk_Bootstrap_macOS.sh", "STEMwerk.lua", "THIRD_PARTY_NOTICES.md",
        "_internal/STEMwerk_Helpers.lua", "_internal/STEMwerk_Managed_Python.lua",
    ]
    missing = [path for path in required if not (args.root / path).is_file()]
    if args.variant == "online" and (args.root / "_bundled/macos/apple-silicon").exists():
        raise SystemExit("ERROR: online payload contains bundled Apple Silicon runtime")
    if args.variant != "online":
        required_payload = [
            "manifest.json", "python", "wheels", "ffmpeg/ffmpeg", "ffmpeg/ffprobe",
            "ffmpeg/COPYING.LGPLv2.1", "ffmpeg/SOURCE_PROVENANCE.json",
            "ffmpeg/THIRD_PARTY_NOTICES.md", "ffmpeg/PROVENANCE.md",
        ]
        if args.variant == "offline-bundled-apple-silicon-mps-allmodels":
            # Alleen het allmodels-megapack bundelt modellen; sinds 2.3.1.0 is
            # bundled-apple-silicon runtime-only (modellen komen via de online catalogus).
            required_payload += ["models", "drumsep"]
        for path in required_payload:
            if not (args.root / "_bundled/macos/apple-silicon" / path).exists():
                missing.append(f"_bundled/macos/apple-silicon/{path}")
        if not missing:
            audit_bundled_apple_silicon_payload(args.root)
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
