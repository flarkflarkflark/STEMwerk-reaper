"""P2.1: Windows installer visual refresh (layout/branding only).

The wizard keeps Inno's standard WizardSizePercent=120,120 (applied before
InitializeWizard) and uses Inno's native WizardStyle=modern dynamic. Because
sizing precedes InitializeWizard, Inno's own
controls and every custom control that derives its geometry from a page's
ClientWidth/ClientHeight reflow automatically; only the Welcome/Finished
heading stacks, the structured Finished page and the installing-page
status width needed explicit handling.

Static checks only: these do not (and cannot) prove a visual 100/150% DPI
PASS -- that remains a live check on the release artifact.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
ISS = ROOT / "installer" / "windows" / "STEMwerk.iss"

TAGLINE = "STEM separation for REAPER"

# Chosen after a live width study (see the P2.1 report); vertical stays 120.
FINAL_WIDTH_PERCENT = 120


def _text() -> str:
    return ISS.read_text(encoding="utf-8")


def _setup_section(text: str) -> str:
    start = text.index("[Setup]")
    end = text.index("\n[", start + 1)
    return text[start:end]


def _function_body(text: str, name: str) -> str:
    try:
        start = text.index(f"function {name}")
    except ValueError:
        start = text.index(f"procedure {name}")
    begin_idx = text.index("begin", start)
    depth = 0
    for match in re.finditer(r"\b(begin|end)\b", text[begin_idx:]):
        depth += 1 if match.group(1) == "begin" else -1
        if depth == 0:
            return text[start : begin_idx + match.end()]
    raise AssertionError(f"unbalanced begin/end in {name}")


# --- Native sizing / style ----------------------------------------------------


def test_wizard_size_percent_is_set_within_inno_documented_range():
    setup = _setup_section(_text())
    lines = [ln for ln in setup.splitlines() if ln.startswith("WizardSizePercent=")]
    assert len(lines) == 1, "exactly one WizardSizePercent directive expected"
    horizontal, vertical = (int(v) for v in lines[0].split("=", 1)[1].split(","))
    # Inno 6.7.1: valid range 100..150 for each axis; 120,120 is the standard
    # size. Compact structured rows make the earlier 150% width unnecessary.
    assert 100 <= horizontal <= 150 and 100 <= vertical <= 150
    assert horizontal == 120 and vertical == 120
    assert (horizontal, vertical) == (FINAL_WIDTH_PERCENT, 120)


def test_wizard_style_follows_the_windows_theme_natively():
    setup = _setup_section(_text())
    lines = [ln for ln in setup.splitlines() if ln.startswith("WizardStyle=")]
    assert lines == ["WizardStyle=modern dynamic"], lines
    # Neither appearance may be forced: "light" or "dark" alone would ignore
    # the user's Windows setting. No custom/third-party skins either.
    tokens = lines[0].split("=", 1)[1].split()
    assert "dynamic" in tokens and "modern" in tokens
    assert "light" not in tokens and "dark" not in tokens
    assert "WizardStyleFile" not in setup, "no third-party VCL skin files"


def test_custom_wizard_images_also_cover_dynamic_dark():
    """In dynamic mode the plain Wizard*ImageFile directives only apply to the
    light case; without the DynamicDark variants Inno silently shows its own
    built-in dark images (observed live). Both must point at the same
    existing STEMwerk assets -- no new asset."""
    setup = _setup_section(_text())
    assert "WizardImageFile=..\\assets\\stemwerk-wizard.bmp" in setup
    assert "WizardImageFileDynamicDark=..\\assets\\stemwerk-wizard.bmp" in setup
    assert "WizardSmallImageFile=..\\assets\\stemwerk.png" in setup
    assert "WizardSmallImageFileDynamicDark=..\\assets\\stemwerk.png" in setup


def test_header_logo_source_is_square_without_white_padding_rows():
    """Inno's header-logo area is square. The previous 55x58 bmp had solid
    white rows baked in (visible as white bands above/below the logo); the
    source now used must be square, large enough to only ever be shrunk, and
    free of all-white edge rows."""
    from PIL import Image

    im = Image.open(ROOT / "installer" / "assets" / "stemwerk.png").convert("RGB")
    w, h = im.size
    assert w == h, "header logo area is square"
    assert w >= 159, "must not be upscaled even at 250% DPI (159x159 area)"
    px = im.load()
    for y in (0, 1, h - 2, h - 1):
        assert not all(min(px[x, y]) >= 240 for x in range(w)), f"white padding row at y={y}"


def test_no_manual_form_or_button_geometry_is_forced():
    """Inno sizes the form, notebooks and the Back/Next/Cancel buttons itself
    (they reflow with WizardSizePercent); overriding any of them by hand would
    fight that and risk buttons falling outside the client area at some DPI."""
    text = _text()
    for forbidden in (
        "WizardForm.Width :=",
        "WizardForm.Height :=",
        "WizardForm.ClientWidth :=",
        "WizardForm.ClientHeight :=",
        "OuterNotebook.Width",
        "InnerNotebook.Width",
        "NextButton.Left",
        "NextButton.Top",
        "BackButton.Left",
        "BackButton.Top",
        "CancelButton.Left",
        "CancelButton.Top",
    ):
        assert forbidden not in text, f"unexpected manual geometry override: {forbidden!r}"


def test_ready_memo_and_license_memo_left_to_native_reflow():
    text = _text()
    for forbidden in ("ReadyMemo.Width", "ReadyMemo.Left", "ReadyMemo.Height", "LicenseMemo.Width"):
        assert forbidden not in text


# --- Tagline ------------------------------------------------------------------


def test_tagline_defined_once_with_the_exact_wording():
    text = _text()
    assert f'#define MyAppTagline "{TAGLINE}"' in text
    assert text.count(TAGLINE) == 1, "the tagline must have a single source of truth"


def test_tagline_is_a_product_string_not_translated_prose():
    body = _function_body(_text(), "CreateTaglineLabel")
    assert "Result.Caption := '{#MyAppTagline}';" in body
    assert "LText(" not in body, "the tagline reads identically in EN/NL/DE"


@pytest.mark.parametrize("forbidden", ["ai-powered", "ai stem", "ai-driven", "ai powered", "powered by ai"])
def test_no_ai_marketing_wording(forbidden):
    assert forbidden not in _text().lower()


# --- Heading hierarchy ----------------------------------------------------------


def test_brand_wordmark_reuses_the_existing_brand_colours():
    body = _function_body(_text(), "CreateBrandWordmark")
    for part, colour in (
        ("'S'", "RGBColor(255, 100, 100)"),
        ("'T'", "RGBColor(100, 200, 255)"),
        ("'E'", "RGBColor(150, 100, 255)"),
        ("'M'", "RGBColor(100, 255, 150)"),
    ):
        assert part in body and colour in body
    # Only S-T-E-M are brand-coloured (theme-aware); "werk" keeps the style's
    # own text colour so it reads on both light and dark.
    assert "Parts[4] := 'werk'; Colors[4] := 0;" in body
    assert "if i < 4 then" in body and "ApplyBrandTextColor(L, Colors[i]);" in body
    assert "L.Font.Color" not in body
    assert "L.Font.Size := AFontSize;" in body
    assert "LText(" not in body


def test_welcome_uses_wordmark_then_tagline_then_body():
    body = _function_body(_text(), "InitializeWizard")
    idx_mark = body.index("CreateBrandWordmark(WizardForm.WelcomePage, WelcomeX, WelcomeTitleY, 15);")
    idx_tag = body.index("CreateTaglineLabel(WizardForm.WelcomePage, WelcomeX, TitleBottom + ScaleY(2));")
    idx_y = body.index("WelcomeY := Tagline.Top + Tagline.Height + ScaleY(14);")
    idx_info = body.index("WelcomeInfoLabel.Top := WelcomeY;")
    assert idx_mark < idx_tag < idx_y < idx_info


def test_old_welcome_title_row_is_gone():
    text = _text()
    assert "WelcomeTitlePrefixLabel" not in text
    assert "WelcomeTitleSuffixLabel" not in text


def test_finished_heading_is_product_identity_not_a_success_claim():
    body = _function_body(_text(), "InitializeWizard")
    assert "CreateBrandWordmark(WizardForm.FinishedPage," in body
    assert "CreateTaglineLabel(WizardForm.FinishedPage," in body
    assert "WizardForm.FinishedHeadingLabel.Visible := False;" in body
    for forbidden in ("Completing the ", "Afronden van ", "Abschluss des "):
        assert forbidden not in body


def test_finished_content_top_never_starts_inside_the_heading():
    body = _function_body(_text(), "InitializeWizard")
    assert "FinishedContentTop := WizardForm.FinishedLabel.Top;" in body
    assert "if Tagline.Top + Tagline.Height + ScaleY(12) > FinishedContentTop then" in body
    assert "FinishedContentTop := Tagline.Top + Tagline.Height + ScaleY(12);" in body


def test_finished_page_is_structured_and_runlist_stays_compact():
    text = _text()
    init_body = _function_body(text, "InitializeWizard")
    assert "FinishedOutcomeLabel := CreateFinishedText('', False);" in init_body
    assert "FinishedPathEdits[i] := TNewEdit.Create(WizardForm);" in init_body
    assert "FinishedPathEdits[i].ReadOnly := True;" in init_body
    assert "FinishedSummaryMemo" not in text
    layout = _function_body(text, "LayoutFinishedPage")
    assert "FinishedOutcomeLabel.Top := y;" in layout
    assert "WizardForm.RunList.Height := (RunListRowHeight(WizardForm.RunList) * WizardForm.RunList.Items.Count) + ScaleY(6);" in layout


# --- Installing page --------------------------------------------------------------


def test_status_detail_uses_the_full_page_width():
    body = _function_body(_text(), "InitializeWizard")
    assert "StatusDetailLabel.Width := PageW - StatusDetailLabel.Left - ScaleX(8);" in body
    assert "ScaleX(112)" not in body


def test_installing_controls_still_derive_from_the_page_size():
    body = _function_body(_text(), "InitializeWizard")
    assert "PageW := WizardForm.InstallingPage.ClientWidth;" in body
    assert "ColumnW := (PageW - (ColumnGap * 4)) div 5;" in body
    assert "WizardForm.ProgressGauge.Width := PageW;" in body
    assert "LogMemo.Width := WizardForm.InstallingPage.ClientWidth;" in body
    assert "LogMemo.Height := WizardForm.InstallingPage.ClientHeight - LogMemo.Top;" in body


# --- Algebraic DPI geometry (not a visual PASS) ---------------------------------------


@pytest.mark.parametrize("scale", [1.0, 1.25, 1.5])
def test_finished_dashboard_gains_the_reclaimed_bitmap_column(scale):
    """The Finished bitmap column is handed to the structured dashboard while
    keeping symmetric native insets."""

    def sc(px):
        return round(px * scale)

    page_w = round(637 * scale)
    inset = sc(42)  # 53px @125%
    dashboard_w = page_w - 2 * inset
    assert dashboard_w > sc(500)
    assert inset + dashboard_w + inset == page_w
    body = _function_body(_text(), "LayoutFinishedPage")
    assert "CW := WizardForm.FinishedPage.ClientWidth - (2 * L);" in body
    assert "WizardForm.RunList.Width := CW;" in body


# --- Theme safety (WizardStyle=modern dynamic) ---------------------------------------

PLAIN_TEXT_LABELS = (
    "WelcomeInfoLabel",
    "TasksWelcomeLabel",
    "TasksWelcomeSuffixLabel",
    "TasksWelcomeSubLabel",
    "TasksBrandLabel",
    "TasksInfoLabel",
    "StatusPrefixLabel",
    "StatusSuffixLabel",
    "StatusDetailLabel",
    "ProgressOverlayLabel",
)


@pytest.mark.parametrize("label", PLAIN_TEXT_LABELS)
def test_plain_text_labels_keep_the_native_theme_colour(label):
    """These fixed dark greys existed only because the wizard used to be
    light-only; on the dark style they would drop to ~1.2-2.2:1 if honoured.
    Plain text must follow the style's own text colour."""
    assert f"{label}.Font.Color" not in _text()


def test_tagline_uses_the_native_text_colour():
    assert "Font.Color" not in _function_body(_text(), "CreateTaglineLabel")


@pytest.mark.parametrize("letter", ["S", "T", "E", "M"])
def test_header_brand_letters_are_theme_aware(letter):
    text = _text()
    for prefix in ("TasksWelcomeStem", "StatusStem"):
        name = f"{prefix}{letter}"
        assert f"{name}.Font.Color" not in text
        assert f"ApplyBrandTextColor({name}, RGBColor(" in text


def test_apply_brand_text_color_keeps_colour_under_dark_style_and_respects_high_contrast():
    body = _function_body(_text(), "ApplyBrandTextColor")
    assert "if HighContrastActive then Exit;" in body
    assert "L.StyleElements := L.StyleElements - [seFont];" in body
    assert "L.Font.Color := BrandTextColor(DarkPaletteColor);" in body
    assert body.index("HighContrastActive") < body.index("Font.Color")


def _wcag_contrast(rgb_a, rgb_b):
    def lum(rgb):
        def lin(c):
            c /= 255
            return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4

        r, g, b = (lin(c) for c in rgb)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b

    hi, lo = sorted((lum(rgb_a), lum(rgb_b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def test_brand_palette_is_readable_on_both_styles():
    """Dark mode keeps the original palette (large bold wordmark >= 3:1 on a
    dark page); light mode uses the mapped darker shades, which must reach
    4.5:1 on white because the same mapping also colours 9pt step labels."""
    body = _function_body(_text(), "BrandTextColor")
    assert "if IsDarkInstallMode then Exit;" in body
    pairs = re.findall(
        r"DarkPaletteColor = RGBColor\((\d+), (\d+), (\d+)\) then Result := RGBColor\((\d+), (\d+), (\d+)\)",
        body,
    )
    assert len(pairs) == 5, pairs
    for pair in pairs:
        dark = tuple(int(v) for v in pair[:3])
        light = tuple(int(v) for v in pair[3:])
        assert _wcag_contrast(dark, (32, 32, 32)) >= 3.0, dark
        assert _wcag_contrast(light, (255, 255, 255)) >= 4.5, light


def test_step_bars_are_theme_aware_and_have_no_fixed_light_track_at_creation():
    text = _text()
    bar = _function_body(text, "SetStepBarState")
    assert "if IsDarkInstallMode then" in bar
    assert "TrackPanel.StyleElements := TrackPanel.StyleElements - [seClient];" in bar
    assert "FillPanel.StyleElements := FillPanel.StyleElements - [seClient];" in bar
    assert "FillPanel.Color := BrandTextColor(FillColor);" in bar
    init_body = _function_body(text, "InitializeWizard")
    assert "RGBColor(232, 232, 232)" not in init_body


def test_inactive_step_labels_use_a_theme_aware_dimmed_colour():
    body = _function_body(_text(), "SetStepLabelState")
    assert "ApplyBrandTextColor(L, BaseColor);" in body
    assert "if IsDarkInstallMode then" in body
    assert "RGBColor(150, 150, 150)" in body and "RGBColor(110, 110, 110)" in body
    assert "if not HighContrastActive then" in body


# --- Welcome keeps its bitmap, Finished reclaims its column --------------------------


def test_welcome_bitmap_stays_visible():
    text = _text()
    assert "WizardForm.WizardBitmapImage.Visible := True;" in _function_body(text, "ApplyUnifiedWizardBranding")
    assert "WizardBitmapImage.Visible := False" not in text


def test_finished_bitmap_is_hidden_and_its_column_reclaimed():
    body = _function_body(_text(), "InitializeWizard")
    assert "WizardForm.WizardBitmapImage2.Visible := False;" in body
    assert "FinishedContentLeft := WizardForm.InnerNotebook.Left;" in body
    assert "CreateBrandWordmark(WizardForm.FinishedPage,\n      FinishedContentLeft," in body.replace("\r\n", "\n")
    assert "CreateTaglineLabel(WizardForm.FinishedPage,\n      FinishedContentLeft," in body.replace("\r\n", "\n")


# --- Cleanup persistence (approved safety change) -------------------------------------


def test_previous_task_choices_are_not_restored():
    assert "UsePreviousTasks=no" in _setup_section(_text()).splitlines()


def test_cleanup_task_is_unchecked_by_default_without_persistence_workarounds():
    text = _text()
    assert 'Name: "cleanup_runtime"; Description: "{cm:TaskCleanupRuntime}"; Flags: unchecked' in text
    assert "checkedonce" not in text
    assert "WizardSelectTasks(" not in text
