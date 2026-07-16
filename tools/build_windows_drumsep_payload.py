#!/usr/bin/env python3
"""Prepare Windows offline DrumSep payloads for bundled allmodels installers."""

from __future__ import annotations

import argparse
import hashlib
import json
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

REPO_ROOT = Path(__file__).resolve().parents[1]
DRUMSEP_COMPAT_CONTRACT_PATH = REPO_ROOT / "tools/assets/drumsep/compatibility_config_contract.json"
DRUMSEP_COMPAT_CONTRACT = json.loads(DRUMSEP_COMPAT_CONTRACT_PATH.read_text(encoding="utf-8"))
DRUMSEP_COMPAT_ASSET = REPO_ROOT / "tools/assets/drumsep" / DRUMSEP_COMPAT_CONTRACT["filename"]

DRUMSEP_MODEL_POLICY = {
    "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt": {
        "role": "canonical_model",
        "size": 437652699,
        "sha256": "d2a4aa53eb584d21eead358a4e66d1882ad182911be018f052b5da73be9096d0",
        "source": "model_cache",
    },
    "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml": {
        "role": "canonical_config",
        "size": 2417,
        "sha256": "440a13f67461b2cdad2bb1cb86c08ff27a8ec53093c4a24d4d7fc2c19cb9f5f5",
        "source": "model_cache",
    },
    DRUMSEP_COMPAT_CONTRACT["filename"]: {
        "role": DRUMSEP_COMPAT_CONTRACT["role"],
        "size": DRUMSEP_COMPAT_CONTRACT["canonical"]["size"],
        "sha256": DRUMSEP_COMPAT_CONTRACT["canonical"]["sha256"],
        "source": "shared_repository_asset",
    },
}


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
            "llvmlite==0.47.0",
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
    parser.add_argument(
        "--backends",
        default="nvidia,directml,cpu",
        help="Comma-separated existing backend names to prepare.",
    )
    parser.add_argument(
        "--wheel-source-root",
        default=None,
        help="Copy existing audited wheel directories instead of downloading packages.",
    )
    parser.add_argument(
        "--stage-root",
        default=None,
        help="Optionally assemble a local official bootstrap stage from the prepared payload.",
    )
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


def verify_file(path: Path, policy: dict[str, object]) -> None:
    ensure_file(path)
    size = path.stat().st_size
    expected_size = int(policy["size"])
    if size != expected_size:
        raise RuntimeError(f"size_mismatch:{path.name}:expected={expected_size}:actual={size}")
    actual_sha = sha256sum(path)
    expected_sha = str(policy["sha256"])
    if actual_sha != expected_sha:
        raise RuntimeError(f"checksum_mismatch:{path.name}:expected={expected_sha}:actual={actual_sha}")


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


def copy_models(model_src: Path, model_dest: Path) -> list[tuple[str, Path]]:
    if model_dest.exists():
        shutil.rmtree(model_dest)
    model_dest.mkdir(parents=True)
    copied: list[tuple[str, Path]] = []
    for name, policy in DRUMSEP_MODEL_POLICY.items():
        src = DRUMSEP_COMPAT_ASSET if policy["source"] == "shared_repository_asset" else model_src / name
        verify_file(src, policy)
        dest = model_dest / name
        shutil.copy2(src, dest)
        verify_file(dest, policy)
        copied.append((str(policy["role"]), dest))
    actual = {path.name for path in model_dest.iterdir() if path.is_file()}
    expected = set(DRUMSEP_MODEL_POLICY)
    if actual != expected:
        raise RuntimeError(
            f"drumsep_inventory_mismatch:missing={sorted(expected - actual)}:extra={sorted(actual - expected)}"
        )
    return copied


def write_manifest(manifest_path: Path, payload_root: Path, entries: list[tuple[str, str, str, Path]]) -> None:
    lines = ["# backend\tsource_family\trole\trelpath\tsize_bytes\tsha256"]
    for backend, source_family, role, path in entries:
        lines.append(
            "\t".join(
                [
                    backend,
                    source_family,
                    role,
                    path.relative_to(payload_root).as_posix(),
                    str(path.stat().st_size),
                    sha256sum(path),
                ]
            )
        )
    manifest_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def audit_payload(
    payload_root: Path,
    manifest_path: Path,
    selected_specs: list[BackendSpec],
) -> None:
    rows = []
    for line in manifest_path.read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 6:
            raise RuntimeError(f"manifest_field_count:{line}")
        rows.append(fields)
    relpaths = [row[3] for row in rows]
    if len(relpaths) != len(set(relpaths)):
        raise RuntimeError("manifest_duplicate_relpath")

    expected_files = {
        path.resolve()
        for spec in selected_specs
        for path in (payload_root / spec.output_dir).glob("*.whl")
    }
    expected_files.update((payload_root / "drumsep-models" / name).resolve() for name in DRUMSEP_MODEL_POLICY)
    manifest_files = {(payload_root / row[3]).resolve() for row in rows}
    if manifest_files != expected_files:
        raise RuntimeError(
            "manifest_filesystem_mismatch:"
            f"missing={sorted(str(path) for path in expected_files - manifest_files)}:"
            f"extra={sorted(str(path) for path in manifest_files - expected_files)}"
        )
    for backend, source_family, role, relpath, size_text, sha in rows:
        path = payload_root / relpath
        ensure_file(path)
        if path.stat().st_size != int(size_text) or sha256sum(path) != sha:
            raise RuntimeError(f"manifest_fingerprint_mismatch:{relpath}")
        if path.parent.name == "drumsep-models":
            policy = DRUMSEP_MODEL_POLICY.get(path.name)
            if not policy:
                raise RuntimeError(f"manifest_unexpected_drumsep_file:{path.name}")
            if backend != "all" or role != policy["role"] or source_family != policy["source"]:
                raise RuntimeError(f"manifest_drumsep_metadata_mismatch:{path.name}")
            verify_file(path, policy)


def copy_existing_wheels(source_root: Path, source_dir: str, destination: Path) -> None:
    source = source_root / source_dir
    if not source.is_dir() or not any(source.glob("*.whl")):
        raise RuntimeError(f"missing_local_wheel_payload:{source}")
    if destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination)


def stage_windows_payload(
    stage_root: Path,
    payload_root: Path,
    manifest_path: Path,
    selected_specs: list[BackendSpec],
    wheel_source_root: Path,
) -> None:
    if stage_root.exists():
        raise RuntimeError(f"existing_stage_requires_new_output:{stage_root}")
    shutil.copytree(REPO_ROOT / "scripts/reaper", stage_root)
    bundled = stage_root / "_bundled"
    shutil.copytree(payload_root / "drumsep-models", bundled / "drumsep-models")
    directml = next((spec for spec in selected_specs if spec.backend == "directml"), None)
    if directml:
        shutil.copytree(payload_root / directml.output_dir, bundled / "drumsep-wheels")
        copy_existing_wheels(wheel_source_root, directml.base_dir, bundled / "wheels")
    for source_dir in ("python", "ffmpeg"):
        source = wheel_source_root / source_dir
        if not source.is_dir():
            raise RuntimeError(f"missing_local_runtime_payload:{source}")
        shutil.copytree(source, bundled / source_dir)
    shutil.copy2(manifest_path, bundled / manifest_path.name)

    required = (
        stage_root / "STEMwerk_Bootstrap_Windows.ps1",
        bundled / "python/python-3.11.8-amd64.exe",
        bundled / "ffmpeg/ffmpeg-release-essentials.zip",
        bundled / "drumsep-models" / DRUMSEP_COMPAT_CONTRACT["filename"],
        bundled / manifest_path.name,
    )
    for path in required:
        ensure_file(path)
    verify_file(
        bundled / "drumsep-models" / DRUMSEP_COMPAT_CONTRACT["filename"],
        DRUMSEP_MODEL_POLICY[DRUMSEP_COMPAT_CONTRACT["filename"]],
    )
    if directml and (
        not any((bundled / "wheels").glob("*.whl"))
        or not any((bundled / "drumsep-wheels").glob("*.whl"))
    ):
        raise RuntimeError("stage_directml_wheel_payload_missing")


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

    entries: list[tuple[str, str, str, Path]] = []
    requested = {item.strip() for item in args.backends.split(",") if item.strip()}
    known = {spec.backend for spec in BACKENDS}
    if not requested or not requested <= known:
        raise RuntimeError(f"invalid_backends:{sorted(requested - known)}")
    wheel_source_root = Path(args.wheel_source_root).resolve() if args.wheel_source_root else None
    selected_specs = [item for item in BACKENDS if item.backend in requested]
    for spec in selected_specs:
        out_dir = payload_root / spec.output_dir
        base_dir = payload_root / spec.base_dir
        if wheel_source_root:
            copy_existing_wheels(wheel_source_root, spec.output_dir, out_dir)
        else:
            pip_download(spec.requirements, out_dir, spec.extra_index_url)
        remove_duplicates_against_base(out_dir, base_dir)
        for wheel in sorted(out_dir.glob("*.whl")):
            entries.append((spec.backend, spec.source_family, "runtime_wheel", wheel))

    model_dest = payload_root / "drumsep-models"
    for role, model in copy_models(model_src, model_dest):
        source_family = str(DRUMSEP_MODEL_POLICY[model.name]["source"])
        entries.append(("all", source_family, role, model))

    write_manifest(manifest_path, payload_root, entries)
    audit_payload(payload_root, manifest_path, selected_specs)
    if args.stage_root:
        if not wheel_source_root:
            raise RuntimeError("stage_requires_wheel_source_root")
        stage_windows_payload(
            Path(args.stage_root).resolve(),
            payload_root,
            manifest_path,
            selected_specs,
            wheel_source_root,
        )
    print(f"Prepared DrumSep payload under {payload_root}")
    print(f"Manifest: {manifest_path}")
    print("WINDOWS_DRUMSEP_PAYLOAD_REQUIRED_LAYOUT=PASS")
    print("WINDOWS_DRUMSEP_PAYLOAD_AUDIT=PASS")
    if args.stage_root:
        print(f"Windows bootstrap stage: {Path(args.stage_root).resolve()}")
        print("WINDOWS_DRUMSEP_STAGE_REQUIRED_LAYOUT=PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
