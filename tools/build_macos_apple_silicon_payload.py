#!/usr/bin/env python3
"""Prepare a bundled Apple Silicon macOS payload for STEMwerk package variants."""

from __future__ import annotations

import argparse
import hashlib
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
    "scipy==1.18.0",
    "numba==0.66.0",
    "llvmlite==0.48.0",
    "torch==2.5.1",
    "torchvision==0.20.1",
    "torchaudio==2.5.1",
    "audio-separator==0.44.3",
    "samplerate==0.1.0",
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
    parser.add_argument("--version")
    parser.add_argument("--output")
    parser.add_argument("--audit-existing")
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
    missing_exact = []
    wrong_platform = []
    for requirement in MAIN_REQUIREMENTS:
        if "==" not in requirement:
            continue
        name, wanted = requirement.split("==", 1)
        wheel_prefix = name.replace("-", "_") + "-" + wanted + "-"
        matches = [path for path in wheels_dir.glob("*.whl") if path.name.lower().startswith(wheel_prefix.lower())]
        if not matches:
            missing_exact.append(requirement)
            continue
        for path in matches:
            filename = path.name.lower()
            if filename.endswith("-none-any.whl"):
                continue
            if "cp312" not in filename or "macosx" not in filename or not any(
                tag in filename for tag in ("arm64", "universal2")
            ):
                wrong_platform.append(path.name)
    if missing_exact or wrong_platform:
        raise RuntimeError(
            "Invalid exact Apple Silicon wheelhouse: "
            f"missing={','.join(missing_exact) or 'none'}; "
            f"wrong_platform={','.join(wrong_platform) or 'none'}"
        )
    missing = [prefix for prefix in REQUIRED_WHEEL_PREFIXES if not any(wheels_dir.glob(f"{prefix}*.whl"))]
    missing += [pattern for pattern in REQUIRED_WHEEL_PATTERNS if not any(wheels_dir.glob(pattern))]
    if missing:
        missing_list = ", ".join(missing)
        raise RuntimeError(f"Incomplete wheelhouse for offline Apple Silicon payload: missing {missing_list}")


def audit_wheelhouse_resolution(wheels_dir: Path, python_executable: str) -> None:
    cmd = [
        python_executable,
        "-m",
        "pip",
        "install",
        "--dry-run",
        "--ignore-installed",
        "--no-cache-dir",
        "--no-index",
        "--find-links",
        str(wheels_dir),
        "--only-binary=:all:",
        *MAIN_REQUIREMENTS,
    ]
    subprocess.run(cmd, check=True, env=command_env())


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


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_manifest(output_dir: Path, version: str) -> None:
    wheel_inventory = [
        {"filename": path.name, "sha256": sha256_file(path)}
        for path in sorted((output_dir / "wheels").glob("*.whl"))
    ]
    manifest = {
        "platform": "macos-apple-silicon",
        "version": version,
        "runtime_policy": "mps_preferred_cpu_fallback",
        "python_tag": "cp312",
        "architecture": "arm64",
        "runtime_requirements": list(MAIN_REQUIREMENTS),
        "wheel_inventory": wheel_inventory,
        "contains": {
            "ffmpeg": True,
            "python": True,
            "wheels": True,
            "core_models": True,
            "drumsep": True,
        },
    }
    (output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def audit_existing_manifest(output_dir: Path) -> None:
    manifest_path = output_dir / "manifest.json"
    ensure_file(manifest_path, "Apple Silicon payload manifest")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("platform") != "macos-apple-silicon":
        raise RuntimeError("Apple Silicon payload manifest has the wrong platform")
    if manifest.get("python_tag") != "cp312" or manifest.get("architecture") != "arm64":
        raise RuntimeError("Apple Silicon payload manifest has the wrong Python or architecture tag")
    if manifest.get("runtime_requirements") != list(MAIN_REQUIREMENTS):
        raise RuntimeError("Apple Silicon payload manifest runtime requirements do not match policy")
    expected_inventory = {
        entry["filename"]: entry["sha256"] for entry in manifest.get("wheel_inventory", [])
    }
    actual_paths = sorted((output_dir / "wheels").glob("*.whl"))
    if set(expected_inventory) != {path.name for path in actual_paths}:
        raise RuntimeError("Apple Silicon payload manifest wheel inventory does not match wheelhouse")
    mismatched = [path.name for path in actual_paths if expected_inventory[path.name] != sha256_file(path)]
    if mismatched:
        raise RuntimeError(f"Apple Silicon payload wheel checksum mismatch: {','.join(mismatched)}")


def main() -> int:
    args = parse_args()
    repo_root = Path.cwd().resolve()
    if args.audit_existing:
        output_dir = Path(args.audit_existing).expanduser().resolve()
        python_executable = payload_python()
        ensure_wheelhouse_complete(output_dir / "wheels")
        audit_existing_manifest(output_dir)
        audit_wheelhouse_resolution(output_dir / "wheels", python_executable)
        print(f"Apple Silicon payload audit passed: {output_dir}")
        return 0
    if not args.version or not args.output:
        raise SystemExit("--version and --output are required unless --audit-existing is used")
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
    audit_wheelhouse_resolution(output_dir / "wheels", python_executable)
    copy_tree(managed_python_dir, output_dir / "python", "managed Python runtime payload")
    copy_files(model_cache, output_dir / "models", CORE_MODEL_FILES, "core model payload file")
    copy_files(model_cache, output_dir / "drumsep", DRUMSEP_FILES, "drumsep payload file")
    write_manifest(output_dir, args.version)
    print(f"Prepared Apple Silicon macOS payload at {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
