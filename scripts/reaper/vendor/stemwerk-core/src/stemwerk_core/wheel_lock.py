"""Locked binary-only CPU wheel manifest and offline wheelhouse staging for S6."""

from __future__ import annotations

import base64
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import shutil
from typing import Any, Callable, Dict, List, Mapping, Optional, Tuple
from urllib.parse import urlparse
import urllib.request
import zipfile

WHEEL_LOCK_FILENAME = "wheel-lock-linux-x86_64-cpu.v1.json"
ALLOWED_WHEEL_HOSTS = frozenset(
    {
        "files.pythonhosted.org",
        "download.pytorch.org",
        "pypi.org",
    }
)
FORBIDDEN_GPU_DISTRIBUTION_PREFIXES = (
    "nvidia-",
    "triton",
    "torch-directml",
    "onnxruntime-gpu",
    "onnxruntime-directml",
    "onnxruntime-silicon",
)
WHEEL_CACHE_ENV = "STEMWERK_WHEEL_CACHE_DIR"


class WheelLockError(RuntimeError):
    """Structured error raised when wheel-lock validation or staging fails."""

    def __init__(self, code: str, message: str, **details: Any) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = dict(details)


@dataclass(frozen=True)
class WheelRecord:
    name: str
    version: str
    filename: str
    sha256: str
    size: int
    source_kind: str
    url: str
    host: str
    tags: Tuple[str, ...]
    requires_python: str
    requires_dist: Tuple[str, ...]
    license: str
    license_classifiers: Tuple[str, ...]
    license_files: Tuple[str, ...]


@dataclass(frozen=True)
class WheelLockManifest:
    schema_version: int
    lock_id: str
    module_id: str
    platform_key: str
    backend: str
    python_pin_name: str
    python_version: str
    abi_tag: str
    platform_tags: Tuple[str, ...]
    glibc_baseline: str
    allowed_hosts: Tuple[str, ...]
    local_vendor_wheel_dir: str
    local_core_package: Mapping[str, Any]
    wheel_count: int
    total_wheel_bytes: int
    wheels: Tuple[WheelRecord, ...]
    manifest_sha256: str


def default_wheel_lock_path() -> Path:
    return Path(__file__).resolve().with_name(WHEEL_LOCK_FILENAME)


def _is_sha256_hex(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(ch in "0123456789abcdef" for ch in value)
    )


def _validate_wheel_record(raw: Mapping[str, Any]) -> WheelRecord:
    if not isinstance(raw, Mapping):
        raise WheelLockError("wheel_lock_invalid", "wheel entry must be a JSON object")
    name = str(raw.get("name") or "").strip()
    version = str(raw.get("version") or "").strip()
    filename = str(raw.get("filename") or "").strip()
    sha256 = str(raw.get("sha256") or "").strip()
    size = raw.get("size")
    source_kind = str(raw.get("source_kind") or "").strip()
    url = str(raw.get("url") or "").strip()
    host = str(raw.get("host") or "").strip()

    if not name or not version or not filename:
        raise WheelLockError("wheel_lock_invalid", "wheel entry missing name, version, or filename")
    if not filename.endswith(".whl") or "/" in filename or "\\" in filename:
        raise WheelLockError(
            "wheel_lock_non_binary",
            f"only binary .whl artifacts are permitted in wheel lock: {filename!r}",
            filename=filename,
        )
    lower_name = name.lower().replace("_", "-")
    if any(lower_name.startswith(prefix) for prefix in FORBIDDEN_GPU_DISTRIBUTION_PREFIXES):
        raise WheelLockError(
            "wheel_lock_gpu_forbidden",
            f"GPU distribution {name!r} is forbidden in the S6 CPU wheel lock",
            distribution=name,
        )
    if "+cu" in version.lower() or "+rocm" in version.lower():
        raise WheelLockError(
            "wheel_lock_gpu_forbidden",
            f"GPU build tag in {name}=={version} is forbidden in the S6 CPU wheel lock",
            distribution=name,
            version=version,
        )
    if not _is_sha256_hex(sha256):
        raise WheelLockError(
            "wheel_lock_invalid",
            f"wheel {filename} has invalid SHA-256 digest",
            filename=filename,
        )
    if isinstance(size, bool) or not isinstance(size, int) or size <= 0:
        raise WheelLockError(
            "wheel_lock_invalid",
            f"wheel {filename} has invalid byte size {size!r}",
            filename=filename,
        )
    if source_kind not in {"https", "pypi", "pytorch_cpu", "vendor_local", "vendor_wheel"}:
        raise WheelLockError(
            "wheel_lock_invalid",
            f"wheel {filename} has unsupported source_kind {source_kind!r}",
            filename=filename,
        )
    if source_kind in {"vendor_local", "vendor_wheel"}:
        if host != "local_vendor" or url.startswith("http"):
            raise WheelLockError(
                "wheel_lock_invalid",
                f"vendor wheel {filename} must use relative repository path",
                filename=filename,
            )
    else:
        parsed = urlparse(url)
        if parsed.scheme != "https" or not parsed.hostname:
            raise WheelLockError(
                "wheel_lock_invalid",
                f"remote wheel {filename} must use https URL",
                filename=filename,
            )
        if parsed.hostname not in ALLOWED_WHEEL_HOSTS or parsed.hostname != host:
            raise WheelLockError(
                "wheel_lock_host_forbidden",
                f"remote wheel {filename} host {parsed.hostname!r} is not in allowed host set",
                filename=filename,
                host=parsed.hostname,
            )

    tags = tuple(str(item) for item in (raw.get("tags") or ()))
    requires_dist = tuple(str(item) for item in (raw.get("requires_dist") or ()))
    license_classifiers = tuple(str(item) for item in (raw.get("license_classifiers") or ()))
    license_files = tuple(str(item) for item in (raw.get("license_files") or ()))
    return WheelRecord(
        name=name,
        version=version,
        filename=filename,
        sha256=sha256,
        size=size,
        source_kind=source_kind,
        url=url,
        host=host,
        tags=tags,
        requires_python=str(raw.get("requires_python") or ""),
        requires_dist=requires_dist,
        license=str(raw.get("license") or ""),
        license_classifiers=license_classifiers,
        license_files=license_files,
    )


def load_wheel_lock(
    module_id: str = "drum_kit",
    platform_key: str = "linux-x86_64",
    backend: str = "cpu",
    *,
    path: Optional[Path] = None,
) -> WheelLockManifest:
    """Load and validate the pinned binary-only wheel lock manifest."""
    manifest_path = Path(path) if path is not None else default_wheel_lock_path()
    try:
        raw_bytes = manifest_path.read_bytes()
        data = json.loads(raw_bytes.decode("utf-8"))
    except Exception as exc:
        raise WheelLockError(
            "wheel_lock_unreadable",
            f"cannot read wheel lock manifest {manifest_path}: {exc}",
        ) from exc

    if not isinstance(data, Mapping):
        raise WheelLockError("wheel_lock_invalid", "wheel lock manifest must be a JSON object")
    if data.get("schema_version") != 1 or data.get("kind") != "stemwerk_wheel_lock":
        raise WheelLockError("wheel_lock_invalid", "unsupported wheel lock schema or kind")
    if (
        data.get("module_id") != module_id
        or data.get("platform_key") != platform_key
        or data.get("backend") != backend
    ):
        raise WheelLockError(
            "wheel_lock_mismatch",
            f"wheel lock target mismatch: expected {module_id}/{platform_key}/{backend}",
        )

    raw_wheels = data.get("wheels")
    if not isinstance(raw_wheels, list) or not raw_wheels:
        raise WheelLockError("wheel_lock_invalid", "wheel lock contains no wheels")

    wheels = tuple(_validate_wheel_record(item) for item in raw_wheels)
    seen_names: set[str] = set()
    for record in wheels:
        normalized = record.name.lower().replace("_", "-")
        if normalized in seen_names:
            raise WheelLockError(
                "wheel_lock_duplicate",
                f"duplicate package {record.name!r} in wheel lock",
            )
        seen_names.add(normalized)

    expected_count = data.get("wheel_count")
    expected_bytes = data.get("total_wheel_bytes")
    actual_bytes = sum(item.size for item in wheels)
    if expected_count != len(wheels):
        raise WheelLockError(
            "wheel_lock_invalid",
            f"wheel_count {expected_count!r} does not match {len(wheels)} records",
        )
    if expected_bytes != actual_bytes:
        raise WheelLockError(
            "wheel_lock_invalid",
            f"total_wheel_bytes {expected_bytes!r} does not match sum {actual_bytes}",
        )

    allowed_hosts = tuple(str(h) for h in (data.get("allowed_hosts") or ()))
    for host in allowed_hosts:
        if host not in ALLOWED_WHEEL_HOSTS:
            raise WheelLockError(
                "wheel_lock_host_forbidden",
                f"manifest allowed_host {host!r} is outside policy",
            )

    manifest_sha256 = hashlib.sha256(raw_bytes).hexdigest()
    return WheelLockManifest(
        schema_version=1,
        lock_id=str(data.get("lock_id") or ""),
        module_id=module_id,
        platform_key=platform_key,
        backend=backend,
        python_pin_name=str(data.get("python_pin_name") or ""),
        python_version=str(data.get("python_version") or ""),
        abi_tag=str(data.get("abi_tag") or ""),
        platform_tags=tuple(str(t) for t in (data.get("platform_tags") or ())),
        glibc_baseline=str(data.get("glibc_baseline") or ""),
        allowed_hosts=allowed_hosts,
        local_vendor_wheel_dir=str(data.get("local_vendor_wheel_dir") or ""),
        local_core_package=dict(data.get("local_core_package") or {}),
        wheel_count=len(wheels),
        total_wheel_bytes=actual_bytes,
        wheels=wheels,
        manifest_sha256=manifest_sha256,
    )


def _record_hash(data: bytes) -> str:
    digest = hashlib.sha256(data).digest()
    return "sha256=" + base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def build_stemwerk_core_wheel(
    wheelhouse_dir: Path,
    *,
    core_package_dir: Optional[Path] = None,
    version: str = "0.1.1",
) -> WheelRecord:
    """Build a deterministic pure-Python PEP 427 wheel for ``stemwerk-core``
    from the shipped ``stemwerk_core`` package directory using stdlib only.
    """
    pkg_dir = Path(core_package_dir) if core_package_dir is not None else Path(__file__).resolve().parent
    if not pkg_dir.is_dir() or not (pkg_dir / "__init__.py").is_file():
        raise WheelLockError(
            "core_wheel_source_missing",
            f"cannot locate stemwerk_core package directory at {pkg_dir}",
        )

    wheelhouse = Path(wheelhouse_dir)
    wheelhouse.mkdir(parents=True, exist_ok=True)
    wheel_filename = f"stemwerk_core-{version}-py3-none-any.whl"
    wheel_path = wheelhouse / wheel_filename
    part_path = wheelhouse / f"{wheel_filename}.part"
    dist_info = f"stemwerk_core-{version}.dist-info"
    fixed_time = (2026, 1, 1, 0, 0, 0)

    records: List[Tuple[str, str, int]] = []
    source_files = sorted(
        path
        for path in pkg_dir.rglob("*")
        if path.is_file()
        and "__pycache__" not in path.parts
        and path.suffix not in {".pyc", ".pyo"}
    )

    with zipfile.ZipFile(part_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for file_path in source_files:
            rel_posix = file_path.relative_to(pkg_dir).as_posix()
            arcname = f"stemwerk_core/{rel_posix}"
            payload = file_path.read_bytes()
            info = zipfile.ZipInfo(arcname, date_time=fixed_time)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            zf.writestr(info, payload)
            records.append((arcname, _record_hash(payload), len(payload)))

        metadata_bytes = (
            "Metadata-Version: 2.1\n"
            "Name: stemwerk-core\n"
            f"Version: {version}\n"
            "Summary: AI stem separation engine for the flarkAUDIO ecosystem.\n"
            "License: Proprietary\n"
            "Requires-Python: >=3.10,<3.13\n"
            "Requires-Dist: soundfile\n"
        ).encode("utf-8")
        wheel_bytes = (
            "Wheel-Version: 1.0\n"
            "Generator: stemwerk-s6-stdlib-wheel\n"
            "Root-Is-Purelib: true\n"
            "Tag: py3-none-any\n"
        ).encode("utf-8")
        top_level_bytes = b"stemwerk_core\n"

        for name_in_dist, payload in (
            ("METADATA", metadata_bytes),
            ("WHEEL", wheel_bytes),
            ("top_level.txt", top_level_bytes),
        ):
            arcname = f"{dist_info}/{name_in_dist}"
            info = zipfile.ZipInfo(arcname, date_time=fixed_time)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            zf.writestr(info, payload)
            records.append((arcname, _record_hash(payload), len(payload)))

        record_arcname = f"{dist_info}/RECORD"
        record_lines = [f"{arc},{digest},{size}" for arc, digest, size in records]
        record_lines.append(f"{record_arcname},,")
        record_payload = ("\n".join(record_lines) + "\n").encode("utf-8")
        info = zipfile.ZipInfo(record_arcname, date_time=fixed_time)
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        zf.writestr(info, record_payload)

    os.replace(part_path, wheel_path)
    final_bytes = wheel_path.read_bytes()
    sha256_hex = hashlib.sha256(final_bytes).hexdigest()
    return WheelRecord(
        name="stemwerk-core",
        version=version,
        filename=wheel_filename,
        sha256=sha256_hex,
        size=len(final_bytes),
        source_kind="in_tree_source",
        url="scripts/reaper/vendor/stemwerk-core/src/stemwerk_core",
        host="local_vendor",
        tags=("py3-none-any",),
        requires_python=">=3.10,<3.13",
        requires_dist=("soundfile",),
        license="Proprietary",
        license_classifiers=(),
        license_files=(),
    )


def _resolve_vendor_wheel_path(record: WheelRecord, repo_root: Optional[Path] = None) -> Path:
    if repo_root is not None:
        candidate = Path(repo_root) / record.url
        if candidate.is_file():
            return candidate
    # Discover relative to stemwerk_core package location:
    # .../scripts/reaper/vendor/stemwerk-core/src/stemwerk_core -> .../scripts/reaper
    here = Path(__file__).resolve()
    for parent in here.parents:
        candidate = parent / record.url
        if candidate.is_file():
            return candidate
        alt = parent / "vendor" / "wheels" / "linux-x86_64-cp312" / record.filename
        if alt.is_file():
            return alt
    raise WheelLockError(
        "vendor_wheel_missing",
        f"cannot locate shipped vendor wheel {record.filename} (expected {record.url})",
        filename=record.filename,
    )


def verify_wheel_file(path: Path, record: WheelRecord) -> None:
    """Verify that ``path`` is a regular file matching ``record.size`` and ``record.sha256``."""
    try:
        st = os.lstat(path)
    except OSError as exc:
        raise WheelLockError(
            "wheel_missing",
            f"staged wheel {record.filename} is missing: {exc}",
            filename=record.filename,
        ) from exc
    if os.path.islink(path) or not os.path.isfile(path):
        raise WheelLockError(
            "wheel_integrity_failed",
            f"staged wheel {record.filename} is not a regular file",
            filename=record.filename,
        )
    if st.st_size != record.size:
        raise WheelLockError(
            "wheel_size_mismatch",
            f"wheel {record.filename} size mismatch: expected {record.size}, got {st.st_size}",
            filename=record.filename,
            expected_size=record.size,
            actual_size=st.st_size,
        )
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            hasher.update(chunk)
    actual_sha256 = hasher.hexdigest()
    if actual_sha256 != record.sha256:
        raise WheelLockError(
            "wheel_hash_mismatch",
            f"wheel {record.filename} SHA-256 mismatch: expected {record.sha256}, got {actual_sha256}",
            filename=record.filename,
            expected_sha256=record.sha256,
            actual_sha256=actual_sha256,
        )


def _download_wheel_https(record: WheelRecord, destination: Path, timeout: float = 120.0) -> None:
    parsed = urlparse(record.url)
    if parsed.scheme != "https" or parsed.hostname not in ALLOWED_WHEEL_HOSTS:
        raise WheelLockError(
            "wheel_lock_host_forbidden",
            f"refusing to download {record.filename} from non-allowlisted URL {record.url!r}",
            filename=record.filename,
        )
    part_path = destination.with_name(f"{destination.name}.part")
    req = urllib.request.Request(
        record.url,
        headers={"User-Agent": "STEMwerk-Core-Installer/2.4"},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            with part_path.open("wb") as out:
                total = 0
                while True:
                    chunk = response.read(256 * 1024)
                    if not chunk:
                        break
                    total += len(chunk)
                    if total > record.size:
                        raise WheelLockError(
                            "wheel_size_mismatch",
                            f"download of {record.filename} exceeded expected size {record.size}",
                            filename=record.filename,
                        )
                    out.write(chunk)
        os.replace(part_path, destination)
    except WheelLockError:
        try:
            part_path.unlink()
        except OSError:
            pass
        raise
    except Exception as exc:
        try:
            part_path.unlink()
        except OSError:
            pass
        raise WheelLockError(
            "wheel_download_failed",
            f"failed downloading wheel {record.filename} from {record.host}: {type(exc).__name__}: {exc}",
            filename=record.filename,
            host=record.host,
        ) from exc


def write_locked_requirements(
    records: Tuple[WheelRecord, ...] | List[WheelRecord],
    destination: Path,
) -> Path:
    """Write a ``pip install --require-hashes`` requirements file for ``records``."""
    lines: List[str] = []
    for record in records:
        lines.append(f"{record.name}=={record.version} \\\n    --hash=sha256:{record.sha256}")
    destination.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return destination


def stage_and_verify_wheelhouse(
    manifest: WheelLockManifest,
    wheelhouse_dir: Path,
    *,
    repo_root: Optional[Path] = None,
    wheel_cache_dir: Optional[Path] = None,
    core_package_dir: Optional[Path] = None,
    fetcher: Optional[Callable[[WheelRecord, Path], None]] = None,
    on_wheel_verified: Optional[Callable[[WheelRecord], None]] = None,
) -> Tuple[Tuple[WheelRecord, ...], Path]:
    """Populate ``wheelhouse_dir`` with every locked wheel, verify exact byte
    sizes and SHA-256 digests before ``pip`` is invoked, synthesize the
    in-tree ``stemwerk-core`` wheel, and write ``requirements-locked.txt``.
    """
    wheelhouse = Path(wheelhouse_dir)
    wheelhouse.mkdir(parents=True, exist_ok=True)

    env_cache = (
        os.environ.get(WHEEL_CACHE_ENV, "").strip()
        or os.environ.get("STEMWERK_S6_WHEELHOUSE_DIR", "").strip()
    )
    cache_dir = (
        Path(wheel_cache_dir)
        if wheel_cache_dir is not None
        else (Path(env_cache) if env_cache else None)
    )

    staged_records: List[WheelRecord] = []
    for record in manifest.wheels:
        target = wheelhouse / record.filename
        if target.exists():
            verify_wheel_file(target, record)
        elif record.source_kind in {"vendor_local", "vendor_wheel"}:
            vendor_src = _resolve_vendor_wheel_path(record, repo_root=repo_root)
            shutil.copyfile(vendor_src, target)
            verify_wheel_file(target, record)
        elif cache_dir is not None and (cache_dir / record.filename).is_file():
            shutil.copyfile(cache_dir / record.filename, target)
            verify_wheel_file(target, record)
        elif fetcher is not None:
            fetcher(record, target)
            verify_wheel_file(target, record)
        else:
            _download_wheel_https(record, target)
            verify_wheel_file(target, record)

        staged_records.append(record)
        if on_wheel_verified is not None:
            on_wheel_verified(record)

    core_record = build_stemwerk_core_wheel(wheelhouse, core_package_dir=core_package_dir)
    verify_wheel_file(wheelhouse / core_record.filename, core_record)
    staged_records.append(core_record)
    if on_wheel_verified is not None:
        on_wheel_verified(core_record)

    requirements_path = write_locked_requirements(
        staged_records,
        wheelhouse / "requirements-locked.txt",
    )
    return tuple(staged_records), requirements_path
