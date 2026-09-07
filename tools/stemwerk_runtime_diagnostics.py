#!/usr/bin/env python3
"""Portable STEMwerk runtime validation harness (Slice 5).

Produces one deterministic, machine-readable JSON report describing this
machine's STEMwerk identity, managed runtime(s), detected hardware/backends,
2.4 contract resolution for every catalogued workflow, and (optionally, via
--real) a real execution fixture. A Markdown summary can be generated from
that same report object -- there is deliberately only one code path that
decides what happened; Markdown just renders it.

Usage:
    python3 tools/stemwerk_runtime_diagnostics.py [--json out.json] [--markdown out.md] [--real]

Design notes
------------
- Identity is always collected in-process (no torch dependency).
- Runtime/version and hardware/backend info are collected by subprocess-
  probing the *managed* STEMwerk runtime's own interpreter(s) when present
  (main venv + any installed DrumSep venv), never by trusting whatever
  ambient Python happens to run this script -- see managed_runtime_python()/
  managed_drumsep_python(). This is exactly the "managed-runtime tests
  inspect the intended runtime/pin source rather than accidentally testing
  ambient system Python" requirement from the Slice 5 brief. When no managed
  runtime is found, the ambient interpreter is probed instead and clearly
  labeled runtime_source="ambient" so a report never silently conflates the
  two.
- Contract resolution reuses the real, already-accepted Slice 1-4 machinery
  (scripts/reaper/_internal/stemwerk_runtime_seam.py's real CapabilityProbe
  builders, scripts/reaper/vendor/stemwerk-core/src/stemwerk_core/
  runtime_resolution.py) -- this harness does not re-implement device
  selection or contract resolution policy.
- Every state uses one of the five verdicts: PASS, FAIL, SKIPPED,
  UNAVAILABLE, NOT_APPLICABLE. A resolver-only contract check is always
  reported with evidence_kind="real_probe_resolution", never confused with
  evidence_kind="real_execution" (an actual separation was run and its
  output inspected) -- see section 6/16 of the Slice 5 brief.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

SCHEMA_VERSION = "1.0.0"

PASS = "PASS"
FAIL = "FAIL"
SKIPPED = "SKIPPED"
UNAVAILABLE = "UNAVAILABLE"
NOT_APPLICABLE = "NOT_APPLICABLE"

REPO_ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = REPO_ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"
INTERNAL = REPO_ROOT / "scripts" / "reaper" / "_internal"
CATALOG_DIR = REPO_ROOT / "scripts" / "reaper" / "catalog"

for _p in (CORE_SRC, INTERNAL):
    if str(_p) not in sys.path:
        sys.path.insert(0, str(_p))


# ---------------------------------------------------------------------------
# Managed runtime location
# ---------------------------------------------------------------------------

def managed_runtime_root() -> Path:
    """Per-user STEMwerk managed-runtime root on this platform. Mirrors
    audio_separator_process.py's _default_model_cache_dir() root (that
    function returns <this>/models; this returns <this>)."""
    override = os.environ.get("STEMWERK_RUNTIME_ROOT")
    if override:
        return Path(override).expanduser()
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / "STEMwerk"
    if os.name == "nt":
        local_appdata = os.environ.get("LOCALAPPDATA")
        if local_appdata:
            return Path(local_appdata) / "STEMwerk"
        return Path.home() / "AppData" / "Local" / "STEMwerk"
    xdg_data_home = os.environ.get("XDG_DATA_HOME")
    if xdg_data_home:
        return Path(xdg_data_home) / "STEMwerk"
    return Path.home() / ".local" / "share" / "STEMwerk"


def _first_existing(root: Path, venv_name: str) -> Optional[Path]:
    for rel in ("bin/python3", "bin/python", "Scripts/python.exe"):
        candidate = root / venv_name / rel
        if candidate.exists():
            return candidate
    return None


def managed_runtime_python() -> Optional[Path]:
    """The main STEMwerk managed venv's interpreter, if bootstrapped."""
    return _first_existing(managed_runtime_root(), ".venv")


def managed_drumsep_pythons() -> Dict[str, Path]:
    """Every installed DrumSep venv on this machine, keyed by backend name.
    Only backends that actually have a venv present are included -- this is
    real filesystem state, not a claim about what *should* be installed."""
    root = managed_runtime_root()
    found: Dict[str, Path] = {}
    for backend, venv_name in (
        ("rocm", ".venv-drumsep-rocm"),
        ("cuda", ".venv-drumsep-cuda"),
        ("directml", ".venv-drumsep-directml"),
        ("cpu", ".venv-drumsep"),
    ):
        python = _first_existing(root, venv_name)
        if python is not None:
            found[backend] = python
    return found


def managed_model_cache_dir() -> Path:
    override = os.environ.get("AUDIO_SEPARATOR_MODEL_DIR")
    if override:
        return Path(override).expanduser()
    return managed_runtime_root() / "models"


# ---------------------------------------------------------------------------
# Identity
# ---------------------------------------------------------------------------

def collect_identity() -> Dict[str, Any]:
    version_path = REPO_ROOT / "VERSION"
    stemwerk_version = version_path.read_text(encoding="utf-8").strip() if version_path.exists() else "unknown"
    return {
        "stemwerk_version": stemwerk_version,
        "platform_system": platform.system(),
        "platform_release": platform.release(),
        "architecture": platform.machine(),
        "python_version": platform.python_version(),
        "harness_python_executable": sys.executable,
        "hostname": platform.node(),
    }


# ---------------------------------------------------------------------------
# Runtime (versions) -- probed via subprocess against the intended interpreter
# ---------------------------------------------------------------------------

_RUNTIME_PROBE_SRC = r"""
import json

result = {}
try:
    import torch
    result["torch_version"] = getattr(torch, "__version__", None)
    result["torch_cuda_available"] = bool(torch.cuda.is_available())
    result["torch_cuda_version"] = getattr(getattr(torch, "version", None), "cuda", None)
    result["torch_hip_version"] = getattr(getattr(torch, "version", None), "hip", None)
    count = torch.cuda.device_count() if result["torch_cuda_available"] else 0
    result["torch_cuda_device_count"] = count
    names = []
    for i in range(count):
        try:
            names.append(torch.cuda.get_device_name(i))
        except Exception:
            pass
    result["torch_cuda_device_names"] = names
    try:
        result["torch_mps_built"] = bool(torch.backends.mps.is_built())
        result["torch_mps_available"] = bool(torch.backends.mps.is_available())
    except Exception:
        result["torch_mps_built"] = None
        result["torch_mps_available"] = None
except Exception as exc:
    result["torch_version"] = None
    result["torch_import_error"] = "%s: %s" % (type(exc).__name__, exc)

for mod_name, key in (
    ("torchaudio", "torchaudio_version"),
    ("torchvision", "torchvision_version"),
    ("numpy", "numpy_version"),
):
    try:
        mod = __import__(mod_name)
        result[key] = getattr(mod, "__version__", None)
    except Exception:
        result[key] = None

try:
    from importlib.metadata import PackageNotFoundError, version as pkg_version
    try:
        result["audio_separator_version"] = pkg_version("audio-separator")
    except PackageNotFoundError:
        result["audio_separator_version"] = None
except Exception:
    result["audio_separator_version"] = None

try:
    import onnxruntime
    result["onnxruntime_version"] = getattr(onnxruntime, "__version__", None)
    try:
        result["onnxruntime_providers"] = list(onnxruntime.get_available_providers())
    except Exception:
        result["onnxruntime_providers"] = []
except Exception:
    result["onnxruntime_version"] = None
    result["onnxruntime_providers"] = []

print(json.dumps(result))
"""


def _run_probe(python_exe: Path, src: str, timeout: int = 60) -> Dict[str, Any]:
    try:
        proc = subprocess.run(
            [str(python_exe), "-c", src],
            capture_output=True, text=True, timeout=timeout,
        )
    except Exception as exc:
        return {"probe_error": f"{type(exc).__name__}: {exc}"}
    if proc.returncode != 0:
        return {"probe_error": (proc.stderr or proc.stdout).strip()[-2000:]}
    lines = [line for line in proc.stdout.strip().splitlines() if line.strip()]
    if not lines:
        return {"probe_error": "probe produced no output"}
    try:
        return json.loads(lines[-1])
    except Exception as exc:
        return {"probe_error": f"could not parse probe output: {exc}", "raw_stdout": proc.stdout[-2000:]}


def collect_runtime(python_exe: Optional[Path], *, source_label: str) -> Dict[str, Any]:
    if python_exe is None:
        return {"status": UNAVAILABLE, "reason": f"no {source_label} interpreter found", "runtime_source": source_label}
    data = _run_probe(python_exe, _RUNTIME_PROBE_SRC)
    data["python_executable"] = str(python_exe)
    data["runtime_source"] = source_label
    data["status"] = FAIL if "probe_error" in data else PASS
    return data


# ---------------------------------------------------------------------------
# Hardware / backend
# ---------------------------------------------------------------------------

_MAIN_HARDWARE_PROBE_SRC = r"""
import json

result = {}
try:
    from stemwerk_core import devices
    result["available_devices"] = devices.get_available_devices()
    resolved_id, resolved_name = devices.select_device("auto")
    result["auto_selected_device_id"] = resolved_id
    result["auto_selected_device_name"] = resolved_name
    result["auto_selected_backend"] = devices.runtime_kind_for_device(resolved_id)
except Exception as exc:
    result["error"] = "%s: %s" % (type(exc).__name__, exc)

print(json.dumps(result))
"""


def collect_main_hardware(python_exe: Optional[Path], *, source_label: str) -> Dict[str, Any]:
    if python_exe is None:
        return {"status": UNAVAILABLE, "reason": f"no {source_label} interpreter found", "runtime_source": source_label}
    data = _run_probe(python_exe, _MAIN_HARDWARE_PROBE_SRC)
    data["python_executable"] = str(python_exe)
    data["runtime_source"] = source_label
    data["status"] = FAIL if ("probe_error" in data or "error" in data) else PASS
    return data


_DRUMSEP_HARDWARE_PROBE_SRC = r"""
import json

result = {}
try:
    import torch
    result["torch_version"] = getattr(torch, "__version__", None)
    result["torch_hip_version"] = getattr(getattr(torch, "version", None), "hip", None)
    result["cuda_available"] = bool(torch.cuda.is_available())
    count = torch.cuda.device_count() if result["cuda_available"] else 0
    names = []
    for i in range(count):
        try:
            names.append(torch.cuda.get_device_name(i))
        except Exception:
            pass
    result["device_names"] = names
except Exception as exc:
    result["error"] = "%s: %s" % (type(exc).__name__, exc)

print(json.dumps(result))
"""


def collect_drumsep_hardware(backend: str, python_exe: Path) -> Dict[str, Any]:
    data = _run_probe(python_exe, _DRUMSEP_HARDWARE_PROBE_SRC)
    data["python_executable"] = str(python_exe)
    data["declared_backend"] = backend
    data["status"] = FAIL if ("probe_error" in data or "error" in data) else PASS
    return data


# ---------------------------------------------------------------------------
# Contracts -- real probe resolution, reusing Slice 1-4's own machinery
# ---------------------------------------------------------------------------

_WORKFLOW_DEFAULT_MODEL = {
    "normal_stems": "htdemucs",
    "drum_kit_direct": "drumsep_mdx23c",
    "drum_kit_split": ("htdemucs", "drumsep_mdx23c"),
}


def _legacy_authoritative_gates_present() -> Dict[str, bool]:
    """Structural regression check: the Slice-4 authoritative gate functions
    must still exist on the loaded legacy module. This does not prove they
    are wired at their call sites (the test suite proves that); it proves
    this harness is looking at a build that still HAS them, so a report
    generated against a build where they were silently removed cannot claim
    authoritative status."""
    try:
        import stemwerk_runtime_seam

        legacy = stemwerk_runtime_seam._load_legacy_module()
    except Exception as exc:
        return {"_error": f"{type(exc).__name__}: {exc}"}
    return {
        "normal_stems": hasattr(legacy, "_enforce_normal_stems_contract"),
        "drum_kit_direct": hasattr(legacy, "_enforce_drum_kit_direct_contract"),
        "drum_kit_split": hasattr(legacy, "_enforce_drum_kit_split_contract"),
    }


def collect_contracts(requested_device: str = "auto") -> Dict[str, Any]:
    try:
        import stemwerk_runtime_seam
        from stemwerk_core.runtime_resolution import (
            ResolutionError,
            StageRequest,
            resolve_execution_plan,
            resolve_workflow_plan,
        )
    except Exception as exc:
        return {"status": UNAVAILABLE, "reason": f"contract machinery not importable: {type(exc).__name__}: {exc}"}

    gates_present = _legacy_authoritative_gates_present()
    results: Dict[str, Any] = {}

    def _plan_dict(plan) -> Dict[str, Any]:
        return {
            "workflow_id": plan.workflow_id,
            "stage_id": plan.stage_id,
            "model_id": plan.model_id,
            "requested_device": plan.requested_device,
            "resolved_backend": plan.resolved_backend,
            "resolved_device": plan.resolved_device,
            "fallback_applied": plan.fallback_applied,
            "reason_code": plan.reason_code,
            "contract_source": plan.contract_source,
        }

    # normal_stems -- single stage, real device-enumeration probe.
    try:
        probe = stemwerk_runtime_seam.build_normal_stems_capability_probe()
        plan = resolve_execution_plan(
            "normal_stems", _WORKFLOW_DEFAULT_MODEL["normal_stems"], requested_device,
            catalog_dir=CATALOG_DIR, probe=probe,
        )
        results["normal_stems"] = {
            "status": PASS,
            "evidence_kind": "real_probe_resolution",
            "authoritative": bool(gates_present.get("normal_stems")),
            "plan": _plan_dict(plan),
        }
    except ResolutionError as exc:
        results["normal_stems"] = {"status": FAIL, "evidence_kind": "real_probe_resolution", "reason": f"{exc.code}: {exc.detail}"}
    except Exception as exc:
        results["normal_stems"] = {"status": UNAVAILABLE, "reason": f"{type(exc).__name__}: {exc}"}

    # drum_kit_direct -- single stage, real DrumSep venv-selection probe.
    try:
        probe = stemwerk_runtime_seam.build_drum_kit_capability_probe()
        plan = resolve_execution_plan(
            "drum_kit_direct", _WORKFLOW_DEFAULT_MODEL["drum_kit_direct"], requested_device,
            catalog_dir=CATALOG_DIR, probe=probe,
        )
        results["drum_kit_direct"] = {
            "status": PASS,
            "evidence_kind": "real_probe_resolution",
            "authoritative": bool(gates_present.get("drum_kit_direct")),
            "plan": _plan_dict(plan),
        }
    except ResolutionError as exc:
        results["drum_kit_direct"] = {"status": FAIL, "evidence_kind": "real_probe_resolution", "reason": f"{exc.code}: {exc.detail}"}
    except Exception as exc:
        results["drum_kit_direct"] = {"status": UNAVAILABLE, "reason": f"{type(exc).__name__}: {exc}"}

    # drum_kit_split -- two stages, real probes for both.
    try:
        stage1_model, stage2_model = _WORKFLOW_DEFAULT_MODEL["drum_kit_split"]
        stage_requests = [
            StageRequest(model_id=stage1_model, requested_device=requested_device, probe=stemwerk_runtime_seam.build_normal_stems_capability_probe()),
            StageRequest(model_id=stage2_model, requested_device=requested_device, probe=stemwerk_runtime_seam.build_drum_kit_capability_probe()),
        ]
        workflow_plan = resolve_workflow_plan("drum_kit_split", stage_requests, catalog_dir=CATALOG_DIR)
        results["drum_kit_split"] = {
            "status": PASS,
            "evidence_kind": "real_probe_resolution",
            "authoritative": bool(gates_present.get("drum_kit_split")),
            "stages": [_plan_dict(p) for p in workflow_plan.stages],
        }
    except ResolutionError as exc:
        results["drum_kit_split"] = {"status": FAIL, "evidence_kind": "real_probe_resolution", "reason": f"{exc.code}: {exc.detail}"}
    except Exception as exc:
        results["drum_kit_split"] = {"status": UNAVAILABLE, "reason": f"{type(exc).__name__}: {exc}"}

    return results


# ---------------------------------------------------------------------------
# Execution agreement (real fixture) -- optional, --real only
# ---------------------------------------------------------------------------

def _referenced_model_hashes(yaml_path: Path) -> List[str]:
    import re

    text = yaml_path.read_text(encoding="utf-8")
    match = re.search(r"models:\s*\[([^\]]*)\]", text)
    if not match:
        return []
    return [h.strip("'\" ") for h in match.group(1).split(",") if h.strip("'\" ")]


def _stage_model_copy(source_dir: Path, model_name: str, dest_dir: Path) -> Optional[Path]:
    """Copies only the yaml + referenced .th weight file(s) into a
    harness-owned scratch directory; never points real execution at the
    live production model cache (see Slice 3's download_checks.json write
    hazard finding, carried forward per Slice 5 section 9)."""
    yaml_src = source_dir / f"{model_name}.yaml"
    if not yaml_src.exists():
        return None
    dest_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(yaml_src, dest_dir / yaml_src.name)
    for prefix in _referenced_model_hashes(yaml_src):
        matches = list(source_dir.glob(f"{prefix}*.th"))
        if not matches:
            return None
        shutil.copy2(matches[0], dest_dir / matches[0].name)
    return dest_dir


def run_real_normal_stems_fixture(requested_device: str, python_exe: Optional[Path]) -> Dict[str, Any]:
    if python_exe is None:
        return {"status": UNAVAILABLE, "reason": "no managed runtime interpreter available"}

    source_dir = managed_model_cache_dir()
    model_name = "htdemucs"
    if not (source_dir / f"{model_name}.yaml").exists():
        return {"status": SKIPPED, "reason": f"{model_name} not locally available under {source_dir}"}

    with tempfile.TemporaryDirectory(prefix="stemwerk_harness_") as tmp:
        tmp_path = Path(tmp)
        staged_models = _stage_model_copy(source_dir, model_name, tmp_path / "models")
        if staged_models is None:
            return {"status": SKIPPED, "reason": f"{model_name} weight files incomplete under {source_dir}"}
        clip = tmp_path / "clip.wav"
        out_dir = tmp_path / "out"
        out_dir.mkdir()

        # Clip synthesis and separation both run inside the managed runtime's
        # own interpreter (never the harness process, whose ambient Python
        # may lack numpy/soundfile entirely -- see collect_runtime()'s own
        # "runtime_source" labeling for why we don't trust ambient Python).
        script = (
            "import json, os, sys\n"
            "sys.path.insert(0, %r)\n"
            "os.environ['AUDIO_SEPARATOR_MODEL_DIR'] = %r\n"
            "import numpy as np\n"
            "import soundfile as sf\n"
            "samples = np.random.default_rng(0).uniform(-0.1, 0.1, size=(44100 * 2, 2)).astype('float32')\n"
            "sf.write(%r, samples, 44100)\n"
            "from stemwerk_core.separator import StemSeparator\n"
            "sep = StemSeparator(model=%r, device=%r)\n"
            "cwd = os.getcwd()\n"
            "os.chdir(%r)\n"
            "try:\n"
            "    result = sep.separate(%r, %r)\n"
            "finally:\n"
            "    os.chdir(cwd)\n"
            "print(json.dumps({'device_used': getattr(sep, 'device_used', None), 'result': str(result)}))\n"
        ) % (
            str(CORE_SRC), str(staged_models), str(clip), model_name, requested_device,
            str(out_dir), str(clip), str(out_dir),
        )
        env = dict(os.environ)
        env["AUDIO_SEPARATOR_MODEL_DIR"] = str(staged_models)
        # Demucs checkpoints predate PyTorch 2.6's weights_only=True default;
        # this is the same compat mechanism audio_separator_process.py's own
        # _enable_torch_weights_only_compat() sets for real Demucs runs.
        env["TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD"] = "1"
        try:
            proc = subprocess.run(
                [str(python_exe), "-c", script],
                capture_output=True, text=True, timeout=180, env=env,
            )
        except Exception as exc:
            return {"status": FAIL, "evidence_kind": "real_execution", "reason": f"{type(exc).__name__}: {exc}"}
        outputs = sorted(p.name for p in out_dir.glob("*.wav") if p.stat().st_size > 0)
        if proc.returncode != 0:
            return {
                "status": FAIL, "evidence_kind": "real_execution",
                "reason": (proc.stderr or proc.stdout).strip()[-2000:],
            }
        return {
            "status": PASS,
            "evidence_kind": "real_execution",
            "requested_device": requested_device,
            "output_count": len(outputs),
            "output_names": outputs,
        }


_DIRECT_DKS_EXPECTED_STEMS = 6


def run_real_drum_kit_direct_fixture(backend: str, drumsep_python: Path) -> Dict[str, Any]:
    """Real end-to-end Direct Kit separation against an already-installed
    DrumSep venv, using only locally-staged model files (never downloads).
    Reuses the real _run_direct_dks_drumsep_helper the production dks_direct
    route itself calls -- this is real_execution evidence, not a resolver-only
    check (contrast collect_contracts(), which is real_probe_resolution)."""
    source_dir = managed_model_cache_dir()
    legacy_checkpoint = "MDX23C-DrumSep-aufr33-jarredou.ckpt"
    resolved_checkpoint = "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt"
    model_stem = Path(resolved_checkpoint).stem
    if not (source_dir / f"{model_stem}.yaml").exists():
        return {"status": SKIPPED, "reason": f"DrumSep model {model_stem} not locally available under {source_dir}"}

    with tempfile.TemporaryDirectory(prefix="stemwerk_harness_dks_") as tmp:
        tmp_path = Path(tmp)
        # DrumSep's checkpoint is a single named .ckpt + sibling .yaml (no
        # Demucs-style hash-referenced .th bag), so this stages by direct
        # filename rather than reusing _stage_model_copy's Demucs-specific
        # "models: [hash, ...]" yaml parsing.
        staged_models = tmp_path / "models"
        staged_models.mkdir(parents=True, exist_ok=True)
        ckpt_src = source_dir / resolved_checkpoint
        yaml_src = source_dir / f"{model_stem}.yaml"
        if not ckpt_src.exists():
            return {"status": SKIPPED, "reason": f"DrumSep checkpoint {resolved_checkpoint} not locally available under {source_dir}"}
        shutil.copy2(ckpt_src, staged_models / ckpt_src.name)
        shutil.copy2(yaml_src, staged_models / yaml_src.name)

        script = (
            "import json, os, sys\n"
            "from pathlib import Path\n"
            "sys.path.insert(0, %r)\n"
            "import numpy as np\n"
            "import soundfile as sf\n"
            "samples = np.random.default_rng(0).uniform(-0.1, 0.1, size=(44100 * 2, 2)).astype('float32')\n"
            "clip = Path(%r)\n"
            "sf.write(str(clip), samples, 44100)\n"
            "import importlib.util\n"
            "spec = importlib.util.spec_from_file_location('m', %r)\n"
            "legacy = importlib.util.module_from_spec(spec)\n"
            "spec.loader.exec_module(legacy)\n"
            "legacy._configure_ffmpeg_runtime()\n"
            "ok, stems, reason, detail = legacy._run_direct_dks_drumsep_helper(\n"
            "    clip, Path(%r), Path(%r), Path(%r),\n"
            "    %r, %r,\n"
            "    route='wrapper', device=%r, requested_device=%r, backend_runtime=%r,\n"
            ")\n"
            "print(json.dumps({'ok': ok, 'stems': stems, 'reason': reason, 'detail': detail}))\n"
        ) % (
            str(CORE_SRC), str(tmp_path / "clip.wav"),
            str(REPO_ROOT / "scripts" / "reaper" / "audio_separator_process.py"),
            str(tmp_path / "out"), str(staged_models), str(drumsep_python),
            legacy_checkpoint, resolved_checkpoint,
            backend, backend, backend,
        )
        (tmp_path / "out").mkdir()
        try:
            # This runs under the *managed main venv* python (not the DrumSep
            # venv) because it needs to import audio_separator_process.py's
            # own helper machinery; the DrumSep separation itself happens in
            # a further real subprocess that _run_direct_dks_drumsep_helper
            # launches using drumsep_python, exactly as production does.
            main_python = managed_runtime_python()
            if main_python is None:
                return {"status": UNAVAILABLE, "reason": "no managed main-venv interpreter available"}
            proc = subprocess.run(
                [str(main_python), "-c", script],
                capture_output=True, text=True, timeout=180,
            )
        except Exception as exc:
            return {"status": FAIL, "evidence_kind": "real_execution", "reason": f"{type(exc).__name__}: {exc}"}
        if proc.returncode != 0:
            return {"status": FAIL, "evidence_kind": "real_execution", "reason": (proc.stderr or proc.stdout).strip()[-2000:]}
        lines = [line for line in proc.stdout.strip().splitlines() if line.strip()]
        try:
            data = json.loads(lines[-1]) if lines else {}
        except Exception as exc:
            return {"status": FAIL, "evidence_kind": "real_execution", "reason": f"could not parse helper output: {exc}"}
        if not data.get("ok"):
            return {"status": FAIL, "evidence_kind": "real_execution", "reason": f"{data.get('reason')}: {data.get('detail')}"}
        stems = data.get("stems") or {}
        return {
            "status": PASS if len(stems) == _DIRECT_DKS_EXPECTED_STEMS else FAIL,
            "evidence_kind": "real_execution",
            "backend": backend,
            "output_count": len(stems),
            "output_names": sorted(stems.keys()),
        }


# ---------------------------------------------------------------------------
# Safety
# ---------------------------------------------------------------------------

def snapshot_model_cache_mtimes() -> Dict[str, float]:
    cache = managed_model_cache_dir()
    if not cache.exists():
        return {}
    return {str(p): p.stat().st_mtime for p in cache.glob("*") if p.is_file()}


def diff_model_cache_mtimes(before: Dict[str, float]) -> Dict[str, Any]:
    after = snapshot_model_cache_mtimes()
    changed = {k: (before.get(k), after.get(k)) for k in set(before) | set(after) if before.get(k) != after.get(k)}
    return {"unchanged": not changed, "changed_files": changed}


# ---------------------------------------------------------------------------
# Backend matrix (static declared intent, section 7 -- not a claim of support)
# ---------------------------------------------------------------------------

BACKEND_MATRIX = {
    "linux": ["rocm", "cpu"],
    "windows": ["cuda", "directml", "cpu"],
    "darwin": ["mps", "cpu"],
}

_PLATFORM_KEY = {"Linux": "linux", "Windows": "windows", "Darwin": "darwin"}


# ---------------------------------------------------------------------------
# Report assembly
# ---------------------------------------------------------------------------

def build_report(*, real: bool = False, requested_device: str = "auto") -> Dict[str, Any]:
    identity = collect_identity()
    this_platform_key = _PLATFORM_KEY.get(identity["platform_system"], identity["platform_system"].lower())

    main_python = managed_runtime_python()
    main_source = "managed" if main_python is not None else "ambient"
    if main_python is None:
        main_python = Path(sys.executable)

    runtime: Dict[str, Any] = {"main": collect_runtime(main_python, source_label=main_source)}
    hardware: Dict[str, Any] = {"main": collect_main_hardware(main_python, source_label=main_source)}

    drumsep_pythons = managed_drumsep_pythons()
    for backend, python_exe in drumsep_pythons.items():
        runtime[f"drumsep_{backend}"] = collect_runtime(python_exe, source_label="managed")
        hardware[f"drumsep_{backend}"] = collect_drumsep_hardware(backend, python_exe)
    for backend in ("rocm", "cuda", "directml", "cpu"):
        key = f"drumsep_{backend}"
        if key not in hardware:
            hardware[key] = {"status": UNAVAILABLE, "reason": f"no .venv-drumsep{'-' + backend if backend != 'cpu' else ''} found under {managed_runtime_root()}"}

    contracts = collect_contracts(requested_device=requested_device)

    backend_matrix: Dict[str, Any] = {}
    for plat, backends in BACKEND_MATRIX.items():
        row = {}
        for backend in backends:
            if plat != this_platform_key:
                row[backend] = NOT_APPLICABLE
                continue
            if backend == "cpu":
                row[backend] = PASS if main_python is not None else UNAVAILABLE
            elif backend in drumsep_pythons or hardware["main"].get("auto_selected_backend") == backend:
                row[backend] = PASS
            else:
                row[backend] = UNAVAILABLE
        backend_matrix[plat] = row

    report: Dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "identity": identity,
        "runtime": runtime,
        "hardware": hardware,
        "contracts": contracts,
        "backend_matrix": backend_matrix,
        "safety": {
            "managed_model_cache_dir": str(managed_model_cache_dir()),
            "note": "no real execution was requested" if not real else "see execution section",
        },
    }

    if real:
        before = snapshot_model_cache_mtimes()
        execution: Dict[str, Any] = {}
        execution["normal_stems_cpu"] = run_real_normal_stems_fixture("cpu", main_python if main_source == "managed" else None)
        auto_backend = hardware["main"].get("auto_selected_backend")
        if auto_backend and auto_backend not in ("cpu", "unavailable"):
            execution["normal_stems_auto"] = run_real_normal_stems_fixture("auto", main_python if main_source == "managed" else None)
        for backend, drumsep_python in drumsep_pythons.items():
            execution[f"drum_kit_direct_{backend}"] = run_real_drum_kit_direct_fixture(backend, drumsep_python)
        report["execution"] = execution
        report["safety"]["model_cache_mtime_check"] = diff_model_cache_mtimes(before)

    return report


# ---------------------------------------------------------------------------
# Markdown rendering (from the same report object -- no second implementation)
# ---------------------------------------------------------------------------

def to_markdown(report: Dict[str, Any]) -> str:
    lines: List[str] = []
    identity = report.get("identity", {})
    lines.append(f"# STEMwerk runtime diagnostics (schema {report.get('schema_version')})")
    lines.append("")
    lines.append(f"Generated: {report.get('generated_at_utc')}")
    lines.append("")
    lines.append("## Identity")
    for key, value in identity.items():
        lines.append(f"- **{key}**: {value}")
    lines.append("")
    lines.append("## Runtime")
    for name, data in report.get("runtime", {}).items():
        lines.append(f"### {name}")
        lines.append(f"- status: {data.get('status')}")
        lines.append(f"- runtime_source: {data.get('runtime_source')}")
        for key in ("torch_version", "torchaudio_version", "torchvision_version", "numpy_version", "audio_separator_version", "onnxruntime_version"):
            if key in data:
                lines.append(f"- {key}: {data.get(key)}")
        lines.append("")
    lines.append("## Hardware / backend")
    for name, data in report.get("hardware", {}).items():
        lines.append(f"### {name}")
        lines.append(f"- status: {data.get('status')}")
        if "auto_selected_device_name" in data:
            lines.append(f"- auto_selected: {data.get('auto_selected_device_name')} ({data.get('auto_selected_backend')})")
        if "device_names" in data:
            lines.append(f"- device_names: {', '.join(data.get('device_names') or []) or 'none'}")
        if data.get("status") != PASS and "reason" in data:
            lines.append(f"- reason: {data.get('reason')}")
        lines.append("")
    lines.append("## Contracts")
    for workflow_id, data in report.get("contracts", {}).items():
        lines.append(f"### {workflow_id}")
        lines.append(f"- status: {data.get('status')} ({data.get('evidence_kind', 'n/a')})")
        lines.append(f"- authoritative: {data.get('authoritative')}")
        if "plan" in data:
            plan = data["plan"]
            lines.append(f"- resolved: {plan.get('resolved_backend')}/{plan.get('resolved_device')} ({plan.get('reason_code')})")
        if "stages" in data:
            for stage in data["stages"]:
                lines.append(f"  - stage {stage.get('stage_id')}: {stage.get('resolved_backend')}/{stage.get('resolved_device')} ({stage.get('reason_code')})")
        lines.append("")
    if "execution" in report:
        lines.append("## Execution agreement (real fixture)")
        for name, data in report["execution"].items():
            lines.append(f"### {name}")
            lines.append(f"- status: {data.get('status')} ({data.get('evidence_kind', 'n/a')})")
            if "output_names" in data:
                lines.append(f"- outputs: {', '.join(data['output_names'])}")
            if data.get("status") != PASS and "reason" in data:
                lines.append(f"- reason: {data.get('reason')}")
            lines.append("")
    lines.append("## Backend matrix")
    for plat, row in report.get("backend_matrix", {}).items():
        lines.append(f"- **{plat}**: " + ", ".join(f"{b}={v}" for b, v in row.items()))
    lines.append("")
    lines.append("## Safety")
    for key, value in report.get("safety", {}).items():
        lines.append(f"- {key}: {value}")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", type=Path, default=None, help="write JSON report to this path (default: stdout)")
    parser.add_argument("--markdown", type=Path, default=None, help="also write a Markdown summary to this path")
    parser.add_argument("--real", action="store_true", help="attempt real execution fixtures where locally available")
    parser.add_argument("--device", default="auto", help="requested device for contract resolution (default: auto)")
    args = parser.parse_args(argv)

    report = build_report(real=args.real, requested_device=args.device)
    payload = json.dumps(report, indent=2, sort_keys=True)

    if args.json:
        args.json.write_text(payload, encoding="utf-8")
    else:
        print(payload)

    if args.markdown:
        args.markdown.write_text(to_markdown(report), encoding="utf-8")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
