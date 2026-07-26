from __future__ import annotations

import inspect
import os
import sys
import threading
import time
import warnings
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Dict, Optional, Sequence, Tuple, Union
import yaml

from .devices import select_device
from .models import resolve_audio_separator_model_id, resolve_model_name
from .progress import ProgressCallback


def _pkg_version(dist_name: str) -> Optional[str]:
    """Return installed version for a distribution name (best-effort)."""
    try:
        try:
            from importlib.metadata import version
        except Exception:
            from importlib_metadata import version  # type: ignore
        return version(dist_name)
    except Exception:
        return None


def _has_torch_directml() -> bool:
    try:
        import torch_directml  # noqa: F401

        return True
    except Exception:
        return False


def _has_onnxruntime_directml_provider() -> bool:
    try:
        import onnxruntime as ort

        return "DmlExecutionProvider" in (ort.get_available_providers() or [])
    except Exception:
        return False


def _resolve_directml_device(device_id: str) -> Tuple[str, bool, int]:
    dml_index = 0
    if ":" in device_id:
        try:
            dml_index = int(device_id.split(":")[1])
        except Exception:
            dml_index = 0

    try:
        import torch_directml  # noqa: F401
        return f"privateuseone:{dml_index}", True, dml_index
    except Exception:
        ort_dml = (
            _pkg_version("onnxruntime-directml")
            or _pkg_version("onnxruntime-gpu")
            or _pkg_version("onnxruntime")
        )
        if ort_dml:
            warnings.warn(
                "DirectML requested but torch-directml not installed; using ONNX Runtime DirectML."
            )
            return f"privateuseone:{dml_index}", True, dml_index
        warnings.warn(
            "DirectML requested but neither torch-directml nor onnxruntime-directml are installed; using CPU."
        )
        return "cpu", False, dml_index


QUALITY_PRESETS = {"fast": 0, "normal": 1, "best": 2}
DEFAULT_QUALITY = "normal"
MPS_DEMUCS_SEGMENT_SIZE = 2

_SEPARATOR_CACHE: Dict[Tuple[str, str, bool, int, Union[int, str]], Any] = {}
_SEPARATOR_CACHE_LOCK = threading.Lock()
DEMUCS_MODEL_ALIASES = {"htdemucs", "htdemucs_ft", "htdemucs_6s", "hdemucs_mmi"}


def _default_model_cache_dir() -> str:
    override = os.environ.get("AUDIO_SEPARATOR_MODEL_DIR")
    if override:
        return override

    home = Path.home()
    if os.name == "nt":
        local_appdata = os.environ.get("LOCALAPPDATA")
        if local_appdata:
            return str(Path(local_appdata) / "STEMwerk" / "models")
        return str(home / "AppData" / "Local" / "STEMwerk" / "models")

    if sys.platform == "darwin":
        return str(home / "Library" / "Application Support" / "STEMwerk" / "models")

    xdg_data_home = os.environ.get("XDG_DATA_HOME")
    if xdg_data_home:
        return str(Path(xdg_data_home) / "STEMwerk" / "models")
    return str(home / ".local" / "share" / "STEMwerk" / "models")


def _is_demucs_model_alias(model_name: Optional[str]) -> bool:
    candidate = str(model_name or "").strip().lower()
    if not candidate:
        return False
    return Path(candidate).stem in DEMUCS_MODEL_ALIASES


def _supported_model_contains(supported_model_files_grouped: Dict[str, Any], requested_name: str) -> bool:
    requested = str(requested_name or "").strip()
    if not requested:
        return False
    for model_list in supported_model_files_grouped.values():
        if not isinstance(model_list, dict):
            continue
        for model_download_list in model_list.values():
            if isinstance(model_download_list, str):
                if model_download_list == requested:
                    return True
                continue
            if not isinstance(model_download_list, dict):
                continue
            for file_name, file_url in model_download_list.items():
                if file_name == requested or file_url == requested:
                    return True
    return False


def _resolve_audio_separator_model_name(separator: Any, model_name: str) -> str:
    requested = str(model_name or "").strip()
    if not _is_demucs_model_alias(requested):
        return requested
    preferred = resolve_audio_separator_model_id(requested)

    supported_model_files_grouped: Dict[str, Any] = {}
    try:
        supported = separator.list_supported_model_files()
        if isinstance(supported, dict):
            supported_model_files_grouped = supported
    except Exception:
        supported_model_files_grouped = {}

    if _supported_model_contains(supported_model_files_grouped, preferred):
        return preferred

    model_file_dir = Path(str(getattr(separator, "model_file_dir", "") or _default_model_cache_dir()))
    if (model_file_dir / preferred).is_file():
        warnings.warn(
            f"Demucs identifier '{requested}' is absent from the audio-separator catalog; using local asset '{preferred}'."
        )
        return preferred

    return preferred


def _should_load_local_demucs_asset(requested_model_name: str, resolved_model_name: str, separator: Any) -> bool:
    if not _is_demucs_model_alias(requested_model_name):
        return False
    candidate = str(resolved_model_name or "").strip()
    if not candidate.lower().endswith(".yaml"):
        return False
    model_file_dir = Path(str(getattr(separator, "model_file_dir", "") or _default_model_cache_dir()))
    return (model_file_dir / candidate).is_file()


def _load_local_demucs_asset(separator: Any, requested_model_name: str, resolved_model_name: str) -> None:
    from audio_separator.separator.architectures.demucs_separator import DemucsSeparator

    model_file_dir = Path(str(getattr(separator, "model_file_dir", "") or _default_model_cache_dir()))
    model_path = (model_file_dir / str(resolved_model_name or "").strip()).resolve()
    model_data = yaml.safe_load(model_path.read_text(encoding="utf-8")) or {}
    common_params = {
        "logger": separator.logger,
        "log_level": separator.log_level,
        "torch_device": separator.torch_device,
        "torch_device_cpu": separator.torch_device_cpu,
        "torch_device_mps": separator.torch_device_mps,
        "onnx_execution_provider": separator.onnx_execution_provider,
        "model_name": Path(str(requested_model_name or "")).stem,
        "model_path": str(model_path),
        "model_data": model_data,
        "output_format": separator.output_format,
        "output_bitrate": separator.output_bitrate,
        "output_dir": separator.output_dir,
        "normalization_threshold": separator.normalization_threshold,
        "amplification_threshold": separator.amplification_threshold,
        "output_single_stem": separator.output_single_stem,
        "invert_using_spec": separator.invert_using_spec,
        "sample_rate": separator.sample_rate,
        "use_soundfile": separator.use_soundfile,
    }
    separator.model_instance = DemucsSeparator(
        common_config=common_params,
        arch_config=separator.arch_specific_params["Demucs"],
    )
    separator.model_friendly_name = f"Demucs local asset: {Path(str(requested_model_name or '')).stem}"


def _processing_downloads_disabled() -> bool:
    value = os.environ.get("STEMWERK_PROCESSING_MAY_DOWNLOAD", "")
    return value.strip().lower() in {"0", "false", "no"}


def _disable_separator_downloads(separator: Any) -> None:
    def blocked_download(model_filename: str):
        raise RuntimeError(
            "processing_download_blocked: required model asset is not installed; run STEMwerk Setup Repair"
        )

    try:
        separator.download_model_files = blocked_download
    except Exception:
        pass


@dataclass(frozen=True)
class SeparationResult:
    """Result of a stem separation run."""

    stems: Dict[str, Path]
    device_used: str
    elapsed: float


class StemSeparator:
    """High-level wrapper around audio-separator for stem separation."""

    def __init__(self, model: str = "htdemucs", device: str = "auto", quality: str = DEFAULT_QUALITY) -> None:
        self.model = model
        self.device = device
        normalized_quality = (quality or DEFAULT_QUALITY).strip().lower()
        if normalized_quality not in QUALITY_PRESETS:
            raise ValueError(f"Unknown quality preset '{quality}'. Use one of {sorted(QUALITY_PRESETS)}.")
        self.quality = normalized_quality
        self.on_progress: Optional[ProgressCallback] = None
        self.on_phase: Optional[Callable[[str], None]] = None

    def _emit_progress(self, percent: float, message: str) -> None:
        callback = self.on_progress
        if callback is None:
            return
        try:
            callback(percent, message)
        except Exception:
            pass

    def _emit_phase(self, phase_name: str) -> None:
        callback = self.on_phase
        if callback is None:
            return
        try:
            callback(phase_name)
        except Exception:
            pass

    def _get_separator(
        self,
        model_name: str,
        separator_device: str,
        use_directml: bool,
    ) -> Tuple[Any, bool, str, bool]:
        from audio_separator.separator import Separator

        init_params = inspect.signature(Separator.__init__).parameters
        legacy_directml_mode = False
        if use_directml and "use_directml" not in init_params:
            legacy_directml_mode = str(separator_device).startswith("privateuseone") and _has_torch_directml()
            if legacy_directml_mode:
                warnings.warn(
                    "Installed audio-separator build lacks the explicit DirectML flag; using legacy torch-directml compatibility mode."
                )
            else:
                warnings.warn(
                    "Installed audio-separator build does not support DirectML; falling back to CPU."
                )
                separator_device = "cpu"
                use_directml = False

        quality_shift = QUALITY_PRESETS[self.quality]
        segment_size: Union[int, str] = (
            MPS_DEMUCS_SEGMENT_SIZE if str(separator_device) == "mps" else "Default"
        )
        cache_key = (
            model_name,
            str(separator_device),
            bool(use_directml),
            int(quality_shift),
            segment_size,
        )
        with _SEPARATOR_CACHE_LOCK:
            separator = _SEPARATOR_CACHE.get(cache_key)
            if separator is not None:
                return separator, False, str(separator_device), bool(use_directml)

            kwargs: Dict[str, Any] = {
                "output_dir": ".",
                "output_format": "WAV",
                "normalization_threshold": 0.9,
                "log_level": 10,
                "mdx_params": {"device": separator_device},
            }
            model_cache_dir = _default_model_cache_dir()
            os.environ["AUDIO_SEPARATOR_MODEL_DIR"] = model_cache_dir
            if "model_file_dir" in init_params:
                kwargs["model_file_dir"] = model_cache_dir
            if "use_soundfile" in init_params:
                kwargs["use_soundfile"] = True
            if "use_directml" in init_params:
                kwargs["use_directml"] = use_directml
            if "demucs_params" in init_params:
                kwargs["demucs_params"] = {
                    "device": separator_device,
                    "segment_size": segment_size,
                    "shifts": quality_shift,
                    "overlap": 0.25,
                    "segments_enabled": True,
                }

            separator = Separator(**kwargs)
            if _processing_downloads_disabled():
                _disable_separator_downloads(separator)
            if legacy_directml_mode and _has_onnxruntime_directml_provider():
                try:
                    separator.onnx_execution_provider = ["DmlExecutionProvider"]
                except Exception:
                    pass
            _SEPARATOR_CACHE[cache_key] = separator
            return separator, True, str(separator_device), bool(use_directml)

    def _set_separator_output(self, separator: Any, output_path: Path) -> None:
        separator.output_dir = str(output_path)
        if getattr(separator, "model_instance", None) is not None:
            separator.model_instance.output_dir = str(output_path)

    def separate(
        self,
        input_file: Union[str, Path],
        output_dir: Union[str, Path],
        stems: Optional[Sequence[str]] = None,
    ) -> SeparationResult:
        """Separate an audio file into stems."""
        start_time = time.time()
        input_path = Path(input_file)
        output_path = Path(output_dir)

        if not input_path.exists():
            raise FileNotFoundError(f"Input file not found: {input_path}")

        output_path.mkdir(parents=True, exist_ok=True)
        model_name = resolve_model_name(self.model)

        self._emit_progress(0.0, "Initializing")
        # Closest safe model/backend setup wrapper: device selection, separator
        # construction/cache lookup, and optional audio-separator load_model().
        self._emit_phase("model_setup_start")

        if str(self.device).lower() == "cpu":
            for key in ("CUDA_VISIBLE_DEVICES", "HIP_VISIBLE_DEVICES", "ROCR_VISIBLE_DEVICES"):
                os.environ[key] = ""

        import torch

        device_id, device_name = select_device(self.device)

        if isinstance(device_id, str) and device_id.startswith("cuda:"):
            try:
                idx = int(device_id.split(":")[1])
                torch.cuda.set_device(idx)
            except Exception as exc:
                warnings.warn(f"Failed to set CUDA device '{device_id}': {exc}")

        if device_id == "cpu":
            separator_device = "cpu"
            use_directml = False
            dml_index = 0
        elif device_id == "mps":
            separator_device = "mps"
            use_directml = False
            dml_index = 0
        elif device_id == "directml" or (
            isinstance(device_id, str) and device_id.startswith("directml:")
        ):
            separator_device, use_directml, dml_index = _resolve_directml_device(device_id)
        else:
            separator_device = device_id
            use_directml = False
            dml_index = 0

        if use_directml:
            os.environ["ORT_DML_DEFAULT_DEVICE_ID"] = str(dml_index)

        separator, created, separator_device, use_directml = self._get_separator(
            model_name,
            str(separator_device),
            use_directml,
        )

        effective_device_id = device_id
        effective_device_name = device_name
        if not use_directml and (device_id == "directml" or str(device_id).startswith("directml:")):
            effective_device_id = "cpu"
            effective_device_name = "CPU"

        if use_directml:
            try:
                import torch_directml

                separator.torch_device = torch_directml.device(dml_index)
                separator.torch_device_dml = separator.torch_device
            except Exception as exc:
                warnings.warn(f"Failed to force DirectML device: {exc}")
        elif effective_device_id == "cpu":
            try:
                separator.torch_device = torch.device("cpu")
            except Exception:
                pass

        self._emit_progress(1.0, f"Initializing [{effective_device_name}]")

        if created:
            loading_done = threading.Event()

            def loading_progress_thread() -> None:
                start = time.time()
                while not loading_done.is_set():
                    elapsed = time.time() - start
                    progress_ratio = 1 - (0.5 ** (elapsed / 15))
                    percent = int(1 + progress_ratio * 9)
                    percent = min(10, percent)

                    if elapsed < 60:
                        self._emit_progress(percent, f"Loading model ({elapsed:.0f}s) [{effective_device_name}]")
                    else:
                        mins = int(elapsed) // 60
                        secs = int(elapsed) % 60
                        self._emit_progress(percent, f"Loading model ({mins}:{secs:02d}) [{effective_device_name}]")

                    loading_done.wait(0.4)

            loading_worker = threading.Thread(target=loading_progress_thread, daemon=True)
            loading_worker.start()

            self._emit_progress(3.0, f"Loading AI model [{effective_device_name}]")

            audio_ver = _pkg_version("audio-separator") or ""
            demucs_name = model_name[:-5] if str(model_name).endswith(".yaml") else str(model_name)
            if audio_ver.startswith("0.14") and demucs_name in {"htdemucs", "htdemucs_ft", "htdemucs_6s", "hdemucs_mmi"}:
                warnings.warn(
                    f"audio-separator {audio_ver} treats Demucs identifiers as UVR models; skipping load_model('{demucs_name}')."
                )
            else:
                load_model_name = model_name
                try:
                    load_model_name = _resolve_audio_separator_model_name(separator, model_name)
                    if _should_load_local_demucs_asset(model_name, load_model_name, separator):
                        separator.logger.info(
                            f"Loading local Demucs asset {load_model_name} for model {Path(str(model_name)).stem}..."
                        )
                        _load_local_demucs_asset(separator, model_name, load_model_name)
                    else:
                        separator.load_model(load_model_name)
                except Exception as exc:
                    msg = str(exc).lower()
                    fallback = model_name
                    if str(load_model_name).lower().endswith(".yaml"):
                        fallback = str(Path(str(load_model_name)).stem)
                    elif str(model_name).endswith(".yaml"):
                        fallback = model_name[:-5]
                    if fallback and ("unsupported model file" in msg or "uvr model data" in msg):
                        warnings.warn(
                            f"Model '{load_model_name}' was rejected by audio-separator; retrying as '{fallback}'."
                        )
                        try:
                            separator.load_model(fallback)
                        except Exception:
                            audio_ver = _pkg_version("audio-separator") or ""
                            if fallback == "htdemucs_ft" and audio_ver.startswith("0.14"):
                                warnings.warn(
                                    "audio-separator 0.14.x does not support htdemucs_ft; falling back to htdemucs."
                                )
                                separator.load_model("htdemucs")
                            else:
                                raise
                    else:
                        raise

            loading_done.set()
            loading_worker.join(timeout=1.0)
        else:
            self._emit_progress(6.0, f"Using cached model [{effective_device_name}]")

        self._set_separator_output(separator, output_path)
        self._emit_phase("model_setup_end")

        self._emit_progress(11.0, f"Starting separation [{effective_device_name}]")

        duration_seconds = 0.0
        try:
            import soundfile as sf

            info = sf.info(str(input_path))
            duration_seconds = float(info.duration)
        except Exception:
            duration_seconds = 180.0

        if effective_device_id == "cpu":
            estimated_time = duration_seconds * 4.0
        else:
            estimated_time = duration_seconds * 0.5

        processing_done = threading.Event()

        def progress_thread() -> None:
            start = time.time()
            last_percent = 11
            while not processing_done.is_set():
                elapsed = time.time() - start
                if estimated_time > 0:
                    progress_ratio = 1 - (0.5 ** (elapsed / estimated_time))
                    percent = int(12 + progress_ratio * 76)
                else:
                    percent = min(88, int(12 + elapsed * 2))

                percent = min(88, max(last_percent, percent))
                last_percent = percent

                mins_elapsed = int(elapsed) // 60
                secs_elapsed = int(elapsed) % 60

                if percent > 15:
                    progress_fraction = (percent - 12) / 78.0
                    if progress_fraction > 0.05:
                        total_est = elapsed / progress_fraction
                        remaining = max(0.0, total_est - elapsed)
                        mins_remaining = int(remaining) // 60
                        secs_remaining = int(remaining) % 60
                        eta_str = f" | ETA {mins_remaining}:{secs_remaining:02d}"
                    else:
                        eta_str = ""
                else:
                    eta_str = ""

                self._emit_progress(
                    percent,
                    f"Processing ({mins_elapsed}:{secs_elapsed:02d}{eta_str}) [{effective_device_name}]",
                )
                processing_done.wait(0.3)

        progress_worker = threading.Thread(target=progress_thread, daemon=True)
        progress_worker.start()

        self._emit_phase("separate_start")
        try:
            output_files = separator.separate(str(input_path)) or []
        finally:
            processing_done.set()
            progress_worker.join(timeout=1.0)
            self._emit_phase("separate_end")

        self._emit_progress(92.0, "Writing stems")

        result: Dict[str, Path] = {}
        stem_mapping = {
            "vocals": ["vocals", "vocal", "Vocals"],
            "drums": ["drums", "drum", "Drums"],
            "bass": ["bass", "Bass"],
            "other": ["other", "Other", "no_vocals", "instrumental", "Instrumental"],
            "guitar": ["guitar", "Guitar"],
            "piano": ["piano", "Piano", "keys", "Keys"],
        }

        for output_file in output_files:
            output_file = Path(output_file)
            if not output_file.is_absolute():
                output_file = output_path / output_file

            filename = output_file.stem.lower()
            matched = False
            for stem_name, patterns in stem_mapping.items():
                for pattern in patterns:
                    if pattern.lower() in filename:
                        result[stem_name] = output_file
                        matched = True
                        break
                if matched:
                    break

        if stems:
            allowed = {stem.lower() for stem in stems}
            result = {name: path for name, path in result.items() if name.lower() in allowed}

        self._emit_progress(100.0, "Complete")

        elapsed = time.time() - start_time
        return SeparationResult(stems=result, device_used=str(effective_device_id), elapsed=elapsed)
