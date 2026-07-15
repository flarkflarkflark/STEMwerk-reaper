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

try:
    from packaging.utils import canonicalize_name, parse_wheel_filename
except ImportError:  # payload Python always has pip, whose vendored packaging is sufficient here
    from pip._vendor.packaging.utils import canonicalize_name, parse_wheel_filename


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
    "samplerate==0.2.4",
    "onnxruntime==1.27.0",
)

CORE_VERSION_POLICY = {
    canonicalize_name(requirement.split("==", 1)[0]): requirement.split("==", 1)[1]
    for requirement in MAIN_REQUIREMENTS
}
CLOSURE_VERSION_POLICY = {canonicalize_name("sympy"): "1.13.1"}

DEPENDENCY_OVERRIDE_POLICY = ({
    "package": "samplerate",
    "upstream_required": "0.1.0",
    "project_override": "0.2.4",
    "scope": "macos-arm64",
},)
FORBIDDEN_REQUIREMENTS = ("samplerate==0.1.0", "sympy==1.14.0")
NON_CLOSURE_PACKAGES = {
    canonicalize_name(name) for name in ("pip", "setuptools", "wheel", "stemwerk-core")
}

DIFFQ_REQUIREMENT = "diffq==0.2.4"
SAMPLERATE_REQUIREMENT = "samplerate==0.2.4"

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
    "samplerate-0.2.4-cp312-cp312-macosx_*_universal2.whl",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version")
    parser.add_argument("--output")
    parser.add_argument(
        "--clean-output",
        action="store_true",
        help="Remove an existing non-empty payload output root before building",
    )
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


def prepare_output_dir(path: Path, clean_output: bool) -> None:
    if path.exists() and any(path.iterdir()):
        if not clean_output:
            raise RuntimeError(f"existing_payload_requires_clean_output:{path}")
        reset_dir(path)
        return
    path.mkdir(parents=True, exist_ok=True)


def wheel_identity(path: Path) -> tuple[str, str]:
    try:
        name, version, _build, _tags = parse_wheel_filename(path.name)
    except Exception as exc:
        raise RuntimeError(f"payload_invalid_wheel_filename:{path.name}:{exc}") from exc
    return canonicalize_name(name), str(version)


def dependency_closure_requirements(wheels_dir: Path) -> list[str]:
    requirements = set()
    for path in wheels_dir.glob("*.whl"):
        name, version = wheel_identity(path)
        if name not in CORE_VERSION_POLICY and name not in NON_CLOSURE_PACKAGES:
            requirements.add(f"{name}=={version}")
    return sorted(requirements)


def write_core_constrained_resolver_file(path: Path) -> None:
    requirements = [requirement for requirement in MAIN_REQUIREMENTS if not requirement.startswith("samplerate==")]
    requirements += [f"{name}=={version}" for name, version in CLOSURE_VERSION_POLICY.items()]
    path.write_text("\n".join(requirements) + "\n", encoding="utf-8")


def validate_closed_world_wheelhouse(wheels_dir: Path) -> list[Path]:
    if not wheels_dir.is_dir():
        raise RuntimeError(f"payload_wheelroot_missing:{wheels_dir}")
    entries = sorted(wheels_dir.iterdir(), key=lambda path: path.name.lower())
    unexpected = [path.name for path in entries if not path.is_file() or path.suffix.lower() != ".whl"]
    if unexpected:
        raise RuntimeError("payload_unexpected_artifacts:" + ",".join(unexpected))
    wheels = [path for path in entries if path.is_file() and path.suffix.lower() == ".whl"]
    lower_names: dict[str, list[str]] = {}
    core_wheels: dict[str, list[tuple[str, str]]] = {name: [] for name in CORE_VERSION_POLICY}
    closure_wheels: dict[str, list[tuple[str, str]]] = {name: [] for name in CLOSURE_VERSION_POLICY}
    for path in wheels:
        lower_names.setdefault(path.name.lower(), []).append(path.name)
        name, version = wheel_identity(path)
        if name in core_wheels:
            core_wheels[name].append((path.name, version))
        if name in closure_wheels:
            closure_wheels[name].append((path.name, version))
    collisions = ["|".join(names) for names in lower_names.values() if len(names) != 1]
    if collisions:
        raise RuntimeError("payload_wheel_case_collision:" + ",".join(collisions))
    failures = []
    for name, wanted in CORE_VERSION_POLICY.items():
        found = core_wheels[name]
        if len(found) != 1 or found[0][1] != wanted:
            detail = "|".join(f"{filename}@{version}" for filename, version in found) or "missing"
            failures.append(f"{name}:expected={wanted}:found={detail}")
    if failures:
        if any(item.startswith("samplerate:") and "@0.1.0" in item for item in failures):
            raise RuntimeError("payload_forbidden_samplerate_0_1_0:" + ";".join(failures))
        raise RuntimeError("payload_core_version_exclusivity:" + ";".join(failures))
    closure_failures = []
    for name, wanted in CLOSURE_VERSION_POLICY.items():
        found = closure_wheels[name]
        if len(found) != 1 or found[0][1] != wanted:
            detail = "|".join(f"{filename}@{version}" for filename, version in found) or "missing"
            closure_failures.append(f"{name}:expected={wanted}:found={detail}")
    if closure_failures:
        raise RuntimeError("dependency_closure_core_conflict:" + ";".join(closure_failures))
    return wheels


def project_resolved_wheels(resolved_dir: Path, wheels_dir: Path) -> None:
    wheels_dir.mkdir(parents=True, exist_ok=True)
    for path in sorted(resolved_dir.glob("*.whl")):
        name, version = wheel_identity(path)
        wanted = CORE_VERSION_POLICY.get(name)
        if wanted is not None and version != wanted:
            continue
        target = wheels_dir / path.name
        if target.exists() and sha256_file(target) != sha256_file(path):
            raise RuntimeError(f"payload_duplicate_filename_content_mismatch:{path.name}")
        if not target.exists():
            shutil.copy2(path, target)


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


def run_pip_download(
    requirements: tuple[str, ...],
    wheels_dir: Path,
    constraints_file: Path,
    python_executable: str,
    *,
    no_deps: bool = False,
) -> None:
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
        if no_deps:
            cmd.append("--no-deps")
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
    if any(wheels_dir.glob("samplerate-0.2.4-cp312-cp312-macosx_*_universal2.whl")):
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
    validate_closed_world_wheelhouse(wheels_dir)
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
    common = [
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
    ]
    subprocess.run(
        [*common, "--no-deps", *MAIN_REQUIREMENTS, *dependency_closure_requirements(wheels_dir)],
        check=True,
        env=command_env(),
    )


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
    # Deferred D6: wheels are fully fingerprinted here; ffmpeg, models, and the
    # managed Python tree still need a separate non-wheel integrity design.
    validate_closed_world_wheelhouse(output_dir / "wheels")
    wheel_inventory = [
        {"filename": path.name, "sha256": sha256_file(path), "size": path.stat().st_size}
        for path in sorted((output_dir / "wheels").glob("*.whl"))
    ]
    manifest = {
        "platform": "macos-apple-silicon",
        "version": version,
        "runtime_policy": "mps_preferred_cpu_fallback",
        "python_tag": "cp312",
        "architecture": "arm64",
        "runtime_requirements": list(MAIN_REQUIREMENTS),
        "target_core_requirements": list(MAIN_REQUIREMENTS),
        "dependency_closure_requirements": dependency_closure_requirements(output_dir / "wheels"),
        "dependency_overrides": list(DEPENDENCY_OVERRIDE_POLICY),
        "forbidden_requirements": list(FORBIDDEN_REQUIREMENTS),
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
    if manifest.get("target_core_requirements") != list(MAIN_REQUIREMENTS):
        raise RuntimeError("payload_override_contract_invalid:target_core_requirements")
    if manifest.get("dependency_overrides") != list(DEPENDENCY_OVERRIDE_POLICY):
        raise RuntimeError("payload_override_contract_invalid:dependency_overrides")
    if manifest.get("forbidden_requirements") != list(FORBIDDEN_REQUIREMENTS):
        raise RuntimeError("payload_override_contract_invalid:forbidden_requirements")
    inventory = manifest.get("wheel_inventory", [])
    filenames = [entry.get("filename", "") for entry in inventory]
    if len(filenames) != len(set(filenames)) or len(filenames) != len({name.lower() for name in filenames}):
        raise RuntimeError("payload_manifest_duplicate:" + ",".join(filenames))
    expected_inventory = {entry["filename"]: entry for entry in inventory}
    actual_paths = validate_closed_world_wheelhouse(output_dir / "wheels")
    physical = {path.name for path in actual_paths}
    manifest_wheels = set(expected_inventory)
    extra = sorted(physical - manifest_wheels)
    missing = sorted(manifest_wheels - physical)
    if extra:
        raise RuntimeError("payload_extra_wheels:" + ",".join(extra))
    if missing:
        raise RuntimeError("payload_missing_wheels:" + ",".join(missing))
    if manifest.get("dependency_closure_requirements") != dependency_closure_requirements(output_dir / "wheels"):
        raise RuntimeError("payload_dependency_closure_mismatch")
    mismatched = [path.name for path in actual_paths if expected_inventory[path.name].get("sha256") != sha256_file(path)]
    if mismatched:
        raise RuntimeError(f"payload_checksum_mismatch:{','.join(mismatched)}")
    wrong_size = [path.name for path in actual_paths if expected_inventory[path.name].get("size") != path.stat().st_size]
    if wrong_size:
        raise RuntimeError(f"payload_size_mismatch:{','.join(wrong_size)}")


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

    prepare_output_dir(output_dir, args.clean_output)
    copy_ffmpeg(ffmpeg_path, ffprobe_path, output_dir / "ffmpeg")
    resolver_dir = output_dir / ".resolver-closure"
    reset_dir(resolver_dir)
    resolver_constraints = resolver_dir / "core-closure-constraints.txt"
    write_core_constrained_resolver_file(resolver_constraints)
    try:
        run_pip_download(("audio-separator==0.44.3",), resolver_dir, resolver_constraints, python_executable)
    except subprocess.CalledProcessError:
        ensure_diffq_wheel(resolver_dir)
        run_pip_download(("audio-separator==0.44.3",), resolver_dir, resolver_constraints, python_executable)
    project_resolved_wheels(resolver_dir, output_dir / "wheels")
    run_pip_download(
        BOOTSTRAP_REQUIREMENTS + MAIN_REQUIREMENTS,
        output_dir / "wheels",
        constraints_file,
        python_executable,
        no_deps=True,
    )
    shutil.rmtree(resolver_dir)
    ensure_samplerate_wheel(output_dir / "wheels")
    build_stemwerk_core_wheel(repo_root, output_dir / "wheels", python_executable)
    ensure_wheelhouse_complete(output_dir / "wheels")
    audit_wheelhouse_resolution(output_dir / "wheels", python_executable)
    copy_tree(managed_python_dir, output_dir / "python", "managed Python runtime payload")
    copy_files(model_cache, output_dir / "models", CORE_MODEL_FILES, "core model payload file")
    copy_files(model_cache, output_dir / "drumsep", DRUMSEP_FILES, "drumsep payload file")
    write_manifest(output_dir, args.version)
    audit_existing_manifest(output_dir)
    print(f"Prepared Apple Silicon macOS payload at {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
