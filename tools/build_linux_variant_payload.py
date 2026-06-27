#!/usr/bin/env python3
"""Prepare Linux bundled payload directories for STEMwerk installer variants."""

from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import sys
from pathlib import Path


FAST_MODEL_FILES = (
    "htdemucs.yaml",
    "955717e8-8726e21a.th",
    "download_checks.json",
)

QUALITY_MODEL_FILES = (
    "htdemucs_ft.yaml",
    "f7e0c4bc-ba3fe64a.th",
    "d12395a8-e57c48e6.th",
    "92cfc3b6-ef3bcb9c.th",
    "04573f0d-f3cf25b2.th",
)

SIXSTEM_MODEL_FILES = (
    "htdemucs_6s.yaml",
    "5c90dfd2-34c22ccb.th",
)

DRUMSEP_MODEL_FILES = (
    "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt",
    "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml",
)

VARIANT_SPECS = {
    "bundled": {
        "backend": "cpu",
        "runtime": "main",
        "models": FAST_MODEL_FILES,
        "allowlist": ("htdemucs",),
        "include_drumsep": False,
    },
    "offline-bundled-cpu-allmodels": {
        "backend": "cpu",
        "runtime": "main",
        "models": FAST_MODEL_FILES + QUALITY_MODEL_FILES + SIXSTEM_MODEL_FILES,
        "allowlist": ("htdemucs", "htdemucs_ft", "htdemucs_6s"),
        "include_drumsep": True,
    },
    "offline-bundled-cuda-allmodels": {
        "backend": "cuda",
        "runtime": "main",
        "models": FAST_MODEL_FILES + QUALITY_MODEL_FILES + SIXSTEM_MODEL_FILES,
        "allowlist": ("htdemucs", "htdemucs_ft", "htdemucs_6s"),
        "include_drumsep": True,
    },
    "offline-bundled-rocm-allmodels": {
        "backend": "rocm",
        "runtime": "main",
        "models": FAST_MODEL_FILES + QUALITY_MODEL_FILES + SIXSTEM_MODEL_FILES,
        "allowlist": ("htdemucs", "htdemucs_ft", "htdemucs_6s"),
        "include_drumsep": True,
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", required=True, choices=tuple(VARIANT_SPECS))
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--model-cache", default=str(Path.home() / ".local" / "share" / "STEMwerk" / "models"))
    parser.add_argument("--repo-root", default=".")
    return parser.parse_args()


def sha256sum(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def copy_required_files(src_root: Path, dest_root: Path, files: tuple[str, ...]) -> None:
    dest_root.mkdir(parents=True, exist_ok=True)
    for name in files:
        src = src_root / name
        if not src.is_file():
            raise FileNotFoundError(f"Missing required payload file: {src}")
        shutil.copy2(src, dest_root / name)


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def dedupe_shared_wheels(*wheel_dirs: Path, shared_dir: Path) -> list[str]:
    shared_dir.mkdir(parents=True, exist_ok=True)
    wheel_map: dict[str, list[Path]] = {}
    for wheel_dir in wheel_dirs:
        if not wheel_dir.is_dir():
            continue
        for wheel_path in sorted(wheel_dir.glob("*.whl")):
            wheel_map.setdefault(wheel_path.name, []).append(wheel_path)

    deduped: list[str] = []
    for wheel_name, paths in sorted(wheel_map.items()):
        if len(paths) < 2:
            continue
        baseline = paths[0]
        baseline_size = baseline.stat().st_size
        baseline_digest = file_digest(baseline)
        for other in paths[1:]:
            if other.stat().st_size != baseline_size:
                break
            if file_digest(other) != baseline_digest:
                break
        else:
            shared_path = shared_dir / wheel_name
            shutil.move(str(baseline), shared_path)
            for duplicate in paths[1:]:
                duplicate.unlink()
            deduped.append(wheel_name)

    if not any(shared_dir.iterdir()):
        shared_dir.rmdir()
    return deduped


def write_allowlist(path: Path, entries: tuple[str, ...]) -> None:
    path.write_text("\n".join(entries) + "\n", encoding="utf-8")


def write_manifest(path: Path, root: Path) -> None:
    lines = ["# relpath\tsize_bytes\tsha256"]
    for file_path in sorted(p for p in root.rglob("*") if p.is_file()):
        lines.append(
            "\t".join(
                [
                    str(file_path.relative_to(root)),
                    str(file_path.stat().st_size),
                    sha256sum(file_path),
                ]
            )
        )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def build_wheelhouse(repo_root: Path, runtime: str, backend: str, output_dir: Path) -> None:
    cmd = [
        sys.executable,
        str(repo_root / "tools" / "build_linux_wheelhouse.py"),
        "--runtime",
        runtime,
        "--backend",
        backend,
        "--output-dir",
        str(output_dir),
        "--extra-wheel-dir",
        str(repo_root / "installer" / "linux" / "payload" / "wheels" / "linux-x86_64-cp312"),
    ]
    subprocess.run(cmd, check=True)


def dedupe_variant_wheels(output_dir: Path) -> list[str]:
    return dedupe_shared_wheels(
        output_dir / "wheels" / "main",
        output_dir / "drumsep-wheels",
        shared_dir=output_dir / "wheels" / "shared",
    )


def main() -> int:
    args = parse_args()
    repo_root = Path(args.repo_root).resolve()
    output_dir = Path(args.output_dir).resolve()
    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    spec = VARIANT_SPECS[args.variant]
    model_cache = Path(args.model_cache).expanduser().resolve()

    write_allowlist(output_dir / "model_allowlist.txt", spec["allowlist"])
    copy_required_files(model_cache, output_dir / "models", spec["models"])
    build_wheelhouse(repo_root, spec["runtime"], spec["backend"], output_dir / "wheels" / "main")

    if spec["include_drumsep"]:
        copy_required_files(model_cache, output_dir / "drumsep-models", DRUMSEP_MODEL_FILES)
        build_wheelhouse(repo_root, "drumsep", spec["backend"], output_dir / "drumsep-wheels")
        deduped = dedupe_variant_wheels(output_dir)
        if deduped:
            print(f"Deduped shared wheels ({len(deduped)}): {', '.join(deduped)}")

    write_manifest(output_dir / "payload-manifest.txt", output_dir)
    print(f"Prepared Linux payload variant {args.variant} at {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
