#!/usr/bin/env python3
"""Isolated DrumSep stage2 helper for STEMwerk Direct Drum Kit Split."""

from __future__ import annotations

import argparse
import contextlib
import json
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

    try:
        print(f"timing_utc={time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime())} drumsep_helper_model_load_start", file=sys.stderr)
        print(f"drumsep_helper_start input={input_path}", file=sys.stderr)
        print(f"drumsep_helper_model_dir={model_dir}", file=sys.stderr)
        print(f"drumsep_helper_model={model_name}", file=sys.stderr)
        print(f"drumsep_helper_output_dir={output_dir}", file=sys.stderr)
        sep = Separator(model_file_dir=str(model_dir), output_dir=str(output_dir), output_format="WAV")
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

    try:
        print(f"timing_utc={time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime())} drumsep_helper_separate_start", file=sys.stderr)
        raw_outputs = sep.separate(str(input_path))
        print(f"timing_utc={time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime())} drumsep_helper_separate_end", file=sys.stderr)
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
    expected_count = len(EXPECTED_STEMS)
    actual_count = len(stems)
    missing = [name for name in EXPECTED_STEMS if name not in stems]
    model_meta = _load_model_metadata(model_dir, model_name)
    found_stems = sorted(stems.keys())
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
