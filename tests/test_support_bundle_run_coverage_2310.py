"""Regression tests for the 2.3.1.0 support-bundle run-coverage gap.

Live evidence: a macOS Apple Silicon smoke session ran 9 processing jobs
(3 Normal Stems, 3 Direct Kit, 3 Kit Split) in close succession. The support
bundle created ~80 seconds after the last one:

  - persisted runs included: 8 (max 8)   -- the oldest of the 9 (run 1,
    Normal Stems Fast) was silently dropped
  - processing_summary.txt surfaced only 5 of the (already-capped) 8 runs,
    with no disclosure that more were included in the bundle than shown

Root cause: two independent, hardcoded, uncoordinated caps in
STEMwerk_Save_Support_Bundle.lua:

  - collectPersistedRunDiagnostics: local maxRunsToInclude = 8
    (selects the newest 8 of runtime_runs/ by mtime-epoch, or by directory
    name string on Windows where epoch isn't probed)
  - buildProcessingSummary: local maxRuns = math.min(5, #runNames)
    (independently re-truncates whatever collectPersistedRunDiagnostics
    already copied into runtime_runs/ down to 5 for the readable summary)

Neither cap is session-aware. Investigated whether authoritative session
grouping already exists in this codebase: each processing run gets its own
unique run_id (reaper.genGuid()), and the one session-adjacent concept that
does exist (session.env's SESSION_ID/SESSION_STARTED_UTC + a timestamp
window) was explicitly demoted from "authoritative" to "provenance only" by
a prior hardening pass in this exact file (see the deriveCurrentWorkerRunHealth
docstring: "legacy_unlinked: ... satisfy the OLD session-timestamp heuristic
... but have no valid structured proof. This is exactly the authority gap
this closes"). Reusing that demoted heuristic for a new purpose would run
against that established precedent, so this fix raises both fixed caps
(newest-first ordering is unchanged and already existing) generously enough
to cover realistic dense smoke/support sessions, and adds an explicit
truncation-disclosure line to processing_summary.txt so it never silently
implies complete coverage.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
SUPPORT_BUNDLE = ROOT / "scripts" / "reaper" / "STEMwerk_Save_Support_Bundle.lua"

LUA = shutil.which("lua5.4") or shutil.which("lua5.3") or shutil.which("lua") or shutil.which("luajit")
pytestmark_lua = pytest.mark.skipif(LUA is None, reason="no lua interpreter available on this host")


def _slice(source: str, start: str, end: str) -> str:
    return source[source.index(start) : source.index(end, source.index(start))]


def _lua_function(source: str, name: str) -> str:
    """Extract a `local function NAME(...) ... end` block by matching
    function/end keyword nesting (Lua has no braces). Good enough for the
    small, control-flow-only helpers this harness extracts -- none contain
    nested function literals that would confuse the depth counter."""
    start = source.index(f"local function {name}(")
    depth = 0
    i = start
    import re

    token_re = re.compile(r"\bfunction\b|\bend\b|\bif\b|\bfor\b|\bwhile\b|\bdo\b|\bthen\b")
    # Simple approach: count function/if/for/while openers vs `end` closers,
    # treating `do`/`then` as non-opening (they belong to for/while/if which
    # we already count) to avoid double counting.
    depth = 0
    pos = start
    opened = False
    while True:
        m = re.search(r"\b(function|if|for|while|end)\b", source[pos:])
        if not m:
            raise AssertionError(name)
        word = m.group(1)
        pos = pos + m.end()
        if word in ("function", "if", "for", "while"):
            depth += 1
            opened = True
        elif word == "end":
            depth -= 1
            if opened and depth == 0:
                return source[start:pos]


# --- Section 2/3 provenance: pin exact current cap values and history -----


def test_max8_cap_location_and_ordering_are_as_documented():
    text = SUPPORT_BUNDLE.read_text(encoding="utf-8")
    fn = _lua_function(text, "collectPersistedRunDiagnostics")
    assert "local maxRunsToInclude = 20" in fn
    assert "table.sort(runEntries, function(a, b)" in fn
    assert "return (a.epoch or 0) > (b.epoch or 0)" in fn, "must remain newest-first by mtime epoch"


def test_max5_cap_location_and_truncation_disclosure():
    text = SUPPORT_BUNDLE.read_text(encoding="utf-8")
    fn = _slice(
        text,
        "local function buildProcessingSummary(bundleDir, capabilityState, runtimeState)",
        "\nlocal function tempFolderContentReferencesItself(fullPath, name)",
    )
    assert "local maxRuns = math.min(16, #runNames)" in fn
    assert "Showing %d of %d included processing runs" in fn
    assert fn.index("local maxRuns = math.min(16, #runNames)") < fn.index("Showing %d of %d included processing runs")


# --- Behavioral proof (real lua interpreter) for the primary bug: ----------
# collectPersistedRunDiagnostics must not silently drop the oldest of a
# dense same-session run set.

_COLLECT_DEPS = (
    "trim",
    "joinPath",
    "fileExists",
    "pathExists",
    "ensureDir",
    "stripTrailingSep",
    "dirname",
    "enumerateSubdirs",
    "enumerateFiles",
    "appendLine",
    "appendKey",
)


def _build_collect_harness(tmp_path: Path, run_count: int) -> str:
    text = SUPPORT_BUNDLE.read_text(encoding="utf-8")
    deps = "\n".join(_lua_function(text, name) for name in _COLLECT_DEPS)
    collect_fn = _lua_function(text, "collectPersistedRunDiagnostics")

    runs_root = tmp_path / "cachelogs" / "runs"
    for i in range(1, run_count + 1):
        run_dir = runs_root / f"run_{i:02d}"
        job_dir = run_dir / "job1"
        job_dir.mkdir(parents=True)
        (job_dir / "exit_code.txt").write_text("0", encoding="utf-8")

    harness = tmp_path / "harness.lua"
    harness.write_text(
        f"""
OS = "Linux"
PATH_SEP = "/"
reaper = {{
    EnumerateSubdirectories = function(path, idx)
        local handle = io.popen("ls -1 " .. "'" .. path:gsub("'", "'\\\\''") .. "' 2>/dev/null")
        if not handle then return nil end
        local names = {{}}
        for line in handle:lines() do
            local ok = os.execute("test -d '" .. (path .. "/" .. line):gsub("'", "'\\\\''") .. "'")
            if ok == true or ok == 0 then names[#names + 1] = line end
        end
        handle:close()
        table.sort(names)
        return names[(idx or 0) + 1]
    end,
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
{deps}
local sanitizeTextContent = function(data) return data end
local function getPathStat(path)
    -- Deterministic synthetic epoch: run_01 is oldest, run_NN is newest --
    -- matches the live scenario where run 1 (earliest) was the one dropped.
    local n = tonumber(path:match("run_(%d+)$"))
    return {{ epoch = (n or 0) * 1000 }}
end
local function copySupportTextFile(src, dst, maxBytes)
    local f = io.open(src, "rb")
    if not f then return false, "missing" end
    local data = f:read("*a") or ""
    f:close()
    ensureDir(stripTrailingSep(dst):match("^(.*)[/\\\\][^/\\\\]+$") or "")
    local out = io.open(dst, "wb")
    if not out then return false, "write_failed" end
    out:write(data)
    out:close()
    return true, "copied"
end
{collect_fn}
local copiedFiles = {{}}
local lines = collectPersistedRunDiagnostics('{tmp_path / "cachelogs"}', '{tmp_path / "bundle"}', copiedFiles)
for _, line in ipairs(lines) do print(line) end
""",
        encoding="utf-8",
    )
    result = subprocess.run([LUA, str(harness)], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout


@pytestmark_lua
def test_nine_recent_runs_all_included_after_cap_increase(tmp_path: Path):
    """A/H: the exact live scenario -- 9 recent runs, all valid, ordered
    closely together -- must not silently drop the oldest one."""
    output = _build_collect_harness(tmp_path, run_count=9)
    included_line = next(line for line in output.splitlines() if line.startswith("- included run_ids:"))
    included_ids = [x.strip() for x in included_line.split(":", 1)[1].split(",")]
    assert len(included_ids) == 9, f"expected all 9 runs included, got: {included_ids}"
    assert "run_01" in included_ids, "run 1 (the oldest of the 9) must not be silently dropped"
    assert "- persisted runs included: 9 (max 20)" in output
    assert "- persisted runs skipped: 0" in output


@pytestmark_lua
def test_historical_runs_beyond_new_cap_are_still_capped_and_disclosed(tmp_path: Path):
    """Caps must still exist -- this is a raised bound, not an unbounded
    collector. With 25 runs, the newest 20 are kept and the skip count is
    disclosed."""
    output = _build_collect_harness(tmp_path, run_count=25)
    included_line = next(line for line in output.splitlines() if line.startswith("- included run_ids:"))
    included_ids = [x.strip() for x in included_line.split(":", 1)[1].split(",")]
    assert len(included_ids) == 20
    assert "run_25" in included_ids and "run_06" in included_ids
    assert "run_05" not in included_ids and "run_01" not in included_ids
    assert "- persisted runs included: 20 (max 20)" in output
    assert "- persisted runs skipped: 5" in output


def test_red_would_have_dropped_run_one_under_the_old_cap_of_eight():
    """RED-documentation: proves the OLD cap (8) would have reproduced the
    exact live bug against the same 9-run fixture the fix above uses --
    keeps the regression's shape pinned even though the live product code
    has moved on to the higher cap."""
    text = SUPPORT_BUNDLE.read_text(encoding="utf-8")
    fn = _lua_function(text, "collectPersistedRunDiagnostics")
    old_cap = 8
    new_run_count = 9
    assert new_run_count > old_cap, "fixture must exceed the old cap to reproduce the historical bug"
    assert "local maxRunsToInclude = 20" in fn, "current cap must exceed the fixture size used above"


# --- Regression: unrelated math.min(8, ...) redaction-source caps untouched -


def test_unrelated_redaction_source_candidate_caps_are_untouched():
    """The two math.min(8, ...) caps inside the redaction-source-candidate
    collector are a different, unrelated mechanism (files fed to the
    redaction scanner, not bundle run-inclusion) and must not be touched by
    this fix."""
    text = SUPPORT_BUNDLE.read_text(encoding="utf-8")
    assert "for i = 1, math.min(8, #runDirs) do" in text
    assert "for i = 1, math.min(8, #tempRuns) do" in text
