#!/usr/bin/env python3
"""Build a Linux CPython 3.12 x86_64 wheelhouse for STEMwerk installer payloads."""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name


BOOTSTRAP_REQUIREMENTS = (
    "pip",
    "setuptools",
    "wheel",
)

TORCH_REQUIREMENTS = (
    "torch",
    "torchaudio",
    "torchvision",
)

TORCH_INDEX_DEPENDENCY_PREFIXES = (
    "pytorch-triton",
)

TARGET_ENV = {
    "sys_platform": "linux",
    "platform_system": "Linux",
    "platform_machine": "x86_64",
    "python_version": "3.12",
    "python_full_version": "3.12.13",
    "implementation_name": "cpython",
    "platform_python_implementation": "CPython",
    "extra": "",
}

TARGET_PLATFORM_ARGS = [
    "--only-binary=:all:",
    "--platform",
    "manylinux2014_x86_64",
    "--platform",
    "manylinux_2_28_x86_64",
    "--python-version",
    "312",
    "--implementation",
    "cp",
    "--abi",
    "cp312",
]

TORCH_PLATFORM_ARGS = [
    "--platform",
    "linux_x86_64",
]


@dataclass(frozen=True)
class WheelhouseSpec:
    requirements: tuple[str, ...]
    index_url: Optional[str] = None
    extra_index_url: Optional[str] = None
    skipped_dependency_names: tuple[str, ...] = ()


SPECS: Dict[tuple[str, str], WheelhouseSpec] = {
    ("main", "cpu"): WheelhouseSpec(
        requirements=(
            "audio-separator==0.23.0",
            "numpy==1.26.4",
            "numba==0.59.1",
            "llvmlite==0.42.0",
            "scipy==1.17.1",
            "onnxruntime",
            "torch==2.5.1",
            "torchvision==0.20.1",
            "torchaudio==2.5.1",
        ),
        index_url="https://download.pytorch.org/whl/cpu",
    ),
    ("main", "cuda"): WheelhouseSpec(
        requirements=(
            "audio-separator[gpu]==0.23.0",
            "numpy==1.26.4",
            "numba==0.59.1",
            "llvmlite==0.42.0",
            "scipy==1.17.1",
            "onnxruntime",
            "torch==2.5.1",
            "torchvision==0.20.1",
            "torchaudio==2.5.1",
        ),
    ),
    ("main", "rocm"): WheelhouseSpec(
        requirements=(
            "audio-separator==0.23.0",
            "numpy==1.26.4",
            "numba==0.59.1",
            "llvmlite==0.42.0",
            "scipy==1.17.1",
            "onnxruntime",
        ),
        index_url="https://download.pytorch.org/whl/rocm6.4",
        # The Linux bootstrap selects the main ROCm torch stack dynamically
        # at install time. Do not bake a mismatched service-line torch set into
        # the main ROCm wheelhouse or pip repair will resolve against the wrong
        # local wheels and duplicate multi-GB torch payloads in the AppImage.
        skipped_dependency_names=(
            "torch",
            "torchaudio",
            "torchvision",
            "pytorch-triton",
            "pytorch-triton-rocm",
        ),
    ),
    ("drumsep", "cpu"): WheelhouseSpec(
        requirements=(
            "audio-separator==0.34.1",
            "numpy==2.4.6",
            "onnxruntime==1.26.0",
            "onnx==1.21.0",
            "onnx2torch==1.5.15",
            "onnx2torch-py313==1.6.0",
            "torch==2.12.0+cpu",
            "torchvision==0.27.0+cpu",
            "numba==0.65.1",
        ),
        index_url="https://download.pytorch.org/whl/cpu",
    ),
    ("drumsep", "cuda"): WheelhouseSpec(
        requirements=(
            "audio-separator==0.34.1",
            "numpy==2.4.6",
            "onnxruntime-gpu==1.24.4",
            "onnx==1.21.0",
            "onnx2torch==1.5.15",
            "torch==2.4.1+cu121",
            "torchvision==0.19.1+cu121",
            "torchaudio==2.4.1+cu121",
            "numba==0.65.1",
        ),
        index_url="https://download.pytorch.org/whl/cu121",
    ),
    ("drumsep", "rocm"): WheelhouseSpec(
        requirements=(
            "audio-separator==0.34.1",
            "numpy==2.4.6",
            "onnxruntime==1.26.0",
            "onnx==1.21.0",
            "onnx2torch==1.5.15",
            "onnx2torch-py313==1.6.0",
            "torch==2.9.1+rocm6.4",
            "torchvision==0.24.1+rocm6.4",
            "torchaudio==2.9.1+rocm6.4",
            "numba==0.65.1",
        ),
        index_url="https://download.pytorch.org/whl/rocm6.4",
    ),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", choices=("main", "drumsep"), required=True)
    parser.add_argument("--backend", choices=("cpu", "cuda", "rocm"), required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--extra-wheel-dir", action="append", default=[])
    return parser.parse_args()


def requirement_name(requirement: str) -> str:
    return canonicalize_name(Requirement(requirement).name)


def uses_torch_index(requirement: str) -> bool:
    name = requirement_name(requirement)
    return name in TORCH_REQUIREMENTS or any(name.startswith(prefix) for prefix in TORCH_INDEX_DEPENDENCY_PREFIXES)


def run_pip_download(requirement: str, out_dir: Path, spec: WheelhouseSpec) -> None:
    cmd = [sys.executable, "-m", "pip", "download", "--dest", str(out_dir), "--no-deps", *TARGET_PLATFORM_ARGS]
    if uses_torch_index(requirement):
        cmd += TORCH_PLATFORM_ARGS
    if spec.index_url and uses_torch_index(requirement):
        cmd += ["--index-url", spec.index_url]
    if spec.extra_index_url and uses_torch_index(requirement):
        cmd += ["--extra-index-url", spec.extra_index_url]
    cmd.append(requirement)
    subprocess.run(cmd, check=True)


def run_bootstrap_downloads(out_dir: Path) -> None:
    for requirement in BOOTSTRAP_REQUIREMENTS:
        cmd = [sys.executable, "-m", "pip", "download", "--dest", str(out_dir), "--no-deps", *TARGET_PLATFORM_ARGS, requirement]
        subprocess.run(cmd, check=True)


def extract_requirements_from_wheel(wheel_path: Path) -> List[Requirement]:
    reqs: List[Requirement] = []
    with zipfile.ZipFile(wheel_path, "r") as zf:
        metadata_name = next((name for name in zf.namelist() if name.endswith(".dist-info/METADATA")), None)
        if not metadata_name:
            return reqs
        data = zf.read(metadata_name).decode("utf-8", errors="ignore")
    for line in data.splitlines():
        if not line.startswith("Requires-Dist:"):
            continue
        try:
            reqs.append(Requirement(line.split(":", 1)[1].strip()))
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
    return f"{req.name}{req.specifier}" if req.specifier else req.name


def copy_extra_wheels(dest_dir: Path, wheel_dirs: Iterable[str]) -> None:
    for wheel_dir in wheel_dirs:
        path = Path(wheel_dir).expanduser().resolve()
        if not path.is_dir():
            continue
        for wheel in sorted(path.glob("*.whl")):
            shutil.copy2(wheel, dest_dir / wheel.name)


def wheel_distribution_name(wheel_path: Path) -> Optional[str]:
    with zipfile.ZipFile(wheel_path, "r") as zf:
        metadata_name = next((name for name in zf.namelist() if name.endswith(".dist-info/METADATA")), None)
        if not metadata_name:
            return None
        data = zf.read(metadata_name).decode("utf-8", errors="ignore")
    for line in data.splitlines():
        if line.startswith("Name:"):
            return canonicalize_name(line.split(":", 1)[1].strip())
    return None


def preloaded_wheel_names(out_dir: Path) -> Dict[str, str]:
    names: Dict[str, str] = {}
    for wheel_path in sorted(out_dir.glob("*.whl")):
        dist_name = wheel_distribution_name(wheel_path)
        if dist_name:
            names.setdefault(dist_name, wheel_path.name)
    return names


def main() -> int:
    args = parse_args()
    spec = SPECS[(args.runtime, args.backend)]
    skipped_dependency_names = {canonicalize_name(name) for name in spec.skipped_dependency_names}
    out_dir = Path(args.output_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    copy_extra_wheels(out_dir, args.extra_wheel_dir)
    run_bootstrap_downloads(out_dir)

    queue: List[str] = list(spec.requirements)
    seen_specs: Set[str] = set()
    resolved_names: Dict[str, str] = preloaded_wheel_names(out_dir)

    while queue:
        requirement = queue.pop(0)
        if requirement in seen_specs:
            continue
        seen_specs.add(requirement)
        name_key = requirement_name(requirement)
        if name_key in resolved_names:
            continue

        before = set(out_dir.glob("*.whl"))
        run_pip_download(requirement, out_dir, spec)
        after = set(out_dir.glob("*.whl"))
        resolved_names[name_key] = requirement

        new_wheels = sorted(after - before)
        if not new_wheels:
            continue
        wheel_path = new_wheels[-1]
        for dep in extract_requirements_from_wheel(wheel_path):
            if not requirement_applies(dep):
                continue
            dep_name = canonicalize_name(dep.name)
            if dep_name in skipped_dependency_names:
                continue
            if dep_name in resolved_names:
                continue
            queue.append(requirement_to_spec(dep))

    print(f"Wheelhouse ready at {out_dir}")
    print(f"runtime={args.runtime} backend={args.backend} wheels={len(list(out_dir.glob('*.whl')))}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
