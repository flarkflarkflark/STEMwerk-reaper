"""Regression coverage for the 2.3.1.1 pre-release Setup UX / installer-policy
cleanup:

  1) Windows online/thin installer: no model-purge task (covered in
     tests/test_windows_upgrade_cleanup_2306.py).
  2) Windows in-REAPER Setup: only the five read-only actions; a fail-closed
     guard if a mutating action is ever still reached; the two notice lines
     no longer reference removed Windows actions.
  3) Linux: Drum Kit Split labels reflect actually-detected capability.
  4) Linux: single, non-alarmist update notice; console autoscroll follows
     the tail / respects manual scroll-up / snaps to the end on completion.
  5) Linux AppImage version hygiene (covered in
     tests/test_linux_native_package_integration_2310.py).

Real production logic execution: tests/support/run_setup_ui_policy_2311_headless.lua
dofile()s the actual STEMwerk_Setup_Internal.lua and exercises the real
choices-list/label functions -- not a reimplementation, not a screenshot.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SETUP_INTERNAL = ROOT / "scripts" / "reaper" / "_internal" / "STEMwerk_Setup_Internal.lua"


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


@pytest.mark.skipif(shutil.which("lua") is None, reason="Lua interpreter required for deferred-window coverage")
def test_check_scroll_matches_macos_baseline_and_keeps_platform_contracts() -> None:
    lua = shutil.which("lua") or "lua"
    harness = ROOT / "tests" / "support" / "run_setup_check_scroll_route_headless.lua"
    baseline = subprocess.run(
        ["git", "show", "HEAD:scripts/reaper/_internal/STEMwerk_Setup_Internal.lua"],
        cwd=ROOT,
        capture_output=True,
        check=True,
    ).stdout

    def run(snapshot: str, os_value: str) -> str:
        result = subprocess.run(
            [lua, str(harness), snapshot, os_value],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        return result.stdout.strip().splitlines()[-1]

    with tempfile.NamedTemporaryFile("wb", suffix=".lua", delete=False) as f:
        f.write(baseline)
        baseline_path = f.name
    try:
        baseline_macos = run(baseline_path, "OSX64")
        current_macos = run("", "OSX64")
        current_linux = run("", "Other")
        current_windows = run("", "Win64")
    finally:
        Path(baseline_path).unlink(missing_ok=True)

    assert baseline_macos == "oldest=true|newest=false|current=false"
    assert current_macos == baseline_macos
    assert current_linux == "oldest=false|newest=true|current=true"
    assert current_windows == "oldest=false|newest=true|current=false"


@pytest.mark.skipif(shutil.which("lua") is None, reason="Lua interpreter required for headless Setup UI coverage")
def test_windows_and_linux_and_macos_setup_menu_policy_headless() -> None:
    result = subprocess.run(
        [shutil.which("lua") or "lua", "tests/support/run_setup_ui_policy_2311_headless.lua"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, f"headless Setup UI policy harness failed:\n{result.stdout}\n{result.stderr}"
    for marker in (
        "PASS windows-choices-are-exactly-the-allowed-five",
        "PASS windows-fail-closed-guard-refuses-every-mutating-mode-and-touches-nothing",
        "PASS windows-fail-closed-guard-does-not-block-the-five-allowed-actions",
        "PASS linux-and-macos-dispatch-not-blocked-by-windows-guard",
        "PASS linux-rocm-machine-shows-cpu-plus-rocm",
        "PASS linux-cuda-machine-shows-cuda-only-no-rocm",
        "PASS linux-cpu-only-machine-shows-cpu-only",
        "PASS linux-no-current-probe-with-old-rocm-files-is-neutral",
        "PASS linux-current-probe-failed-is-neutral",
        "PASS linux-current-probe-conflicts-with-persisted-state-is-neutral",
        "PASS linux-current-probe-consistent-with-persisted-state-dispatches-correctly",
        "PASS linux-torch-hip-false-never-claims-rocm",
        "PASS linux-torch-hip-zero-never-claims-rocm",
        "PASS linux-corrupt-version-never-claims-rocm",
        "PASS linux-partial-state-is-neutral",
        "PASS linux-foreign-profile-is-neutral",
        "PASS linux-correct-neutral-fallback-dispatches-to-no-gpu-choice",
        "PASS linux-uncertain-capability-uses-neutral-fallback",
        "PASS macos-choices-and-labels-are-unchanged",
        "ALL PASS run_setup_ui_policy_2311_headless",
    ):
        assert marker in result.stdout, f"missing expected marker {marker!r} in:\n{result.stdout}"


@pytest.mark.skipif(shutil.which("lua") is None, reason="Lua interpreter required for runtime policy coverage")
def test_runtime_setup_platform_policy_has_no_windows_mutating_route() -> None:
    result = subprocess.run(
        [shutil.which("lua") or "lua", "tests/support/run_runtime_setup_platform_policy_headless.lua"],
        cwd=ROOT,
        env={**os.environ, "LOCALAPPDATA": "/virtual/stemwerk-localappdata"},
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    for marker in (
        "PASS windows-dependency-failure",
        "PASS windows-python-missing",
        "PASS windows-bootstrap-failure",
        "PASS windows-torch-torchaudio-onnx-failure",
        "PASS windows-interactive-confirmation-never-starts-setup",
        "PASS windows-diagnosis-without-runtime-root-stays-read-only",
        "PASS windows-direct-runsetup-fails-closed",
        "PASS windows-runtime-resolution-without-root-stays-read-only",
        "PASS linux-interactive-setup-route-preserved",
        "PASS macos-interactive-setup-route-preserved",
        "PASS unknown-platform-does-not-default-to-windows-or-unix-setup",
        "ALL PASS runtime-setup-platform-policy",
    ):
        assert marker in result.stdout


def test_windows_mutating_dispatch_fails_closed_and_points_to_the_installer() -> None:
    text = _read(SETUP_INTERNAL)
    guard_start = text.index('function startWindowsSetup(runtime, separatorScript, mode, reuseWindow)')
    # The guard must be the first thing the function does -- before any
    # ensureDir/guard-file/process-launch side effect.
    guard_region = text[guard_start:guard_start + 1400]
    assert 'if OS == "Windows" then' in guard_region
    assert "Nothing was changed." in guard_region
    assert "STEMwerk installer" in guard_region
    assert "return false" in guard_region
    first_ensure_dir = guard_region.find("ensureDir(runtime.runtimeState)")
    guard_if = guard_region.find('if OS == "Windows" then')
    guard_return = guard_region.find("return false")
    assert guard_if < guard_return, "the guard must return before the function continues"
    assert first_ensure_dir == -1 or guard_return < first_ensure_dir, (
        "the fail-closed guard must return before any mutation (ensureDir/guard file/process launch)"
    )


def test_windows_choices_dispatch_chokepoint_only_reaches_startwindowssetup_via_menu() -> None:
    text = _read(SETUP_INTERNAL)
    # startWindowsSetup must have exactly one *call* site (its own def line
    # excluded): the dispatch inside existingRuntimeSetupMenuTick, itself
    # only reachable for ids that buildSetupMenuChoices puts in `choices` --
    # which no longer includes any mutating id on Windows (proven by the
    # headless test above).
    call_sites = [
        idx for idx in range(len(text))
        if text.startswith("startWindowsSetup(", idx) and text[max(0, idx - 9):idx] != "function "
    ]
    assert len(call_sites) == 1, f"expected exactly one call site for startWindowsSetup, found {len(call_sites)}"


def test_windows_notices_no_longer_reference_removed_actions() -> None:
    text = _read(SETUP_INTERNAL)
    for key in ("setup_models_kept_notice", "setup_destructive_actions_notice"):
        idx = text.index(f'setupText("{key}"')
        context = text[max(0, idx - 250):idx]
        assert 'not compact and OS ~= "Windows"' in context, (
            f"{key} notice must be gated off on Windows now that Repair/Rebuild venv/"
            "Delete models/Delete runtime no longer exist there"
        )


def test_check_only_and_support_bundle_remain_reachable_and_unmutated() -> None:
    text = _read(SETUP_INTERNAL)
    assert "-- Check only verifies current truth; it never persists it." in text
    assert 'if chosen == "verify" then' in text
    assert "windowsVerifyStart(runtime, separatorScript, true)" in text
    assert 'elseif chosen == "support-bundle" then' in text
    assert "runSupportBundleAction()" in text


def test_single_non_duplicate_update_notice_with_no_unconditional_repair_claim() -> None:
    text = _read(SETUP_INTERNAL)
    assert "setup_update_detected_repair_recommended" not in text, (
        "the old duplicate 'Repair recommended' notice key must be fully removed, not just unused"
    )
    assert "Repair recommended" not in text
    assert 'setupText("setup_update_detected_choose_action"' in text
    idx = text.index('setupText("setup_update_detected_choose_action"')
    assert "run Check only first" in text[idx:idx + 200] or "Check only" in text[idx:idx + 200]


def test_i18n_no_longer_defines_the_removed_repair_recommended_key() -> None:
    for i18n_path in (ROOT / "i18n" / "languages.lua", ROOT / "scripts" / "reaper" / "i18n" / "languages.lua"):
        text = _read(i18n_path)
        assert "setup_update_detected_repair_recommended" not in text
        assert len(re.findall(r"setup_update_detected_choose_action\s*=", text)) == 3, (
            f"expected exactly 3 (EN/NL/DE) setup_update_detected_choose_action entries in {i18n_path}"
        )
        assert len(re.findall(r"setup_update_detected_choose_action_windows\s*=", text)) == 3, (
            f"expected exactly 3 (EN/NL/DE) setup_update_detected_choose_action_windows entries in {i18n_path}"
        )


def test_i18n_copies_of_new_drumsep_capability_keys_stay_in_sync() -> None:
    root_text = _read(ROOT / "i18n" / "languages.lua")
    scripts_text = _read(ROOT / "scripts" / "reaper" / "i18n" / "languages.lua")
    assert root_text == scripts_text, "i18n/languages.lua and scripts/reaper/i18n/languages.lua must stay byte-identical"
    for key in (
        "setup_choice_drumsep_runtime_cpu_label",
        "setup_choice_drumsep_runtime_cuda_label",
        "setup_summary_drumkit_generic",
    ):
        assert root_text.count(key) == 3, f"expected 3 (EN/NL/DE) occurrences of {key}"


def test_i18n_current_check_result_keys_exist_in_en_nl_de_and_stay_in_sync() -> None:
    # Second review round, Finding 5: the in-memory "Current Check result"
    # section's banner/title/status labels must exist in all three shipped
    # languages, not just as an English fallback.
    root_text = _read(ROOT / "i18n" / "languages.lua")
    scripts_text = _read(ROOT / "scripts" / "reaper" / "i18n" / "languages.lua")
    assert root_text == scripts_text, "i18n/languages.lua and scripts/reaper/i18n/languages.lua must stay byte-identical"
    for key in (
        "current_check_result_title",
        "current_check_status_label",
        "current_check_status_ok",
        "current_check_status_not_proven",
        "current_check_status_failed",
        "current_check_profile_label",
        "current_check_backend_label",
        "current_check_reason_label",
    ):
        assert len(re.findall(re.escape(key) + r"\s*=", root_text)) == 3, f"expected 3 (EN/NL/DE) occurrences of {key}"
    assert '"--- Resultaat huidige Check ---"' in root_text, "Dutch section title must be the actual translated text, not a copy of the English fallback"
    assert '"--- Ergebnis der aktuellen Check ---"' in root_text, "German section title must be the actual translated text, not a copy of the English fallback"
    assert '"NIET BEWEZEN"' in root_text and '"NICHT NACHGEWIESEN"' in root_text, "the not-proven status label must be translated in NL/DE"
    assert '"MISLUKT"' in root_text and '"FEHLGESCHLAGEN"' in root_text, "the failed status label must be translated in NL/DE"


@pytest.mark.skipif(shutil.which("lua") is None, reason="Lua interpreter required for headless render coverage")
def test_current_check_result_render_headless() -> None:
    # Second review round, Finding 5: executable RENDER proof (not a pure
    # decision function alone) that the real production rendering pipeline
    # -- showDeferredFinalWindow -> linuxSetupTick -> linuxDrawFinal ->
    # drawLinuxLogPanel -- actually draws the historical banner above the
    # scrollable console, the Current Check result section below the
    # historical content and visible in the initial (bottom) viewport, never
    # abusively removes marker-looking ordinary content, is unambiguous for
    # both success and failure, and never appears on macOS/Windows.
    result = subprocess.run(
        [shutil.which("lua") or "lua", "tests/support/run_current_check_result_render_headless.lua"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, f"headless Current Check result render harness failed:\n{result.stdout}\n{result.stderr}"
    for marker in (
        "PASS banner-drawn-above-content-and-current-section-visible-at-bottom",
        "PASS short-and-long-logs-both-show-current-section-initially",
        "PASS marker-count-variations-never-abusively-remove-ordinary-content",
        "PASS successful-and-failed-checks-are-unambiguous",
        "PASS missing-optional-fields-are-omitted-not-filled-in",
        "PASS macos-and-windows-never-get-the-linux-presentation",
        "All headless Current Check result render tests passed.",
    ):
        assert marker in result.stdout, f"missing expected marker {marker!r} in:\n{result.stdout}"


def test_console_autoscroll_follows_tail_and_respects_manual_scroll() -> None:
    # 2.3.1.1 Finding 5: every manual scroll-position mutation (wheel,
    # scrollbar drag, keyboard) now routes through one shared pair of global
    # helpers (setLinuxLogScrollManual / adjustLinuxLogScroll) so followTail
    # can never drift out of sync with a site that moves the scroll position
    # by hand. The actual state-machine behavior (not just this source
    # shape) is proven executably by
    # tests/support/run_setup_linux_not_proven_headless.lua's
    # fixture-h-keyboard-scroll-updates-follow-tail-like-wheel-scrollbar --
    # a source-text assertion alone is not sufficient proof of behavior, so
    # this test only pins the structural contract that every input site
    # dispatches through the shared helpers instead of mutating
    # logScroll/followTail on its own.
    text = _read(SETUP_INTERNAL)
    assert "followTail = true" in text
    assert "pendingFinalScrollReset" in text
    assert "function setLinuxLogScrollManual(newScroll, totalLines, visibleLines, target)" in text
    assert "function adjustLinuxLogScroll(delta, totalLines, visibleLines, target)" in text
    assert "target.followTail = target.logScroll <= 2" in text, (
        "the shared helper itself, not any individual input handler, must be the one place that sets followTail"
    )
    # Running phase: only force back to the bottom when the user hasn't
    # scrolled away. 2.3.1.1 Finding 6: gated to Linux only -- see
    # test_finding6_completion_follow_is_linux_only below.
    running_guard_idx = text.index("if linuxConsoleAutoscrollAppliesOnThisOS() and LINUX_SETUP.followTail then")
    assert "LINUX_SETUP.logScroll = 0" in text[running_guard_idx:running_guard_idx + 120]
    # Every scroll INPUT site (wheel, both scrollbar-drag phases, arrow keys,
    # Page Up/Down, Home, End) must dispatch through one of the two shared
    # helpers -- never assign LINUX_SETUP.logScroll/.followTail directly.
    assert text.count("adjustLinuxLogScroll(") >= 5, (
        "wheel, Up, Down, Page Up, and Page Down must all call the shared adjustLinuxLogScroll helper"
    )
    assert text.count("setLinuxLogScrollManual(") >= 5, (
        "both scrollbar-drag phases, Home, End, and the completion transition's helper definition must all involve the shared setLinuxLogScrollManual helper"
    )
    tick_start = text.index("function linuxSetupTick()")
    tick_end = text.index("\ndo\n", tick_start)
    tick_body = text[tick_start:tick_end]
    assert "LINUX_SETUP.followTail = (LINUX_SETUP.logScroll or 0) <= 2" not in tick_body, (
        "no input handler inside linuxSetupTick may set followTail directly anymore -- only the shared helper may"
    )
    for key_name, key_code in (("Home", "1752132965"), ("End", "6647396"), ("Page Up", "1885828464"), ("Page Down", "1885824110")):
        assert f"key == {key_code}" in tick_body, f"{key_name} keyboard scroll handler (key {key_code}) must be present"
    # Completion transition: the reset is deferred to the next tick, applied
    # unconditionally (not gated on followTail) so it always wins at the end.
    # 2.3.1.1 Finding 6: gated to Linux only -- see
    # test_finding6_completion_follow_is_linux_only below.
    consume_idx = text.index("if linuxConsoleAutoscrollAppliesOnThisOS() and LINUX_SETUP.pendingFinalScrollReset then")
    consume_region = text[consume_idx:consume_idx + 200]
    assert "LINUX_SETUP.logScroll = 0" in consume_region
    assert "LINUX_SETUP.followTail = true" in consume_region
    assert text.count("LINUX_SETUP.pendingFinalScrollReset = true") == 2, (
        "both finalized=true transition sites must arm the deferred scroll reset"
    )


def test_autoscroll_code_is_shared_with_macos_not_windows_specific() -> None:
    # linuxSetupTick / LINUX_SETUP is used for both Linux and macOS
    # (startLinuxSetup has no OS gate), and never for Windows (which uses the
    # entirely separate WINDOWS_SETUP / windowsSetupTick).
    #
    # 2.3.1.1 Finding 6 (adversarial review) INVERTED this test's original
    # premise: the completion-follow/autoscroll behavior turned out to be a
    # genuinely new 2.3.1.1 feature with no macOS counterpart before this
    # release, so sharing it unconditionally with macOS was itself the bug --
    # it must now be gated to Linux only via linuxConsoleAutoscrollAppliesOnThisOS()
    # (a single pure, headlessly-testable predicate both gate sites call, so
    # there is exactly one place that decides this, not two independently
    # maintained OS checks). See test_finding6_completion_follow_is_linux_only
    # for the executable proof that this predicate actually returns
    # False on macOS and True on Linux.
    text = _read(SETUP_INTERNAL)
    assert "function linuxConsoleAutoscrollAppliesOnThisOS()" in text
    assert "return OS ==" in text
    tick_start = text.index("function linuxSetupTick()")
    tick_end = text.index("\ndo\n", tick_start)
    tick_body = text[tick_start:tick_end]
    assert 'OS == "Windows"' not in tick_body, "this shared code must never branch on Windows -- Windows never reaches it"
    assert tick_body.count("linuxConsoleAutoscrollAppliesOnThisOS()") == 2, (
        "exactly the two completion-follow/autoscroll gate sites (running-phase pull-to-bottom, "
        "deferred completion reset) must dispatch through the shared predicate"
    )
    assert 'OS == "macOS"' not in tick_body.replace(
        'if OS == "macOS" then\n            tryExec(LINUX_SETUP.launchCmd)', ""
    ), (
        "no OTHER OS-specific branch may exist in linuxSetupTick beyond the pre-existing launch-exec "
        "branch (excluded above) and the two calls to the shared autoscroll predicate"
    )


def test_finding6_completion_follow_is_linux_only() -> None:
    # Executable proof (not just source text) that the real production
    # predicate governing both autoscroll gate sites actually returns True
    # on Linux and False on macOS -- a negative regression test proving the
    # new Linux follow-transition is not applied on macOS, per Finding 6.
    harness = ROOT / "tests" / "support" / "run_setup_ui_policy_2311_headless.lua"
    assert "linuxConsoleAutoscrollAppliesOnThisOS" not in _read(harness), (
        "sanity: this Lua expression is meant to be checked inline below, not duplicated into the shared harness file"
    )
    script = f"""
STEMWERK_SETUP_HEADLESS_TEST = true
reaper = {{
    ShowMessageBox = function() return 0 end,
    GetOS = function() return GETOS_VALUE end,
    GetExtState = function() return "" end,
    SetExtState = function() end,
    HasExtState = function() return false end,
    DeleteExtState = function() end,
    ShowConsoleMsg = function() end,
    defer = function() end,
    GetResourcePath = function() return "/tmp" end,
    get_action_context = function() return "", "" end,
}}
assert(loadfile("{SETUP_INTERNAL}"))()
print(tostring(linuxConsoleAutoscrollAppliesOnThisOS()))
"""
    lua = shutil.which("lua5.4") or shutil.which("lua5.3") or shutil.which("lua") or shutil.which("luajit")
    if lua is None:
        pytest.skip("no lua interpreter available on this host")

    for os_value, expected in (('"Other"', "true"), ('"OSX64"', "false"), ('"Win64"', "false")):
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
            f.write(script.replace("GETOS_VALUE", os_value))
            path = f.name
        try:
            result = subprocess.run([lua, path], text=True, capture_output=True)
            assert result.returncode == 0, result.stdout + result.stderr
            actual = result.stdout.strip()
            assert actual == expected, (
                f"linuxConsoleAutoscrollAppliesOnThisOS() with reaper.GetOS()={os_value} "
                f"must return {expected}, got {actual!r} (stderr: {result.stderr})"
            )
        finally:
            Path(path).unlink(missing_ok=True)


# ===========================================================================
# Second independent adversarial review, Finding 1: exhaustive sweep for
# stale Windows recovery copy that still instructed choosing Repair/Rebuild
# venv/a Drum Kit runtime install inside REAPER, even though Windows Setup
# has offered none of those since the first review round. Each assertion
# below is scoped to the specific user-visible function/section it belongs
# to (never a blanket repository-wide absence check), and checks the actual
# shipped text, not just an internal key name.
# ===========================================================================

INSTALLER_ISS = ROOT / "installer" / "windows" / "STEMwerk.iss"
WINDOWS_GUIDE_EN = ROOT / "installer" / "windows" / "STEMwerk_Windows_Setup_Guide.md"
WINDOWS_GUIDE_NL = ROOT / "installer" / "windows" / "STEMwerk_Windows_Setup_Guide.nl.md"
WINDOWS_GUIDE_DE = ROOT / "installer" / "windows" / "STEMwerk_Windows_Setup_Guide.de.md"
STEMWERK_LUA = ROOT / "scripts" / "reaper" / "STEMwerk.lua"
SUPPORT_BUNDLE_LUA = ROOT / "scripts" / "reaper" / "STEMwerk_Save_Support_Bundle.lua"


def test_installer_finished_page_no_longer_offers_check_or_repair_in_reaper() -> None:
    text = _read(INSTALLER_ISS)
    assert "check or repair the runtime" not in text, (
        "the installer finished-page must no longer tell the user STEMwerk: Setup can repair the runtime"
    )
    idx = text.index("function BuildFinishedSummaryText")
    end = text.index("\nfunction FindLastPos", idx)
    section = text[idx:end]
    assert "LText('- Use STEMwerk: Setup to check the runtime (Check only). " in section
    assert "re-run this STEMwerk installer to repair it." in section, "EN finished-page text must point to the external installer for repair"
    assert "voer deze STEMwerk-installer opnieuw uit om te herstellen." in section, "NL finished-page text must point to the external installer for repair"
    assert "fuehre diesen STEMwerk-Installer erneut aus, um sie zu reparieren." in section, "DE finished-page text must point to the external installer for repair"


def test_windows_guide_still_correctly_points_repair_at_the_installer() -> None:
    # Regression guard on top of the first review round's fix: re-affirm the
    # shipped guide text (not just the internal contract) across all three
    # languages, scoped to the "Setup and repair" section.
    for path, heading, must_contain in (
        (WINDOWS_GUIDE_EN, "## Setup and repair", "not by `STEMwerk: Setup` inside REAPER"),
        (WINDOWS_GUIDE_NL, "## Setup en herstel", "niet door `STEMwerk: Setup` binnen REAPER"),
        (WINDOWS_GUIDE_DE, "## Setup und Reparatur", "nicht von `STEMwerk: Setup` innerhalb von REAPER"),
    ):
        text = _read(path)
        idx = text.index(heading)
        section = text[idx:idx + 700]
        assert must_contain in section, f"{path.name}: Setup/repair section must state install/repair is owned by the installer"
        assert "Repair" not in section.replace("not by `STEMwerk: Setup`", "").replace("Repair recommended", ""), (
            f"{path.name}: the Setup/repair section must not instruct choosing a Repair action inside REAPER"
        )


def test_stemwerk_lua_windows_product_copy_points_to_the_installer_not_reaper_actions() -> None:
    text = _read(STEMWERK_LUA)

    # 1) Drum Kit Split runtime-missing/broken guidance.
    idx = text.index('local runtimeGuidance = "Run Setup/Repair Drum Kit Split runtime.\\n"')
    section = text[idx:idx + 500]
    assert 'elseif OS == "Windows" then' in section
    assert 'runtimeGuidance = "Re-run the STEMwerk installer to repair the Drum Kit Split runtime.\\n"' in section

    # 2) Required-model-missing block message.
    idx = text.index("B0_MODEL_BLOCK_MESSAGE")
    section = text[idx:idx + 400]
    assert '(OS == "Windows")' in section
    assert "Re-run the STEMwerk installer to install the required models before processing." in section
    assert "Open STEMwerk Setup and run Repair to install the required models before processing." in section, (
        "the non-Windows text (Linux/macOS, where Repair genuinely exists) must be preserved unchanged"
    )

    # 3) Python-not-found preflight message.
    idx = text.index('"Python not found at: "')
    section = text[idx:idx + 300]
    assert '(OS == "Windows")' in section
    assert "Re-run the STEMwerk installer to repair the runtime." in section
    assert "Run STEMwerk-SETUP.lua to repair the runtime." in section, (
        "the non-Windows text (Linux/macOS, where STEMwerk-SETUP.lua genuinely offers repair) must be preserved unchanged"
    )

    # 4) Missing-onnxruntime friendly-hint message.
    idx = text.index("Friendly hint for the most common missing dependency")
    section = text[idx:idx + 900]
    assert '(OS == "Windows")' in section
    assert "Then run STEMwerk: Setup in REAPER and click Check only to verify the runtime. If problems remain, re-run the STEMwerk installer to repair it." in section
    assert "Then rerun STEMwerk-SETUP.lua in REAPER to repair the runtime." in section, (
        "the non-Windows text must be preserved unchanged"
    )


def test_support_bundle_error_hint_points_windows_at_the_installer() -> None:
    text = _read(SUPPORT_BUNDLE_LUA)
    idx = text.index('kvAssignLast(entry, "error_hint", (OS == "Windows")')
    section = text[idx:idx + 350]
    assert "re-run the STEMwerk installer before retrying." in section
    assert "run Setup/Repair before retrying." in section, "the non-Windows hint text must be preserved unchanged"


def test_performpostbootstrap_literal_messages_route_through_windows_safe_reason_text() -> None:
    # Second review round found these three hardcoded finalMessage literals
    # inside performPostBootstrap (a function already confirmed
    # Windows-reachable via safePerformPostBootstrap/WINDOWS_SETUP) bypassed
    # windowsSafeReasonText entirely -- unlike the prettySetupReason()/
    # formatCheckErrors() calls in the same function that the first review
    # round already wrapped.
    text = _read(SETUP_INTERNAL)
    fn_start = text.index("local function performPostBootstrap(")
    fn_end = text.index("\nsafePerformPostBootstrap = function", fn_start)
    body = text[fn_start:fn_end]

    for var_name, needle in (
        ("pythonUnsupportedText", "managed Python runtime for Repair/Rebuild."),
        ("torchTooNewText", "Run Repair/Rebuild to restore the supported runtime."),
        ("torchaudioMissingText", "torchaudio is missing. Run Repair/Rebuild to restore the supported runtime."),
    ):
        assert needle in body, f"expected literal text containing {needle!r} in performPostBootstrap"
        guard = f'if OS == "Windows" then {var_name} = windowsSafeReasonText({var_name}) end'
        assert guard in body, f"{var_name} must be routed through windowsSafeReasonText before being appended to finalMessage"

    # windowsSafeReasonText's own replacement table (defined once, reused by
    # every call site) already knows how to rewrite both exact phrases used
    # above -- confirms this fix does not silently no-op on Windows.
    ws_start = text.index("function windowsSafeReasonText(text)")
    ws_end = text.index("\nend", text.index("return text", ws_start))
    ws_body = text[ws_start:ws_end]
    assert '"Run Repair/Rebuild to restore the supported runtime.", "Re-run the STEMwerk installer to restore the supported runtime."' in ws_body
    assert '"for Repair/Rebuild.", "for the next STEMwerk installer run."' in ws_body


def test_windows_reachable_repair_button_text_stays_confined_to_linux_macos_only_code() -> None:
    # Defense-in-depth, narrowly scoped: the literal "Repair"/"Rebuild venv"
    # action-button labels must remain only inside linuxDrawFinal (confirmed
    # Linux/macOS-only, never called by WINDOWS_SETUP/windowsSetupTick) and
    # buildCheckOnlyFinalMessage (reachable only via verifyExistingSetup,
    # which existingRuntimeSetupMenuTick's own dispatch never calls for
    # Windows -- windowsVerifyStart is used there instead).
    text = _read(SETUP_INTERNAL)
    assert 'existingRuntimeSetupMenuTick' in text
    dispatch_idx = text.index('if chosen == "verify" then')
    dispatch_region = text[dispatch_idx:dispatch_idx + 250]
    assert 'if OS == "Windows" then\n                windowsVerifyStart(runtime, separatorScript, true)' in dispatch_region
    assert "verifyExistingSetup(runtime, separatorScript)" in dispatch_region


def test_finding4_historical_banner_is_linux_only() -> None:
    # Second review round, Finding 4: the historical-provenance marker/banner
    # (Finding 3) is genuinely new 2.3.1.1 UI with no macOS counterpart
    # before this release -- linuxSetupTick/LINUX_SETUP is shared with
    # macOS, so it must be gated to Linux only, exactly like
    # linuxConsoleAutoscrollAppliesOnThisOS gates the completion-follow
    # feature. This exercises the real production predicate AND the real
    # labelHistoricalCheckOnlyLogLines contract together, end to end -- not
    # a source-text assertion alone.
    text = _read(SETUP_INTERNAL)
    assert "function linuxHistoricalBannerAppliesOnThisOS()" in text
    guard_idx = text.index("local isLinuxCheckOnly = linuxHistoricalBannerAppliesOnThisOS() and LINUX_SETUP.checkVerdict ~= nil")
    call_site = text[guard_idx:guard_idx + 250]
    assert "labelHistoricalCheckOnlyLogLines(readTail(LINUX_SETUP.logFile, 400), isLinuxCheckOnly)" in call_site, (
        "linuxSetupTick must gate the historical marker through the shared OS predicate, not compute OS ==\"Linux\" inline"
    )
    assert "if isLinuxCheckOnly then" in call_site, (
        "the Current Check result section (Finding 5) must be gated by the same isLinuxCheckOnly flag as the historical marker"
    )

    script = f"""
STEMWERK_SETUP_HEADLESS_TEST = true
reaper = {{
    ShowMessageBox = function() return 0 end,
    GetOS = function() return GETOS_VALUE end,
    GetExtState = function() return "" end,
    SetExtState = function() end,
    HasExtState = function() return false end,
    DeleteExtState = function() end,
    ShowConsoleMsg = function() end,
    defer = function() end,
    GetResourcePath = function() return "/tmp" end,
    get_action_context = function() return "", "" end,
}}
assert(loadfile("{SETUP_INTERNAL}"))()
local applies = linuxHistoricalBannerAppliesOnThisOS()
-- Mirrors linuxSetupTick's exact call-site expression end to end: a
-- Check-only window (checkVerdict ~= nil, modeled here as a truthy table)
-- on this OS, run through the real, already-tested
-- labelHistoricalCheckOnlyLogLines contract.
local rawLines = {{ "Mode: repair", "Successfully installed pip-26.2.1" }}
local checkVerdict = {{ isCheckOnly = true }}
local labelled = labelHistoricalCheckOnlyLogLines(rawLines, applies and checkVerdict ~= nil)
local hasMarker = labelled[1] == historicalCheckOnlyLogMarkerText()
print(tostring(applies) .. "|" .. tostring(hasMarker) .. "|" .. tostring(#labelled))
"""
    lua = shutil.which("lua5.4") or shutil.which("lua5.3") or shutil.which("lua") or shutil.which("luajit")
    if lua is None:
        pytest.skip("no lua interpreter available on this host")

    for os_value, expected_applies, expected_marker in (
        ('"Other"', "true", "true"),
        ('"OSX64"', "false", "false"),
        ('"Win64"', "false", "false"),
    ):
        with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False) as f:
            f.write(script.replace("GETOS_VALUE", os_value))
            path = f.name
        try:
            result = subprocess.run([lua, path], text=True, capture_output=True)
            assert result.returncode == 0, result.stdout + result.stderr
            applies, has_marker, line_count = result.stdout.strip().split("|")
            assert applies == expected_applies, f"GetOS()={os_value}: linuxHistoricalBannerAppliesOnThisOS() expected {expected_applies}, got {applies}"
            assert has_marker == expected_marker, (
                f"GetOS()={os_value}: historical marker presence expected {expected_marker}, got {has_marker} "
                f"(macOS/Windows must render the Check-only console exactly like baseline -- no marker, "
                f"original line count preserved)"
            )
            if expected_marker == "false":
                assert line_count == "2", f"GetOS()={os_value}: non-Linux must leave the original 2 lines completely untouched (baseline), got {line_count}"
        finally:
            Path(path).unlink(missing_ok=True)
