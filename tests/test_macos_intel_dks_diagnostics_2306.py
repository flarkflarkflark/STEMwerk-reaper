from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAIN = (ROOT / "scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")
SUPPORT = (ROOT / "scripts/reaper/STEMwerk_Save_Support_Bundle.lua").read_text(encoding="utf-8")


def test_intel_dks_selection_and_saved_state_are_guarded_before_dispatch():
    assert MAIN.count("if intelMacDksPolicyBlocked() then") >= 2
    assert "clearDialogWorkflowSelection()\n        showIntelMacDksPolicyBlock(DKS_WORKFLOW.SOURCE_DIRECT)" in MAIN
    assert "clearDialogWorkflowSelection()\n        showIntelMacDksPolicyBlock(DKS_WORKFLOW.SOURCE_EXTRACT)" in MAIN
    assert "if drumkit and intelMacDksPolicyBlocked() then" in MAIN


def test_intel_dks_presets_are_not_drawn_but_normal_presets_remain():
    guarded = MAIN.index("if not intelMacDksPolicyBlocked() then")
    direct = MAIN.index("presetLabelDrumKit", guarded)
    kit_split = MAIN.index("presetLabelEdks", direct)
    guard_end = MAIN.index("\n    end", kit_split)
    assert guarded < direct < kit_split < guard_end
    assert "applyPresetAll()" in MAIN
    assert 'isModelAvailableInCurrentMode("htdemucs_6s")' in MAIN


def test_policy_block_is_handled_and_cannot_reach_runtime_work():
    assert 'SW_LOG.logExecResult("intel_dks_policy_block", 0, detail)' in MAIN
    assert '"worker_started=false", "handled=true", "fatal=false"' in MAIN
    dispatch_guard = MAIN.index("if isDrumKitWorkflow and intelMacDrumsepUnsupported() then")
    dependency_guard = MAIN.index("ensureDependenciesInteractive()", dispatch_guard)
    assert MAIN.index("showIntelMacDksPolicyBlock(workflowSourceState)", dispatch_guard) < dependency_guard
    assert MAIN.index("return", dispatch_guard) < dependency_guard


def test_safe_message_box_does_not_depend_on_setup_module_export():
    assert 'type(reaper.ShowMessageBox) == "function"' in MAIN
    assert "SW_SETUP.showMessageBox(title, body, 0)" not in MAIN
    assert "Normal CPU stem separation, including the normal six-stem mode" in MAIN


def test_support_parser_consumes_actual_output_json_evidence():
    assert 'parseJsonStringField(line, "output_names")' in SUPPORT
    assert 'parseJsonNumberField(line, "output_count")' in SUPPORT
    assert 'parseJsonStringField(line, "output_validation_reason")' in SUPPORT
    assert 'kvAssignLast(entry, "output_validation_reason", validationReason)' in SUPPORT
