"""Regression tests for the 2.3.1.0 parallel processing_summary evidence gap.

Live macOS evidence: parallel item_N jobs (job_id=item_1, item_2, ...) write
their authoritative output-validation evidence as explicit key=value lines
in their own separation_log.txt (output_validation_reason=, found_stems=,
expected_stems=, runtime_selected=, backend_runtime=) -- never into
phase_events.jsonl or timing_events.jsonl. jobOwnOutputEvidence() in
STEMwerk_Save_Support_Bundle.lua fed the run-level parallel aggregation
logic in buildProcessingSummary, but only ever read the JSON event files,
so a job whose evidence lives solely in separation_log.txt contributed
nothing to the aggregate -- and buildProcessingSummary's own truthfulness
safeguard (never let a single leaked-in job's value stand in for a run's
whole aggregate) then correctly, but unhelpfully, fell back to "unknown"
even though complete, authoritative per-item evidence actually existed.

This file proves jobOwnOutputEvidence()'s own behavior directly (unit
level, real lua5.4, extracted verbatim from the real source): the
separation_log.txt fallback it must gain, the precedence between JSON and
separation_log evidence when both exist, and robustness (missing file,
unrelated/malformed lines, human-readable prose without explicit key=value
evidence, job-directory scoping).

End-to-end run-level aggregation (mixed/partial/validation-failure
handling across parallel item_N jobs) is covered by
tests/support/run_support_bundle_headless.lua's ELEVENTHFU scenarios,
which dofile() the real production script against mocked scenarios --
stronger evidence than a source-text check, so this file does not
duplicate it.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SUPPORT_BUNDLE = ROOT / "scripts" / "reaper" / "STEMwerk_Save_Support_Bundle.lua"

LUA = shutil.which("lua5.4") or shutil.which("lua5.3") or shutil.which("lua") or shutil.which("luajit")
pytestmark_lua = pytest.mark.skipif(LUA is None, reason="no lua interpreter available on this host")


def _lua_function(source: str, name: str) -> str:
    """Extract a `local function NAME(...) ... end` block by matching
    function/end keyword nesting (Lua has no braces), skipping over string
    literals and comments so keyword-like words inside them don't confuse
    the depth counter."""
    start = source.index(f"local function {name}(")
    pos = start
    depth = 0
    opened = False
    token_re = re.compile(
        r'--\[(=*)\[|--.*|\[(=*)\[|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|\b(function|if|for|while|end)\b'
    )
    while True:
        m = token_re.search(source, pos)
        if not m:
            raise AssertionError(name)
        if m.group(1) is not None:
            close = "]" + m.group(1) + "]"
            end_idx = source.index(close, m.end())
            pos = end_idx + len(close)
            continue
        if m.group(2) is not None:
            close = "]" + m.group(2) + "]"
            end_idx = source.index(close, m.end())
            pos = end_idx + len(close)
            continue
        word = m.group(3)
        pos = m.end()
        if word is None:
            continue
        if word in ("function", "if", "for", "while"):
            depth += 1
            opened = True
        elif word == "end":
            depth -= 1
            if opened and depth == 0:
                return source[start:pos]


_DEPS = (
    "trim",
    "joinPath",
    "readFile",
    "countDelimitedValues",
    "enumerateFiles",
    "detectStemNamesFromText",
    "detectStemNamesFromFiles",
    "parseJsonStringField",
    "parseJsonNumberField",
    "parseKeyValueLine",
)


def _build_harness(tmp_path: Path, job_dir: Path) -> str:
    text = SUPPORT_BUNDLE.read_text(encoding="utf-8")
    deps = "\n".join(_lua_function(text, name) for name in _DEPS)
    fn = _lua_function(text, "jobOwnOutputEvidence")

    harness = tmp_path / "harness.lua"
    harness.write_text(
        f"""
OS = "Linux"
PATH_SEP = "/"
reaper = {{
    EnumerateFiles = function(path, idx)
        local handle = io.popen("ls -1 " .. "'" .. path:gsub("'", "'\\\\''") .. "' 2>/dev/null")
        if not handle then return nil end
        local names = {{}}
        for line in handle:lines() do
            local ok = os.execute("test -f '" .. (path .. "/" .. line):gsub("'", "'\\\\''") .. "'")
            if ok == true or ok == 0 then names[#names + 1] = line end
        end
        handle:close()
        table.sort(names)
        return names[(idx or 0) + 1]
    end,
}}
local UNIVERSAL_STEM_NAMES = {{ "vocals", "drums", "bass", "other", "guitar", "piano" }}
{deps}
{fn}
local found, validation = jobOwnOutputEvidence('{job_dir}')
print("FOUND=" .. tostring(found))
print("VALIDATION=" .. tostring(validation))
""",
        encoding="utf-8",
    )
    result = subprocess.run([LUA, str(harness)], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


def _parse(output: str) -> tuple[str, str]:
    found = re.search(r"^FOUND=(.*)$", output, re.MULTILINE).group(1)
    validation = re.search(r"^VALIDATION=(.*)$", output, re.MULTILINE).group(1)
    return found, validation


@pytestmark_lua
def test_separation_log_fallback_used_when_json_absent(tmp_path: Path):
    job_dir = tmp_path / "item_1"
    job_dir.mkdir()
    (job_dir / "separation_log.txt").write_text(
        "output_validation_reason=ok\nfound_stems=4\nexpected_stems=4\n"
        "runtime_selected=mps\nbackend_runtime=metal\n",
        encoding="utf-8",
    )
    found, validation = _parse(_build_harness(tmp_path, job_dir))
    assert found == "4", f"expected found=4 from separation_log.txt fallback, got {found}"
    assert validation == "ok", f"expected validation=ok from separation_log.txt fallback, got {validation}"


@pytestmark_lua
def test_found_stems_as_stem_name_list_is_counted(tmp_path: Path):
    job_dir = tmp_path / "item_1"
    job_dir.mkdir()
    (job_dir / "separation_log.txt").write_text(
        "output_validation_reason=ok\nfound_stems=kick,snare,toms,hihat,ride,crash\n",
        encoding="utf-8",
    )
    found, validation = _parse(_build_harness(tmp_path, job_dir))
    assert found == "6", f"expected a 6-stem comma list to count as 6, got {found}"
    assert validation == "ok"


@pytestmark_lua
def test_json_event_evidence_takes_precedence_over_separation_log(tmp_path: Path):
    """A: precedence -- when both JSON event evidence and separation_log
    evidence exist and genuinely disagree, JSON must win outright; the
    conflicting separation_log value must never silently overwrite it."""
    job_dir = tmp_path / "item_1"
    job_dir.mkdir()
    (job_dir / "phase_events.jsonl").write_text(
        '{"time":1,"output_count":4,"output_validation_reason":"ok"}\n',
        encoding="utf-8",
    )
    (job_dir / "separation_log.txt").write_text(
        "output_validation_reason=missing_output\nfound_stems=99\n",
        encoding="utf-8",
    )
    found, validation = _parse(_build_harness(tmp_path, job_dir))
    assert found == "4", f"JSON output_count=4 must win over contradictory separation_log found_stems=99, got {found}"
    assert validation == "ok", f"JSON output_validation_reason=ok must win over contradictory separation_log value, got {validation}"


@pytestmark_lua
def test_missing_separation_log_file_is_tolerated(tmp_path: Path):
    job_dir = tmp_path / "item_1"
    job_dir.mkdir()
    found, validation = _parse(_build_harness(tmp_path, job_dir))
    assert found == "nil"
    assert validation == "nil"


@pytestmark_lua
def test_unrelated_and_malformed_lines_are_ignored(tmp_path: Path):
    job_dir = tmp_path / "item_1"
    job_dir.mkdir()
    (job_dir / "separation_log.txt").write_text(
        "this is not a key=value line at all\n"
        "=== SEPARATION LOG ===\n"
        "unrelated_field=some_value\n"
        "   \n",
        encoding="utf-8",
    )
    found, validation = _parse(_build_harness(tmp_path, job_dir))
    assert found == "nil", "unrelated key=value lines must not be misread as found_stems"
    assert validation == "nil", "unrelated key=value lines must not be misread as output_validation_reason"


@pytestmark_lua
def test_human_readable_success_sentence_does_not_imply_validation_ok(tmp_path: Path):
    """Section 3: must not infer PASS from prose like 'Exported audio file
    successfully' when no explicit output_validation_reason= key exists."""
    job_dir = tmp_path / "item_1"
    job_dir.mkdir()
    (job_dir / "separation_log.txt").write_text(
        "Exported audio file successfully\nAll stems written to disk\n",
        encoding="utf-8",
    )
    found, validation = _parse(_build_harness(tmp_path, job_dir))
    assert validation == "nil", "human-readable success prose must not be treated as authoritative validation evidence"


@pytestmark_lua
def test_scoped_to_own_job_directory_not_sibling(tmp_path: Path):
    """Robustness: evidence must be read only from the selected job's own
    directory, never a sibling job's separation_log.txt."""
    job_dir = tmp_path / "item_1"
    job_dir.mkdir()
    (job_dir / "separation_log.txt").write_text("found_stems=4\noutput_validation_reason=ok\n", encoding="utf-8")

    sibling_dir = tmp_path / "item_2"
    sibling_dir.mkdir()
    (sibling_dir / "separation_log.txt").write_text(
        "found_stems=999\noutput_validation_reason=missing_output\n", encoding="utf-8"
    )

    found, validation = _parse(_build_harness(tmp_path, job_dir))
    assert found == "4", f"must read only item_1's own separation_log.txt, not item_2's, got {found}"
    assert validation == "ok"
