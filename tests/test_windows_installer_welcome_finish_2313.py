"""P2: Windows installer Welcome-page wording/layout and Finish-page summary.

Two real problems, fixed here:

1. Welcome page: the final bullet was visually clipped. Root cause was a hard
   `WelcomeInfoLabel.Height := ScaleY(120)` box -- the EN copy alone needs
   ~14-15 wrapped lines at 9pt, NL/DE more. Fixed the same way LogMemo already
   sizes itself a few hundred lines down in this same file: fill the actual
   remaining page height instead of guessing a fixed number. The wording was
   also misleading ("a clean STEMwerk setup") even though this installer also
   repairs an existing one.

2. Finish page: structured component, system and path rows report the result
   without a page-level scrolling memo. Final installed sizes are measured
   once by the bootstrap during installation and persisted in bootstrap.env;
   the Finish page only reads and formats those values, so opening it never
   recursively scans the multi-GB runtime tree.

Static checks against the .iss source (declaration-anchored, no line
numbers), mirroring the existing style in test_windows_installer_truthful_result_2313.py,
plus a real ISCC compile at the fixed path this machine has Inno Setup 6
installed at.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
ISS = ROOT / "installer" / "windows" / "STEMwerk.iss"
BOOTSTRAP = ROOT / "scripts" / "reaper" / "STEMwerk_Bootstrap_Windows.ps1"


def _text() -> str:
    return ISS.read_text(encoding="utf-8")


def _function_body(text: str, name: str) -> str:
    """Same begin/end-nesting extraction as test_windows_installer_truthful_result_2313.py,
    fixed to actually fall back to `procedure` (the original's `if start == -1`
    branch is unreachable since str.index() raises rather than returning -1)."""
    try:
        start = text.index(f"function {name}")
    except ValueError:
        start = text.index(f"procedure {name}")
    begin_idx = text.index("\nbegin", start)
    depth = 0
    i = begin_idx
    body_end = None
    while i < len(text):
        if text.startswith("begin", i) and (i == 0 or not text[i - 1].isalnum()):
            depth += 1
            i += len("begin")
            continue
        if text.startswith("end", i) and (i == 0 or not text[i - 1].isalnum()):
            depth -= 1
            i += len("end")
            if depth == 0:
                body_end = i
                break
            continue
        i += 1
    assert body_end is not None, f"could not find matching end for {name}"
    return text[start:body_end]


def _lext_calls(body: str) -> list[tuple[str, str, str]]:
    return re.findall(r"LText\(\s*'((?:[^'\\]|\\.)*)',\s*'((?:[^'\\]|\\.)*)',\s*'((?:[^'\\]|\\.)*)'", body)


def _powershell_function(text: str, name: str) -> str:
    start = text.index(f"function {name}")
    end = text.find("\nfunction ", start + len(name) + 9)
    assert end != -1, f"could not find end of PowerShell function {name}"
    return text[start:end]


def _run_footprint_measurement(tmp_path: Path, script_root: Path, runtime_root: Path) -> dict[str, int]:
    powershell = shutil.which("powershell.exe")
    if powershell is None:
        pytest.skip("Windows PowerShell is required for footprint behavior coverage")
    helper = _powershell_function(BOOTSTRAP.read_text(encoding="utf-8"), "Measure-StemwerkInstalledFootprint")
    quote = lambda value: "'" + str(value).replace("'", "''") + "'"
    harness = tmp_path / "measure-footprint.ps1"
    harness.write_text(
        helper
        + "\n$result = Measure-StemwerkInstalledFootprint "
        + quote(script_root)
        + " "
        + quote(runtime_root)
        + "\nif ($null -eq $result) { exit 9 }\n"
        + "$result | ConvertTo-Json -Compress\n",
        encoding="utf-8",
    )
    result = subprocess.run(
        [powershell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(harness)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return json.loads(result.stdout.strip().splitlines()[-1])


# --- Welcome page: layout fix -------------------------------------------------


def test_welcome_label_no_longer_uses_a_fixed_height_box():
    text = _text()
    assert "WelcomeInfoLabel.Height := ScaleY(120);" not in text, (
        "the fixed 120px box was the root cause of the truncated final bullet"
    )
    assert "WelcomeInfoLabel.AutoSize := False;" in text
    assert "WelcomeInfoLabel.WordWrap := True;" in text


def test_welcome_label_height_fills_remaining_page_space():
    text = _text()
    assert "WelcomeInfoLabel.Height := WizardForm.WelcomePage.ClientHeight - WelcomeY - ScaleY(12);" in text, (
        "must size against the page's actual remaining height, the same pattern "
        "already proven for LogMemo, not another guessed constant"
    )


# --- Welcome page: wording -----------------------------------------------------


def test_welcome_no_longer_claims_a_clean_setup_only():
    text = _text()
    assert "a clean STEMwerk setup" not in text
    assert "een schone STEMwerk setup" not in text
    assert "ein sauberes STEMwerk Setup" not in text


@pytest.mark.parametrize(
    "needle",
    [
        "This installer will guide you through installing or repairing STEMwerk.",
        "Deze installer begeleidt je bij het installeren of herstellen van STEMwerk.",
        "Dieser Installer fuehrt dich durch die Installation oder Reparatur von STEMwerk.",
    ],
)
def test_welcome_intro_states_install_or_repair_in_all_three_languages(needle):
    assert needle in _text()


@pytest.mark.parametrize(
    "needle",
    [
        "- Install or update the REAPER STEMwerk scripts.",
        "- De REAPER STEMwerk scripts installeren of bijwerken.",
        "- Die REAPER STEMwerk Skripte installieren oder aktualisieren.",
        "- Prepare or repair the STEMwerk runtime.",
        "- De STEMwerk-runtime voorbereiden of herstellen.",
        "- Die STEMwerk-Runtime vorbereiten oder reparieren.",
        "- Optionally clean previous runtime state and cache. Downloaded models are kept.",
        "- Optioneel de vorige runtime-status en cache opschonen. Gedownloade modellen blijven behouden.",
        "- Optional den vorherigen Runtime-Status und Cache bereinigen. Heruntergeladene Modelle bleiben erhalten.",
    ],
)
def test_welcome_three_bullets_present_in_all_three_languages(needle):
    assert needle in _text()


def test_welcome_bullet_count_is_exactly_three_per_language():
    """The truncated bullet was the LAST of three; pin the count so a future
    edit can't silently drop or grow it without updating this test."""
    text = _text()
    start = text.index("WelcomeInfoLabel.Caption :=")
    end = text.index(";\n", text.index("Tipp: Nach dem Setup", start))
    block = text[start:end]
    assert block.count("'- ") == 9, "expected 3 bullets x 3 languages (EN/NL/DE) in the Welcome caption"


# --- Finish page: compact structured dashboard ---------------------------------


def test_finished_label_is_hidden_and_old_summary_memo_is_gone():
    text = _text()
    body = _function_body(text, "LayoutFinishedPage")
    assert "WizardForm.FinishedLabel.Visible := False;" in body
    assert "WizardForm.FinishedLabel.Caption := '';" in body
    assert "FinishedSummaryMemo" not in text
    assert "LayoutFinishedSummary" not in text


def test_finished_page_uses_native_structured_controls():
    text = _text()
    init = _function_body(text, "InitializeWizard")
    for name in (
        "FinishedOutcomeLabel",
        "FinishedComponentsHeading",
        "FinishedSystemHeading",
        "FinishedPathsHeading",
    ):
        assert name in init
    assert "FinishedPathEdits[i] := TNewEdit.Create(WizardForm);" in init
    assert "FinishedPathEdits[i].ReadOnly := True;" in init
    assert "FinishedOpenButtons[i] := TNewButton.Create(WizardForm);" in init


def test_component_column_gets_more_room_than_system_column():
    body = _function_body(_text(), "LayoutFinishedPage")
    assert "ComponentW := (CW * 55) div 100;" in body
    assert "SystemW := CW - ComponentW;" in body
    assert "FinishedSystemHeading.Left := L + ComponentW;" in body


def test_finish_page_is_filled_then_laid_out_on_entry():
    body = _function_body(_text(), "CurPageChanged")
    assert body.index("FillFinishedPage;") < body.index("LayoutFinishedPage;")
    assert "WizardForm.FinishedLabel.Caption := BuildFinishedSummaryText;" not in body


def test_outcome_height_avoids_the_uncallable_adjustheight_rtti_method():
    body = _function_body(_text(), "LayoutFinishedPage")
    assert "FinishedOutcomeLabel.AdjustHeight;" not in body
    assert "if BootstrapSucceeded then" in body
    assert "FinishedOutcomeLabel.Height := ScaleY(54)" in body
    assert "FinishedOutcomeLabel.Height := ScaleY(84)" in body


def test_finish_has_five_status_facts_and_four_location_rows():
    text = _text()
    assert "FinishedStatusNames: array[0..4]" in text
    assert "FinishedStatusValues: array[0..4]" in text
    assert "FinishedComponentSizes: array[0..2]" in text
    assert "FinishedTotalNameLabel: TNewStaticText" in text
    assert "FinishedTotalSizeLabel: TNewStaticText" in text
    assert "FinishedPathLabels: array[0..3]" in text
    assert "FinishedPathEdits: array[0..3]" in text
    assert "FinishedOpenButtons: array[0..3]" in text
    assert "FinishedCopyButtons" not in text
    init = _function_body(text, "InitializeWizard")
    for label in ("REAPER scripts", "STEMwerk runtime", "Models/cache", "FFmpeg", "Acceleration"):
        assert label in init
    for label in ("REAPER scripts", "Runtime", "Models/cache", "Setup log"):
        assert label in init
    assert "for i := 0 to 4 do" in init
    assert "FinishedStatusValues[i] := CreateFinishedText('', False);" in init
    assert "for i := 0 to 2 do" in init
    assert "FinishedComponentSizes[i] := CreateFinishedText('', False);" in init
    assert "for i := 0 to 3 do" in init
    assert init.index("for i := 0 to 4 do") < init.index("for i := 0 to 3 do")


def test_path_rows_use_resolved_values_and_keep_ffmpeg_path_off_the_main_page():
    body = _function_body(_text(), "FillFinishedPage")
    assert "ExpandConstant('{app}')" in body
    assert "GetRuntimeBasePath" in body
    assert "FinishedModelsDir" in body
    assert "GetLogPath" in body
    assert "%APPDATA%" not in body and "%LOCALAPPDATA%" not in body
    assert "FFMPEG_PATH" not in body


def test_open_buttons_use_the_resolved_field_values():
    click = _function_body(_text(), "FinishedOpenClick")
    assert "ShellExec('', FinishedPathEdits[i].Text" in click
    assert "FinishedOpenTarget" not in _text()


def test_finish_page_reads_persisted_sizes_and_never_scans_any_tree():
    text = _text()
    fill = _function_body(text, "FillFinishedPage")
    assert "GetDirTreeSizeBytes" not in text
    for key in (
        "INSTALLED_SCRIPTS_BYTES",
        "INSTALLED_RUNTIME_BYTES",
        "INSTALLED_MODELS_BYTES",
        "INSTALLED_TOTAL_BYTES",
    ):
        assert f"FinishedMeasuredSizeText('{key}')" in fill
    assert "FindFirst" not in fill and "FindNext" not in fill


def test_models_status_is_only_available_when_models_exist():
    body = _function_body(_text(), "FinishedModelsStatusText")
    assert "if DirExists(FinishedModelsDir) then" in body
    assert "Not present" in body and "Niet aanwezig" in body and "Nicht vorhanden" in body


def test_ffmpeg_status_is_compact_and_localized():
    body = _function_body(_text(), "FinishedFfmpegStatusText")
    for source in ("bundled", "download", "existing"):
        assert f"Source = '{source}'" in body
    for value in ("Bundled", "Meegeleverd", "Mitgeliefert", "Downloaded", "Gedownload", "Heruntergeladen", "Reused", "Hergebruikt", "Wiederverwendet"):
        assert value in body


def test_backend_status_maps_known_backends_without_long_reason_suffix():
    body = _function_body(_text(), "FinishedBackendStatusText")
    for raw, display in (("directml", "DirectML"), ("cuda", "CUDA"), ("cpu", "CPU")):
        assert f"BackendValue = '{raw}'" in body and f"Result := '{display}'" in body
    assert "BACKEND_REASON" not in body


def test_no_run_delta_or_required_space_is_mislabeled_as_installed_total():
    text = _text()
    for forbidden in ("space added", "Space added", "added by this", "newly added"):
        assert forbidden not in text
    fill = _function_body(text, "FillFinishedPage")
    assert "MinimumFreeSpaceMB" not in fill
    assert "GetSpaceOnDisk" not in fill


def test_bootstrap_persists_all_footprint_metrics_together_only_after_success():
    text = BOOTSTRAP.read_text(encoding="utf-8")
    measure_idx = text.index("$installedFootprint = Measure-StemwerkInstalledFootprint $scriptRoot $RuntimeBase")
    final_state_idx = text.index('$lines += "STATUS=$status"', measure_idx)
    assert text.rfind('if ($status -eq "ok")', 0, measure_idx) != -1
    assert measure_idx < final_state_idx
    state_block = text[final_state_idx:text.index("$lines | Out-File -FilePath $StateFile", final_state_idx)]
    assert 'if ($null -ne $installedFootprint)' in state_block
    for key in (
        "INSTALLED_SCRIPTS_BYTES",
        "INSTALLED_RUNTIME_BYTES",
        "INSTALLED_MODELS_BYTES",
        "INSTALLED_TOTAL_BYTES",
    ):
        assert key in state_block


def test_runtime_excludes_models_total_counts_models_once_and_external_ffmpeg_is_excluded(tmp_path: Path):
    scripts = tmp_path / "scripts"
    runtime = tmp_path / "runtime"
    external = tmp_path / "external-ffmpeg"
    (scripts / "_bundled").mkdir(parents=True)
    (runtime / ".venv").mkdir(parents=True)
    (runtime / "models").mkdir(parents=True)
    (runtime / "state").mkdir(parents=True)
    external.mkdir()
    (scripts / "main.lua").write_bytes(b"s" * 9)
    (scripts / "_bundled" / "payload.whl").write_bytes(b"b" * 999)
    (runtime / ".venv" / "package.py").write_bytes(b"r" * 100)
    (runtime / "state" / "bootstrap.env").write_bytes(b"e" * 5)
    (runtime / "models" / "model.ckpt").write_bytes(b"m" * 200)
    (external / "ffmpeg.exe").write_bytes(b"f" * 1000)

    measured = _run_footprint_measurement(tmp_path, scripts, runtime)
    assert measured == {
        "ScriptsBytes": 9,
        "RuntimeBytes": 105,
        "ModelsBytes": 200,
        "TotalBytes": 314,
    }


def test_total_uses_unique_paths_when_script_and_runtime_roots_overlap(tmp_path: Path):
    runtime = tmp_path / "runtime"
    scripts = runtime / "scripts"
    (runtime / "models").mkdir(parents=True)
    scripts.mkdir()
    (scripts / "main.lua").write_bytes(b"s" * 9)
    (runtime / "runtime.bin").write_bytes(b"r" * 100)
    (runtime / "models" / "model.ckpt").write_bytes(b"m" * 200)

    measured = _run_footprint_measurement(tmp_path, scripts, runtime)
    assert measured["ScriptsBytes"] == 9
    assert measured["RuntimeBytes"] == 109
    assert measured["ModelsBytes"] == 200
    assert measured["TotalBytes"] == 309


def test_missing_or_invalid_metrics_render_no_fake_total():
    text = _text()
    reader = _function_body(text, "FinishedMeasuredSizeText")
    layout = _function_body(text, "LayoutFinishedPage")
    bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
    assert "Result := '';" in reader
    assert "if TryReadBootstrapBytes(Key, Bytes) then" in reader
    assert "FinishedTotalSizeLabel.Caption <> ''" in layout
    assert "FinishedTotalNameLabel.Visible := BootstrapSucceeded and" in layout
    assert "if ($null -eq $installedFootprint)" in bootstrap
    assert "no size total will be reported" in bootstrap


def test_installed_size_labels_have_en_nl_de_parity():
    text = _text()
    init = _function_body(text, "InitializeWizard")
    formatter = _function_body(text, "FormatApproxInstalledSize")
    assert "LText('Total STEMwerk', 'Totaal STEMwerk', 'STEMwerk gesamt')" in init
    assert "LText('Approx. ', 'Ong. ', 'Ca. ')" in formatter
    assert "' KiB'" in formatter
    assert "' MiB'" in formatter
    assert "' GiB'" in formatter


def test_finished_binary_size_formatter_uses_iec_units_and_concise_rounding():
    formatter = _function_body(_text(), "FormatApproxInstalledSize")
    assert "Bytes < 1048576" in formatter
    assert "(Bytes + 512) div 1024" in formatter
    assert "Bytes < 1073741824" in formatter
    assert "(Bytes + 524288) div 1048576" in formatter
    assert "((Bytes * 100) + 536870912) div 1073741824" in formatter
    assert "' MB'" not in formatter
    assert "' GB'" not in formatter


def test_size_scan_uses_existing_localized_status_detail_without_fake_progress():
    bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
    measurement = bootstrap[bootstrap.index("$installedFootprint = $null"):]
    assert 'LogStatusDetail "Calculating installed size..."' in measurement
    assert measurement.index('LogStatusDetail "Calculating installed size..."') < measurement.index(
        "$installedFootprint = Measure-StemwerkInstalledFootprint"
    )
    assert "STEMWERK_STATUS progress=" not in measurement

    localizer = _function_body(_text(), "LocalizeStatusDetail")
    for label in (
        "Calculating installed size...",
        "Installatiegrootte wordt berekend...",
        "Installierte Groesse wird berechnet...",
    ):
        assert label in localizer


@pytest.mark.parametrize(
    "needle",
    [
        "- Use STEMwerk: Setup to check the runtime (Check only). If it reports a problem, re-run this STEMwerk installer to repair it.",
        "- Gebruik STEMwerk: Setup om de runtime te controleren (Check only). Meldt dat een probleem, voer deze STEMwerk-installer opnieuw uit om te herstellen.",
        "- Nutze STEMwerk: Setup, um die Runtime zu pruefen (Check only). Meldet das ein Problem, fuehre diesen STEMwerk-Installer erneut aus, um sie zu reparieren.",
    ],
)
def test_protected_check_only_and_installer_repair_guidance_remains(needle):
    assert needle in _function_body(_text(), "BuildFinishedSuccessSummaryText")


def test_success_outcome_is_short_and_versioned():
    body = _function_body(_text(), "BuildFinishedSuccessSummaryText")
    assert "STEMwerk setup completed." in body
    assert "VersionTag" in body
    for forbidden in ("What was installed:", "Installed locations:", "Show action list", "ReaScript: Load"):
        assert forbidden not in body


def test_read_bootstrap_value_is_line_anchored_and_status_reader_is_unchanged():
    text = _text()
    reader = _function_body(text, "ReadBootstrapValue")
    assert "Copy(Lines[i], 1, Length(Prefix)) = Prefix" in reader
    assert "Result := Trim" in reader
    assert "Marker := 'STATUS=';" in _function_body(text, "ReadBootstrapStatus")


def test_all_finish_helpers_localize_every_lext_call():
    text = _text()
    names = (
        "BuildFinishedSuccessSummaryText",
        "BuildFinishedFailureSummaryText",
        "FinishedScriptsStatusText",
        "FinishedModelsStatusText",
        "FinishedFfmpegStatusText",
        "FinishedBackendStatusText",
        "FormatApproxInstalledSize",
    )
    for name in names:
        for en, nl, de in _lext_calls(_function_body(text, name)):
            assert en.strip() and nl.strip() and de.strip()


def test_failure_summary_makes_no_success_status_claims():
    body = _function_body(_text(), "BuildFinishedFailureSummaryText")
    for forbidden in ("FormatApproxMB", "FormatApproxInstalledSize", "Acceleration", "FFmpeg"):
        assert forbidden not in body


def test_iss_still_never_mentions_the_offline_patch_installer():
    assert "STEMwerk_Offline_Patch" not in _text()


def test_runlist_uses_compact_content_height_and_bottom_anchor():
    text = _text()
    helper = _function_body(text, "RunListRowHeight")
    layout = _function_body(text, "LayoutFinishedPage")
    assert "List.Font.Height" in helper and "List.MinItemHeight" in helper
    assert "List.Height" not in helper and "Items.Count" not in helper
    assert "WizardForm.RunList.Height := (RunListRowHeight(WizardForm.RunList) * WizardForm.RunList.Items.Count) + ScaleY(6);" in layout
    assert "WizardForm.FinishedPage.ClientHeight - WizardForm.RunList.Height - ScaleY(8)" in layout
    assert "if RunListTop < y + ScaleY(4) then" in layout
    assert "WizardForm.RunList.Visible := False;" in layout


def test_structured_layout_has_no_page_level_scroll_control():
    text = _text()
    layout = _function_body(text, "LayoutFinishedPage")
    assert "ScrollBars" not in layout
    assert "TNewMemo" not in layout
    assert "for i := 0 to 3 do" in layout
    assert "for i := 0 to 4 do" in layout


@pytest.mark.parametrize("scale", [1.0, 1.25, 1.5])
def test_normal_finish_regions_fit_the_standard_height(scale):
    """Conservative model of the successful page at the retained 120% height.
    This is a static guard, not a visual DPI certification."""

    def sc(px):
        return round(px * scale)

    # Normalized from the live 125% wizard: 515px page height and 96px
    # content top become 412px and 77px at 100%.
    page_h = sc(412)
    content_top = sc(77)
    outcome_h = sc(54)
    status_h = sc(17) + 4 * sc(17) + sc(4)
    paths_h = sc(17) + sc(2) + 4 * (sc(20) + sc(1))
    content_bottom = content_top + outcome_h + sc(2) + status_h + paths_h
    run_h = 2 * (sc(14) + sc(8)) + sc(6)
    run_top = page_h - run_h - sc(8)
    assert content_bottom + sc(4) <= run_top


# --- Ready page: real canonical space figures, not Inno's `Space` parameter --
#
# BUG 1 (live validation, round 2): the Ready page rendered "...preflight
# estimate): " with NOTHING after the colon. Root cause: Inno's `Space`
# parameter to UpdateReadyMemo is NOT a disk-space figure -- it is only the
# indentation string Inno uses internally when composing the memo. The
# correction reuses the SAME required-space constant and SAME target path the
# real PrepareToInstall gate already uses, via one shared function
# (GetRuntimeDiskSpaceStatus), so displayed values can never disagree with the
# actual pass/fail decision the installer makes at install time.


def test_update_ready_memo_does_not_misuse_the_space_parameter_as_a_size():
    text = _text()
    assert (
        "function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,"
        in text
    )
    body = _function_body(text, "UpdateReadyMemo")
    assert not re.search(r"\+\s*Space\s*;", body), (
        "Space is Inno's indentation string, not a disk-space value -- it must "
        "not be appended to Result as if it were one"
    )
    assert not re.search(r"\+\s*Space\s*\)", body)


def test_ready_memo_reuses_the_shared_runtime_disk_space_status_function():
    body = _function_body(_text(), "UpdateReadyMemo")
    assert "GetRuntimeDiskSpaceStatus(RequiredMB, FreeMB, TotalMB)" in body
    # Must not recompute a second, independent estimate from the ISPP
    # constant or a fresh GetSpaceOnDisk call -- only the shared function.
    assert "{#MinimumFreeSpaceMB}" not in body
    assert "GetSpaceOnDisk(" not in body


def test_get_runtime_disk_space_status_is_the_single_source_of_required_value():
    text = _text()
    body = _function_body(text, "GetRuntimeDiskSpaceStatus")
    assert "RequiredMB := {#MinimumFreeSpaceMB};" in body
    assert "GetSpaceOnDisk(GetRuntimeBasePath, True, FreeMB, TotalMB)" in body
    # PrepareToInstall (the actual gate) must call the SAME shared function
    # rather than recomputing RequiredMB/FreeMB itself, so the Ready-page
    # display and the real gate can never disagree.
    prepare_body = _function_body(text, "PrepareToInstall")
    assert "GetRuntimeDiskSpaceStatus(RequiredMB, FreeMB, TotalMB)" in prepare_body
    assert "{#MinimumFreeSpaceMB}" not in prepare_body, (
        "PrepareToInstall must get RequiredMB from the shared function now, "
        "not redeclare the ISPP constant inline"
    )


def test_ready_memo_status_matches_the_real_gate_pass_fail_logic():
    """Both the Ready-page display and PrepareToInstall's actual abort/warn
    decision must use the identical comparison (FreeMB < RequiredMB)."""
    text = _text()
    ready_body = _function_body(text, "UpdateReadyMemo")
    gate_body = _function_body(text, "PrepareToInstall")
    assert "if FreeMB < RequiredMB then" in ready_body
    assert "if FreeMB < RequiredMB then" in gate_body


def test_ready_memo_disk_space_line_localized_in_all_three_languages():
    body = _function_body(_text(), "UpdateReadyMemo")
    for needle in (
        "Disk space (STEMwerk runtime): ",
        "Schijfruimte (STEMwerk-runtime): ",
        "Speicherplatz (STEMwerk-Runtime): ",
    ):
        assert needle in body
    for needle in ("required", "vereist", "erforderlich"):
        assert needle in body
    for needle in ("available", "beschikbaar", "verfuegbar"):
        assert needle in body
    for needle in (
        "NOT ENOUGH SPACE",
        "ONVOLDOENDE RUIMTE",
        "NICHT GENUG SPEICHERPLATZ",
    ):
        assert needle in body
    for forbidden in ("installed size", "Installed size", "total footprint", "Total footprint"):
        assert forbidden not in body
    for footprint_key in (
        "INSTALLED_SCRIPTS_BYTES",
        "INSTALLED_RUNTIME_BYTES",
        "INSTALLED_MODELS_BYTES",
        "INSTALLED_TOTAL_BYTES",
    ):
        assert footprint_key not in body


def test_insufficient_disk_space_actually_blocks_installation():
    """PrepareToInstall must still return a non-empty Result (Inno's abort
    signal for this callback) when free space is below the requirement --
    the Ready-page display must never suggest a check that isn't real."""
    body = _function_body(_text(), "PrepareToInstall")
    assert "if SuppressibleMsgBox(PromptText, mbConfirmation, MB_YESNO, IDNO) = IDNO then" in body
    idx_msgbox = body.index("SuppressibleMsgBox(")
    idx_result = body.index("Result := LText(", idx_msgbox)
    assert idx_result > idx_msgbox
    assert "Installation canceled due to low free disk space." in body


def test_ready_memo_preserves_the_existing_memo_sections():
    """Must not replace Inno's dir/group/tasks summary wholesale -- only add to it."""
    body = _function_body(_text(), "UpdateReadyMemo")
    assert "Result := MemoDirInfo;" in body
    assert "MemoGroupInfo" in body
    assert "MemoTasksInfo" in body


# --- License page: version display derived from the same AppVersion source -----


def test_license_version_display_is_fixed_from_the_wizard_not_the_static_file():
    text = _text()
    assert "procedure FixLicenseVersionDisplay;" in text
    body = _function_body(text, "FixLicenseVersionDisplay")
    assert "WizardForm.LicenseMemo" in body
    assert "'{#MyAppVersion}'" in body, (
        "must derive the displayed version from the same AppVersion source as "
        "everywhere else in the wizard, not another hardcoded literal"
    )
    # Never write a literal release number into the fix itself.
    assert "2.3.1.2" not in body
    assert "2.3.1.3" not in body


def test_license_version_fix_is_called_from_initialize_wizard():
    text = _text()
    init_body = _function_body(text, "InitializeWizard")
    assert "FixLicenseVersionDisplay;" in init_body


def test_static_license_file_version_sync_is_unaffected():
    """This slice must not touch the existing version_sync.py-managed static
    file or its own regression tests -- only add a wizard-side display fix
    alongside it."""
    text = Path("tools/version_sync.py").read_text(encoding="utf-8")
    assert "installer/windows/STEMwerk_License_Agreement.txt" in text


# --- Real ISCC compile -----------------------------------------------------------

_ISCC_EXE = Path(r"C:\Users\Administrator\AppData\Local\Programs\Inno Setup 6\ISCC.exe")


def _iscc_available() -> bool:
    return _ISCC_EXE.is_file()


@pytest.mark.skipif(not _iscc_available(), reason="Inno Setup 6 not installed at the expected path")
def test_installer_compiles_with_the_real_iscc():
    import os

    dist_dir = ISS.parent / "dist"
    existed_before = dist_dir.exists()
    env = dict(os.environ)
    env["STEMWERK_VERSION"] = "0.0.0-pytest"
    env["STEMWERK_BUILD_DATE"] = "2026-01-01"
    try:
        result = subprocess.run(
            [str(_ISCC_EXE), str(ISS)],
            capture_output=True,
            text=True,
            env=env,
            timeout=180,
        )
        assert result.returncode == 0, f"ISCC compile failed:\n{result.stdout}\n{result.stderr}"
        assert "Successful compile" in result.stdout
    finally:
        if dist_dir.exists() and not existed_before:
            shutil.rmtree(dist_dir, ignore_errors=True)
