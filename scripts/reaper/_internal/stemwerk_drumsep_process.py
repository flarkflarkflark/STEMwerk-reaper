#!/usr/bin/env python3
"""Isolated DrumSep stage2 helper for STEMwerk Direct Drum Kit Split."""

from __future__ import annotations

import argparse
import contextlib
import importlib.metadata as metadata
import inspect
import json
import os
import shutil
import sys
import traceback
import yaml
from pathlib import Path
from typing import Any
import time


EXPECTED_STEMS = ("kick", "snare", "toms", "hihat", "ride", "crash")
REAPER_FILENAMES = {
    "kick": "kick.wav",
    "snare": "snare.wav",
    "toms": "toms.wav",
    "hihat": "hi-hat.wav",
    "ride": "ride.wav",
    "crash": "crash.wav",
}
DIRECT_DEMIX_KEYS = ("Kick", "Snare", "Toms", "Hh", "Ride", "Crash")


class DirectDemixValidationError(RuntimeError):
    def __init__(self, reason: str, message: str):
        super().__init__(message)
        self.reason = reason


def _probe_gpu_device(device: str) -> tuple[bool, str, dict[str, str]]:
    requested = str(device or "").strip().lower()
    if requested not in {"cuda", "rocm"}:
        return True, "not_requested", {}
    try:
        import torch

        hip = str(getattr(torch.version, "hip", "") or "")
        cuda_version = str(getattr(torch.version, "cuda", "") or "")
        available = bool(torch.cuda.is_available())
        if requested == "rocm" and not hip:
            return False, "rocm_no_hip", {"torch_hip": hip, "torch_cuda": cuda_version}
        if requested == "cuda" and hip:
            return False, "cuda_runtime_is_rocm", {"torch_hip": hip, "torch_cuda": cuda_version}
        if not available:
            return False, "torch_cuda_unavailable", {"torch_hip": hip, "torch_cuda": cuda_version}
        tensor = torch.ones(1, device="cuda:0")
        return True, "ok", {
            "torch_hip": hip,
            "torch_cuda": cuda_version,
            "tensor_device": str(tensor.device),
            "device_name": str(torch.cuda.get_device_name(0)),
        }
    except Exception as exc:
        return False, f"{type(exc).__name__}:{exc}", {}


def normalize_stem_name(value: str | Path) -> str | None:
    text = Path(value).stem if isinstance(value, Path) else str(value or "")
    normalized = "".join(ch for ch in text.lower() if ch.isalnum())
    if "kick" in normalized:
        return "kick"
    if "snare" in normalized:
        return "snare"
    if "toms" in normalized or normalized.endswith("tom") or "tomtom" in normalized:
        return "toms"
    if normalized in {"hh", "hihat", "hat"} or "hihat" in normalized or "hihat" in normalized.replace("hh", "hihat"):
        return "hihat"
    if "ride" in normalized:
        return "ride"
    if "crash" in normalized:
        return "crash"
    return None


def _json_default(value: Any) -> str:
    return str(value)


def write_result(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True, default=_json_default) + "\n", encoding="utf-8")


def _candidate_paths(output_dir: Path, raw_outputs: Any, before: set[Path]) -> list[Path]:
    candidates: list[Path] = []
    if isinstance(raw_outputs, (list, tuple, set)):
        for item in raw_outputs:
            try:
                p = Path(str(item))
            except Exception:
                continue
            if not p.is_absolute():
                p = output_dir / p
            candidates.append(p)

    for p in sorted(output_dir.glob("*.wav")):
        if p.resolve() not in before:
            candidates.append(p)

    unique: list[Path] = []
    seen: set[str] = set()
    for p in candidates:
        key = str(p.resolve())
        if key not in seen:
            seen.add(key)
            unique.append(p)
    return unique


def normalize_outputs(output_dir: Path, raw_outputs: Any, before: set[Path]) -> tuple[dict[str, str], list[str]]:
    stems: dict[str, str] = {}
    raw_paths: list[str] = []
    for path in _candidate_paths(output_dir, raw_outputs, before):
        raw_paths.append(str(path))
        stem_key = normalize_stem_name(path)
        if not stem_key:
            continue
        if not path.exists():
            continue
        target = output_dir / REAPER_FILENAMES[stem_key]
        if path.resolve() != target.resolve():
            if target.exists():
                target.unlink()
            shutil.move(str(path), str(target))
        stems[stem_key] = str(target)
    return stems, raw_paths


def _error_payload(reason: str, stage: str, message: str, **extra: Any) -> dict[str, Any]:
    payload = {
        "ok": False,
        "error_stage": stage,
        "error_reason": reason,
        "message": message,
    }
    payload.update(extra)
    return payload


def _emit_output_count_markers(expected_count: int, actual_count: int, mismatch: bool) -> None:
    print(f"expected_drum_outputs={expected_count}", file=sys.stderr)
    print(f"actual_drum_outputs={actual_count}", file=sys.stderr)
    if mismatch:
        print("output_count_mismatch=yes", file=sys.stderr)


def _model_download_checks_path(model_dir: Path) -> Path:
    return model_dir / "download_checks.json"


def _resolve_model_yaml_path(model_dir: Path, model_name: str) -> tuple[Path | None, str]:
    checks_path = _model_download_checks_path(model_dir)
    try:
        checks = json.loads(checks_path.read_text(encoding="utf-8"))
    except Exception:
        checks = {}
    mdx23c = checks.get("mdx23c_download_list") if isinstance(checks, dict) else {}
    if isinstance(mdx23c, dict):
        for _entry_name, entry in mdx23c.items():
            if not isinstance(entry, dict):
                continue
            yaml_name = entry.get(model_name)
            if yaml_name:
                return model_dir / str(yaml_name), "download_checks"
    yaml_candidates = sorted(model_dir.glob("*.yaml"))
    if len(yaml_candidates) == 1:
        return yaml_candidates[0], "single_yaml_fallback"
    named = model_dir / (Path(model_name).stem + ".yaml")
    if named.exists():
        return named, "named_fallback"
    return None, "missing"


def _load_model_metadata(model_dir: Path, model_name: str) -> dict[str, Any]:
    yaml_path, yaml_resolution = _resolve_model_yaml_path(model_dir, model_name)
    payload: dict[str, Any] = {
        "yaml_path": str(yaml_path) if yaml_path else "",
        "yaml_resolution": yaml_resolution,
        "yaml_top_level_keys": [],
        "training_instruments": [],
        "target_instrument": "",
        "expected_stems": list(EXPECTED_STEMS),
    }
    if not yaml_path or not yaml_path.exists():
        return payload
    try:
        data = yaml.load(yaml_path.read_text(encoding="utf-8"), Loader=yaml.FullLoader)
    except Exception as exc:
        payload["yaml_error"] = f"{type(exc).__name__}: {exc}"
        return payload
    if not isinstance(data, dict):
        payload["yaml_error"] = f"unexpected_yaml_type:{type(data).__name__}"
        return payload
    payload["yaml_top_level_keys"] = sorted(str(key) for key in data.keys())
    training = data.get("training") if isinstance(data.get("training"), dict) else {}
    instruments = training.get("instruments") if isinstance(training.get("instruments"), list) else []
    payload["training_instruments"] = [str(item) for item in instruments if str(item).strip()]
    payload["target_instrument"] = str(training.get("target_instrument") or "")
    return payload


def _runtime_two_stem_limit_reason(found_stems: list[str], model_meta: dict[str, Any]) -> str:
    training_instruments = model_meta.get("training_instruments") if isinstance(model_meta, dict) else []
    if not isinstance(training_instruments, list):
        training_instruments = []
    if len(training_instruments) < 3:
        return ""
    normalized = {normalize_stem_name(name) for name in training_instruments}
    normalized.discard(None)
    found_set = {str(name) for name in found_stems}
    if found_set == {"kick", "snare"} and {"kick", "snare"}.issubset(normalized):
        return "audio_separator_mdxc_runtime_primary_secondary_only"
    return ""


def _ordered_found_stems(stems: dict[str, Any]) -> list[str]:
    return [name for name in EXPECTED_STEMS if name in stems]


def _distribution_version(name: str) -> str:
    try:
        return metadata.version(name)
    except Exception:
        return ""


def _direct_demix_model_device(separator: Any) -> str:
    try:
        model_run = separator.model_instance.model_run
        parameter = next(model_run.parameters())
        return str(parameter.device)
    except Exception:
        return "unknown"


def _apply_separator_requested_device(separator: Any, requested_device: str) -> None:
    requested = str(requested_device or "").strip().lower()
    if requested == "cpu":
        cpu_device = getattr(separator, "torch_device_cpu", None)
        setattr(separator, "torch_device", cpu_device or "cpu")
        setattr(separator, "onnx_execution_provider", ["CPUExecutionProvider"])
        return
    if requested == "mps":
        mps_device = getattr(separator, "torch_device_mps", None)
        setattr(separator, "torch_device", mps_device or "mps")
        return


def _observability_requested_device(args: argparse.Namespace) -> str:
    requested = str(getattr(args, "requested_device", "") or "").strip()
    if requested:
        return requested
    return str(getattr(args, "device", "") or "").strip()


def _observability_backend_runtime(args: argparse.Namespace) -> str:
    backend = str(getattr(args, "backend_runtime", "") or "").strip()
    if backend:
        return backend
    return str(getattr(args, "device", "") or "").strip()


def _validate_direct_demix_sources(sources: Any) -> dict[str, Any]:
    if not isinstance(sources, dict):
        raise DirectDemixValidationError(
            "direct_demix_not_dict",
            f"MDXCSeparator.demix() returned {type(sources).__name__}, expected dict",
        )

    normalized_sources: dict[str, Any] = {}
    raw_keys: list[str] = []
    unknown_keys: list[str] = []
    for raw_key, value in sources.items():
        raw_name = str(raw_key)
        raw_keys.append(raw_name)
        normalized = normalize_stem_name(raw_name)
        if normalized not in EXPECTED_STEMS:
            unknown_keys.append(raw_name)
            continue
        if normalized in normalized_sources:
            raise DirectDemixValidationError(
                "duplicate_normalized_stem",
                f"Multiple direct-demix keys normalize to {normalized}",
            )
        normalized_sources[normalized] = value

    if unknown_keys:
        raise DirectDemixValidationError(
            "unknown_direct_demix_keys",
            "Unknown direct-demix keys: " + ",".join(sorted(unknown_keys)),
        )

    expected_raw = set(DIRECT_DEMIX_KEYS)
    found_raw = set(raw_keys)
    missing_raw = sorted(expected_raw - found_raw)
    extra_raw = sorted(found_raw - expected_raw)
    if missing_raw:
        raise DirectDemixValidationError(
            "missing_direct_demix_keys",
            "Missing direct-demix keys: " + ",".join(missing_raw),
        )
    if extra_raw:
        raise DirectDemixValidationError(
            "unknown_direct_demix_keys",
            "Unknown direct-demix keys: " + ",".join(extra_raw),
        )
    if set(normalized_sources) != set(EXPECTED_STEMS):
        raise DirectDemixValidationError(
            "partial_direct_demix_kit",
            "Direct-demix result did not normalize to the complete six-part kit",
        )
    return normalized_sources


def _direct_demix_frames_channels(array: Any) -> Any:
    import numpy as np

    data = np.asarray(array)
    if data.ndim == 1:
        data = data.reshape((-1, 1))
    elif data.ndim == 2:
        if data.shape[0] in {1, 2} and data.shape[1] > data.shape[0]:
            data = data.T
        elif data.shape[1] not in {1, 2}:
            raise DirectDemixValidationError(
                "invalid_output_channel_count",
                f"Unsupported direct-demix array shape {tuple(data.shape)}",
            )
    else:
        raise DirectDemixValidationError(
            "invalid_output_shape",
            f"Unsupported direct-demix array shape {tuple(data.shape)}",
        )
    if data.shape[0] <= 0:
        raise DirectDemixValidationError("empty_output", "Direct-demix output has no frames")
    if data.shape[1] not in {1, 2}:
        raise DirectDemixValidationError(
            "invalid_output_channel_count",
            f"Direct-demix output has {data.shape[1]} channels",
        )
    if not np.isfinite(data).all():
        raise DirectDemixValidationError("invalid_output_samples", "Direct-demix output contains non-finite samples")
    return data


def _validate_written_audio(path: Path, expected_sample_rate: int, expected_frames: int, expected_channels: int) -> None:
    import soundfile as sf

    try:
        info = sf.info(str(path))
    except Exception as exc:
        raise DirectDemixValidationError(
            "unreadable_output",
            f"Could not read output {path}: {type(exc).__name__}: {exc}",
        ) from exc
    if int(info.samplerate or 0) != expected_sample_rate or expected_sample_rate <= 0:
        raise DirectDemixValidationError(
            "invalid_output_sample_rate",
            f"Output {path} sample rate is {info.samplerate}, expected {expected_sample_rate}",
        )
    if int(info.frames or 0) != expected_frames or expected_frames <= 0:
        raise DirectDemixValidationError(
            "invalid_output_frame_count",
            f"Output {path} frames are {info.frames}, expected {expected_frames}",
        )
    if int(info.channels or 0) != expected_channels or expected_channels not in {1, 2}:
        raise DirectDemixValidationError(
            "invalid_output_channel_count",
            f"Output {path} channels are {info.channels}, expected {expected_channels}",
        )
    if not path.exists() or path.stat().st_size <= 44:
        raise DirectDemixValidationError("empty_output", f"Output {path} is empty")


def _validate_direct_demix_device(separator: Any, expected_device: str) -> str:
    requested = str(expected_device or "").strip().lower()
    effective_device = str(getattr(separator, "torch_device", "")).lower()
    model_device = _direct_demix_model_device(separator)
    model_device_lower = model_device.lower()
    if requested == "mps":
        if effective_device != "mps":
            raise DirectDemixValidationError(
                "effective_device_not_mps",
                f"Separator device is {getattr(separator, 'torch_device', 'unknown')}",
            )
        if not model_device_lower.startswith("mps"):
            raise DirectDemixValidationError(
                "model_device_not_mps",
                f"Model device is {model_device}",
            )
        return model_device
    if requested == "cpu":
        if effective_device != "cpu":
            raise DirectDemixValidationError(
                "effective_device_not_cpu",
                f"Separator device is {getattr(separator, 'torch_device', 'unknown')}",
            )
        if not model_device_lower.startswith("cpu"):
            raise DirectDemixValidationError(
                "model_device_not_cpu",
                f"Model device is {model_device}",
            )
        return model_device
    raise DirectDemixValidationError("unsupported_direct_demix_device", f"Unsupported direct-demix device {expected_device}")


def _run_drumsep_all_targets_direct_demix(
    separator: Any,
    input_path: Path,
    output_dir: Path,
    model_metadata: dict[str, Any],
    device: str,
) -> dict[str, str]:
    del model_metadata
    import soundfile as sf
    from audio_separator.separator.uvr_lib_v5 import spec_utils

    fallback_value = os.environ.get("PYTORCH_ENABLE_MPS_FALLBACK")
    requested_device = str(device or "").strip().lower()
    if requested_device == "mps" and fallback_value is not None:
        raise DirectDemixValidationError(
            "pytorch_mps_fallback_env_set",
            "PYTORCH_ENABLE_MPS_FALLBACK must be unset for direct-demix",
        )
    _validate_direct_demix_device(separator, requested_device)

    model = separator.model_instance
    mix = model.prepare_mix(str(input_path))
    mix = spec_utils.normalize(
        wave=mix,
        max_peak=separator.normalization_threshold,
        min_peak=separator.amplification_threshold,
    )
    normalized_sources = _validate_direct_demix_sources(model.demix(mix=mix))
    sample_rate = int(getattr(separator, "sample_rate", 0) or 0)
    if sample_rate <= 0:
        raise DirectDemixValidationError("invalid_output_sample_rate", f"Invalid sample rate {sample_rate}")

    stems: dict[str, str] = {}
    for stem_name in EXPECTED_STEMS:
        data = _direct_demix_frames_channels(normalized_sources[stem_name])
        target = output_dir / REAPER_FILENAMES[stem_name]
        try:
            sf.write(str(target), data, sample_rate)
        except Exception as exc:
            raise DirectDemixValidationError(
                "output_write_failed",
                f"Could not write {target}: {type(exc).__name__}: {exc}",
            ) from exc
        _validate_written_audio(target, sample_rate, int(data.shape[0]), int(data.shape[1]))
        stems[stem_name] = str(target)
    if set(stems) != set(EXPECTED_STEMS):
        raise DirectDemixValidationError("partial_direct_demix_kit", "Not all six canonical outputs were written")
    return stems


def _run_drumsep_mps_all_targets_direct_demix(
    separator: Any,
    input_path: Path,
    output_dir: Path,
    model_metadata: dict[str, Any],
) -> dict[str, str]:
    return _run_drumsep_all_targets_direct_demix(separator, input_path, output_dir, model_metadata, "mps")


def run(args: argparse.Namespace) -> int:
    input_path = Path(args.input).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    model_dir = Path(args.model_dir).expanduser().resolve()
    result_json = Path(args.result_json).expanduser().resolve()
    model_name = str(args.model)

    output_dir.mkdir(parents=True, exist_ok=True)
    before = {p.resolve() for p in output_dir.glob("*.wav")}

    try:
        print(f"timing_utc={time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime())} drumsep_helper_imports_start", file=sys.stderr)
        from audio_separator.separator import Separator
        print(f"timing_utc={time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime())} drumsep_helper_imports_done", file=sys.stderr)
    except Exception as exc:
        write_result(result_json, _error_payload("drumsep_helper_failed", "stage2_runtime", f"{type(exc).__name__}: {exc}"))
        return 1

    gpu_probe_ok, gpu_probe_reason, gpu_probe = _probe_gpu_device(args.device)
    print(f"drumsep_helper_gpu_probe_status={'ok' if gpu_probe_ok else 'failed'}", file=sys.stderr)
    print(f"drumsep_helper_gpu_probe_reason={gpu_probe_reason}", file=sys.stderr)
    print(f"drumsep_helper_gpu_probe_torch_hip={gpu_probe.get('torch_hip', '')}", file=sys.stderr)
    print(f"drumsep_helper_gpu_probe_torch_cuda={gpu_probe.get('torch_cuda', '')}", file=sys.stderr)
    print(f"drumsep_helper_gpu_probe_tensor_device={gpu_probe.get('tensor_device', '')}", file=sys.stderr)
    print(f"drumsep_helper_gpu_probe_device_name={gpu_probe.get('device_name', '')}", file=sys.stderr)
    if not gpu_probe_ok:
        write_result(
            result_json,
            _error_payload(
                "drumsep_helper_gpu_probe_failed",
                "stage2_runtime",
                gpu_probe_reason,
                requested_helper_device=args.device,
                gpu_probe=gpu_probe,
            ),
        )
        return 1

    try:
        print(f"timing_utc={time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime())} drumsep_helper_model_load_start", file=sys.stderr)
        print(f"drumsep_helper_start input={input_path}", file=sys.stderr)
        print(f"drumsep_helper_model_dir={model_dir}", file=sys.stderr)
        print(f"drumsep_helper_model={model_name}", file=sys.stderr)
        print(f"drumsep_helper_output_dir={output_dir}", file=sys.stderr)
        separator_kwargs = {
            "model_file_dir": str(model_dir),
            "output_dir": str(output_dir),
            "output_format": "WAV",
        }
        init_params = inspect.signature(Separator.__init__).parameters
        accepts_var_kwargs = any(param.kind == inspect.Parameter.VAR_KEYWORD for param in init_params.values())
        if "mdx_params" in init_params or accepts_var_kwargs:
            separator_kwargs["mdx_params"] = {"device": str(args.device or "cpu")}
        if "demucs_params" in init_params or accepts_var_kwargs:
            separator_kwargs["demucs_params"] = {"device": str(args.device or "cpu")}
        if "mdxc_params" in init_params or accepts_var_kwargs:
            separator_kwargs["mdxc_params"] = {"device": str(args.device or "cpu")}
        if args.route in {"mps-direct-demix", "direct-demix"}:
            separator_kwargs.update(
                {
                    "output_single_stem": None,
                    "use_soundfile": True,
                    "use_autocast": False,
                }
            )
        sep = Separator(**separator_kwargs)
        if args.route in {"mps-direct-demix", "direct-demix"}:
            _apply_separator_requested_device(sep, str(args.device or "cpu"))
        sep.load_model(model_name)
        print(f"timing_utc={time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime())} drumsep_helper_model_load_end", file=sys.stderr)
    except Exception as exc:
        write_result(
            result_json,
            _error_payload(
                "drumsep_model_load_failed",
                "stage2_model_load",
                f"{type(exc).__name__}: {exc}",
                traceback=traceback.format_exc(),
            ),
        )
        return 1

    model_meta = _load_model_metadata(model_dir, model_name)
    requested_device = _observability_requested_device(args)
    backend_runtime = _observability_backend_runtime(args)
    try:
        print(f"timing_utc={time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime())} drumsep_helper_separate_start", file=sys.stderr)
        if args.route in {"mps-direct-demix", "direct-demix"}:
            if args.device not in {"cpu", "mps"}:
                raise DirectDemixValidationError(
                    "requested_device_not_supported_for_direct_demix",
                    f"Direct-demix requires device cpu or mps, got {args.device}",
                )
            stems = _run_drumsep_all_targets_direct_demix(
                sep,
                input_path,
                output_dir,
                model_meta,
                args.device,
            )
            raw_outputs = list(stems.values())
        else:
            raw_outputs = sep.separate(str(input_path))
            stems, raw_outputs = normalize_outputs(output_dir, raw_outputs, before)
        print(f"timing_utc={time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime())} drumsep_helper_separate_end", file=sys.stderr)
    except Exception as exc:
        validation_reason = getattr(exc, "reason", "")
        if validation_reason:
            print(f"output_validation_reason={validation_reason}", file=sys.stderr)
        write_result(
            result_json,
            _error_payload(
                "drumsep_direct_demix_failed" if args.route in {"mps-direct-demix", "direct-demix"} else "drumsep_separate_failed",
                "stage2_output_validation" if validation_reason else "stage2_separate",
                f"{type(exc).__name__}: {exc}",
                traceback=traceback.format_exc(),
                output_validation_reason=validation_reason,
                expected_stems=list(EXPECTED_STEMS),
                found_stems=[],
                direct_demix_enabled=1 if args.route in {"mps-direct-demix", "direct-demix"} else 0,
                direct_demix_device=str(args.device or "").strip().lower() if args.route in {"mps-direct-demix", "direct-demix"} else "",
                drumsep_direct_demix_route="direct_demix" if args.route in {"mps-direct-demix", "direct-demix"} else "",
                drumsep_mps_all_targets_route="direct_demix" if args.route in {"mps-direct-demix", "direct-demix"} else "",
                backend_runtime=backend_runtime,
                audio_separator_version=_distribution_version("audio-separator"),
                requested_device=requested_device,
                effective_device=str(getattr(sep, "torch_device", "unknown")),
                model_device=_direct_demix_model_device(sep),
            ),
        )
        return 1

    raw_paths = [str(path) for path in raw_outputs]
    expected_count = len(EXPECTED_STEMS)
    actual_count = len(stems)
    missing = [name for name in EXPECTED_STEMS if name not in stems]
    found_stems = _ordered_found_stems(stems)
    validation_reason = _runtime_two_stem_limit_reason(found_stems, model_meta)
    print(f"model_id={model_name}", file=sys.stderr)
    print(f"output_dir={output_dir}", file=sys.stderr)
    print(f"found_stems={','.join(found_stems)}", file=sys.stderr)
    print(f"found_files={'|'.join(raw_paths)}", file=sys.stderr)
    print(f"yaml_path={model_meta.get('yaml_path') or 'missing'}", file=sys.stderr)
    print(f"yaml_resolution={model_meta.get('yaml_resolution') or 'unknown'}", file=sys.stderr)
    print(f"yaml_top_level_keys={','.join(model_meta.get('yaml_top_level_keys') or [])}", file=sys.stderr)
    print(f"yaml_training_instruments={','.join(model_meta.get('training_instruments') or [])}", file=sys.stderr)
    print(f"yaml_target_instrument={model_meta.get('target_instrument') or 'none'}", file=sys.stderr)
    print(f"expected_stems={','.join(EXPECTED_STEMS)}", file=sys.stderr)
    if args.route in {"mps-direct-demix", "direct-demix"}:
        direct_device = str(args.device or "").strip().lower()
        model_device = _direct_demix_model_device(sep)
        print("direct_demix_enabled=1", file=sys.stderr)
        print(f"direct_demix_device={direct_device}", file=sys.stderr)
        print("drumsep_direct_demix_route=direct_demix", file=sys.stderr)
        print("drumsep_mps_all_targets_route=direct_demix", file=sys.stderr)
        print(f"mps_fallback_enabled={0 if direct_device == 'mps' else ''}", file=sys.stderr)
        print(f"pytorch_mps_fallback_env={'unset' if direct_device == 'mps' else ''}", file=sys.stderr)
        print("output_validation_reason=ok", file=sys.stderr)
        print(f"backend_runtime={backend_runtime}", file=sys.stderr)
        print(f"audio_separator_version={_distribution_version('audio-separator')}", file=sys.stderr)
        print(f"requested_device={requested_device}", file=sys.stderr)
        print(f"effective_device={direct_device}", file=sys.stderr)
        print(f"model_device={model_device}", file=sys.stderr)
        print(f"direct_demix_keys={','.join(DIRECT_DEMIX_KEYS)}", file=sys.stderr)
    if validation_reason:
        print(f"output_validation_reason={validation_reason}", file=sys.stderr)
    if missing or len(stems) != len(EXPECTED_STEMS):
        _emit_output_count_markers(expected_count, actual_count, True)
        write_result(
            result_json,
            _error_payload(
                "drumsep_output_count_mismatch",
                "stage2_output_validation",
                f"expected {expected_count} stems, got {actual_count}",
                stems=stems,
                missing=missing,
                raw_outputs=raw_paths,
                expected_drum_outputs=expected_count,
                actual_drum_outputs=actual_count,
                expected_stems=list(EXPECTED_STEMS),
                found_stems=found_stems,
                found_files=raw_paths,
                output_dir=str(output_dir),
                model_id=model_name,
                yaml_path=model_meta.get("yaml_path") or "",
                yaml_resolution=model_meta.get("yaml_resolution") or "",
                yaml_top_level_keys=model_meta.get("yaml_top_level_keys") or [],
                yaml_training_instruments=model_meta.get("training_instruments") or [],
                yaml_target_instrument=model_meta.get("target_instrument") or "",
                output_validation_reason=validation_reason,
                output_count_mismatch=True,
            ),
        )
        return 1

    _emit_output_count_markers(expected_count, actual_count, False)
    write_result(
        result_json,
        {
            "ok": True,
            "stems": stems,
            "raw_outputs": raw_paths,
            "expected_drum_outputs": expected_count,
            "actual_drum_outputs": actual_count,
            "output_count_mismatch": False,
            "direct_demix_enabled": 1 if args.route in {"mps-direct-demix", "direct-demix"} else 0,
            "direct_demix_device": str(args.device or "").strip().lower() if args.route in {"mps-direct-demix", "direct-demix"} else "",
            "drumsep_direct_demix_route": "direct_demix" if args.route in {"mps-direct-demix", "direct-demix"} else "",
            "drumsep_mps_all_targets_route": "direct_demix" if args.route in {"mps-direct-demix", "direct-demix"} else "",
            "mps_fallback_enabled": 0 if args.route in {"mps-direct-demix", "direct-demix"} and str(args.device or "").strip().lower() == "mps" else "",
            "pytorch_mps_fallback_env": "unset" if args.route in {"mps-direct-demix", "direct-demix"} and str(args.device or "").strip().lower() == "mps" else "",
            "output_validation_reason": "ok",
            "expected_stems": list(EXPECTED_STEMS),
            "found_stems": found_stems,
            "backend_runtime": backend_runtime,
            "audio_separator_version": _distribution_version("audio-separator"),
            "requested_device": requested_device,
            "effective_device": str(getattr(sep, "torch_device", "unknown")),
            "model_device": _direct_demix_model_device(sep),
            "direct_demix_keys": list(DIRECT_DEMIX_KEYS) if args.route in {"mps-direct-demix", "direct-demix"} else [],
        },
    )
    print("drumsep_helper_ok=true", file=sys.stderr)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Run DrumSep MDX23C in the isolated STEMwerk DrumSep runtime.")
    parser.add_argument("--input", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--model-dir", required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--result-json", required=True)
    parser.add_argument("--log-file", default="")
    parser.add_argument("--route", choices=["wrapper", "mps-direct-demix", "direct-demix"], default="wrapper")
    parser.add_argument("--device", choices=["cpu", "cuda", "rocm", "mps"], default="cpu")
    parser.add_argument("--requested-device", default="")
    parser.add_argument("--backend-runtime", default="")
    args = parser.parse_args()

    if args.log_file:
        log_path = Path(args.log_file).expanduser().resolve()
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with log_path.open("a", encoding="utf-8", errors="replace") as log_fh:
            with contextlib.redirect_stderr(log_fh):
                return run(args)
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
