"""2.3.1.3 Windows Setup/Repair dispatch regression coverage.

Windows reaches the shared Linux/macOS final Setup window through Check only
(finalizeWindowsVerify -> showDeferredFinalWindow). That window must never
route Windows into startLinuxSetup, which clears bootstrap.env/capabilities.env
and then tries `/bin/sh ...STEMwerk_Bootstrap_Windows.ps1`. The Windows
installer-required message must also pass title and body in the adapter's order.

tests/support/run_windows_repair_dispatch_2313_headless.lua drives the real
production Lua (menu click -> verify ticks -> final window -> button click).
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
HARNESS = ROOT / "tests" / "support" / "run_windows_repair_dispatch_2313_headless.lua"
MAIN = ROOT / "scripts" / "reaper" / "STEMwerk.lua"


@pytest.mark.skipif(shutil.which("lua") is None, reason="Lua interpreter required for headless Setup coverage")
def test_windows_repair_dispatch_headless(tmp_path: Path) -> None:
    # The harness writes Windows-style paths as literal file names in its cwd.
    result = subprocess.run(
        [shutil.which("lua") or "lua", str(HARNESS)],
        cwd=tmp_path,
        env={**os.environ, "STEMWERK_TEST_REPO_ROOT": str(ROOT)},
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, f"headless Windows repair dispatch harness failed:\n{result.stdout}\n{result.stderr}"
    for marker in (
        "PASS windows-check-only-route-reaches-final-window-without-repair",
        "PASS windows-repair-click-uses-installer-guard-and-preserves-state",
        "PASS windows-rebuild-venv-click-uses-installer-guard-and-preserves-state",
        "PASS windows-success-final-window-unchanged",
        "PASS linux-final-window-repair-and-rebuild-unchanged",
        "PASS macos-final-window-repair-and-rebuild-unchanged",
        "PASS windows-installer-required-message-title-and-body",
        "ALL PASS run_windows_repair_dispatch_2313_headless",
    ):
        assert marker in result.stdout, f"missing expected marker {marker!r} in:\n{result.stdout}"


def test_runtime_setup_message_adapter_takes_title_then_text() -> None:
    # The headless message test records (title, text) in this exact order, so
    # it is only meaningful while the one production adapter keeps it.
    text = MAIN.read_text(encoding="utf-8")
    start = text.index("showMessageBox = function(title, text, type)")
    adapter = text[start:start + 250]
    assert "reaper.ShowMessageBox(tostring(text), tostring(title), type or 0)" in adapter
