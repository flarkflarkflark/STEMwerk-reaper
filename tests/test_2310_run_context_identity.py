"""Structural/source-level regression tests for the 2.3.1.0 RunContext /
JobContext identity plumbing (implementation step 1 of GitHub issue #91's
two-step design -- project-targeting itself is explicitly NOT part of this
change and is not touched or tested here).

STEMwerk.lua and STEMwerk_Workflow.lua drive REAPER's gfx/defer UI loop and
are not exercised by a headless Lua harness (there is no REAPER mock for
that surface in this repo). The currentness/health BEHAVIOR these identity
fields feed into (deriveCurrentWorkerRunHealth, probeWorkerJobEvidence) is
covered end-to-end against real production code by
tests/support/run_support_bundle_headless.lua (structured-identity-*,
mismatched-job-run-id-*, missing-job-identity-*, replayed-structured-context-*
scenarios). This file pins the plumbing that headless suite cannot reach:
where run_id is generated and propagated, that it is a real GUID (not a
timestamp/dir-name derivation), that job_id assignment matches the
single/item_N/track_N convention, that the same run_id survives Kit
Split's stage1/stage2 and Direct Kit's helper subprocess boundary, and that
persisted evidence carries the structured identity file through unchanged.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STEMWERK_LUA = ROOT / "scripts" / "reaper" / "STEMwerk.lua"
WORKFLOW_LUA = ROOT / "scripts" / "reaper" / "_internal" / "STEMwerk_Workflow.lua"
LOG_LUA = ROOT / "scripts" / "reaper" / "_internal" / "STEMwerk_Log.lua"
SUPPORT_BUNDLE_LUA = ROOT / "scripts" / "reaper" / "STEMwerk_Save_Support_Bundle.lua"
SEPARATOR_PY = ROOT / "scripts" / "reaper" / "audio_separator_process.py"
DRUMSEP_HELPER_PY = ROOT / "scripts" / "reaper" / "_internal" / "stemwerk_drumsep_process.py"


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class TestAuthoritativeRunIdGeneration:
    """Section 2/15A: one authoritative run_id per accepted processing
    action, sourced from reaper.genGuid() -- never derived from a
    timestamp, directory name, or path."""

    def test_run_context_created_once_in_run_separation_workflow(self):
        text = _read(STEMWERK_LUA)
        # Created inside runSeparationWorkflow(), which is the single Process
        # click / quick-preset entry point (both routes call this function;
        # see checkQuickPreset()'s deferred call site). runSeparationWorkflow
        # is defined LATER in the file than the multi-track queue entry
        # point's own defensive fallback, so scope the search to this
        # function's own body rather than the first textual occurrence.
        start = text.index("function runSeparationWorkflow(originProjectContext)")
        body = text[start:start + 20000]
        assert "progressState.runContext = {" in body, (
            "RunContext creation must live inside runSeparationWorkflow(), "
            "the accepted Process-click/quick-preset entry point, stored "
            "on the existing per-run progressState table"
        )

    def test_run_id_sourced_from_reaper_gen_guid(self):
        text = _read(STEMWERK_LUA)
        assert "reaper.genGuid()" in text, (
            "run_id must be sourced from reaper.genGuid() (authoritative "
            "logical identity), not any timestamp/path derivation"
        )

    def test_run_id_is_not_derived_from_run_dir_name(self):
        text = _read(STEMWERK_LUA)
        start = text.index("function runSeparationWorkflow(originProjectContext)")
        window = text[start:start + 20000]
        ctx_start = window.index("progressState.runContext = {")
        block = window[ctx_start:ctx_start + 500]
        assert "run_id = (reaper and reaper.genGuid" in block, (
            "run_id field must come from reaper.genGuid(), not from "
            "WORKFLOW_TEMP_DIR / makeUniqueTempSubdir's generated name"
        )
        assert "run_dir_name = WORKFLOW_TEMP_DIR" in block, (
            "run_dir_name stays the physical temp-dir locator, kept "
            "textually distinct from the run_id field"
        )

    def test_multi_track_path_reuses_same_run_context_not_a_new_one(self):
        text = _read(STEMWERK_LUA)
        # _sep.runSingleTrackSeparation (the multi-track queue entry point)
        # must reuse progressState.runContext rather than manufacturing a
        # fresh run_id whenever it is reached from runSeparationWorkflow().
        start = text.index("_sep.runSingleTrackSeparation = function(trackList)")
        window = text[start:start + 4000]
        assert "if not progressState.runContext then" in window, (
            "multi-track entry point must reuse an existing RunContext "
            "when one was already created by runSeparationWorkflow(), "
            "only falling back to creating one defensively"
        )
        assert 'progressState.runContext.run_dir_name = baseTempDir' in window, (
            "run_dir_name must be updated to the actual base temp dir "
            "the multi-track queue uses, while run_id stays unchanged"
        )

    def test_multi_track_queue_shares_run_context_reference(self):
        text = _read(STEMWERK_LUA)
        assert "multiTrackQueue.runContext = progressState.runContext" in text, (
            "multiTrackQueue must reference (not copy/regenerate) the same "
            "RunContext so every job launched from the queue inherits the "
            "identical run_id"
        )


class TestNoGlobalMutableCurrentRunState:
    """Section 5: RunContext must be stored in the existing per-run state
    table, not a new global that two concurrent script instances could
    stomp on."""

    def test_no_new_top_level_local_declarations_added(self):
        # Hard release-breaking constraint: STEMwerk.lua was already at
        # 199/200 top-level `local` declarations before this change. New
        # state must be added as fields on existing tables (progressState,
        # multiTrackQueue, per-job tables), never as new top-level locals.
        text = _read(STEMWERK_LUA)
        count = sum(
            1 for line in text.splitlines() if line.startswith("local ")
        )
        assert count <= 200, (
            f"STEMwerk.lua has {count} top-level local declarations; "
            "Lua's 200-local-per-chunk limit must not be exceeded"
        )


class TestJobIdAssignment:
    """Section 3/15B/15C: smallest existing natural identities
    (single/item_N/track_N), unique within a run, stable across a job's
    own stage1/stage2, distinct across parallel jobs."""

    def test_per_item_job_gets_item_n_job_id(self):
        text = _read(STEMWERK_LUA)
        assert 'jobId = "item_" .. jobIndex,' in text, (
            "per-item multi-track jobs must carry jobId = item_<index>, "
            "matching the item_N directory naming already used"
        )

    def test_per_track_job_gets_track_n_job_id(self):
        text = _read(STEMWERK_LUA)
        assert 'jobId = "track_" .. jobIndex,' in text, (
            "per-track multi-track jobs must carry jobId = track_<index>, "
            "matching the track_N directory naming already used"
        )

    def test_single_track_path_uses_single_job_id(self):
        text = _read(WORKFLOW_LUA)
        assert 'local jobIdArg = "single"' in text, (
            "the single-track WORKFLOW.startSeparationProcess path must "
            "use job_id='single', matching its existing 'single' job tag "
            "convention"
        )

    def test_job_launcher_uses_job_own_id_not_only_index(self):
        text = _read(STEMWERK_LUA)
        start = text.index("_sep.startSeparationProcessForJob = function(job, segmentSize)")
        window = text[start:start + 2500]
        assert "local jobIdArg = job.jobId or jobTag" in window, (
            "the per-job launcher must prefer the job's own explicit "
            "jobId (item_N/track_N) over the numeric-only jobTag fallback"
        )


class TestWorkerEnvPropagation:
    """Section 6: only run_id/job_id (plus the physical run_dir_name and
    started_utc needed to populate worker_context.json) cross the process
    boundary -- never a ReaProject*/userdata/project-targeting state."""

    def test_env_vars_use_stemwerk_prefix_matching_existing_convention(self):
        text = _read(STEMWERK_LUA)
        for var in (
            "STEMWERK_RUN_ID",
            "STEMWERK_JOB_ID",
            "STEMWERK_RUN_DIR_NAME",
            "STEMWERK_RUN_STARTED_UTC",
        ):
            assert var in text, f"{var} must be set for worker launches in STEMwerk.lua"
            assert var in _read(WORKFLOW_LUA), (
                f"{var} must also be set for the single-track launch path in STEMwerk_Workflow.lua"
            )

    def test_all_four_job_launch_mechanisms_carry_run_identity(self):
        # STEMwerk.lua's startSeparationProcessForJob has four launch
        # mechanisms: Windows PowerShell (hidden), Windows foreground
        # fallback, Unix background sh launcher, Unix foreground fallback.
        # Every one of them must carry the run identity env vars, or a
        # platform/fallback combination would silently lose identity.
        text = _read(STEMWERK_LUA)
        start = text.index("_sep.startSeparationProcessForJob = function(job, segmentSize)")
        end = text.index("\n_sep.getProgressTotalUnits", start)
        window = text[start:end]
        assert window.count("STEMWERK_RUN_ID") >= 4, (
            "expected STEMWERK_RUN_ID to be set on all four job launch "
            "mechanisms (Windows psInner, Windows fallback, Unix sh "
            "launcher, Unix fallback)"
        )

    def test_no_reaproject_pointer_passed_to_worker(self):
        text = _read(STEMWERK_LUA)
        start = text.index("_sep.startSeparationProcessForJob = function(job, segmentSize)")
        end = text.index("\n_sep.getProgressTotalUnits", start)
        window = text[start:end]
        assert "ReaProject" not in window, (
            "worker launch must never pass a ReaProject*/project pointer "
            "across the process boundary -- diagnostic identity only"
        )


class TestPythonWorkerContextEvidence:
    """Section 7: structured worker_context.json evidence, shared
    unchanged across Kit Split's stage1/stage2 (same process, same env)
    and echoed into Direct Kit's helper subprocess evidence."""

    def test_write_worker_context_helper_exists(self):
        text = _read(SEPARATOR_PY)
        assert "def _write_worker_context(" in text
        assert '"schema": 1' in text
        assert '"run_id": run_id' in text
        assert '"job_id": job_id' in text

    def test_write_worker_context_called_once_before_flow_branching(self):
        text = _read(SEPARATOR_PY)
        write_call_idx = text.index("_write_worker_context(args.output_dir")
        # The Kit Split (dks_extract) stage1/stage2 branch point.
        dks_branch_idx = text.index("_is_extract_dks_source(args.workflow_mode, args.workflow_source)")
        assert write_call_idx < dks_branch_idx, (
            "worker_context.json must be written once, before Normal/"
            "6-Stem/Direct-Kit/Kit-Split flow branching, so stage1 and "
            "stage2 of Kit Split share identical identity evidence "
            "written by the same process"
        )
        call_sites = text.count("_write_worker_context(args.output_dir")
        assert call_sites == 1, (
            f"worker_context.json must be written exactly once per worker "
            f"process invocation, not per stage (found {call_sites} call sites)"
        )

    def test_worker_context_reads_identity_from_env_not_argv_reparsing(self):
        text = _read(SEPARATOR_PY)
        start = text.index("def _write_worker_context(")
        end = text.index("\n\n\n", start)
        body = text[start:end]
        assert 'os.environ.get("STEMWERK_RUN_ID"' in body
        assert 'os.environ.get("STEMWERK_JOB_ID"' in body
        assert 'os.environ.get("STEMWERK_RUN_DIR_NAME"' in body
        assert 'os.environ.get("STEMWERK_RUN_STARTED_UTC"' in body

    def test_direct_kit_helper_echoes_parent_run_and_job_id(self):
        text = _read(DRUMSEP_HELPER_PY)
        start = text.index("def write_result(")
        end = text.index("\n\n\n", start)
        body = text[start:end]
        assert 'os.environ.get("STEMWERK_RUN_ID"' in body
        assert 'os.environ.get("STEMWERK_JOB_ID"' in body
        assert '"run_id": run_id' in body
        assert '"job_id": job_id' in body

    def test_direct_kit_helper_env_inherits_via_clean_env_not_filtered(self):
        # build_drumsep_subprocess_env's base env comes from _clean_env(),
        # which is dict(os.environ) with a small explicit removal list.
        # STEMWERK_RUN_ID/STEMWERK_JOB_ID must not be in that removal list,
        # or the helper subprocess would silently lose parent identity.
        text = _read(SEPARATOR_PY)
        start = text.index("def _clean_env(")
        end = text.index("\n\n\n", start)
        body = text[start:end]
        assert "STEMWERK_RUN_ID" not in body
        assert "STEMWERK_JOB_ID" not in body


class TestPersistedRunDiagnosticsPreserveStructuredIdentity:
    """Section 8: worker_context.json must survive both persistence paths
    (STEMwerk_Log.persistRunDiagnostics and the support bundle's own
    collectPersistedRunDiagnostics whitelist) unchanged."""

    def test_stemwerk_log_persist_run_diagnostics_copies_worker_context(self):
        text = _read(LOG_LUA)
        start = text.index("function SW_LOG.persistRunDiagnostics(")
        end = text.index("\nend", start)
        body = text[start:end]
        assert '"worker_context.json"' in body

    def test_support_bundle_collector_whitelist_includes_worker_context(self):
        text = _read(SUPPORT_BUNDLE_LUA)
        start = text.index("local function collectPersistedRunDiagnostics(")
        end = text.index("local nestedAllowed", start)
        body = text[start:end]
        assert '["worker_context.json"] = true' in body


class TestCurrentProcessingStateConcurrencyDesign:
    """Section 9: current-processing state is a keyed-by-run_id registry
    (one file per run_id), not a single shared pointer -- so two
    concurrent STEMwerk script instances cannot overwrite each other's
    run identity."""

    def test_current_processing_dir_is_keyed_by_run_id_not_a_single_file(self):
        text = _read(LOG_LUA)
        assert "function SW_LOG.getCurrentProcessingDir()" in text
        start = text.index("function SW_LOG.writeCurrentProcessingState(")
        end = text.index("\nend", text.index("return path", start))
        body = text[start:end]
        assert 'tostring(runContext.run_id) .. ".json"' in body, (
            "each run's current-processing state must be written to its "
            "own <run_id>.json file, not a single shared pointer path"
        )

    def test_status_transitions_wired_at_completion_and_cancel_points(self):
        stemwerk_text = _read(STEMWERK_LUA)
        workflow_text = _read(WORKFLOW_LUA)
        assert 'SW_LOG.writeCurrentProcessingState(progressState.runContext, "running")' in stemwerk_text
        assert 'SW_LOG.writeCurrentProcessingState(progressState.runContext, "completed")' in stemwerk_text
        assert 'SW_LOG.writeCurrentProcessingState(multiTrackQueue.runContext' in stemwerk_text
        assert 'SW_LOG.writeCurrentProcessingState(multiTrackQueue.runContext, "cancelled")' in stemwerk_text
        assert 'SW_LOG.writeCurrentProcessingState(C.progressState.runContext, "cancelled")' in workflow_text


class TestSupportBundleReadsCurrentProcessingRegistry:
    """Section 10/16/17: support-bundle diagnostics reads the whole
    current_processing directory (not a single latest-wins file), and
    structured run_id identity -- not timestamps -- decides current vs
    recent_unlinked vs historical. Full behavioral coverage of this logic
    lives in tests/support/run_support_bundle_headless.lua; this pins the
    call-site wiring that produces the records that suite consumes."""

    def test_read_current_processing_records_helper_exists(self):
        text = _read(SUPPORT_BUNDLE_LUA)
        assert "local function readCurrentProcessingRecords(cacheLogDir)" in text

    def test_derive_current_worker_run_health_accepts_current_processing_records(self):
        text = _read(SUPPORT_BUNDLE_LUA)
        assert (
            "local function deriveCurrentWorkerRunHealth(runsRoot, nowEpoch, "
            "sessionStartedUtc, sessionId, currentProcessingRecords)"
        ) in text

    def test_call_site_passes_current_processing_records(self):
        text = _read(SUPPORT_BUNDLE_LUA)
        start = text.index("local currentWorkerHealth = deriveCurrentWorkerRunHealth(")
        window = text[start:start + 400]
        assert "readCurrentProcessingRecords(cacheLogDir)" in window

    def test_legacy_session_path_can_never_grant_current_status(self):
        # Follow-up hardening (release/2.3.1.0-final-prep, closing the gap
        # the prior commit's own author disclosed): the additive tradeoff
        # this test used to pin -- the legacy session-timestamp heuristic
        # stays live and is only VETOED when a structured mismatch is also
        # present -- was exactly the authority bypass this hardening
        # closes. It is not merely vetoed on conflict any more; it can
        # never independently set isCurrent at all. deriveCurrentWorkerRunHealth
        # now computes isCurrent as structuredMatch narrowed by
        # physicalDirBound (the later release/2.3.1.0-final-prep delta
        # closing the physical run-directory binding gap: matching the
        # selected record's run_id is necessary but no longer sufficient,
        # the run directory's own name must also equal the selected
        # record's run_dir_name) -- the pre-existing session-timestamp/
        # marker evidence -- sessionCurrent, runStartIso, sessionIdConflict
        # -- feeds ONLY the legacy_unlinked/recent_unlinked provenance
        # split below, never currentness itself). Full behavioral coverage
        # (every one of the ~88 pre-existing headless scenarios that
        # predate structured identity, migrated onto genuine structured
        # evidence where their expectations relied on the old authority
        # path, plus new fixtures for the closed gap) lives in
        # tests/support/run_support_bundle_headless.lua.
        text = _read(SUPPORT_BUNDLE_LUA)
        start = text.index("local function deriveCurrentWorkerRunHealth(")
        end = text.index("\nend", text.index("return result", start))
        body = text[start:end]
        assert "local isCurrent = structuredMatch and physicalDirBound\n" in body, (
            "isCurrent must be assigned structuredMatch narrowed only by "
            "physicalDirBound -- no `or (sessionCurrent and ...)` fallback "
            "may reintroduce the legacy authority bypass this hardening "
            "closes"
        )
        assert " or (sessionCurrent" not in body, (
            "isCurrent must never be widened by an `or` fallback onto the "
            "legacy session-timestamp signal"
        )
        assert "sessionCurrent and runStartIso >= sessionStartedUtc" in body, (
            "the legacy session-timestamp signal must still be computed "
            "and readable as provenance (legacy_unlinked classification), "
            "just never wired into isCurrent itself"
        )

# NOTE: a `TestProjectTargetingUntouched` guard previously lived here,
# asserting that commit-2 (GitHub issue #91 project-targeting) had not yet
# been implemented. That phase boundary has now been reached intentionally
# (release/2.3.1.0-final-prep implements project-targeting import in
# STEMwerk.lua/STEMwerk_Workflow.lua/STEMwerk_Project_Context.lua), so the
# guard's premise no longer holds and it has been removed. See
# tests/lua/test_project_context.lua and
# tests/test_project_context_targeting.py for project-targeting coverage.
