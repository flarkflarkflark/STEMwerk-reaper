"""Live (local-machine) evidence collectors for STEMwerk Core readiness.

Bounded side-effect contract:

- Every hardware/runtime observation happens in a bounded subprocess against
  the *intended* interpreter (managed STEMwerk venv when present, otherwise
  the ambient interpreter running this process, labeled ``runtime_source``
  accordingly) -- never by importing Torch/GPU libraries into this process.
- Parent-process filesystem evidence checks are pure ``stat``/content reads
  and do not intentionally provision, download, repair, evict, or change
  installed runtime/model state. Each live probe creates and later cleans an
  owned temporary working directory, and disables subprocess bytecode writes.
- Controlled tests establish filesystem invariance and no required network
  calls for their payloads and environments. They do not universally rule out
  cache/config writes, network activity, or other initialization effects from
  arbitrary real third-party imports.
- The existing diagnostics timeout policy is preserved (``_run_probe``
  defaults to 60 s); no shorter production limits are introduced.

The runtime-imports probe payload and required-import profiles are the
canonical copies moved from ``tools/stemwerk_runtime_diagnostics.py``; that
harness imports them back from here. DrumSep selection is also Core-owned:
the selector runs in the intended interpreter through the same validated
Core-origin boundary, then the selected interpreter gets its own required-
imports probe. Neither path imports the REAPER processor.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Callable, Dict, Optional

from . import managed_runtime
from . import device_policy
from .verdicts import FAIL, PASS, UNAVAILABLE


def _stable_device_identity(properties: Any) -> Dict[str, str]:
    """Return only physical-device identifiers exposed by Torch."""

    identity: Dict[str, str] = {}
    for key in ("uuid", "pci_bus_id"):
        try:
            value = getattr(properties, key, None)
        except Exception:
            value = None
        text = "" if value is None else str(value).strip()
        if text:
            identity[key] = text
    return identity


def _has_stable_device_identity(identity: Any) -> bool:
    if not isinstance(identity, dict):
        return False
    return any(
        str(identity.get(key) or "").strip() for key in ("uuid", "pci_bus_id")
    )


# ---------------------------------------------------------------------------
# Generic bounded subprocess JSON probe shared with
# tools/stemwerk_runtime_diagnostics.py (the harness imports it back).
# ---------------------------------------------------------------------------

def _run_probe(python_exe: Path, src: str, timeout: int = 60) -> Dict[str, Any]:
    """Run one JSON probe in an isolated, disposable process context.

    The selected interpreter keeps its own installed packages, but it cannot
    inherit a caller-supplied Python import path, startup hook, current working
    directory, or bytecode-write policy. The temporary working directory is
    owned and removed by this call.
    """

    env = os.environ.copy()
    for key in ("PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP", "PYTHONINSPECT"):
        env.pop(key, None)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    try:
        with tempfile.TemporaryDirectory(prefix="stemwerk-readiness-") as scratch:
            proc = subprocess.run(
                [str(python_exe), "-I", "-B", "-c", src],
                capture_output=True,
                text=True,
                timeout=timeout,
                cwd=scratch,
                env=env,
            )
    except Exception as exc:
        return {"probe_error": f"{type(exc).__name__}: {exc}"}
    if proc.returncode != 0:
        return {"probe_error": (proc.stderr or proc.stdout).strip()[-2000:]}
    lines = [line for line in proc.stdout.strip().splitlines() if line.strip()]
    if not lines:
        return {"probe_error": "probe produced no output"}
    try:
        payload = json.loads(lines[-1])
    except Exception as exc:
        return {"probe_error": f"could not parse probe output: {exc}", "raw_stdout": proc.stdout[-2000:]}
    if not isinstance(payload, dict):
        return {"probe_error": f"probe output must be a JSON object, got {type(payload).__name__}"}
    return payload


def _run_core_probe(
    python_exe: Path,
    src: str,
    timeout: int = 60,
    *,
    core_source_dir: Optional[Path] = None,
    expected_python_executable: Optional[Path] = None,
) -> Dict[str, Any]:
    """Run a payload against this exact Core source and validate identity."""

    current_package = Path(__file__).resolve().parent
    expected_core = current_package / "__init__.py"
    source_dir = Path(core_source_dir or current_package.parent).resolve()
    expected_python = Path(expected_python_executable or python_exe).absolute()
    wrapper = f"""
import contextlib
import io
import json
import pathlib
import sys

_core_source_dir = {str(source_dir)!r}
sys.path.insert(0, _core_source_dir)
try:
    import stemwerk_core
finally:
    if sys.path and sys.path[0] == _core_source_dir:
        del sys.path[0]
    else:
        sys.path.remove(_core_source_dir)

_captured = io.StringIO()
with contextlib.redirect_stdout(_captured):
    exec(compile({src!r}, "<stemwerk-readiness-probe>", "exec"), {{"__name__": "__main__"}})
_lines = [line for line in _captured.getvalue().splitlines() if line.strip()]
if not _lines:
    raise RuntimeError("Core probe payload produced no output")
_payload = json.loads(_lines[-1])
if not isinstance(_payload, dict):
    raise TypeError("Core probe payload must be a JSON object")
_payload["_stemwerk_probe_meta"] = {{
    "core_origin": str(pathlib.Path(stemwerk_core.__file__).resolve()),
    "python_executable": str(pathlib.Path(sys.executable).absolute()),
}}
print(json.dumps(_payload))
"""
    payload = _run_probe(python_exe, wrapper, timeout=timeout)
    if "probe_error" in payload:
        return payload
    metadata = payload.pop("_stemwerk_probe_meta", None)
    if not isinstance(metadata, dict):
        return {"probe_error": "Core probe returned no identity metadata"}
    actual_core = Path(str(metadata.get("core_origin") or "")).resolve()
    if actual_core != expected_core.resolve():
        return {
            "probe_error": (
                f"Core origin mismatch: expected {expected_core.resolve()}, got {actual_core}"
            )
        }
    actual_python = Path(str(metadata.get("python_executable") or "")).absolute()
    if os.path.normcase(str(actual_python)) != os.path.normcase(str(expected_python)):
        return {
            "probe_error": (
                f"interpreter identity mismatch: expected {expected_python}, got {actual_python}"
            )
        }
    payload["core_origin"] = str(actual_core)
    payload["python_executable"] = str(actual_python)
    return payload


# ---------------------------------------------------------------------------
# Runtime-imports evidence (payload + profiles moved verbatim from
# tools/stemwerk_runtime_diagnostics.py; the harness imports them back).
# ---------------------------------------------------------------------------

_RUNTIME_PROBE_SRC = r"""
import importlib
import json
from importlib.metadata import version as pkg_version

result = {"imports": {}}
modules = {}
for module_name in (
    "audio_separator",
    "numpy",
    "onnx",
    "onnx2torch",
    "onnxruntime",
    "stemwerk_core",
    "torch",
    "torchaudio",
    "torchvision",
):
    try:
        modules[module_name] = importlib.import_module(module_name)
        result["imports"][module_name] = {"ok": True}
    except Exception as exc:
        result["imports"][module_name] = {
            "ok": False,
            "error": "%s: %s" % (type(exc).__name__, exc),
        }

torch = modules.get("torch")
if torch is not None:
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
else:
    result["torch_version"] = None
    result["torch_cuda_available"] = None
    result["torch_cuda_version"] = None
    result["torch_hip_version"] = None
    result["torch_cuda_device_count"] = None
    result["torch_cuda_device_names"] = []
    result["torch_mps_built"] = None
    result["torch_mps_available"] = None

for module_name, key in (
    ("torchaudio", "torchaudio_version"),
    ("torchvision", "torchvision_version"),
    ("numpy", "numpy_version"),
    ("onnx", "onnx_version"),
):
    module = modules.get(module_name)
    result[key] = getattr(module, "__version__", None) if module is not None else None

try:
    result["audio_separator_version"] = pkg_version("audio-separator")
except Exception:
    result["audio_separator_version"] = None

onnxruntime = modules.get("onnxruntime")
if onnxruntime is not None:
    result["onnxruntime_version"] = getattr(onnxruntime, "__version__", None)
    try:
        result["onnxruntime_providers"] = list(onnxruntime.get_available_providers())
    except Exception:
        result["onnxruntime_providers"] = []
else:
    result["onnxruntime_version"] = None
    result["onnxruntime_providers"] = []

print(json.dumps(result))
"""

_RUNTIME_REQUIRED_IMPORTS = {
    "main": ("audio_separator", "numpy", "onnxruntime", "stemwerk_core", "torch", "torchaudio"),
    # Mirrors audio_separator_process._verify_drumsep_runtime. onnx2torch is
    # intentionally optional there and remains optional here.
    "drumsep": ("audio_separator", "numpy", "onnx", "onnxruntime", "torch"),
}


def evaluate_required_imports(
    data: Dict[str, Any], runtime_profile: str
) -> "tuple[Dict[str, str], list, str, str]":
    """Shared verdict evaluation for a runtime-imports probe payload.

    Returns ``(failures, required_imports, status, reason)``. Used by both
    the diagnostics harness (report shaping) and Core readiness collection,
    so the two never disagree on what a passing runtime-imports check is.
    """

    required_imports = _RUNTIME_REQUIRED_IMPORTS.get(runtime_profile)
    if required_imports is None:
        return {}, [], FAIL, f"unknown runtime profile: {runtime_profile}"

    failures: Dict[str, str] = {}
    imports = data.get("imports")
    if not isinstance(imports, dict):
        imports = {}
    for module_name in required_imports:
        evidence = imports.get(module_name)
        if not isinstance(evidence, dict):
            failures[module_name] = "no import evidence"
        elif evidence.get("ok") is not True:
            failures[module_name] = str(evidence.get("error") or "import did not succeed")

    if "probe_error" in data:
        return failures, list(required_imports), FAIL, f"runtime probe failed: {data['probe_error']}"
    if failures:
        return failures, list(required_imports), FAIL, "required package import validation failed"
    return failures, list(required_imports), PASS, ""


def collect_runtime_imports(
    python_exe: Optional[Path], *, source_label: str, runtime_profile: str = "main"
) -> Dict[str, Any]:
    """Readiness-shaped runtime-imports evidence for one interpreter."""

    evidence = {
        "source": "collected",
        "evidence_kind": "required_imports",
        "runtime_source": source_label,
    }
    if python_exe is None:
        return {
            "verdict": UNAVAILABLE,
            "reason": f"no {source_label} interpreter found",
            "evidence": evidence,
        }
    data = dict(_run_core_probe(python_exe, _RUNTIME_PROBE_SRC))
    failures, required, status, reason = evaluate_required_imports(data, runtime_profile)
    result = {
        "verdict": status,
        "evidence": {
            **evidence,
            "python_executable": str(python_exe),
            "core_origin": data.get("core_origin"),
            "runtime_profile": runtime_profile,
            "required_imports": required,
            "failed_required_imports": failures,
        },
    }
    if reason:
        result["reason"] = reason
    if status == FAIL and "probe_error" not in data:
        result.setdefault("reason", "required package import validation failed")
    return result


# ---------------------------------------------------------------------------
# DrumSep runtime/backend resolution evidence
# ---------------------------------------------------------------------------

SELECTOR_PROVENANCE = "core_select_drumsep_runtime"

_DRUMSEP_SELECTION_PROBE_SRC = r"""
import json
from pathlib import Path

from stemwerk_core import drumsep_runtime

try:
    selected, runtime_kind, selection_info = drumsep_runtime.select_drumsep_runtime(
        %(requested)r,
        Path(%(runtime_base)r) if %(runtime_base)r else None,
    )
    result = {
        "selected_python": str(selected) if selected is not None else "",
        "runtime_kind": runtime_kind,
        "selection_info": selection_info,
    }
except Exception as exc:
    result = {"error": "%%s: %%s" %% (type(exc).__name__, exc)}

print(json.dumps(result, sort_keys=True))
"""


_CUDA_DEVICE_IDENTITIES_PROBE_SRC = r"""
import json

from stemwerk_core.readiness_collect import _stable_device_identity

result = {"device_identities": []}
try:
    import torch
    if not bool(torch.cuda.is_available()):
        raise RuntimeError("Torch CUDA namespace is unavailable")
    for index in range(int(torch.cuda.device_count())):
        result["device_identities"].append({
            "id": "cuda:%d" % index,
            "name": str(torch.cuda.get_device_name(index)),
            "identity": _stable_device_identity(torch.cuda.get_device_properties(index)),
        })
except Exception as exc:
    result["error"] = "%s: %s" % (type(exc).__name__, exc)

print(json.dumps(result, sort_keys=True))
"""


def collect_drum_kit_resolution(
    requested_device: str,
    python_exe: Optional[Path],
    *,
    source_label: str,
    runtime_base: Optional[Path] = None,
) -> Dict[str, Any]:
    """Collect selector, capability, and selected-runtime import evidence."""

    evidence = {
        "source": "collected",
        "evidence_kind": "production_selector_result",
        "runtime_source": source_label,
        "selector_provenance": SELECTOR_PROVENANCE,
    }
    if python_exe is None:
        unavailable = {
            "verdict": UNAVAILABLE,
            "reason": f"no {source_label} interpreter found",
            "evidence": evidence,
        }
        return {"capability": unavailable, "runtime": dict(unavailable)}

    src = _DRUMSEP_SELECTION_PROBE_SRC % {
        "requested": str(requested_device or "auto"),
        "runtime_base": str(runtime_base) if runtime_base is not None else "",
    }
    data = _run_core_probe(python_exe, src, timeout=DRUMSEP_RUNTIME_SELECTION_TIMEOUT_SECONDS)
    error = data.get("probe_error") or data.get("error")
    if error:
        capability = {
            "verdict": FAIL,
            "reason_code": "runtime_evidence_broken",
            "reason": f"DrumSep runtime selection probe failed: {error}",
            "evidence": {
                **evidence,
                "python_executable": str(python_exe),
                "core_origin": data.get("core_origin"),
            },
        }
        runtime = {
            "verdict": UNAVAILABLE,
            "reason_code": "runtime_evidence_broken",
            "reason": "DrumSep selection supplied no interpreter",
            "evidence": {
                "source": "collected",
                "evidence_kind": "required_imports",
                "runtime_source": "managed_drumsep",
                "runtime_profile": "drumsep",
            },
        }
        return {"capability": capability, "runtime": runtime}

    runtime_kind = str(data.get("runtime_kind") or "")
    selected_text = str(data.get("selected_python") or "")
    raw_info = data.get("selection_info")
    if not isinstance(raw_info, dict):
        raw_info = {}
    raw_info = dict(raw_info)
    resolved = (
        runtime_kind
        if selected_text and runtime_kind in device_policy.DRUMSEP_RUNTIME_KINDS
        else "unavailable"
    )
    resolved_device_id = resolved
    resolved_device_name = resolved
    resolved_device_identity: Dict[str, str] = {}
    indexed_device_error = ""
    indexed_device_reason_code = "backend_unavailable"
    identity_probe_error = ""
    if resolved in {"cuda", "rocm"}:
        identity_data = _run_core_probe(
            Path(selected_text), _CUDA_DEVICE_IDENTITIES_PROBE_SRC
        )
        identity_probe_error = str(
            identity_data.get("probe_error") or identity_data.get("error") or ""
        )
        raw_identities = identity_data.get("device_identities")
        device_identities = (
            [dict(item) for item in raw_identities if isinstance(item, dict)]
            if isinstance(raw_identities, list)
            else []
        )
        raw_info["device_identities"] = device_identities
        execution = next(
            (
                item
                for item in device_identities
                if str(item.get("id") or "").strip().lower() == "cuda:0"
            ),
            {},
        )
        resolved_device_id = "cuda:0"
        resolved_device_name = str(execution.get("name") or "").strip()
        raw_identity = execution.get("identity")
        if isinstance(raw_identity, dict):
            resolved_device_identity = {
                str(key): str(value)
                for key, value in raw_identity.items()
                if str(value).strip()
            }
        if not resolved_device_name:
            selector_names = raw_info.get("device_names") or []
            if isinstance(selector_names, list) and selector_names:
                resolved_device_name = str(selector_names[0])
        raw_info.update(
            {
                "execution_device_id": resolved_device_id,
                "execution_device_name": resolved_device_name,
                "execution_device_identity": resolved_device_identity,
            }
        )

    indexed_match = re.fullmatch(
        r"cuda:(\d+)", str(requested_device or "auto").strip().lower()
    )
    if indexed_match and resolved in {"cuda", "rocm"}:
        requested_index = int(indexed_match.group(1))
        device_names = raw_info.get("device_names") or []
        if not isinstance(device_names, list):
            device_names = []
        device_names = [str(name) for name in device_names]
        if not device_names:
            device_names = [str(item.get("name") or "") for item in device_identities]
        raw_info.update(
            {
                "requested_device_id": str(requested_device),
                "requested_device_index": requested_index,
                "execution_device_id": resolved_device_id,
                "execution_device_name": resolved_device_name,
                "execution_device_identity": resolved_device_identity,
                "requested_device_index_preserved": (
                    requested_index == 0
                    and bool(resolved_device_name.strip())
                    and _has_stable_device_identity(resolved_device_identity)
                ),
            }
        )
        if requested_index >= len(device_names) or not device_names[requested_index].strip():
            indexed_device_error = (
                f"requested DrumSep device {str(requested_device)!r} is not available "
                f"in the selected {resolved} runtime"
            )
        elif requested_index != 0:
            indexed_device_reason_code = "execution_contract_unsupported"
            indexed_device_error = (
                f"requested DrumSep device {str(requested_device)!r} cannot be preserved: "
                "the existing execution handoff uses cuda:0"
            )
        elif not _has_stable_device_identity(resolved_device_identity):
            indexed_device_reason_code = "runtime_evidence_broken"
            detail = f": {identity_probe_error}" if identity_probe_error else ""
            indexed_device_error = (
                "selected DrumSep runtime supplied no stable identity for "
                f"execution device cuda:0{detail}"
            )
    resolution = {
        "requested": str(requested_device or "auto"),
        "resolved_device_id": resolved_device_id,
        "resolved_device_name": resolved_device_name,
        "resolved_backend": resolved,
        "resolved_device_identity": resolved_device_identity,
        "selection_info": raw_info,
    }
    if resolved == "unavailable":
        detail = str(raw_info.get("detail") or runtime_kind or "malformed selector result")
        reason_code = (
            "runtime_evidence_missing"
            if runtime_kind == "missing"
            else "runtime_evidence_broken"
        )
        capability = {
            "verdict": FAIL,
            "reason_code": reason_code,
            "reason": f"production DrumSep runtime selection found no usable runtime: {detail}",
            "resolution": resolution,
            "evidence": {
                **evidence,
                "python_executable": str(python_exe),
                "core_origin": data.get("core_origin"),
            },
        }
        runtime = {
            "verdict": UNAVAILABLE,
            "reason_code": reason_code,
            "reason": f"no usable DrumSep interpreter ({runtime_kind or 'malformed'})",
            "evidence": {
                "source": "collected",
                "evidence_kind": "required_imports",
                "runtime_source": "managed_drumsep",
                "runtime_profile": "drumsep",
            },
        }
        return {"capability": capability, "runtime": runtime}

    selected_python = Path(selected_text)
    capability = {
        "verdict": FAIL if indexed_device_error else PASS,
        "resolution": resolution,
        "evidence": {
            **evidence,
            "python_executable": str(selected_python),
            "selector_python_executable": str(data.get("python_executable") or python_exe),
            "core_origin": data.get("core_origin"),
        },
    }
    if indexed_device_error:
        capability["reason_code"] = indexed_device_reason_code
        capability["reason"] = indexed_device_error
    runtime = collect_runtime_imports(
        selected_python, source_label="managed_drumsep", runtime_profile="drumsep"
    )
    return {"capability": capability, "runtime": runtime}


# The selector can inspect several ordered runtime families and each candidate
# retains its established 120-second cold-import bound. This aggregate guard
# bounds the subprocess without imposing a shorter policy on valid fallback
# chains.
DRUMSEP_RUNTIME_SELECTION_TIMEOUT_SECONDS = 60 * 60


def build_drum_kit_collector(
    runtime_base: Optional[Path] = None,
) -> "Callable[[str], Dict[str, Any]]":
    """Build the client-neutral live DrumSep collector used by all clients."""

    def collect(requested_device: str) -> Dict[str, Any]:
        managed = managed_runtime.managed_runtime_python()
        python_exe = managed if managed is not None else Path(sys.executable)
        source_label = "managed" if managed is not None else "ambient"
        return collect_drum_kit_resolution(
            requested_device,
            python_exe,
            source_label=source_label,
            runtime_base=runtime_base,
        )

    return collect


# ---------------------------------------------------------------------------
# Normal-Stems device/backend resolution evidence
# ---------------------------------------------------------------------------

_NORMAL_RESOLUTION_PROBE_SRC = r"""
import json
import pathlib

from stemwerk_core.readiness_collect import _stable_device_identity

requested_text = %(requested)r
probe_evidence = {
    "torch_import": {"status": "NOT_RUN"},
    "availability": {"status": "NOT_RUN"},
    "enumeration": {"status": "NOT_RUN"},
    "requested_device": {"id": requested_text, "available": False},
}
result = {"probe_evidence": probe_evidence}
try:
    import torch
except Exception as exc:
    probe_evidence["torch_import"] = {
        "status": "FAIL",
        "error_type": type(exc).__name__,
        "error": str(exc)[:500],
    }
    result["error"] = "torch_import_failed: %%s: %%s" %% (type(exc).__name__, exc)
else:
    probe_evidence["torch_import"] = {
        "status": "PASS",
        "module_origin": str(pathlib.Path(torch.__file__).resolve()),
        "version": str(getattr(torch, "__version__", "")),
        "cuda_build": getattr(getattr(torch, "version", None), "cuda", None),
        "hip_build": getattr(getattr(torch, "version", None), "hip", None),
    }
    try:
        cuda_available = bool(torch.cuda.is_available())
    except Exception as exc:
        probe_evidence["availability"] = {
            "status": "FAIL",
            "error_type": type(exc).__name__,
            "error": str(exc)[:500],
        }
        result["error"] = "torch_availability_failed: %%s: %%s" %% (type(exc).__name__, exc)
    else:
        probe_evidence["availability"] = {
            "status": "PASS",
            "cuda_namespace_available": cuda_available,
        }
        if not cuda_available:
            probe_evidence["enumeration"] = {
                "status": "NOT_APPLICABLE",
                "device_count": 0,
                "devices": [],
            }
        else:
            try:
                device_count = int(torch.cuda.device_count())
                observed_devices = []
                for index in range(device_count):
                    observed_devices.append({
                        "id": "cuda:%%d" %% index,
                        "name": str(torch.cuda.get_device_name(index)),
                        "identity": _stable_device_identity(
                            torch.cuda.get_device_properties(index)
                        ),
                    })
            except Exception as exc:
                probe_evidence["enumeration"] = {
                    "status": "FAIL",
                    "error_type": type(exc).__name__,
                    "error": str(exc)[:500],
                }
                result["error"] = "torch_enumeration_failed: %%s: %%s" %% (type(exc).__name__, exc)
            else:
                probe_evidence["enumeration"] = {
                    "status": "PASS",
                    "device_count": device_count,
                    "devices": observed_devices,
                }

if "error" not in result:
    try:
        from stemwerk_core import devices, device_policy
        result["available_devices"] = devices.get_available_devices()
        skips = getattr(devices, "_DEVICE_SKIPS", None) or []
        result["device_skips"] = [dict(item) for item in skips]
        requested, resolved, preview, live_ids = device_policy.resolve_normal_runtime_device(requested_text)
        requested_normalized = str(requested or "auto").strip().lower()
        requested_available = requested_normalized in {str(item).strip().lower() for item in live_ids}
        if requested_normalized in {"cuda", "directml"}:
            requested_available = any(
                str(item).strip().lower().startswith(requested_normalized + ":")
                for item in live_ids
            )
        probe_evidence["requested_device"] = {
            "id": requested,
            "available": requested_available,
        }
        preview_id, _, preview_name = preview.partition("|")
        result["requested"] = requested
        result["resolved_device_id"] = preview_id
        result["resolved_device_name"] = preview_name
        result["resolved_backend"] = devices.runtime_kind_for_device(preview_id)
        resolved_evidence = next(
            (
                item
                for item in probe_evidence["enumeration"].get("devices", [])
                if item.get("id") == preview_id
            ),
            {},
        )
        result["resolved_device_identity"] = resolved_evidence.get("identity") or {}
    except Exception as exc:
        result["error"] = "device_policy_failed: %%s: %%s" %% (type(exc).__name__, exc)

print(json.dumps(result))
"""


def collect_normal_stems_resolution(
    requested_device: str,
    python_exe: Optional[Path],
    *,
    source_label: str,
) -> Dict[str, Any]:
    """Run the real Normal-Stems selection policy inside the intended
    interpreter and return the fully resolved snapshot.

    The policy itself (``stemwerk_core.device_policy.resolve_normal_runtime_device``)
    executes in the subprocess; this process only receives its result, so no
    selection logic is re-derived here and no Torch/GPU library is loaded
    into this process.
    """

    evidence = {
        "source": "collected",
        "evidence_kind": "real_probe_resolution",
        "runtime_source": source_label,
    }
    if python_exe is None:
        return {
            "verdict": UNAVAILABLE,
            "reason": f"no {source_label} interpreter found",
            "evidence": evidence,
        }
    src = _NORMAL_RESOLUTION_PROBE_SRC % {"requested": str(requested_device or "auto")}
    data = _run_core_probe(python_exe, src)
    probe_evidence = data.get("probe_evidence")
    if not isinstance(probe_evidence, dict):
        probe_evidence = {
            "protocol": {
                "status": FAIL,
                "error": "probe returned no structured device evidence",
            }
        }
    error = data.get("probe_error") or data.get("error")
    if error:
        return {
            "verdict": FAIL,
            "reason": f"device resolution probe failed: {error}",
            "evidence": {
                **evidence,
                "python_executable": str(python_exe),
                "core_origin": data.get("core_origin"),
                "probe_evidence": probe_evidence,
            },
        }
    required_keys = ("resolved_device_id", "resolved_device_name", "resolved_backend")
    if not all(key in data for key in required_keys):
        return {
            "verdict": UNAVAILABLE,
            "reason": "device resolution probe returned insufficient capability evidence",
            "evidence": {
                **evidence,
                "python_executable": str(python_exe),
                "core_origin": data.get("core_origin"),
                "probe_evidence": probe_evidence,
            },
        }
    resolution = {
        "requested": data.get("requested") or str(requested_device or "auto"),
        "resolved_device_id": str(data["resolved_device_id"]),
        "resolved_device_name": str(data["resolved_device_name"]),
        "resolved_backend": str(data["resolved_backend"]),
        "resolved_device_identity": dict(data.get("resolved_device_identity") or {}),
        "available_devices": data.get("available_devices") or [],
        "device_skips": data.get("device_skips") or [],
    }
    result = {
        "verdict": PASS,
        "resolution": resolution,
        "evidence": {
            **evidence,
            "python_executable": str(data["python_executable"]),
            "core_origin": str(data["core_origin"]),
            "probe_evidence": probe_evidence,
        },
    }
    requested_evidence = probe_evidence.get("requested_device") or {}
    if requested_evidence.get("available") is False:
        requested = str(requested_evidence.get("id") or requested_device or "auto")
        result.update(
            {
                "verdict": FAIL,
                "reason_code": "backend_unavailable",
                "reason": f"requested device {requested!r} is not available",
            }
        )
    return result


# ---------------------------------------------------------------------------
# FFmpeg evidence: candidate discovery is read-only path enumeration;
# usability requires a bounded ``-version`` execution -- a path existing on
# disk is never treated as usable FFmpeg.
# ---------------------------------------------------------------------------

_FFMPEG_PROBE_TIMEOUT_SECONDS = 10


def collect_ffmpeg() -> Dict[str, Any]:
    evidence = {
        "source": "collected",
        "evidence_kind": "ffmpeg_usability_probe",
        "runtime_source": "local",
    }
    candidates = managed_runtime.candidate_ffmpeg_paths()
    present: list[str] = []
    for candidate in candidates:
        try:
            if not candidate.exists() or candidate.is_dir():
                continue
        except Exception:
            continue
        present.append(str(candidate))
        try:
            proc = subprocess.run(
                [str(candidate), "-version"],
                capture_output=True, text=True,
                timeout=_FFMPEG_PROBE_TIMEOUT_SECONDS,
            )
        except Exception:
            continue
        if proc.returncode == 0 and (proc.stdout or "").startswith("ffmpeg"):
            return {
                "verdict": PASS,
                "path": str(candidate),
                "evidence": {
                    **evidence,
                    "candidates_checked": len(present),
                    "usability": "executed_version_probe",
                },
            }
    if present:
        return {
            "verdict": FAIL,
            "reason": "ffmpeg candidates exist but none executed -version successfully",
            "evidence": {**evidence, "candidates_present": present},
        }
    return {
        "verdict": UNAVAILABLE,
        "reason": "no ffmpeg candidate found",
        "evidence": {**evidence, "candidates_checked": len(candidates)},
    }
