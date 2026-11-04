"""Read-only S4 installation assessment; no execution permission is granted.

S6 must calibrate space and the Windows package tree against its selected CPU
wheel set. This module never creates paths, probes the network or takes a lock.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass
import hashlib
import hmac
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import sys
from typing import Any, Mapping, Sequence

from . import asset_acquisition, install_lock, managed_runtime, module_descriptors, module_verify
from ._install_paths import InstallPathError, absolute_root, check_existing_directories, lstat_inside


SCHEMA_VERSION = "1.0.0"
GIB = 1024**3
WINDOWS_MAX_PATH = 259  # Characters before the terminating NUL, without long-path opt-in.
ASSET_BYTES = asset_acquisition.CHECKPOINT_SIZE + asset_acquisition.CONFIG_SIZE
LINUX_FFMPEG_PAIR_BYTES = 142_534_568 + 142_305_128
FFMPEG_ARCHIVE_BYTES = {"linux-x86_64": 137_863_452, "win-x86_64": 171_535_354}
FFMPEG_CANDIDATE_PAIR_BYTES = {"linux-x86_64": LINUX_FFMPEG_PAIR_BYTES}

# Only an estimate. The 13 GiB row is a rounded measurement of this host's
# 2.3 ROCm environment (13,745,793,286 bytes), not a Direct Kit CPU pin.
ESTIMATE_ITEMS = {
    "module_environment_bytes": 13 * GIB,
    "wheel_download_cache_bytes": GIB,
    "temporary_build_bytes": GIB,
    "drumsep_assets_bytes": 3 * ASSET_BYTES,
    "safety_margin_bytes": GIB,
}
ESTIMATE_FFMPEG_BYTES = {"linux-x86_64": 137_863_452 + 2 * LINUX_FFMPEG_PAIR_BYTES,
                         "win-x86_64": GIB, "darwin-arm64": GIB}

PLANNED_DIRECTORIES = (
    ("assets",), ("runtimes",), ("runtimes", "python"),
    ("runtimes", "drum_kit"), ("runtimes", "ffmpeg"),
    ("state",), ("state", "modules"), ("state", "locks"),
    ("logs",), ("tmp",), ("models",),
)
PLANNED_FILES = (
    ("state", "module-registry.v1.json"),
    ("state", "modules", "drum_kit.receipt.json"),
    ("state", "locks", "install.lock"),
)
WINDOWS_KNOWN_FILES = PLANNED_FILES + (
    ("logs", "00000000-0000-0000-0000-000000000000", "events.ndjson"),
    ("tmp", "00000000-0000-0000-0000-000000000000", "journal.json"),
)
LEGACY_MARKERS = (
    ("state", "ready_to_go.env"), ("state", "bootstrap.env"),
    ("state", "capabilities.env"), (".venv-drumsep",),
    (".venv-drumsep-rocm",), (".venv-drumsep-cuda",),
    (".venv-drumsep-directml",), (".venv",), ("python",),
)


class PreflightError(Exception):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


@dataclass(frozen=True)
class HostFacts:
    platform_id: str | None
    os_version: str
    glibc_version: str | None
    free_bytes: int | None
    vcpp_runtime_present: bool | None
    vcpp_evidence: str = "injected"


def _version(value: str | None) -> tuple[int, ...] | None:
    if not value:
        return None
    match = re.match(r"\A([0-9]+(?:\.[0-9]+)*)(?=$|[-+_])", value)
    if match is None:
        return None
    return tuple(int(part) for part in match.group(1).split("."))


def _nearest_existing(path: Path) -> Path:
    while not path.exists():
        if path == path.parent:
            raise PreflightError("path_unavailable")
        path = path.parent
    return path


def observe_host(root: Path) -> HostFacts:
    """Collect host facts without changing the filesystem or environment."""

    from .module_install import current_platform

    platform_id = current_platform()
    try:
        volume = _nearest_existing(root)
        free_bytes = shutil.disk_usage(volume).free
    except OSError as exc:
        raise PreflightError("path_unavailable") from exc
    vcpp: bool | None = None
    vcpp_evidence = "not_applicable"
    if platform_id == "win-x86_64":
        vcpp, vcpp_evidence = _windows_vcpp_registry()
        # sys.getwindowsversion gives the actual build even when version
        # manifests alter win32_ver's reported release name.
        win = sys.getwindowsversion()
        version = f"{win.major}.{win.minor}.{win.build}"
    elif platform_id == "darwin-arm64":
        version = platform.mac_ver()[0]
    else:
        version = platform.release().split("-", 1)[0]
    return HostFacts(platform_id, version, platform.libc_ver()[1] or None,
                     free_bytes, vcpp, vcpp_evidence)


def _windows_vcpp_registry() -> tuple[bool | None, str]:
    """Registry presence is evidence, not proof that Torch/ONNX DLLs load."""

    try:
        import winreg
    except ImportError:
        return None, "registry_unavailable"
    key = r"SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\X64"
    missing = 0
    for view in (getattr(winreg, "KEY_WOW64_64KEY", 0), getattr(winreg, "KEY_WOW64_32KEY", 0)):
        try:
            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key,
                                0, winreg.KEY_READ | view) as handle:
                try:
                    installed, _ = winreg.QueryValueEx(handle, "Installed")
                except FileNotFoundError:
                    return None, "registry_inconclusive"
        except FileNotFoundError:
            missing += 1
            continue
        except OSError:
            return None, "registry_query_failed"
        if installed == 1:
            return None, "registry_installed_unverified"
    if missing == 2:
        return None, "registry_missing_unverified"
    return None, "registry_inconclusive"


def _path_findings(root: Path, facts: HostFacts) -> tuple[list[str], list[str]]:
    blockers: list[str] = []
    incomplete: list[str] = []
    try:
        if root.is_symlink() and not root.exists():
            return ["path_ineligible"], []
        # Existing segments below root may never be links or reparse points.
        for parts in PLANNED_DIRECTORIES:
            existing = check_existing_directories(root, parts)
            if existing is not None:
                if facts.platform_id == "win-x86_64":
                    incomplete.append("path_writability_unknown")
                elif not os.access(existing, os.W_OK | os.X_OK):
                    blockers.append("path_unwritable")
        for parts in PLANNED_FILES:
            path_stat = lstat_inside(root.joinpath(*parts))
            if path_stat is not None and not stat.S_ISREG(path_stat.st_mode):
                blockers.append("path_ineligible")
        existing = _nearest_existing(root)
        if not existing.is_dir():
            blockers.append("path_ineligible")
        elif facts.platform_id == "win-x86_64":
            incomplete.append("path_writability_unknown")
        elif not os.access(existing, os.W_OK | os.X_OK):
            blockers.append("path_unwritable")
    except InstallPathError as exc:
        (incomplete if exc.code == "path_unavailable" else blockers).append(exc.code)
    except (OSError, ValueError):
        incomplete.append("path_inspection_unknown")
    return sorted(set(blockers)), sorted(set(incomplete))


def _platform_findings(facts: HostFacts) -> tuple[list[str], list[str]]:
    blockers: list[str] = []
    incomplete: list[str] = []
    if facts.platform_id == "linux-x86_64":
        kernel = _version(facts.os_version)
        glibc = _version(facts.glibc_version)
        if kernel is None:
            incomplete.append("os_version_unknown")
        elif kernel < (4, 18):
            blockers.append("os_too_old")
        if glibc is None:
            incomplete.append("glibc_version_unknown")
        elif glibc < (2, 28):
            blockers.append("glibc_too_old")
    elif facts.platform_id == "darwin-arm64":
        macos = _version(facts.os_version)
        if macos is None or macos == (10, 16):
            incomplete.append("os_version_unknown")
        elif macos < (14, 0):
            blockers.append("os_too_old")
    elif facts.platform_id == "win-x86_64":
        windows = _version(facts.os_version)
        if windows is None or len(windows) != 3:
            incomplete.append("os_version_unknown")
        elif windows[2] < 19045:
            blockers.append("os_too_old")
        if facts.vcpp_runtime_present is False:
            blockers.append("vcpp_runtime_missing")
        elif facts.vcpp_runtime_present is not True:
            incomplete.append("vcpp_runtime_unknown")
    else:
        blockers.append("unsupported_platform")
    return blockers, incomplete


def fingerprint(actions: dict[str, Any]) -> str:
    """Bind consent to stable inputs, never to volatile free-space readings."""

    try:
        encoded = json.dumps(actions, sort_keys=True, separators=(",", ":"),
                             ensure_ascii=False, allow_nan=False).encode("utf-8")
    except UnicodeEncodeError as exc:
        raise PreflightError("path_encoding_unsupported") from exc
    return hashlib.sha256(encoded).hexdigest()


def _space_assessment(facts: HostFacts) -> tuple[dict[str, Any], list[str], list[str], list[str]]:
    estimate_items = dict(ESTIMATE_ITEMS)
    estimate_items["ffmpeg_static_pair_bytes"] = ESTIMATE_FFMPEG_BYTES.get(facts.platform_id, GIB)
    candidate_ffmpeg = FFMPEG_CANDIDATE_PAIR_BYTES.get(facts.platform_id)
    archive = FFMPEG_ARCHIVE_BYTES.get(facts.platform_id)
    # The Linux FFmpeg pair is a candidate, not a selected release pin.
    # Only the pinned assets establish a current hard lower bound.
    known_minimum = ASSET_BYTES
    estimate = sum(estimate_items.values())
    blockers: list[str] = []
    warnings: list[str] = []
    incomplete = ["actual_pinned_install_space"]
    incomplete.append("ffmpeg_final_size_unknown")
    if facts.free_bytes is None:
        incomplete.append("free_space_unknown")
    elif facts.free_bytes < known_minimum:
        blockers.append("insufficient_known_space")
    elif facts.free_bytes < estimate:
        warnings.append("below_provisional_estimate")
    return {
        "filesystem": "root_volume", "available_bytes": facts.free_bytes,
        "known_minimum_bytes": known_minimum, "estimate_bytes": estimate,
        "estimate_status": "provisional",
        "estimate_items": estimate_items,
        "estimate_provenance": {
            "module_environment_bytes": "2.3 Linux ROCm environment measured 13,745,793,286 bytes; not a CPU requirement",
            "wheel_download_cache_bytes": "unmeasured 1 GiB wheel-only cache allowance; excludes assets and FFmpeg",
            "temporary_build_bytes": "unmeasured 1 GiB extra build allowance; excludes final venv and assets",
            "drumsep_assets_bytes": "three distinct copies of pinned asset bytes (download, stage, final) assumed to coexist; actual peak unmeasured",
            "ffmpeg_static_pair_bytes": "Linux candidate archive and pair measurements; other platforms unmeasured 1 GiB allowance",
            "safety_margin_bytes": "unmeasured 1 GiB allowance",
        },
        "storage": {
            "download": {"filesystem": "root_volume_planned", "assets_bytes": ASSET_BYTES,
                         "ffmpeg_archive_bytes": archive, "coexistence": "assumed with staged and final assets in estimate; actual peak unknown"},
            "temporary": {"filesystem": "root_volume_planned", "assets_bytes": ASSET_BYTES,
                          "ffmpeg_pair_bytes": None,
                          "candidate_ffmpeg_pair_bytes": candidate_ffmpeg, "venv_bytes": None,
                          "coexistence": "unknown"},
            "final": {"filesystem": "root_volume", "assets_bytes": ASSET_BYTES,
                      "ffmpeg_bytes": None, "candidate_ffmpeg_bytes": candidate_ffmpeg,
                      "venv_bytes": None,
                      "coexistence": "asset and FFmpeg final files coexist"},
        },
        "known_minimum_scope": "pinned final asset bytes only; FFmpeg release pin and peak remain unknown",
        "unknown_quantities": ["pinned_cpu_venv", "peak_temporary_overlap",
                               "complete_download_cache", "release_ffmpeg_pair"],
    }, blockers, warnings, incomplete


def _windows_path_assessment(root: Path) -> tuple[dict[str, Any], list[str]]:
    paths = [{"path": str(root.joinpath(*parts)),
              "length": len(str(root.joinpath(*parts)).encode("utf-16-le")) // 2}
             for parts in WINDOWS_KNOWN_FILES]
    too_long = [entry for entry in paths if entry["length"] > WINDOWS_MAX_PATH]
    return {
        "status": "incomplete", "maximum_length": WINDOWS_MAX_PATH,
        "known_paths": paths, "full_tree_max_length": None,
        "package_set": "unselected_cpu_wheels",
    }, ["known_path_too_long"] if too_long else []


def _installation_assessment(module_id: str, root: Path,
                             verification: Mapping[str, Any] | None
                             ) -> tuple[dict[str, Any], dict[str, Any], list[str], list[str], list[str]]:
    blockers: list[str] = []
    warnings: list[str] = []
    incomplete: list[str] = []
    try:
        report = (module_verify.verify_module(module_id, root=root)
                  if verification is None else verification)
        lookup = report["lookup"]
        state = report["installation_state"]
        lock_status = report["lock_status"]
        operation_id = report.get("operation_id")
    except Exception:
        return ({"status": "unknown", "lookup": None, "reported_state": None},
                {"status": "unknown", "operation_id": None}, [], [],
                ["existing_installation_unknown", "lock_state_unknown"])
    if lookup == "no_registry" or state == "unknown":
        incomplete.append("existing_installation_unknown")
        status = "unknown"
    else:
        status = state
        if state != "not_installed":
            warnings.append("existing_installation_detected")
            incomplete.append("existing_installation_action_pending")
    if lock_status == install_lock.HELD or report.get("operation_in_progress") is True:
        blockers.append("lock_held")
    elif lock_status == install_lock.STALE:
        warnings.append("stale_lock")
    elif lock_status != install_lock.FREE:
        incomplete.append("lock_state_unknown")
    return ({"status": status, "lookup": lookup, "reported_state": state},
            {"status": lock_status, "operation_id": operation_id},
            blockers, warnings, incomplete)


def _legacy_assessment(roots: Sequence[Path]) -> tuple[dict[str, Any], list[str], list[str]]:
    candidates = []
    incomplete = ["duplicate_payload_scope_unknown"]
    seen = set()
    for root in roots:
        root = Path(root)
        key = os.path.normcase(os.path.normpath(str(root)))
        if key in seen:
            continue
        seen.add(key)
        markers = []
        for parts in LEGACY_MARKERS:
            path = root.joinpath(*parts)
            try:
                parent = check_existing_directories(root, parts[:-1])
                path_stat = lstat_inside(path) if parent is not None else None
            except InstallPathError:
                incomplete.append("legacy_payload_inspection_unknown")
                continue
            if path_stat is None:
                continue
            if not (stat.S_ISREG(path_stat.st_mode) or stat.S_ISDIR(path_stat.st_mode)):
                incomplete.append("legacy_payload_inspection_unknown")
            else:
                markers.append(str(path))
        if markers:
            candidates.append({"root": str(root), "markers": markers,
                               "version": None, "ownership": "unknown"})
    candidates.sort(key=lambda entry: entry["root"])
    warnings = []
    if candidates:
        warnings.append("legacy_payload_detected")
    if len(candidates) > 1:
        warnings.append("duplicate_legacy_payload")
    return ({"candidates": candidates,
             "duplicate_status": "observed" if len(candidates) > 1 else "not_observed_in_scanned_roots",
             "classification": "legacy_layout_candidate; version unverified"},
            warnings, incomplete)


def plan(module_id: str, root: Path | str | None = None,
         facts: HostFacts | None = None, *,
         verification: Mapping[str, Any] | None = None,
         legacy_roots: Sequence[Path] | None = None) -> dict[str, Any]:
    descriptor = module_descriptors.get_module_descriptor(module_id)
    try:
        root = absolute_root(managed_runtime.managed_runtime_root() if root is None else root)
    except InstallPathError as exc:
        raise PreflightError(exc.code) from exc
    actual_facts = observe_host(root) if facts is None else facts
    platform_blockers, platform_incomplete = _platform_findings(actual_facts)
    path_blockers, path_incomplete = _path_findings(root, actual_facts)
    space, space_blockers, space_warnings, space_incomplete = _space_assessment(actual_facts)
    if actual_facts.platform_id == "win-x86_64":
        try:
            path_budget, length_blockers = _windows_path_assessment(root)
        except UnicodeEncodeError as exc:
            raise PreflightError("path_encoding_unsupported") from exc
        path_incomplete += ["windows_full_path_unmeasured"]
    else:
        path_budget, length_blockers = None, []
    if path_blockers:
        installation = {"status": "unknown", "lookup": None, "reported_state": None}
        lock = {"status": "unknown", "operation_id": None}
        inspect_blockers, inspect_warnings = [], []
        inspect_incomplete = ["existing_installation_unknown", "lock_state_unknown"]
    else:
        installation, lock, inspect_blockers, inspect_warnings, inspect_incomplete = (
            _installation_assessment(module_id, root, verification))
    roots = legacy_roots
    if roots is None:
        roots = ((root,) if facts is not None or os.environ.get("STEMWERK_RUNTIME_ROOT")
                 else (root, *managed_runtime.runtime_base_candidates()))
    if path_blockers:
        legacy = {"candidates": [], "duplicate_status": "unknown",
                  "classification": "inspection skipped for ineligible root"}
        legacy_warnings, legacy_incomplete = [], ["legacy_payload_inspection_unknown"]
    else:
        legacy, legacy_warnings, legacy_incomplete = _legacy_assessment(roots)
    blockers = sorted(set(platform_blockers + path_blockers + space_blockers +
                          length_blockers + inspect_blockers))
    warnings = sorted(set(space_warnings + inspect_warnings + legacy_warnings))
    incomplete = sorted(set(platform_incomplete + path_incomplete + space_incomplete +
                            inspect_incomplete + legacy_incomplete +
                            ["manifest_network_hosts", "bootstrap_operation_state_unknown"]))
    outcome = "blocked" if blockers else "incomplete" if incomplete else "no_blocker_found"
    items = space["estimate_items"]
    actions = {
        "operation": "plan", "plan_schema": SCHEMA_VERSION,
        "descriptor_version": module_descriptors.DESCRIPTOR_VERSION,
        "module": descriptor.module_id, "platform": actual_facts.platform_id,
        "workflow": descriptor.workflow_id, "engine": descriptor.engine_id,
        "root": str(root), "components": [asdict(c) for c in descriptor.components],
        "existing_installation": {"status": installation["status"], "lookup": installation["lookup"]},
        "legacy_candidate_roots": [entry["root"] for entry in legacy["candidates"]],
        "estimate_items": items,
        "steps": [
            {"phase": "create_environment", "estimate_bytes": items["temporary_build_bytes"]},
            {"phase": "install_packages", "estimate_bytes": items["module_environment_bytes"]},
            {"phase": "fetch_ffmpeg", "estimate_bytes": items["ffmpeg_static_pair_bytes"]},
            {"phase": "verify_ffmpeg", "estimate_bytes": None},
            {"phase": "fetch_assets", "estimate_bytes": items["drumsep_assets_bytes"]},
            {"phase": "verify_assets", "estimate_bytes": None},
            {"phase": "publish", "estimate_bytes": None},
            {"phase": "activate", "estimate_bytes": None},
            {"phase": "verify_module", "estimate_bytes": None},
        ],
    }
    return {
        "kind": "stemwerk_module_install_plan", "schema_version": SCHEMA_VERSION,
        "scope": "s4_assessment", "preflight_result": outcome,
        "blockers": blockers, "warnings": warnings, "incomplete": incomplete,
        "fingerprint": fingerprint(actions), "actions": actions,
        "space": space, "path_budget": path_budget,
        "installation": installation, "lock": lock, "legacy_payloads": legacy,
        "platform_check": {"observed_os": actual_facts.os_version,
                           "observed_glibc": actual_facts.glibc_version,
                           "vcpp_runtime_present": actual_facts.vcpp_runtime_present,
                           "vcpp_evidence": actual_facts.vcpp_evidence,
                           "required": {"linux-x86_64": {"kernel": "4.18", "glibc": "2.28"},
                                        "darwin-arm64": {"macos": "14.0"},
                                        "win-x86_64": {"windows_build": "19045", "vcpp_runtime": True}}.get(actual_facts.platform_id)},
    }


def require_current_plan(consented_fingerprint: str, module_id: str,
                         root: Path | str | None = None,
                         facts: HostFacts | None = None) -> dict[str, Any]:
    """Replan immediately before S6 execution and refuse changed consent."""

    current_plan = plan(module_id, root, facts)
    current_fingerprint = current_plan["fingerprint"]
    valid_consent = (
        isinstance(consented_fingerprint, str)
        and re.fullmatch(r"[0-9a-f]{64}", consented_fingerprint)
        and hmac.compare_digest(current_fingerprint, consented_fingerprint)
    )
    if not valid_consent:
        raise PreflightError("plan_changed")
    if current_plan["preflight_result"] != "no_blocker_found":
        raise PreflightError("preflight_blocked" if current_plan["blockers"] else "preflight_incomplete")
    return current_plan
