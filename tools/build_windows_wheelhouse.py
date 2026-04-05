#!/usr/bin/env python3
"""Build a self-contained Windows wheelhouse for offline STEMwerk installs.

This script resolves dependencies by repeatedly downloading wheels (no sdists),
then parsing wheel metadata and enqueuing transitive dependencies that apply to
Windows CPython 3.11.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import Dict, Iterable, List, Set

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name


TARGET_ENV = {
    "sys_platform": "win32",
    "platform_system": "Windows",
    "platform_machine": "AMD64",
    "platform_release": "11",
    "python_version": "3.11",
    "python_full_version": "3.11.8",
    "implementation_name": "cpython",
    "platform_python_implementation": "CPython",
    "extra": "",
}

SKIP_DEP_NAMES = {
    "diffq",      # non-Windows dependency
    "julius",     # no reliable win_amd64 wheel on index
    "samplerate", # no reliable win_amd64 wheel on index
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build Windows wheelhouse for offline bootstrap")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--platform", default="win_amd64")
    parser.add_argument("--python-version", default="311")
    parser.add_argument("--implementation", default="cp")
    parser.add_argument("--abi", default="cp311")
    parser.add_argument("--include-cuda-wheels", type=int, choices=(0, 1), default=1)
    parser.add_argument("--include-directml-wheels", type=int, choices=(0, 1), default=0)
    return parser.parse_args()


def pip_download(requirement: str, out_dir: Path, args: argparse.Namespace) -> None:
    cmd = [
        sys.executable,
        "-m",
        "pip",
        "download",
        "--dest",
        str(out_dir),
        "--only-binary=:all:",
        "--platform",
        args.platform,
        "--python-version",
        args.python_version,
        "--implementation",
        args.implementation,
        "--abi",
        args.abi,
        "--no-deps",
        requirement,
    ]
    subprocess.run(cmd, check=True)


def pip_download_with_index(requirement: str, out_dir: Path, args: argparse.Namespace, index_url: str) -> None:
    cmd = [
        sys.executable,
        "-m",
        "pip",
        "download",
        "--dest",
        str(out_dir),
        "--only-binary=:all:",
        "--platform",
        args.platform,
        "--python-version",
        args.python_version,
        "--implementation",
        args.implementation,
        "--abi",
        args.abi,
        "--no-deps",
        "--index-url",
        index_url,
        requirement,
    ]
    subprocess.run(cmd, check=True)


def find_new_wheels(before: Set[Path], out_dir: Path) -> List[Path]:
    after = set(out_dir.glob("*.whl"))
    return sorted(after - before)


def extract_requirements_from_wheel(wheel_path: Path) -> List[Requirement]:
    reqs: List[Requirement] = []
    with zipfile.ZipFile(wheel_path, "r") as zf:
        metadata_name = None
        for name in zf.namelist():
            if name.endswith(".dist-info/METADATA"):
                metadata_name = name
                break
        if not metadata_name:
            return reqs
        data = zf.read(metadata_name).decode("utf-8", errors="ignore")

    for line in data.splitlines():
        if not line.startswith("Requires-Dist:"):
            continue
        spec = line.split(":", 1)[1].strip()
        try:
            reqs.append(Requirement(spec))
        except Exception:
            continue
    return reqs


def requirement_applies(req: Requirement) -> bool:
    if req.marker is None:
        return True
    try:
        return bool(req.marker.evaluate(TARGET_ENV))
    except Exception:
        return False


def requirement_to_spec(req: Requirement) -> str:
    if req.specifier:
        return f"{req.name}{req.specifier}"
    return req.name


def seeded_requirements(include_directml: bool) -> Iterable[str]:
    # Keep versions aligned with Windows bootstrap defaults.
    requirements = [
        "pip",
        "setuptools",
        "wheel",
        "pycparser",
        "Cython",
        "beartype>=0.18.5,<0.19.0",
        "diffq-fixed>=0.2",
        "einops>=0.7",
        "librosa>=0.10",
        "llvmlite<0.48,>=0.47.0dev0",
        "ml_collections",
        "MarkupSafe>=2.0",
        "numpy<2",
        "onnx>=1.14",
        "onnx2torch>=1.5",
        "soundfile>=0.12.1",
        "pydub>=0.25",
        "pyyaml",
        "requests>=2",
        "resampy>=0.4",
        "rotary-embedding-torch>=0.6.1,<0.7.0",
        "scipy>=1.13.0,<2.0.0",
        "six>=1.16",
        "tqdm",
        "onnxruntime==1.24.4",
        "torch==2.4.1",
        "torchvision==0.19.1",
        "audio-separator==0.24.4",
    ]
    if include_directml:
        requirements += [
            "torch-directml==0.2.5.dev240914",
            "onnxruntime-directml==1.24.4",
        ]
    return requirements


def main() -> int:
    args = parse_args()
    out_dir = Path(args.output_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)

    queue: List[str] = list(seeded_requirements(include_directml=bool(args.include_directml_wheels)))
    seen_specs: Set[str] = set()
    resolved_names: Dict[str, str] = {}

    while queue:
        spec = queue.pop(0)
        if spec in seen_specs:
            continue
        seen_specs.add(spec)

        req_obj = Requirement(spec)
        name_key = canonicalize_name(req_obj.name)
        if name_key in SKIP_DEP_NAMES:
            continue
        if name_key in resolved_names:
            continue

        before = set(out_dir.glob("*.whl"))
        pip_download(spec, out_dir, args)
        new_wheels = find_new_wheels(before, out_dir)

        if not new_wheels:
            # Wheel may already be present from previous resolution.
            resolved_names[name_key] = spec
            continue

        # Prefer the newest wheel from this download operation.
        wheel_path = new_wheels[-1]
        resolved_names[name_key] = spec

        for dep in extract_requirements_from_wheel(wheel_path):
            if not requirement_applies(dep):
                continue
            dep_name = canonicalize_name(dep.name)
            if dep_name in SKIP_DEP_NAMES:
                continue
            if dep_name in resolved_names:
                continue
            queue.append(requirement_to_spec(dep))

            # Bundle CUDA wheels explicitly so offline CUDA installs can succeed.
            if int(args.include_cuda_wheels) == 1:
                cuda_index = "https://download.pytorch.org/whl/cu121"
                pip_download_with_index("torch==2.4.1+cu121", out_dir, args, cuda_index)
                pip_download_with_index("torchvision==0.19.1+cu121", out_dir, args, cuda_index)

    print(f"Wheelhouse ready at {out_dir}")
    print(f"Total wheels: {len(list(out_dir.glob('*.whl')))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
