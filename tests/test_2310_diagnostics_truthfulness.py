"""Regression tests for the 2.3.1.0 diagnostics/setup/support-bundle
truthfulness fixes.

These pin the concrete, reproducible bugs identified in the release-gate
review: a UI/log/support-bundle summary must never state something that
contradicts current evidence (e.g. treating a failed Python import probe as
successful because it printed text on stderr, writing __pycache__ during a
check-only probe, or a misleading "Last run" label for data that is really
just the last recorded setup script version).

Model-collapsing / device-classification / run-association / output-count
truthfulness fixes (Direct Kit, Kit Split, AMD ROCm vs NVIDIA CUDA, 6-Stem
late resolution, parallel aggregation, run-ID association, acceptance-phase
terminology, current-fatal severity) are covered end-to-end by the real
production code path in tests/support/run_support_bundle_headless.lua,
which dofile()s the actual STEMwerk_Save_Support_Bundle.lua against mocked
scenarios -- that is stronger evidence than a source-text check here, so
this file does not duplicate it.
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "scripts" / "reaper" / "_internal" / "STEMwerk_Setup_Internal.lua"
LANG_TOP = ROOT / "i18n" / "languages.lua"
LANG_SCRIPTS = ROOT / "scripts" / "reaper" / "i18n" / "languages.lua"


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class TestLinuxImportHelpersRequireExitCodeZero:
    """Section A: success requires subprocess exit code 0; stray stderr/
    stdout text on a non-zero exit must not be treated as success."""

    def test_source_no_longer_treats_any_output_as_success(self):
        text = _read(SETUP)
        # This was the exact bug: a non-zero/failed close() with any stray
        # output text (e.g. a partial traceback) was accepted as success.
        assert 'return (output ~= "")' not in text, (
            "canImportAudioSeparator/canImportStemwerkCore must not treat "
            "any stderr/stdout text as proof of success on a non-zero exit"
        )

    def test_import_helpers_gate_success_on_exit_code(self):
        text = _read(SETUP)
        for fn_name in ("canImportAudioSeparator", "canImportStemwerkCore"):
            start = text.index(f"local function {fn_name}(path)")
            end = text.index("\nend", start)
            body = text[start:end]
            assert "return ok == true or code == 0" in body, (
                f"{fn_name} must gate success purely on the subprocess exit "
                f"code (h:close() ok/code), not on whether any text was "
                f"printed"
            )

    def test_only_one_canImportStemwerkCore_definition_remains(self):
        # The pre-existing source defined canImportStemwerkCore twice with
        # byte-identical (buggy) bodies, where the second silently shadowed
        # the first. Fixing the bug in only one copy while leaving an
        # identical, now-inconsistent duplicate around would be confusing;
        # both were consolidated into a single corrected definition.
        text = _read(SETUP)
        assert text.count("local function canImportStemwerkCore(path)") == 1


class TestCheckOnlyProbesSuppressBytecode:
    """Section B: check-only Python probes/imports must not write
    __pycache__ into the shipped source tree."""

    EXPECTED_B_FLAG_SNIPPETS = [
        # directRuntimeDeviceProbe (device probe)
        'quoteArg(pythonPath) .. " -B -c "',
        # canRunPython's python-version probe
        '" -B -c " .. quoteArg("import sys;',
        # pythonVersionText
        '" -B -c " .. quoteArg("import platform;',
        # checkPinnedTorchRuntime (torch/torchaudio/numpy/numba probe)
        '" -B -c " .. quoteArg(script)',
        # canImportAudioSeparator (audio_separator / onnxruntime / Separator)
        '" -B -c " .. quoteArg("import audio_separator; import onnxruntime; from audio_separator.separator import Separator")',
        '" -B -c " .. quoteArg("import audio_separator; import onnxruntime")',
        # canImportStemwerkCore (stemwerk_core)
        '" -B -c " .. quoteArg("import stemwerk_core")',
        # probeRuntimeDevices (--list-devices-machine / --list-devices)
        '" -B -u " .. quoteArg(separatorScript) .. " --list-devices-machine"',
        '" -B -u " .. quoteArg(separatorScript) .. " --list-devices"',
    ]

    def test_all_check_only_probe_invocations_pass_dash_b(self):
        text = _read(SETUP)
        missing = [snippet for snippet in self.EXPECTED_B_FLAG_SNIPPETS if snippet not in text]
        assert not missing, f"check-only probe(s) missing -B bytecode suppression: {missing}"

    def test_linux_env_prefix_also_sets_pythondontwritebytecode(self):
        text = _read(SETUP)
        start = text.index("linuxEnvPrefix = function()")
        end = text.index("\nend", start)
        body = text[start:end]
        assert "PYTHONDONTWRITEBYTECODE=1" in body

    def test_pip_install_is_not_touched(self):
        # -B only belongs on check-only diagnostic probes. The real
        # dependency-install path (`-m pip install`) must be untouched --
        # this is a release invariant (no runtime-installation behavior
        # changes), not a check-only probe.
        text = _read(SETUP)
        assert 'quoteArg(pythonPath) .. " -m pip install "' in text


class TestPythonDashBActuallySuppressesBytecode:
    """Behavioral proof (not just a source grep) that `python -B` is an
    effective, real mechanism for the fix above: importing a local module
    with -B must not leave __pycache__ behind, while the same import
    without -B does."""

    def _run_import(self, python: str, workdir: Path, use_b: bool) -> None:
        args = [python]
        if use_b:
            args.append("-B")
        args += ["-c", "import stemwerk_probe_dummy"]
        subprocess.run(args, cwd=str(workdir), check=True, capture_output=True)

    def test_dash_b_prevents_pycache_directory(self):
        python = shutil.which("python3") or shutil.which("python")
        if not python:
            pytest.skip("no python interpreter available in this environment")
        with tempfile.TemporaryDirectory() as tmp:
            workdir = Path(tmp)
            (workdir / "stemwerk_probe_dummy.py").write_text("VALUE = 1\n", encoding="utf-8")

            self._run_import(python, workdir, use_b=True)
            assert not (workdir / "__pycache__").exists(), (
                "python -B must not create __pycache__ for a check-only import probe"
            )

            self._run_import(python, workdir, use_b=False)
            assert (workdir / "__pycache__").exists(), (
                "sanity check failed: this python does not create __pycache__ "
                "on a plain import, so the -B assertion above would be "
                "meaningless -- environment issue, not a fix issue"
            )


class TestLastRunSemantics:
    """Section C: the "Last run" label was misleading -- it only ever
    reflects bootstrap.env:STEMWERK_SETUP_VERSION (the last *recorded setup
    script version*), never a real "last run" history. The smallest
    truthful fix is relabeling it to describe the data actually held."""

    def test_i18n_label_no_longer_says_last_run(self):
        for path in (LANG_TOP, LANG_SCRIPTS):
            text = _read(path)
            assert 'setup_last_run_label = "Last run",' not in text, (
                f"{path} still uses the misleading English 'Last run' label"
            )
            assert 'setup_last_run_label = "Recorded setup version",' in text

    def test_i18n_copies_stay_in_sync(self):
        assert _read(LANG_TOP) == _read(LANG_SCRIPTS), (
            "the two languages.lua copies (top-level and scripts/reaper) "
            "must stay byte-identical"
        )

    def test_setup_internal_fallback_text_matches(self):
        text = _read(SETUP)
        assert 'setupText("setup_last_run_label", "Last run")' not in text
        assert text.count('setupText("setup_last_run_label", "Recorded setup version")') == 2

    def test_unknown_state_still_does_not_claim_a_known_last_run(self):
        # When lastSetupVersion is empty, the row must render the
        # (now-truthfully-labeled) field with an explicit "(unknown)" value
        # rather than fabricating a version -- and the label itself no
        # longer primes the reader to expect real run history.
        text = _read(SETUP)
        start = text.index("-- Version info block")
        end = text.index("\nend", start)
        body = text[start:end]
        assert 'setupText("setup_unknown", "(unknown)")' in body
