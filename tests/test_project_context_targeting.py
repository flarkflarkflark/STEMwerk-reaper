"""Structural/source-level regression tests for GitHub issue #91
(project-targeting import): completed stems must import back into the
REAPER project that requested processing, never into whatever project is
active when processing finishes.

Behavioral coverage of the decision logic itself (capture / liveness /
anchor validation / scoped select-run-restore, including the concurrent-run,
tab-switch, origin-closed, same-path-reopen, rename/save, and
exception-during-import scenarios) lives in
tests/lua/test_project_context.lua against the real pure module
(scripts/reaper/_internal/STEMwerk_Project_Context.lua) via a mocked
`reaper` API table.

STEMwerk.lua/STEMwerk_Workflow.lua drive REAPER's gfx/defer UI loop and
cannot be headlessly loaded end-to-end (no REAPER GUI mock exists in this
repo). This file pins the WIRING that the headless module test cannot
reach: that the origin project is captured at the right moment (once, before
any async work is launched, not re-captured per job/tab-switch/import), that
both real import entry points are routed through the fail-closed guard, that
the fail-closed messaging exists and preserves outputs, and that no
ReaProject*/project reference ever crosses the Python worker boundary.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
REAPER_DIR = ROOT / "scripts" / "reaper"
STEMWERK_LUA = REAPER_DIR / "STEMwerk.lua"
WORKFLOW_LUA = REAPER_DIR / "_internal" / "STEMwerk_Workflow.lua"
PROJECT_CONTEXT_LUA = REAPER_DIR / "_internal" / "STEMwerk_Project_Context.lua"
SEPARATOR_PY = REAPER_DIR / "audio_separator_process.py"
LUA_TEST = ROOT / "tests" / "lua" / "test_project_context.lua"

LUA_CANDIDATES = [
    shutil.which("lua"),
    shutil.which("lua5.4"),
    shutil.which("luajit"),
    r"C:\Users\Administrator\AppData\Local\Programs\Lua\bin\lua.exe",
]


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def _lua_interpreter():
    for candidate in LUA_CANDIDATES:
        if candidate and Path(candidate).exists():
            return candidate
    return None


def test_project_context_module_exists_with_pure_helpers():
    assert PROJECT_CONTEXT_LUA.exists(), "STEMwerk_Project_Context.lua module missing"
    src = _read(PROJECT_CONTEXT_LUA)
    for fn in (
        "function M.capture",
        "function M.isProjectStillOpen",
        "function M.validateOriginProjectContext",
        "function M.withProjectInstance",
        "function M.restoreProjectInstance",
    ):
        assert fn in src, f"{fn} missing from STEMwerk_Project_Context.lua"


def test_project_context_lua_regression_suite():
    lua = _lua_interpreter()
    if not lua:
        pytest.skip("no Lua interpreter available")
    proc = subprocess.run(
        [lua, str(LUA_TEST)],
        capture_output=True,
        text=True,
        cwd=str(ROOT),
        timeout=120,
    )
    output = proc.stdout + proc.stderr
    assert proc.returncode == 0, f"Lua regression suite failed:\n{output}"
    assert "RESULT: all tests passed" in output


class TestOriginCaptureOnce:
    """Section 3/4: the requesting project is captured exactly once per
    accepted processing action, before any async work is launched -- never
    re-captured in a progress loop, completion callback, or import
    function."""

    def test_run_context_captures_project_before_multi_track_dispatch(self):
        src = _read(STEMWERK_LUA)
        create_pos = src.find("progressState.runContext = {\n        schema = 1,")
        assert create_pos != -1, "RunContext creation site in runSeparationWorkflow not found"
        dispatch_pos = src.find("_sep.runSingleTrackSeparation(trackList)", create_pos)
        assert dispatch_pos != -1
        assert create_pos < dispatch_pos, (
            "RunContext (and its captured project) must be created before "
            "the multi-track dispatch, so the SAME captured project is used "
            "whether the run stays single-track or switches to multi-track"
        )
        window = src[create_pos:create_pos + 800]
        assert "PROJECT_CONTEXT.capture(reaper, selectedItem, requestingProjectAnchorTracks)" in window

    def test_project_is_not_recaptured_in_progress_loop_or_import_functions(self):
        # PROJECT_CONTEXT.capture must only be called at RunContext creation
        # sites (runSeparationWorkflow's primary creation, and
        # _sep.runSingleTrackSeparation's defensive same-call-stack fallback
        # for entry without going through runSeparationWorkflow first) --
        # never inside the progress loop, completion callback, or import
        # functions themselves.
        stemwerk_src = _read(STEMWERK_LUA)
        workflow_src = _read(WORKFLOW_LUA)
        capture_call_count = stemwerk_src.count("PROJECT_CONTEXT.capture(")
        assert capture_call_count == 2, (
            f"expected exactly 2 PROJECT_CONTEXT.capture(...) call sites "
            f"(runSeparationWorkflow + _sep.runSingleTrackSeparation "
            f"defensive fallback), found {capture_call_count}"
        )
        assert "PROJECT_CONTEXT.capture(" not in workflow_src, (
            "the progress loop / completion callback module must never "
            "recapture the origin project"
        )

    def test_multi_track_queue_shares_the_same_run_context(self):
        src = _read(STEMWERK_LUA)
        assert "multiTrackQueue.runContext = progressState.runContext" in src, (
            "multi-track queue must reuse the single RunContext (and its "
            "captured project) created once per processing action, not a "
            "separately-captured one"
        )


class TestFailClosedNoActiveProjectFallback:
    """Section 8 (absolute invariant): if the origin project cannot be
    proven live, import must never fall back to whatever project is
    currently active."""

    def test_single_track_import_is_gated_by_origin_validation(self):
        src = _read(WORKFLOW_LUA)
        assert "local function importStemsRespectingOriginProject(stems)" in src
        gate_pos = src.find("local function importStemsRespectingOriginProject(stems)")
        fn_end = src.find("\n-- Finish separation after progress completes", gate_pos)
        assert fn_end != -1
        body = src[gate_pos:fn_end]
        assert "PROJECT_CONTEXT.validateOriginProjectContext(reaper, runCtx)" in body
        assert "if not originOk then\n        return false, originReason\n    end" in body
        # The real import call must be inside the scoped withProjectInstance
        # wrapper, never called unconditionally/outside origin validation.
        validate_pos = body.find("PROJECT_CONTEXT.validateOriginProjectContext")
        scoped_pos = body.find("PROJECT_CONTEXT.withProjectInstance")
        process_pos = body.find("processStemsResult(stems)")
        assert validate_pos != -1 and scoped_pos != -1 and process_pos != -1
        assert validate_pos < scoped_pos < process_pos, (
            "origin must be validated BEFORE the scoped select/import runs"
        )

    def test_multi_track_import_is_gated_by_origin_validation(self):
        src = _read(STEMWERK_LUA)
        assert "_sep.importAllStemsRespectingOriginProject = function()" in src
        gate_pos = src.find("_sep.importAllStemsRespectingOriginProject = function()")
        fn_end = src.find("\n-- Process all stems after parallel jobs complete", gate_pos)
        assert fn_end != -1
        body = src[gate_pos:fn_end]
        assert "PROJECT_CONTEXT.validateOriginProjectContext(reaper, runCtx)" in body
        validate_pos = body.find("PROJECT_CONTEXT.validateOriginProjectContext")
        scoped_pos = body.find("PROJECT_CONTEXT.withProjectInstance")
        call_pos = body.find("_sep.processAllStemsResult()")
        assert validate_pos != -1 and scoped_pos != -1 and call_pos != -1
        assert validate_pos < scoped_pos < call_pos

    def test_both_real_entry_points_are_routed_through_the_guard(self):
        # The two genuine import entry points in the whole codebase must be
        # called ONLY through the origin-respecting wrapper, never directly
        # from a progress loop.
        stemwerk_src = _read(STEMWERK_LUA)
        workflow_src = _read(WORKFLOW_LUA)
        assert stemwerk_src.count("_sep.processAllStemsResult()") == 1, (
            "_sep.processAllStemsResult() must have exactly one caller: "
            "_sep.importAllStemsRespectingOriginProject"
        )
        assert "_sep.importAllStemsRespectingOriginProject()" in stemwerk_src
        assert workflow_src.count("return processStemsResult(stems)") == 1, (
            "processStemsResult(stems) must be called exactly once, from "
            "inside importStemsRespectingOriginProject's scoped wrapper"
        )
        assert "local importOk = processStemsResult(stems)" not in workflow_src, (
            "the old unwrapped/unvalidated call site must be gone"
        )
        assert "importStemsRespectingOriginProject(stems)" in workflow_src

    def test_fail_closed_message_present_for_both_paths(self):
        stemwerk_src = _read(STEMWERK_LUA)
        workflow_src = _read(WORKFLOW_LUA)
        for src in (stemwerk_src, workflow_src):
            assert "Original Project Unavailable" in src
            assert "Stems were not imported" in src
            assert "Outputs remain available at" in src

    def test_never_falls_back_to_active_project_on_origin_failure(self):
        # There must be no code path where, after validateOriginProjectContext
        # returns not-ok, the wrapper proceeds to call the real import
        # function anyway.
        workflow_src = _read(WORKFLOW_LUA)
        gate_pos = workflow_src.find("local function importStemsRespectingOriginProject(stems)")
        fn_end = workflow_src.find("\n-- Finish separation after progress completes", gate_pos)
        body = workflow_src[gate_pos:fn_end]
        not_ok_branch = body.split("if not originOk then", 1)[1].split("end", 1)[0]
        assert "processStemsResult" not in not_ok_branch

        stemwerk_src = _read(STEMWERK_LUA)
        gate_pos2 = stemwerk_src.find("_sep.importAllStemsRespectingOriginProject = function()")
        fn_end2 = stemwerk_src.find("\n-- Process all stems after parallel jobs complete", gate_pos2)
        body2 = stemwerk_src[gate_pos2:fn_end2]
        not_ok_branch2 = body2.split("if not originOk then", 1)[1].split("return\n    end", 1)[0]
        assert "_sep.processAllStemsResult()" not in not_ok_branch2


class TestOutputsPreservedOnImportBlocked:
    """Section 8/15: when origin is unavailable (or import raises), the
    generated stems must remain preserved -- never cleaned up as if the run
    failed outright, and never silently deleted."""

    def test_single_track_cleanup_gate_unchanged_and_still_reachable(self):
        src = _read(WORKFLOW_LUA)
        assert "success = (importOk ~= false), keepStemPaths = stems" in src
        # importStemsRespectingOriginProject returns importOk == false for
        # BOTH an origin-unavailable block and an import exception, so the
        # existing cleanup gate (unmodified) naturally skips destructive
        # cleanup and preserves every generated stem file in both cases.

    def test_dks_regression_suite_updated_for_the_new_call_site(self):
        # tests/test_dks_extract_import_invariants.py pins the literal
        # single-track import call site; it must track the wrapped call,
        # not the old bare processStemsResult(stems) call.
        dks_test_src = _read(ROOT / "tests" / "test_dks_extract_import_invariants.py")
        assert "importStemsRespectingOriginProject(stems)" in dks_test_src
        assert "success = (importOk ~= false)" in dks_test_src


class TestNoProjectPointerCrossesWorkerBoundary:
    """Section 11/16: ReaProject*/project pointers must never be passed to
    the Python worker (env var, file, or argv), and must never be
    serialized. Only run_id/job_id diagnostics identity crosses that
    boundary, exactly as already implemented."""

    def test_project_ref_never_referenced_near_python_invocation(self):
        for path in (STEMWERK_LUA, WORKFLOW_LUA):
            src = _read(path)
            for marker in ("os.execute", "ExecProcess", "io.popen", "quoteArg(PYTHON_PATH"):
                idx = 0
                while True:
                    idx = src.find(marker, idx)
                    if idx == -1:
                        break
                    window = src[max(0, idx - 400):idx + 400]
                    assert ".project.ref" not in window, (
                        f"{path.name}: found project.ref near a process-launch "
                        f"call ({marker}); project identity must never cross "
                        f"the worker boundary"
                    )
                    assert ".project.anchors" not in window
                    idx += len(marker)

    def test_separator_script_has_no_project_reference(self):
        src = _read(SEPARATOR_PY)
        assert "ReaProject" not in src
        assert "project_ref" not in src.lower().replace("_", "")

    def test_project_context_module_never_touches_run_id_or_job_id(self):
        # Hard separation of concerns: the project-targeting module must
        # never read/write run_id or job_id (diagnostics identity is a
        # completely separate concern owned by STEMwerk_Log.lua's accepted
        # RunContext authority design).
        # Functional usage only (e.g. `.run_id`, `run_id =`) -- the module's
        # own header comment explains the boundary in prose using the plain
        # words "run_id"/"job_id", which is fine and expected.
        import re

        src = _read(PROJECT_CONTEXT_LUA)
        assert re.search(r"\.run_id\b|run_id\s*=", src) is None
        assert re.search(r"\.job_id\b|job_id\s*=", src) is None


class TestRunContextAuthorityUntouched:
    """Explicit scope-boundary guard: this change must not touch the
    accepted RunContext diagnostics-authority logic (run_id/job_id
    semantics, worker_context validation, current_processing selection,
    strict JSON, etc.)."""

    def test_diagnostics_authority_files_not_touched(self):
        import subprocess as sp

        result = sp.run(
            ["git", "diff", "--name-only", "011ab8f5d8ea863d01d9acab27b97654967510e7", "--"],
            capture_output=True, text=True, cwd=str(ROOT),
        )
        if result.returncode != 0:
            pytest.skip("git history unavailable in this environment")
        changed = set(result.stdout.strip().splitlines())
        forbidden = {
            "scripts/reaper/STEMwerk_Save_Support_Bundle.lua",
            "scripts/reaper/_internal/STEMwerk_Log.lua",
        }
        touched = changed & forbidden
        assert not touched, f"diagnostics-authority files must not be touched: {touched}"


class TestLocalVariableCeiling:
    """Section 22: STEMwerk.lua was already at 199/200 top-level `local`
    declarations before this change; this commit must add zero."""

    def test_top_level_local_count_unchanged_by_this_commit(self):
        text = _read(STEMWERK_LUA)
        count = sum(1 for line in text.splitlines() if line.startswith("local "))
        assert count == 199, (
            f"STEMwerk.lua has {count} top-level local declarations; this "
            f"commit must add none (new state belongs on existing tables "
            f"or as global function/table-field definitions, exactly like "
            f"DKS_IMPORT/PROJECT_CONTEXT above)"
        )
