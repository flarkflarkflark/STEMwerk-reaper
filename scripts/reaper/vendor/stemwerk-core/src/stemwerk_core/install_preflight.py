"""Read-only S4 installation assessment and S6 Linux CPU preflight/consent gate.

This module never creates paths, probes the network or takes a lock.
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
from typing import Any, Mapping, Optional, Sequence
from urllib.parse import urlparse

from . import (
    asset_acquisition,
    install_events,
    install_journal,
    install_lock,
    managed_ffmpeg,
    managed_python,
    managed_runtime,
    model_assets,
    module_descriptors,
    module_registry,
    module_verify,
    runtime_manifest,
    wheel_lock,
)
from ._install_paths import InstallPathError, absolute_root, check_existing_directories, lstat_inside


SCHEMA_VERSION = "1.0.0"
SCOPE_S4 = "s4_assessment"
SCOPE_S4_ASSESSMENT = SCOPE_S4
SCOPE_S6_CPU = "s6_cpu"
GIB = 1024**3
MIB = 1024**2
WINDOWS_MAX_PATH = 259  # Characters before the terminating NUL, without long-path opt-in.
ASSET_BYTES = asset_acquisition.CHECKPOINT_SIZE + asset_acquisition.CONFIG_SIZE
# Linux: the pinned BtbN pair (ffmpeg-pin.v1.json, checked against it by a test).
# Windows is still the F3 candidate's API size; macOS has no figure. Both stay
# unmeasured until their platform steps.
LINUX_FFMPEG_PAIR_BYTES = 140_488_520 + 140_259_080
LINUX_FFMPEG_INSTALLED_LOGICAL_BYTES = LINUX_FFMPEG_PAIR_BYTES + 7_651 + 3_202  # + LICENSE.txt + NOTICE.txt
# Allocated on ext4 (`du --block-size=1` of <root>/runtimes/ffmpeg, parent directory included),
# measured in the S7 end-to-end run; the 4 KiB-block calculation gave 280,768,512.
LINUX_FFMPEG_INSTALLED_ALLOCATED_BYTES = 280_780_800
FFMPEG_ARCHIVE_BYTES = {"linux-x86_64": 136_027_168, "win-x86_64": 171_535_354}
FFMPEG_CANDIDATE_PAIR_BYTES = {"linux-x86_64": LINUX_FFMPEG_PAIR_BYTES}
FFMPEG_INSTALLED_BYTES = {"linux-x86_64": LINUX_FFMPEG_INSTALLED_LOGICAL_BYTES}

# One sampled fresh install from verified local caches, so without downloads.
# Logical bytes, allocated blocks and physical pages are different quantities:
# - logical and allocated: `du` of the root on ext4, median sample gap 25 ms;
# - physical: statvfs of a dedicated tmpfs holding only the root, gap 2 ms. It
#   is a real high-water mark, for tmpfs. No physical ext4 peak was measured.
# The budget is the ext4 allocated peak plus headroom for other file systems,
# path length, metadata, Core wheel growth and a TMPDIR on the same volume.
OBSERVED_S6_LINUX_CPU_STORAGE = {
    "python_archive_bytes": 34_505_639,
    "python_installed_bytes": 98_482_767,
    "wheelhouse_external_bytes": 396_290_399,
    "wheelhouse_core_wheel_bytes": 210_216,
    "module_venv_installed_bytes": 1_294_288_407,
    "module_venv_staging_peak_bytes": 1_299_096_298,
    "drumsep_assets_bytes": ASSET_BYTES,
    "s6_sampled_logical_peak_root_bytes": 2_268_102_042,
    "s6_sampled_allocated_peak_root_bytes": 2_385_100_800,
    "s6_measured_tmpfs_physical_peak_root_bytes": 2_361_139_200,
    "s6_measured_tmpfs_physical_peak_tmpdir_bytes": 2_064_384,
    "s6_retained_logical_root_bytes": 1_830_456_846,
    "s6_retained_allocated_root_bytes": 1_947_435_008,
    "s6_root_budget_headroom_bytes": 256 * MIB,
    # S7: the pair is published before the assets, so its allocated bytes add to the
    # asset-phase peak; the archive (136 MB) is gone by then. One fresh install with the
    # pair, from verified wheel and asset caches and the real vendor URL for FFmpeg, on
    # ext4 (du every 3.5 ms, 1,798 samples): the peak is the S6 peak plus the pair (plus
    # 68 KiB of path-length and metadata difference) and occurs in the asset phase.
    # Logical and allocated bytes; no physical (tmpfs) high-water mark was re-measured.
    "s7_sampled_logical_peak_root_bytes": 2_548_934_631,
    "s7_sampled_allocated_peak_root_bytes": 2_665_951_232,
    "s7_retained_logical_root_bytes": 2_111_290_923,
    "s7_retained_allocated_root_bytes": 2_228_350_976,
    "s7_ffmpeg_archive_bytes": 136_027_168,
    "s7_ffmpeg_pair_bytes": LINUX_FFMPEG_PAIR_BYTES,
    "s7_ffmpeg_installed_logical_bytes": LINUX_FFMPEG_INSTALLED_LOGICAL_BYTES,
    "s7_ffmpeg_installed_allocated_bytes": LINUX_FFMPEG_INSTALLED_ALLOCATED_BYTES,
    "s7_ffmpeg_phase_peak_allocated_bytes": 136_027_168 + LINUX_FFMPEG_INSTALLED_ALLOCATED_BYTES,
    "s6_enforced_root_budget_bytes": 2_665_951_232 + 256 * MIB,
    "posix_venv_max_relpath_length": 163,
    "windows_venv_max_relpath_length": 152,
}

# Calibrated from observed S6 Linux x86_64 CPU measurements (replacing the S4
# provisional 13 GiB ROCm figures). The Linux FFmpeg pair is the S7 pin.
ESTIMATE_ITEMS = {
    "module_environment_bytes": OBSERVED_S6_LINUX_CPU_STORAGE["module_venv_installed_bytes"],
    "wheel_download_cache_bytes": (
        OBSERVED_S6_LINUX_CPU_STORAGE["wheelhouse_external_bytes"]
        + OBSERVED_S6_LINUX_CPU_STORAGE["wheelhouse_core_wheel_bytes"]
    ),
    "temporary_build_bytes": (
        OBSERVED_S6_LINUX_CPU_STORAGE["python_archive_bytes"]
        + OBSERVED_S6_LINUX_CPU_STORAGE["python_installed_bytes"]
        + (
            OBSERVED_S6_LINUX_CPU_STORAGE["module_venv_staging_peak_bytes"]
            - OBSERVED_S6_LINUX_CPU_STORAGE["module_venv_installed_bytes"]
        )
    ),
    "drumsep_assets_bytes": 2 * ASSET_BYTES,
    "safety_margin_bytes": 256 * MIB,
}
ESTIMATE_FFMPEG_BYTES = {
    # streaming extraction: the archive and one staged copy of the kept files
    "linux-x86_64": 136_027_168 + LINUX_FFMPEG_INSTALLED_ALLOCATED_BYTES,
    "win-x86_64": GIB,
    "darwin-arm64": GIB,
}

PLANNED_DIRECTORIES = (
    ("assets",),
    ("runtimes",),
    ("runtimes", "python"),
    ("runtimes", "drum_kit"),
    ("runtimes", "ffmpeg"),
    ("state",),
    ("state", "modules"),
    ("state", "locks"),
    ("logs",),
    ("tmp",),
    ("models",),
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
    ("state", "ready_to_go.env"),
    ("state", "bootstrap.env"),
    ("state", "capabilities.env"),
    (".venv-drumsep",),
    (".venv-drumsep-rocm",),
    (".venv-drumsep-cuda",),
    (".venv-drumsep-directml",),
    (".venv",),
    ("python",),
)


class PreflightError(Exception):
    def __init__(
        self,
        code: str,
        *,
        plan_document: Optional[Mapping[str, Any]] = None,
        blockers: Sequence[str] = (),
    ) -> None:
        super().__init__(code)
        self.code = code
        self.plan_document = dict(plan_document) if plan_document is not None else None
        self.blockers = tuple(blockers)


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


def fingerprint(actions: Mapping[str, Any]) -> str:
    try:
        encoded = json.dumps(
            actions,
            sort_keys=True,
            separators=(",", ":"),
            ensure_ascii=False,
            allow_nan=False,
        ).encode("utf-8")
    except UnicodeEncodeError as exc:
        raise PreflightError("path_encoding_unsupported") from exc
    return hashlib.sha256(encoded).hexdigest()


def _space_assessment(facts: HostFacts) -> tuple[dict[str, Any], list[str], list[str], list[str]]:
    estimate_items = dict(ESTIMATE_ITEMS)
    estimate_items["ffmpeg_static_pair_bytes"] = ESTIMATE_FFMPEG_BYTES.get(facts.platform_id, GIB)
    candidate_ffmpeg = FFMPEG_CANDIDATE_PAIR_BYTES.get(facts.platform_id)
    installed_ffmpeg = FFMPEG_INSTALLED_BYTES.get(facts.platform_id)
    archive = FFMPEG_ARCHIVE_BYTES.get(facts.platform_id)
    # FFmpeg is pinned on Linux only; Windows and macOS stay candidates. S4 keeps
    # ASSET_BYTES as the cross-platform known minimum while reporting the
    # calibrated S6 Linux CPU measurements in storage.
    known_minimum = ASSET_BYTES
    estimate = sum(estimate_items.values())
    blockers: list[str] = []
    warnings: list[str] = []
    incomplete = ["actual_pinned_install_space"]
    if installed_ffmpeg is None:
        incomplete.append("ffmpeg_final_size_unknown")
    if facts.free_bytes is None:
        incomplete.append("free_space_unknown")
    elif facts.free_bytes < known_minimum:
        blockers.append("insufficient_known_space")
    elif facts.free_bytes < estimate:
        warnings.append("below_provisional_estimate")
    return (
        {
            "filesystem": "root_volume",
            "available_bytes": facts.free_bytes,
            "known_minimum_bytes": known_minimum,
            "estimate_bytes": estimate,
            "estimate_status": (
                "calibrated_s6_cpu_s7_ffmpeg_linux"
                if installed_ffmpeg is not None
                else "calibrated_s6_cpu_ffmpeg_unmeasured"
            ),
            "estimate_items": estimate_items,
            "observed_s6_linux_cpu": dict(OBSERVED_S6_LINUX_CPU_STORAGE),
            "estimate_provenance": {
                "module_environment_bytes": (
                    "Sampled S6 Linux CPU module_venv: 1,294,288,407 logical bytes "
                    "(36,283 entries, 0 .pyc; staged peak 1,299,096,298 logical bytes)"
                ),
                "wheel_download_cache_bytes": (
                    "61 locked Linux cp312 CPU wheels (396,290,399 bytes), including the vendored diffq wheel "
                    "+ sampled synthesized stemwerk_core wheel (210,216 bytes)"
                ),
                "temporary_build_bytes": (
                    "Pinned CPython 3.12.16 archive (34,505,639 bytes) + extracted runtime "
                    "(98,482,767 bytes) + staged ensurepip bytecode delta (5,008,378 bytes)"
                ),
                "drumsep_assets_bytes": (
                    "Two copies of pinned DrumSep assets (437,655,116 bytes each) coexist "
                    "during atomic staging-to-publication materialization"
                ),
                "ffmpeg_static_pair_bytes": (
                    "Linux: pinned archive (136,027,168 bytes) + one staged copy of the kept files "
                    "(280,780,800 allocated bytes); other platforms unmeasured 1 GiB allowance"
                ),
                "safety_margin_bytes": "256 MiB bounded filesystem headroom",
            },
            "storage": {
                "download": {
                    "filesystem": "root_volume_planned",
                    "assets_bytes": ASSET_BYTES,
                    "wheelhouse_bytes": ESTIMATE_ITEMS["wheel_download_cache_bytes"],
                    "ffmpeg_archive_bytes": archive,
                    "coexistence": "wheelhouse and asset staging are cleaned after S6 publication",
                },
                "temporary": {
                    "filesystem": "root_volume_planned",
                    "assets_bytes": ASSET_BYTES,
                    "ffmpeg_pair_bytes": installed_ffmpeg,
                    "candidate_ffmpeg_pair_bytes": candidate_ffmpeg,
                    "venv_bytes": OBSERVED_S6_LINUX_CPU_STORAGE["module_venv_staging_peak_bytes"],
                    "coexistence": "sampled root peak: 2,268,102,042 logical and 2,385,100,800 allocated bytes on ext4; 2,361,139,200 physical on tmpfs",
                },
                "final": {
                    "filesystem": "root_volume",
                    "assets_bytes": ASSET_BYTES,
                    "ffmpeg_bytes": installed_ffmpeg,
                    "candidate_ffmpeg_bytes": candidate_ffmpeg,
                    "venv_bytes": OBSERVED_S6_LINUX_CPU_STORAGE["module_venv_installed_bytes"],
                    "managed_python_bytes": OBSERVED_S6_LINUX_CPU_STORAGE["python_installed_bytes"],
                    "coexistence": "sampled retained root: 1,830,456,846 logical and 1,947,435,008 allocated bytes on ext4, plus the Linux FFmpeg pair (280,758,453 logical, 280,780,800 allocated bytes)",
                },
            },
            "known_minimum_scope": "pinned final asset bytes in S4 full-route view; see s6_cpu for S6 minimum",
            "unknown_quantities": [] if installed_ffmpeg is not None else ["release_ffmpeg_pair"],
        },
        blockers,
        warnings,
        incomplete,
    )


def _windows_path_assessment(root: Path) -> tuple[dict[str, Any], list[str]]:
    paths = [
        {
            "path": str(root.joinpath(*parts)),
            "length": len(str(root.joinpath(*parts)).encode("utf-16-le")) // 2,
        }
        for parts in WINDOWS_KNOWN_FILES
    ]
    too_long = [entry for entry in paths if entry["length"] > WINDOWS_MAX_PATH]
    return (
        {
            "status": "incomplete",
            "maximum_length": WINDOWS_MAX_PATH,
            "known_paths": paths,
            "full_tree_max_length": None,
            "linux_cpu_wheel_set_windows_relpath_max_length": (
                OBSERVED_S6_LINUX_CPU_STORAGE["windows_venv_max_relpath_length"]
            ),
            "package_set": "unselected_windows_cpu_wheels",
        },
        ["known_path_too_long"] if too_long else [],
    )


def _installation_assessment(
    module_id: str,
    root: Path,
    verification: Mapping[str, Any] | None,
) -> tuple[dict[str, Any], dict[str, Any], list[str], list[str], list[str]]:
    blockers: list[str] = []
    warnings: list[str] = []
    incomplete: list[str] = []
    try:
        report = (
            module_verify.verify_module(module_id, root=root)
            if verification is None
            else verification
        )
        lookup = report["lookup"]
        state = report["installation_state"]
        lock_status = report["lock_status"]
        operation_id = report.get("operation_id")
    except Exception:
        return (
            {"status": "unknown", "lookup": None, "reported_state": None},
            {"status": "unknown", "operation_id": None},
            [],
            [],
            ["existing_installation_unknown", "lock_state_unknown"],
        )
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
    return (
        {"status": status, "lookup": lookup, "reported_state": state},
        {"status": lock_status, "operation_id": operation_id},
        blockers,
        warnings,
        incomplete,
    )


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
            candidates.append(
                {"root": str(root), "markers": markers, "version": None, "ownership": "unknown"}
            )
    candidates.sort(key=lambda entry: entry["root"])
    warnings = []
    if candidates:
        warnings.append("legacy_payload_detected")
    if len(candidates) > 1:
        warnings.append("duplicate_legacy_payload")
    return (
        {
            "candidates": candidates,
            "duplicate_status": (
                "observed" if len(candidates) > 1 else "not_observed_in_scanned_roots"
            ),
            "classification": "legacy_layout_candidate; version unverified",
        },
        warnings,
        incomplete,
    )


def _has_recoverable_receipt_journal(root: Path, module_id: str) -> bool:
    """Return True when an interrupted S6 operation on ``root`` completed
    publishing ``state/modules/<module>.receipt.json`` (recorded in its
    journal or operation log) and can be reconciled under lock before mutation.
    """
    rec_file = module_registry.receipt_path(root, module_id)
    if not rec_file.is_file():
        return False
    if module_registry.read_and_validate_module_record(root, module_id)[0] == "valid":
        return False  # a committed registration is not an interrupted one
    try:
        rec_data = json.loads(rec_file.read_text(encoding="utf-8"))
        module_registry._validate_receipt_structure(rec_data, module_id)
    except Exception:
        return False
    rec_op = str(rec_data.get("operation_id") or "")
    if not rec_op:
        return False
    journal_path = root / "tmp" / rec_op / install_journal.JOURNAL_FILENAME
    if journal_path.is_file():
        try:
            records = install_journal.parse_journal(journal_path.read_bytes(), rec_op)
            completions = {
                r.get("intent_seq") for r in records if r.get("record") == "completion"
            }
            expected_dest = module_registry.receipt_relpath(module_id).as_posix()
            if any(
                r.get("record") == "intent"
                and r.get("action") == install_journal.RENAME
                and r.get("destination") == expected_dest
                and r.get("seq") in completions
                for r in records
            ):
                return True
        except Exception:
            return False
    op_events = root / "logs" / rec_op / install_events.EVENTS_FILENAME
    return op_events.is_file()


def _has_interrupted_operation(root: Path) -> bool:
    """True when another operation's journal is waiting for recovery under lock."""
    tmp = root / "tmp"
    try:
        return any((entry / install_journal.JOURNAL_FILENAME).is_file() for entry in tmp.iterdir())
    except OSError:
        return False


def _s6_destination_assessment(
    module_id: str,
    root: Path,
    verification: Mapping[str, Any] | None,
    *,
    ignore_self_lock_operation_id: Optional[str] = None,
) -> tuple[dict[str, Any], dict[str, Any], list[str], list[str], list[str]]:
    blockers: list[str] = []
    warnings: list[str] = []
    incomplete: list[str] = []

    try:
        report = (
            module_verify.verify_module(module_id, root=root)
            if verification is None
            else verification
        )
        lookup = report["lookup"]
        state = report["installation_state"]
        lock_status = report["lock_status"]
        operation_id = report.get("operation_id")
    except Exception:
        return (
            {"status": "unknown", "lookup": None, "reported_state": None},
            {"status": "unknown", "operation_id": None},
            ["existing_installation_unknown"],
            [],
            ["lock_state_unknown"],
        )

    is_self_lock = (
        ignore_self_lock_operation_id is not None
        and operation_id == ignore_self_lock_operation_id
    )
    if not is_self_lock:
        if lock_status == install_lock.HELD or report.get("operation_in_progress") is True:
            blockers.append("lock_held")
        elif lock_status == install_lock.STALE:
            warnings.append("stale_lock")
        elif lock_status != install_lock.FREE:
            incomplete.append("lock_state_unknown")

    # Check managed_python destination conflict on disk
    try:
        py_rec = runtime_manifest.python_record("linux-x86_64")
        mp_doc = managed_python.verify_managed_python(root, py_rec)
        if mp_doc.get("status") == managed_python.INVALID:
            blockers.append("runtime_conflict")
    except Exception:
        blockers.append("runtime_conflict")

    # Check module_venv destination and assets destination conflicts
    try:
        venv_dir, _, _ = module_registry.expected_module_venv_dir(
            root, module_id, "linux-x86_64", "cpu"
        )
    except Exception:
        venv_dir = None

    assets_dir = module_registry.expected_drumsep_assets_dir(root)
    try:
        ffmpeg_pin = managed_ffmpeg.load_pin("linux-x86_64")
        ffmpeg_dir: Optional[Path] = managed_ffmpeg.published_directory(root, ffmpeg_pin)
    except managed_ffmpeg.FFmpegError:
        ffmpeg_pin, ffmpeg_dir = None, None

    def ffmpeg_destination_findings() -> None:
        # A directory at the pair's destination that no receipt names is adopted
        # only when it is exactly the pinned tree (a run killed after publishing).
        if ffmpeg_dir is not None and os.path.lexists(ffmpeg_dir):
            if managed_ffmpeg.matches_pin(ffmpeg_dir, ffmpeg_pin):
                warnings.append("recoverable_ffmpeg_publication")
            else:
                blockers.append("runtime_conflict")

    components_by_id = {
        str(c.get("component_id")): c
        for c in (report.get("components") or ())
        if isinstance(c, Mapping)
    }

    if state == "repair_required":
        mp_comp = components_by_id.get("managed_python") or {}
        mv_comp = components_by_id.get("module_venv") or {}
        da_comp = components_by_id.get("drumsep_assets") or {}
        if mp_comp.get("class") == "present_failing" or mv_comp.get("class") == "present_failing":
            blockers.append("runtime_conflict")
        if da_comp.get("class") == "present_failing":
            blockers.append("asset_conflict")
        if (components_by_id.get("ffmpeg") or {}).get("class") == "present_failing":
            blockers.append("runtime_conflict")
        if "runtime_conflict" not in blockers and "asset_conflict" not in blockers:
            blockers.append("runtime_conflict")
    elif state == "unknown":
        if _has_recoverable_receipt_journal(root, module_id):
            warnings.append("recoverable_receipt_journal")
        else:
            blockers.append("existing_installation_unknown")
    elif state == "not_installed":
        # Even when not_installed in registry, refuse pre-existing unreceipted
        # module_venv directory or corrupt pre-existing asset directory.
        if venv_dir is not None and venv_dir.exists():
            # Only bytes sealed by an interrupted S6 publication may be resumed.
            if module_registry.matches_publication_record(root, module_id, venv_dir):
                warnings.append("recoverable_venv_publication")
            else:
                blockers.append("runtime_conflict")
        if assets_dir.exists():
            descriptor = module_descriptors.get_module_descriptor(module_id)
            asset_comp = next(c for c in descriptor.components if c.component_id == "drumsep_assets")
            verdict = module_verify.verify_asset_component(
                asset_comp, module_verify.ComponentLocation(assets_dir)
            )
            if verdict.component_class != module_verify.PRESENT_PASSING:
                blockers.append("asset_conflict")
        ffmpeg_destination_findings()
    elif state in {"partial", "installed"}:
        warnings.append("existing_installation_detected")
        # If module_venv is absent in registry while its target directory exists on disk,
        # that's an unreceipted conflict.
        mv_comp = components_by_id.get("module_venv") or {}
        if mv_comp.get("class") == "absent" and venv_dir is not None and venv_dir.exists():
            blockers.append("runtime_conflict")
        if (components_by_id.get("ffmpeg") or {}).get("class") == "absent":
            ffmpeg_destination_findings()

    return (
        {
            "status": state if state != "unknown" else "unknown",
            "lookup": lookup,
            "reported_state": state,
            "ffmpeg": (components_by_id.get("ffmpeg") or {}).get("class"),
        },
        {"status": "self_held" if is_self_lock else lock_status, "operation_id": operation_id},
        sorted(set(blockers)),
        sorted(set(warnings)),
        sorted(set(incomplete)),
    )


def plan_s6_cpu(
    module_id: str,
    root: Path | str | None = None,
    facts: HostFacts | None = None,
    *,
    verification: Mapping[str, Any] | None = None,
    ignore_self_lock_operation_id: Optional[str] = None,
) -> dict[str, Any]:
    """Produce the S6 Linux-first CPU installation plan and preflight verdict."""
    descriptor = module_descriptors.get_module_descriptor(module_id)
    try:
        root_path = absolute_root(
            managed_runtime.managed_runtime_root() if root is None else root
        )
    except InstallPathError as exc:
        raise PreflightError(exc.code) from exc

    actual_facts = observe_host(root_path) if facts is None else facts
    try:
        python_rec = runtime_manifest.python_record(actual_facts.platform_id)
        python_pin = python_rec.to_json()
    except runtime_manifest.ManifestError as exc:
        if exc.code != "platform_unsupported":
            raise PreflightError(exc.code) from exc
        python_rec = None
        python_pin = None

    try:
        lock_manifest = wheel_lock.load_wheel_lock(module_id, "linux-x86_64", "cpu")
    except wheel_lock.WheelLockError as exc:
        raise PreflightError(exc.code) from exc

    try:
        ffmpeg_pin = managed_ffmpeg.load_pin("linux-x86_64")
    except managed_ffmpeg.FFmpegError as exc:
        raise PreflightError(exc.code) from exc

    platform_blockers, platform_incomplete = _platform_findings(actual_facts)
    if actual_facts.platform_id in ("darwin-arm64", "win-x86_64"):
        platform_incomplete.append("s6_platform_port_pending")

    path_blockers, path_incomplete = _path_findings(root_path, actual_facts)

    # The peak is the staged venv, managed Python and two asset copies; the
    # wheelhouse is gone by then, and the Python archive went before the plan.
    s6_known_minimum = OBSERVED_S6_LINUX_CPU_STORAGE["s6_enforced_root_budget_bytes"]
    s6_estimate = s6_known_minimum

    if path_blockers:
        installation = {"status": "unknown", "lookup": None, "reported_state": None}
        lock_info = {"status": "unknown", "operation_id": None}
        inspect_blockers: list[str] = []
        inspect_warnings: list[str] = []
        inspect_incomplete = ["existing_installation_unknown", "lock_state_unknown"]
    else:
        installation, lock_info, inspect_blockers, inspect_warnings, inspect_incomplete = (
            _s6_destination_assessment(
                module_id,
                root_path,
                verification,
                ignore_self_lock_operation_id=ignore_self_lock_operation_id,
            )
        )

    space_blockers: list[str] = []
    space_warnings: list[str] = []
    space_incomplete: list[str] = []
    # A sealed venv or a receipt means the large publications already happened.
    already_s6_satisfied = installation.get("reported_state") in {"partial", "installed"} or bool(
        {"recoverable_venv_publication", "recoverable_receipt_journal"} & set(inspect_warnings)
    )
    required_minimum = 64 * MIB if already_s6_satisfied else s6_known_minimum
    # An S6 root without the pair still has to fetch and stage it (archive + one copy).
    ffmpeg_done = installation.get("ffmpeg") == module_verify.PRESENT_PASSING or (
        "recoverable_ffmpeg_publication" in inspect_warnings
    )
    if already_s6_satisfied and not ffmpeg_done:
        required_minimum += OBSERVED_S6_LINUX_CPU_STORAGE["s7_ffmpeg_phase_peak_allocated_bytes"]
    if actual_facts.free_bytes is None:
        space_incomplete.append("free_space_unknown")
    elif actual_facts.free_bytes < required_minimum:
        # Stale staging is reclaimed only under the lock, so a kill near the
        # limit must still reach recovery. The replan under lock then enforces
        # the budget against what recovery actually freed.
        if ignore_self_lock_operation_id is None and not path_blockers and _has_interrupted_operation(root_path):
            space_warnings.append("space_recheck_after_recovery")
        else:
            space_blockers.append("insufficient_known_space")

    python_host = urlparse(python_rec.url).hostname if python_rec is not None else "github.com"
    asset_hosts = sorted(
        {
            host
            for asset in asset_acquisition._production_policy().assets
            for src in asset.sources
            for host in ((urlparse(src.url).hostname or ""), *src.redirect_hosts)
        }
        - {""}
    )
    ffmpeg_hosts = (urlparse(ffmpeg_pin.archive_url).hostname or "", *managed_ffmpeg.REDIRECT_HOSTS)
    network_hosts = sorted(
        {host for host in (python_host, *lock_manifest.allowed_hosts, *asset_hosts, *ffmpeg_hosts) if host}
    )

    s6_components = [
        asdict(c)
        for c in descriptor.components
        if c.component_id in {"managed_python", "module_venv", "drumsep_assets", "ffmpeg"}
    ]
    venv_pin_id = module_registry.compute_venv_pin_id(
        lock_manifest.python_pin_name, lock_manifest.manifest_sha256
    )
    mp_dest = (
        str(runtime_manifest.published_directory(root_path, python_rec))
        if python_rec is not None
        else str(root_path / "runtimes" / "python")
    )
    venv_dest = str(root_path / "runtimes" / descriptor.module_id / venv_pin_id)
    assets_dest = str(module_registry.expected_drumsep_assets_dir(root_path))
    ffmpeg_dest = str(managed_ffmpeg.published_directory(root_path, ffmpeg_pin))

    actions = {
        "operation": "install",
        "scope": SCOPE_S6_CPU,
        "plan_schema": SCHEMA_VERSION,
        "descriptor_version": module_descriptors.DESCRIPTOR_VERSION,
        "module": descriptor.module_id,
        "platform": actual_facts.platform_id,
        "backend": "cpu",
        "workflow": descriptor.workflow_id,
        "engine": descriptor.engine_id,
        "root": str(root_path),
        "managed_python": python_pin,
        "module_venv_pin_id": venv_pin_id,
        "ffmpeg": ffmpeg_pin.to_json(),
        "destinations": {
            "managed_python": mp_dest,
            "module_venv": venv_dest,
            "ffmpeg": ffmpeg_dest,
            "drumsep_assets": assets_dest,
        },
        "wheel_lock": {
            "lock_id": lock_manifest.lock_id,
            "sha256": lock_manifest.manifest_sha256,
            "wheel_count": lock_manifest.wheel_count,
            "total_wheel_bytes": lock_manifest.total_wheel_bytes,
        },
        "components": s6_components,
        "network_hosts": network_hosts,
        "steps": [
            {
                "phase": "create_environment",
                "estimate_bytes": OBSERVED_S6_LINUX_CPU_STORAGE["python_installed_bytes"],
            },
            {
                "phase": "install_packages",
                "estimate_bytes": (
                    lock_manifest.total_wheel_bytes
                    + OBSERVED_S6_LINUX_CPU_STORAGE["module_venv_staging_peak_bytes"]
                ),
            },
            {
                "phase": "fetch_ffmpeg",
                "estimate_bytes": OBSERVED_S6_LINUX_CPU_STORAGE["s7_ffmpeg_phase_peak_allocated_bytes"],
            },
            {
                "phase": "verify_ffmpeg",
                "estimate_bytes": None,
            },
            {
                "phase": "fetch_assets",
                "estimate_bytes": 2 * ASSET_BYTES,
            },
            {
                "phase": "verify_assets",
                "estimate_bytes": None,
            },
            {
                "phase": "publish",
                "estimate_bytes": None,
            },
            {
                "phase": "verify_module",
                "estimate_bytes": None,
            },
        ],
    }

    blockers = sorted(set(platform_blockers + path_blockers + space_blockers + inspect_blockers))
    warnings = sorted(set(space_warnings + inspect_warnings))
    incomplete = sorted(set(platform_incomplete + path_incomplete + space_incomplete + inspect_incomplete))
    outcome = "blocked" if blockers else "incomplete" if incomplete else "no_blocker_found"

    return {
        "kind": "stemwerk_module_install_plan",
        "schema_version": SCHEMA_VERSION,
        "scope": SCOPE_S6_CPU,
        "preflight_result": outcome,
        "blockers": blockers,
        "warnings": warnings,
        "incomplete": incomplete,
        "fingerprint": fingerprint(actions),
        "actions": actions,
        "space": {
            "filesystem": "root_volume",
            "available_bytes": actual_facts.free_bytes,
            "known_minimum_bytes": s6_known_minimum,
            "estimate_bytes": s6_estimate,
            "estimate_status": "sampled_allocated_peak_plus_headroom",
            "budget_basis": "sampled ext4 allocated root peak + 256 MiB headroom; a cached-source sample, not a physical ext4 high-water mark; wheelhouse and asset staging peaks do not coincide",
            "external_locations": "wheel and asset caches are read-only sources when supplied; TMPDIR holds about 2 MB of pip and verification scratch; all staged writes stay on root",
            "observed_s6_linux_cpu": dict(OBSERVED_S6_LINUX_CPU_STORAGE),
        },
        "installation": installation,
        "lock": lock_info,
        "network_hosts": network_hosts,
        "platform_check": {
            "observed_os": actual_facts.os_version,
            "observed_glibc": actual_facts.glibc_version,
            "vcpp_runtime_present": actual_facts.vcpp_runtime_present,
            "vcpp_evidence": actual_facts.vcpp_evidence,
            "required": {
                "linux-x86_64": {"kernel": "4.18", "glibc": "2.28"},
                "darwin-arm64": {"macos": "14.0"},
                "win-x86_64": {"windows_build": "19045", "vcpp_runtime": True},
            }.get(actual_facts.platform_id),
        },
    }


def plan(
    module_id: str,
    root: Path | str | None = None,
    facts: HostFacts | None = None,
    *,
    verification: Mapping[str, Any] | None = None,
    legacy_roots: Sequence[Path] | None = None,
    scope: str = SCOPE_S4,
) -> dict[str, Any]:
    if scope == SCOPE_S6_CPU:
        return plan_s6_cpu(module_id, root, facts, verification=verification)
    if scope != SCOPE_S4:
        raise ValueError(f"unsupported plan scope: {scope!r}")

    descriptor = module_descriptors.get_module_descriptor(module_id)
    try:
        root = absolute_root(managed_runtime.managed_runtime_root() if root is None else root)
    except InstallPathError as exc:
        raise PreflightError(exc.code) from exc
    actual_facts = observe_host(root) if facts is None else facts
    try:
        python_pin = runtime_manifest.python_record(actual_facts.platform_id).to_json()
    except runtime_manifest.ManifestError as exc:
        if exc.code != "platform_unsupported":
            raise PreflightError(exc.code) from exc
        python_pin = None  # the platform finding below blocks
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
            _installation_assessment(module_id, root, verification)
        )
    roots = legacy_roots
    if roots is None:
        roots = (
            (root,)
            if facts is not None or os.environ.get("STEMWERK_RUNTIME_ROOT")
            else (root, *managed_runtime.runtime_base_candidates())
        )
    if path_blockers:
        legacy = {
            "candidates": [],
            "duplicate_status": "unknown",
            "classification": "inspection skipped for ineligible root",
        }
        legacy_warnings, legacy_incomplete = [], ["legacy_payload_inspection_unknown"]
    else:
        legacy, legacy_warnings, legacy_incomplete = _legacy_assessment(roots)
    blockers = sorted(
        set(
            platform_blockers
            + path_blockers
            + space_blockers
            + length_blockers
            + inspect_blockers
        )
    )
    warnings = sorted(set(space_warnings + inspect_warnings + legacy_warnings))
    incomplete = sorted(
        set(
            platform_incomplete
            + path_incomplete
            + space_incomplete
            + inspect_incomplete
            + legacy_incomplete
            + ["manifest_network_hosts", "bootstrap_operation_state_unknown"]
        )
    )
    outcome = "blocked" if blockers else "incomplete" if incomplete else "no_blocker_found"
    items = space["estimate_items"]
    actions = {
        "operation": "plan",
        "plan_schema": SCHEMA_VERSION,
        "descriptor_version": module_descriptors.DESCRIPTOR_VERSION,
        "module": descriptor.module_id,
        "platform": actual_facts.platform_id,
        "workflow": descriptor.workflow_id,
        "engine": descriptor.engine_id,
        "root": str(root),
        "components": [asdict(c) for c in descriptor.components],
        "managed_python": python_pin,
        "existing_installation": {
            "status": installation["status"],
            "lookup": installation["lookup"],
        },
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
    s6_summary: Optional[dict[str, Any]] = None
    try:
        s6_doc = plan_s6_cpu(module_id, root, actual_facts, verification=verification)
        s6_summary = {
            "scope": SCOPE_S6_CPU,
            "preflight_result": s6_doc["preflight_result"],
            "fingerprint": s6_doc["fingerprint"],
            "blockers": s6_doc["blockers"],
            "warnings": s6_doc["warnings"],
            "incomplete": s6_doc["incomplete"],
            "known_minimum_bytes": s6_doc["space"]["known_minimum_bytes"],
            "estimate_bytes": s6_doc["space"]["estimate_bytes"],
            "network_hosts": s6_doc["network_hosts"],
        }
    except Exception:
        s6_summary = None

    result = {
        "kind": "stemwerk_module_install_plan",
        "schema_version": SCHEMA_VERSION,
        "scope": SCOPE_S4,
        "preflight_result": outcome,
        "blockers": blockers,
        "warnings": warnings,
        "incomplete": incomplete,
        "fingerprint": fingerprint(actions),
        "actions": actions,
        "space": space,
        "path_budget": path_budget,
        "installation": installation,
        "lock": lock,
        "legacy_payloads": legacy,
        "platform_check": {
            "observed_os": actual_facts.os_version,
            "observed_glibc": actual_facts.glibc_version,
            "vcpp_runtime_present": actual_facts.vcpp_runtime_present,
            "vcpp_evidence": actual_facts.vcpp_evidence,
            "required": {
                "linux-x86_64": {"kernel": "4.18", "glibc": "2.28"},
                "darwin-arm64": {"macos": "14.0"},
                "win-x86_64": {"windows_build": "19045", "vcpp_runtime": True},
            }.get(actual_facts.platform_id),
        },
    }
    if s6_summary is not None:
        result["s6_cpu"] = s6_summary
    return result


def require_current_plan(
    consented_fingerprint: str,
    module_id: str,
    root: Path | str | None = None,
    facts: HostFacts | None = None,
    *,
    scope: str = SCOPE_S4,
    ignore_self_lock_operation_id: Optional[str] = None,
) -> dict[str, Any]:
    """Replan immediately before S6 execution and refuse changed consent."""
    if not isinstance(consented_fingerprint, str) or not re.fullmatch(
        r"[0-9a-f]{64}", consented_fingerprint
    ):
        raise PreflightError("plan_changed")

    if scope == SCOPE_S6_CPU:
        s6_plan = plan_s6_cpu(
            module_id,
            root,
            facts,
            ignore_self_lock_operation_id=ignore_self_lock_operation_id,
        )
        valid_consent = hmac.compare_digest(
            s6_plan["fingerprint"], consented_fingerprint
        )
        if not valid_consent:
            raise PreflightError("plan_changed", plan_document=s6_plan)
        if s6_plan["preflight_result"] != "no_blocker_found":
            blockers = s6_plan.get("blockers") or ()
            if len(blockers) == 1 and blockers[0] in {
                "runtime_conflict",
                "asset_conflict",
                "lock_held",
                "insufficient_known_space",
            }:
                raise PreflightError(
                    blockers[0], plan_document=s6_plan, blockers=blockers
                )
            raise PreflightError(
                "preflight_blocked" if blockers else "preflight_incomplete",
                plan_document=s6_plan,
                blockers=blockers,
            )
        return s6_plan

    current_plan = plan(module_id, root, facts, scope=scope)
    current_fingerprint = current_plan["fingerprint"]
    valid_consent = hmac.compare_digest(current_fingerprint, consented_fingerprint)
    if not valid_consent:
        raise PreflightError("plan_changed", plan_document=current_plan)
    if current_plan["preflight_result"] != "no_blocker_found":
        raise PreflightError(
            "preflight_blocked" if current_plan["blockers"] else "preflight_incomplete",
            plan_document=current_plan,
            blockers=current_plan.get("blockers") or (),
        )
    return current_plan
