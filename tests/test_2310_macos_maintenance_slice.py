"""Regression tests for the narrow 2.3.1.0 macOS maintenance slice:

1. The ROCm-specific Setup action (drumsep-rocm-runtime) must only be
   visible on Linux -- it was gated by `OS ~= "Windows"` (true on macOS
   too), so it incorrectly appeared in the macOS Setup menu even though
   AMD ROCm is a Linux-only runtime.

   2.3.1.1 update: the choices-list construction that item 1 pins was
   extracted from startExistingRuntimeSetupMenu into a standalone,
   directly-callable global function (buildSetupMenuChoices), and the
   ROCm choice is now additionally gated on Linux by actually-detected
   ROCm hardware evidence (capabilities.env), not just OS == "Linux" --
   see tests/test_2311_setup_ui_policy.py for the full CPU/CUDA/ROCm/
   unknown capability matrix. _run_choices_harness below now dofile()s
   the real script and calls buildSetupMenuChoices directly (matching
   tests/support/run_*_headless.lua's pattern) instead of extracting a
   source substring, and test_rocm_setup_action_visible_on_linux supplies
   real ROCm capability evidence to match that updated, more precise
   contract.
2. The D4 cross-variant installer guard (postinstall) already refuses
   correctly and prints informative `echo` text, but macOS Installer.app's
   GUI never surfaces stdout -- only a generic failure dialog. The guard
   now also raises a GUI-visible `osascript` dialog (suppressed under
   TEST_MODE) before exiting 1, without weakening the refusal.
3. Check-only wording under "Historical/stale (not used for the result
   above):" contained a bullet that contradicted its own heading by
   claiming cached macOS ready-state "was used to accept" an inconclusive
   probe -- while the surrounding code's own comments ("Record (never
   apply)", "Disclosure only ... never removes a current negative probe
   result") establish that this flag is never applied to the verdict.
   The bullet is reworded to be truthful and consistent with the heading,
   with no change to the underlying pass/fail authority logic.

Item 4 (parallel/batch processing_summary field aggregation) was
investigated and found to already be fixed and covered end-to-end by
tests/support/run_support_bundle_headless.lua (parallel-output-aggregation,
mixed-success-parallel-jobs, and related scenarios all pass unmodified) --
no source change was needed or made for it in this slice.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "scripts" / "reaper" / "_internal" / "STEMwerk_Setup_Internal.lua"
POSTINSTALL = ROOT / "installer" / "macos" / "scripts" / "postinstall"

LUA = shutil.which("lua5.4") or shutil.which("lua5.3") or shutil.which("lua") or shutil.which("luajit")
pytestmark_lua = pytest.mark.skipif(LUA is None, reason="no lua interpreter available on this host")


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


# --- Item 1: ROCm Setup action is Linux-only -------------------------------


def _lua_state_literal(state: dict[str, str] | None) -> str:
    if not state:
        return "nil"
    parts = ", ".join(f'{key} = "{value}"' for key, value in state.items())
    return "{ " + parts + " }"


def _run_choices_harness(
    tmp_path: Path, os_value: str, runtime_state_dir: Path | None = None, state: dict[str, str] | None = None
) -> list[str]:
    harness = tmp_path / f"choices_{os_value}.lua"
    state_dir = str(runtime_state_dir).replace("\\", "\\\\") if runtime_state_dir else str(tmp_path).replace("\\", "\\\\")
    harness.write_text(
        f"""
STEMWERK_SETUP_HEADLESS_TEST = true
reaper = {{
    ShowMessageBox = function() return 0 end,
    GetOS = function() return "{'Win64' if os_value == 'Windows' else ('OSX64' if os_value == 'macOS' else 'Other')}" end,
    GetExtState = function() return "" end,
    SetExtState = function() end,
    HasExtState = function() return false end,
    DeleteExtState = function() end,
    ShowConsoleMsg = function() end,
    defer = function() end,
    GetResourcePath = function() return "/tmp" end,
    get_action_context = function() return "", "" end,
}}
gfx = {{ init = function() end, mouse_wheel = 0, mouse_cap = 0, w = 1000, h = 700 }}
assert(loadfile("{str(SETUP)}"))()
local runtime = {{ runtimeState = "{state_dir}", runtimeLogs = "{state_dir}", base = "{state_dir}" }}
local choices = buildSetupMenuChoices(runtime, {_lua_state_literal(state)})
for _, c in ipairs(choices) do print(c.id) end
""",
        encoding="utf-8",
    )
    result = subprocess.run([LUA, str(harness)], text=True, capture_output=True)
    assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout.splitlines()


@pytestmark_lua
def test_rocm_setup_action_hidden_on_macos(tmp_path: Path):
    ids = _run_choices_harness(tmp_path, "macOS")
    assert "drumsep-rocm-runtime" not in ids, f"ROCm action must not appear on macOS: {ids}"
    assert "drumsep-runtime" in ids, "CPU DrumSep action must still appear on macOS"
    assert "delete-models" in ids and "delete-runtime" in ids


@pytestmark_lua
def test_rocm_setup_action_visible_on_linux(tmp_path: Path):
    # 2.3.1.1 (second review, Finding 2): the ROCm choice is only shown once
    # ROCm hardware is evidenced by an actual probe from THIS invocation
    # (state.CURRENT_PROBE_*, invocation-local, never read from disk alone)
    # -- see tests/test_2311_setup_ui_policy.py for the full capability
    # matrix, including the neutral-until-probed contract this pins here too.
    state_dir = tmp_path / "state"
    state_dir.mkdir()
    (state_dir / "capabilities.env").write_text(
        "CAP_VERSION=1\nPROFILE=linux-rocm\nBACKEND=rocm\nCUDA_AVAILABLE=true\nCUDA_COUNT=1\nTORCH_HIP=6.4.43483-a187df25c\n",
        encoding="utf-8",
    )
    current_probe = {
        "CURRENT_PROBE_OK": "true",
        "CURRENT_PROBE_PROFILE": "linux-rocm",
        "CURRENT_PROBE_BACKEND": "rocm",
        "CURRENT_PROBE_CUDA_AVAILABLE": "true",
        "CURRENT_PROBE_CUDA_COUNT": "1",
        "CURRENT_PROBE_TORCH_HIP": "6.4.43483-a187df25c",
    }
    ids = _run_choices_harness(tmp_path, "Linux", runtime_state_dir=state_dir, state=current_probe)
    assert "drumsep-rocm-runtime" in ids, f"ROCm action must appear on Linux with a current-invocation ROCm probe: {ids}"

    # Without a current-invocation probe, the same persisted capabilities.env
    # must NOT be enough on its own (this is exactly the bug Finding 2 closed).
    idsNoProbe = _run_choices_harness(tmp_path, "Linux", runtime_state_dir=state_dir)
    assert "drumsep-rocm-runtime" not in idsNoProbe, (
        f"persisted capabilities.env alone (no current-invocation probe) must never surface the ROCm choice: {idsNoProbe}"
    )


@pytestmark_lua
def test_rocm_setup_action_still_hidden_on_windows(tmp_path: Path):
    ids = _run_choices_harness(tmp_path, "Windows")
    assert "drumsep-rocm-runtime" not in ids
    # 2.3.1.1: Windows Setup-within-REAPER no longer offers any mutating
    # action, including these -- see tests/test_2311_setup_ui_policy.py.
    assert "drumsep-cuda-runtime" not in ids and "drumsep-directml-runtime" not in ids


def test_red_old_guard_would_have_shown_rocm_action_on_macos():
    """RED-documentation: the old `OS ~= "Windows"` guard is true for both
    Linux and macOS, so it could not have distinguished them -- pins the
    exact shape of the bug this fix closes."""
    text = _read(SETUP)
    start = text.index("function buildSetupMenuChoices(runtime, state)")
    end = text.index("\nend", start)
    snippet = text[start:end]
    assert 'if OS == "Linux" and' in snippet, "current source must gate ROCm specifically to Linux"
    old_os_check_alone_would_include_macos = ("macOS" != "Windows")
    assert old_os_check_alone_would_include_macos, "sanity: macOS satisfies the old OS ~= Windows guard"


# --- Item 2: D4 guard now raises a GUI-visible osascript dialog ------------


def test_d4_guard_source_has_gui_dialog_before_exit():
    text = _read(POSTINSTALL)
    d4_start = text.index('if [[ -f "$TARGET/_bundled/macos/apple-silicon/manifest.json" ]]')
    d4_end = text.index("\nfi", text.index("exit 1", d4_start))
    block = text[d4_start:d4_end]
    assert "osascript" in block, "D4 refusal must raise a GUI-visible osascript dialog"
    assert 'if [[ "$TEST_MODE" != "yes" ]]' in block, "dialog must be suppressed under TEST_MODE for hermetic tests"
    assert block.index("osascript") < block.index("exit 1"), "dialog must appear before the refusal exit 1"
    assert "sudo -u \"$CONSOLE_USER\"" in block, "dialog must run as the console user, matching the success dialog"


def _postinstall_env(src, home):
    import os

    env = dict(os.environ)
    env["STEMWERK_POSTINSTALL_SRC_OVERRIDE"] = str(src)
    env["STEMWERK_POSTINSTALL_HOME_OVERRIDE"] = str(home)
    return env


def _mk_tree(tmp_path):
    home = tmp_path / "home"
    target = home / "Library/Application Support/REAPER/Scripts/STEMwerk-reaper"
    target.mkdir(parents=True)
    return home, target


@pytest.mark.skipif(__import__("os").name == "nt", reason="POSIX/bash installer")
def test_d4_refusal_still_exits_1_and_preserves_payload_with_dialog_added(tmp_path: Path):
    """The dialog addition must not weaken the guard: refusal behavior,
    exit code, and payload preservation must be identical to before."""
    src = tmp_path / "src"
    (src / "scripts").mkdir(parents=True)
    (src / "scripts/a.lua").write_text("x\n", encoding="utf-8")
    home, target = _mk_tree(tmp_path)
    manifest = target / "_bundled/macos/apple-silicon/manifest.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text("{}\n", encoding="utf-8")

    result = subprocess.run(["bash", str(POSTINSTALL)], env=_postinstall_env(src, home),
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 1
    assert "has been stopped" in result.stdout
    assert manifest.is_file(), "bundled payload must be preserved on refusal"
    # TEST_MODE must have suppressed any actual osascript invocation --
    # otherwise this test would hang/fail on a host without a GUI session.


@pytest.mark.skipif(__import__("os").name == "nt", reason="POSIX/bash installer")
def test_online_target_upgraded_by_incoming_bundled_payload_is_allowed(tmp_path: Path):
    """D4 only refuses bundled-over-thin. The reverse -- an existing thin/
    online install receiving a bundled payload -- is a legitimate upgrade
    and must proceed (not previously covered by an explicit test)."""
    src = tmp_path / "src"
    (src / "_bundled/macos/apple-silicon").mkdir(parents=True)
    (src / "_bundled/macos/apple-silicon/manifest.json").write_text("{}\n", encoding="utf-8")
    (src / "scripts").mkdir()
    (src / "scripts/a.lua").write_text("x\n", encoding="utf-8")

    home, target = _mk_tree(tmp_path)
    (target / "scripts").mkdir(parents=True)
    (target / "scripts/a.lua").write_text("old\n", encoding="utf-8")

    result = subprocess.run(["bash", str(POSTINSTALL)], env=_postinstall_env(src, home),
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stdout + result.stderr
    assert (target / "_bundled/macos/apple-silicon/manifest.json").is_file(), "bundled payload must be installed"


# --- Item 3: cached-state disclosure wording is truthful and consistent ---


def test_stale_provenance_bullet_no_longer_claims_it_was_used():
    text = _read(SETUP)
    assert "was used to accept an inconclusive current Torch probe result" not in text, (
        "old wording claimed cached state decided/accepted an inconclusive probe, "
        "contradicting the 'not used for the result above' heading and the "
        "'Record (never apply)' / 'Disclosure only' comments on the same mechanism"
    )


def test_stale_provenance_bullet_is_consistent_with_not_used_heading():
    text = _read(SETUP)
    idx = text.index("if checkProbe.usedCachedReadyStateFallback then")
    bullet_start = text.index('"macOS cached ready_to_go/capabilities state', idx)
    bullet_end = text.index("\n", bullet_start)
    bullet = text[bullet_start:bullet_end]
    assert "not used to decide" in bullet, f"bullet must state it was not used to decide the result: {bullet}"

    heading_idx = text.index('"Historical/stale (not used for the result above):"')
    heading = text[heading_idx:heading_idx + 60]
    assert "not used for the result above" in heading


def test_stale_provenance_mechanism_is_still_disclosure_only_never_applied():
    """Confirms the wording fix did not touch the actual authority logic:
    canAcceptMacReadyHealthyState must still never be applied to
    adjustedErrors/verifiedRuntimeOk (disclosure only)."""
    text = _read(SETUP)
    comment_idx = text.index("canAcceptMacReadyHealthyState is NOT applied to adjustedErrors")
    assert comment_idx > 0
    verified_idx = text.index(
        "local verifiedRuntimeOk = verification.pythonOk and verification.ffmpegOk and #adjustedErrors == 0"
    )
    # The verifiedRuntimeOk computation itself must not reference the cached-state flag.
    line_start = text.rindex("\n", 0, verified_idx) + 1
    line_end = text.index("\n", verified_idx)
    verified_line = text[line_start:line_end]
    assert "canAcceptMacReadyHealthyState" not in verified_line
    assert "usedCachedReadyStateFallback" not in verified_line
