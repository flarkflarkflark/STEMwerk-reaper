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
        "PASS apple-silicon-is-not-flagged-unsupported",
        "PASS apple-silicon-setup-actions-still-offer-drumsep-runtime",
        "PASS apple-silicon-step5-label-is-the-original-unchanged-label",
        "PASS apple-silicon-step5-is-not-forced-neutral",
        "PASS apple-silicon-direct-dispatch-is-not-blocked-by-the-intel-guard",
        "PASS apple-silicon-direct-dispatch-writes-the-drumsep-state-file",
        # 6) Linux x86_64: unaffected.
        "PASS linux-x86_64-is-not-flagged-unsupported-by-the-macos-guard",
        "PASS linux-x86_64-setup-actions-still-offer-drumsep-runtime",
        "PASS linux-x86_64-step5-label-is-the-original-unchanged-label",
        "PASS linux-x86_64-step5-is-not-forced-neutral",
        # Sanity: the guard is OS-gated, not just arch-gated.
        "PASS windows-is-not-flagged-unsupported-by-the-macos-guard-even-with-x86_64-arch",
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
