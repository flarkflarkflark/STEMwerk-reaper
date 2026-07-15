#!/usr/bin/env python3
"""Prepare a bundled Apple Silicon macOS payload for STEMwerk package variants."""

from __future__ import annotations

import argparse
import json
import os
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
    "numpy==2.4.4",
    "torch==2.5.1",
    "torchvision==0.20.1",
    "torchaudio==2.5.1",
    "audio-separator==0.44.3",
    "llvmlite==0.48.0",
    "numba==0.66.0",
    "onnxruntime",
)

DIFFQ_REQUIREMENT = "diffq==0.2.4"
SAMPLERATE_REQUIREMENT = "samplerate==0.1.0"

REQUIRED_WHEEL_PREFIXES = (
    "pip-",
    "setuptools-",
    "wheel-",
    "audio_separator-",
    "diffq-",
    "llvmlite-",
    "numba-",
    "numpy-",
    "onnxruntime-",
    "scipy-",
    "stemwerk_core-",
    "torch-",
    "torchaudio-",
    "torchvision-",
)

REQUIRED_WHEEL_PATTERNS = (
    "samplerate-0.1.0-*.whl",
)


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
        "--managed-python",
        default=str(Path.home() / "Library" / "Application Support" / "STEMwerk" / "python"),
    )
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


def copy_tree(src_root: Path, dest_root: Path, label: str) -> None:
    if not src_root.is_dir():
        raise FileNotFoundError(f"Missing required {label}: {src_root}")
    shutil.copytree(src_root, dest_root)


def command_env() -> dict[str, str]:
    env = os.environ.copy()
    env.setdefault("PIP_DISABLE_PIP_VERSION_CHECK", "1")
    return env


def python_version(python_executable: str) -> tuple[int, int]:
    cmd = [
        python_executable,
        "-c",
        "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')",
    ]
    result = subprocess.run(cmd, check=True, capture_output=True, text=True, env=command_env())
    major, minor = result.stdout.strip().split(".", 1)
    return int(major), int(minor)


def payload_python() -> str:
    candidates = (
        Path.home() / "Library" / "Application Support" / "STEMwerk" / ".venv" / "bin" / "python",
        Path("/opt/homebrew/bin/python3.12"),
        Path("/usr/local/bin/python3.12"),
        Path(sys.executable),
    )
    for candidate in candidates:
        if not candidate.is_file():
            continue
        version = python_version(str(candidate))
        if version == (3, 12):
            return str(candidate)
    raise RuntimeError("Missing native Python 3.12 interpreter for macOS Apple Silicon payload wheel downloads")


def run_pip_download(requirements: tuple[str, ...], wheels_dir: Path, constraints_file: Path, python_executable: str) -> None:
    wheels_dir.mkdir(parents=True, exist_ok=True)
    for requirement in requirements:
        cmd = [
            python_executable,
            "-m",
            "pip",
            "download",
            "--dest",
            str(wheels_dir),
            "--only-binary=:all:",
            "--find-links",
            str(wheels_dir),
        ]
        if constraints_file.is_file() and requirement not in BOOTSTRAP_REQUIREMENTS:
            cmd += ["-c", str(constraints_file)]
        cmd.append(requirement)
        subprocess.run(cmd, check=True, env=command_env())


def wheel_builder_python() -> str:
    return payload_python()


def ensure_diffq_wheel(wheels_dir: Path) -> None:
    if any(wheels_dir.glob("diffq-*.whl")):
        return
    cmd = [wheel_builder_python(), "-m", "pip", "wheel", "--no-deps", "--wheel-dir", str(wheels_dir), DIFFQ_REQUIREMENT]
    subprocess.run(cmd, check=True, env=command_env())


def ensure_samplerate_wheel(wheels_dir: Path) -> None:
    if any(wheels_dir.glob("samplerate-0.1.0-*.whl")):
        return
    cmd = [
        wheel_builder_python(),
        "-m",
        "pip",
        "download",
        "--dest",
        str(wheels_dir),
        "--only-binary=:all:",
        "--no-deps",
        SAMPLERATE_REQUIREMENT,
    ]
    subprocess.run(cmd, check=True, env=command_env())


def ensure_wheelhouse_complete(wheels_dir: Path) -> None:
    missing = [prefix for prefix in REQUIRED_WHEEL_PREFIXES if not any(wheels_dir.glob(f"{prefix}*.whl"))]
    missing += [pattern for pattern in REQUIRED_WHEEL_PATTERNS if not any(wheels_dir.glob(pattern))]
    if missing:
        missing_list = ", ".join(missing)
        raise RuntimeError(f"Incomplete wheelhouse for offline Apple Silicon payload: missing {missing_list}")


def build_stemwerk_core_wheel(repo_root: Path, wheels_dir: Path, python_executable: str) -> None:
    if any(wheels_dir.glob("stemwerk_core-*.whl")):
        return
    cmd = [
        python_executable,
        "-m",
        "pip",
        "wheel",
        "--no-deps",
        "--no-build-isolation",
        "--wheel-dir",
        str(wheels_dir),
        str(repo_root / "scripts" / "reaper" / "vendor" / "stemwerk-core"),
    ]
    subprocess.run(cmd, check=True, env=command_env())


def write_manifest(output_dir: Path, version: str) -> None:
    manifest = {
        "platform": "macos-apple-silicon",
        "version": version,
        "runtime_policy": "mps_preferred_cpu_fallback",
        "contains": {
            "ffmpeg": True,
            "python": True,
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
    managed_python_dir = Path(args.managed_python).expanduser().resolve()
    constraints_file = (repo_root / args.constraints).resolve()
    python_executable = payload_python()

    reset_dir(output_dir)
    copy_ffmpeg(ffmpeg_path, ffprobe_path, output_dir / "ffmpeg")
    try:
        run_pip_download(BOOTSTRAP_REQUIREMENTS + MAIN_REQUIREMENTS, output_dir / "wheels", constraints_file, python_executable)
    except subprocess.CalledProcessError:
        ensure_diffq_wheel(output_dir / "wheels")
        run_pip_download(BOOTSTRAP_REQUIREMENTS + MAIN_REQUIREMENTS, output_dir / "wheels", constraints_file, python_executable)
    ensure_samplerate_wheel(output_dir / "wheels")
    build_stemwerk_core_wheel(repo_root, output_dir / "wheels", python_executable)
    ensure_wheelhouse_complete(output_dir / "wheels")
    copy_tree(managed_python_dir, output_dir / "python", "managed Python runtime payload")
    copy_files(model_cache, output_dir / "models", CORE_MODEL_FILES, "core model payload file")
    copy_files(model_cache, output_dir / "drumsep", DRUMSEP_FILES, "drumsep payload file")
    write_manifest(output_dir, args.version)
    print(f"Prepared Apple Silicon macOS payload at {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
