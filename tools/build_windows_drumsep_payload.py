#!/usr/bin/env python3
"""Prepare Windows offline DrumSep payloads for bundled allmodels installers."""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Set

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name


PLATFORM_ARGS = [
    "--only-binary=:all:",
    "--platform",
    "win_amd64",
    "--python-version",
    "311",
    "--implementation",
    "cp",
    "--abi",
    "cp311",
]

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

DRUMSEP_MODEL_FILES = [
    "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt",
    "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml",
]


@dataclass(frozen=True)
class BackendSpec:
    backend: str
    output_dir: str
    base_dir: str
    source_family: str
    extra_index_url: str | None
    requirements: tuple[str, ...]


BACKENDS = (
    BackendSpec(
        backend="nvidia",
        output_dir="drumsep-wheels-nvidia",
        base_dir="wheels-nvidia",
        source_family="pypi+pytorch-cu121",
        extra_index_url="https://download.pytorch.org/whl/cu121",
        requirements=(
            "audio-separator==0.34.1",
            "onnxruntime==1.26.0",
            "torch==2.4.1+cu121",
            "torchvision==0.19.1+cu121",
            "torchaudio==2.4.1+cu121",
            "onnxruntime-gpu==1.24.4",
        ),
    ),
    BackendSpec(
        backend="directml",
        output_dir="drumsep-wheels-directml",
        base_dir="wheels-directml",
        source_family="pypi",
        extra_index_url=None,
        requirements=(
            "audio-separator==0.34.1",
            "torch==2.4.1",
            "torchvision==0.19.1",
            "torch-directml==0.2.5.dev240914",
            "onnxruntime-directml==1.24.4",
            "onnx==1.21.0",
            "onnx2torch==1.5.15",
            "librosa==0.11.0",
            "samplerate==0.1.0",
            "soundfile==0.14.0",
        ),
    ),
    BackendSpec(
        backend="cpu",
        output_dir="drumsep-wheels-cpu",
        base_dir="wheels-cpu",
        source_family="pypi",
        extra_index_url=None,
        requirements=(
            "audio-separator==0.34.1",
            "numpy==2.4.6",
            "onnxruntime==1.26.0",
            "onnx==1.21.0",
            "onnx2torch==1.5.15",
            "onnx2torch-py313==1.6.0",
            "torch==2.12.0",
            "torchvision==0.27.0",
            "numba==0.65.1",
        ),
    ),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--payload-root", default="installer/windows/payload")
    parser.add_argument(
        "--model-src",
        default=os.path.expanduser("~/.local/share/STEMwerk/models"),
    )
    parser.add_argument("--manifest", default=None)
    return parser.parse_args()


def sha256sum(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def ensure_file(path: Path) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"Missing required file: {path}")


def pip_download(requirements: tuple[str, ...], out_dir: Path, extra_index_url: str | None) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    queue: List[str] = list(requirements)
    seen_specs: Set[str] = set()
    resolved_names: Dict[str, str] = {}
    while queue:
        spec = queue.pop(0)
        if spec in seen_specs:
            continue
        seen_specs.add(spec)

        req_obj = Requirement(spec)
        name_key = canonicalize_name(req_obj.name)
        if name_key in resolved_names:
            continue

        before = set(out_dir.glob("*.whl"))
        cmd = [sys.executable, "-m", "pip", "download", "--dest", str(out_dir)]
        cmd += PLATFORM_ARGS
        cmd += ["--no-deps"]
        if extra_index_url:
            cmd += ["--extra-index-url", extra_index_url]
        cmd += [spec]
        subprocess.run(cmd, check=True)
        after = set(out_dir.glob("*.whl"))
        new_wheels = sorted(after - before)
        resolved_names[name_key] = spec
        if not new_wheels:
            continue
        wheel_path = new_wheels[-1]
        for dep in extract_requirements_from_wheel(wheel_path):
            if not requirement_applies(dep):
                continue
            dep_name = canonicalize_name(dep.name)
            if dep_name in resolved_names:
                continue
            queue.append(requirement_to_spec(dep))


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


def remove_duplicates_against_base(out_dir: Path, base_dir: Path) -> None:
    if not base_dir.is_dir():
        return
    for wheel in sorted(out_dir.glob("*.whl")):
        if (base_dir / wheel.name).is_file():
            wheel.unlink()


def copy_models(model_src: Path, model_dest: Path) -> list[Path]:
    model_dest.mkdir(parents=True, exist_ok=True)
    copied: list[Path] = []
    for name in DRUMSEP_MODEL_FILES:
        src = model_src / name
        ensure_file(src)
        dest = model_dest / name
        shutil.copy2(src, dest)
        copied.append(dest)
    return copied


def write_manifest(manifest_path: Path, payload_root: Path, entries: list[tuple[str, str, Path]]) -> None:
    lines = ["# backend\tsource_family\trelpath\tsize_bytes\tsha256"]
    for backend, source_family, path in entries:
        lines.append(
            "\t".join(
                [
                    backend,
                    source_family,
                    str(path.relative_to(payload_root)),
                    str(path.stat().st_size),
                    sha256sum(path),
                ]
            )
        )
    manifest_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    repo_root = Path.cwd()
    payload_root = (repo_root / args.payload_root).resolve()
    model_src = Path(args.model_src).expanduser().resolve()
    manifest_path = (
        Path(args.manifest).resolve()
        if args.manifest
        else payload_root / "drumsep-payload-manifest.txt"
    )

    entries: list[tuple[str, str, Path]] = []
    for spec in BACKENDS:
        out_dir = payload_root / spec.output_dir
        base_dir = payload_root / spec.base_dir
        pip_download(spec.requirements, out_dir, spec.extra_index_url)
        remove_duplicates_against_base(out_dir, base_dir)
        for wheel in sorted(out_dir.glob("*.whl")):
            entries.append((spec.backend, spec.source_family, wheel))

    model_dest = payload_root / "drumsep-models"
    for model in copy_models(model_src, model_dest):
        entries.append(("all", "local-cache", model))

    write_manifest(manifest_path, payload_root, entries)
    print(f"Prepared DrumSep payload under {payload_root}")
    print(f"Manifest: {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
