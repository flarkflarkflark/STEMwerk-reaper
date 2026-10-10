"""Regression coverage for the Visual C++ x64 runtime preflight (issue #126
follow-up).

Real user evidence (issue #126) showed Torch/ONNX Runtime native DLL
initialization failures ("c10.dll", ONNX Runtime init errors, silent CPU
fallback) that were actually caused by a stale Microsoft Visual C++ x64
Redistributable rather than anything STEMwerk installs itself; installing
the current redistributable resolved it. LogVisualCppRuntimeStatus() in
STEMwerk_Bootstrap_Windows.ps1 is a warn-only preflight that logs the
detected state before Torch/ONNX Runtime work begins -- it must never
auto-install/download anything and must never turn an absent/stale runtime
into a hard setup failure on its own.

pwsh is available on this Linux dev machine, so the extraction/parsing logic
itself is exercised for real here against synthetic registry-query output;
the real Windows registry cannot be reached from Linux (see the docstring
note in each test below).
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest
import shutil

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "scripts" / "reaper" / "STEMwerk_Bootstrap_Windows.ps1"


def _ps_function(text: str, name: str) -> str:
    start = text.index(f"function {name}")
    brace = text.index("{", start)
    depth = 0
    single = False
    double = False
    for index in range(brace, len(text)):
        char = text[index]
        previous = text[index - 1] if index else ""
        if char == "'" and not double and previous != "`":
            single = not single
        elif char == '"' and not single and previous != "`":
            double = not double
        elif not single and not double:
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    return text[start : index + 1]
    raise AssertionError(name)


def _pwsh_available() -> bool:
    return shutil.which("pwsh") is not None


def _run_harness(tmp_path: Path, fake_registry_ps: str) -> dict[str, str]:
    text = BOOTSTRAP.read_text(encoding="utf-8-sig")
    function = _ps_function(text, "LogVisualCppRuntimeStatus")
    harness = tmp_path / "vcpp.ps1"
    harness.write_text(
        f"""
$script:ProgressLines = @()
$script:StatusDetailLines = @()
function LogProgress([string]$Message) {{ $script:ProgressLines += $Message }}
function LogStatusDetail([string]$Message) {{ $script:StatusDetailLines += $Message }}
function Get-ItemProperty {{
    param([string]$Path, [string]$ErrorAction)
{fake_registry_ps}
}}

{function}

LogVisualCppRuntimeStatus

foreach ($line in $script:ProgressLines) {{ "PROGRESS=$line" }}
foreach ($line in $script:StatusDetailLines) {{ "DETAIL=$line" }}
""",
        encoding="utf-8",
    )
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-File", str(harness)],
        check=True,
        text=True,
        capture_output=True,
        timeout=60,
    )
    progress = []
    detail = []
    for line in result.stdout.splitlines():
        if line.startswith("PROGRESS="):
            progress.append(line[len("PROGRESS=") :])
        elif line.startswith("DETAIL="):
            detail.append(line[len("DETAIL=") :])
    return {"progress": progress, "detail": detail}


@pytest.mark.skipif(not _pwsh_available(), reason="pwsh not available")
def test_missing_registry_key_reports_missing_and_does_not_hard_fail(tmp_path):
    # No real Windows registry on this Linux machine -- Get-ItemProperty is
    # stubbed to always throw, simulating neither runtime key existing.
    result = _run_harness(tmp_path, "throw 'not found'")
    assert any("VCPP_RUNTIME_STATUS=missing" in line for line in result["progress"])
    assert any("was not detected" in line for line in result["detail"])
    # Warn-only: no Set-Status call exists in the harness at all, so if the
    # function tried to call it, this would fail with a command-not-found
    # error rather than silently succeeding -- the harness completing at all
    # already proves no hard-failure path was taken.


@pytest.mark.skipif(not _pwsh_available(), reason="pwsh not available")
def test_stale_version_reports_stale_with_version_and_does_not_hard_fail(tmp_path):
    fake = """
    if ($Path -eq 'HKLM:\\SOFTWARE\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\X64') {
        return [pscustomobject]@{ Installed = 1; Version = '14.29.30139.0' }
    }
    throw 'not found'
    """
    result = _run_harness(tmp_path, fake)
    assert any("VCPP_RUNTIME_STATUS=stale version=14.29.30139.0" in line for line in result["progress"])
    assert any("appears outdated" in line for line in result["detail"])


@pytest.mark.skipif(not _pwsh_available(), reason="pwsh not available")
def test_current_version_reports_ok_with_no_warning(tmp_path):
    fake = """
    if ($Path -eq 'HKLM:\\SOFTWARE\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\X64') {
        return [pscustomobject]@{ Installed = 1; Version = '14.44.35211.0' }
    }
    throw 'not found'
    """
    result = _run_harness(tmp_path, fake)
    assert any("VCPP_RUNTIME_STATUS=ok version=14.44.35211.0" in line for line in result["progress"])
    assert result["detail"] == []


@pytest.mark.skipif(not _pwsh_available(), reason="pwsh not available")
def test_wow6432node_mirror_is_checked_when_primary_key_is_absent(tmp_path):
    fake = """
    if ($Path -eq 'HKLM:\\SOFTWARE\\WOW6432Node\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\X64') {
        return [pscustomobject]@{ Installed = 1; Version = '14.44.35211.0' }
    }
    throw 'not found'
    """
    result = _run_harness(tmp_path, fake)
    assert any("VCPP_RUNTIME_STATUS=ok version=14.44.35211.0" in line for line in result["progress"])


@pytest.mark.skipif(not _pwsh_available(), reason="pwsh not available")
def test_malformed_version_string_does_not_crash_and_degrades_to_ok(tmp_path):
    fake = """
    if ($Path -eq 'HKLM:\\SOFTWARE\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\X64') {
        return [pscustomobject]@{ Installed = 1; Version = 'not-a-version' }
    }
    throw 'not found'
    """
    result = _run_harness(tmp_path, fake)
    # Must not throw (subprocess.run(check=True) would raise if it did);
    # malformed version text degrades to a plain ok report rather than a crash.
    assert any(line.startswith("VCPP_RUNTIME_STATUS=ok") for line in result["progress"])
