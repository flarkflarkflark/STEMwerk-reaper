"""Regression coverage for GitHub issue #111's macOS FFmpeg failure chain."""

from __future__ import annotations

import os
import shutil
import subprocess
import textwrap
from pathlib import Path

import pytest

from tools import macos_ffmpeg


ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "scripts/reaper/STEMwerk_Bootstrap_macOS.sh"
SETUP_LUA = ROOT / "scripts/reaper/_internal/STEMwerk_Setup_Internal.lua"


def _function(text: str, name: str) -> str:
    start = text.index(f"{name}() {{")
    lines = text[start:].splitlines()
    depth = 0
    output: list[str] = []
    for line in lines:
        output.append(line)
        depth += line.count("{") - line.count("}")
        if depth == 0:
            break
    return "\n".join(output) + "\n"


def _make_tool(path: Path, *, exit_code: int = 0, version_name: str | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    output = f"{version_name or path.name} version fixture" if exit_code == 0 else "dyld: Library not loaded"
    path.write_text(f"#!/bin/sh\nprintf '%s\\n' '{output}' >&2\nexit {exit_code}\n", encoding="utf-8")
    path.chmod(0o755)


def _run_pair(tmp_path: Path, ffmpeg: Path) -> dict[str, str]:
    text = BOOTSTRAP.read_text(encoding="utf-8")
    tmp_path.mkdir(parents=True, exist_ok=True)
    harness = tmp_path / "pair.sh"
    harness.write_text(
        "#!/bin/sh\nset -u\nFFMPEG=''\nFFPROBE=''\nFFMPEG_VALIDATED=no\nFFMPEG_VALIDATION_REASON=not_checked\n"
        + _function(text, "validate_ffmpeg_pair")
        + f"validate_ffmpeg_pair '{ffmpeg}'\nrc=$?\n"
        + "printf 'RC=%s\\nREASON=%s\\nVALIDATED=%s\\nFFMPEG=%s\\nFFPROBE=%s\\n' "
          '"$rc" "$FFMPEG_VALIDATION_REASON" "$FFMPEG_VALIDATED" "$FFMPEG" "$FFPROBE"\n',
        encoding="utf-8",
    )
    harness.chmod(0o755)
    result = subprocess.run([str(harness)], capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stderr
    return dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)


def test_ffmpeg_missing_and_non_executable_are_not_healthy(tmp_path: Path) -> None:
    missing = _run_pair(tmp_path / "missing", tmp_path / "missing/ffmpeg")
    assert missing == {
        "RC": "1", "REASON": "ffmpeg_not_found", "VALIDATED": "no", "FFMPEG": "", "FFPROBE": ""
    }
    bad = tmp_path / "non executable/ffmpeg"
    bad.parent.mkdir(parents=True)
    bad.write_text("fixture", encoding="utf-8")
    state = _run_pair(tmp_path / "nonexec-run", bad)
    assert state["RC"] == "1"
    assert state["REASON"] == "ffmpeg_not_executable"
    assert state["VALIDATED"] == "no"


def test_ffmpeg_that_simulates_missing_dylib_is_not_healthy(tmp_path: Path) -> None:
    ffmpeg = tmp_path / "broken dylib/ffmpeg"
    _make_tool(ffmpeg, exit_code=134)
    _make_tool(ffmpeg.parent / "ffprobe")
    state = _run_pair(tmp_path / "run", ffmpeg)
    assert state["RC"] == "1"
    assert state["REASON"] == "ffmpeg_dependency_failed"
    assert state["VALIDATED"] == "no"


@pytest.mark.parametrize(
    "probe_setup,reason",
    [
        ("missing", "ffprobe_not_found"),
        ("nonexec", "ffprobe_not_executable"),
        ("broken", "ffprobe_dependency_failed"),
    ],
)
def test_ffprobe_must_exist_be_executable_and_run(tmp_path: Path, probe_setup: str, reason: str) -> None:
    ffmpeg = tmp_path / probe_setup / "ffmpeg"
    _make_tool(ffmpeg, version_name="ffmpeg")
    probe = ffmpeg.parent / "ffprobe"
    if probe_setup == "nonexec":
        probe.write_text("fixture", encoding="utf-8")
    elif probe_setup == "broken":
        _make_tool(probe, exit_code=134)
    state = _run_pair(tmp_path / f"run-{probe_setup}", ffmpeg)
    assert state["RC"] == "1"
    assert state["REASON"] == reason
    assert state["VALIDATED"] == "no"


def test_working_pair_and_paths_with_spaces_are_accepted(tmp_path: Path) -> None:
    ffmpeg = tmp_path / "Application Support/STEMwerk payload/ffmpeg"
    _make_tool(ffmpeg, version_name="ffmpeg")
    _make_tool(ffmpeg.parent / "ffprobe", version_name="ffprobe")
    state = _run_pair(tmp_path / "run", ffmpeg)
    assert state["RC"] == "0"
    assert state["REASON"] == "ffmpeg_pair_valid"
    assert state["VALIDATED"] == "yes"
    assert state["FFMPEG"] == str(ffmpeg)
    assert state["FFPROBE"] == str(ffmpeg.parent / "ffprobe")


@pytest.mark.parametrize(
    "ffmpeg_identity,ffprobe_identity,reason",
    [
        ("ffprobe", "ffmpeg", "ffmpeg_identity_mismatch"),
        ("not-a-tool", "ffprobe", "ffmpeg_identity_mismatch"),
        ("ffmpeg", "not-a-tool", "ffprobe_identity_mismatch"),
    ],
)
def test_pair_rejects_swapped_or_arbitrary_successful_executables(
    tmp_path: Path, ffmpeg_identity: str, ffprobe_identity: str, reason: str
) -> None:
    ffmpeg = tmp_path / "pair/ffmpeg"
    _make_tool(ffmpeg, version_name=ffmpeg_identity)
    _make_tool(ffmpeg.parent / "ffprobe", version_name=ffprobe_identity)
    state = _run_pair(tmp_path / "run", ffmpeg)
    assert state["RC"] == "1"
    assert state["REASON"] == reason
    assert state["VALIDATED"] == "no"


@pytest.mark.parametrize(
    "silent_tool,reason",
    [
        ("ffmpeg", "ffmpeg_identity_mismatch"),
        ("ffprobe", "ffprobe_identity_mismatch"),
    ],
)
def test_pair_rejects_successful_tool_with_completely_empty_output(
    tmp_path: Path, silent_tool: str, reason: str
) -> None:
    ffmpeg = tmp_path / "silent pair/ffmpeg"
    probe = ffmpeg.parent / "ffprobe"
    _make_tool(ffmpeg, version_name="ffmpeg")
    _make_tool(probe, version_name="ffprobe")
    silent = ffmpeg if silent_tool == "ffmpeg" else probe
    silent.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    silent.chmod(0o755)

    state = _run_pair(tmp_path / f"run-{silent_tool}", ffmpeg)
    assert state["RC"] == "1"
    assert state["REASON"] == reason
    assert state["VALIDATED"] == "no"


@pytest.mark.skipif(shutil.which("lua") is None, reason="Lua interpreter required for headless Setup UI coverage")
def test_actual_check_only_row_maps_ffmpeg_reasons_to_friendly_messages() -> None:
    result = subprocess.run(
        [shutil.which("lua") or "lua", "tests/support/run_setup_final_rows_headless.lua"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, f"headless Setup harness failed:\n{result.stdout}\n{result.stderr}"
    assert "PASS ffmpeg-reasons-are-friendly-in-actual-check-only-row" in result.stdout


@pytest.mark.parametrize(
    "setup,reason",
    [
        ("ffmpeg-missing", "ffmpeg_not_found"),
        ("ffmpeg-nonexec", "ffmpeg_not_executable"),
        ("ffprobe-missing", "ffprobe_not_found"),
        ("ffprobe-nonexec", "ffprobe_not_executable"),
        ("ffmpeg-identity", "ffmpeg_identity_mismatch"),
        ("ffprobe-identity", "ffprobe_identity_mismatch"),
    ],
)
def test_bundled_availability_preserves_concrete_pair_reason(
    tmp_path: Path, setup: str, reason: str
) -> None:
    bundled = tmp_path / "Application Support/STEMwerk/_bundled/macos/apple-silicon"
    (bundled / "wheels").mkdir(parents=True)
    (bundled / "python").mkdir()
    (bundled / "manifest.json").write_text("{}\n", encoding="utf-8")
    ffmpeg = bundled / "ffmpeg/ffmpeg"
    probe = ffmpeg.parent / "ffprobe"
    if setup != "ffmpeg-missing":
        if setup == "ffmpeg-nonexec":
            ffmpeg.parent.mkdir()
            ffmpeg.write_text("fixture\n", encoding="utf-8")
        else:
            _make_tool(ffmpeg, version_name="wrong" if setup == "ffmpeg-identity" else "ffmpeg")
    if setup not in {"ffmpeg-missing", "ffmpeg-nonexec", "ffprobe-missing"}:
        if setup == "ffprobe-nonexec":
            probe.write_text("fixture\n", encoding="utf-8")
        else:
            _make_tool(probe, version_name="wrong" if setup == "ffprobe-identity" else "ffprobe")
    shell = BOOTSTRAP.read_text(encoding="utf-8")
    harness = tmp_path / "bundled.sh"
    harness.write_text(
        "#!/bin/sh\nset -u\n"
        f"BUNDLED_PAYLOAD_DIR='{bundled}'\nMAC_ARCH=arm64\n"
        "FFMPEG=''\nFFPROBE=''\nFFMPEG_VALIDATED=no\nFFMPEG_VALIDATION_REASON=not_checked\n"
        + "".join(
            _function(shell, name)
            for name in (
                "bundled_ffmpeg_path", "validate_ffmpeg_pair",
                "bundled_ffmpeg_pair_works", "bundled_payload_available",
            )
        )
        + "bundled_payload_available\nrc=$?\n"
          "printf 'RC=%s\\nREASON=%s\\n' \"$rc\" \"$FFMPEG_VALIDATION_REASON\"\n",
        encoding="utf-8",
    )
    result = subprocess.run(["sh", str(harness)], capture_output=True, text=True, check=True)
    state = dict(line.split("=", 1) for line in result.stdout.splitlines())
    assert state == {"RC": "1", "REASON": reason}


@pytest.mark.parametrize(
    "present,expected",
    [
        ((), ("missing", "missing", "missing")),
        (("htdemucs.yaml", "955717e8-8726e21a.th"), ("ok", "missing", "missing")),
        ((
            "htdemucs.yaml", "955717e8-8726e21a.th", "htdemucs_ft.yaml",
            "f7e0c4bc-ba3fe64a.th", "d12395a8-e57c48e6.th", "92cfc3b6-ef3bcb9c.th",
            "04573f0d-f3cf25b2.th", "htdemucs_6s.yaml", "5c90dfd2-34c22ccb.th",
        ), ("ok", "ok", "ok")),
    ],
)
def test_empty_partial_and_complete_model_cache(tmp_path: Path, present: tuple[str, ...], expected: tuple[str, ...]) -> None:
    model_dir = tmp_path / "models"
    model_dir.mkdir()
    for name in present:
        (model_dir / name).touch()
    text = BOOTSTRAP.read_text(encoding="utf-8")
    script = tmp_path / "models.sh"
    script.write_text(
        "#!/bin/sh\n" + _function(text, "verify_core_model_cache")
        + f"verify_core_model_cache '{model_dir}'\n",
        encoding="utf-8",
    )
    result = subprocess.run(["sh", str(script)], capture_output=True, text=True, check=True)
    values = dict(line.split("=", 1) for line in result.stdout.splitlines())
    assert (values["fast"], values["quality"], values["sixstem"]) == expected


def test_prefetch_is_blocked_without_validated_ffmpeg_and_classifies_constructor_error(tmp_path: Path) -> None:
    text = BOOTSTRAP.read_text(encoding="utf-8")
    funcs = "".join(
        _function(text, name) for name in ("verify_core_model_cache", "validate_ffmpeg_pair", "ensure_core_model_cache")
    )
    model_dir = tmp_path / "models"
    fake_python = tmp_path / "python"
    marker = tmp_path / "python-started"
    fake_python.write_text(f"#!/bin/sh\n: > '{marker}'\necho 'check_ffmpeg_installed'\nexit 1\n", encoding="utf-8")
    fake_python.chmod(0o755)
    log = tmp_path / "bootstrap.log"
    harness = tmp_path / "prefetch.sh"
    harness.write_text(textwrap.dedent(f"""\
        #!/bin/sh
        set -u
        LOG_FILE='{log}'
        FFMPEG=''
        FFPROBE=''
        FFMPEG_VALIDATED=no
        FFMPEG_VALIDATION_REASON=not_checked
        CORE_MODEL_PREFETCH_REASON=''
        log() {{ printf '%s\\n' "$*" >> "$LOG_FILE"; }}
        {funcs}
        ensure_core_model_cache '{fake_python}' '{model_dir}'
        printf 'RC=%s\\nREASON=%s\\n' "$?" "$CORE_MODEL_PREFETCH_REASON"
    """), encoding="utf-8")
    state = subprocess.run(["sh", str(harness)], capture_output=True, text=True, check=True).stdout
    assert "RC=2" in state and "REASON=ffmpeg_not_found" in state
    assert not marker.exists(), "Separator/model prefetch must not start without FFmpeg"

    ffmpeg = tmp_path / "working pair/ffmpeg"
    _make_tool(ffmpeg, version_name="ffmpeg")
    _make_tool(ffmpeg.parent / "ffprobe", version_name="ffprobe")
    harness_text = harness.read_text(encoding="utf-8").replace("FFMPEG=''", f"FFMPEG='{ffmpeg}'").replace(
        "FFMPEG_VALIDATED=no", "FFMPEG_VALIDATED=yes"
    )
    harness.write_text(harness_text, encoding="utf-8")
    state = subprocess.run(["sh", str(harness)], capture_output=True, text=True, check=True).stdout
    assert "RC=2" in state and "REASON=ffmpeg_constructor_failed" in state

    fake_python.write_text(
        f"#!/bin/sh\n: > '{marker}'\necho 'HTTPS model download failed'\nexit 1\n", encoding="utf-8"
    )
    fake_python.chmod(0o755)
    state = subprocess.run(["sh", str(harness)], capture_output=True, text=True, check=True).stdout
    assert "RC=1" in state and "REASON=core_model_download_failed" in state


def test_readiness_and_repair_contracts_include_ffmpeg() -> None:
    shell = BOOTSTRAP.read_text(encoding="utf-8")
    ready = _function(shell, "write_ready_to_go_state")
    assert 'echo "FFMPEG_STATUS=${_ffmpeg_status}"' in ready
    assert '[ "${_ffmpeg_status}" != "ok" ]' in ready
    assert '[ "${_ffmpeg_status}" = "ok" ] && [ "${_main_runtime_status}" = "ok" ]' in ready
    assert 'RUNTIME_POLICY_MATCHED="yes"' in shell
    match_case = shell[shell.index("match\\|*)"):shell.index("mismatch\\|*)")]
    assert "exit 0" not in match_case
    assert 'if [ "${RUNTIME_POLICY_MATCHED}" != "yes" ]; then' in shell
    assert '[ "${FFMPEG_VALIDATED}" = "yes" ]' in shell
    assert "core_model_prefetch_blocked=" in shell


def test_readiness_stays_false_without_ffmpeg_even_with_complete_models(tmp_path: Path) -> None:
    shell = BOOTSTRAP.read_text(encoding="utf-8")
    funcs = "".join(
        _function(shell, name)
        for name in ("model_cache_dir", "ready_to_go_state_file", "verify_core_model_cache", "validate_ffmpeg_pair", "write_ready_to_go_state")
    )
    model_dir = tmp_path / "home/Library/Application Support/STEMwerk/models"
    model_dir.mkdir(parents=True)
    for name in (
        "htdemucs.yaml", "955717e8-8726e21a.th", "htdemucs_ft.yaml", "f7e0c4bc-ba3fe64a.th",
        "d12395a8-e57c48e6.th", "92cfc3b6-ef3bcb9c.th", "04573f0d-f3cf25b2.th",
        "htdemucs_6s.yaml", "5c90dfd2-34c22ccb.th",
    ):
        (model_dir / name).touch()
    runtime = tmp_path / "runtime"
    (runtime / "state").mkdir(parents=True)
    harness = tmp_path / "ready.sh"
    harness.write_text(textwrap.dedent(f"""\
        #!/bin/sh
        set -u
        HOME='{tmp_path / 'home'}'
        RUNTIME_BASE='{runtime}'
        MAC_ARCH=arm64
        FFMPEG=''
        FFPROBE=''
        FFMPEG_VALIDATED=no
        FFMPEG_VALIDATION_REASON=ffprobe_not_found
        {funcs}
        write_ready_to_go_state mps ok ok ok ok
    """), encoding="utf-8")
    subprocess.run(["sh", str(harness)], check=True)
    state = dict(
        line.split("=", 1)
        for line in (runtime / "state/ready_to_go.env").read_text(encoding="utf-8").splitlines()
    )
    assert state["FFMPEG_STATUS"] == "missing"
    assert state["FFMPEG_REASON"] == "ffprobe_not_found"
    assert state["READY_TO_GO_STATUS"] == "missing"
    assert state["NORMAL_STEMS_MODEL_READY"] == "no"
    assert state["DIRECT_KIT_READY"] == "no"
    assert state["KIT_SPLIT_READY"] == "no"


def test_reapack_and_bundled_routes_are_both_explicit_and_truthful() -> None:
    shell = BOOTSTRAP.read_text(encoding="utf-8")
    assert 'MACOS_PAYLOAD_PREFLIGHT_REASON="online_fallback"' in shell
    assert 'MACOS_BUNDLED_FFMPEG_STATUS="validation_failed"' in shell
    assert 'MACOS_BUNDLED_FFMPEG_STATUS="validated"' in shell
    assert '"$(bundled_ffmpeg_path || true)"' in shell
    assert '"${_path_ffmpeg}"' in shell
    lua = SETUP_LUA.read_text(encoding="utf-8")
    assert "function buildFfmpegCheckRow(verification, ffmpegPath)" in lua
    assert "buildFfmpegCheckRow(verification, ffmpegPath)" in lua


def test_official_source_recipe_is_redistributable_and_pinned() -> None:
    assert macos_ffmpeg.FFMPEG_SOURCE_URL.startswith("https://ffmpeg.org/releases/")
    assert len(macos_ffmpeg.FFMPEG_SOURCE_SHA256) == 64
    assert macos_ffmpeg.FFMPEG_LICENSE == "LGPL-2.1-or-later"
    source = Path(macos_ffmpeg.__file__).read_text(encoding="utf-8")
    assert '"--disable-autodetect"' in source
    assert '"--disable-shared"' in source
    assert "--enable-nonfree" not in macos_ffmpeg.FFMPEG_CONFIGURE_FLAGS
    assert "--enable-gpl" not in macos_ffmpeg.FFMPEG_CONFIGURE_FLAGS
    assert '("CONFIG_GPL", "CONFIG_NONFREE")' in source


def test_dependency_audit_rejects_homebrew_and_missing_relative_closure(tmp_path: Path, monkeypatch) -> None:
    binary = tmp_path / "ffmpeg"
    binary.write_bytes(b"fixture")
    monkeypatch.setattr(macos_ffmpeg, "macho_architectures", lambda _path: ("arm64",))
    monkeypatch.setattr(
        macos_ffmpeg, "macho_dependencies", lambda _path: ("/opt/homebrew/Cellar/ffmpeg/lib/libavcodec.dylib",)
    )
    with pytest.raises(RuntimeError, match="Forbidden package-manager dependency"):
        macos_ffmpeg.audit_macho_closure(binary)

    monkeypatch.setattr(macos_ffmpeg, "macho_dependencies", lambda _path: ("@loader_path/libmissing.dylib",))
    with pytest.raises(RuntimeError, match="Missing bundled Mach-O dependency"):
        macos_ffmpeg.audit_macho_closure(binary)
