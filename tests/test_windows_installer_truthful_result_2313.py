"""Regression coverage for the combined #120(b)/#122(b) Windows installer
truthfulness slice.

The Inno Setup installer previously always showed the Finished-page summary
"STEMwerk setup completed." and unconditionally offered/opened the
post-install setup guide, regardless of whether STEMwerk_Bootstrap_Windows.ps1
actually succeeded. This tested a single authoritative result --
BootstrapSucceeded, resolved once in CurStepChanged(ssPostInstall) from the
same STATUS field the bootstrap script itself uses to decide its own process
exit code -- that both the Finished-page text and the guide-open action now
branch on.

The current [Run] entry that launches STEMwerk_Installer_Windows.ps1 is a
plain declarative entry (no scripted Exec() call), so Inno Setup does not
expose that process's exit code to [Code] directly without a larger
architectural change; %LOCALAPPDATA%\\STEMwerk\\state\\bootstrap.env's
STATUS field is the narrowest reliable substitute, not free-text log
scraping -- it is the exact structured value the bootstrap script treats as
authoritative for its own exit code.

These are static checks against the .iss source (no Inno Setup Compiler or
Wine-hosted Inno Setup runtime is available in this Linux dev environment;
see the accompanying report for what still needs real Windows validation),
mirroring the style already used in tests/test_windows_payload_contract_2306.py
and tests/test_windows_disk_space_preflight_2313.py.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ISS = ROOT / "installer" / "windows" / "STEMwerk.iss"


def _text() -> str:
    return ISS.read_text(encoding="utf-8")


def _function_body(text: str, name: str) -> str:
    """Extract one Pascal function/procedure body by brace-free `begin`/`end;`
    matching (Pascal Script has no braces, so this tracks begin/end nesting
    instead, skipping the small number of `begin`/`end` keyword occurrences
    inside string literals this file happens to contain -- none of the
    functions targeted by these tests have any)."""
    start = text.index(f"function {name}")
    if start == -1:
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


def test_bootstrap_result_is_resolved_from_the_authoritative_state_file():
    text = _text()
    assert "function GetBootstrapStatePath: string;" in text
    assert "GetRuntimeBasePath + '\\state\\bootstrap.env'" in text
    assert "function ReadBootstrapStatus: string;" in text
    assert "LoadStringFromFile(GetBootstrapStatePath, RawContent)" in text
    assert "Marker := 'STATUS=';" in text
    assert "function ResolveBootstrapSucceeded: Boolean;" in text
    assert "Result := ReadBootstrapStatus = 'ok';" in text


def test_bootstrap_succeeded_is_a_single_resolved_result():
    text = _text()
    # Exactly one global BootstrapSucceeded declaration -- one classifier,
    # not several independent ones. (Anchored to the `var` block's leading
    # indentation so it does not also match inside
    # "function ResolveBootstrapSucceeded: Boolean;".)
    assert text.count("\n  BootstrapSucceeded: Boolean;\n") == 1
    # Resolved exactly once, at ssPostInstall (after the automatic [Run]
    # entry that launches the bootstrap has already completed, and before
    # the Finished page's [Run] Check: clauses or FinishedLabel are built).
    assert "procedure CurStepChanged(CurStep: TSetupStep);" in text
    assert "if CurStep = ssPostInstall then" in text
    assert "BootstrapSucceeded := ResolveBootstrapSucceeded;" in text
    # Success is never inferred merely from the process having returned or
    # the wizard reaching wpFinished -- the only assignment site is the one
    # above, driven by the state file.
    assignment_sites = re.findall(r"BootstrapSucceeded\s*:=", text)
    assert len(assignment_sites) == 1


def test_finished_summary_dispatches_on_the_resolved_result():
    body = _function_body(_text(), "BuildFinishedSummaryText")
    assert "if BootstrapSucceeded then" in body
    assert "Result := BuildFinishedSuccessSummaryText" in body
    assert "Result := BuildFinishedFailureSummaryText" in body


def test_success_finished_text_reports_success():
    body = _function_body(_text(), "BuildFinishedSuccessSummaryText")
    assert "STEMwerk setup completed." in body
    assert "What was installed:" in body


def test_failure_finished_text_reports_failure_and_points_to_the_log():
    body = _function_body(_text(), "BuildFinishedFailureSummaryText")
    assert "did not complete successfully" in body
    assert "GetLogPath" in body


def test_failure_finished_text_makes_no_unconditional_installed_claims():
    body = _function_body(_text(), "BuildFinishedFailureSummaryText")
    # None of the success-path's "X was installed" claims may appear in the
    # failure path.
    for forbidden in ("What was installed:", "- REAPER scripts", "- STEMwerk runtime", "- Required audio tools", "were successfully installed"):
        assert forbidden not in body, f"failure text must not claim {forbidden!r}"


def test_failure_and_success_text_are_distinct_functions():
    text = _text()
    assert "function BuildFinishedSuccessSummaryText: string;" in text
    assert "function BuildFinishedFailureSummaryText: string;" in text
    # The old unconditional name must no longer exist as a text-building
    # function in its own right -- only as the dispatcher.
    assert text.count("function BuildFinishedSuccessSummaryText") == 1
    assert text.count("function BuildFinishedFailureSummaryText") == 1


def test_each_language_path_is_wired_in_both_finished_texts():
    text = _text()
    for name in ("BuildFinishedSuccessSummaryText", "BuildFinishedFailureSummaryText"):
        body = _function_body(text, name)
        # Every LText(...) call in both functions must supply exactly three
        # non-empty string-literal arguments (EN, NL, DE), so no language is
        # silently left out for the new failure text.
        calls = re.findall(r"LText\(\s*'((?:[^'\\]|\\.)*)',\s*'((?:[^'\\]|\\.)*)',\s*'((?:[^'\\]|\\.)*)'", body)
        assert calls, f"{name} has no LText(...) calls"
        for en, nl, de in calls:
            assert en.strip(), f"{name}: empty EN string in an LText(...) call"
            assert nl.strip(), f"{name}: empty NL string in an LText(...) call"
            assert de.strip(), f"{name}: empty DE string in an LText(...) call"


def test_guide_action_is_gated_on_bootstrap_success():
    text = _text()
    guide_line = next(
        line for line in text.splitlines()
        if "GetLocalizedGuidePath" in line and line.strip().startswith("Filename:")
    )
    assert "Check: BootstrapSucceeded" in guide_line, (
        "the post-install guide [Run] entry must be gated on BootstrapSucceeded "
        "so it is not offered as a normal next step after a failed install"
    )


def test_setup_log_action_remains_unconditionally_available():
    text = _text()
    log_line = next(
        line for line in text.splitlines()
        if "bootstrap.log" in line and line.strip().startswith("Filename:")
    )
    assert "Check:" not in log_line, (
        "the 'Open setup log' action must remain available regardless of "
        "bootstrap outcome -- it is particularly useful after a failure"
    )
    assert "unchecked" in log_line, "the log action's existing unchecked default must be preserved"


def test_bootstrap_installer_run_entry_is_unmodified():
    # Requirement: do not alter bootstrap/runtime installation behavior
    # itself -- the actual [Run] entry that launches the installer wrapper
    # must be untouched by this slice.
    text = _text()
    assert (
        'Filename: "powershell.exe"; Parameters: "-ExecutionPolicy Bypass -NoProfile -File '
        '""{app}\\STEMwerk_Installer_Windows.ps1""{code:GetInstallerScriptArgs}"; '
        'StatusMsg: "Preparing STEMwerk runtime..."; Flags: runhidden waituntilterminated'
    ) in text
