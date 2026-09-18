"""Regression tests for the macOS Intel Direct Kit / Kit Split (DKS) blanket
architecture-policy removal.

Real-world context: Intel MacBook Pro 11,2 validation proved the main
runtime (Normal Stems Fast/htdemucs, 6-Stem) works end-to-end on Intel
macOS CPU, but Direct Kit / Kit Split were unconditionally rejected --
purely because MAC_ARCH == "x86_64" -- before any real provisioning/
readiness/preflight logic ever ran. Forensics found FOUR independent
architecture-only gates (the task's own brief named three; this slice's
investigation found a fourth, previously unflagged one):

  1. STEMwerk_Bootstrap_macOS.sh: the READY_* driver skipped
     ensure_drumsep_assets() entirely for x86_64, writing
     READY_DETAIL="unsupported_mac_intel" instead of ever attempting it.
  2. STEMwerk_Bootstrap_macOS.sh: write_ready_to_go_state() re-derived
     DRUMSEP_STATUS="unsupported_mac_intel"/DKS_SUPPORTED="false" from that
     same detail string, independent of any real readiness evidence.
  3. STEMwerk.lua: intelMacDksPolicyBlocked() -- gated button drawing,
     Direct Kit/Kit Split selection, and session restore.
  4. STEMwerk.lua: intelMacDrumsepUnsupported() -- a SEPARATE, duplicate
     gate in runSeparationWorkflow() that aborted the actual run even if
     (1)-(3) were somehow bypassed. Not named in the original forensics.
  5. STEMwerk_Setup_Internal.lua: resolveDrumsepPolicyState()'s fallback
     synthesized the same "unsupported_mac_intel" verdict from architecture
     alone whenever the cached ready_to_go state was blank/incomplete.

All five are removed/narrowed here. Real production logic is executed
directly wherever practical (real POSIX /bin/sh functions extracted
verbatim from the bootstrap script, real `lua` executing the actual policy
functions) rather than re-implemented or merely string-matched.
"""

from __future__ import annotations

import re
import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "scripts" / "reaper" / "STEMwerk_Bootstrap_macOS.sh"
MAIN_LUA = ROOT / "scripts" / "reaper" / "STEMwerk.lua"

SH = "/bin/sh"

_HEREDOC_START_RE = re.compile(r"<<-?\s*'?\"?([A-Za-z_][A-Za-z0-9_]*)'?\"?")


def _bootstrap_text() -> str:
    return BOOTSTRAP.read_text(encoding="utf-8")


def _function_body(text: str, name: str) -> str:
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


_WRITE_READY_STATE_FUNCTIONS = (
    "validate_ffmpeg_pair",
    "model_cache_dir",
    "ready_to_go_state_file",
    "verify_core_model_cache",
    "write_ready_to_go_state",
)


def _write_ready_state_funcs_src() -> str:
    text = _bootstrap_text()
    return "\n".join(_function_body(text, name) for name in _WRITE_READY_STATE_FUNCTIONS)


def _make_model_cache(model_dir: Path) -> None:
    model_dir.mkdir(parents=True, exist_ok=True)
    for name in (
        "htdemucs.yaml",
        "955717e8-8726e21a.th",
        "htdemucs_ft.yaml",
        "f7e0c4bc-ba3fe64a.th",
        "d12395a8-e57c48e6.th",
        "92cfc3b6-ef3bcb9c.th",
        "04573f0d-f3cf25b2.th",
        "htdemucs_6s.yaml",
        "5c90dfd2-34c22ccb.th",
    ):
        (model_dir / name).write_bytes(b"x")


def _make_ffmpeg_pair(tmp_path: Path) -> Path:
    ffmpeg_dir = tmp_path / "ffmpeg-pair"
    ffmpeg_dir.mkdir()
    ffmpeg = ffmpeg_dir / "ffmpeg"
    ffprobe = ffmpeg_dir / "ffprobe"
    for tool, version_line in (
        (ffmpeg, "ffmpeg version 6.0-fixture Copyright (c) fixture"),
        (ffprobe, "ffprobe version 6.0-fixture Copyright (c) fixture"),
    ):
        tool.write_text(f"#!/bin/sh\necho '{version_line}'\nexit 0\n", encoding="utf-8")
        tool.chmod(0o755)
    return ffmpeg


def _run_write_ready_to_go_state(
    tmp_path: Path,
    *,
    mac_arch: str,
    runtime_status: str,
    drumsep_model_status: str,
    main_runtime_status: str = "ok",
    detail: str = "ok",
    with_models: bool = True,
) -> dict[str, str]:
    home = tmp_path / "home"
    model_dir = home / "Library" / "Application Support" / "STEMwerk" / "models"
    if with_models:
        _make_model_cache(model_dir)
    else:
        model_dir.mkdir(parents=True)
    runtime_base = tmp_path / "runtime"
    (runtime_base / "state").mkdir(parents=True)
    ffmpeg = _make_ffmpeg_pair(tmp_path)

    script = "\n".join(
        [
            "#!/bin/sh",
            "set -eu",
            f'HOME="{home}"',
            f'MAC_ARCH="{mac_arch}"',
            f'RUNTIME_BASE="{runtime_base}"',
            f'FFMPEG="{ffmpeg}"',
            "log() { :; }",
            _write_ready_state_funcs_src(),
            f'write_ready_to_go_state "cpu" "{runtime_status}" "{drumsep_model_status}" "{detail}" "{main_runtime_status}"',
        ]
    )
    script_path = tmp_path / "driver.sh"
    script_path.write_text(script, encoding="utf-8")
    script_path.chmod(0o755)

    proc = subprocess.run([SH, str(script_path)], capture_output=True, text=True, check=False)
    assert proc.returncode == 0, proc.stderr

    state_file = runtime_base / "state" / "ready_to_go.env"
    result: dict[str, str] = {}
    for line in state_file.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            result[key] = value
    return result


# ---------------------------------------------------------------------------
# C. Successful mocked Intel CPU DrumSep readiness produces the same valid
#    supported/ready state the existing (arm64) workflow already produces --
#    no special-casing, no fake success.
# ---------------------------------------------------------------------------
def test_x86_64_real_readiness_produces_same_ready_state_as_arm64(tmp_path: Path) -> None:
    x86_64_result = _run_write_ready_to_go_state(
        tmp_path / "x86_64",
        mac_arch="x86_64",
        runtime_status="ok",
        drumsep_model_status="ok",
    )
    arm64_result = _run_write_ready_to_go_state(
        tmp_path / "arm64",
        mac_arch="arm64",
        runtime_status="ok",
        drumsep_model_status="ok",
    )

    for key in ("DRUMSEP_STATUS", "DKS_SUPPORTED", "DIRECT_KIT_READY", "KIT_SPLIT_READY", "READY_TO_GO_STATUS"):
        assert x86_64_result[key] == arm64_result[key] == (
            "ready" if key == "DRUMSEP_STATUS" else
            "true" if key == "DKS_SUPPORTED" else
            "yes" if key in ("DIRECT_KIT_READY", "KIT_SPLIT_READY") else
            "ok"
        ), f"{key}: x86_64={x86_64_result[key]!r} arm64={arm64_result[key]!r}"


# ---------------------------------------------------------------------------
# D. A genuine provisioning/preflight failure still reports failure/not-
#    ready on Intel -- it must not be converted into a fake success, and it
#    must not be mislabeled "unsupported_mac_intel" either (DKS remains
#    SUPPORTED on this architecture, just not currently ready).
# ---------------------------------------------------------------------------
def test_x86_64_genuine_preflight_failure_is_not_ready_and_not_fake_unsupported(tmp_path: Path) -> None:
    result = _run_write_ready_to_go_state(
        tmp_path,
        mac_arch="x86_64",
        runtime_status="missing",
        drumsep_model_status="missing",
        detail="drumsep_model_download_failed",
    )
    assert result["DRUMSEP_STATUS"] == "missing"
    assert result["DKS_SUPPORTED"] == "true"
    assert result["DIRECT_KIT_READY"] == "no"
    assert result["KIT_SPLIT_READY"] == "no"


# ---------------------------------------------------------------------------
# G. Apple-Silicon existing behavior is unchanged (explicit non-regression
#    check, independent of the parity check above).
# ---------------------------------------------------------------------------
def test_arm64_ready_state_derivation_unaffected(tmp_path: Path) -> None:
    ready = _run_write_ready_to_go_state(
        tmp_path / "ready",
        mac_arch="arm64",
        runtime_status="ok",
        drumsep_model_status="ok",
    )
    assert ready["DRUMSEP_STATUS"] == "ready"
    assert ready["DIRECT_KIT_READY"] == "yes"

    failed = _run_write_ready_to_go_state(
        tmp_path / "failed",
        mac_arch="arm64",
        runtime_status="missing",
        drumsep_model_status="missing",
    )
    assert failed["DRUMSEP_STATUS"] == "missing"
    assert failed["DIRECT_KIT_READY"] == "no"


# ---------------------------------------------------------------------------
# The removed bootstrap-level x86_64 special case no longer exists in
# write_ready_to_go_state()'s source at all (not just behaviorally dead).
# ---------------------------------------------------------------------------
def test_write_ready_to_go_state_source_has_no_arch_only_branch() -> None:
    script = _bootstrap_text()
    fn = _function_body(script, "write_ready_to_go_state")
    assert 'MAC_ARCH' not in fn
    assert 'unsupported_mac_intel' not in fn


# ---------------------------------------------------------------------------
# E / F / I. intelMacDksPolicyBlocked() / intelMacDrumsepUnsupported() no
# longer hide/block Direct Kit / Kit Split solely for OS=macOS,
# ARCH=x86_64 or ARCH=amd64 -- proven by executing the REAL extracted
# function bodies under a real `lua` interpreter, not by grepping for the
# old string. Also proves no Windows/Linux regression (both already
# returned false there; still do).
# ---------------------------------------------------------------------------
def _lua_function_body(text: str, signature: str) -> str:
    start = text.index(signature)
    end = text.index("\nend", start) + len("\nend")
    return text[start:end]


LUA = shutil.which("lua") or shutil.which("lua5.4") or shutil.which("lua5.3")


@pytest.mark.skipif(LUA is None, reason="Lua interpreter required for policy-function behavioral coverage")
@pytest.mark.parametrize(
    "os_value,arch_value,expect_blocked",
    [
        ("macOS", "x86_64", False),
        ("macOS", "amd64", False),
        ("macOS", "arm64", False),
        ("Windows", "x86_64", False),
        ("Linux", "x86_64", False),
    ],
)
def test_intel_mac_dks_policy_functions_never_block(tmp_path: Path, os_value: str, arch_value: str, expect_blocked: bool) -> None:
    main_text = MAIN_LUA.read_text(encoding="utf-8")
    policy_blocked_src = _lua_function_body(main_text, "function intelMacDksPolicyBlocked()")
    drumsep_unsupported_src = _lua_function_body(main_text, "local function intelMacDrumsepUnsupported()")

    script = textwrap.dedent(
        f"""
        OS = "{os_value}"
        ARCH = "{arch_value}"
        {policy_blocked_src}
        {drumsep_unsupported_src.replace("local function", "function", 1)}
        print("policy_blocked=" .. tostring(intelMacDksPolicyBlocked()))
        print("drumsep_unsupported=" .. tostring(intelMacDrumsepUnsupported()))
        """
    )
    script_path = tmp_path / "probe.lua"
    script_path.write_text(script, encoding="utf-8")
    proc = subprocess.run([LUA, str(script_path)], capture_output=True, text=True, check=False)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    lines = dict(line.split("=", 1) for line in proc.stdout.splitlines() if "=" in line)
    assert lines["policy_blocked"] == str(expect_blocked).lower()
    assert lines["drumsep_unsupported"] == str(expect_blocked).lower()


def test_intel_mac_dks_policy_functions_source_no_longer_checks_architecture() -> None:
    main_text = MAIN_LUA.read_text(encoding="utf-8")
    policy_blocked_src = _lua_function_body(main_text, "function intelMacDksPolicyBlocked()")
    drumsep_unsupported_src = _lua_function_body(main_text, "local function intelMacDrumsepUnsupported()")
    assert "ARCH" not in policy_blocked_src
    assert "x86_64" not in policy_blocked_src
    assert "ARCH" not in drumsep_unsupported_src
    assert "x86_64" not in drumsep_unsupported_src
    assert policy_blocked_src.strip().endswith("return false\nend")
    assert drumsep_unsupported_src.strip().endswith("return false\nend")


# ---------------------------------------------------------------------------
# The now-false "Drum Kit Split is not enabled on Intel Macs in this
# release" completion message is gone from the reachable Setup-complete
# message path.
# ---------------------------------------------------------------------------
def test_setup_internal_no_longer_claims_dks_unavailable_on_intel_completion() -> None:
    setup_internal = (ROOT / "scripts/reaper/_internal/STEMwerk_Setup_Internal.lua").read_text(encoding="utf-8")
    segment_start = setup_internal.index('finalMessage[#finalMessage + 1] = "Setup completed using Intel macOS CPU fallback."')
    segment_end = setup_internal.index("\n        end", segment_start)
    assert "Drum Kit Split is not enabled" not in setup_internal[segment_start:segment_end]


# ---------------------------------------------------------------------------
# H. resolveDrumsepPolicyState() no longer invents unsupported_mac_intel
# from architecture alone -- wired via the headless Lua harness that
# dofile()s the real STEMwerk_Setup_Internal.lua (established convention,
# see tests/support/run_setup_macos_ready_state_fallback_headless.lua).
# ---------------------------------------------------------------------------
@pytest.mark.skipif(LUA is None, reason="Lua interpreter required for Setup-Internal policy coverage")
def test_intel_dks_policy_removal_headless_lua_suite() -> None:
    result = subprocess.run(
        [LUA, "tests/support/run_intel_dks_policy_removal_headless.lua"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    for marker in (
        "PASS x86_64-blank-state-is-missing-not-unsupported",
        "PASS x86_64-real-readiness-produces-ready",
        "PASS x86_64-genuine-preflight-failure-stays-missing",
        "PASS x86_64-stale-literal-unsupported-value-still-honored",
        "PASS arm64-parity-unaffected",
        "All headless Intel DKS policy-removal tests passed.",
    ):
        assert marker in result.stdout, f"missing expected marker {marker!r} in:\n{result.stdout}"
