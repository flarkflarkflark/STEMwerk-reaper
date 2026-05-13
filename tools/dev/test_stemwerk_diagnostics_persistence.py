#!/usr/bin/env python3
from __future__ import annotations

import json
import shutil
import tempfile
from pathlib import Path

ALLOWED = [
    "timing_events.jsonl",
    "phase_events.jsonl",
    "stdout.txt",
    "separation_log.txt",
    "exit_code.txt",
    "done.txt",
]
BLOCKED = ["input.wav", "vocals.wav", "project.rpp", "model.onnx", "model.pth"]


def sw_basename(path: str) -> str:
    p = path.rstrip("/\\")
    if not p:
        return ""
    return Path(p).name


def sw_parent(path: str) -> str:
    p = path.rstrip("/\\")
    if not p:
        return ""
    return str(Path(p).parent)


def derive_run_and_job(output_dir: str) -> tuple[str, str]:
    dir_name = sw_basename(output_dir)
    parent_name = sw_basename(sw_parent(output_dir))
    is_job_dir = dir_name == "single" or dir_name.startswith("item_") or dir_name.startswith("track_")

    if dir_name.startswith("STEMwerk_") or dir_name.startswith("STEMwerk-"):
        return dir_name, "single"
    if is_job_dir and (parent_name.startswith("STEMwerk_") or parent_name.startswith("STEMwerk-")):
        return parent_name, dir_name
    if parent_name.startswith("STEMwerk_") or parent_name.startswith("STEMwerk-"):
        return parent_name, (dir_name or "single")
    return "STEMwerk_unknown", (dir_name or "single")


def persist_run_diagnostics(output_dir: Path, runs_root: Path) -> Path:
    run_id, job_name = derive_run_and_job(str(output_dir))
    target = runs_root / run_id / job_name
    target.mkdir(parents=True, exist_ok=True)
    for name in ALLOWED:
        src = output_dir / name
        if src.exists() and src.is_file():
            shutil.copyfile(src, target / name)
    return target


def write_dummy_job(path: Path, exit_code: int = 0, done: str = "DONE") -> None:
    path.mkdir(parents=True, exist_ok=True)
    (path / "timing_events.jsonl").write_text('{"time":1.0,"event":"lua_extract_start"}\n', encoding="utf-8")
    (path / "phase_events.jsonl").write_text('{"time":2.0,"phase":"python_start"}\n', encoding="utf-8")
    (path / "stdout.txt").write_text("PROGRESS:1:Initializing\n", encoding="utf-8")
    (path / "separation_log.txt").write_text("diag\n", encoding="utf-8")
    (path / "exit_code.txt").write_text(str(exit_code), encoding="utf-8")
    (path / "done.txt").write_text(done, encoding="utf-8")
    for name in BLOCKED:
        (path / name).write_text("binary-ish", encoding="utf-8")


def assert_true(cond: bool, msg: str) -> None:
    if not cond:
        raise AssertionError(msg)


def check_job(persisted_job: Path, expect_exit: str) -> None:
    for name in ALLOWED:
        assert_true((persisted_job / name).exists(), f"missing allowed file: {persisted_job / name}")
    for name in BLOCKED:
        assert_true(not (persisted_job / name).exists(), f"blocked file copied: {persisted_job / name}")
    assert_true((persisted_job / "exit_code.txt").read_text(encoding="utf-8").strip() == expect_exit, "exit_code mismatch")


def run() -> dict:
    with tempfile.TemporaryDirectory(prefix="stemwerk_diag_test_") as td:
        root = Path(td)
        fake_tmp = root / "tmp"
        runs_root = root / "cache" / "STEMwerk" / "logs" / "runs"
        runs_root.mkdir(parents=True, exist_ok=True)

        single = fake_tmp / "STEMwerk_FAKE_A" / "single"
        item1 = fake_tmp / "STEMwerk_FAKE_B" / "item_1"
        track2 = fake_tmp / "STEMwerk_FAKE_B" / "track_2"
        weird = fake_tmp / "not_a_stemwerk_run" / "weird_job"

        write_dummy_job(single, exit_code=0, done="DONE")
        write_dummy_job(item1, exit_code=143, done="ERROR")
        write_dummy_job(track2, exit_code=0, done="DONE")
        write_dummy_job(weird, exit_code=9, done="ERROR")

        p_single = persist_run_diagnostics(single, runs_root)
        p_item1 = persist_run_diagnostics(item1, runs_root)
        p_track2 = persist_run_diagnostics(track2, runs_root)
        p_weird = persist_run_diagnostics(weird, runs_root)

        assert_true(p_single == runs_root / "STEMwerk_FAKE_A" / "single", "single target path wrong")
        assert_true(p_item1 == runs_root / "STEMwerk_FAKE_B" / "item_1", "item_1 target path wrong")
        assert_true(p_track2 == runs_root / "STEMwerk_FAKE_B" / "track_2", "track_2 target path wrong")
        assert_true(p_weird == runs_root / "STEMwerk_unknown" / "weird_job", "unknown fallback path wrong")

        check_job(p_single, "0")
        check_job(p_item1, "143")
        check_job(p_track2, "0")
        check_job(p_weird, "9")

        run_a_files = sorted(p.name for p in (runs_root / "STEMwerk_FAKE_A").iterdir())
        run_b_files = sorted(p.name for p in (runs_root / "STEMwerk_FAKE_B").iterdir())
        assert_true(run_a_files == ["single"], "run A mixed jobs")
        assert_true(run_b_files == ["item_1", "track_2"], "run B mixed jobs")

        return {
            "ok": True,
            "runs_root": str(runs_root),
            "paths": {
                "single": str(p_single),
                "item_1": str(p_item1),
                "track_2": str(p_track2),
                "weird": str(p_weird),
            },
            "notes": "Mirror test for Lua derivation/copy semantics.",
        }


if __name__ == "__main__":
    result = run()
    print(json.dumps(result, indent=2))
