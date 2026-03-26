#!/home/flark/STEMwerk/.venv/bin/python -u
"""
Audio Separator Script for STEMwerk
Thin wrapper around stemwerk-core for REAPER.

Progress output (stdout):
    PROGRESS:<percent>:<stage>
    Example: PROGRESS:45:Processing chunk 3/8
"""

import argparse
from contextlib import contextmanager
import importlib
import importlib.util
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Dict, List, Optional, Set

StemSeparator = None
get_available_devices = None
select_device = None
core_devices = None
_core_loaded = False


def _require_core() -> None:
    global StemSeparator, get_available_devices, select_device, core_devices, _core_loaded
    if _core_loaded:
        return
    try:
        from stemwerk_core import StemSeparator as _StemSeparator
        from stemwerk_core import get_available_devices as _get_available_devices
        from stemwerk_core import select_device as _select_device
        from stemwerk_core import devices as _core_devices
    except Exception as exc:
        raise ModuleNotFoundError(
            "stemwerk_core is required for this operation. Install with: pip install stemwerk-core"
        ) from exc

    StemSeparator = _StemSeparator
    get_available_devices = _get_available_devices
    select_device = _select_device
    core_devices = _core_devices
    _core_loaded = True


class _TeeTextIO:
    def __init__(self, *streams):
        self._streams = [s for s in streams if s is not None]

    def write(self, s):
        for st in self._streams:
            try:
                st.write(s)
            except Exception:
                pass
        return len(s)

    def flush(self):
        for st in self._streams:
            try:
                st.flush()
            except Exception:
                pass


_progress_file = None


@contextmanager
def _working_directory(path: Path):
    previous = Path.cwd()
    os.chdir(path)
    try:
        yield
    finally:
        os.chdir(previous)


def _resolve_stem_path(output_dir: Path, stem_path: Path | str) -> Path:
    path = Path(stem_path)
    if path.is_absolute():
        return path
    return output_dir / path


def _setup_reaper_io(output_dir: Optional[str]):
    """If output_dir is set, write progress/log/done markers into that folder."""
    global _progress_file
    if not output_dir:
        return None

    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)
    stdout_path = out / "stdout.txt"
    stderr_path = out / "separation_log.txt"
    done_path = out / "done.txt"

    stdout_f = open(stdout_path, "w", encoding="utf-8", buffering=1)
    stderr_f = open(stderr_path, "w", encoding="utf-8", buffering=1)
    _progress_file = stdout_f

    sys.stderr = _TeeTextIO(sys.stderr, stderr_f)

    def write_done(status: str):
        try:
            done_path.write_text(status + "\n", encoding="utf-8")
        except Exception:
            pass

    return write_done


def _read_simple_env_file(path: Path) -> Dict[str, str]:
    values: Dict[str, str] = {}
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return values
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"')
        if key:
            values[key] = value
    return values


def _candidate_ffmpeg_paths() -> List[Path]:
    candidates: List[Path] = []
    seen: Set[str] = set()

    def add(path_value: Optional[str | Path]) -> None:
        if not path_value:
            return
        try:
            path = Path(path_value).expanduser()
        except Exception:
            return
        key = str(path).lower()
        if key in seen:
            return
        seen.add(key)
        candidates.append(path)

    ffmpeg_env = os.environ.get("FFMPEG_PATH") or os.environ.get("IMAGEIO_FFMPEG_EXE")
    add(ffmpeg_env)

    local_appdata = os.environ.get("LOCALAPPDATA")
    if local_appdata:
        runtime_base = Path(local_appdata) / "STEMwerk"
        add(runtime_base / "ffmpeg" / "bin" / "ffmpeg.exe")
        add(runtime_base / "ffmpeg" / "ffmpeg.exe")
        add(runtime_base / "bin" / "ffmpeg.exe")
        bootstrap_values = _read_simple_env_file(runtime_base / "state" / "bootstrap.env")
        add(bootstrap_values.get("FFMPEG_PATH"))
        capabilities_values = _read_simple_env_file(runtime_base / "state" / "capabilities.env")
        add(capabilities_values.get("FFMPEG_PATH"))

    exe_dir = Path(sys.executable).resolve().parent
    add(exe_dir / "ffmpeg.exe")
    add(exe_dir.parent / "ffmpeg" / "bin" / "ffmpeg.exe")

    found = shutil.which("ffmpeg")
    add(found)

    return candidates


def _configure_ffmpeg_runtime() -> Optional[Path]:
    for candidate in _candidate_ffmpeg_paths():
        try:
            if not candidate.exists() or candidate.is_dir():
                continue
        except Exception:
            continue

        candidate_str = str(candidate)
        candidate_dir = str(candidate.parent)
        current_path = os.environ.get("PATH", "")
        path_parts = current_path.split(os.pathsep) if current_path else []
        normalized_dir = candidate_dir.lower()
        if normalized_dir not in {part.lower() for part in path_parts if part}:
            os.environ["PATH"] = candidate_dir + (os.pathsep + current_path if current_path else "")
        os.environ["FFMPEG_PATH"] = candidate_str
        os.environ["IMAGEIO_FFMPEG_EXE"] = candidate_str
        return candidate
    return None


def _default_model_cache_dir() -> Path:
    override = os.environ.get("AUDIO_SEPARATOR_MODEL_DIR")
    if override:
        return Path(override).expanduser()

    home = Path.home()
    if os.name == "nt":
        local_appdata = os.environ.get("LOCALAPPDATA")
        if local_appdata:
            return Path(local_appdata) / "STEMwerk" / "models"
        return home / "AppData" / "Local" / "STEMwerk" / "models"

    if sys.platform == "darwin":
        return home / "Library" / "Application Support" / "STEMwerk" / "models"

    xdg_data_home = os.environ.get("XDG_DATA_HOME")
    if xdg_data_home:
        return Path(xdg_data_home) / "STEMwerk" / "models"
    return home / ".local" / "share" / "STEMwerk" / "models"


def _configure_model_cache_runtime() -> Path:
    model_dir = _default_model_cache_dir()
    try:
        model_dir.mkdir(parents=True, exist_ok=True)
    except Exception:
        pass
    os.environ["AUDIO_SEPARATOR_MODEL_DIR"] = str(model_dir)
    return model_dir


def emit_progress(percent: float, stage: str = ""):
    """Output progress in machine-readable format for Lua to parse."""
    line = f"PROGRESS:{int(percent)}:{stage}\n"
    global _progress_file
    if _progress_file is not None:
        try:
            _progress_file.write(line)
            _progress_file.flush()
        except Exception:
            pass
    try:
        sys.stdout.write(line)
        sys.stdout.flush()
    except Exception:
        pass


def _split_list(value: Optional[str]) -> List[str]:
    if not value:
        return []
    text = str(value)
    for sep in (";", "\n", "\t", " "):
        text = text.replace(sep, ",")
    return [part.strip() for part in text.split(",") if part.strip()]


def _get_device_skips() -> List[Dict[str, str]]:
    _require_core()
    skips = getattr(core_devices, "_DEVICE_SKIPS", None)
    if not skips:
        return []
    return [dict(item) for item in skips]


def _get_skip_ids() -> Set[str]:
    ids: Set[str] = set()
    for s in _get_device_skips():
        sid = s.get("id", "")
        if sid:
            ids.add(sid)
    return ids


def _prefer_linux_amd_device(devices: List[Dict[str, str]], skip_ids: Set[str]) -> Optional[Dict[str, str]]:
    if not devices:
        return None
    candidates = [d for d in devices if d.get("id") not in skip_ids]
    if not candidates:
        return None

    def score(dev: Dict[str, str]) -> int:
        name = (dev.get("name") or "").lower()
        sc = 0
        if "radeon rx" in name or " rx " in name or name.startswith("rx "):
            sc += 3
        if "radeon" in name and "graphics" not in name:
            sc += 1
        if "graphics" in name and "rx" not in name:
            sc -= 1
        if "780m" in name:
            sc -= 2
        return sc

    return max(candidates, key=score)


def _clean_env() -> Dict[str, str]:
    env = dict(os.environ)
    for key in ("HIP_VISIBLE_DEVICES", "HSA_OVERRIDE_GFX_VERSION", "ROCR_VISIBLE_DEVICES", "CUDA_VISIBLE_DEVICES"):
        env.pop(key, None)
    return env

def _run_cmd_lines(cmd: List[str]) -> List[str]:
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.STDOUT, text=True, env=_clean_env())
    except Exception:
        return []
    return [line.strip() for line in out.splitlines() if line.strip()]


def _filter_rocm_lines(lines: List[str]) -> List[str]:
    keep: List[str] = []
    for line in lines:
        if re.search(r"(Marketing Name|Name:|gfx\d+|Device Type|Vendor Name)", line):
            keep.append(line.strip())
    return keep


def _get_rocm_host_lines() -> List[str]:
    lines: List[str] = []
    if shutil.which("rocminfo"):
        lines.extend(_filter_rocm_lines(_run_cmd_lines(["rocminfo"])))
    if shutil.which("rocm-smi"):
        smi = _run_cmd_lines(["rocm-smi"])
        for line in smi:
            if "GPU" in line or "gfx" in line or "Device" in line:
                lines.append(line)
    seen: Set[str] = set()
    out: List[str] = []
    for line in lines:
        if line not in seen:
            out.append(line)
            seen.add(line)
    return out


def _emit_env_diagnostics() -> None:
    keys = [
        "ROCM_PATH",
        "LD_LIBRARY_PATH",
        "HIP_VISIBLE_DEVICES",
        "HSA_OVERRIDE_GFX_VERSION",
        "ROCR_VISIBLE_DEVICES",
        "CUDA_VISIBLE_DEVICES",
    ]
    for key in keys:
        val = os.environ.get(key)
        if val is not None and val != "":
            print(f"STEMWERK_ENV\t{key}={val}")
        else:
            print(f"STEMWERK_ENV\t{key}=")


def _build_env_json() -> Dict[str, object]:
    env: Dict[str, object] = {
        "platform": platform.system(),
        "python": platform.python_version(),
        "sys_executable": sys.executable,
        "pythonpath_env": os.environ.get("PYTHONPATH"),
        "ld_library_path_env": os.environ.get("LD_LIBRARY_PATH"),
        "torch": None,
        "torch_file": None,
        "cuda_available": False,
        "cuda_count": 0,
        "mps_available": False,
        "directml_possible": importlib.util.find_spec("torch_directml") is not None,
        "rocm_path_exists": False,
        "torch_hip": None,
        "onnxruntime": None,
        "onnxruntime-gpu": None,
        "onnxruntime-directml": None,
        "onnxruntime-silicon": None,
    }

    try:
        env["rocm_path_exists"] = bool(os.path.exists("/opt/rocm") or os.environ.get("ROCM_PATH"))
    except Exception:
        env["rocm_path_exists"] = False

    try:
        import torch

        env["torch"] = getattr(torch, "__version__", str(torch))
        try:
            env["torch_file"] = getattr(torch, "__file__", None)
        except Exception:
            env["torch_file"] = None
        try:
            env["torch_hip"] = getattr(getattr(torch, "version", None), "hip", None)
        except Exception:
            env["torch_hip"] = None
        try:
            env["cuda_available"] = bool(torch.cuda.is_available())
        except Exception:
            env["cuda_available"] = False
        try:
            env["cuda_count"] = int(torch.cuda.device_count()) if env["cuda_available"] else 0
        except Exception:
            env["cuda_count"] = 0
        try:
            env["mps_available"] = bool(
                getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available()
            )
        except Exception:
            env["mps_available"] = False
    except Exception:
        pass

    try:
        try:
            from importlib.metadata import version as dist_version
        except Exception:
            from importlib_metadata import version as dist_version  # type: ignore

        def _dist(name: str) -> Optional[str]:
            try:
                return dist_version(name)
            except Exception:
                return None

        env["onnxruntime"] = _dist("onnxruntime")
        env["onnxruntime-gpu"] = _dist("onnxruntime-gpu")
        env["onnxruntime-directml"] = _dist("onnxruntime-directml")
        env["onnxruntime-silicon"] = _dist("onnxruntime-silicon")
    except Exception:
        pass

    return env


def _log_device_diagnostics(devices: List[Dict[str, str]], env: Dict[str, object]) -> None:
    try:
        ids = [d.get("id", "") for d in devices]
        print(f"STEMWERK_DIAG devices={ids}", file=sys.stderr)
    except Exception:
        pass

    try:
        print(
            "STEMWERK_DIAG cuda_available="
            + str(env.get("cuda_available"))
            + " cuda_count="
            + str(env.get("cuda_count")),
            file=sys.stderr,
        )
    except Exception:
        pass

    try:
        if env.get("cuda_available"):
            import torch

            for i in range(torch.cuda.device_count()):
                print(f"STEMWERK_DIAG cuda_device_{i}={torch.cuda.get_device_name(i)}", file=sys.stderr)
    except Exception:
        pass

    try:
        if env.get("cuda_available"):
            import torch

            for i in range(torch.cuda.device_count()):
                try:
                    props = torch.cuda.get_device_properties(i)
                    info = {
                        "name": props.name,
                        "total_memory": getattr(props, "total_memory", None),
                        "multi_processor_count": getattr(props, "multi_processor_count", None),
                        "major": getattr(props, "major", None),
                        "minor": getattr(props, "minor", None),
                        "gcn_arch": getattr(props, "gcnArchName", None),
                        "pci_bus_id": getattr(props, "pciBusID", None),
                    }
                    print(f"STEMWERK_DIAG cuda_props_{i}={info}", file=sys.stderr)
                except Exception:
                    pass
    except Exception:
        pass


def list_devices_machine(skip_devices: Optional[Set[str]] = None):
    """Machine-readable dump for REAPER/Lua UIs (no JSON parser needed on Lua side)."""
    _require_core()
    devices = get_available_devices()
    if skip_devices:
        devices = [d for d in devices if d.get("id") not in skip_devices]

    print("STEMWERK_DEVICES_BEGIN")
    print("STEMWERK_ENV_BEGIN")
    _emit_env_diagnostics()
    print("STEMWERK_ENV_END")
    print("STEMWERK_HOST_VISIBLE_BEGIN")
    for d in devices:
        print(f"STEMWERK_DEVICE\t{d.get('id','')}\t{d.get('name','')}\t{d.get('type','')}")

    skips = _get_device_skips()
    skip_ids = set()
    for s in skips:
        sid = s.get("id", "")
        sname = s.get("name", "")
        reason = s.get("reason", "")
        reason = str(reason).replace("\t", " ")
        print(f"STEMWERK_DEVICE_SKIPPED\t{sid}\t{sname}\t{reason}")
        if sid:
            skip_ids.add(sid)

    preferred = None
    if sys.platform.startswith("linux"):
        preferred = _prefer_linux_amd_device(devices, skip_ids)
    if preferred:
        print(f"STEMWERK_SELECTED_DEVICE\t{preferred.get('id','')}\t{preferred.get('name','')}")
    else:
        try:
            dev_id, dev_name = select_device("auto")
            print(f"STEMWERK_SELECTED_DEVICE\t{dev_id}\t{dev_name}")
        except Exception:
            pass

    if devices:
        print("STEMWERK_USABLE_BEGIN")
        for d in devices:
            print(f"STEMWERK_USABLE_GPU\t{d.get('id','')}\t{d.get('name','')}\t{d.get('type','')}")
        print("STEMWERK_USABLE_END")

    host_lines = _get_rocm_host_lines()
    for line in host_lines:
        print(f"STEMWERK_HOST_GPU\t{line}")
    print("STEMWERK_HOST_VISIBLE_END")

    env = _build_env_json()
    print("STEMWERK_TORCH_VISIBLE_BEGIN")
    try:
        print(
            "STEMWERK_TORCH_INFO\tver="
            + str(env.get("torch"))
            + "\thip="
            + str(env.get("torch_hip"))
            + "\tcuda_available="
            + str(env.get("cuda_available"))
            + "\tcuda_count="
            + str(env.get("cuda_count")),
        )
    except Exception:
        pass
    try:
        if env.get("cuda_available"):
            import torch

            for i in range(torch.cuda.device_count()):
                print(f"STEMWERK_TORCH_GPU\tcuda:{i}\t{torch.cuda.get_device_name(i)}")
                try:
                    props = torch.cuda.get_device_properties(i)
                    info = {
                        "name": props.name,
                        "total_memory": getattr(props, "total_memory", None),
                        "multi_processor_count": getattr(props, "multi_processor_count", None),
                        "major": getattr(props, "major", None),
                        "minor": getattr(props, "minor", None),
                        "gcn_arch": getattr(props, "gcnArchName", None),
                        "pci_bus_id": getattr(props, "pciBusID", None),
                    }
                    print(f"STEMWERK_TORCH_PROP\tcuda:{i}\t{info}")
                except Exception:
                    pass
    except Exception:
        pass
    print("STEMWERK_TORCH_VISIBLE_END")
    _log_device_diagnostics(devices, env)
    print("STEMWERK_ENV_JSON " + json.dumps(env, ensure_ascii=False))
    print("STEMWERK_DEVICES_END")


def list_devices(skip_devices: Optional[Set[str]] = None):
    """List all available compute devices."""
    _require_core()
    devices = get_available_devices()
    if skip_devices:
        devices = [d for d in devices if d.get("id") not in skip_devices]
    print("Available devices:")
    for dev in devices:
        print(f"  {dev['id']}:  {dev['name']} ({dev['type']})")
    return devices


def check_installation():
    """Check if stemwerk-core and audio-separator are properly installed."""
    try:
        _require_core()
        from audio_separator.separator import Separator  # noqa: F401
        import torch

        print("audio-separator:  OK", file=sys.stderr)
        print(f"PyTorch: {torch.__version__}", file=sys.stderr)
        print(f"CUDA available: {torch.cuda.is_available()}", file=sys.stderr)

        if torch.cuda.is_available():
            for i in range(torch.cuda.device_count()):
                print(f"GPU {i}:  {torch.cuda.get_device_name(i)}", file=sys.stderr)

        try:
            import torch_directml
            print("DirectML:  Available", file=sys.stderr)
        except ImportError:
            print("DirectML: Not installed (pip install torch-directml)", file=sys.stderr)

        return True
    except ImportError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        print("\nInstall with: pip install stemwerk-core", file=sys.stderr)
        return False


def main():
    parser = argparse.ArgumentParser(description="Audio Separator for STEMwerk")
    parser.add_argument("input", nargs="?", help="Input audio file")
    parser.add_argument("output_dir", nargs="?", help="Output directory for stems")
    parser.add_argument("--model", default="htdemucs",
                        help="Model to use (htdemucs, htdemucs_ft, htdemucs_6s, etc.)")
    parser.add_argument("--device", default="auto",
                        help="Device to use:  auto, cpu, cuda:0, cuda: 1, directml")
    parser.add_argument("--stems", default="",
                        help="Optional comma-separated stems (vocals, drums, bass, other, guitar, piano)")
    parser.add_argument("--env-json", action="store_true",
                        help="Emit STEMWERK_ENV_JSON and device list for Lua")
    parser.add_argument("--skip-devices", default="",
                        help="Comma-separated device ids to skip")
    parser.add_argument("--check", action="store_true",
                        help="Only check installation, don't process")
    parser.add_argument("--list-models", action="store_true",
                        help="List available models")
    parser.add_argument("--list-devices", action="store_true",
                        help="List available compute devices")
    parser.add_argument("--list-devices-machine", action="store_true",
                        help="List available devices in a machine-readable format (for REAPER UIs)")

    args = parser.parse_args()

    write_done = _setup_reaper_io(args.output_dir if args.output_dir else None)
    ffmpeg_path = _configure_ffmpeg_runtime()
    model_cache_dir = _configure_model_cache_runtime()
    if ffmpeg_path is not None:
        print(f"STEMWERK_DIAG ffmpeg_path={ffmpeg_path}", file=sys.stderr)
    else:
        print("STEMWERK_DIAG ffmpeg_path=NOT_FOUND", file=sys.stderr)
    print(f"STEMWERK_DIAG model_cache_dir={model_cache_dir}", file=sys.stderr)

    skip_devices = set(_split_list(args.skip_devices))

    if args.env_json or args.list_devices_machine:
        list_devices_machine(skip_devices)
        return 0

    if args.check:
        if check_installation():
            print("\nInstallation OK!")
            list_devices(skip_devices)
            return 0
        return 1

    if args.list_devices:
        list_devices(skip_devices)
        return 0

    if args.list_models:
        print("Popular models:")
        print("  htdemucs - Hybrid Transformer Demucs (default, fast)")
        print("  htdemucs_ft - Fine-tuned Demucs (better quality)")
        print("  htdemucs_6s - 6-stem model (guitar, piano)")
        print("  UVR-MDX-NET-Voc_FT - Best vocal isolation")
        print("  Kim_Vocal_2 - Alternative vocal model")
        return 0

    if not args.input or not args.output_dir:
        parser.print_help()
        return 1

    _require_core()

    if not os.path.exists(args.input):
        print(f"ERROR: Input file not found: {args.input}", file=sys.stderr)
        return 1

    device_preference = args.device
    if device_preference in skip_devices:
        print(f"WARNING: Device '{device_preference}' skipped; using auto", file=sys.stderr)
        device_preference = "auto"

    stems = _split_list(args.stems)

    resolved_device = device_preference
    if device_preference == "auto":
        preferred = None
        if sys.platform.startswith("linux"):
            preferred = _prefer_linux_amd_device(get_available_devices(), _get_skip_ids())
        if preferred:
            resolved_device = preferred.get("id") or "auto"
            print(
                f"STEMWERK_DIAG auto_selected_preferred={resolved_device} ({preferred.get('name','')})",
                file=sys.stderr,
            )
        else:
            try:
                dev_id, dev_name = select_device("auto")
                print(f"STEMWERK_DIAG auto_selected={dev_id} ({dev_name})", file=sys.stderr)
                resolved_device = dev_id
            except Exception:
                resolved_device = "auto"
    else:
        print(f"STEMWERK_DIAG requested_device={device_preference}", file=sys.stderr)

    try:
        output_root = Path(args.output_dir).resolve()
        output_root.mkdir(parents=True, exist_ok=True)

        sep = StemSeparator(model=args.model, device=resolved_device)

        def reaper_progress(pct: float, msg: str):
            emit_progress(pct, msg)

        sep.on_progress = reaper_progress

        with _working_directory(output_root):
            result = sep.separate(args.input, str(output_root), stems=stems or None)
        
        # Mapping logica voor REAPER compatibiliteit
        stem_mapping = {
            'vocals': ['vocals', 'vocal', 'Vocals'],
            'drums':  ['drums', 'drum', 'Drums'],
            'bass': ['bass', 'Bass'],
            'other': ['other', 'Other', 'no_vocals', 'instrumental', 'Instrumental'],
            'guitar': ['guitar', 'Guitar'],
            'piano': ['piano', 'Piano', 'keys', 'Keys']
        }

        reaper_stems = {}
        for stem_name, stem_path in result.stems.items():
            abs_path = _resolve_stem_path(output_root, stem_path)
            if not abs_path.exists():
                raise FileNotFoundError(f"Expected separated stem not found: {abs_path}")
            
            # Zoek naar de juiste REAPER naam
            filename = abs_path.stem.lower()
            target_name = stem_name  # fallback
            
            for map_name, patterns in stem_mapping.items():
                if any(p.lower() in filename for p in patterns):
                    target_name = map_name
                    break
            
            # Hernoem bestand naar simpele naam (bijv. vocals.wav)
            new_path = abs_path.parent / f"{target_name}.wav"
            if abs_path != new_path:
                if new_path.exists():
                    os.remove(new_path)
                shutil.move(str(abs_path), str(new_path))
            
            reaper_stems[target_name] = str(new_path)
            print(f"  {target_name}:  {new_path}", file=sys.stderr)

        # Print de JSON die Lua verwacht
        print(json.dumps(reaper_stems))

        if write_done:
            write_done("DONE")

        return 0
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        import traceback

        traceback.print_exc(file=sys.stderr)
        if write_done:
            write_done("ERROR")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
