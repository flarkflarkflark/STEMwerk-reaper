"""S6 Linux-first Direct Kit CPU installation orchestrator for STEMwerk Core.

S7 adds the pinned FFmpeg pair to the same transaction, and to an existing S6
root that lacks it, without touching the interpreter, the environment or the assets.
"""

from __future__ import annotations

import base64
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
from typing import Any, Callable, Dict, Mapping, Optional, Tuple
from urllib.parse import urlparse
import urllib.request
import uuid

from . import (
    asset_acquisition,
    asset_materialization,
    asset_preparation,
    install_events,
    install_journal,
    install_lock,
    install_preflight,
    managed_ffmpeg,
    managed_python,
    managed_runtime,
    model_assets,
    module_descriptors,
    module_registry,
    module_verify,
    runtime_manifest,
    subprocess_policy,
    wheel_lock,
)
from ._install_paths import InstallPathError, absolute_root, ensure_directories

ASSET_SOURCE_CACHE_ENV = "STEMWERK_ASSET_SOURCE_DIR"
FAULT_INJECT_ENV = "STEMWERK_TEST_S6_FAULT_PHASE"


class S6InstallError(RuntimeError):
    """Structured error raised during an S6 installation phase."""

    def __init__(
        self,
        phase: str,
        code: str,
        message: str,
        *,
        action: str = "Inspect the installation log and retry or repair the destination.",
        details: Optional[Mapping[str, Any]] = None,
    ) -> None:
        super().__init__(message)
        self.phase = phase
        self.code = code
        self.message = message
        self.action = action
        self.details = dict(details or {})


def _resolve_operation_id(explicit_operation_id: Optional[str] = None) -> str:
    raw = (
        str(explicit_operation_id or "").strip()
        or str(os.environ.get("STEMWERK_OPERATION_ID") or "").strip()
    )
    if not raw:
        return str(uuid.uuid4())
    install_events._check_operation_id(raw, "invalid_operation_id")
    return raw


def _open_or_accept_events(root: Path, operation_id: str) -> Tuple[install_events.EventWriter, Path]:
    logs_dir = ensure_directories(root, ("logs",))
    op_log_dir = logs_dir / operation_id
    if (op_log_dir / install_events.EVENTS_FILENAME).is_file():
        writer = install_events.EventWriter.accept_handover(op_log_dir, operation_id)
    else:
        outer = install_events.EventWriter.start_operation(logs_dir, operation_id)
        outer.append("done", "bootstrap", verified=True)
        writer = install_events.EventWriter.accept_handover(op_log_dir, operation_id)
    if not (op_log_dir / install_events.STARTED_FILENAME).exists():
        install_events.write_started(op_log_dir, operation_id)
    return writer, op_log_dir


def _determine_managed_python_ownership(root: Path, operation_id: str, module_id: str) -> str:
    """Return ``core_managed`` when managed Python was provisioned by a
    Core/outer-bootstrap operation on ``root``, or ``unknown`` when a
    pre-existing unreceipted directory was reused.
    """
    rec_file = module_registry.receipt_path(root, module_id)
    if rec_file.is_file():
        try:
            rec = json.loads(rec_file.read_text(encoding="utf-8"))
            mp = (rec.get("components") or {}).get("managed_python") or {}
            if mp.get("ownership") == "core_managed":
                return "core_managed"
        except Exception:
            pass

    logs_dir = root / "logs"
    if logs_dir.is_dir():
        for entry in sorted(logs_dir.iterdir()):
            if not entry.is_dir():
                continue
            outcome_file = entry / "bootstrap.outcome"
            events_file = entry / install_events.EVENTS_FILENAME
            if outcome_file.is_file() and events_file.is_file():
                try:
                    if outcome_file.read_text(encoding="utf-8").strip() == "new":
                        events = install_events.read_events(entry)
                        if any(
                            ev.get("phase") == "bootstrap" and ev.get("state") == "done" and ev.get("verified") is True
                            for ev in events
                        ):
                            return "core_managed"
                except Exception:
                    continue
    return "unknown"


def _normalize_venv_permissions(venv_root: Path) -> None:
    """Strip group/world write bits on all directories and regular files in
    ``venv_root`` before immutable publication.
    """
    if os.name != "posix":
        return
    root_mode = stat.S_IMODE(os.lstat(venv_root).st_mode) & ~0o022
    os.chmod(venv_root, root_mode)
    for current_root, dirnames, filenames in os.walk(venv_root, topdown=True, followlinks=False):
        current_path = Path(current_root)
        for name in [*dirnames, *filenames]:
            target = current_path / name
            st = os.lstat(target)
            if stat.S_ISLNK(st.st_mode):
                continue
            cleaned_mode = stat.S_IMODE(st.st_mode) & ~0o022
            if cleaned_mode != stat.S_IMODE(st.st_mode):
                os.chmod(target, cleaned_mode)


def _update_record_rows(stage: Path, changed: Mapping[Path, bytes]) -> None:
    """Keep each distribution's RECORD truthful about scripts rewritten after install."""
    for record_path in sorted((stage / "lib").glob("python*/site-packages/*.dist-info/RECORD")):
        site = record_path.parent.parent
        rows = list(csv.reader(record_path.read_text(encoding="utf-8").splitlines()))
        modified = False
        for row in rows:
            data = changed.get(Path(os.path.normpath(site / row[0]))) if row else None
            if data is None or len(row) != 3:
                continue
            digest = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode("ascii")
            row[1:] = [f"sha256={digest}", str(len(data))]
            modified = True
        if modified:
            buffer = io.StringIO()
            csv.writer(buffer, lineterminator="\n").writerows(rows)
            record_path.write_text(buffer.getvalue(), encoding="utf-8")


def _disable_script_bytecode(data: bytes, published: bytes) -> bytes:
    """Add ``-B`` to a console script's interpreter, in both forms pip generates.

    Without it, starting a script without ``PYTHONDONTWRITEBYTECODE`` writes
    ``.pyc`` files into the venv and the managed Python, and both then fail
    their exact comparison.
    """
    first, newline, rest = data.partition(b"\n")
    interpreter = published + b"/bin/python"
    if first.startswith(b"#!" + interpreter) and b" " not in first[len(interpreter) + 2:]:
        return first + b" -B" + newline + rest
    line, line_end, tail = rest.partition(b"\n")
    arguments = b' "$0" "$@"'
    if first == b"#!/bin/sh" and line.startswith(b"'''exec' ") and interpreter in line and line.endswith(arguments):
        return first + newline + line[: -len(arguments)] + b" -B" + arguments + line_end + tail
    return data


def _rewrite_staged_venv_paths(stage: Path, published: Path) -> None:
    """Make generated entry points refer to the path they will be published at.

    pip and venv embed the absolute staging path. Runs before the tree identity
    is sealed, so the receipt pins the corrected bytes.
    """
    old, new = os.fsencode(str(stage)), os.fsencode(str(published))
    old_prompt, new_prompt = os.fsencode(f"({stage.name}) "), os.fsencode(f"({published.name}) ")
    scripts = stage / ("Scripts" if os.name == "nt" else "bin")
    changed: Dict[Path, bytes] = {}
    for path in [stage / "pyvenv.cfg", *(sorted(scripts.iterdir()) if scripts.is_dir() else ())]:
        if path.is_symlink() or not path.is_file():
            continue
        original = path.read_bytes()
        data = original.replace(old, new).replace(old_prompt, new_prompt)
        data = _disable_script_bytecode(data, new)
        if data != original:
            path.write_bytes(data)
            changed[Path(os.path.normpath(path))] = data
    _update_record_rows(stage, changed)


def _probe_published_entry_points(venv_dir: Path) -> None:
    """Fail before registration if shipped console scripts cannot start."""
    with tempfile.TemporaryDirectory(prefix="stemwerk-console-probe-") as scratch:
        env = subprocess_policy.clean_pip_env()
        env["NUMBA_CACHE_DIR"] = str(Path(scratch) / "numba")
        for name, args in (("pip", ("--version",)), ("audio-separator", ("--help",))):
            script = venv_dir / "bin" / name
            if not script.is_file():
                raise S6InstallError("publish", "entry_point_missing", str(script))
            try:
                result = subprocess.run([str(script), *args], env=env, capture_output=True,
                                        text=True, timeout=60, check=False)
            except (OSError, subprocess.TimeoutExpired) as exc:
                raise S6InstallError("publish", "entry_point_failed", f"{name}: {exc}") from exc
            if result.returncode != 0:
                raise S6InstallError("publish", "entry_point_failed",
                                     f"{name} exited {result.returncode}: {(result.stderr or result.stdout)[-500:]}")


def _verify_published_object(root: Path, module_id: str, path: Path) -> bool:
    """Verifier hook passed to ``install_journal.recover``."""
    try:
        rel = path.relative_to(root).as_posix()
    except ValueError:
        return False
    if rel.startswith(f"runtimes/{module_id}/"):
        return module_registry.matches_publication_record(root, module_id, path)
    if rel.startswith("runtimes/ffmpeg/"):
        # The pair's bytes are vendor-pinned, so no seal is needed: a published
        # directory is acceptable only when it is exactly the pinned tree.
        try:
            pin = managed_ffmpeg.load_pin("linux-x86_64")
        except managed_ffmpeg.FFmpegError:
            return False
        return path == managed_ffmpeg.published_directory(root, pin) and managed_ffmpeg.matches_pin(path, pin)
    if rel == module_registry.receipt_relpath(module_id).as_posix():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            module_registry._validate_receipt_structure(data, module_id)
            return True
        except Exception:
            return False
    return path.exists()


def _recover_s6_asset_materializations(root: Path, current_op: str) -> None:
    """Remove the destination lock and stage of a dead S6 materialization.

    Runs under the install lock, before journal recovery removes the evidence.
    A journal proves an S6 operation that is no longer running; only a lock
    naming that operation, and the stage named after it, belong to it. A lock
    naming anything else may belong to a live or unknown materializer and stays.
    """
    tmp = root / "tmp"
    if not tmp.is_dir():
        return
    dest = module_registry.expected_drumsep_assets_dir(root)
    lock_path = dest.parent / f".{dest.name}.stemwerk-materialize.lock"
    allowed = {a.name for a in asset_acquisition._production_policy().assets}
    allowed.add(asset_materialization.RECEIPT_FILENAME)
    for op_dir in sorted(tmp.iterdir()):
        op = op_dir.name
        if op == current_op:
            continue
        try:
            install_events._check_operation_id(op, "journal_invalid")
            install_journal.parse_journal((op_dir / install_journal.JOURNAL_FILENAME).read_bytes(), op)
        except (install_events.InstallFileError, install_journal.JournalError, OSError):
            continue  # no readable journal: nothing here is proven to be S6's
        try:
            stage = dest.parent / f".{dest.name}.stemwerk-stage-{op}"
            if os.path.lexists(stage):
                if not stat.S_ISDIR(os.lstat(stage).st_mode):
                    raise ValueError("stage is not a directory")
                for entry in stage.iterdir():
                    if entry.name not in allowed or not stat.S_ISREG(os.lstat(entry).st_mode):
                        raise ValueError(f"stage contains unrecognized entry {entry.name!r}")
                shutil.rmtree(stage)
            if os.path.lexists(lock_path):
                if stat.S_ISREG(os.lstat(lock_path).st_mode) and lock_path.read_bytes() == f"{op}\n".encode("ascii"):
                    lock_path.unlink()
        except (OSError, ValueError) as exc:
            raise install_lock.LockError(
                "recovery_incomplete", f"asset materialization recovery refused for {op}: {exc}"
            ) from exc


def _reconcile_interrupted_receipt_under_lock(root: Path, module_id: str) -> bool:
    """If a previous operation crashed after publishing ``<module>.receipt.json``
    and before updating ``module-registry.v1.json``, verify all components in
    the receipt and atomically update ``module-registry.v1.json``.
    """
    status, _, _ = module_registry.read_and_validate_module_record(root, module_id)
    if status == "valid":
        return False
    if not install_preflight._has_recoverable_receipt_journal(root, module_id):
        return False
    rec_file = module_registry.receipt_path(root, module_id)
    try:
        raw_bytes = rec_file.read_bytes()
        rec_sha256 = hashlib.sha256(raw_bytes).hexdigest()
        rec_data = json.loads(raw_bytes.decode("utf-8"))
        validated = module_registry._validate_receipt_structure(rec_data, module_id)
    except Exception:
        return False

    descriptor = module_descriptors.get_module_descriptor(module_id)
    lookup = module_verify.RegistryLookup(root, validated)
    for comp in descriptor.components:
        if comp.component_id not in {"managed_python", "module_venv", "drumsep_assets", "ffmpeg"}:
            continue
        loc = lookup.locate(module_id, comp.component_id)
        if loc is None and comp.component_id == "ffmpeg":
            continue  # a receipt written before the pair was installed
        if loc is None:
            return False
        verifier = module_verify.DEFAULT_VERIFIERS.get(comp.kind)
        if verifier is None:
            return False
        verdict = verifier(comp, loc)
        if verdict.component_class != module_verify.PRESENT_PASSING:
            return False

    module_registry.write_registry_from_receipt(root, module_id, validated, rec_sha256)
    return True


def _acquire_drumsep_sources_into(
    staging_sources_dir: Path,
    *,
    asset_source_dir: Optional[Path] = None,
) -> Mapping[str, Path]:
    """Acquire and verify DrumSep model source files into ``staging_sources_dir``."""
    staging_sources_dir.parent.mkdir(parents=True, exist_ok=True)
    policy = asset_acquisition._production_policy()
    env_cache = (
        os.environ.get(ASSET_SOURCE_CACHE_ENV, "").strip()
        or os.environ.get("STEMWERK_S6_ASSETS_SOURCE_DIR", "").strip()
    )
    cache_dir = (
        Path(asset_source_dir)
        if asset_source_dir is not None
        else (Path(env_cache) if env_cache else None)
    )

    if cache_dir is not None and all((cache_dir / asset.name).is_file() for asset in policy.assets):
        staging_sources_dir.mkdir(parents=True, exist_ok=True)
        result: Dict[str, Path] = {}
        for asset in policy.assets:
            src = cache_dir / asset.name
            dst = staging_sources_dir / asset.name
            shutil.copyfile(src, dst)
            validated = asset_materialization._validate_source(asset.name, dst, asset.sha256)
            if validated.size != asset.size:
                dst.unlink(missing_ok=True)
                raise S6InstallError(
                    "fetch_assets",
                    "asset_size_mismatch",
                    f"cached asset {asset.name} size mismatch: expected {asset.size}, got {validated.size}",
                )
            result[asset.name] = dst
        return result

    try:
        acquired = asset_acquisition.acquire_drumsep_sources(
            asset_acquisition.AcquisitionRequest(staging_sources_dir)
        )
        return {k: Path(v) for k, v in (acquired.get("sources") or {}).items()}
    except asset_acquisition.AcquisitionError as direct_exc:
        # When running behind an HTTPS proxy where raw socket.getaddrinfo is
        # disabled (e.g. sandboxed environments with HTTPS_PROXY), fall back to
        # urllib.request while enforcing the exact same policy allowlist, size
        # bound, and SHA-256 verification.
        if direct_exc.code not in {"network_error", "dns_failed", "source_unavailable"} or not (
            os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")
        ):
            raise S6InstallError(
                "fetch_assets",
                direct_exc.code,
                str(direct_exc),
            ) from direct_exc

    staging_sources_dir.mkdir(parents=True, exist_ok=True)
    result = {}
    for asset in policy.assets:
        src_spec = asset.sources[0]
        allowed_hosts = set(src_spec.redirect_hosts) | {urlparse(src_spec.url).hostname or ""}
        parsed = urlparse(src_spec.url)
        if parsed.scheme != "https" or parsed.hostname not in allowed_hosts:
            raise S6InstallError(
                "fetch_assets",
                "disallowed_host",
                f"asset {asset.name} URL host {parsed.hostname!r} is not in allowlist",
            )
        target = staging_sources_dir / asset.name
        part = staging_sources_dir / f"{asset.name}.part"
        req = urllib.request.Request(
            src_spec.url,
            headers={"User-Agent": "STEMwerk-Core-Installer/2.4"},
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                with part.open("wb") as out:
                    total = 0
                    hasher = hashlib.sha256()
                    while True:
                        chunk = resp.read(256 * 1024)
                        if not chunk:
                            break
                        total += len(chunk)
                        if total > asset.size:
                            raise S6InstallError(
                                "fetch_assets",
                                "asset_size_mismatch",
                                f"download of {asset.name} exceeded pinned size {asset.size}",
                            )
                        hasher.update(chunk)
                        out.write(chunk)
            if total != asset.size:
                part.unlink(missing_ok=True)
                raise S6InstallError(
                    "fetch_assets",
                    "asset_size_mismatch",
                    f"download of {asset.name} had size {total}, expected {asset.size}",
                )
            if hasher.hexdigest() != asset.sha256:
                part.unlink(missing_ok=True)
                raise S6InstallError(
                    "fetch_assets",
                    "asset_integrity_mismatch",
                    f"download of {asset.name} failed SHA-256 verification",
                )
            os.replace(part, target)
            result[asset.name] = target
        except S6InstallError:
            part.unlink(missing_ok=True)
            raise
        except Exception as exc:
            part.unlink(missing_ok=True)
            raise S6InstallError(
                "fetch_assets",
                "asset_download_failed",
                f"failed downloading {asset.name}: {type(exc).__name__}: {exc}",
            ) from exc
    return result


def _acquire_ffmpeg(
    writer: install_events.EventWriter,
    journal: install_journal.Journal,
    root: Path,
    pin: managed_ffmpeg.FFmpegPin,
    *,
    source_dir: Optional[Path],
    opener: Optional[Callable[..., Any]],
    trigger_fault: Callable[[str], None],
) -> Tuple[Optional[Path], managed_ffmpeg.TreeReport, str]:
    """Fetch, verify, extract and probe the pair, or adopt an exact published one.

    Returns ``(stage, report, ownership)``. ``stage`` is ``None`` when a previous
    run already published a tree that matches the pin byte for byte; then nothing
    is downloaded. Any other directory at the destination is a ``runtime_conflict``.
    """
    destination = managed_ffmpeg.published_directory(root, pin)
    writer.append("active_indeterminate", "fetch_ffmpeg", since_seconds=0)
    if os.path.lexists(destination):
        try:
            report = managed_ffmpeg.inspect_tree(destination, pin)
        except managed_ffmpeg.FFmpegError as exc:
            raise S6InstallError("fetch_ffmpeg", "runtime_conflict", f"{destination} cannot be read: {exc.code}") from exc
        if not report.ok:
            raise S6InstallError(
                "fetch_ffmpeg",
                "runtime_conflict",
                f"pre-existing directory {destination} is not the pinned FFmpeg tree: {report.reason}",
            )
        writer.append("done", "fetch_ffmpeg", verified=True)
        writer.append("active_indeterminate", "verify_ffmpeg", since_seconds=0)
        _probe_ffmpeg(destination, pin)
        writer.append("done", "verify_ffmpeg", verified=True)
        return None, report, "unknown"

    writer.append("active_determinate", "fetch_ffmpeg", done=0, total=pin.archive_size, unit="bytes")
    work = journal.create_directory(journal.core_directory / "ffmpeg")
    download = journal.create_directory(work / "download")
    stage = journal.create_directory(work / "stage")
    env_cache = os.environ.get(managed_ffmpeg.ARCHIVE_CACHE_ENV, "").strip()
    cache = source_dir if source_dir is not None else (Path(env_cache) if env_cache else None)
    try:
        report = managed_ffmpeg.stage_pair(pin, download, stage, source_dir=cache, opener=opener)
    except managed_ffmpeg.FFmpegError as exc:
        raise S6InstallError("fetch_ffmpeg", exc.code, exc.message, details=exc.details) from exc
    writer.append("active_determinate", "fetch_ffmpeg", done=pin.archive_size, total=pin.archive_size, unit="bytes")
    writer.append("done", "fetch_ffmpeg", verified=True)
    writer.append("active_indeterminate", "verify_ffmpeg", since_seconds=0)
    _probe_ffmpeg(stage, pin)
    trigger_fault("after_ffmpeg_staging")
    writer.append("done", "verify_ffmpeg", verified=True)
    return stage, report, "core_managed"


def _probe_ffmpeg(directory: Path, pin: managed_ffmpeg.FFmpegPin) -> None:
    """Run the pair before it is published or adopted; a failure blocks registration."""
    try:
        managed_ffmpeg.probe_pair(directory, pin)
    except managed_ffmpeg.FFmpegError as exc:
        raise S6InstallError("verify_ffmpeg", exc.code, exc.message, details=exc.details) from exc


def _publish_ffmpeg(
    journal: install_journal.Journal,
    root: Path,
    pin: managed_ffmpeg.FFmpegPin,
    stage: Optional[Path],
) -> Path:
    destination = managed_ffmpeg.published_directory(root, pin)
    if stage is None:
        return destination
    ensure_directories(root, ("runtimes", "ffmpeg"))
    try:
        journal.rename(stage, destination)
    except asset_materialization.MaterializationError as exc:
        raise S6InstallError("publish", "runtime_conflict", str(exc)) from exc
    return destination


def _confirm_published_ffmpeg(
    destination: Path, pin: managed_ffmpeg.FFmpegPin, staged: managed_ffmpeg.TreeReport
) -> managed_ffmpeg.TreeReport:
    """The published tree must be the tree that was verified, before any receipt names it."""
    try:
        report = managed_ffmpeg.inspect_tree(destination, pin)
    except managed_ffmpeg.FFmpegError as exc:
        raise S6InstallError("publish", "runtime_conflict", f"the published FFmpeg tree is unreadable: {exc.code}") from exc
    if not report.ok or report.tree_sha256 != staged.tree_sha256:
        raise S6InstallError(
            "publish",
            "runtime_conflict",
            f"the published FFmpeg tree differs from the verified one: {report.reason}",
        )
    return report


def _ffmpeg_result_entry(entry: Mapping[str, Any]) -> Dict[str, Any]:
    return {
        key: entry[key]
        for key in ("path", "pin_id", "version", "tree_sha256", "entry_count", "total_bytes", "ownership")
    }


def _cleanup_bootstrap_handover_file(root: Path, operation_id: str) -> None:
    op_tmp = root / "tmp" / operation_id
    handover = op_tmp / "bootstrap-operation.json"
    try:
        if handover.is_file():
            handover.unlink()
        if op_tmp.is_dir() and not any(op_tmp.iterdir()):
            op_tmp.rmdir()
    except OSError:
        pass


def _finalize_failure(
    writer: Optional[install_events.EventWriter],
    op_log_dir: Optional[Path],
    operation_id: str,
    module_id: str,
    phase: str,
    code: str,
    message: str,
    *,
    action: str = "Inspect the installation log and retry or repair the destination.",
    details: Optional[Mapping[str, Any]] = None,
) -> Tuple[int, Dict[str, Any]]:
    doc: Dict[str, Any] = {
        "kind": "stemwerk_module_install_error",
        "schema_version": "1.0.0",
        "operation": "install",
        "operation_id": operation_id,
        "module_id": module_id,
        "phase": phase,
        "error": {
            "code": code,
            "message": message,
            "action": action,
            **(dict(details) if details else {}),
        },
    }
    if writer is not None and op_log_dir is not None:
        try:
            writer.append("failed", phase, error_code=code, detail=message, action=action)
        except Exception:
            pass
        try:
            if not (op_log_dir / install_events.RESULT_FILENAME).exists():
                install_events.write_result(op_log_dir, operation_id, 2, doc)
        except Exception:
            pass
    return 2, doc


def install_module(
    module_id: str,
    plan_fingerprint: str,
    *,
    root: Path | str | None = None,
    operation_id: Optional[str] = None,
    facts: Optional[install_preflight.HostFacts] = None,
    wheel_cache_dir: Optional[Path] = None,
    asset_source_dir: Optional[Path] = None,
    ffmpeg_source_dir: Optional[Path] = None,
    ffmpeg_opener: Optional[Callable[..., Any]] = None,
    fault_hook: Optional[Callable[[str], None]] = None,
) -> Tuple[int, Dict[str, Any]]:
    """Execute the S6 Linux-first Direct Kit CPU installation transaction.

    The pinned FFmpeg pair is part of the transaction (S7). A root that already
    holds the verified S6 components but not the pair gets the pair added; its
    interpreter, environment and assets are not touched.

    Returns ``(exit_code, document)`` where ``exit_code`` is ``0`` on success
    and ``2`` on structured refusal or failure.
    """
    descriptor = module_descriptors.get_module_descriptor(module_id)
    op_id = _resolve_operation_id(operation_id)

    try:
        root_path = absolute_root(
            managed_runtime.managed_runtime_root() if root is None else root
        )
    except InstallPathError as exc:
        return _finalize_failure(
            None, None, op_id, module_id, "preflight", exc.code, str(exc)
        )

    writer: Optional[install_events.EventWriter] = None
    op_log_dir: Optional[Path] = None

    def trigger_fault(point: str) -> None:
        env_point = os.environ.get(FAULT_INJECT_ENV, "").strip()
        if fault_hook is not None:
            fault_hook(point)
        if env_point and env_point == point:
            raise S6InstallError(
                "publish"
                if "receipt" in point or "publish" in point
                else "verify_ffmpeg" if "ffmpeg" in point
                else "install_packages",
                f"fault_injected_{point}",
                f"injected fault at {point}",
            )

    try:
        writer, op_log_dir = _open_or_accept_events(root_path, op_id)
    except install_events.InstallFileError as exc:
        return _finalize_failure(
            None, None, op_id, module_id, "preflight", exc.code, str(exc)
        )

    # 1. Preflight before lock
    writer.append("active_indeterminate", "preflight", since_seconds=0)
    try:
        install_preflight.require_current_plan(
            plan_fingerprint,
            module_id,
            root_path,
            facts,
            scope=install_preflight.SCOPE_S6_CPU,
        )
    except install_preflight.PreflightError as exc:
        _cleanup_bootstrap_handover_file(root_path, op_id)
        return _finalize_failure(
            writer,
            op_log_dir,
            op_id,
            module_id,
            "preflight",
            exc.code,
            f"preflight refused installation before lock: {exc.code}",
            details={"blockers": list(exc.blockers)} if exc.blockers else None,
        )

    # 2. Acquire install lock (which also runs journal recovery and stale bootstrap cleanup)
    writer.append("active_indeterminate", "lock", since_seconds=0)
    try:
        lock = install_lock.acquire(
            root_path,
            op_id,
            verify_published=lambda path: _verify_published_object(root_path, module_id, path),
            before_recovery=lambda: _recover_s6_asset_materializations(root_path, op_id),
        )
    except install_lock.LockError as exc:
        _cleanup_bootstrap_handover_file(root_path, op_id)
        return _finalize_failure(
            writer,
            op_log_dir,
            op_id,
            module_id,
            "lock",
            exc.code,
            str(exc),
        )
    writer.append("done", "lock", verified=True)

    journal: Optional[install_journal.Journal] = None
    try:
        # 2b. Reconcile any interrupted receipt under lock and inspect recovery report
        recovery_report = lock.recovery or install_journal.recover(
            root_path,
            current_operation_id=op_id,
            verify_published=lambda path: _verify_published_object(root_path, module_id, path),
        )
        # An empty journal never reached its first intent, so nothing was changed.
        unresolved = [
            operation
            for operation in recovery_report.operations
            if not operation.complete and operation.error != "journal_empty"
        ]
        if unresolved:
            raise S6InstallError(
                "lock",
                "recovery_incomplete",
                "an interrupted operation could not be recovered",
                details={"recovery": recovery_report.to_json()},
            )
        reconciled = _reconcile_interrupted_receipt_under_lock(root_path, module_id)

        # 2c. Replan under lock against consented fingerprint
        try:
            s6_plan = install_preflight.require_current_plan(
                plan_fingerprint,
                module_id,
                root_path,
                facts,
                scope=install_preflight.SCOPE_S6_CPU,
                ignore_self_lock_operation_id=op_id,
            )
        except install_preflight.PreflightError as exc:
            _cleanup_bootstrap_handover_file(root_path, op_id)
            return _finalize_failure(
                writer,
                op_log_dir,
                op_id,
                module_id,
                "preflight",
                exc.code,
                f"preflight under lock refused installation: {exc.code}",
                details={"blockers": list(exc.blockers)} if exc.blockers else None,
            )
        writer.append("done", "preflight", verified=True)

        # 2d. Verify and snapshot managed Python before S6 work
        py_rec = runtime_manifest.python_record("linux-x86_64")
        mp_dir = runtime_manifest.published_directory(root_path, py_rec)
        mp_before = managed_python.verify_managed_python(root_path, py_rec)
        if mp_before.get("status") != managed_python.VERIFIED:
            raise S6InstallError(
                "create_environment",
                "runtime_conflict" if mp_before.get("status") == managed_python.INVALID else "managed_python_missing",
                f"managed Python at {mp_dir} is not usable ({mp_before.get('status')}: {mp_before.get('reasons')})",
            )
        mp_before_identity = module_registry.compute_tree_identity(mp_dir)
        mp_ownership = _determine_managed_python_ownership(root_path, op_id, module_id)

        venv_dir, venv_pin_id, lock_manifest = module_registry.expected_module_venv_dir(
            root_path, module_id, "linux-x86_64", "cpu"
        )
        bundle_id = module_registry.DRUMSEP_ASSET_SET_ID
        assets_dir = module_registry.expected_drumsep_assets_dir(root_path)

        try:
            ffmpeg_pin = managed_ffmpeg.load_pin("linux-x86_64")
        except managed_ffmpeg.FFmpegError as exc:
            raise S6InstallError("preflight", exc.code, exc.message) from exc

        # 2e. Check if the components are already installed and verified (idempotent no-op)
        pre_verify = module_verify.verify_module(module_id, root=root_path)
        pre_classes = {
            str(c.get("component_id")): c.get("class")
            for c in (pre_verify.get("components") or ())
            if isinstance(c, Mapping)
        }
        s6_installed = (
            pre_classes.get("managed_python") == module_verify.PRESENT_PASSING
            and pre_classes.get("module_venv") == module_verify.PRESENT_PASSING
            and pre_classes.get("drumsep_assets") == module_verify.PRESENT_PASSING
        )
        if s6_installed and pre_classes.get("ffmpeg") == module_verify.PRESENT_PASSING:
            for phase in (
                "create_environment",
                "install_packages",
                "fetch_ffmpeg",
                "verify_ffmpeg",
                "fetch_assets",
                "verify_assets",
                "publish",
                "verify_module",
            ):
                writer.append("active_indeterminate", phase, since_seconds=0)
                writer.append("done", phase, verified=True)

            trigger_fault("before_noop_integrity_check")
            mp_after = managed_python.verify_managed_python(root_path, py_rec)
            mp_after_identity = module_registry.compute_tree_identity(mp_dir)
            if (
                mp_after.get("status") != managed_python.VERIFIED
                or mp_after_identity != mp_before_identity
            ):
                raise S6InstallError(
                    "verify_module",
                    "managed_python_mutated",
                    "managed Python runtime tree changed during no-op verification",
                )

            module_registry.remove_publication_record(root_path, module_id)
            _cleanup_bootstrap_handover_file(root_path, op_id)
            doc = {
                "kind": "stemwerk_module_install_result",
                "schema_version": "1.0.0",
                "operation": "install",
                "operation_id": op_id,
                "module_id": descriptor.module_id,
                "platform_key": "linux-x86_64",
                "backend": "cpu",
                "plan_fingerprint": plan_fingerprint,
                "outcome": "reused_after_recovery" if reconciled else "reused",
                "installation_state": pre_verify["installation_state"],
                "readiness": "not_ready",
                "decided_by_rule": pre_verify["decided_by_rule"],
                "pending_slices": ["s9_activation"],
                "recovery": recovery_report.to_json(),
                "verification": pre_verify,
            }
            install_events.write_result(op_log_dir, op_id, 0, doc)
            return 0, doc

        def finish_transaction(receipt_payload: Dict[str, Any]) -> Tuple[Dict[str, Any], module_registry.TreeIdentity]:
            """Receipt, registry, fresh verification, managed-Python gate, journal cleanup."""
            nonlocal journal
            receipt_bytes = (json.dumps(receipt_payload, indent=2, sort_keys=True) + "\n").encode("utf-8")
            receipt_sha256 = hashlib.sha256(receipt_bytes).hexdigest()
            staged_receipt = journal.create_file(core_dir / f"{module_id}.receipt.json", receipt_bytes)
            target_receipt = module_registry.receipt_path(root_path, module_id)
            journal.rename(staged_receipt, target_receipt, publish=os.replace)

            trigger_fault("between_receipt_and_registry")

            module_registry.write_registry_from_receipt(
                root_path, module_id, receipt_payload, receipt_sha256
            )
            module_registry.remove_publication_record(root_path, module_id)
            writer.append("done", "publish", verified=True)

            # Final verification and managed-Python invariance gate
            writer.append("active_indeterminate", "verify_module", since_seconds=0)
            post_verify = module_verify.verify_module(module_id, root=root_path)
            post_classes = {
                str(c.get("component_id")): c.get("class")
                for c in (post_verify.get("components") or ())
                if isinstance(c, Mapping)
            }
            if (
                post_verify.get("installation_state") != module_verify.PARTIAL
                or post_verify.get("decided_by_rule") != 4
                or post_classes.get("managed_python") != module_verify.PRESENT_PASSING
                or post_classes.get("module_venv") != module_verify.PRESENT_PASSING
                or post_classes.get("drumsep_assets") != module_verify.PRESENT_PASSING
                or post_classes.get("ffmpeg") != module_verify.PRESENT_PASSING
                or post_classes.get("reaper_activation") != module_verify.ABSENT
            ):
                raise S6InstallError(
                    "verify_module",
                    "post_install_verification_failed",
                    f"unexpected post-install verification state: {post_verify.get('installation_state')} ({post_classes})",
                )

            trigger_fault("before_final_integrity_check")
            mp_after = managed_python.verify_managed_python(root_path, py_rec)
            mp_after_identity = module_registry.compute_tree_identity(mp_dir)
            if (
                mp_after.get("status") != managed_python.VERIFIED
                or mp_after_identity != mp_before_identity
            ):
                raise S6InstallError(
                    "verify_module",
                    "managed_python_mutated",
                    "managed Python runtime tree was modified during S6 installation",
                )
            writer.append("done", "verify_module", verified=True)

            # Clean up this operation's journal and staging directory
            journal.close()
            journal = None
            install_journal._recover_operation(
                root_path,
                install_journal.operation_directory(root_path, op_id),
                op_id,
                verify_published=lambda path: _verify_published_object(root_path, module_id, path),
            )
            _cleanup_bootstrap_handover_file(root_path, op_id)
            return post_verify, mp_after_identity

        if s6_installed and pre_classes.get("ffmpeg") == module_verify.ABSENT:
            # S6 is complete and receipted; only the pair is missing. Nothing but the
            # pair, the receipt and the registry entry is written.
            journal = install_journal.open_journal(root_path, op_id)
            core_dir = journal.core_directory
            for phase in ("create_environment", "install_packages"):
                writer.append("active_indeterminate", phase, since_seconds=0)
                writer.append("done", phase, verified=True)
            ffmpeg_stage, ffmpeg_report, ffmpeg_ownership = _acquire_ffmpeg(
                writer, journal, root_path, ffmpeg_pin,
                source_dir=ffmpeg_source_dir, opener=ffmpeg_opener, trigger_fault=trigger_fault,
            )
            for phase in ("fetch_assets", "verify_assets"):
                writer.append("active_indeterminate", phase, since_seconds=0)
                writer.append("done", phase, verified=True)
            writer.append("active_indeterminate", "publish", since_seconds=0)
            ensure_directories(root_path, ("state", "modules"))
            ffmpeg_dir = _publish_ffmpeg(journal, root_path, ffmpeg_pin, ffmpeg_stage)
            trigger_fault("after_ffmpeg_publish")
            published_report = _confirm_published_ffmpeg(ffmpeg_dir, ffmpeg_pin, ffmpeg_report)
            ffmpeg_entry = managed_ffmpeg.receipt_entry(
                root_path, ffmpeg_dir, ffmpeg_pin, published_report, ffmpeg_ownership
            )
            trigger_fault("before_receipt")
            status, current_receipt, reason = module_registry.read_and_validate_module_record(root_path, module_id)
            if status != "valid" or current_receipt is None:
                raise S6InstallError("publish", "registration_changed", f"the registration is {status}: {reason}")
            post_verify, _mp_identity = finish_transaction(
                module_registry.receipt_with_ffmpeg(
                    current_receipt, ffmpeg_entry, operation_id=op_id, plan_fingerprint=plan_fingerprint
                )
            )
            doc = {
                "kind": "stemwerk_module_install_result",
                "schema_version": "1.0.0",
                "operation": "install",
                "operation_id": op_id,
                "module_id": descriptor.module_id,
                "platform_key": "linux-x86_64",
                "backend": "cpu",
                "plan_fingerprint": plan_fingerprint,
                "outcome": "ffmpeg_added",
                "installation_state": post_verify["installation_state"],
                "readiness": "not_ready",
                "decided_by_rule": post_verify["decided_by_rule"],
                "pending_slices": ["s9_activation"],
                "components": {"ffmpeg": _ffmpeg_result_entry(ffmpeg_entry)},
                "recovery": recovery_report.to_json(),
                "verification": post_verify,
            }
            install_events.write_result(op_log_dir, op_id, 0, doc)
            return 0, doc

        # 3. Open transaction journal and create staged environment
        journal = install_journal.open_journal(root_path, op_id)
        core_dir = journal.core_directory

        venv_already_published = False
        installed_packages: Dict[str, str] = {}
        if venv_dir.exists():
            # An interrupted operation may have published venv_dir before its
            # receipt and registry commit. Adopt it only by comparing with the
            # identity sealed before that rename; never from its current bytes.
            try:
                sealed = module_registry.read_publication_record(root_path, module_id, venv_dir)
                if sealed is None:
                    raise S6InstallError(
                        "create_environment",
                        "runtime_conflict",
                        f"{venv_dir} exists without a sealed interrupted publication",
                    )
                probe_loc = module_verify.ComponentLocation(
                    path=venv_dir,
                    receipt_entry={
                        "ownership": "core_managed",
                        "pin_id": venv_pin_id,
                        "wheel_lock_id": lock_manifest.lock_id,
                        "wheel_lock_sha256": lock_manifest.manifest_sha256,
                        "tree_sha256": sealed["tree_sha256"],
                        "entry_count": sealed["entry_count"],
                        "total_bytes": sealed["total_bytes"],
                        "packages": {w.name: w.version for w in lock_manifest.wheels},
                    },
                    runtime_root=root_path,
                )
                venv_comp_desc = next(c for c in descriptor.components if c.component_id == "module_venv")
                verdict = module_verify._verify_module_venv_with_receipt(venv_comp_desc, probe_loc)
                if verdict.component_class == module_verify.PRESENT_PASSING:
                    venv_already_published = True
                else:
                    raise S6InstallError(
                        "create_environment",
                        "runtime_conflict",
                        f"pre-existing runtime directory {venv_dir} failed verification: {verdict.reason_code}",
                    )
            except S6InstallError:
                raise
            except Exception as exc:
                raise S6InstallError(
                    "create_environment",
                    "runtime_conflict",
                    f"pre-existing runtime directory {venv_dir} is invalid: {exc}",
                ) from exc

        venv_stage = core_dir / "venv-stage"
        if venv_already_published:
            writer.append("active_indeterminate", "create_environment", since_seconds=0)
            writer.append("done", "create_environment", verified=True)
            writer.append("active_indeterminate", "install_packages", since_seconds=0)
            installed_packages = {w.name: w.version for w in lock_manifest.wheels}
            installed_packages["stemwerk-core"] = "0.1.1"
            writer.append("done", "install_packages", verified=True)
        else:
            writer.append("active_indeterminate", "create_environment", since_seconds=0)
            journal.create_directory(venv_stage)
            mp_python = managed_python.interpreter_path(mp_dir, "linux-x86_64")
            env = subprocess_policy.clean_pip_env()
            completed = subprocess.run(
                subprocess_policy.isolated_python_cmd(mp_python, "-m", "venv", str(venv_stage)),
                capture_output=True,
                text=True,
                timeout=120,
                env=env,
                check=False,
            )
            if completed.returncode != 0:
                raise S6InstallError(
                    "create_environment",
                    "venv_creation_failed",
                    f"venv creation failed (rc={completed.returncode}): {(completed.stderr or completed.stdout)[-500:]}",
                )
            writer.append("done", "create_environment", verified=True)

            # 4. Stage verified binary wheelhouse and install packages offline
            wheelhouse_dir = journal.create_directory(core_dir / "wheelhouse")
            total_wheels = lock_manifest.wheel_count + 1
            writer.append("active_determinate", "install_packages", done=0, total=total_wheels, unit="wheels")
            verified_count = 0

            def _on_wheel(_rec: wheel_lock.WheelRecord) -> None:
                nonlocal verified_count
                verified_count += 1
                if verified_count in {1, total_wheels} or verified_count % 15 == 0:
                    writer.append(
                        "active_determinate",
                        "install_packages",
                        done=verified_count,
                        total=total_wheels,
                        unit="wheels",
                    )

            try:
                staged_records, req_path = wheel_lock.stage_and_verify_wheelhouse(
                    lock_manifest,
                    wheelhouse_dir,
                    wheel_cache_dir=wheel_cache_dir,
                    on_wheel_verified=_on_wheel,
                )
            except wheel_lock.WheelLockError as exc:
                raise S6InstallError("install_packages", exc.code, exc.message, details=exc.details) from exc

            venv_python = venv_stage / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
            dry_run_cmd = subprocess_policy.isolated_python_cmd(
                venv_python,
                "-m",
                "pip",
                "--isolated",
                "install",
                "--dry-run",
                "--no-index",
                "--find-links",
                str(wheelhouse_dir),
                "--only-binary=:all:",
                "--require-hashes",
                "-r",
                str(req_path),
            )
            dry_proc = subprocess.run(
                dry_run_cmd,
                capture_output=True,
                text=True,
                timeout=180,
                env=env,
                check=False,
            )
            if dry_proc.returncode != 0:
                raise S6InstallError(
                    "install_packages",
                    "pip_dry_run_failed",
                    f"offline binary-only pip --dry-run failed: {(dry_proc.stderr or dry_proc.stdout)[-800:]}",
                )

            install_cmd = subprocess_policy.isolated_python_cmd(
                venv_python,
                "-m",
                "pip",
                "--isolated",
                "install",
                "--no-cache-dir",
                "--no-index",
                "--find-links",
                str(wheelhouse_dir),
                "--only-binary=:all:",
                "--require-hashes",
                "--no-compile",
                "--no-deps",
                "-r",
                str(req_path),
            )
            inst_proc = subprocess.run(
                install_cmd,
                capture_output=True,
                text=True,
                timeout=300,
                env=env,
                check=False,
            )
            if inst_proc.returncode != 0:
                raise S6InstallError(
                    "install_packages",
                    "pip_install_failed",
                    f"offline binary-only pip install failed: {(inst_proc.stderr or inst_proc.stdout)[-800:]}",
                )

            check_proc = subprocess.run(
                subprocess_policy.isolated_python_cmd(venv_python, "-m", "pip", "--isolated", "check"),
                capture_output=True,
                text=True,
                timeout=60,
                env=env,
                check=False,
            )
            if check_proc.returncode != 0:
                raise S6InstallError(
                    "install_packages",
                    "pip_check_failed",
                    f"pip check failed in staged venv: {(check_proc.stderr or check_proc.stdout)[-800:]}",
                )

            # Remove wheelhouse immediately to minimize peak disk usage
            journal.remove(wheelhouse_dir)

            # Strip ensurepip's __pycache__ inside staged venv and normalize modes
            subprocess_policy.strip_pycache_tree(venv_stage)
            _rewrite_staged_venv_paths(venv_stage, venv_dir)
            _normalize_venv_permissions(venv_stage)

            installed_packages = {rec.name: rec.version for rec in staged_records}
            probe_ok, probe_reason, probe_details = module_verify._probe_module_venv_interpreter(
                venv_python, installed_packages
            )
            if not probe_ok:
                raise S6InstallError("install_packages", "staged_venv_probe_failed",
                                     f"{probe_reason}: {probe_details}")
            writer.append("done", "install_packages", verified=True)
            trigger_fault("after_venv_staging")

        # 5. Fetch, verify and probe the pinned FFmpeg pair (before the assets, design 7.2)
        ffmpeg_stage, ffmpeg_report, ffmpeg_ownership = _acquire_ffmpeg(
            writer, journal, root_path, ffmpeg_pin,
            source_dir=ffmpeg_source_dir, opener=ffmpeg_opener, trigger_fault=trigger_fault,
        )

        # 5 & 6. Fetch and verify DrumSep model assets
        asset_comp_desc = next(c for c in descriptor.components if c.component_id == "drumsep_assets")
        existing_asset_verdict = (
            module_verify.verify_asset_component(
                asset_comp_desc, module_verify.ComponentLocation(assets_dir)
            )
            if assets_dir.exists()
            else None
        )
        if (
            existing_asset_verdict is not None
            and existing_asset_verdict.component_class == module_verify.PRESENT_PASSING
        ):
            assets_ownership = "unknown"
            writer.append("active_indeterminate", "fetch_assets", since_seconds=0)
            writer.append("done", "fetch_assets", verified=True)
            writer.append("active_indeterminate", "verify_assets", since_seconds=0)
            writer.append("done", "verify_assets", verified=True)
        elif existing_asset_verdict is not None:
            raise S6InstallError(
                "verify_assets",
                "asset_conflict",
                f"pre-existing asset directory {assets_dir} failed verification: {existing_asset_verdict.reason_code}",
            )
        else:
            assets_ownership = "core_managed"
            assets_work_dir = journal.create_directory(core_dir / "assets")
            sources_dir = assets_work_dir / "sources"
            writer.append(
                "active_determinate",
                "fetch_assets",
                done=0,
                total=install_preflight.ASSET_BYTES,
                unit="bytes",
            )
            sources = _acquire_drumsep_sources_into(
                sources_dir, asset_source_dir=asset_source_dir
            )
            writer.append(
                "active_determinate",
                "fetch_assets",
                done=install_preflight.ASSET_BYTES,
                total=install_preflight.ASSET_BYTES,
                unit="bytes",
            )
            writer.append("done", "fetch_assets", verified=True)

            writer.append("active_indeterminate", "verify_assets", since_seconds=0)
            ensure_directories(root_path, ("assets",))
            try:
                asset_preparation.prepare_drumsep_assets(
                    asset_preparation.PreparationRequest(
                        destination=assets_dir,
                        local_sources=sources,
                        acquire=False,
                        operation_id=op_id,
                    )
                )
            except asset_preparation.PreparationError as exc:
                raise S6InstallError("verify_assets", exc.code, str(exc)) from exc
            except asset_materialization.MaterializationError as exc:
                raise S6InstallError("verify_assets", exc.code, str(exc)) from exc
            journal.remove(assets_work_dir)
            writer.append("done", "verify_assets", verified=True)

        trigger_fault("after_asset_publish")

        # 7. Publish module_venv, write receipt, and atomically update registry
        writer.append("active_indeterminate", "publish", since_seconds=0)
        ensure_directories(root_path, ("runtimes", module_id))
        ensure_directories(root_path, ("state", "modules"))

        if not venv_already_published:
            staged_identity = module_registry.compute_tree_identity(venv_stage)
            if staged_identity.pyc_count != 0:
                raise S6InstallError(
                    "publish",
                    "module_venv_bytecode_pollution",
                    f"staged module_venv contains {staged_identity.pyc_count} bytecode files",
                )
            module_registry.write_publication_record(
                root_path,
                module_id,
                operation_id=op_id,
                module_venv_dir=venv_dir,
                module_venv_pin_id=venv_pin_id,
                identity=staged_identity,
            )
            try:
                journal.rename(venv_stage, venv_dir)
            except asset_materialization.MaterializationError as exc:
                raise S6InstallError("publish", "runtime_conflict", str(exc)) from exc
            trigger_fault("after_venv_publish")

        ffmpeg_dir = _publish_ffmpeg(journal, root_path, ffmpeg_pin, ffmpeg_stage)
        trigger_fault("after_ffmpeg_publish")

        trigger_fault("before_receipt")
        _probe_published_entry_points(venv_dir)
        # The receipt must pin exactly what was sealed before publication.
        if not module_registry.matches_publication_record(root_path, module_id, venv_dir):
            raise S6InstallError(
                "publish",
                "runtime_conflict",
                "the published module environment differs from its sealed identity",
            )
        venv_identity = module_registry.compute_tree_identity(venv_dir)
        ffmpeg_entry = managed_ffmpeg.receipt_entry(
            root_path, ffmpeg_dir, ffmpeg_pin,
            _confirm_published_ffmpeg(ffmpeg_dir, ffmpeg_pin, ffmpeg_report), ffmpeg_ownership,
        )

        policy_assets = {a.name: a for a in asset_acquisition._production_policy().assets}
        drumsep_artifacts = {
            pin.name: {
                "sha256": pin.sha256,
                "size_bytes": pin.size,
                "source_url": policy_assets[pin.name].sources[0].url if pin.name in policy_assets else "",
            }
            for pin in asset_comp_desc.assets
        }

        receipt_payload = module_registry.build_s6_receipt(
            root_path,
            module_id=module_id,
            operation_id=op_id,
            plan_fingerprint=plan_fingerprint,
            platform_key="linux-x86_64",
            backend="cpu",
            managed_python_dir=mp_dir,
            managed_python_pin_id=py_rec.name,
            managed_python_archive_sha256=py_rec.sha256,
            managed_python_identity=mp_before_identity,
            managed_python_s5b_tree_sha256=mp_before_identity.s5b_tree_sha256,
            managed_python_ownership=mp_ownership,
            module_venv_dir=venv_dir,
            module_venv_pin_id=venv_pin_id,
            wheel_lock_id=lock_manifest.lock_id,
            wheel_lock_sha256=lock_manifest.manifest_sha256,
            module_venv_identity=venv_identity,
            installed_packages=installed_packages,
            drumsep_assets_dir=assets_dir,
            drumsep_bundle_id=bundle_id,
            drumsep_artifacts=drumsep_artifacts,
            drumsep_assets_ownership=assets_ownership,
            ffmpeg_entry=ffmpeg_entry,
        )
        post_verify, mp_after_identity = finish_transaction(receipt_payload)

        result_doc: Dict[str, Any] = {
            "kind": "stemwerk_module_install_result",
            "schema_version": "1.0.0",
            "operation": "install",
            "operation_id": op_id,
            "module_id": descriptor.module_id,
            "platform_key": "linux-x86_64",
            "backend": "cpu",
            "plan_fingerprint": plan_fingerprint,
            "outcome": "installed_s6_partial",
            "installation_state": post_verify["installation_state"],
            "readiness": "not_ready",
            "decided_by_rule": post_verify["decided_by_rule"],
            "pending_slices": ["s9_activation"],
            "components": {
                "managed_python": {
                    "path": str(mp_dir),
                    "pin_id": py_rec.name,
                    "s5b_tree_sha256": mp_after_identity.s5b_tree_sha256,
                    "tree_sha256": mp_after_identity.tree_sha256,
                    "entry_count": mp_after_identity.entry_count,
                    "pyc_count": mp_after_identity.pyc_count,
                    "ownership": mp_ownership,
                },
                "module_venv": {
                    "path": str(venv_dir),
                    "pin_id": venv_pin_id,
                    "wheel_lock_id": lock_manifest.lock_id,
                    "wheel_lock_sha256": lock_manifest.manifest_sha256,
                    "tree_sha256": venv_identity.tree_sha256,
                    "entry_count": venv_identity.entry_count,
                    "total_bytes": venv_identity.total_bytes,
                    "pyc_count": venv_identity.pyc_count,
                    "ownership": "core_managed",
                },
                "ffmpeg": _ffmpeg_result_entry(ffmpeg_entry),
                "drumsep_assets": {
                    "path": str(assets_dir),
                    "bundle_id": bundle_id,
                    "ownership": assets_ownership,
                },
            },
            "recovery": recovery_report.to_json(),
            "verification": post_verify,
        }
        install_events.write_result(op_log_dir, op_id, 0, result_doc)
        return 0, result_doc

    except S6InstallError as exc:
        if journal is not None:
            journal.close()
        return _finalize_failure(
            writer,
            op_log_dir,
            op_id,
            module_id,
            exc.phase,
            exc.code,
            exc.message,
            action=exc.action,
            details=exc.details,
        )
    except Exception as exc:
        if journal is not None:
            journal.close()
        return _finalize_failure(
            writer,
            op_log_dir,
            op_id,
            module_id,
            "install_packages",
            "unexpected_install_error",
            f"{type(exc).__name__}: {exc}",
        )
    finally:
        lock.release()
