"""Regression tests for the 2.3.1.0 macOS clean offline first-run bootstrap
release blocker: a genuinely fresh, offline, bundled/allmodels Apple
Silicon install fails on its FIRST automatic initialization (Setup UI:
"Python path is missing", backend=cpu, backend_reason=python_missing;
bootstrap.log shows "onnxruntime import failed: No module named
'onnxruntime'" / "onnxruntime: expected 1.27.0, got missing"), while an
immediate manual Repair -- using the exact same bundled payload, still
fully offline -- succeeds and reaches a healthy state.

Investigation performed here with the real shell functions extracted
verbatim from STEMwerk_Bootstrap_macOS.sh and executed under a real POSIX
`sh` (never a re-implementation):

  assert_pinned_torch_stack() is called once BEFORE onnxruntime is
  installed (by design/ordering -- the install only happens after that
  first assertion) and once again AFTER. On every genuinely fresh/offline
  run this makes the FIRST assertion's "onnxruntime missing" failure
  unavoidable -- exactly the bootstrap.log lines quoted above -- which the
  script records as a sticky STATUS=deps_failed/torch_pin_assert_failed
  (set_status() only ever records the FIRST failure of a run; every later
  call is a no-op while STATUS != "ok"). The script already anticipates
  this and re-verifies everything at the very end, computing
  FINAL_RUNTIME_VERIFIED, and clears exactly that stale STATUS_REASON.

  test_clean_first_run_self_heals_when_onnxruntime_install_succeeds below
  PROVES, by direct execution of the real code, that this exact documented
  ordering already self-heals correctly on a single automatic run -- the
  "onnxruntime missing" log lines are expected, harmless, self-recovering
  noise, not proof of the reported failure. This DISPROVES the most
  obvious reading of the live evidence.

  What direct execution DOES prove is a real, narrower structural gap:
  the clearing block does not key off the truth it already computed
  (FINAL_RUNTIME_VERIFIED) -- it re-derives "was this a torch/onnxruntime
  hiccup" by enumerating exactly three literal STATUS_REASON strings
  (torch_install_failed, torch_pin_repair_failed, torch_pin_assert_failed).
  Any OTHER legitimate first-run-only transient sticky failure recorded
  earlier in the same run and equally superseded by that same final
  verification -- e.g. audio_separator_install_failed, numba_missing_
  after_setup, samplerate_arch_mismatch_requires_runtime_rebuild, or even
  onnxruntime_install_failed itself (which set_status() can never record
  in the first place once STATUS is already stuck, per the same sticky-
  first-wins rule) -- can NEVER be cleared, even though the exact same
  final verification block that clears the three whitelisted strings
  already proved the runtime is fully healthy. test_stale_status_not_
  whitelisted_survives_successful_final_verification below proves this
  gap directly (RED against the current source).

  This is exactly the "failed intermediate STATUS persisting after later
  recovery" category the investigation was asked to check for -- it is
  real and fixed here, even though it does not reproduce the *exact*
  literal onnxruntime-labeled symptom from the live report (which, per
  the proof above, already self-heals). A live macOS retest is required
  to confirm which specific transient reason the real report actually hit.

Repair succeeds because it is a second, independent invocation of the
same script against a venv that already has onnxruntime (and whatever
else) correctly installed from the first run's own successful work -- so
its first assertion never observes anything missing, and STATUS never
becomes sticky-failed at all.
"""

from __future__ import annotations

import re
import subprocess
import textwrap
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "scripts" / "reaper" / "STEMwerk_Bootstrap_macOS.sh"

SH = "/bin/sh"


def _bootstrap_text() -> str:
    return BOOTSTRAP.read_text(encoding="utf-8")


_HEREDOC_START_RE = re.compile(r"<<-?\s*'?\"?([A-Za-z_][A-Za-z0-9_]*)'?\"?")


def _function_body(text: str, name: str) -> str:
    """Extract a `name() { ... }` block by scanning line-by-line for the
    closing brace, skipping over the CONTENTS of any heredoc (<<PY ... PY)
    the function body contains -- several of these bootstrap functions
    embed Python source (including bare `}` lines, e.g. dict literals) via
    heredocs, which a naive "next lone `}` line" search would mistake for
    the shell function's own closing brace."""
    start = text.index(f"\n{name}() {{\n") + 1
    lines = text[start:].splitlines(keepends=True)
    heredoc_delim = None
    consumed = []
    for line in lines:
        consumed.append(line)
        if heredoc_delim is not None:
            if line.rstrip("\n") == heredoc_delim:
                heredoc_delim = None
            continue
        m = _HEREDOC_START_RE.search(line)
        if m:
            heredoc_delim = m.group(1)
            continue
        if line == "}\n" or line == "}":
            return "".join(consumed)
    raise AssertionError(f"could not find end of function {name}")


_FUNCTIONS = (
    "log",
    "write_state",
    "set_status",
    "set_progress",
    "bundled_ffmpeg_path",
    "install_with_optional_bundled_wheels",
    "pinned_torch_stack_already_ok",
    "install_pinned_torch_stack",
    "assert_pinned_torch_stack",
    "repair_samplerate_if_arch_mismatch",
    "verify_venv_arch",
    "verify_audio_separator_runtime_deps",
    "validate_ffmpeg_pair",
)


def _driver_segment(text: str) -> str:
    """The real, unmodified sequential flow this bug lives in: from the
    moment the venv is confirmed present through the stale-STATUS-clearing
    block, verbatim. Ends right after the clearing block so this test can
    inspect STATUS/STATUS_REASON without needing FFmpeg/model/DrumSep
    fixtures, which are unrelated to this defect.

    The real script wraps just the venv-create/venv-use `if` blocks (the
    part starting this slice) inside a larger `if [ -z "${PYTHON}" ]; then
    exit 1; else ... fi` -- this slice starts inside that `else` branch, so
    the one `fi` closing that outer if/else (immediately after the venv-use
    block's own closing `fi`, whose opening this slice deliberately
    excludes since $PYTHON is always resolved in this harness) is removed
    to keep the extracted snippet self-contained and syntactically valid.
    The rest of the slice (FFmpeg discovery, final verification block) is
    top-level/sequential in the real script and needs no such adjustment.
    """
    start = text.index('  if [ -x "${RUNTIME_BASE}/.venv/bin/python" ]; then\n')
    end = text.index("\nREADY_RUNTIME_KIND=", start)
    segment = text[start:end]
    orphan_fi = "    fi\n  fi\nfi\nfi\n\nset_progress"
    replacement = "    fi\n  fi\n\nset_progress"
    assert segment.count(orphan_fi) == 1, segment
    segment = segment.replace(orphan_fi, replacement)
    # This slice includes the real FFmpeg-discovery loop, which probes
    # hardcoded absolute Homebrew/MacPorts/system paths. On a machine that
    # actually has FFmpeg installed there (e.g. a dev laptop with
    # Homebrew), those paths would be found and validated, invalidating
    # any test that wants to exercise "FFmpeg genuinely undiscoverable".
    # Rewrite them to a nonexistent root so this suite never depends on
    # what happens to be installed on the machine running it. Harmless for
    # every other test here, since their fake FFmpeg fixture is always
    # found via the stubbed bundled_ffmpeg_path() candidate first, before
    # the loop ever reaches these hardcoded paths.
    for root in ("/opt/homebrew", "/usr/local", "/opt/local", "/usr/bin"):
        segment = segment.replace(f'"{root}/', f'"/nonexistent-test-root{root}/')
    return segment


def _build_harness(
    tmp_path: Path,
    *,
    onnxruntime_install_succeeds: bool,
    pre_status_reason: str | None = None,
    ffmpeg_missing: bool = False,
) -> Path:
    text = _bootstrap_text()
    funcs = "\n".join(_function_body(text, name) for name in _FUNCTIONS)
    driver = _driver_segment(text)

    runtime_base = tmp_path / "runtime"
    (runtime_base / ".venv" / "bin").mkdir(parents=True)
    log_file = tmp_path / "bootstrap.log"
    state_file = tmp_path / "bootstrap.env"
    script_dir = tmp_path / "script_dir"
    script_dir.mkdir()

    fake_python = runtime_base / ".venv" / "bin" / "python"
    marker = tmp_path / "onnxruntime_installed.marker"
    install_fails_marker = tmp_path / "onnxruntime_install_should_fail"
    if not onnxruntime_install_succeeds:
        install_fails_marker.write_text("1", encoding="utf-8")
    if pre_status_reason is not None or ffmpeg_missing:
        # Isolate the whitelist-gap question from onnxruntime timing
        # entirely: onnxruntime is already present from the start, so the
        # only sticky failure in play is the injected pre_status_reason (or,
        # for ffmpeg_missing, whatever the real FFmpeg-discovery loop itself
        # records) -- not the documented, harmless "first assertion
        # transiently observes onnxruntime missing" race that would
        # otherwise win set_status()'s sticky-first-wins and mask it.
        marker.write_text("1", encoding="utf-8")

    # A fake VENV_PY that intercepts every invocation style the real
    # functions above actually use (argv -c checks, `-` heredoc probes
    # sniffed by content, and `-m pip ...`), so the real shell control
    # flow runs completely unmodified while only the Python-side truth of
    # "is onnxruntime importable yet" is faked via a marker file.
    fake_python.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/sh
            MARKER="{marker}"
            FAIL_MARKER="{install_fails_marker}"
            case "$1" in
              -c)
                case "$2" in
                  *"import onnxruntime"*)
                    if [ -f "$MARKER" ]; then
                      echo "1.27.0"
                      exit 0
                    fi
                    exit 1
                    ;;
                  *)
                    exit 0
                    ;;
                esac
                ;;
              -m)
                if [ "$2" = "pip" ]; then
                  case "$*" in
                    *"onnxruntime=="*)
                      if [ -f "$FAIL_MARKER" ]; then
                        echo "simulated offline install failure" >&2
                        exit 1
                      fi
                      : > "$MARKER"
                      exit 0
                      ;;
                    *)
                      exit 0
                      ;;
                  esac
                fi
                exit 0
                ;;
              -)
                _body="$(cat)"
                case "$_body" in
                  *expected_onnxruntime*)
                    # assert_pinned_torch_stack's real probe: report every
                    # other pinned package as already-satisfied, and
                    # onnxruntime according to the marker file -- exactly
                    # mirroring the real probe's ok|... / bad|...;failures=...
                    # output contract.
                    if [ -f "$MARKER" ]; then
                      echo "ok|profile=test; mac_arch=arm64; numpy=1.26.4; numba=0.59.1; llvmlite=0.42.0; torch=2.5.1; torchvision=0.20.1; torchaudio=2.5.1; audio-separator=0.23.0; onnxruntime=1.27.0; mps_built=True; mps_available=True"
                    else
                      echo "bad|profile=test; failures=onnxruntime import failed: No module named 'onnxruntime'; onnxruntime: expected 1.27.0, got missing; mac_arch=arm64"
                    fi
                    ;;
                  *'"numpy"'*|*expected\\ =*)
                    echo "ok"
                    ;;
                  *"MACOS_ARCH_GUARD"*)
                    echo "MACOS_ARCH_GUARD status=ok"
                    ;;
                  *"audio_separator"*)
                    echo "ok"
                    ;;
                  *)
                    echo "ok"
                    ;;
                esac
                exit 0
                ;;
              *)
                exit 0
                ;;
            esac
            """
        ),
        encoding="utf-8",
    )
    fake_python.chmod(0o755)
    fake_ffmpeg = tmp_path / "ffmpeg pair" / "ffmpeg"
    if not ffmpeg_missing:
        fake_ffmpeg.parent.mkdir()
        fake_ffprobe = fake_ffmpeg.parent / "ffprobe"
        # validate_ffmpeg_pair() only accepts a candidate whose `-version`
        # first line matches "ffmpeg version *" / "ffprobe version *"
        # (STEMwerk_Bootstrap_macOS.sh's ffmpeg_identity_mismatch check) --
        # the fixtures must actually satisfy that, not just exist.
        for tool, version_line in (
            (fake_ffmpeg, "ffmpeg version 6.0-fixture Copyright (c) fixture"),
            (fake_ffprobe, "ffprobe version 6.0-fixture Copyright (c) fixture"),
        ):
            tool.write_text(f"#!/bin/sh\necho '{version_line}'\nexit 0\n", encoding="utf-8")
            tool.chmod(0o755)

    if ffmpeg_missing:
        _bundled_ffmpeg_stub_body = "return 1"
    else:
        _bundled_ffmpeg_stub_body = "printf '%s\\n' '" + str(fake_ffmpeg) + "'"

    harness = tmp_path / "harness.sh"
    harness.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/sh
            set -u
            RUNTIME_BASE="{runtime_base}"
            LOG_FILE="{log_file}"
            STATE_FILE="{state_file}"
            SCRIPT_DIR="{script_dir}"
            MACOS_CONSTRAINTS_FILE="{script_dir}/constraints/macos.txt"
            PACKAGE="audio-separator"
            MAC_ARCH="x86_64"
            PINNED_NUMPY_VERSION="1.26.4"
            PINNED_NUMBA_VERSION="0.59.1"
            PINNED_LLVMLITE_VERSION="0.42.0"
            PINNED_AUDIO_SEPARATOR_VERSION="0.23.0"
            PINNED_SAMPLERATE_VERSION="0.1.0"
            PINNED_ONNXRUNTIME_VERSION="1.27.0"
            PINNED_TORCH_VERSION="2.5.1"
            PINNED_TORCHVISION_VERSION="0.20.1"
            PINNED_TORCHAUDIO_VERSION="2.5.1"
            PINNED_TORCH_STACK_LABEL="apple-silicon"
            BUNDLED_WHEELS_DIR=""
            MANAGED_WHEELS_DIR=""
            TORCH_PIN_APPLIED="0"
            FFMPEG="{"" if ffmpeg_missing else fake_ffmpeg}"
            FFPROBE="{"" if ffmpeg_missing else fake_ffmpeg.parent / 'ffprobe'}"
            FFMPEG_VALIDATED="{"no" if ffmpeg_missing else "yes"}"
            FFMPEG_VALIDATION_REASON="{"" if ffmpeg_missing else "ffmpeg_pair_valid"}"
            VENV_PY=""
            STATUS="{"deps_failed" if pre_status_reason is not None else "ok"}"
            STATUS_REASON="{pre_status_reason or ""}"
            STEP_INDEX=""
            STEP_TOTAL="6"
            STEP_LABEL=""
            PROFILE=""
            BACKEND=""
            BACKEND_REASON=""
            AUDIO_SEPARATOR_IMPORT="unknown"
            AUDIO_SEPARATOR_DEPS_COMPLETE="unknown"
            BACKEND_DEPS_COMPLETE="unknown"
            BACKEND_DEPS_REASON=""
            SAMPLERATE_VERSION=""
            SAMPLERATE_MODULE_PATH=""
            SAMPLERATE_DYLIB_PATH=""
            SAMPLERATE_DYLIB_ARCH=""
            SAMPLERATE_PLATFORM_MACHINE=""
            SAMPLERATE_SYSCONFIG_PLATFORM=""
            SAMPLERATE_ARCH_MATCH=""
            SAMPLERATE_REPAIR_ATTEMPTED="no"
            BUILD_TOOLS_MISSING="no"
            PYTHON="{fake_python}"
            SELECTED_PYTHON_VERSION="3.12.13"
            FIRST_UNSUPPORTED_PYTHON_PATH=""
            FIRST_UNSUPPORTED_PYTHON_VERSION=""
            MANAGED_PYTHON_ERROR=""
            STEMWERK_INSTALLER=""
            MANAGED_PYTHON_ENABLED="no"
            MANAGED_PYTHON_STATUS=""
            MANAGED_PYTHON_VERSION=""
            MANAGED_PYTHON_RELEASE=""
            MANAGED_PYTHON_PLATFORM=""
            MANAGED_PYTHON_ARCH=""
            MANAGED_PYTHON_URL=""
            MANAGED_PYTHON_SHA256_OK=""
            MANAGED_PYTHON_PATH=""
            MANAGED_PYTHON_REPLACED=""
            MANAGED_PYTHON_ROLLBACK=""
            SYSTEM_PYTHON_PATH=""
            SYSTEM_PYTHON_VERSION=""
            SYSTEM_PYTHON_USED="no"
            MACOS_BUNDLED_PAYLOAD_STATUS="present"
            MACOS_BUNDLED_FFMPEG_STATUS="ok"
            MACOS_BUNDLED_WHEELHOUSE_STATUS="ok"
            MACOS_BUNDLED_MODELS_STATUS=""
            MACOS_BUNDLED_DRUMSEP_STATUS=""
            MACOS_MANAGED_WHEELHOUSE_STATUS=""
            MACOS_ONNXRUNTIME_PIN="1.27.0"
            MACOS_ARCH_GUARD_STATUS=""
            MACOS_ARCH_GUARD_DETAIL=""
            MACOS_PAYLOAD_PREFLIGHT_STATUS=""
            MACOS_PAYLOAD_PREFLIGHT_REASON=""
            MACOS_PAYLOAD_PREFLIGHT_WHEELHOUSE=""
            MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED=""
            MACOS_RUNTIME_POLICY_STATUS=""
            MACOS_RUNTIME_POLICY_REASON=""
            MACOS_RUNTIME_POLICY_OBSERVED=""
            MACOS_RUNTIME_POLICY_MUTATION_STARTED=""

            {funcs}

            # These must be defined AFTER {{funcs}}, not before: bundled_ffmpeg_path
            # is both stubbed here AND present in _FUNCTIONS (its real body is
            # part of the driver's own candidate-discovery flow), and shell
            # allows silent function redefinition -- whichever definition comes
            # LAST wins. Defining the intended fakes last ensures they always
            # take effect instead of being silently shadowed by the real
            # extracted bundled_ffmpeg_path() (which needs BUNDLED_PAYLOAD_DIR,
            # unset here, and would fail under `set -u`).
            resolve_core_target() {{ CORE_TARGET="stub"; CORE_TARGET_DESC="stub"; return 0; }}
            install_stemwerk_core_target() {{ return 0; }}
            log_final_dependency_versions() {{ :; }}
            bundled_ffmpeg_path() {{ {_bundled_ffmpeg_stub_body}; }}
            command_path() {{ return 1; }}

            {driver}

            printf 'FINAL_STATUS=%s\\n' "${{STATUS}}"
            printf 'FINAL_STATUS_REASON=%s\\n' "${{STATUS_REASON}}"
            printf 'FINAL_RUNTIME_VERIFIED=%s\\n' "${{FINAL_RUNTIME_VERIFIED:-}}"
            """
        ),
        encoding="utf-8",
    )
    harness.chmod(0o755)
    return harness


def _run(harness: Path) -> subprocess.CompletedProcess:
    return subprocess.run([SH, str(harness)], text=True, capture_output=True, timeout=30)


def _parse(stdout: str) -> dict:
    out = {}
    for line in stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
    return out


def test_first_assertion_transiently_observes_onnxruntime_missing(tmp_path: Path):
    """Proves the documented ordering: on a fresh venv, the FIRST
    assert_pinned_torch_stack call (before onnxruntime install) always
    fails on 'onnxruntime missing' -- this is expected/by-design, not the
    bug itself."""
    harness = _build_harness(tmp_path, onnxruntime_install_succeeds=True)
    result = _run(harness)
    assert result.returncode == 0, result.stdout + result.stderr
    log_text = (tmp_path / "bootstrap.log").read_text(encoding="utf-8")
    assert "onnxruntime import failed: No module named 'onnxruntime'" in log_text
    assert "onnxruntime: expected 1.27.0, got missing" in log_text


def test_clean_first_run_self_heals_when_onnxruntime_install_succeeds(tmp_path: Path):
    """A: the exact documented scenario -- onnxruntime is genuinely
    installed by the remediation step between the two assertions. The
    final STATUS must be ok, not left stuck on the transient first-assert
    failure, on a SINGLE automatic run (no manual Repair needed)."""
    harness = _build_harness(tmp_path, onnxruntime_install_succeeds=True)
    result = _run(harness)
    assert result.returncode == 0, result.stdout + result.stderr
    parsed = _parse(result.stdout)
    assert parsed.get("FINAL_RUNTIME_VERIFIED") == "yes", result.stdout
    assert parsed.get("FINAL_STATUS") == "ok", (
        "clean first-run bootstrap did not self-heal after onnxruntime was "
        f"successfully installed by its own remediation step: {parsed}"
    )


def test_stale_status_not_whitelisted_survives_successful_final_verification(tmp_path: Path):
    """Proves the real structural gap: a sticky STATUS_REASON recorded
    earlier in the run for a reason OTHER than the three whitelisted
    torch/onnxruntime strings (here: audio_separator_install_failed, a
    real, existing set_status() reason elsewhere in this same script) is
    NEVER cleared, even though the exact same final verification block
    that clears the whitelisted three already proved FINAL_RUNTIME_
    VERIFIED=yes. This is the "failed intermediate STATUS persisting
    after later recovery" defect -- present regardless of which specific
    transient reason a real run happens to hit first."""
    harness = _build_harness(
        tmp_path,
        onnxruntime_install_succeeds=True,
        pre_status_reason="audio_separator_install_failed",
    )
    result = _run(harness)
    assert result.returncode == 0, result.stdout + result.stderr
    parsed = _parse(result.stdout)
    assert parsed.get("FINAL_RUNTIME_VERIFIED") == "yes", result.stdout
    assert parsed.get("FINAL_STATUS") == "ok", (
        "a stale, already-superseded STATUS_REASON not covered by the "
        "clearing whitelist survived a fully successful final runtime "
        f"verification: {parsed}"
    )


def test_real_onnxruntime_install_failure_still_truthfully_fails(tmp_path: Path):
    """C: if the remediation step genuinely fails (e.g. truly missing
    from the offline wheelhouse), the final STATUS must still truthfully
    report failure -- never a false success."""
    harness = _build_harness(tmp_path, onnxruntime_install_succeeds=False)
    result = _run(harness)
    assert result.returncode == 0, result.stdout + result.stderr
    parsed = _parse(result.stdout)
    assert parsed.get("FINAL_RUNTIME_VERIFIED") == "no", result.stdout
    assert parsed.get("FINAL_STATUS") != "ok", (
        f"a genuine onnxruntime install failure was falsely reported as healthy: {parsed}"
    )


def test_missing_ffmpeg_status_survives_successful_final_runtime_verification(tmp_path: Path):
    """Issue #111 (flarkflarkflark/STEMwerk-reaper): a genuinely offline,
    managed-wheelhouse install where FFmpeg is undiscoverable anywhere (no
    bundled payload, nothing at any Homebrew/MacPorts/system path, nothing
    on PATH) hits the script's real FFmpeg-discovery loop, which records a
    sticky STATUS=missing_ffmpeg/ffmpeg_not_found via set_status(). The
    final runtime verification block re-checks numba/samplerate/
    audio_separator/onnxruntime/stemwerk_core/the pinned torch stack --
    none of which say anything about FFmpeg -- and must NOT be allowed to
    clear this sticky status to "ok" on that basis alone. This is the exact
    reported crash: bootstrap reports healthy while
    ensure_core_model_cache() goes on to instantiate
    audio_separator.Separator(...) without FFmpeg, raising an uncaught
    FileNotFoundError deep in setup instead of surfacing the real,
    already-known cause."""
    harness = _build_harness(tmp_path, onnxruntime_install_succeeds=True, ffmpeg_missing=True)
    result = _run(harness)
    assert result.returncode == 0, result.stdout + result.stderr
    parsed = _parse(result.stdout)
    assert parsed.get("FINAL_RUNTIME_VERIFIED") == "yes", result.stdout
    log_text = (tmp_path / "bootstrap.log").read_text(encoding="utf-8")
    assert "Cleared stale STATUS" not in log_text, (
        "a sticky missing_ffmpeg status was cleared by the final runtime "
        f"verification whitelist despite FFmpeg still being undiscoverable: {log_text}"
    )
    assert parsed.get("FINAL_STATUS") == "missing_ffmpeg", (
        "a genuinely missing FFmpeg was not truthfully reported as a sticky "
        f"failure after a fully successful final runtime verification: {parsed}"
    )
    assert parsed.get("FINAL_STATUS_REASON") == "ffmpeg_not_found", parsed
