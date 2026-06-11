#!/usr/bin/env python3
"""Portable, development-only STEMwerk workflow benchmark runner."""

from __future__ import annotations

import argparse
import csv
import json
import os
import platform
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time
import wave
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable


SCHEMA_VERSION = 1
DRUMSEP_MODEL = "MDX23C-DrumSep-aufr33-jarredou.ckpt"
WORKFLOWS = {"normal", "dks_direct", "dks_extract"}
RUN_KINDS = {"cold", "warm"}
DEVICE_CHOICES = {"auto", "cpu", "gpu", "rocm", "cuda", "mps", "directml"}


@dataclass
class RuntimeInfo:
    root: Path
    python: Path
    process_script: Path
    model_cache: Path
    state_files: dict[str, dict[str, str]]


@dataclass
class AudioInfo:
    path: Path
    duration_sec: float
    sample_rate: int
    channels: int


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def result_folder_name(hostname: str, now: datetime | None = None) -> str:
    stamp = (now or datetime.now()).strftime("%Y%m%d-%H%M%S")
    safe_host = re.sub(r"[^A-Za-z0-9._-]+", "-", hostname).strip("-") or "unknown-host"
    return f"{safe_host}-{stamp}"


def calculate_x_realtime(duration_sec: float, wall_sec: float) -> float:
    return duration_sec / wall_sec if wall_sec > 0 else 0.0


def runtime_root_candidates(system: str | None = None, home: Path | None = None) -> list[Path]:
    system = system or platform.system()
    home = home or Path.home()
    if system == "Linux":
        return [home / ".local" / "share" / "STEMwerk"]
    if system == "Darwin":
        return [
            home / "Library" / "Application Support" / "STEMwerk",
            Path("/Users/Shared/STEMwerk"),
        ]
    if system == "Windows":
        local_app_data = os.environ.get("LOCALAPPDATA")
        return [Path(local_app_data) / "STEMwerk"] if local_app_data else []
    return []


def _python_candidates(root: Path, system: str) -> list[Path]:
    if system == "Windows":
        return [
            root / ".venv" / "Scripts" / "python.exe",
            root / "python" / "python.exe",
            root / "python" / "Scripts" / "python.exe",
        ]
    return [
        root / ".venv" / "bin" / "python",
        root / "python" / "bin" / "python3",
        root / "python" / "bin" / "python",
    ]


def _live_script_candidates(system: str, home: Path) -> list[Path]:
    repo_script = Path(__file__).resolve().parents[2] / "scripts" / "reaper" / "audio_separator_process.py"
    candidates = [repo_script]
    if system == "Windows":
        app_data = os.environ.get("APPDATA")
        if app_data:
            candidates.append(Path(app_data) / "REAPER" / "Scripts" / "STEMwerk-reaper" / "audio_separator_process.py")
    elif system == "Darwin":
        candidates.append(
            home / "Library" / "Application Support" / "REAPER" / "Scripts"
            / "STEMwerk-reaper" / "audio_separator_process.py"
        )
    else:
        candidates.append(
            home / ".config" / "REAPER" / "Scripts" / "STEMwerk-reaper"
            / "audio_separator_process.py"
        )
    return candidates


def parse_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return values
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def detect_runtime(
    system: str | None = None,
    home: Path | None = None,
    roots: Iterable[Path] | None = None,
) -> RuntimeInfo:
    system = system or platform.system()
    home = home or Path.home()
    candidate_roots = list(roots) if roots is not None else runtime_root_candidates(system, home)
    for root in candidate_roots:
        python_path = next((path for path in _python_candidates(root, system) if path.is_file()), None)
        if python_path is None:
            continue
        process_script = next(
            (path for path in _live_script_candidates(system, home) if path.is_file()),
            None,
        )
        if process_script is None:
            raise RuntimeError(
                f"STEMwerk runtime found at {root}, but audio_separator_process.py was not found "
                "in the repository or installed REAPER scripts."
            )
        state_dir = root / "state"
        state_files = {
            path.name: parse_env_file(path)
            for path in sorted(state_dir.glob("*.env"))
            if path.is_file()
        }
        return RuntimeInfo(
            root=root,
            python=python_path,
            process_script=process_script,
            model_cache=root / "models",
            state_files=state_files,
        )
    checked = ", ".join(str(path) for path in candidate_roots) or "(no platform candidates)"
    raise RuntimeError(f"No existing STEMwerk runtime found. Checked: {checked}")


def read_wav_info(path: Path) -> AudioInfo:
    if path.suffix.lower() != ".wav":
        raise ValueError(f"Benchmark v1 requires WAV input: {path}")
    try:
        with wave.open(str(path), "rb") as wav:
            sample_rate = wav.getframerate()
            channels = wav.getnchannels()
            frames = wav.getnframes()
    except (OSError, wave.Error) as exc:
        raise ValueError(f"Cannot read WAV input {path}: {exc}") from exc
    if sample_rate <= 0 or channels <= 0:
        raise ValueError(f"Invalid WAV metadata: {path}")
    return AudioInfo(path, frames / sample_rate, sample_rate, channels)


def load_preset(path: Path) -> dict[str, Any]:
    try:
        preset = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"Cannot load preset {path}: {exc}") from exc
    if preset.get("schema_version") != 1:
        raise ValueError("Preset schema_version must be 1")
    if not isinstance(preset.get("name"), str) or not preset["name"].strip():
        raise ValueError("Preset name is required")
    if not isinstance(preset.get("audio_file"), str) or not preset["audio_file"].strip():
        raise ValueError("Preset audio_file is required")
    jobs = preset.get("jobs")
    if not isinstance(jobs, list) or not jobs:
        raise ValueError("Preset jobs must be a non-empty list")
    for index, job in enumerate(jobs, 1):
        if job.get("workflow") not in WORKFLOWS:
            raise ValueError(f"Preset job {index} has unsupported workflow")
        if not isinstance(job.get("mode"), str) or not job["mode"]:
            raise ValueError(f"Preset job {index} requires mode")
        run_kinds = job.get("runs", preset.get("runs", ["cold"]))
        if not isinstance(run_kinds, list) or not run_kinds or not set(run_kinds) <= RUN_KINDS:
            raise ValueError(f"Preset job {index} has invalid runs")
    return preset


def _run_best_effort(command: list[str], timeout: int = 12) -> str:
    if shutil.which(command[0]) is None:
        return ""
    try:
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return "\n".join(part.strip() for part in (completed.stdout, completed.stderr) if part.strip())


def collect_system_info(runtime: RuntimeInfo) -> dict[str, Any]:
    system = platform.system()
    commands: list[list[str]]
    if system == "Linux":
        commands = [
            ["lspci"],
            ["nvidia-smi", "--query-gpu=name,driver_version", "--format=csv,noheader"],
            ["rocminfo"],
        ]
    elif system == "Darwin":
        commands = [["system_profiler", "SPHardwareDataType", "SPDisplaysDataType"]]
    elif system == "Windows":
        commands = [
            ["powershell", "-NoProfile", "-Command",
             "Get-CimInstance Win32_Processor,Win32_VideoController | Format-List Name"],
            ["wmic", "path", "win32_VideoController", "get", "name"],
        ]
    else:
        commands = []
    command_outputs = {" ".join(cmd): _run_best_effort(cmd) for cmd in commands}
    gpu_lines: list[str] = []
    for output in command_outputs.values():
        for line in output.splitlines():
            if re.search(r"(AMD|NVIDIA|Radeon|GeForce|Intel.*Graphics|Apple.*GPU)", line, re.I):
                value = line.strip()
                if value and value not in gpu_lines:
                    gpu_lines.append(value)
    ram_bytes = 0
    try:
        page_size = os.sysconf("SC_PAGE_SIZE")
        pages = os.sysconf("SC_PHYS_PAGES")
        ram_bytes = int(page_size * pages)
    except (AttributeError, OSError, ValueError):
        pass
    return {
        "hostname": socket.gethostname(),
        "os": f"{system} {platform.release()}",
        "platform": platform.platform(),
        "machine": platform.machine(),
        "cpu": platform.processor() or platform.machine(),
        "ram_bytes": ram_bytes,
        "gpu_names": gpu_lines,
        "runtime_root": str(runtime.root),
        "python_executable": str(runtime.python),
        "process_script": str(runtime.process_script),
        "model_cache": str(runtime.model_cache),
        "state_files": runtime.state_files,
        "diagnostic_commands": command_outputs,
    }


def _resolve_mode(job: dict[str, Any]) -> tuple[str, str]:
    workflow = job["workflow"]
    mode = job["mode"]
    if workflow == "normal":
        return mode, mode
    if workflow == "dks_direct":
        return DRUMSEP_MODEL, mode
    stage1_models = {
        "Fast": "htdemucs",
        "Quality": "htdemucs_ft",
        "Expanded": "htdemucs_6s",
    }
    if mode not in stage1_models:
        raise ValueError(f"Unsupported dks_extract mode: {mode}")
    return stage1_models[mode], mode


def build_command(
    runtime: RuntimeInfo,
    audio: Path,
    output_dir: Path,
    workflow: str,
    mode: str,
    device: str,
) -> list[str]:
    model, _display_mode = _resolve_mode({"workflow": workflow, "mode": mode})
    command = [
        str(runtime.python),
        "-u",
        str(runtime.process_script),
        str(audio),
        str(output_dir),
        "--model",
        model,
        "--device",
        device,
    ]
    if workflow == "normal":
        command.extend(["--workflow-mode", "stems", "--workflow-source", "normal"])
    else:
        command.extend(
            [
                "--workflow-mode",
                "drumkit",
                "--workflow-source",
                workflow,
                "--requested-stage2-model",
                DRUMSEP_MODEL,
            ]
        )
    return command


def _parse_markers(text: str) -> dict[str, str]:
    markers: dict[str, str] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if "=" in stripped and re.match(r"^[A-Za-z_][A-Za-z0-9_.-]*=", stripped):
            key, value = stripped.split("=", 1)
            markers[key] = value
    return markers


def _parse_output_count(stdout: str) -> int:
    for line in reversed(stdout.splitlines()):
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(payload, dict):
            return len(payload)
        if isinstance(payload, list):
            return len(payload)
    return 0


def _backend_from_markers(markers: dict[str, str], device: str) -> str:
    for key in ("drumsep_runtime_selected", "backend_runtime", "backend"):
        value = markers.get(key, "").strip().lower()
        if value and value not in {"gpu", "unknown"}:
            return value
    effective = markers.get("effective_device", markers.get("device", "")).lower()
    if "cuda" in effective:
        return "cuda"
    if "directml" in effective or "privateuseone" in effective:
        return "directml"
    if "mps" in effective:
        return "mps"
    return device


def _expected_output_count(workflow: str, mode: str) -> int:
    if workflow != "normal":
        return 6
    return 6 if mode == "htdemucs_6s" else 4


def _write_system_info(path: Path, info: dict[str, Any]) -> None:
    lines = [
        f"{key}={json.dumps(value, sort_keys=True) if isinstance(value, (dict, list)) else value}"
        for key, value in info.items()
    ]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _write_results(
    result_dir: Path,
    rows: list[dict[str, Any]],
    system_info: dict[str, Any],
    json_path: Path,
    csv_path: Path,
    markdown_path: Path,
) -> None:
    payload = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": utc_timestamp(),
        "system": system_info,
        "results": rows,
    }
    json_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    fieldnames = list(rows[0].keys()) if rows else [
        "schema_version", "timestamp", "hostname", "os", "cpu", "gpu", "runtime_root",
        "preset", "workflow", "mode", "device_requested", "backend_selected",
        "effective_device", "audio_file", "duration_sec", "sample_rate", "channels",
        "run_kind", "cap", "wall_sec", "x_realtime", "status", "output_count", "error",
    ]
    with csv_path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
    headers = ["workflow", "mode", "run_kind", "device_requested", "backend_selected",
               "wall_sec", "x_realtime", "status", "output_count", "error"]
    lines = [
        "# STEMwerk benchmark summary",
        "",
        f"Result folder: `{result_dir}`",
        "",
        "| " + " | ".join(headers) + " |",
        "|" + "|".join("---" for _ in headers) + "|",
    ]
    for row in rows:
        lines.append("| " + " | ".join(str(row.get(key, "")).replace("|", "\\|") for key in headers) + " |")
    markdown_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _selected_jobs(
    preset: dict[str, Any],
    workflow_filter: set[str] | None,
    run_filter: set[str] | None,
) -> list[tuple[dict[str, Any], str]]:
    selected: list[tuple[dict[str, Any], str]] = []
    for job in preset["jobs"]:
        if workflow_filter and job["workflow"] not in workflow_filter:
            continue
        run_kinds = job.get("runs", preset.get("runs", ["cold"]))
        for run_kind in run_kinds:
            if not run_filter or run_kind in run_filter:
                selected.append((job, run_kind))
    return selected


def _comma_set(value: str | None, allowed: set[str], label: str) -> set[str] | None:
    if not value:
        return None
    values = {item.strip() for item in value.split(",") if item.strip()}
    invalid = values - allowed
    if invalid:
        raise ValueError(f"Invalid {label}: {', '.join(sorted(invalid))}")
    return values


def _output_path(value: str | None, result_dir: Path, default_name: str) -> Path:
    if not value:
        return result_dir / default_name
    path = Path(value).expanduser()
    return path if path.is_absolute() else result_dir / path


def run_benchmark(args: argparse.Namespace) -> int:
    preset_path = Path(args.preset).expanduser().resolve()
    preset = load_preset(preset_path)
    input_dir = Path(args.input_dir).expanduser().resolve()
    audio_path = input_dir / preset["audio_file"]
    if not audio_path.is_file():
        raise FileNotFoundError(
            f"Required benchmark audio is missing: {audio_path}\n"
            "See tools/benchmark/README.md for placeholder filenames and audio requirements."
        )
    audio = read_wav_info(audio_path)
    runtime = detect_runtime()
    system_info = collect_system_info(runtime)
    output_root = Path(args.output_dir).expanduser().resolve()
    result_dir = output_root / result_folder_name(system_info["hostname"])
    logs_dir = result_dir / "logs"
    logs_dir.mkdir(parents=True, exist_ok=False)
    _write_system_info(result_dir / "system_info.txt", system_info)

    workflow_filter = _comma_set(args.workflow, WORKFLOWS, "workflow")
    run_filter = _comma_set(args.runs, RUN_KINDS, "run kind")
    jobs = _selected_jobs(preset, workflow_filter, run_filter)
    if not jobs:
        raise ValueError("No benchmark jobs remain after applying filters")

    rows: list[dict[str, Any]] = []
    for index, (job, run_kind) in enumerate(jobs, 1):
        workflow = job["workflow"]
        mode = job["mode"]
        device = args.device or job.get("device", "auto")
        run_output = result_dir / "outputs" / f"{index:02d}-{workflow}-{mode}-{run_kind}"
        command = build_command(runtime, audio.path, run_output, workflow, mode, device)
        log_prefix = logs_dir / f"{index:02d}-{workflow}-{mode}-{run_kind}"
        started = time.monotonic()
        stdout = ""
        stderr = ""
        return_code = 0
        error = ""
        if args.dry_run:
            status = "planned"
        else:
            run_output.mkdir(parents=True, exist_ok=False)
            try:
                completed = subprocess.run(command, capture_output=True, text=True, check=False)
                stdout = completed.stdout or ""
                stderr = completed.stderr or ""
                return_code = completed.returncode
            except OSError as exc:
                return_code = 127
                error = f"{type(exc).__name__}: {exc}"
            status = "success" if return_code == 0 else "failed"
        wall_sec = time.monotonic() - started
        markers = _parse_markers(stderr)
        output_count = _parse_output_count(stdout)
        if not args.dry_run and return_code == 0 and output_count != _expected_output_count(workflow, mode):
            status = "failed"
            error = (
                f"output_count_mismatch: expected {_expected_output_count(workflow, mode)}, "
                f"found {output_count}"
            )
        if return_code != 0 and not error:
            error = markers.get("error_reason") or f"process_exit_{return_code}"
        if args.dry_run:
            stdout = shlex.join(command) + "\n"
            markers = {}
        log_prefix.with_suffix(".stdout.log").write_text(stdout, encoding="utf-8")
        log_prefix.with_suffix(".stderr.log").write_text(stderr, encoding="utf-8")
        row = {
            "schema_version": SCHEMA_VERSION,
            "timestamp": utc_timestamp(),
            "hostname": system_info["hostname"],
            "os": system_info["os"],
            "cpu": system_info["cpu"],
            "gpu": "|".join(system_info["gpu_names"]),
            "runtime_root": str(runtime.root),
            "preset": preset["name"],
            "workflow": workflow,
            "mode": mode,
            "device_requested": device,
            "backend_selected": "" if args.dry_run else _backend_from_markers(markers, device),
            "effective_device": markers.get(
                "model_device",
                markers.get("effective_device", markers.get("device", "")),
            ),
            "audio_file": audio.path.name,
            "duration_sec": round(audio.duration_sec, 3),
            "sample_rate": audio.sample_rate,
            "channels": audio.channels,
            "run_kind": run_kind,
            "cap": int(job.get("cap", preset.get("cap", 1))),
            "wall_sec": round(wall_sec, 3),
            "x_realtime": round(calculate_x_realtime(audio.duration_sec, wall_sec), 3)
            if not args.dry_run else 0.0,
            "status": status,
            "output_count": output_count,
            "error": error,
        }
        rows.append(row)
        print(
            f"[{index}/{len(jobs)}] {workflow} {mode} {run_kind}: "
            f"{status} ({row['wall_sec']:.3f}s)"
        )

    json_path = _output_path(args.json_out, result_dir, "benchmark_results.json")
    csv_path = _output_path(args.csv_out, result_dir, "benchmark_summary.csv")
    markdown_path = _output_path(args.markdown_out, result_dir, "benchmark_summary.md")
    for path in (json_path, csv_path, markdown_path):
        path.parent.mkdir(parents=True, exist_ok=True)
    _write_results(result_dir, rows, system_info, json_path, csv_path, markdown_path)
    print(f"Results: {result_dir}")
    return 1 if any(row["status"] == "failed" for row in rows) else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", required=True, help="Directory containing preset WAV files")
    parser.add_argument("--preset", required=True, help="Benchmark preset JSON")
    parser.add_argument("--output-dir", required=True, help="Root directory for result folders")
    parser.add_argument("--runs", help="Comma-separated filter: cold,warm")
    parser.add_argument("--workflow", help="Comma-separated filter: normal,dks_direct,dks_extract")
    parser.add_argument("--device", choices=sorted(DEVICE_CHOICES), help="Override preset device")
    parser.add_argument("--json-out", nargs="?", const="benchmark_results.json")
    parser.add_argument("--csv-out", nargs="?", const="benchmark_summary.csv")
    parser.add_argument("--markdown-out", nargs="?", const="benchmark_summary.md")
    parser.add_argument("--dry-run", action="store_true", help="Plan commands without processing audio")
    return parser


def main() -> int:
    try:
        return run_benchmark(build_parser().parse_args())
    except (FileExistsError, FileNotFoundError, RuntimeError, ValueError) as exc:
        print(f"benchmark error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
