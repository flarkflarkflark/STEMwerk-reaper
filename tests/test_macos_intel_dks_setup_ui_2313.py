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
  - presented step 5 of the progress/final legend as an active, warning-amber
    "Drum Kit runtime" phase on Intel macOS, even though that step actually
    re-verifies the shared main runtime on every platform, not a separate
    DrumSep install;
  - had no defense-in-depth guard if "drumsep-runtime"/"drumsep-rocm-runtime"
    setup dispatch was somehow invoked directly on Intel macOS.

The fix adds one small, reused policy source, isIntelMacDksUnsupported(), to
STEMwerk_Setup_Internal.lua (mirroring the main GUI's check, which this
separate script cannot call directly) and applies it at the three UI/dispatch
surfaces above. Check-only/Repair diagnostic reporting already correctly said
"unsupported on Intel macOS" via resolveDrumsepPolicyState/DKS_SUPPORTED (now
consolidated to call the same new helper) and is unchanged by this slice.

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
        # 3) Intel macOS Setup/Repair/Check presentation: no active phase.
        "PASS intel-macos-step5-label-says-unsupported",
        "PASS intel-macos-step5-label-still-mentions-drum-kit-for-context",
        "PASS intel-macos-step5-color-is-neutral-grey-not-the-warning-amber",
        "PASS intel-macos-step5-is-forced-out-of-active-completed-palette",
        "PASS intel-macos-steps-1-through-4-are-unaffected",
        # 4) Direct Drum Kit setup dispatch on Intel macOS: clean, no mutation.
        "PASS intel-macos-direct-dispatch-writes-no-state-file",
        "PASS intel-macos-direct-dispatch-shows-a-message",
        "PASS intel-macos-direct-dispatch-message-says-unsupported-not-an-error",
        "PASS intel-macos-direct-dispatch-also-blocks-drumsep-rocm-runtime",
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


def test_check_only_diagnostic_wording_is_unchanged() -> None:
    """Important distinction: this slice must not remove the diagnostic
    knowledge that DKS is unsupported on Intel macOS -- only the implication
    that it can be installed/repaired/selected/used there."""
    text = SETUP_INTERNAL.read_text(encoding="utf-8")
    assert 'drumsepStatus = "unsupported_mac_intel"' in text
    assert 'dksSupported = drumsepStatus == "unsupported_mac_intel" and "false" or "true"' in text
