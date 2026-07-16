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
import tempfile
import zipfile
from email.parser import BytesParser
from email.policy import default as email_policy
from pathlib import Path

try:
    from packaging.markers import default_environment
    from packaging.requirements import Requirement
    from packaging.utils import canonicalize_name, parse_wheel_filename
    from packaging.version import Version
except ImportError:  # payload Python always has pip, whose vendored packaging is sufficient here
    from pip._vendor.packaging.markers import default_environment
    from pip._vendor.packaging.requirements import Requirement
    from pip._vendor.packaging.utils import canonicalize_name, parse_wheel_filename
    from pip._vendor.packaging.version import Version


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
    "config_drumsep_mdx23c.yaml",
)
DRUMSEP_MODEL_CACHE_FILES = DRUMSEP_FILES[:2]
DRUMSEP_COMPAT_ASSET = Path("tools/assets/macos/drumsep/config_drumsep_mdx23c.yaml")
DRUMSEP_COMPAT_CANONICAL_SHA256 = "b7165bb73a0b08df49ac4ed5fe7424e29bf2f707b5878300f729a7e92671257a"
DRUMSEP_COMPAT_CANONICAL_SIZE = 2331
DRUMSEP_COMPAT_INSTRUMENTS = ("kick", "snare", "toms", "hh", "ride", "crash")
DRUMSEP_COMPAT_SOURCE_PROVENANCE = {
    "sha256": "17d1649a227f841165bdb4c11a42082898192a1ea3ceab7e7e0b9293d6589dd6",
    "size": 2417,
    "newlines": "CRLF",
}
DRUMSEP_FILE_POLICY = {
    DRUMSEP_FILES[0]: {
        "role": "canonical_model",
    },
    DRUMSEP_FILES[1]: {
        "role": "canonical_config",
    },
    DRUMSEP_FILES[2]: {
        "role": "compatibility_config",
        "sha256": DRUMSEP_COMPAT_CANONICAL_SHA256,
        "size": DRUMSEP_COMPAT_CANONICAL_SIZE,
        "canonical_payload_newlines": "LF",
        "instruments": DRUMSEP_COMPAT_INSTRUMENTS,
        "source_provenance": DRUMSEP_COMPAT_SOURCE_PROVENANCE,
    },
}

BOOTSTRAP_REQUIREMENTS = (
    "pip",
    "setuptools",
    "wheel",
)
BOOTSTRAP_VERSION_POLICY = {
    "pip": "26.1.2",
    "setuptools": "83.0.0",
    "wheel": "0.45.1",
}
PINNED_BOOTSTRAP_REQUIREMENTS = tuple(
    f"{name}=={BOOTSTRAP_VERSION_POLICY[name]}" for name in BOOTSTRAP_REQUIREMENTS
)
STEMWERK_CORE_VERSION = "0.1.1"

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
BOOTSTRAP_ALLOWLIST = {canonicalize_name(name) for name in BOOTSTRAP_REQUIREMENTS}
REQUIRED_CLOSURE_PACKAGES = {canonicalize_name("flatbuffers")}
FULL_CORE_RESOLVER_REQUIREMENTS = tuple(
    requirement for requirement in MAIN_REQUIREMENTS if not requirement.startswith("samplerate==")
)

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
    requirements += list(PINNED_BOOTSTRAP_REQUIREMENTS)
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
    required_closure_wheels: dict[str, list[tuple[str, str]]] = {name: [] for name in REQUIRED_CLOSURE_PACKAGES}
    bootstrap_wheels: dict[str, list[tuple[str, str]]] = {
        canonicalize_name(name): [] for name in BOOTSTRAP_REQUIREMENTS
    }
    for path in wheels:
        lower_names.setdefault(path.name.lower(), []).append(path.name)
        name, version = wheel_identity(path)
        if name in core_wheels:
            core_wheels[name].append((path.name, version))
        if name in closure_wheels:
            closure_wheels[name].append((path.name, version))
        if name in required_closure_wheels:
            required_closure_wheels[name].append((path.name, version))
        if name in bootstrap_wheels:
            bootstrap_wheels[name].append((path.name, version))
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
    required_closure_failures = [
        f"{name}:found=" + ("|".join(f"{filename}@{version}" for filename, version in found) or "missing")
        for name, found in required_closure_wheels.items()
        if len(found) != 1
    ]
    if required_closure_failures:
        raise RuntimeError("dependency_closure_core_conflict:" + ";".join(required_closure_failures))
    bootstrap_failures = []
    for name, wanted in BOOTSTRAP_VERSION_POLICY.items():
        found = bootstrap_wheels[canonicalize_name(name)]
        if len(found) != 1 or found[0][1] != wanted:
            detail = "|".join(f"{filename}@{version}" for filename, version in found) or "missing"
            bootstrap_failures.append(f"{name}:expected={wanted}:found={detail}")
    if bootstrap_failures:
        raise RuntimeError("bootstrap_tool_version_conflict:" + ";".join(bootstrap_failures))
    return wheels


def target_marker_environment() -> dict[str, str]:
    environment = default_environment()
    environment.update({
        "implementation_name": "cpython",
        "python_version": "3.12",
        "python_full_version": "3.12.0",
        "sys_platform": "darwin",
        "platform_system": "Darwin",
        "platform_machine": "arm64",
        "extra": "",
    })
    return environment


def core_wheel_requires_dist(path: Path) -> list[Requirement]:
    try:
        with zipfile.ZipFile(path) as archive:
            metadata_names = [name for name in archive.namelist() if name.endswith(".dist-info/METADATA")]
            if len(metadata_names) != 1:
                raise RuntimeError(f"payload_core_metadata_missing:{path.name}")
            message = BytesParser(policy=email_policy).parsebytes(archive.read(metadata_names[0]))
    except RuntimeError:
        raise
    except Exception as exc:
        raise RuntimeError(f"payload_core_metadata_invalid:{path.name}:{exc}") from exc
    requirements = []
    for value in message.get_all("Requires-Dist", []):
        try:
            requirements.append(Requirement(value))
        except Exception as exc:
            raise RuntimeError(f"payload_core_metadata_invalid:{path.name}:{value}:{exc}") from exc
    return requirements


def validate_core_requires_dist(wheels_dir: Path) -> None:
    wheels = list(wheels_dir.glob("*.whl"))
    available: dict[str, set[str]] = {}
    core_paths: dict[str, Path] = {}
    for path in wheels:
        name, version = wheel_identity(path)
        available.setdefault(name, set()).add(version)
        if name in CORE_VERSION_POLICY:
            core_paths[name] = path
    environment = target_marker_environment()
    override = DEPENDENCY_OVERRIDE_POLICY[0]
    for core_name, path in core_paths.items():
        for requirement in core_wheel_requires_dist(path):
            if requirement.marker and not requirement.marker.evaluate(environment):
                print(f"PAYLOAD_CORE_DEPENDENCY core={core_name} requirement={requirement} active=false")
                continue
            dependency = canonicalize_name(requirement.name)
            if dependency in BOOTSTRAP_ALLOWLIST:
                print(f"PAYLOAD_CORE_DEPENDENCY core={core_name} requirement={requirement} active=true source=bootstrap")
                continue
            if (
                core_name == canonicalize_name("audio-separator")
                and dependency == canonicalize_name(override["package"])
                and str(requirement.specifier) == f"=={override['upstream_required']}"
                and override["project_override"] in available.get(dependency, set())
            ):
                print(f"PAYLOAD_CORE_DEPENDENCY core={core_name} requirement={requirement} active=true source=override")
                continue
            versions = set() if dependency in NON_CLOSURE_PACKAGES else available.get(dependency, set())
            if not versions or not any(Version(version) in requirement.specifier for version in versions):
                raise RuntimeError(
                    f"payload_core_dependency_unsatisfied:{core_name}:{requirement}:available={','.join(sorted(versions)) or 'missing'}"
                )
            source = "core" if dependency in CORE_VERSION_POLICY else "closure"
            print(f"PAYLOAD_CORE_DEPENDENCY core={core_name} requirement={requirement} active=true source={source}")


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


def run_pip_download_plan(
    requirements: tuple[str, ...], wheels_dir: Path, constraints_file: Path, python_executable: str
) -> None:
    wheels_dir.mkdir(parents=True, exist_ok=True)
    cmd = [
        python_executable, "-m", "pip", "download", "--dest", str(wheels_dir),
        "--only-binary=:all:", "--find-links", str(wheels_dir), "-c", str(constraints_file),
        *requirements,
    ]
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


def isolated_environment_python(environment_dir: Path) -> Path:
    return environment_dir / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


def run_core_build_command(command: list[str], failure_reason: str, **kwargs) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(command, check=True, env=command_env(), **kwargs)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise RuntimeError(failure_reason) from exc


def validate_stemwerk_core_candidates(directory: Path) -> Path:
    candidates = sorted(directory.glob("stemwerk_core-*.whl"))
    if not candidates:
        raise RuntimeError("core_wheel_missing")
    if len(candidates) != 1:
        raise RuntimeError("core_wheel_ambiguous:" + ",".join(path.name for path in candidates))
    name, version = wheel_identity(candidates[0])
    if name != canonicalize_name("stemwerk-core") or version != STEMWERK_CORE_VERSION:
        raise RuntimeError(f"core_wheel_invalid:{candidates[0].name}")
    return candidates[0]


def build_stemwerk_core_wheel(repo_root: Path, wheels_dir: Path, python_executable: str) -> Path:
    existing = sorted(wheels_dir.glob("stemwerk_core-*.whl"))
    if existing:
        return validate_stemwerk_core_candidates(wheels_dir)

    wheels_dir.mkdir(parents=True, exist_ok=True)
    temporary = None
    print(f"CORE_BUILD_INVOKING_PYTHON={python_executable}")
    try:
        try:
            temporary = tempfile.TemporaryDirectory(prefix=".stemwerk-core-build-", dir=wheels_dir.parent)
        except OSError as exc:
            raise RuntimeError("core_build_environment_create_failed") from exc
        build_root = Path(temporary.name)
        environment_dir = build_root / "venv"
        built_wheels = build_root / "dist"
        built_wheels.mkdir()
        run_core_build_command(
            [python_executable, "-m", "venv", str(environment_dir)],
            "core_build_environment_create_failed",
        )
        build_python = isolated_environment_python(environment_dir)
        if not build_python.is_file():
            raise RuntimeError("core_build_environment_create_failed:python_missing")
        print(f"CORE_BUILD_TEMPORARY_PYTHON={build_python}")
        install_command = [
            str(build_python), "-m", "pip", "install", "--no-index", "--find-links", str(wheels_dir),
            "--only-binary=:all:", "--upgrade", *PINNED_BOOTSTRAP_REQUIREMENTS,
        ]
        print("CORE_BUILD_TOOL_POLICY=" + " ".join(PINNED_BOOTSTRAP_REQUIREMENTS))
        run_core_build_command(install_command, "core_build_tools_install_failed")
        backend_probe = (
            "import importlib.metadata as m; import setuptools; import wheel; import setuptools.build_meta; "
            "print('pip=' + m.version('pip') + ' setuptools=' + m.version('setuptools') + ' wheel=' + m.version('wheel'))"
        )
        probe = run_core_build_command(
            [str(build_python), "-c", backend_probe],
            "core_build_backend_unavailable",
            capture_output=True,
            text=True,
        )
        print("CORE_BUILD_TOOL_VERSIONS=" + probe.stdout.strip())
        source_dir = repo_root / "scripts" / "reaper" / "vendor" / "stemwerk-core"
        isolated_source_dir = build_root / "source" / "stemwerk-core"
        try:
            shutil.copytree(
                source_dir,
                isolated_source_dir,
                ignore=shutil.ignore_patterns("build", "dist", "*.egg-info", "__pycache__", "*.pyc"),
            )
        except OSError as exc:
            raise RuntimeError("core_build_source_prepare_failed") from exc
        print(f"CORE_BUILD_SOURCE={source_dir}")
        build_command = [
            str(build_python), "-m", "pip", "wheel", "--no-deps", "--no-build-isolation",
            "--wheel-dir", str(built_wheels), str(isolated_source_dir),
        ]
        print("CORE_BUILD_COMMAND=" + " ".join(build_command))
        run_core_build_command(build_command, "core_wheel_build_failed")
        built_wheel = validate_stemwerk_core_candidates(built_wheels)
        destination = wheels_dir / built_wheel.name
        shutil.copy2(built_wheel, destination)
        print(f"CORE_BUILD_OUTPUT_WHEEL={destination.name}")
        return destination
    finally:
        if temporary is not None:
            temporary.cleanup()
            print("CORE_BUILD_TEMPORARY_ENV_CLEANUP=ok")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_drumsep_files(drumsep_dir: Path, inventory: list[dict] | None = None) -> list[Path]:
    if not drumsep_dir.is_dir():
        raise RuntimeError(f"payload_drumsep_root_missing:{drumsep_dir}")
    entries = sorted(drumsep_dir.iterdir(), key=lambda path: path.name.lower())
    physical = {path.name: path for path in entries if path.is_file()}
    if len(physical) != len(entries) or set(physical) != set(DRUMSEP_FILE_POLICY):
        raise RuntimeError(
            "payload_drumsep_files_mismatch:expected=" + ",".join(DRUMSEP_FILE_POLICY)
            + ":actual=" + ",".join(path.name for path in entries)
        )
    for filename, policy in DRUMSEP_FILE_POLICY.items():
        path = physical[filename]
        if policy.get("sha256") and sha256_file(path) != policy["sha256"]:
            raise RuntimeError(f"payload_drumsep_checksum_mismatch:{filename}")
        if "size" in policy and path.stat().st_size != policy["size"]:
            raise RuntimeError(f"payload_drumsep_size_mismatch:{filename}")
        if filename == DRUMSEP_COMPAT_ASSET.name:
            try:
                import yaml

                document = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.FullLoader)
                instruments = tuple(document["training"]["instruments"])
            except Exception as exc:
                raise RuntimeError(f"payload_drumsep_semantics_invalid:{filename}:{exc}") from exc
            if instruments != DRUMSEP_COMPAT_INSTRUMENTS:
                raise RuntimeError(f"payload_drumsep_instruments_mismatch:{filename}")
    if inventory is not None:
        manifest_by_name = {item.get("filename", ""): item for item in inventory}
        if len(manifest_by_name) != len(inventory) or set(manifest_by_name) != set(physical):
            raise RuntimeError("payload_drumsep_inventory_mismatch")
        for filename, path in physical.items():
            item = manifest_by_name[filename]
            policy = DRUMSEP_FILE_POLICY[filename]
            if item.get("role") != policy["role"]:
                raise RuntimeError(f"payload_drumsep_role_mismatch:{filename}")
            if item.get("sha256") != sha256_file(path) or item.get("size") != path.stat().st_size:
                raise RuntimeError(f"payload_drumsep_inventory_fingerprint_mismatch:{filename}")
            if filename == DRUMSEP_COMPAT_ASSET.name:
                if item.get("canonical_payload_newlines") != policy["canonical_payload_newlines"]:
                    raise RuntimeError(f"payload_drumsep_inventory_policy_mismatch:{filename}:newlines")
                if item.get("instruments") != list(policy["instruments"]):
                    raise RuntimeError(f"payload_drumsep_inventory_policy_mismatch:{filename}:instruments")
                if item.get("source_provenance") != policy["source_provenance"]:
                    raise RuntimeError(f"payload_drumsep_inventory_policy_mismatch:{filename}:provenance")
    return list(physical.values())


def drumsep_file_inventory(drumsep_dir: Path) -> list[dict]:
    paths = validate_drumsep_files(drumsep_dir)
    inventory = [
        {
            "filename": path.name,
            "role": DRUMSEP_FILE_POLICY[path.name]["role"],
            "sha256": sha256_file(path),
            "size": path.stat().st_size,
        }
        for path in sorted(paths, key=lambda item: item.name)
    ]
    compatibility = next(item for item in inventory if item["filename"] == DRUMSEP_COMPAT_ASSET.name)
    compatibility.update(
        canonical_payload_newlines="LF",
        instruments=list(DRUMSEP_COMPAT_INSTRUMENTS),
        source_provenance=dict(DRUMSEP_COMPAT_SOURCE_PROVENANCE),
    )
    return inventory


def write_manifest(output_dir: Path, version: str) -> None:
    # Deferred D6: wheels are fully fingerprinted here; ffmpeg, models, and the
    # managed Python tree still need a separate non-wheel integrity design.
    validate_closed_world_wheelhouse(output_dir / "wheels")
    validate_core_requires_dist(output_dir / "wheels")
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
        "bootstrap_requirements": list(BOOTSTRAP_REQUIREMENTS),
        "dependency_overrides": list(DEPENDENCY_OVERRIDE_POLICY),
        "forbidden_requirements": list(FORBIDDEN_REQUIREMENTS),
        "wheel_inventory": wheel_inventory,
        "drumsep_file_inventory": drumsep_file_inventory(output_dir / "drumsep"),
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
    if manifest.get("bootstrap_requirements") != list(BOOTSTRAP_REQUIREMENTS):
        raise RuntimeError("payload_override_contract_invalid:bootstrap_requirements")
    validate_drumsep_files(output_dir / "drumsep", manifest.get("drumsep_file_inventory"))
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
    validate_core_requires_dist(output_dir / "wheels")


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
    # onnx-weekly is intentionally not separately pinned in this hotfix. The
    # closed-world manifest freezes the exact resolver snapshot; add a policy
    # pin during the next ASEP/runtime upgrade if cross-build determinism needs it.
    try:
        run_pip_download_plan(FULL_CORE_RESOLVER_REQUIREMENTS, resolver_dir, resolver_constraints, python_executable)
    except subprocess.CalledProcessError:
        ensure_diffq_wheel(resolver_dir)
        run_pip_download_plan(FULL_CORE_RESOLVER_REQUIREMENTS, resolver_dir, resolver_constraints, python_executable)
    project_resolved_wheels(resolver_dir, output_dir / "wheels")
    run_pip_download(
        PINNED_BOOTSTRAP_REQUIREMENTS + MAIN_REQUIREMENTS,
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
    copy_files(model_cache, output_dir / "drumsep", DRUMSEP_MODEL_CACHE_FILES, "drumsep payload file")
    copy_files(
        repo_root / DRUMSEP_COMPAT_ASSET.parent,
        output_dir / "drumsep",
        (DRUMSEP_COMPAT_ASSET.name,),
        "DrumSep compatibility config",
    )
    write_manifest(output_dir, args.version)
    audit_existing_manifest(output_dir)
    print(f"Prepared Apple Silicon macOS payload at {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
