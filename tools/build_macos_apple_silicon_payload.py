#!/usr/bin/env python3
"""Prepare a closed, arm64-only Apple Silicon payload for STEMwerk 2.3.x."""

from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from email.parser import BytesParser
from pathlib import Path

try:
    from tools.macos_ffmpeg import (
        FFMPEG_LICENSE,
        FFMPEG_SOURCE_SHA256,
        FFMPEG_SOURCE_URL,
        FFMPEG_VERSION,
        build_official_arm64_ffmpeg,
        macho_architectures,
        validate_macho_release_contract,
        validate_macho_tree_release_contract,
        validate_macho_wheel_release_contract,
        validate_ffmpeg_pair,
    )
    from tools.macos_release_hygiene import (
        validate_macos_release_wheelhouse,
        validate_stemwerk_core_source_tree,
    )
    from tools.macos_managed_python import (
        prepare_managed_python_payload,
        validate_official_managed_python_provenance,
    )
except ModuleNotFoundError:  # Direct execution via ``python tools/...py``.
    from macos_ffmpeg import (  # type: ignore[no-redef]
        FFMPEG_LICENSE,
        FFMPEG_SOURCE_SHA256,
        FFMPEG_SOURCE_URL,
        FFMPEG_VERSION,
        build_official_arm64_ffmpeg,
        macho_architectures,
        validate_macho_release_contract,
        validate_macho_tree_release_contract,
        validate_macho_wheel_release_contract,
        validate_ffmpeg_pair,
    )
    from macos_release_hygiene import (  # type: ignore[no-redef]
        validate_macos_release_wheelhouse,
        validate_stemwerk_core_source_tree,
    )
    from macos_managed_python import (  # type: ignore[no-redef]
        prepare_managed_python_payload,
        validate_official_managed_python_provenance,
    )


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
DRUMSEP_COMPAT_FILENAME = "config_drumsep_mdx23c.yaml"
DRUMSEP_COMPAT_SIZE = 2328
DRUMSEP_COMPAT_SHA256 = "132231a5ab49141b8987b0daffcdd21d11e73df3669f1ac0755d697497b5f31b"

# Keep the official 2.3.0.4 runtime generation coherent.  In particular,
# audio-separator 0.23.0 requires samplerate 0.1.0 in its wheel metadata.
BOOTSTRAP_REQUIREMENTS = (
    "pip==26.1.2",
    "setuptools==83.0.0",
    "wheel==0.47.0",
)
RUNTIME_REQUIREMENTS = (
    "numpy==1.26.4",
    "torch==2.5.1",
    "torchvision==0.20.1",
    "torchaudio==2.5.1",
    "audio-separator==0.23.0",
    "samplerate==0.1.0",
    "llvmlite==0.42.0",
    "numba==0.59.1",
    "onnxruntime==1.27.0",
    "diffq==0.2.4",
)

SAMPLERATE_WHEEL_SHA256 = "f55e5c9d0a8ba3c82a53b7d9c34a2d145439c61166a7f310efaec88f2781b8f8"
LIBSAMPLERATE_VERSION = "0.2.2"
LIBSAMPLERATE_URL = "https://github.com/libsndfile/libsamplerate/archive/refs/tags/0.2.2.tar.gz"
LIBSAMPLERATE_SHA256 = "16e881487f184250deb4fcb60432d7556ab12cb58caea71ef23960aec6c0405a"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument(
        "--model-cache",
        default=str(Path.home() / "Library" / "Application Support" / "STEMwerk" / "models"),
    )
    parser.add_argument(
        "--ffmpeg",
        help="Development-only override; requires --allow-development-ffmpeg-override and --ffprobe.",
    )
    parser.add_argument("--ffprobe", help="Development-only override paired with --ffmpeg.")
    parser.add_argument(
        "--allow-development-ffmpeg-override",
        action="store_true",
        help="Explicitly permit a non-release FFmpeg override. Output is marked release-ineligible.",
    )
    parser.add_argument(
        "--release-mode",
        action="store_true",
        help="Require the official pinned source build and release-eligible provenance.",
    )
    parser.add_argument(
        "--source-artifact-dir",
        help="Preserve the exact verified FFmpeg source archive and checksum for release distribution.",
    )
    parser.add_argument(
        "--managed-python",
        help="Development-only override with an already extracted managed-Python directory.",
    )
    parser.add_argument(
        "--managed-python-artifact",
        help="Exact pinned python-build-standalone archive; required by release mode.",
    )
    parser.add_argument("--constraints", default="scripts/reaper/constraints/macos.txt")
    parser.add_argument(
        "--drumsep-compat-config",
        default="tools/assets/macos/drumsep/config_drumsep_mdx23c.yaml",
    )
    parser.add_argument(
        "--with-models",
        action="store_true",
        help="Include core models + DrumSep checkpoints (megapack). Default since 2.3.1.0 is "
        "runtime-only (models download via the online catalog on first Setup/Repair).",
    )
    return parser.parse_args()


def command_env() -> dict[str, str]:
    env = os.environ.copy()
    env.setdefault("PIP_DISABLE_PIP_VERSION_CHECK", "1")
    env.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    return env


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def ensure_file(path: Path, label: str) -> None:
    if not path.is_file():
        raise FileNotFoundError(f"Missing required {label}: {path}")


def verify_file(path: Path, label: str, *, size: int | None = None, sha256: str | None = None) -> None:
    ensure_file(path, label)
    if size is not None and path.stat().st_size != size:
        raise RuntimeError(f"Invalid {label} size: {path.stat().st_size}, expected {size}")
    if sha256 is not None and sha256_file(path) != sha256:
        raise RuntimeError(f"Invalid {label} SHA256: {path}")


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


def copy_drumsep_assets(model_cache: Path, compat_config: Path, dest_root: Path) -> dict[str, object]:
    verify_file(
        compat_config,
        "DrumSep compatibility config",
        size=DRUMSEP_COMPAT_SIZE,
        sha256=DRUMSEP_COMPAT_SHA256,
    )
    copy_files(model_cache, dest_root, DRUMSEP_FILES, "DrumSep payload file")
    shutil.copy2(compat_config, dest_root / DRUMSEP_COMPAT_FILENAME)
    copied = dest_root / DRUMSEP_COMPAT_FILENAME
    verify_file(
        copied,
        "copied DrumSep compatibility config",
        size=DRUMSEP_COMPAT_SIZE,
        sha256=DRUMSEP_COMPAT_SHA256,
    )
    return {
        "path": f"drumsep/{DRUMSEP_COMPAT_FILENAME}",
        "size": copied.stat().st_size,
        "sha256": sha256_file(copied),
    }


def copy_tree(src_root: Path, dest_root: Path, label: str) -> None:
    if not src_root.is_dir():
        raise FileNotFoundError(f"Missing required {label}: {src_root}")
    shutil.copytree(src_root, dest_root)


def python_version(python_executable: str) -> tuple[int, int]:
    result = subprocess.run(
        [python_executable, "-c", "import sys; print(f'{sys.version_info[0]}.{sys.version_info[1]}')"],
        check=True,
        capture_output=True,
        text=True,
        env=command_env(),
    )
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
        if candidate.is_file() and python_version(str(candidate)) == (3, 12):
            return str(candidate)
    raise RuntimeError("Missing native Python 3.12 interpreter for Apple Silicon payload assembly")


def normalize_distribution(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def validate_declared_policy(requirements: tuple[str, ...]) -> None:
    versions = {}
    for requirement in requirements:
        if "==" not in requirement:
            raise RuntimeError(f"Unpinned payload requirement: {requirement}")
        name, version = requirement.split("==", 1)
        versions[normalize_distribution(name)] = version
    if versions.get("audio-separator") == "0.23.0" and versions.get("samplerate") != "0.1.0":
        raise RuntimeError("Conflicting policy: audio-separator 0.23.0 requires samplerate 0.1.0")
    if versions.get("numba") == "0.59.1" and versions.get("llvmlite") != "0.42.0":
        raise RuntimeError("Conflicting policy: numba 0.59.1 requires llvmlite 0.42.x")


def build_diffq_wheel(wheels_dir: Path, python_executable: str) -> None:
    subprocess.run(
        [
            python_executable,
            "-m",
            "pip",
            "wheel",
            "--no-deps",
            "--wheel-dir",
            str(wheels_dir),
            "diffq==0.2.4",
        ],
        check=True,
        env=command_env(),
    )


def download_closed_wheelhouse(
    wheels_dir: Path, constraints_file: Path, python_executable: str
) -> None:
    wheels_dir.mkdir(parents=True, exist_ok=True)
    build_diffq_wheel(wheels_dir, python_executable)
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
    if constraints_file.is_file():
        cmd += ["-c", str(constraints_file)]
    cmd += [*BOOTSTRAP_REQUIREMENTS, *RUNTIME_REQUIREMENTS]
    subprocess.run(cmd, check=True, env=command_env())


def build_stemwerk_core_wheel(repo_root: Path, wheels_dir: Path, python_executable: str) -> None:
    subprocess.run(
        [
            python_executable,
            "-m",
            "pip",
            "wheel",
            "--no-deps",
            "--no-build-isolation",
            "--wheel-dir",
            str(wheels_dir),
            str(repo_root / "scripts" / "reaper" / "vendor" / "stemwerk-core"),
        ],
        check=True,
        env=command_env(),
    )


def _download_verified(url: str, destination: Path, expected_sha256: str) -> None:
    urllib.request.urlretrieve(url, destination)
    if sha256_file(destination) != expected_sha256:
        raise RuntimeError(f"Downloaded source SHA256 mismatch: {destination.name}")


def _build_native_libsamplerate(work_dir: Path) -> Path:
    archive = work_dir / f"libsamplerate-{LIBSAMPLERATE_VERSION}.tar.gz"
    _download_verified(LIBSAMPLERATE_URL, archive, LIBSAMPLERATE_SHA256)
    with tarfile.open(archive, "r:gz") as source_tar:
        source_tar.extractall(work_dir, filter="data")
    source = work_dir / f"libsamplerate-{LIBSAMPLERATE_VERSION}"
    build_dir = work_dir / "libsamplerate-build"
    build_dir.mkdir()
    (build_dir / "config.h").touch()
    output = build_dir / "libsamplerate.dylib"
    cmd = [
        "xcrun",
        "clang",
        "-dynamiclib",
        "-arch",
        "arm64",
        "-O2",
        "-fPIC",
        f"-I{build_dir}",
        f"-I{source / 'include'}",
        f"-I{source / 'src'}",
        '-DPACKAGE="libsamplerate"',
        f'-DVERSION="{LIBSAMPLERATE_VERSION}"',
        "-DCPU_IS_BIG_ENDIAN=0",
        "-DCPU_IS_LITTLE_ENDIAN=1",
        "-DHAVE_LRINT=1",
        "-DHAVE_LRINTF=1",
        "-DHAVE_STDBOOL_H=1",
        "-DHAVE_STDINT_H=1",
        "-DHAVE_UNISTD_H=1",
        "-DENABLE_SINC_FAST_CONVERTER=1",
        "-DENABLE_SINC_MEDIUM_CONVERTER=1",
        "-DENABLE_SINC_BEST_CONVERTER=1",
        "-DSIZEOF_INT=4",
        "-DSIZEOF_LONG=8",
        "-install_name",
        "@loader_path/libsamplerate.dylib",
        "-current_version",
        "3.2.0",
        "-compatibility_version",
        "3.0.0",
        "-o",
        str(output),
        str(source / "src" / "samplerate.c"),
        str(source / "src" / "src_linear.c"),
        str(source / "src" / "src_sinc.c"),
        str(source / "src" / "src_zoh.c"),
    ]
    subprocess.run(cmd, check=True, env=command_env())
    assert_arm64_macho(output)
    return output


def _wheel_dist_info(root: Path) -> Path:
    matches = list(root.glob("*.dist-info"))
    if len(matches) != 1:
        raise RuntimeError(f"Wheel must contain one .dist-info directory: {root}")
    return matches[0]


def _record_digest(path: Path) -> str:
    digest = base64.urlsafe_b64encode(hashlib.sha256(path.read_bytes()).digest()).rstrip(b"=").decode("ascii")
    return f"sha256={digest}"


def _repack_wheel(root: Path, output: Path) -> None:
    dist_info = _wheel_dist_info(root)
    record = dist_info / "RECORD"
    rows = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path == record:
            continue
        rows.append((path.relative_to(root).as_posix(), _record_digest(path), str(path.stat().st_size)))
    rows.append((record.relative_to(root).as_posix(), "", ""))
    with record.open("w", encoding="utf-8", newline="") as handle:
        csv.writer(handle, lineterminator="\n").writerows(rows)
    if output.exists():
        output.unlink()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(root.rglob("*")):
            if path.is_file():
                info = zipfile.ZipInfo(path.relative_to(root).as_posix(), date_time=(2023, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (path.stat().st_mode & 0xFFFF) << 16
                archive.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def assert_arm64_macho(path: Path) -> None:
    architectures = macho_architectures(path)
    if architectures and architectures != ("arm64",):
        raise RuntimeError(
            "reason=macos_macho_architecture_mismatch "
            f"Non-arm64-only Mach-O object: {path} ({' '.join(architectures)})"
        )
    # Uses validate_macho_release_contract's default ceiling
    # (BUNDLED_APPLE_SILICON_MACOS_AUDIT_MAXIMUM, "14.0") -- this builder
    # assembles the bundled Apple Silicon payload, so every Mach-O it
    # produces (including FFmpeg's own binaries) is checked against the
    # PACKAGE's contract here, not FFmpeg's own (lower) build target.
    validate_macho_release_contract(path)


def _retag_wheel_file(original: Path, root: Path, *, force_samplerate: bool = False) -> Path:
    wheel_metadata = _wheel_dist_info(root) / "WHEEL"
    text = wheel_metadata.read_text(encoding="utf-8")
    if force_samplerate:
        text = re.sub(r"^Root-Is-Purelib:.*$", "Root-Is-Purelib: false", text, flags=re.MULTILINE)
        text = re.sub(r"^Tag:.*$", "Tag: py3-none-macosx_11_0_arm64", text, flags=re.MULTILINE)
        target_name = "samplerate-0.1.0-py3-none-macosx_11_0_arm64.whl"
    else:
        text = text.replace("universal2", "arm64")
        target_name = original.name.replace("universal2", "arm64")
        # macOS arm64 starts at deployment target 11.0.  Universal2 wheels may
        # advertise an older x86-compatible target that is invalid once the
        # x86_64 slice has been removed.
        text = re.sub(r"macosx_10_[0-9]+_arm64", "macosx_11_0_arm64", text)
        target_name = re.sub(r"macosx_10_[0-9]+_arm64", "macosx_11_0_arm64", target_name)
    wheel_metadata.write_text(text, encoding="utf-8")
    target = original.with_name(target_name)
    _repack_wheel(root, target)
    if original != target and original.exists():
        original.unlink()
    return target


def replace_samplerate_with_native_arm64(wheels_dir: Path) -> Path:
    matches = list(wheels_dir.glob("samplerate-0.1.0-*.whl"))
    if len(matches) != 1:
        raise RuntimeError("Expected exactly one samplerate 0.1.0 wheel before native rebuild")
    original = matches[0]
    if sha256_file(original) != SAMPLERATE_WHEEL_SHA256:
        raise RuntimeError("Unexpected samplerate 0.1.0 upstream wheel SHA256")
    with tempfile.TemporaryDirectory(prefix="stemwerk-samplerate-arm64-") as temp_name:
        temp = Path(temp_name)
        unpacked = temp / "wheel"
        with zipfile.ZipFile(original) as archive:
            archive.extractall(unpacked)
        native_library = _build_native_libsamplerate(temp)
        destination = unpacked / "samplerate" / "_samplerate_data" / "libsamplerate.dylib"
        shutil.copy2(native_library, destination)
        target = _retag_wheel_file(original, unpacked, force_samplerate=True)
    return target


def thin_universal_wheels(wheels_dir: Path) -> None:
    for wheel in sorted(wheels_dir.glob("*.whl")):
        with tempfile.TemporaryDirectory(prefix="stemwerk-wheel-arm64-") as temp_name:
            root = Path(temp_name) / "wheel"
            with zipfile.ZipFile(wheel) as archive:
                archive.extractall(root)
            changed = False
            for candidate in root.rglob("*"):
                if not candidate.is_file():
                    continue
                architectures = macho_architectures(candidate)
                if not architectures:
                    continue
                if "arm64" not in architectures:
                    raise RuntimeError(f"Wheel contains x86_64-only Mach-O object: {wheel.name}:{candidate.relative_to(root)}")
                if architectures != ("arm64",):
                    thinned = candidate.with_name(candidate.name + ".arm64")
                    subprocess.run(["lipo", str(candidate), "-thin", "arm64", "-output", str(thinned)], check=True)
                    thinned.replace(candidate)
                    changed = True
                try:
                    assert_arm64_macho(candidate)
                except RuntimeError as exc:
                    raise RuntimeError(
                        f"{exc} wheel={wheel.name} entry={candidate.relative_to(root).as_posix()}"
                    ) from exc
            if changed:
                _retag_wheel_file(wheel, root)


def wheel_metadata(wheel: Path) -> tuple[str, str]:
    with zipfile.ZipFile(wheel) as archive:
        metadata_names = [
            name
            for name in archive.namelist()
            if name.endswith(".dist-info/METADATA") and name.count("/") == 1
        ]
        if len(metadata_names) != 1:
            raise RuntimeError(f"Invalid wheel metadata: {wheel.name}")
        metadata = BytesParser().parsebytes(archive.read(metadata_names[0]))
    return str(metadata["Name"]), str(metadata["Version"])


def resolved_wheel_inventory(wheels_dir: Path) -> list[dict[str, object]]:
    distributions: dict[str, Path] = {}
    inventory = []
    for wheel in sorted(wheels_dir.glob("*.whl")):
        name, version = wheel_metadata(wheel)
        normalized = normalize_distribution(name)
        if normalized in distributions:
            raise RuntimeError(
                f"Duplicate wheel distribution {normalized}: {distributions[normalized].name}, {wheel.name}"
            )
        distributions[normalized] = wheel
        inventory.append(
            {
                "name": name,
                "normalized_name": normalized,
                "version": version,
                "filename": wheel.name,
                "size": wheel.stat().st_size,
                "sha256": sha256_file(wheel),
            }
        )
    expected = {normalize_distribution(item.split("==", 1)[0]) for item in RUNTIME_REQUIREMENTS}
    missing = sorted(expected - distributions.keys())
    if missing:
        raise RuntimeError(f"Incomplete wheelhouse: missing {', '.join(missing)}")
    return inventory


def verify_offline_resolution(wheels_dir: Path, python_executable: str) -> None:
    subprocess.run(
        [
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
            *RUNTIME_REQUIREMENTS,
        ],
        check=True,
        env=command_env(),
    )


def verify_payload_architectures(output_dir: Path) -> None:
    # Both helpers default to BUNDLED_APPLE_SILICON_MACOS_AUDIT_MAXIMUM
    # ("14.0"). FFmpeg's own binaries (built at FFMPEG_DEPLOYMENT_TARGET,
    # "12.0") pass this trivially: 12.0 does not exceed the 14.0 ceiling.
    for root in (output_dir / "ffmpeg", output_dir / "python"):
        validate_macho_tree_release_contract(root)
    for wheel in (output_dir / "wheels").rglob("*.whl"):
        validate_macho_wheel_release_contract(wheel)


def prepare_portable_ffmpeg(
    destination: Path,
    ffmpeg_override: str | None,
    ffprobe_override: str | None,
    *,
    release_mode: bool = False,
    allow_development_override: bool = False,
    source_artifact_dir: Path | None = None,
) -> dict[str, object]:
    if bool(ffmpeg_override) != bool(ffprobe_override):
        raise RuntimeError("--ffmpeg and --ffprobe must be supplied together")
    destination.mkdir(parents=True, exist_ok=True)
    if not ffmpeg_override:
        return build_official_arm64_ffmpeg(destination, source_artifact_dir=source_artifact_dir)
    if release_mode:
        raise RuntimeError("Release mode refuses all FFmpeg/ffprobe overrides")
    if not allow_development_override:
        raise RuntimeError(
            "Development FFmpeg overrides require --allow-development-ffmpeg-override"
        )
    ffmpeg = Path(ffmpeg_override).expanduser().resolve()
    ffprobe = Path(ffprobe_override or "").expanduser().resolve()
    ensure_file(ffmpeg, "ffmpeg override")
    ensure_file(ffprobe, "ffprobe override")
    shutil.copy2(ffmpeg, destination / "ffmpeg")
    shutil.copy2(ffprobe, destination / "ffprobe")
    audit = validate_ffmpeg_pair(destination / "ffmpeg", destination / "ffprobe")
    provenance = {
        "component": "FFmpeg",
        "build_mode": "development-override",
        "official_source_build": False,
        "release_eligible": False,
        "version": audit["versions"]["ffmpeg"],
        "license": "development-override-license-unverified",
        "source_url": "development-override",
        "source_sha256": "development-override",
        "reproducibility": "not applicable: externally supplied development binaries",
        "binaries": {
            name: {
                "sha256": sha256_file(destination / name),
                "size": (destination / name).stat().st_size,
            }
            for name in ("ffmpeg", "ffprobe")
        },
        "validation": audit,
    }
    (destination / "SOURCE_PROVENANCE.json").write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return provenance


def write_manifest(
    output_dir: Path,
    version: str,
    wheel_inventory: list[dict[str, object]],
    compatibility_config: dict[str, object] | None,
    with_models: bool,
    ffmpeg_provenance: dict[str, object],
    managed_python_provenance: dict[str, object],
) -> None:
    manifest = {
        "platform": "macos-apple-silicon-arm64",
        "version": version,
        "runtime_policy": "stemwerk-2.3.0.4-coherent-mps",
        "declared_requirements": list(RUNTIME_REQUIREMENTS),
        "resolved_packages": wheel_inventory,
        "drumsep_compatibility_config": compatibility_config,
        "source_provenance": {
            "samplerate_python_wheel_sha256": SAMPLERATE_WHEEL_SHA256,
            "libsamplerate_version": LIBSAMPLERATE_VERSION,
            "libsamplerate_source_url": LIBSAMPLERATE_URL,
            "libsamplerate_source_sha256": LIBSAMPLERATE_SHA256,
            "ffmpeg_version": FFMPEG_VERSION,
            "ffmpeg_license": FFMPEG_LICENSE,
            "ffmpeg_source_url": FFMPEG_SOURCE_URL,
            "ffmpeg_source_sha256": FFMPEG_SOURCE_SHA256,
        },
        "ffmpeg": ffmpeg_provenance,
        "managed_python": managed_python_provenance,
        "contains": {
            "ffmpeg": True,
            "python": True,
            "wheels": True,
            "core_models": bool(with_models),
            "drumsep": bool(with_models),
        },
    }
    (output_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def main() -> int:
    args = parse_args()
    repo_root = Path.cwd().resolve()
    output_dir = (repo_root / args.output).resolve()
    model_cache = Path(args.model_cache).expanduser().resolve()
    managed_python_artifact = (
        Path(args.managed_python_artifact).expanduser().resolve()
        if args.managed_python_artifact else None
    )
    managed_python_dir = (
        Path(args.managed_python).expanduser().resolve()
        if args.managed_python
        else Path.home() / "Library" / "Application Support" / "STEMwerk" / "python"
    )
    constraints_file = (repo_root / args.constraints).resolve()
    compat_config = (repo_root / args.drumsep_compat_config).resolve()
    source_artifact_dir = (
        (repo_root / args.source_artifact_dir).resolve() if args.source_artifact_dir else None
    )
    if args.release_mode and source_artifact_dir is None:
        raise RuntimeError("Release mode requires --source-artifact-dir for corresponding source")
    if args.release_mode and managed_python_artifact is None:
        raise RuntimeError("Release mode requires --managed-python-artifact")
    if args.release_mode and args.managed_python:
        raise RuntimeError("Release mode refuses --managed-python development directory overrides")
    python_executable = payload_python()

    validate_declared_policy(RUNTIME_REQUIREMENTS)
    validate_stemwerk_core_source_tree(
        repo_root / "scripts/reaper/vendor/stemwerk-core", release_mode=args.release_mode
    )
    reset_dir(output_dir)
    ffmpeg_provenance = prepare_portable_ffmpeg(
        output_dir / "ffmpeg",
        args.ffmpeg,
        args.ffprobe,
        release_mode=args.release_mode,
        allow_development_override=args.allow_development_ffmpeg_override,
        source_artifact_dir=source_artifact_dir,
    )
    if args.release_mode and ffmpeg_provenance.get("release_eligible") is not True:
        raise RuntimeError("Release mode produced release-ineligible FFmpeg provenance")

    wheels_dir = output_dir / "wheels"
    download_closed_wheelhouse(wheels_dir, constraints_file, python_executable)
    build_stemwerk_core_wheel(repo_root, wheels_dir, python_executable)
    replace_samplerate_with_native_arm64(wheels_dir)
    thin_universal_wheels(wheels_dir)
    validate_macos_release_wheelhouse(wheels_dir)
    inventory = resolved_wheel_inventory(wheels_dir)
    verify_offline_resolution(wheels_dir, python_executable)

    managed_python_provenance = prepare_managed_python_payload(
        output_dir / "python",
        artifact=managed_python_artifact,
        development_source=managed_python_dir if managed_python_artifact is None else None,
        release_mode=args.release_mode,
    )
    if args.release_mode and managed_python_provenance.get("release_eligible") is not True:
        raise RuntimeError("Release mode produced release-ineligible managed-Python provenance")
    compatibility: dict[str, object] | None = None
    if args.with_models:
        copy_files(model_cache, output_dir / "models", CORE_MODEL_FILES, "core model payload file")
        compatibility = copy_drumsep_assets(model_cache, compat_config, output_dir / "drumsep")
    else:
        print("runtime-only payload: models/ and drumsep/ are not bundled (online catalog supplies them)")
    verify_payload_architectures(output_dir)
    write_manifest(
        output_dir, args.version, inventory, compatibility, args.with_models,
        ffmpeg_provenance, managed_python_provenance,
    )
    if args.release_mode:
        manifest = json.loads((output_dir / "manifest.json").read_text(encoding="utf-8"))
        validate_official_managed_python_provenance(output_dir / "python", manifest)
    print(f"Prepared closed arm64 Apple Silicon payload at {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
