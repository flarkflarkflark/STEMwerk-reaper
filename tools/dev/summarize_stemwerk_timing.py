#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple


LUA_EVENTS = {
    "lua_extract_start",
    "lua_extract_end",
    "python_launch",
    "first_progress_seen",
    "progress_50_seen",
    "progress_87_or_88_seen",
    "progress_90_or_92_seen",
    "done_seen",
    "import_start",
    "import_end",
}

PHASE_EVENTS = {
    "python_start",
    "model_setup_start",
    "model_setup_end",
    "separate_start",
    "separate_end",
    "stem_write_start",
    "stem_write_end",
    "python_done",
}


@dataclass
class JobSummary:
    job: str
    path: Path
    exit_code: Optional[int]
    done: str
    lua_extract_s: Optional[float]
    queue_to_python_s: Optional[float]
    model_setup_s: Optional[float]
    separate_s: Optional[float]
    stem_write_s: Optional[float]
    python_total_s: Optional[float]
    import_s: Optional[float]
    total_lua_s: Optional[float]
    first_progress_s: Optional[float]
    p50_s: Optional[float]
    p87_s: Optional[float]
    p90_s: Optional[float]
    notes: str
    python_start: Optional[float]
    python_done: Optional[float]
    last_phase_time: Optional[float]


def load_jsonl(path: Path) -> List[Dict[str, object]]:
    rows: List[Dict[str, object]] = []
    if not path.exists():
        return rows
    with path.open("r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(row, dict):
                rows.append(row)
    return rows


def load_exit_code(path: Path) -> Optional[int]:
    if not path.exists():
        return None
    text = path.read_text(encoding="utf-8", errors="ignore").strip()
    if not text:
        return None
    try:
        return int(text)
    except ValueError:
        return None


def load_done(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8", errors="ignore").strip()


def latest_progress(stdout_path: Path) -> str:
    if not stdout_path.exists():
        return ""
    latest = ""
    with stdout_path.open("r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            line = line.strip()
            if line.startswith("PROGRESS:"):
                latest = line
    return latest


def event_map(rows: Iterable[Dict[str, object]], key_name: str, allow: set[str]) -> Dict[str, Tuple[float, Dict[str, object]]]:
    mapped: Dict[str, Tuple[float, Dict[str, object]]] = {}
    for row in rows:
        name = row.get(key_name)
        time_v = row.get("time")
        if not isinstance(name, str) or name not in allow:
            continue
        if not isinstance(time_v, (int, float)):
            continue
        mapped[name] = (float(time_v), row)
    return mapped


def duration(start: Optional[float], end: Optional[float]) -> Optional[float]:
    if start is None or end is None:
        return None
    return end - start


def gather_jobs(input_paths: List[Path]) -> List[Path]:
    jobs: List[Path] = []
    for base in input_paths:
        if not base.exists():
            continue
        if (base / "timing_events.jsonl").exists() or (base / "phase_events.jsonl").exists():
            jobs.append(base)
            continue
        if base.is_dir():
            for child in sorted(base.iterdir()):
                if not child.is_dir():
                    continue
                if (child / "timing_events.jsonl").exists() or (child / "phase_events.jsonl").exists():
                    jobs.append(child)
    deduped: Dict[str, Path] = {str(job.resolve()): job for job in jobs}
    return sorted(deduped.values(), key=lambda p: p.name)


def summarize_job(job_dir: Path) -> JobSummary:
    timing_rows = load_jsonl(job_dir / "timing_events.jsonl")
    phase_rows = load_jsonl(job_dir / "phase_events.jsonl")

    timing = event_map(timing_rows, "event", LUA_EVENTS)
    phases = event_map(phase_rows, "phase", PHASE_EVENTS)

    def t_event(name: str) -> Optional[float]:
        item = timing.get(name)
        return item[0] if item else None

    def p_event(name: str) -> Optional[float]:
        item = phases.get(name)
        return item[0] if item else None

    exit_code = load_exit_code(job_dir / "exit_code.txt")
    done = load_done(job_dir / "done.txt")

    python_start = p_event("python_start")
    python_done = p_event("python_done")
    last_phase_time = max((t for t, _ in phases.values()), default=None)

    notes: List[str] = []
    if exit_code is None:
        notes.append("no_exit")
    elif exit_code != 0:
        notes.append("nonzero_exit")

    if not done:
        notes.append("no_done")
    elif done != "DONE":
        notes.append(f"done={done}")

    if not phase_rows:
        notes.append("no_phase_events")

    if python_start is not None and python_done is None:
        notes.append("python_incomplete")

    if not timing_rows:
        notes.append("no_timing_events")

    progress_line = latest_progress(job_dir / "stdout.txt")
    if progress_line and "PROGRESS:100:" not in progress_line and python_done is None:
        notes.append("last_progress_partial")

    return JobSummary(
        job=job_dir.name,
        path=job_dir,
        exit_code=exit_code,
        done=done,
        lua_extract_s=duration(t_event("lua_extract_start"), t_event("lua_extract_end")),
        queue_to_python_s=duration(t_event("python_launch"), p_event("python_start")),
        model_setup_s=duration(p_event("model_setup_start"), p_event("model_setup_end")),
        separate_s=duration(p_event("separate_start"), p_event("separate_end")),
        stem_write_s=duration(p_event("stem_write_start"), p_event("stem_write_end")),
        python_total_s=duration(python_start, python_done),
        import_s=duration(t_event("import_start"), t_event("import_end")),
        total_lua_s=duration(t_event("lua_extract_start"), t_event("import_end")),
        first_progress_s=duration(t_event("python_launch"), t_event("first_progress_seen")),
        p50_s=duration(t_event("python_launch"), t_event("progress_50_seen")),
        p87_s=duration(t_event("python_launch"), t_event("progress_87_or_88_seen")),
        p90_s=duration(t_event("python_launch"), t_event("progress_90_or_92_seen")),
        notes=",".join(notes),
        python_start=python_start,
        python_done=python_done,
        last_phase_time=last_phase_time,
    )


def fmt(value: Optional[float]) -> str:
    if value is None:
        return "NA"
    return f"{value:.3f}"


def print_table(summaries: List[JobSummary]) -> None:
    headers = [
        "job",
        "exit",
        "done",
        "lua_extract_s",
        "queue_to_python_s",
        "model_setup_s",
        "separate_s",
        "stem_write_s",
        "python_total_s",
        "import_s",
        "total_lua_s",
        "first_progress_s",
        "p50_s",
        "p87_s",
        "p90_s",
        "notes",
    ]

    rows: List[List[str]] = []
    for summary in summaries:
        rows.append(
            [
                summary.job,
                "NA" if summary.exit_code is None else str(summary.exit_code),
                summary.done or "NA",
                fmt(summary.lua_extract_s),
                fmt(summary.queue_to_python_s),
                fmt(summary.model_setup_s),
                fmt(summary.separate_s),
                fmt(summary.stem_write_s),
                fmt(summary.python_total_s),
                fmt(summary.import_s),
                fmt(summary.total_lua_s),
                fmt(summary.first_progress_s),
                fmt(summary.p50_s),
                fmt(summary.p87_s),
                fmt(summary.p90_s),
                summary.notes or "",
            ]
        )

    widths = [len(h) for h in headers]
    for row in rows:
        for idx, cell in enumerate(row):
            widths[idx] = max(widths[idx], len(cell))

    def line(parts: List[str]) -> str:
        return "  ".join(part.ljust(widths[idx]) for idx, part in enumerate(parts))

    print(line(headers))
    print(line(["-" * width for width in widths]))
    for row in rows:
        print(line(row))


def compute_overlap(summaries: List[JobSummary]) -> Tuple[int, List[str]]:
    starts_ends: List[Tuple[float, float]] = []
    notes: List[str] = []
    for s in summaries:
        if s.python_start is None:
            continue
        end = s.python_done if s.python_done is not None else s.last_phase_time
        if end is None:
            continue
        starts_ends.append((s.python_start, end))
        if s.python_done is None:
            notes.append(f"{s.job}:open_interval")

    if not starts_ends:
        return 0, notes

    points: List[Tuple[float, int]] = []
    for start, end in starts_ends:
        points.append((start, 1))
        points.append((end, -1))

    points.sort(key=lambda p: (p[0], p[1]))
    current = 0
    max_overlap = 0
    for _, delta in points:
        current += delta
        if current > max_overlap:
            max_overlap = current

    return max_overlap, notes


def run_summary(summaries: List[JobSummary]) -> None:
    completed = sum(1 for s in summaries if s.exit_code == 0 and s.done == "DONE")
    errors = sum(1 for s in summaries if s.exit_code not in (None, 0) or (s.done and s.done != "DONE"))

    separate_values = [s.separate_s for s in summaries if s.separate_s is not None]
    sum_separate = sum(separate_values) if separate_values else None
    max_separate = max(separate_values) if separate_values else None

    starts: List[float] = []
    ends: List[float] = []
    for s in summaries:
        start_candidates = [t for t in (s.python_start,) if t is not None]
        lua_start = load_event_time(s.path / "timing_events.jsonl", "event", "lua_extract_start")
        if lua_start is not None:
            start_candidates.append(lua_start)
        if start_candidates:
            starts.append(min(start_candidates))

        end_candidates: List[float] = []
        imp_end = load_event_time(s.path / "timing_events.jsonl", "event", "import_end")
        if imp_end is not None:
            end_candidates.append(imp_end)
        if s.python_done is not None:
            end_candidates.append(s.python_done)
        elif s.last_phase_time is not None:
            end_candidates.append(s.last_phase_time)
        if end_candidates:
            ends.append(max(end_candidates))

    wallclock_span = (max(ends) - min(starts)) if starts and ends else None
    max_overlap, overlap_notes = compute_overlap(summaries)

    run_notes: List[str] = []
    if max_overlap >= 2:
        run_notes.append("parallel_overlap_detected")
    if overlap_notes:
        run_notes.extend(overlap_notes)

    print("\nRun summary")
    print(f"- jobs: {len(summaries)}")
    print(f"- completed: {completed}")
    print(f"- error_or_cancel: {errors}")
    print(f"- max_python_overlap: {max_overlap}")
    print(f"- wallclock_span_s: {fmt(wallclock_span)}")
    print(f"- sum_separate_s: {fmt(sum_separate)}")
    print(f"- max_separate_s: {fmt(max_separate)}")
    print(f"- notes: {', '.join(run_notes) if run_notes else 'none'}")


def load_event_time(path: Path, key_name: str, target: str) -> Optional[float]:
    rows = load_jsonl(path)
    latest = None
    for row in rows:
        if row.get(key_name) == target and isinstance(row.get("time"), (int, float)):
            latest = float(row["time"])
    return latest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Summarize STEMwerk per-job timing/phase diagnostics from run/job directories."
    )
    parser.add_argument("paths", nargs="+", help="One or more run roots or job directories")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    input_paths = [Path(p).expanduser() for p in args.paths]
    jobs = gather_jobs(input_paths)

    if not jobs:
        print("No job directories found in given paths.")
        return 1

    summaries = [summarize_job(job) for job in jobs]
    print_table(summaries)
    run_summary(summaries)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
