#!/usr/bin/env python3
"""Isolated DrumSep stage2 helper for STEMwerk Direct Drum Kit Split."""

from __future__ import annotations

import argparse
import contextlib
import json
import shutil
import sys
import traceback
from pathlib import Path
from typing import Any


EXPECTED_STEMS = ("kick", "snare", "toms", "hihat", "ride", "crash")
REAPER_FILENAMES = {
    "kick": "kick.wav",
    "snare": "snare.wav",
    "toms": "toms.wav",
    "hihat": "hi-hat.wav",
    "ride": "ride.wav",
    "crash": "crash.wav",
}


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


def run(args: argparse.Namespace) -> int:
    input_path = Path(args.input).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    model_dir = Path(args.model_dir).expanduser().resolve()
    result_json = Path(args.result_json).expanduser().resolve()
    model_name = str(args.model)

    output_dir.mkdir(parents=True, exist_ok=True)
    before = {p.resolve() for p in output_dir.glob("*.wav")}

    try:
        from audio_separator.separator import Separator
    except Exception as exc:
        write_result(result_json, _error_payload("drumsep_helper_failed", "stage2_runtime", f"{type(exc).__name__}: {exc}"))
        return 1

    try:
        print(f"drumsep_helper_start input={input_path}", file=sys.stderr)
        print(f"drumsep_helper_model_dir={model_dir}", file=sys.stderr)
        print(f"drumsep_helper_model={model_name}", file=sys.stderr)
        print(f"drumsep_helper_output_dir={output_dir}", file=sys.stderr)
        sep = Separator(model_file_dir=str(model_dir), output_dir=str(output_dir), output_format="WAV")
        sep.load_model(model_name)
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

    try:
        raw_outputs = sep.separate(str(input_path))
    except Exception as exc:
        write_result(
            result_json,
            _error_payload(
                "drumsep_separate_failed",
                "stage2_separate",
                f"{type(exc).__name__}: {exc}",
                traceback=traceback.format_exc(),
            ),
        )
        return 1

    stems, raw_paths = normalize_outputs(output_dir, raw_outputs, before)
    missing = [name for name in EXPECTED_STEMS if name not in stems]
    if missing or len(stems) != len(EXPECTED_STEMS):
        write_result(
            result_json,
            _error_payload(
                "drumsep_output_count_mismatch",
                "stage2_output_validation",
                f"expected {len(EXPECTED_STEMS)} stems, got {len(stems)}",
                stems=stems,
                missing=missing,
                raw_outputs=raw_paths,
            ),
        )
        return 1

    write_result(result_json, {"ok": True, "stems": stems, "raw_outputs": raw_paths})
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
