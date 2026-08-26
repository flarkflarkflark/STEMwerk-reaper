#!/usr/bin/env python3
"""Build and validate STEMwerk's portable Apple Silicon FFmpeg pair."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from collections.abc import Mapping
from pathlib import Path


FFMPEG_VERSION = "8.0.3"
FFMPEG_SOURCE_URL = f"https://ffmpeg.org/releases/ffmpeg-{FFMPEG_VERSION}.tar.xz"
FFMPEG_SOURCE_SHA256 = "6136812ea6d4e68bdba27e33c2a94382711cdf4f8602ffef056ff792bd6f9818"
FFMPEG_LICENSE = "LGPL-2.1-or-later"
MACOS_DEPLOYMENT_TARGET = "12.0"
FFMPEG_CONFIGURE_FLAGS = (
    f"--prefix=/STEMwerk/ffmpeg-{FFMPEG_VERSION}",
    "--arch=arm64",
    "--cc=clang",
    "--disable-shared",
    "--enable-static",
    "--disable-doc",
    "--disable-debug",
    "--disable-ffplay",
    "--disable-network",
    "--disable-autodetect",
    f"--extra-cflags=-arch arm64 -mmacosx-version-min={MACOS_DEPLOYMENT_TARGET}",
    f"--extra-ldflags=-arch arm64 -mmacosx-version-min={MACOS_DEPLOYMENT_TARGET}",
)

FORBIDDEN_ABSOLUTE_PREFIXES = (
    "/opt/homebrew/",
    "/usr/local/Homebrew/",
    "/usr/local/Cellar/",
    "/opt/local/",
    "/sw/",
)
ALLOWED_SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")
FORBIDDEN_EMBEDDED_PATHS = (
    *FORBIDDEN_ABSOLUTE_PREFIXES,
    "/private/tmp/",
    "/var/folders/",
    "stemwerk-ffmpeg-build-",
)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _run(command: list[str], **kwargs: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, check=True, text=True, **kwargs)


def macho_architectures(path: Path) -> tuple[str, ...]:
    with path.open("rb") as handle:
        magic = handle.read(4)
    if magic not in {
        b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe",
        b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",
    }:
        return ()
    result = _run(["lipo", "-archs", str(path)], capture_output=True)
    return tuple(result.stdout.strip().split())


def macho_dependencies(path: Path) -> tuple[str, ...]:
    result = _run(["otool", "-L", str(path)], capture_output=True)
    dependencies: list[str] = []
    for line in result.stdout.splitlines()[1:]:
        dependency = line.strip().split(" (compatibility version", 1)[0]
        if dependency:
            dependencies.append(dependency)
    return tuple(dependencies)


def macho_build_metadata(path: Path) -> dict[str, object]:
    """Return the deployment target, SDK and LC_RPATH values from a Mach-O."""
    output = _run(["otool", "-l", str(path)], capture_output=True).stdout.splitlines()
    minimum_os = ""
    sdk = ""
    rpaths: list[str] = []
    for index, line in enumerate(output):
        command = line.strip()
        window = [item.strip() for item in output[index + 1:index + 10]]
        if command == "cmd LC_BUILD_VERSION":
            for item in window:
                if item.startswith("minos "):
                    minimum_os = item.split(None, 1)[1]
                elif item.startswith("sdk "):
                    sdk = item.split(None, 1)[1]
        elif command == "cmd LC_VERSION_MIN_MACOSX":
            for item in window:
                if item.startswith("version "):
                    minimum_os = item.split(None, 1)[1]
                elif item.startswith("sdk "):
                    sdk = item.split(None, 1)[1]
        elif command == "cmd LC_RPATH":
            for item in window:
                if item.startswith("path "):
                    rpaths.append(item.split(None, 2)[1])
                    break
    if not minimum_os:
        raise RuntimeError(f"Mach-O has no macOS minimum-version load command: {path}")
    return {"minimum_os": minimum_os, "sdk": sdk, "rpaths": rpaths}


def embedded_forbidden_paths(path: Path) -> tuple[str, ...]:
    output = _run(["strings", "-a", str(path)], capture_output=True).stdout
    return tuple(prefix for prefix in FORBIDDEN_EMBEDDED_PATHS if prefix in output)


def parse_buildconf_flags(output: str) -> list[str]:
    flags: list[str] = []
    for line in output.splitlines():
        flag = line.strip()
        if not flag.startswith("--"):
            continue
        if "=" in flag:
            key, value = flag.split("=", 1)
            if len(value) >= 2 and value[0] == value[-1] == "'":
                flag = f"{key}={value[1:-1]}"
        flags.append(flag)
    return flags


def _resolve_relative_dependency(binary: Path, executable_dir: Path, dependency: str) -> Path:
    if dependency.startswith("@loader_path/"):
        return binary.parent / dependency[len("@loader_path/"):]
    if dependency.startswith("@executable_path/"):
        return executable_dir / dependency[len("@executable_path/"):]
    raise RuntimeError(f"Unresolved Mach-O dependency is not permitted: {binary}: {dependency}")


def audit_macho_closure(binary: Path, *, expected_arch: str = "arm64") -> list[dict[str, object]]:
    """Require a complete closure made only of bundled files and macOS system libraries."""
    executable_dir = binary.parent.resolve()
    pending = [binary.resolve()]
    seen: set[Path] = set()
    records: list[dict[str, object]] = []
    while pending:
        current = pending.pop()
        if current in seen:
            continue
        seen.add(current)
        if not current.is_file():
            raise RuntimeError(f"Missing bundled Mach-O dependency: {current}")
        architectures = macho_architectures(current)
        if architectures != (expected_arch,):
            raise RuntimeError(
                f"Expected thin {expected_arch} Mach-O object: {current} ({' '.join(architectures) or 'not Mach-O'})"
            )
        dependencies = macho_dependencies(current)
        for dependency in dependencies:
            if dependency.startswith(FORBIDDEN_ABSOLUTE_PREFIXES):
                raise RuntimeError(f"Forbidden package-manager dependency: {current}: {dependency}")
            if dependency.startswith(ALLOWED_SYSTEM_PREFIXES):
                continue
            if dependency.startswith("/"):
                raise RuntimeError(f"Forbidden external absolute dependency: {current}: {dependency}")
            resolved = _resolve_relative_dependency(current, executable_dir, dependency).resolve()
            if executable_dir not in (resolved, *resolved.parents):
                raise RuntimeError(f"Mach-O dependency escapes bundled FFmpeg directory: {dependency}")
            pending.append(resolved)
        records.append({
            "path": current.relative_to(executable_dir).as_posix(),
            "architectures": list(architectures),
            "dependencies": list(dependencies),
        })
    return records


def validate_ffmpeg_pair(
    ffmpeg: Path,
    ffprobe: Path,
    *,
    expected_arch: str = "arm64",
    expected_deployment_target: str | None = None,
    require_official_build: bool = False,
) -> dict[str, object]:
    for path, label in ((ffmpeg, "ffmpeg"), (ffprobe, "ffprobe")):
        if not path.is_file():
            raise RuntimeError(f"Missing required {label}: {path}")
        if not os.access(path, os.X_OK):
            raise RuntimeError(f"Required {label} is not executable: {path}")
    closure = {
        "ffmpeg": audit_macho_closure(ffmpeg, expected_arch=expected_arch),
        "ffprobe": audit_macho_closure(ffprobe, expected_arch=expected_arch),
    }
    clean_env = os.environ.copy()
    clean_env.update({"PATH": "/usr/bin:/bin", "DYLD_LIBRARY_PATH": "", "DYLD_FALLBACK_LIBRARY_PATH": ""})
    versions: dict[str, str] = {}
    build_metadata: dict[str, dict[str, object]] = {}
    build_configurations: dict[str, list[str]] = {}
    for path, label in ((ffmpeg, "ffmpeg"), (ffprobe, "ffprobe")):
        result = subprocess.run(
            [str(path), "-version"], capture_output=True, text=True, env=clean_env, timeout=30
        )
        if result.returncode != 0:
            detail = (result.stderr or result.stdout).strip().replace("\n", " ")[-1000:]
            raise RuntimeError(f"{label} -version failed with exit {result.returncode}: {detail}")
        first_line = result.stdout.splitlines()[0] if result.stdout.splitlines() else ""
        if not first_line.lower().startswith(f"{label} version "):
            raise RuntimeError(f"Unexpected {label} -version output: {first_line}")
        if require_official_build and not first_line.startswith(f"{label} version {FFMPEG_VERSION} "):
            raise RuntimeError(f"Unexpected official {label} version: {first_line}")
        configuration_result = subprocess.run(
            [str(path), "-buildconf"], capture_output=True, text=True, env=clean_env, timeout=30
        )
        if configuration_result.returncode != 0:
            raise RuntimeError(f"{label} -buildconf failed with exit {configuration_result.returncode}")
        buildconf = configuration_result.stdout
        reported_flags = parse_buildconf_flags(buildconf)
        flags = [flag for flag in FFMPEG_CONFIGURE_FLAGS if flag in reported_flags]
        if require_official_build and tuple(flags) != FFMPEG_CONFIGURE_FLAGS:
            missing = [flag for flag in FFMPEG_CONFIGURE_FLAGS if flag not in reported_flags]
            raise RuntimeError(f"{label} is missing required configure flags: {', '.join(missing)}")
        if "--enable-gpl" in buildconf or "--enable-nonfree" in buildconf:
            raise RuntimeError(f"{label} enables forbidden GPL/nonfree configuration")
        metadata = macho_build_metadata(path)
        if expected_deployment_target and metadata["minimum_os"] != expected_deployment_target:
            raise RuntimeError(
                f"Unexpected {label} minimum macOS: {metadata['minimum_os']} "
                f"(expected {expected_deployment_target})"
            )
        if metadata["rpaths"]:
            raise RuntimeError(f"Unexpected {label} LC_RPATH entries: {metadata['rpaths']}")
        forbidden = embedded_forbidden_paths(path)
        if forbidden:
            raise RuntimeError(f"Forbidden embedded build/package path in {label}: {', '.join(forbidden)}")
        versions[label] = first_line
        build_metadata[label] = metadata
        build_configurations[label] = flags
    if require_official_build:
        license_result = subprocess.run(
            [str(ffmpeg), "-L"], capture_output=True, text=True, env=clean_env, timeout=30
        )
        if license_result.returncode != 0 or "GNU Lesser General Public" not in license_result.stdout:
            raise RuntimeError("Official FFmpeg binary does not report the expected LGPL license")
    return {
        "versions": versions,
        "configure_flags": build_configurations,
        "build_metadata": build_metadata,
        "closure": closure,
    }


def _toolchain_metadata() -> dict[str, str]:
    commands = {
        "macos_version": ["sw_vers", "-productVersion"],
        "macos_build": ["sw_vers", "-buildVersion"],
        "developer_dir": ["xcode-select", "-p"],
        "apple_clang": ["clang", "--version"],
        "sdk_path": ["xcrun", "--sdk", "macosx", "--show-sdk-path"],
        "sdk_version": ["xcrun", "--sdk", "macosx", "--show-sdk-version"],
    }
    values = {
        name: _run(command, capture_output=True).stdout.strip()
        for name, command in commands.items()
    }
    xcode = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True)
    xcode_detail = "\n".join(part.strip() for part in (xcode.stdout, xcode.stderr) if part.strip())
    values["xcode"] = f"exit={xcode.returncode}; {xcode_detail or 'no output'}"
    values["host_architecture"] = os.uname().machine
    values["deployment_target"] = MACOS_DEPLOYMENT_TARGET
    return values


def _copy_distribution_notices(destination: Path) -> dict[str, dict[str, object]]:
    repo_root = Path(__file__).resolve().parents[1]
    sources = {
        "COPYING.LGPLv2.1": destination / "COPYING.LGPLv2.1",
        "THIRD_PARTY_NOTICES.md": repo_root / "THIRD_PARTY_NOTICES.md",
        "PROVENANCE.md": repo_root / "tools/macos-ffmpeg/PROVENANCE.md",
    }
    records: dict[str, dict[str, object]] = {}
    for name, source in sources.items():
        if not source.is_file():
            raise RuntimeError(f"Missing FFmpeg distribution notice: {source}")
        target = destination / name
        if source.resolve() != target.resolve():
            shutil.copy2(source, target)
        records[name] = {"sha256": sha256_file(target), "size": target.stat().st_size}
    return records


def build_official_arm64_ffmpeg(
    destination: Path, *, source_artifact_dir: Path | None = None
) -> dict[str, object]:
    if os.uname().sysname != "Darwin" or os.uname().machine != "arm64":
        raise RuntimeError("The portable FFmpeg source build requires a native Apple Silicon macOS host")
    toolchain = _toolchain_metadata()
    destination.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="stemwerk-ffmpeg-build-") as temp_name:
        temp = Path(temp_name)
        archive = temp / f"ffmpeg-{FFMPEG_VERSION}.tar.xz"
        urllib.request.urlretrieve(FFMPEG_SOURCE_URL, archive)
        if sha256_file(archive) != FFMPEG_SOURCE_SHA256:
            raise RuntimeError("Official FFmpeg source SHA256 mismatch")
        source = temp / "source"
        source.mkdir()
        with tarfile.open(archive, "r:xz") as source_tar:
            source_tar.extractall(source, filter="data")
        extracted = source / f"ffmpeg-{FFMPEG_VERSION}"
        if source_artifact_dir is not None:
            source_artifact_dir.mkdir(parents=True, exist_ok=True)
            preserved = source_artifact_dir / archive.name
            shutil.copy2(archive, preserved)
            (source_artifact_dir / f"{archive.name}.sha256").write_text(
                f"{FFMPEG_SOURCE_SHA256}  {archive.name}\n", encoding="utf-8"
            )
        configure = ["./configure", *FFMPEG_CONFIGURE_FLAGS]
        build_command = ["make", f"-j{max(1, os.cpu_count() or 1)}", "ffmpeg", "ffprobe"]
        env = os.environ.copy()
        env.update({"MACOSX_DEPLOYMENT_TARGET": MACOS_DEPLOYMENT_TARGET, "LC_ALL": "C"})
        _run(configure, cwd=extracted, env=env, capture_output=True)
        config_text = (extracted / "config.h").read_text(encoding="utf-8")
        configuration_macros = {}
        for macro in ("CONFIG_GPL", "CONFIG_NONFREE"):
            marker = f"#define {macro} "
            matches = [line for line in config_text.splitlines() if line.startswith(marker)]
            if len(matches) != 1:
                raise RuntimeError(f"Could not prove {macro} from FFmpeg config.h")
            configuration_macros[macro] = int(matches[0].split()[-1])
        if configuration_macros != {"CONFIG_GPL": 0, "CONFIG_NONFREE": 0}:
            raise RuntimeError(f"Forbidden FFmpeg license configuration: {configuration_macros}")
        _run(build_command, cwd=extracted, env=env, capture_output=True)
        for name in ("ffmpeg", "ffprobe"):
            shutil.copy2(extracted / name, destination / name)
            (destination / name).chmod(0o755)
        shutil.copy2(extracted / "COPYING.LGPLv2.1", destination / "COPYING.LGPLv2.1")
    notices = _copy_distribution_notices(destination)
    audit = validate_ffmpeg_pair(
        destination / "ffmpeg",
        destination / "ffprobe",
        expected_deployment_target=MACOS_DEPLOYMENT_TARGET,
        require_official_build=True,
    )
    provenance = {
        "component": "FFmpeg",
        "build_mode": "official-source",
        "official_source_build": True,
        "release_eligible": True,
        "version": FFMPEG_VERSION,
        "license": FFMPEG_LICENSE,
        "source_url": FFMPEG_SOURCE_URL,
        "source_sha256": FFMPEG_SOURCE_SHA256,
        "deployment_target": MACOS_DEPLOYMENT_TARGET,
        "configure": configure,
        "build_command": build_command,
        "configuration_macros": configuration_macros,
        "toolchain": toolchain,
        "reproducibility": "pinned source and auditable build inputs; byte-identical reproducibility is not claimed",
        "source_artifact": {
            "filename": f"ffmpeg-{FFMPEG_VERSION}.tar.xz",
            "sha256": FFMPEG_SOURCE_SHA256,
        },
        "notices": notices,
        "binaries": {
            name: {"sha256": sha256_file(destination / name), "size": (destination / name).stat().st_size}
            for name in ("ffmpeg", "ffprobe")
        },
        "validation": audit,
    }
    (destination / "SOURCE_PROVENANCE.json").write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return provenance


def validate_official_provenance(
    ffmpeg_dir: Path, *, manifest: Mapping[str, object] | None = None
) -> dict[str, object]:
    provenance_path = ffmpeg_dir / "SOURCE_PROVENANCE.json"
    if not provenance_path.is_file():
        raise RuntimeError(f"Missing FFmpeg provenance: {provenance_path}")
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    expected = {
        "component": "FFmpeg",
        "build_mode": "official-source",
        "official_source_build": True,
        "release_eligible": True,
        "version": FFMPEG_VERSION,
        "license": FFMPEG_LICENSE,
        "source_url": FFMPEG_SOURCE_URL,
        "source_sha256": FFMPEG_SOURCE_SHA256,
        "deployment_target": MACOS_DEPLOYMENT_TARGET,
        "configuration_macros": {"CONFIG_GPL": 0, "CONFIG_NONFREE": 0},
    }
    for key, value in expected.items():
        if provenance.get(key) != value:
            raise RuntimeError(f"Invalid official FFmpeg provenance field {key}: {provenance.get(key)!r}")
    if provenance.get("configure") != ["./configure", *FFMPEG_CONFIGURE_FLAGS]:
        raise RuntimeError("FFmpeg provenance configure command does not match the official recipe")
    build_command = provenance.get("build_command")
    if not isinstance(build_command, list) or build_command[-2:] != ["ffmpeg", "ffprobe"]:
        raise RuntimeError("FFmpeg provenance build command is missing or invalid")
    toolchain = provenance.get("toolchain")
    required_toolchain = (
        "macos_version", "macos_build", "developer_dir", "xcode", "apple_clang", "sdk_path",
        "sdk_version", "host_architecture", "deployment_target",
    )
    if not isinstance(toolchain, Mapping) or any(not toolchain.get(key) for key in required_toolchain):
        raise RuntimeError("FFmpeg provenance does not contain the complete build toolchain")
    if toolchain.get("host_architecture") != "arm64" or toolchain.get("deployment_target") != MACOS_DEPLOYMENT_TARGET:
        raise RuntimeError("FFmpeg provenance build host/target is not the release contract")
    source_artifact = provenance.get("source_artifact")
    if source_artifact != {
        "filename": f"ffmpeg-{FFMPEG_VERSION}.tar.xz", "sha256": FFMPEG_SOURCE_SHA256
    }:
        raise RuntimeError("FFmpeg corresponding-source artifact provenance is invalid")
    reproducibility = provenance.get("reproducibility", "")
    if not isinstance(reproducibility, str) or "byte-identical reproducibility is not claimed" not in reproducibility:
        raise RuntimeError("FFmpeg provenance overstates or omits the reproducibility contract")
    audit = validate_ffmpeg_pair(
        ffmpeg_dir / "ffmpeg",
        ffmpeg_dir / "ffprobe",
        expected_deployment_target=MACOS_DEPLOYMENT_TARGET,
        require_official_build=True,
    )
    if provenance.get("validation") != audit:
        raise RuntimeError("FFmpeg recorded validation/closure differs from the actual binaries")
    for name in ("ffmpeg", "ffprobe"):
        binary = ffmpeg_dir / name
        recorded = provenance.get("binaries", {}).get(name, {})
        if recorded.get("sha256") != sha256_file(binary) or recorded.get("size") != binary.stat().st_size:
            raise RuntimeError(f"FFmpeg provenance binary integrity mismatch: {name}")
    notices = provenance.get("notices", {})
    for name in ("COPYING.LGPLv2.1", "THIRD_PARTY_NOTICES.md", "PROVENANCE.md"):
        path = ffmpeg_dir / name
        record = notices.get(name, {}) if isinstance(notices, dict) else {}
        if not path.is_file():
            raise RuntimeError(f"Missing FFmpeg notice/license file: {name}")
        if record.get("sha256") != sha256_file(path) or record.get("size") != path.stat().st_size:
            raise RuntimeError(f"FFmpeg notice/license integrity mismatch: {name}")
    license_text = (ffmpeg_dir / "COPYING.LGPLv2.1").read_text(encoding="utf-8", errors="replace")
    notices_text = (ffmpeg_dir / "THIRD_PARTY_NOTICES.md").read_text(encoding="utf-8", errors="replace")
    provenance_text = (ffmpeg_dir / "PROVENANCE.md").read_text(encoding="utf-8", errors="replace")
    if "GNU LESSER GENERAL PUBLIC LICENSE" not in license_text:
        raise RuntimeError("Bundled FFmpeg license file is not LGPL-2.1")
    for value in (FFMPEG_VERSION, FFMPEG_SOURCE_URL, FFMPEG_SOURCE_SHA256, FFMPEG_LICENSE):
        if value not in notices_text + "\n" + provenance_text:
            raise RuntimeError(f"FFmpeg notices do not identify corresponding source value: {value}")
    if manifest is not None:
        source = manifest.get("source_provenance", {})
        expected_manifest = {
            "ffmpeg_version": FFMPEG_VERSION,
            "ffmpeg_license": FFMPEG_LICENSE,
            "ffmpeg_source_url": FFMPEG_SOURCE_URL,
            "ffmpeg_source_sha256": FFMPEG_SOURCE_SHA256,
        }
        for key, value in expected_manifest.items():
            if not isinstance(source, Mapping) or source.get(key) != value:
                raise RuntimeError(f"Manifest/provenance mismatch for {key}")
        if manifest.get("ffmpeg") != provenance:
            raise RuntimeError("Manifest embedded FFmpeg provenance differs from SOURCE_PROVENANCE.json")
        contains = manifest.get("contains", {})
        if not isinstance(contains, Mapping) or contains.get("ffmpeg") is not True:
            raise RuntimeError("Manifest does not declare bundled FFmpeg")
    return {"provenance": provenance, "validation": audit}
