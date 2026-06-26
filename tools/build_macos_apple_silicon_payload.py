#!/usr/bin/env python3
"""Prepare a bundled Apple Silicon macOS payload for STEMwerk package variants."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path


CORE_MODEL_FILES = (
    "htdemucs.yaml",
    "955717e8-8726e21a.th",
    "htdemucs_ft.yaml",
    "f7e0c4bc-ba3fe64a.th",
    "d12395a8-e57c48e6.th",
    "92cfc3b6-ef3bcb9c.th",
    "04573f0d-f3cf25b2.th",
    "htdemucs_6s.yaml",
    "5c90dfd2-34c22ccb.th",
    "download_checks.json",
)

DRUMSEP_FILES = (
    "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt",
    "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml",
)

BOOTSTRAP_REQUIREMENTS = (
    "pip",
    "setuptools",
    "wheel",
)

MAIN_REQUIREMENTS = (
    "numpy==1.26.4",
    "torch==2.5.1",
    "torchvision==0.20.1",
    "torchaudio==2.5.1",
    "audio-separator==0.23.0",
    "llvmlite==0.42.0",
    "numba==0.59.1",
    "onnxruntime-silicon",
    "onnxruntime",
)

TARGET_PLATFORM_ARGS = [
    "--only-binary=:all:",
    "--platform",
    "macosx_11_0_arm64",
    "--python-version",
    "312",
    "--implementation",
    "cp",
    "--abi",
    "cp312",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument(
        "--model-cache",
        default=str(Path.home() / "Library" / "Application Support" / "STEMwerk" / "models"),
    )
    parser.add_argument("--ffmpeg", default="/opt/homebrew/bin/ffmpeg")
    parser.add_argument("--ffprobe", default="/opt/homebrew/bin/ffprobe")
    parser.add_argument(
        "--constraints",
        default="scripts/reaper/constraints/macos.txt",
    )
    return parser.parse_args()


def ensure_file(path: Path, label: str) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"Missing required {label}: {path}")


def reset_dir(path: Path) -> None:
    if path.exists():
        shutil.rmtree(path)
    path.mkdir(parents=True, exist_ok=True)


def copy_files(src_root: Path, dest_root: Path, names: tuple[str, ...], label: str) -> None:
    dest_root.mkdir(parents=True, exist_ok=True)
    for name in names:
        src = src_root / name
        ensure_file(src, label)
        shutil.copy2(src, dest_root / name)


def copy_ffmpeg(ffmpeg_path: Path, ffprobe_path: Path, dest_root: Path) -> None:
    ensure_file(ffmpeg_path, "ffmpeg binary")
    ensure_file(ffprobe_path, "ffprobe binary")
    dest_root.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ffmpeg_path, dest_root / "ffmpeg")
    shutil.copy2(ffprobe_path, dest_root / "ffprobe")


def run_pip_download(requirements: tuple[str, ...], wheels_dir: Path, constraints_file: Path) -> None:
    wheels_dir.mkdir(parents=True, exist_ok=True)
    for requirement in requirements:
        cmd = [
            sys.executable,
            "-m",
            "pip",
            "download",
            "--dest",
            str(wheels_dir),
            *TARGET_PLATFORM_ARGS,
        ]
        if constraints_file.is_file() and requirement not in BOOTSTRAP_REQUIREMENTS:
            cmd += ["-c", str(constraints_file)]
        cmd.append(requirement)
        subprocess.run(cmd, check=True)


def write_manifest(output_dir: Path, version: str) -> None:
    manifest = {
        "platform": "macos-apple-silicon",
        "version": version,
        "runtime_policy": "mps_preferred_cpu_fallback",
        "contains": {
            "ffmpeg": True,
            "wheels": True,
            "core_models": True,
            "drumsep": True,
        },
    }
    (output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    repo_root = Path.cwd().resolve()
    output_dir = (repo_root / args.output).resolve()
    model_cache = Path(args.model_cache).expanduser().resolve()
    ffmpeg_path = Path(args.ffmpeg).expanduser().resolve()
    ffprobe_path = Path(args.ffprobe).expanduser().resolve()
    constraints_file = (repo_root / args.constraints).resolve()

    reset_dir(output_dir)
    copy_ffmpeg(ffmpeg_path, ffprobe_path, output_dir / "ffmpeg")
    run_pip_download(BOOTSTRAP_REQUIREMENTS + MAIN_REQUIREMENTS, output_dir / "wheels", constraints_file)
    copy_files(model_cache, output_dir / "models", CORE_MODEL_FILES, "core model payload file")
    copy_files(model_cache, output_dir / "drumsep", DRUMSEP_FILES, "drumsep payload file")
    write_manifest(output_dir, args.version)
    print(f"Prepared Apple Silicon macOS payload at {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
