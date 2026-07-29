"""Regression contracts for the dks_extract (Kit Split) import failure.

Root cause (fixed in 2.3.1.0): SETTINGS_MOD.load() re-derived the workflow
stem set on every settings load and activated the DRUMKIT set only for
dks_direct. A mid-run settings reload (WORKFLOW.runSeparationWithProgress)
therefore reset the global STEMS to the standard set during dks_extract runs,
which made HELPERS.finalizeStemFiles discard the six validated kit output
paths. The importer then created 0 tracks while the UI reported success.

These tests pin the fix and the hard success invariants:
- settings loads must not touch the stem set while a run is active
- the import handoff uses the validated output map, not the global STEMS
- imported-track count must equal the validated output count, otherwise the
  workflow fails loudly (no green completion dialog, outputs preserved)
"""

import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
REAPER_DIR = ROOT / "scripts" / "reaper"
MAIN_LUA = REAPER_DIR / "STEMwerk.lua"
SETTINGS_LUA = REAPER_DIR / "_internal" / "STEMwerk_Settings.lua"
HELPERS_LUA = REAPER_DIR / "_internal" / "STEMwerk_Helpers.lua"
WORKFLOW_LUA = REAPER_DIR / "_internal" / "STEMwerk_Workflow.lua"
DKS_IMPORT_LUA = REAPER_DIR / "_internal" / "STEMwerk_DKS_Import.lua"
SUPPORT_BUNDLE_LUA = REAPER_DIR / "STEMwerk_Save_Support_Bundle.lua"
LUA_TEST = ROOT / "tests" / "lua" / "test_dks_import_flow.lua"

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


def test_dks_import_module_exists_with_pure_helpers():
    assert DKS_IMPORT_LUA.exists(), "STEMwerk_DKS_Import.lua module missing"
    src = _read(DKS_IMPORT_LUA)
    assert "function M.validateImportResult" in src
    assert "function M.expectedTracksForItems" in src
    assert "function M.normalizeStemPathKey" in src
    assert "function M.collectStemPathsFromStdoutJson" in src


def test_settings_load_never_clobbers_stemset_during_run():
    src = _read(SETTINGS_LUA)
    assert "runContextActive" in src, "settings load must detect an active run context"
    guard_pos = src.find("runContextActive")
    activate_pos = src.find("C.activateWorkflowStemSet(directWorkflow")
    assert activate_pos != -1
    assert guard_pos < activate_pos, "run-context guard must precede stem-set activation"
    assert "not runContextActive then" in src


def test_finalize_stem_files_uses_validated_map_set_not_global_stems():
    src = _read(HELPERS_LUA)
    assert "function HELPERS.finalizeStemFiles(stems, sourceTrackName, sourceItemName, stemSet)" in src
    assert "and stemSet or STEMS" in src, "explicit stem set must win, global STEMS only as fallback"


def test_process_stems_result_passes_resolved_set_and_validates_import():
    src = _read(MAIN_LUA)
    assert (
        "HELPERS.finalizeStemFiles(stems, sourceTrackName, sourceItemName, resolveStemSetForPaths(stems))"
        in src
    ), "import handoff must resolve the stem set from the validated output map"
    assert "DKS_IMPORT.validateImportResult(dksExpectedOutputs" in src
    assert 'SW_LOG.logExecResult("dks_expected_output_count=" ' in src
    assert 'SW_LOG.logExecResult("dks_imported_track_count=" ' in src
    assert 'SW_LOG.logExecResult("dks_import_validation_reason=" ' in src
    assert '"workflow_success=no"' in src
    assert '"workflow_failure_reason=" ' in src
    assert '"workflow_success=yes"' in src


def test_false_success_is_impossible_on_import_mismatch():
    src = _read(MAIN_LUA)
    verdict_pos = src.find("DKS_IMPORT.validateImportResult(dksExpectedOutputs")
    result_window_pos = src.find("showResultWindow(selectedStemData, resultData or resultMsg)")
    assert verdict_pos != -1 and result_window_pos != -1
    assert verdict_pos < result_window_pos, (
        "the import verdict must gate the green completion dialog"
    )
    fail_block = src[verdict_pos:result_window_pos]
    assert 'showMessage("Kit Split Failed"' in fail_block
    assert "return false" in fail_block
    assert "were preserved for recovery" in fail_block


def test_finish_separation_preserves_outputs_on_import_failure():
    src = _read(WORKFLOW_LUA)
    assert "local importOk = processStemsResult(stems)" in src
    assert "success = (importOk ~= false)" in src, (
        "temp outputs must be preserved (no success cleanup) when import validation fails"
    )


def test_normalize_and_parse_delegated_to_testable_module():
    src = _read(MAIN_LUA)
    assert "return DKS_IMPORT.normalizeStemPathKey(name)" in src
    assert "return DKS_IMPORT.collectStemPathsFromStdoutJson(stdoutFile)" in src


def test_support_bundle_records_import_counts_and_verdict():
    src = _read(SUPPORT_BUNDLE_LUA)
    for key in (
        "dks_expected_output_count",
        "dks_validated_output_count",
        "dks_imported_track_count",
        "dks_import_validation_reason",
        "workflow_success",
        "workflow_failure_reason",
    ):
        assert f'"{key}"' in src, f"support bundle must scrape {key}"


def test_lua_regression_suite():
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
