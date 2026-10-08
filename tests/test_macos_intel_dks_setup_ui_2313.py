"""Setup UI consistency fix for Intel-macOS Drum Kit / DKS, STEMwerk 2.3.1.3.

Product policy (unchanged, already correctly enforced by the main STEMwerk.lua
processing GUI's intelMacDksPolicyBlocked(), which hides Direct Kit/Kit Split
controls there): Drum Kit Split is unsupported on Intel macOS, supported on
Apple Silicon macOS, and unaffected on any Linux architecture.

Before this slice, STEMwerk Setup (a separate REAPER script/process from the
main GUI) still:
  - offered an actionable "Drum Kit Split runtime" install/repair action and
    a "DrumKit CPU" Modes legend entry on Intel macOS (buildSetupMenuChoices
    gated only on OS ~= "Windows", with no Intel-macOS carve-out);
  - presented a fifth progress/final row for Drum Kit on Intel macOS even
    though that platform has no DrumSep setup phase;
  - had no defense-in-depth guard if "drumsep-runtime"/"drumsep-rocm-runtime"
    setup dispatch was somehow invoked directly on Intel macOS.

The fix adds one small, reused policy source, isIntelMacDksUnsupported(), to
STEMwerk_Setup_Internal.lua (mirroring the main GUI's check, which this
separate script cannot call directly) and applies it at the three UI/dispatch
surfaces above. Check-only/Repair diagnostic reporting already correctly said
"unsupported on Intel macOS" via resolveDrumsepPolicyState/DKS_SUPPORTED (now
consolidated to call the same new helper) and is unchanged by this slice.

Follow-up i18n correction: the direct-dispatch guard's message originally used
a raw, hand-written English string instead of the existing
drumsep_intel_mac_unsupported_title/_body keys the main STEMwerk.lua GUI's
showIntelMacDksPolicyBlock() already uses for this identical policy. It now
calls setupText(key, fallback) -- the same STEMwerk_I18N.lua/languages.lua
dictionary -- so EN/NL/DE all resolve through the existing translations
instead of a Setup-only duplicate.

Real production logic execution: tests/support/run_macos_intel_dks_setup_ui_headless.lua
dofile()s the actual STEMwerk_Setup_Internal.lua and exercises the real
choices-list/legend-model/dispatch functions -- not a reimplementation, not a
screenshot.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SETUP_INTERNAL = ROOT / "scripts" / "reaper" / "_internal" / "STEMwerk_Setup_Internal.lua"

LUA = shutil.which("lua5.4") or shutil.which("lua5.3") or shutil.which("lua") or shutil.which("luajit")
pytestmark = pytest.mark.skipif(LUA is None, reason="no lua interpreter available")


def test_intel_macos_drum_kit_setup_ui_headless() -> None:
    result = subprocess.run(
        [LUA, "tests/support/run_macos_intel_dks_setup_ui_headless.lua"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, f"headless Intel-macOS DKS Setup UI harness failed:\n{result.stdout}\n{result.stderr}"
    for marker in (
        # 0) Fresh production entry: architecture is discovered by Setup
        # itself, then the real healthy-existing-runtime screen is rendered.
        "PASS fresh-intel-production-load-detects-x86_64-without-global-injection",
        "PASS fresh-intel-healthy-existing-runtime-has-exact-action-grid",
        "PASS fresh-intel-healthy-existing-runtime-renders-real-screen",
        "PASS fresh-intel-healthy-existing-runtime-renders-no-dks-action-or-mode",
        "PASS fresh-intel-healthy-existing-runtime-keeps-normal-actions",
        # 0b) Shared renderer polish is exercised through the real draw path:
        #     localized text, aligned cards, practical sizes, and zoom.
        "PASS intel-default-layout-renders-complete-aligned-card-text-en",
        "PASS intel-default-layout-renders-localized-header-and-modes-en",
        "PASS intel-default-layout-has-nine-uniform-nonoverlapping-cards-en",
        "PASS intel-default-layout-renders-complete-aligned-card-text-nl",
        "PASS intel-default-layout-renders-localized-header-and-modes-nl",
        "PASS intel-default-layout-has-nine-uniform-nonoverlapping-cards-nl",
        "PASS intel-default-layout-renders-complete-aligned-card-text-de",
        "PASS intel-default-layout-renders-localized-header-and-modes-de",
        "PASS intel-default-layout-has-nine-uniform-nonoverlapping-cards-de",
        "PASS intel-minimum-viewport-keeps-uniform-nonoverlapping-action-grid",
        "PASS intel-larger-viewport-keeps-uniform-nonoverlapping-action-grid",
        "PASS intel-minimum-viewport-at-160pct-keeps-action-grid-in-bounds",
        "PASS intel-minimum-viewport-at-80pct-keeps-action-grid-in-bounds",
        "PASS intel-minimum-viewport-at-260pct-uses-compact-grid-in-bounds",
        "PASS intel-localized-layout-complete-valid-utf8-en-100%",
        "PASS intel-localized-layout-complete-valid-utf8-en-260%",
        "PASS intel-localized-layout-complete-valid-utf8-en-300%",
        "PASS intel-localized-layout-complete-valid-utf8-nl-100%",
        "PASS intel-localized-layout-complete-valid-utf8-nl-260%",
        "PASS intel-localized-layout-complete-valid-utf8-nl-300%",
        "PASS intel-localized-layout-complete-valid-utf8-de-100%",
        "PASS intel-localized-layout-complete-valid-utf8-de-260%",
        "PASS intel-localized-layout-complete-valid-utf8-de-300%",
        # 1) Intel macOS Setup actions: no actionable Drum Kit Split runtime.
        "PASS intel-macos-setup-actions-have-no-drumsep-runtime-choice",
        "PASS intel-macos-setup-actions-keep-unrelated-mutating-actions",
        # 2) Intel macOS Modes legend: no actionable DrumKit CPU.
        "PASS intel-macos-modes-legend-has-no-drumkit-cpu-producing-choice",
        # 3) Intel macOS Setup/Repair/Check presentation: exactly four rows.
        "PASS intel-macos-step-legend-has-exactly-four-rows",
        "PASS intel-macos-step-legend-has-no-drum-kit-row",
        "PASS intel-macos-step-legend-has-no-unsupported-row",
        "PASS intel-macos-steps-1-through-4-are-unaffected",
        # 4) Direct Drum Kit setup dispatch on Intel macOS: clean, no mutation,
        #    and the message reuses the existing localized keys in EN/NL/DE.
        "PASS intel-macos-direct-dispatch-writes-no-state-file-en",
        "PASS intel-macos-direct-dispatch-shows-exactly-one-message-en",
        "PASS intel-macos-dispatch-title-is-in-the-title-slot-en",
        "PASS intel-macos-dispatch-body-is-in-the-text-slot-en",
        "PASS intel-macos-dispatch-body-is-not-the-old-raw-custom-english-text-en",
        "PASS intel-macos-direct-dispatch-writes-no-state-file-nl",
        "PASS intel-macos-direct-dispatch-shows-exactly-one-message-nl",
        "PASS intel-macos-dispatch-title-is-in-the-title-slot-nl",
        "PASS intel-macos-dispatch-body-is-in-the-text-slot-nl",
        "PASS intel-macos-dispatch-body-is-not-the-old-raw-custom-english-text-nl",
        "PASS intel-macos-direct-dispatch-writes-no-state-file-de",
        "PASS intel-macos-direct-dispatch-shows-exactly-one-message-de",
        "PASS intel-macos-dispatch-title-is-in-the-title-slot-de",
        "PASS intel-macos-dispatch-body-is-in-the-text-slot-de",
        "PASS intel-macos-dispatch-body-is-not-the-old-raw-custom-english-text-de",
        "PASS intel-macos-direct-dispatch-also-blocks-drumsep-rocm-runtime",
        "PASS intel-macos-rocm-dispatch-also-uses-the-localized-keys",
        # 5) Apple Silicon macOS: Drum Kit actions remain available.
        "PASS apple-silicon-production-load-detects-arm64",
        "PASS apple-silicon-is-not-flagged-unsupported",
        "PASS apple-silicon-setup-actions-still-offer-drumsep-runtime",
        "PASS apple-silicon-existing-runtime-ui-keeps-dks-card-and-mode",
        "PASS apple-silicon-existing-runtime-ui-keeps-uniform-nonoverlapping-grid",
        "PASS apple-silicon-modes-complete-260%",
        "PASS apple-silicon-modes-complete-300%",
        "PASS apple-silicon-step5-label-is-the-original-unchanged-label",
        "PASS apple-silicon-step5-is-not-forced-neutral",
        "PASS apple-silicon-direct-dispatch-is-not-blocked-by-the-intel-guard",
        "PASS apple-silicon-direct-dispatch-writes-the-drumsep-state-file",
        # 6) Linux x86_64: unaffected.
        "PASS linux-x86_64-is-not-flagged-unsupported-by-the-macos-guard",
        "PASS linux-x86_64-setup-actions-still-offer-drumsep-runtime",
        "PASS linux-existing-runtime-ui-keeps-dks-card-and-mode",
        "PASS linux-existing-runtime-ui-keeps-uniform-nonoverlapping-grid",
        "PASS linux-modes-complete-260%",
        "PASS linux-modes-complete-300%",
        "PASS linux-x86_64-step5-label-is-the-original-unchanged-label",
        "PASS linux-x86_64-step5-is-not-forced-neutral",
        # Sanity: the guard is OS-gated, not just arch-gated.
        "PASS windows-is-not-flagged-unsupported-by-the-macos-guard-even-with-x86_64-arch",
        "PASS windows-existing-runtime-ui-keeps-read-only-policy",
        "PASS windows-existing-runtime-ui-keeps-uniform-nonoverlapping-grid",
        "PASS windows-modes-complete-260%",
        "PASS windows-modes-complete-300%",
    ):
        assert marker in result.stdout, f"missing expected marker: {marker}\n{result.stdout}"


def test_isIntelMacDksUnsupported_is_the_single_definition_reused_everywhere() -> None:
    """Guards against a second, independent "Intel Mac unsupported" check ever
    being re-derived instead of reusing isIntelMacDksUnsupported()."""
    text = SETUP_INTERNAL.read_text(encoding="utf-8")
    assert "function isIntelMacDksUnsupported()" in text
    assert text.count("isIntelMacDksUnsupported()") >= 4, (
        "expected the shared helper to be called from resolveDrumsepPolicyState, "
        "buildSetupMenuChoices, drawLinuxStepLegend, and startLinuxSetup's guard"
    )


def test_direct_dispatch_guard_reuses_the_existing_localized_keys() -> None:
    """The i18n correction: no new keys, no raw custom English string, and
    the same (title, text, type) msgBox argument order already proven from
    every other call site in this file."""
    text = SETUP_INTERNAL.read_text(encoding="utf-8")
    guard = text[text.index('mode == "drumsep-runtime" or mode == "drumsep-rocm-runtime") and isIntelMacDksUnsupported()') :]
    guard = guard[: guard.index("local isDrumsepRuntime")]
    assert 'setupText("drumsep_intel_mac_unsupported_title", "Drum Kit Split unavailable on Intel Mac")' in guard
    assert 'setupText(' in guard and "drumsep_intel_mac_unsupported_body" in guard
    assert "msgBox(title, body, 0)" in guard
    assert '"STEMwerk Setup"' not in guard, (
        "msgBox must no longer be called with a hardcoded literal title in this guard"
    )
    assert guard.count("setupText(") >= 2, "expected at least one setupText() call for the title and one for the body"


def test_check_only_diagnostic_wording_is_unchanged() -> None:
    """Important distinction: this slice must not remove the diagnostic
    knowledge that DKS is unsupported on Intel macOS -- only the implication
    that it can be installed/repaired/selected/used there."""
    text = SETUP_INTERNAL.read_text(encoding="utf-8")
    assert 'drumsepStatus = "unsupported_mac_intel"' in text
    assert 'dksSupported = drumsepStatus == "unsupported_mac_intel" and "false" or "true"' in text


def test_polished_card_grid_uses_identical_draw_and_hit_test_geometry() -> None:
    """The centered grid origin is presentation-only: clicks must resolve
    against the exact same card rectangles that are drawn."""
    text = SETUP_INTERNAL.read_text(encoding="utf-8")
    body = text[text.index("function existingRuntimeSetupMenuTick()") :]
    body = body[: body.index("\nend")]
    bx_line = "local bx = layout.gridX + col * (layout.btnW + btnGapX)"
    assert body.count(bx_line) == 2, "draw and click routes must share the centered grid origin"
    assert "local bx = bodyX + col * (layout.btnW + btnGapX)" not in body

    # Action dispatch remains byte-identical in meaning after the geometry
    # slice: the selected IDs still reach the same existing callbacks.
    assert 'if chosen == "verify" then' in body
    assert "verifyExistingSetup(runtime, separatorScript)" in body
    assert 'elseif chosen == "repair" or chosen == "rebuild-venv"' in body
    assert "startLinuxSetup(runtime, separatorScript, chosen)" in body
    assert 'elseif chosen == "support-bundle" then' in body
    assert "runSupportBundleAction()" in body
    assert 'elseif chosen == "cancel" then' in body


def test_polished_card_content_reserves_shared_title_and_subtitle_blocks() -> None:
    """All cards reserve the same title/subtitle blocks, so one wrapped
    translation cannot move another card's title or subtitle baseline."""
    text = SETUP_INTERNAL.read_text(encoding="utf-8")
    body = text[text.index("function existingRuntimeSetupMenuTick()") :]
    body = body[: body.index("\nend")]
    assert "local titleByChoice = {}" in body
    assert "local titleMaxLines = 1" in body
    assert "local labelBlockH = titleMaxLines * labelH" in body
    assert "local subtitleBlock = withSubs and (subMaxLines * subH) or 0" in body
    assert "local subY = contentY + layout.labelBlockH + layout.innerGap" in body
    assert "if bodyW < 700 then cols = 2 end" in body
    assert "or scale >= 2.8" not in body
