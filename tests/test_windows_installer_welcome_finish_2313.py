"""P2: Windows installer Welcome-page wording/layout and Finish-page summary.

Two real problems, fixed here:

1. Welcome page: the final bullet was visually clipped. Root cause was a hard
   `WelcomeInfoLabel.Height := ScaleY(120)` box -- the EN copy alone needs
   ~14-15 wrapped lines at 9pt, NL/DE more. Fixed the same way LogMemo already
   sizes itself a few hundred lines down in this same file: fill the actual
   remaining page height instead of guessing a fixed number. The wording was
   also misleading ("a clean STEMwerk setup") even though this installer also
   repairs an existing one.

2. Finish page: previously only ever said "setup completed" with no useful
   detail. Added REAPER-scripts size, models/cache size, FFmpeg path+status
   and the acceleration backend -- all read from state the bootstrap script
   already writes, or from directory scans measured cheap on a real install
   (REAPER scripts: 164 files, instant; models: 12 files, instant). The
   runtime root itself (its two Python venvs alone were 70,000+ files, several
   GB) is deliberately NOT scanned -- measured directly, that would visibly
   stall the page -- so no runtime size and no "total footprint" are claimed;
   truthfulness over false precision.

Static checks against the .iss source (declaration-anchored, no line
numbers), mirroring the existing style in test_windows_installer_truthful_result_2313.py,
plus a real ISCC compile at the fixed path this machine has Inno Setup 6
installed at.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
ISS = ROOT / "installer" / "windows" / "STEMwerk.iss"


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


# --- Finish page: read-only scrollable summary control ---------------------------
#
# Live DrawText measurement (native DT_CALCRECT|DT_WORDBREAK against the real
# live font/width) proved a plain static label has a hard ceiling: even with
# RunList correctly compacted, the real content needs more height than the
# page has, in all three languages (400px needed vs 274px available in EN/DE,
# 500px vs 249px in NL). WizardForm.FinishedLabel is hidden; a new read-only,
# vertically-scrollable TNewMemo (FinishedSummaryMemo) shows the detailed
# summary instead, so overflow is reachable by scrolling rather than clipped.


def test_finished_label_is_hidden_not_left_showing_duplicate_text():
    body = _function_body(_text(), "LayoutFinishedSummary")
    assert "WizardForm.FinishedLabel.Visible := False;" in body
    assert "WizardForm.FinishedLabel.Caption := '';" in body


def test_finished_summary_memo_created_read_only_and_scrollable():
    text = _text()
    assert "FinishedSummaryMemo := TNewMemo.Create(WizardForm);" in text
    init_body = _function_body(text, "InitializeWizard")
    assert "FinishedSummaryMemo.Parent := WizardForm.FinishedPage;" in init_body
    assert "FinishedSummaryMemo.ReadOnly := True;" in init_body
    assert "FinishedSummaryMemo.ScrollBars := ssVertical;" in init_body
    assert "FinishedSummaryMemo.WordWrap := True;" in init_body


def test_finish_layout_positions_the_memo_not_the_old_label():
    text = _text()
    assert "procedure LayoutFinishedSummary;" in text
    body = _function_body(text, "LayoutFinishedSummary")
    assert "FinishedSummaryMemo.Left := WizardForm.FinishedLabel.Left;" in body
    assert "FinishedSummaryMemo.Top := WizardForm.FinishedLabel.Top;" in body
    assert "FinishedSummaryMemo.Width :=" in body
    assert "WizardForm.RunList" in body, "must not overlap the Open guide/Open log checkboxes"


def test_finish_layout_is_actually_called_before_setting_the_text():
    text = _text()
    idx_layout = text.index("LayoutFinishedSummary;", text.index("procedure CurPageChanged"))
    idx_settext = text.index("FinishedSummaryMemo.Lines.Text := BuildFinishedSummaryText;")
    assert idx_layout < idx_settext, "layout must be applied before the (possibly overflowing) text is assigned"


def test_only_one_control_shows_the_detailed_summary():
    """Guard against two competing summary controls / duplicate text: the
    hidden, emptied FinishedLabel must never also receive the built summary
    text anywhere in CurPageChanged."""
    curpage_body = _function_body(_text(), "CurPageChanged")
    assert "WizardForm.FinishedLabel.Caption := BuildFinishedSummaryText;" not in curpage_body
    assert "FinishedSummaryMemo.Lines.Text := BuildFinishedSummaryText;" in curpage_body


# --- Finish page: new fields, cheap and truthful --------------------------------


def test_dir_size_scan_skips_bundled_offline_payload():
    body = _function_body(_text(), "GetDirTreeSizeBytes")
    assert "_bundled" in body
    assert "Continue" in body


def test_dir_size_scan_is_never_called_on_the_full_runtime_base_or_a_venv():
    """The expensive trees (measured: 70,000+ files, several GB) must not be
    scanned anywhere in the finish-summary builder."""
    body = _function_body(_text(), "BuildFinishedSuccessSummaryText")
    for call in re.finditer(r"GetDirTreeSizeBytes\(([^)]*)\)", body):
        arg = call.group(1)
        assert "GetRuntimeBasePath" not in arg or "\\models" in arg, (
            f"GetDirTreeSizeBytes called on {arg!r}: only {{app}} and RuntimeBase\\models "
            "were measured cheap; the runtime root itself must never be scanned"
        )
        assert ".venv" not in arg


def test_scripts_and_models_sizes_use_the_approx_formatter():
    body = _function_body(_text(), "BuildFinishedSuccessSummaryText")
    assert "FormatApproxMB(GetDirTreeSizeBytes(ExpandConstant('{app}')))" in body
    assert "FormatApproxMB(GetDirTreeSizeBytes(ModelsDir))" in body


def test_models_line_only_shown_when_models_dir_actually_exists():
    body = _function_body(_text(), "BuildFinishedSuccessSummaryText")
    # The populating assignment (second "ModelsLine :=", after the empty-string
    # default) must be the statement immediately guarded by DirExists(ModelsDir).
    guard_idx = body.index("if DirExists(ModelsDir) then")
    next_assign_idx = body.index("ModelsLine :=", guard_idx)
    between = body[guard_idx + len("if DirExists(ModelsDir) then") : next_assign_idx]
    assert between.strip() == "", f"unexpected statements between the guard and the assignment: {between!r}"


def test_no_total_footprint_or_space_added_claim_anywhere():
    """These require scanning the expensive runtime tree; since that scan is
    deliberately not performed, no total/added-space figure may be shown."""
    text = _text()
    for forbidden in (
        "Total STEMwerk footprint",
        "Total current STEMwerk footprint",
        "space added",
        "Space added",
        "added by this",
        "newly added",
    ):
        assert forbidden not in text, f"found unmeasurable claim: {forbidden!r}"


def test_runtime_data_line_has_no_size_claim():
    """The runtime root's path must still be shown; unlike scripts/models, no
    size follows it on the same or next line."""
    body = _function_body(_text(), "BuildFinishedSuccessSummaryText")
    idx = body.index("'  ' + GetRuntimeBasePath + #13#10")
    following = body[idx : idx + 200]
    assert "FormatApproxMB" not in following


def test_finished_summary_paths_are_resolved_not_placeholder_env_vars():
    """BUG 3 (live validation, round 2): the Finished page literally displayed
    '%APPDATA%\\REAPER\\Scripts\\STEMwerk-reaper' instead of the real resolved
    path, while other lines already showed real C:\\Users\\... paths. Every
    path shown here must come from the same resolved-path accessors the rest
    of the wizard already uses ({app} via ExpandConstant, GetRuntimeBasePath),
    never a literal %ENVVAR%-style placeholder string."""
    body = _function_body(_text(), "BuildFinishedSuccessSummaryText")
    assert "%APPDATA%" not in body
    assert "%LOCALAPPDATA%" not in body
    assert "ExpandConstant('{app}')" in body
    assert "GetRuntimeBasePath" in body


@pytest.mark.parametrize(
    "needle",
    [
        "- Models/cache:",
        "- Modellen/cache:",
        "- Modelle/Cache:",
    ],
)
def test_models_cache_label_present_in_all_three_languages(needle):
    assert needle in _function_body(_text(), "BuildFinishedSuccessSummaryText")


@pytest.mark.parametrize(
    "needle",
    [
        "installed from the bundled offline payload",
        "geinstalleerd vanuit de gebundelde offline payload",
        "installiert aus der gebuendelten Offline-Payload",
        "downloaded during setup",
        "gedownload tijdens setup",
        "waehrend des Setups heruntergeladen",
        "reused (already present on this system)",
        "hergebruikt (al aanwezig op dit systeem)",
        "wiederverwendet (bereits auf diesem System vorhanden)",
    ],
)
def test_ffmpeg_status_labels_present_in_all_three_languages(needle):
    assert needle in _function_body(_text(), "BuildFinishedSuccessSummaryText")


def test_ffmpeg_path_only_shown_when_a_path_value_exists():
    body = _function_body(_text(), "BuildFinishedSuccessSummaryText")
    assert "if FfmpegPathValue <> '' then" in body


def test_ffmpeg_block_only_shown_when_source_is_known():
    body = _function_body(_text(), "BuildFinishedSuccessSummaryText")
    assert "if FfmpegSourceValue <> '' then" in body


@pytest.mark.parametrize(
    "needle",
    ["Acceleration backend: ", "Acceleratie-backend: ", "Beschleunigungs-Backend: "],
)
def test_backend_label_present_in_all_three_languages(needle):
    assert needle in _function_body(_text(), "BuildFinishedSuccessSummaryText")


def test_backend_block_only_shown_when_backend_is_known():
    body = _function_body(_text(), "BuildFinishedSuccessSummaryText")
    assert "if BackendValue <> '' then" in body


def test_backend_values_map_to_their_display_names():
    body = _function_body(_text(), "BuildFinishedSuccessSummaryText")
    assert "if BackendValue = 'directml' then" in body and "'DirectML'" in body
    assert "if BackendValue = 'cuda' then" in body and "'CUDA'" in body
    assert "if BackendValue = 'cpu' then" in body and "'CPU'" in body


def test_backend_reason_appended_only_when_present():
    body = _function_body(_text(), "BuildFinishedSuccessSummaryText")
    assert "if BackendReasonValue <> '' then" in body


# --- Finish page: trimmed prose (scrolling replaces "must all fit" pressure) -----
#
# Live DrawText measurement proved the page's real facts alone already exceed
# the available height; these removals are the concise-operational-summary
# trim, not another attempt to force-fit content. The scrollable
# FinishedSummaryMemo (see above) is what actually handles any remaining
# overflow -- these are the genuinely redundant lines, not required facts.


def test_cleanup_explanation_prose_removed_from_summary():
    """The cleanup task's effect is already visible as the Task selection
    itself on the previous wizard page; repeating it here in prose was
    redundant, not a fact unique to the Finished page."""
    body = _function_body(_text(), "BuildFinishedSuccessSummaryText")
    for forbidden in (
        "Cleared previous runtime state",
        "Kept existing runtime data",
        "WizardIsTaskSelected('cleanup_runtime')",
    ):
        assert forbidden not in body


def test_generic_offline_payload_prose_removed_from_summary():
    """Not a per-install fact -- generic boilerplate about the installer
    build flavor, unrelated to what actually happened on this machine."""
    body = _function_body(_text(), "BuildFinishedSuccessSummaryText")
    assert "Offline model/runtime payload" not in body
    assert "Offline model-/runtime-payload" not in body
    assert "Offline-Modell-/Runtime-Payload" not in body


@pytest.mark.parametrize(
    "needle",
    [
        "- Use STEMwerk: Setup to check the runtime (Check only). If it reports a problem, re-run this STEMwerk installer to repair it.",
        "- Gebruik STEMwerk: Setup om de runtime te controleren (Check only). Meldt dat een probleem, voer deze STEMwerk-installer opnieuw uit om te herstellen.",
        "- Nutze STEMwerk: Setup, um die Runtime zu pruefen (Check only). Meldet das ein Problem, fuehre diesen STEMwerk-Installer erneut aus, um sie zu reparieren.",
    ],
)
def test_next_step_is_now_a_single_concise_line_per_language(needle):
    """The old 3-bullet walkthrough (start REAPER and open the Actions menu /
    ReaScript: Load... / this Check-only bullet) is trimmed to just this one
    bullet -- the two dropped ones were generic app-discovery prose already
    covered by the guide; this one is protected policy text (see
    test_verbose_action_list_walkthrough_removed and the pre-existing,
    unrelated test_installer_finished_page_no_longer_offers_check_or_repair_in_reaper
    in test_2311_setup_ui_policy.py): only a successful install may tell the
    user to run Check only and treat the external installer as the repair
    path, so this exact wording must survive the trim."""
    body = _function_body(_text(), "BuildFinishedSuccessSummaryText")
    assert needle in body


def test_verbose_action_list_walkthrough_removed():
    """Only the generic discovery bullets are dropped; the Check-only /
    repair-via-installer bullet (asserted present above) is deliberately
    kept -- it is pinned as policy text by an unrelated pre-existing test."""
    body = _function_body(_text(), "BuildFinishedSuccessSummaryText")
    for forbidden in (
        "Show action list",
        "ReaScript: Load",
        "check the Actions menu for STEMwerk",
    ):
        assert forbidden not in body


# --- Finish page: state reader ---------------------------------------------------


def test_read_bootstrap_value_is_a_generic_line_anchored_reader():
    text = _text()
    assert "function ReadBootstrapValue(const Key: string): string;" in text
    body = _function_body(text, "ReadBootstrapValue")
    # Line-start anchored (Copy(...,1,...) = Prefix), not a raw Pos() substring
    # search -- so "BACKEND=" can never match inside a later, unrelated key.
    assert "Copy(Lines[i], 1, Length(Prefix)) = Prefix" in body


def test_read_bootstrap_status_is_untouched():
    """ReadBootstrapStatus's exact shape is pinned by an existing regression
    test (test_windows_installer_truthful_result_2313.py); this slice must add
    a separate generic reader alongside it, not refactor it."""
    text = _text()
    assert "Marker := 'STATUS=';" in _function_body(text, "ReadBootstrapStatus")


# --- Regression: every new LText call is properly 3-way, failure text untouched -


def test_every_lext_call_in_success_summary_is_fully_localized():
    body = _function_body(_text(), "BuildFinishedSuccessSummaryText")
    calls = _lext_calls(body)
    # Lower than an earlier version of this test expected: trimming the
    # cleanup explanation, generic offline-payload prose, and the 3-line
    # Action-list walkthrough (see the "trimmed prose" tests above) removed
    # several LText(...) calls along with the now-redundant text itself.
    assert len(calls) >= 10, "expected at least the pre-existing plus the new LText(...) calls"
    for en, nl, de in calls:
        assert en.strip() and nl.strip() and de.strip()


def test_failure_summary_still_makes_no_size_or_backend_claims():
    body = _function_body(_text(), "BuildFinishedFailureSummaryText")
    for forbidden in ("FormatApproxMB", "GetDirTreeSizeBytes", "Acceleration backend", "FFmpeg:"):
        assert forbidden not in body


def test_iss_still_never_mentions_the_offline_patch_installer():
    assert "STEMwerk_Offline_Patch" not in _text()


# --- Finish page: corrected RunList geometry (proven by live diagnostics) --------
#
# Two earlier versions of the static-label fix were live-validation failures.
# Temporary Log()-based instrumentation (BeforeLayout/AfterLayout/
# VisibleDelayed, since removed) proved the actual root cause on real
# hardware: RunList.Height is Inno's stock full-leftover-page-space default
# (318px observed for 2 one-line items) and never changes on its own --
# neither "trust RunList.Top" (v1) nor "trust RunList.Height" (v2) could ever
# have worked, since the box itself was oversized by roughly 5x. This RunList
# sizing logic is unchanged by the later move from FinishedLabel to
# FinishedSummaryMemo -- only its anchor reference did.


def test_layout_no_longer_merely_reads_runlist_top():
    body = _function_body(_text(), "LayoutFinishedSummary")
    assert "WizardForm.RunList.Top := RunListTop;" in body, (
        "RunList's position must be SET by this procedure, not just read -- "
        "reading its stock Top was the root cause of the live overlap"
    )


def test_runlist_is_pinned_to_a_stable_band_near_the_bottom_of_the_page():
    body = _function_body(_text(), "LayoutFinishedSummary")
    assert "WizardForm.FinishedPage.ClientHeight - WizardForm.RunList.Height - ScaleY(8)" in body


def test_runlist_height_is_now_explicitly_computed_not_trusted_from_inno():
    """BUG 2 root cause: Inno's stock RunList.Height (318px for 2 items, per
    live diagnostic evidence) is NOT sized for its actual content -- it must
    now be explicitly SET from a real per-row height, not left alone."""
    body = _function_body(_text(), "LayoutFinishedSummary")
    assert "WizardForm.RunList.Height := (RowHeight * WizardForm.RunList.Items.Count) + ScaleY(6);" in body


def test_run_list_row_height_uses_font_metrics_not_the_stock_height_or_count():
    """Pascal Script exposes no read-only 'actual rendered row height' on
    TNewCheckListBox (confirmed against the Inno Setup 6.7.1 Pascal Script
    class reference: only a settable MinItemHeight floor exists) -- so the
    row height must come from the control's own live Font metrics, never
    from dividing its stock Height by Items.Count (that division is exactly
    the invalid 318/2 geometry this fix removes)."""
    text = _text()
    assert "function RunListRowHeight(List: TNewCheckListBox): Integer;" in text
    body = _function_body(text, "RunListRowHeight")
    assert "List.Font.Height" in body
    assert "List.MinItemHeight" in body
    assert "List.Height" not in body, "must not derive row height from the stock (invalid) Height"
    assert "Items.Count" not in body, "must not derive row height by dividing by item count"


def test_zero_items_hides_runlist_and_gives_summary_the_full_remaining_space():
    """The summary control must not assume a fixed number of RunList items --
    handled defensively for 0 (hidden) as well as N > 0."""
    body = _function_body(_text(), "LayoutFinishedSummary")
    assert "if (WizardForm.RunList <> nil) and (WizardForm.RunList.Items.Count > 0) then" in body
    idx_else = body.index("\n  end\n  else\n")
    else_block = body[idx_else:]
    assert "WizardForm.RunList.Visible := False;" in else_block
    assert "WizardForm.FinishedPage.ClientHeight - FinishedSummaryMemo.Top - ScaleY(12);" in else_block


def test_summary_height_is_derived_from_the_new_runlist_top_not_the_old_one():
    body = _function_body(_text(), "LayoutFinishedSummary")
    idx_set = body.index("WizardForm.RunList.Top := RunListTop;")
    idx_desired = body.index("DesiredHeight := RunListTop - FinishedSummaryMemo.Top - ScaleY(8);")
    assert idx_set < idx_desired, (
        "the memo's height must be computed from the repositioned RunList.Top, "
        "after it has been moved -- not from whatever Inno originally set it to"
    )


def test_desired_height_clamp_is_downward_only_never_forces_overlap():
    """The earlier (broken) versions clamped DesiredHeight UP to a fixed
    minimum (96sc), which is exactly what re-introduced overlap risk when
    RunListTop sat close to the summary control's Top. The fix must only
    floor at zero, never clamp upward past whatever RunListTop actually
    allows."""
    body = _function_body(_text(), "LayoutFinishedSummary")
    assert "if DesiredHeight < 0 then" in body
    assert "DesiredHeight := 0" in body
    assert "ScaleY(96)" not in body, "must not reintroduce the old upward clamp"


def test_geometry_formulas_cannot_produce_an_overlapping_region():
    """Prove the two controls' vertical regions cannot overlap, algebraically,
    for representative (non-negative) FinishedPage/RunList inputs -- not just
    by trusting the source shape. RunListTop has one floor clamp (never above
    FinishedLabel.Top, a degenerate-page-only guard -- see
    test_runlist_top_has_a_degenerate_page_floor_clamp), and DesiredHeight is
    floored at zero; neither can push FinishedLabel's bottom edge past
    RunList.Top."""
    for finished_label_top in (0, 40, 84, 120):
        for client_height in (200, 300, 500, 515, 900):
            for run_list_height in (0, 20, 46, 60, 120):
                run_list_top = client_height - run_list_height - 8
                if run_list_top < finished_label_top:
                    run_list_top = finished_label_top
                desired_height = run_list_top - finished_label_top - 8
                if desired_height < 0:
                    desired_height = 0
                finished_label_bottom = finished_label_top + desired_height
                assert finished_label_bottom <= run_list_top, (
                    f"overlap: label bottom {finished_label_bottom} > RunList.Top {run_list_top} "
                    f"(client_height={client_height}, run_list_height={run_list_height})"
                )


def test_runlist_top_has_a_degenerate_page_floor_clamp():
    """On a pathologically short ClientHeight, RunListTop computed from
    ClientHeight - RunList.Height - margin could fall below the summary
    control's Top, which would overlap even at DesiredHeight=0 (since its
    bottom edge is never above its own Top). This one clamp is necessary and
    cannot itself cause overlap -- it raises RunListTop no higher than the
    summary control's Top, never past it."""
    body = _function_body(_text(), "LayoutFinishedSummary")
    assert "if RunListTop < FinishedSummaryMemo.Top then" in body
    assert "RunListTop := FinishedSummaryMemo.Top;" in body


def test_finished_label_gains_materially_more_height_than_the_broken_128px_case():
    """Live diagnostic evidence measured the OLD (broken) formula giving
    FinishedLabel.Height=128 at ClientHeight=515, FinishedLabel.Top=84,
    Items.Count=2. Prove the NEW formula gives a materially larger region at
    those same inputs, for any plausible per-row height (a single checkbox
    row is comfortably under 60px at any realistic DPI/font combination) --
    the region is now handed to FinishedSummaryMemo, not FinishedLabel."""
    client_height = 515
    finished_label_top = 84
    item_count = 2
    for row_height in (10, 20, 30, 45, 60):
        run_list_height = row_height * item_count + 6
        run_list_top = client_height - run_list_height - 8
        desired_height = run_list_top - finished_label_top - 8
        assert desired_height > 250, (
            f"expected materially more than the broken 128px, got {desired_height} "
            f"for row_height={row_height}"
        )


@pytest.mark.parametrize("scale", [1.0, 1.25, 1.5])
def test_layout_remains_valid_under_100_125_150_percent_scaling(scale):
    """Static algebraic check (not a substitute for a live visual PASS at
    each scale) that the formula stays overlap-free and leaves the summary
    control a sane amount of space across representative DPI scale factors."""

    def sc(px):
        return round(px * scale)

    client_height = sc(515)
    finished_label_top = sc(84)
    for item_count in (0, 1, 2, 5):
        if item_count > 0:
            row_height = sc(14) + sc(8)  # font metric + padding, both DPI-scaled
            run_list_height = row_height * item_count + sc(6)
            run_list_top = client_height - run_list_height - sc(8)
            desired_height = run_list_top - finished_label_top - sc(8)
        else:
            desired_height = client_height - finished_label_top - sc(12)
            run_list_top = client_height  # RunList hidden; nothing to overlap
        if desired_height < 0:
            desired_height = 0
        finished_label_bottom = finished_label_top + desired_height
        assert finished_label_bottom <= run_list_top, (
            f"overlap at scale={scale}, item_count={item_count}"
        )
        assert desired_height > 0, f"zero-height region at scale={scale}, item_count={item_count}"


def test_summary_does_not_assume_content_always_fits_without_scrolling():
    """The whole point of replacing the static label with a memo is to stop
    assuming rendered content height <= available Height. This test exists
    to prevent a future regression back to that assumption: the control must
    be genuinely scrollable (ScrollBars=ssVertical, proven above), and
    nothing in the layout may compute or clamp DesiredHeight against the
    text's own required height (that would defeat the point -- overflow must
    be reachable by scrolling, not pre-emptively sized around)."""
    body = _function_body(_text(), "LayoutFinishedSummary")
    assert "DrawText" not in body
    assert "RequiredHeight" not in body
    assert "TextHeight" not in body


# --- Finish page: merged summary (no duplicate "installed" list) ---------------


def test_installed_locations_heading_is_gone_merged_into_what_was_installed():
    body = _function_body(_text(), "BuildFinishedSuccessSummaryText")
    assert "Installed locations:" not in body, (
        "this repeated the same three items 'What was installed:' already "
        "named; live validation showed the duplication was what pushed the "
        "actually-new size/FFmpeg/backend detail off the visible page"
    )
    assert "What was installed:" in body


def test_each_installed_item_has_its_path_folded_directly_under_it():
    body = _function_body(_text(), "BuildFinishedSuccessSummaryText")
    idx_scripts = body.index("LText('- REAPER scripts:'")
    idx_scripts_line = body.index("ScriptsLine +", idx_scripts)
    idx_runtime = body.index("LText('- STEMwerk runtime:'")
    assert idx_scripts < idx_scripts_line < idx_runtime, (
        "the scripts path/size must appear directly under the scripts bullet, "
        "not in a separate later section"
    )


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
