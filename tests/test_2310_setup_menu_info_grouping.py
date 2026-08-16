"""Regression tests for the 2.3.1.0 Setup-menu "environment details" grouping
GUI polish in STEMwerk_Setup_Internal.lua.

The pre-action existing-runtime Setup menu (existingRuntimeSetupMenuTick --
shown when an existing runtime is detected, before the user picks
Check/Repair/Rebuild) used to render its Runtime/Models/Setup script/Recorded
setup version rows as three separate floating pieces (one bordered box for
Runtime, then unbordered free-floating Models and version-line text). This
groups all four rows into one bordered `drawLinuxPanel` info card so they
read as a single related unit.

A follow-up pass then made the four rows internally consistent: Runtime used
to split its label onto one line and its (possibly wrapped) value onto the
line(s) below, Models already rendered label+value on one line, and Setup
script/Recorded setup version were concatenated onto a single shared line.
Now all four rows are one row per field, label and value on the same line,
with a shared value column so the block reads as an aligned table.

This is presentation-only: no gfx/REAPER environment is available in this
sandbox to execute the draw path itself (see the module docstring in
tests/support/run_setup_final_rows_headless.lua for the same limitation --
that harness's `reaper` stub deliberately does not include `gfx`), so these
tests prove the structural invariants via source inspection rather than
pixel output, following the same style already used by
tests/test_2310_diagnostics_truthfulness.py for this exact file.

Data-source/verdict/color/historical-log/scroll semantics for the *separate*
post-action finalized result window (linuxDrawFinal /
deriveLinuxFinalPresentation / buildLinuxFinalRows) are untouched by this
change and continue to be covered by the existing
tests/support/run_setup_linux_final_presentation_headless.lua,
tests/support/run_setup_linux_not_proven_headless.lua and
tests/support/run_setup_final_rows_headless.lua suites -- this file does not
duplicate those.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "scripts" / "reaper" / "_internal" / "STEMwerk_Setup_Internal.lua"


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _function_body(text: str, signature: str) -> str:
    """Return a Lua function's body, from its `function NAME(...)` line up to
    the matching column-0 `end` that closes it (mirrors the existing
    text.index(...)-based slicing convention already used against this same
    file in tests/test_2310_diagnostics_truthfulness.py)."""
    start = text.index(signature)
    end = text.index("\nend", start)
    return text[start:end]


class TestExistingRuntimeMenuInfoGrouping:
    """existingRuntimeSetupMenuTick is the pre-action "existing runtime
    found, choose what to do" menu -- confirmed by grep to be the only place
    in this file where the setup_runtime_label/setup_models_label/
    setup_script_label/setup_last_run_label rows are rendered at all."""

    def test_four_row_labels_render_exactly_once_each_in_the_menu_function(self):
        text = _read(SETUP)
        body = _function_body(text, "function existingRuntimeSetupMenuTick()")

        assert body.count('setupText("setup_runtime_label"') == 1
        assert body.count('setupText("setup_models_label"') == 1
        assert body.count('setupText("setup_script_label"') == 1
        # The label is now resolved once (its own row); only the *value*
        # differs between the known-version and unknown-version branches.
        assert body.count('setupText("setup_last_run_label"') == 1

    def test_row_order_is_runtime_then_models_then_script_then_recorded_version(self):
        text = _read(SETUP)
        body = _function_body(text, "function existingRuntimeSetupMenuTick()")

        runtime_idx = body.index('setupText("setup_runtime_label"')
        models_idx = body.index('setupText("setup_models_label"')
        script_idx = body.index('setupText("setup_script_label"')
        recorded_idx = body.index('setupText("setup_last_run_label"')

        assert runtime_idx < models_idx < script_idx < recorded_idx

    def test_four_rows_share_a_single_grouped_panel_container(self):
        """All four rows must be drawn inside ONE drawLinuxPanel(...) card
        (the grouping), not each floating separately or each getting its own
        border as before."""
        text = _read(SETUP)
        body = _function_body(text, "function existingRuntimeSetupMenuTick()")

        card_start = body.index("-- Environment details card")
        # The next drawLinuxPanel call after the card comment is the grouped
        # container; the four labels must all be *drawn* after it opens.
        # (setupText(...) resolution for runtime/models labels happens
        # earlier, alongside their width/wrap measurements, so this checks
        # the actual gfx.drawstr(...) call sites -- the real render order --
        # rather than where each label string gets resolved.)
        panel_call_idx = body.index("drawLinuxPanel(bodyX, y, leftColW, groupH,", card_start)

        runtime_draw_idx = body.index("gfx.drawstr(runtimeLabel)", card_start)
        models_draw_idx = body.index("gfx.drawstr(modelLabel)", card_start)
        script_draw_idx = body.index("gfx.drawstr(scriptLabel)", card_start)
        recorded_draw_idx = body.index("gfx.drawstr(recordedLabel)", card_start)

        assert panel_call_idx < runtime_draw_idx < models_draw_idx < script_draw_idx < recorded_draw_idx

        # And there must be exactly one drawLinuxPanel call feeding this
        # card's four rows (no leftover per-row border from the old layout).
        # Scope the count to the card region only: from the card comment up
        # to the row loop that closes it ("y = y + groupH + 10"), so this
        # does not pick up the unrelated "Modes" summary panel drawn later
        # in the same function.
        card_end = body.index("y = y + groupH + 10", card_start)
        card_region = body[card_start:card_end]
        assert card_region.count("drawLinuxPanel(") == 1

    def test_exactly_four_rows_are_drawn_in_order(self):
        """Runtime, Models, Setup script and Recorded setup version must
        each get their own row -- no more, no fewer -- drawn in that order."""
        text = _read(SETUP)
        body = _function_body(text, "function existingRuntimeSetupMenuTick()")
        card_start = body.index("-- Environment details card")
        card_end = body.index("y = y + groupH + 10", card_start)
        card_region = body[card_start:card_end]

        label_draws = re.findall(
            r"gfx\.drawstr\((runtimeLabel|modelLabel|scriptLabel|recordedLabel)\)",
            card_region,
        )
        assert label_draws == ["runtimeLabel", "modelLabel", "scriptLabel", "recordedLabel"]

    def _row_pair_is_adjacent(self, card_region: str, label_var: str, value_var: str) -> bool:
        """True if the label's gfx.drawstr(...) and its value's
        gfx.drawstr(...) are drawn with no `rowY = rowY + ...` advance in
        between -- i.e. they share the same row/gfx.y."""
        label_idx = card_region.index(f"gfx.drawstr({label_var})")
        value_idx = card_region.index(f"gfx.drawstr({value_var})", label_idx)
        between = card_region[label_idx:value_idx]
        return "rowY = rowY" not in between

    def test_runtime_label_and_value_share_the_same_row(self):
        text = _read(SETUP)
        body = _function_body(text, "function existingRuntimeSetupMenuTick()")
        card_start = body.index("-- Environment details card")
        card_end = body.index("y = y + groupH + 10", card_start)
        card_region = body[card_start:card_end]
        assert self._row_pair_is_adjacent(card_region, "runtimeLabel", "runtimeValue")

    def test_models_label_and_value_share_the_same_row(self):
        text = _read(SETUP)
        body = _function_body(text, "function existingRuntimeSetupMenuTick()")
        card_start = body.index("-- Environment details card")
        card_end = body.index("y = y + groupH + 10", card_start)
        card_region = body[card_start:card_end]
        assert self._row_pair_is_adjacent(card_region, "modelLabel", "modelValue")

    def test_setup_script_label_and_value_share_the_same_row(self):
        text = _read(SETUP)
        body = _function_body(text, "function existingRuntimeSetupMenuTick()")
        card_start = body.index("-- Environment details card")
        card_end = body.index("y = y + groupH + 10", card_start)
        card_region = body[card_start:card_end]
        assert self._row_pair_is_adjacent(card_region, "scriptLabel", "scriptValue")

    def test_recorded_version_label_and_value_share_the_same_row(self):
        text = _read(SETUP)
        body = _function_body(text, "function existingRuntimeSetupMenuTick()")
        card_start = body.index("-- Environment details card")
        card_end = body.index("y = y + groupH + 10", card_start)
        card_region = body[card_start:card_end]
        assert self._row_pair_is_adjacent(card_region, "recordedLabel", "recordedValue")

    def test_setup_script_and_recorded_version_no_longer_share_a_row(self):
        """This was the exact bug being fixed: Setup script and Recorded
        setup version used to be concatenated onto one shared verLabel
        line. They must now be two independent rows with a rowY advance
        between the script row's value and the recorded-version row's
        label."""
        text = _read(SETUP)
        body = _function_body(text, "function existingRuntimeSetupMenuTick()")
        card_start = body.index("-- Environment details card")
        card_end = body.index("y = y + groupH + 10", card_start)
        card_region = body[card_start:card_end]

        script_value_idx = card_region.index("gfx.drawstr(scriptValue)")
        recorded_label_idx = card_region.index("gfx.drawstr(recordedLabel)", script_value_idx)
        between = card_region[script_value_idx:recorded_label_idx]
        assert "rowY = rowY" in between

        # And there must be no single combined "verLabel" concatenation left
        # anywhere in the card region (the old shared-row implementation).
        assert "verLabel" not in card_region

    def test_data_sources_are_unchanged(self):
        """The four rows must still read from the exact same fields as
        before: m.runtime.base, m.modelDir, m.currentVersion,
        m.lastSetupVersion. No cached copies or duplicate state were
        introduced for layout purposes."""
        text = _read(SETUP)
        body = _function_body(text, "function existingRuntimeSetupMenuTick()")
        card_start = body.index("-- Environment details card")
        card_end = body.index("y = y + groupH + 10", card_start)
        card_region = body[card_start:card_end]

        assert "tostring(m.runtime.base)" in card_region
        assert "tostring(m.modelDir)" in card_region
        assert 'm.currentVersion or ""' in card_region
        assert 'm.lastSetupVersion or ""' in card_region

    def test_grouping_is_scoped_to_this_menu_and_does_not_touch_the_finalized_result_window(self):
        """linuxDrawFinal is the separate post-action finalized-result
        window (built from deriveLinuxFinalPresentation/buildLinuxFinalRows)
        and must not gain (or lose) any of these four rows as a side effect
        of this change."""
        text = _read(SETUP)
        final_body = _function_body(text, "function linuxDrawFinal(finalLines, finalSuccess, state, logLines, pid)")

        assert 'setupText("setup_runtime_label"' not in final_body
        assert 'setupText("setup_models_label"' not in final_body
        assert 'setupText("setup_script_label"' not in final_body
        assert '"-- Environment details card"' not in final_body
        assert "-- Environment details card" not in final_body

    def test_group_container_reuses_the_existing_drawlinuxpanel_primitive(self):
        """Section 5 of the grouping requirement: reuse an existing
        panel/card primitive rather than inventing a new design system."""
        text = _read(SETUP)
        assert re.search(r"^local function drawLinuxPanel\(x, y, w, h, bg, border\)", text, re.MULTILINE)

    def test_windows_overview_extra_rows_still_render_after_the_grouped_card(self):
        """OS == 'Windows' renders its own additional overview rows further
        down in the same function; confirm that block still exists,
        unchanged, and still comes after the grouped card rather than being
        absorbed into it (this function is shared across Windows/macOS/
        Linux -- only the four common rows are grouped)."""
        text = _read(SETUP)
        body = _function_body(text, "function existingRuntimeSetupMenuTick()")
        card_start = body.index("-- Environment details card")
        windows_idx = body.index('if OS == "Windows" and m.windowsOverview then')
        assert windows_idx > card_start

    def _windows_overview_block(self) -> str:
        text = _read(SETUP)
        body = _function_body(text, "function existingRuntimeSetupMenuTick()")
        start = body.index('if OS == "Windows" and m.windowsOverview then')
        end = body.index("\n    end", start)
        return body[start:end]

    def test_windows_overview_detail_rows_use_theme_aware_text_color(self):
        """Profile/backend, Python, FFmpeg, Verification, audio_separator,
        stemwerk_core, samplerate and julius are drawn from the shared `rows`
        list in this block. That draw call used to hard-code a light-gray
        gfx.set() triplet meant for a dark background only, so on Windows
        light theme these rows were nearly invisible while the rest of the
        UI (which reads themeTextSecondary/ACTIVE_THEME like every other row
        on this same screen) stayed readable. Assert the rows color call is
        theme-aware instead of a bare literal."""
        block = self._windows_overview_block()
        assert "gfx.set(0.78, 0.80, 0.84, 1)" not in block, (
            "detail rows still use the old hard-coded dark-theme-only color literal"
        )
        assert "gfx.set(themeTextSecondary[1], themeTextSecondary[2], themeTextSecondary[3], 1)" in block

    def test_windows_overview_status_line_semantic_color_is_unchanged(self):
        """Only the detail rows below 'Last setup: ...' were reported as a
        contrast problem -- the status line itself already reads fine in both
        themes. Prove its semantic (repair/ok) color assignment is untouched
        by the detail-row contrast fix."""
        block = self._windows_overview_block()
        assert (
            "gfx.set(o.needsRepair and 0.97 or 0.55, o.needsRepair and 0.80 or 0.57, "
            "o.needsRepair and 0.15 or 0.62, 1)"
        ) in block

    def test_theme_text_secondary_token_definition_is_untouched(self):
        """The fix must reuse the existing textSecondary theme token, not
        redefine it or change its light/dark palette values."""
        text = _read(SETUP)
        assert 'local themeTextSecondary = setupThemeColor("textSecondary", { 0.55, 0.57, 0.62 })' in text
