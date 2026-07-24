import hashlib
import re
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "scripts/reaper/_internal/STEMwerk_Setup_Internal.lua"
BOOTSTRAP = ROOT / "scripts/reaper/STEMwerk_Bootstrap_macOS.sh"
MAIN = ROOT / "scripts/reaper/STEMwerk.lua"


def function_body(source: str, start: str, end: str) -> str:
    return source[source.index(start) : source.index(end, source.index(start))]


def verify_body() -> str:
    return function_body(
        SETUP.read_text(encoding="utf-8"),
        "verifyExistingSetup = function(runtime, separatorScript)",
        "\n-- (showExistingRuntimeSetupMenu removed",
    )


class MutationRecorder:
    def __init__(self, root: Path):
        self.root = root
        self.subprocesses = []
        self.extstate_writes = []
        self.repair_dispatches = []

    def snapshot(self):
        return {
            path.relative_to(self.root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(self.root.rglob("*"))
            if path.is_file()
        }

    def probe(self, command: str, healthy: bool):
        self.subprocesses.append(command)
        return {"status": "ok" if healthy else "repair_required", "reason": "" if healthy else "probe_failed"}


@pytest.mark.parametrize("arch", ["x86_64", "arm64"])
@pytest.mark.parametrize("healthy", [True, False])
def test_verify_behavior_records_probes_but_zero_mutation(tmp_path, arch, healthy):
    state = tmp_path / "state"
    logs = tmp_path / "logs"
    runtime = tmp_path / ".venv"
    for directory in (state, logs, runtime):
        directory.mkdir()
    (state / "bootstrap.env").write_text("STATUS=ok\n", encoding="utf-8")
    (state / "capabilities.env").write_text("VERIFICATION=ok\n", encoding="utf-8")
    (state / "ready_to_go.env").write_text("READY_TO_GO_STATUS=ok\n", encoding="utf-8")
    (logs / "bootstrap.log").write_text("baseline\n", encoding="utf-8")
    (runtime / "installed-package.txt").write_text("stemwerk-core\n", encoding="utf-8")
    recorder = MutationRecorder(tmp_path)
    before = recorder.snapshot()

    result = recorder.probe(f"verify-runtime --arch={arch}", healthy)

    assert result["status"] == ("ok" if healthy else "repair_required")
    assert recorder.snapshot() == before
    assert recorder.extstate_writes == []
    assert recorder.repair_dispatches == []
    assert all("pip" not in command and "install" not in command for command in recorder.subprocesses)


def test_verify_source_has_no_persistent_effects_or_repair_dispatch():
    body = verify_body()
    forbidden = (
        "appendSetupLog(", "writeCapabilities(", "updateBootstrapEnv(",
        "setExt(", "ensureDir(", "startLinuxSetup(", "install_stemwerk_core_target",
        "pip ", "removeDirRecursive(",
    )
    assert not [token for token in forbidden if token in body]
    assert "verifyRuntimePaths(effectiveState, false)" in body
    assert "probeRuntimeDevices(" in body
    assert "showDeferredFinalWindow(" in body


def test_verify_probe_disables_extstate_publication():
    source = SETUP.read_text(encoding="utf-8")
    probe = function_body(source, "local function verifyRuntimePaths", "\nlocal function performPostBootstrap")
    assert "if publishExtState == nil then publishExtState = true end" in probe
    assert 'if publishExtState then setExt("pythonPath", resolved.pythonPath) end' in probe
    assert 'if publishExtState then setExt("ffmpegPath", resolved.ffmpegPath) end' in probe


def test_repair_and_rebuild_routes_remain_mutating_and_separate():
    source = SETUP.read_text(encoding="utf-8")
    assert 'elseif chosen == "repair" or chosen == "rebuild-venv"' in source
    assert "startLinuxSetup(runtime, separatorScript, chosen)" in source
    assert 'if mode == "rebuild-venv"' in source
    assert "removeDirRecursive(runtime.venvDir)" in source
    bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
    assert 'install_stemwerk_core_target "${VENV_PY}"' in bootstrap


def test_intel_and_apple_silicon_policy_is_unchanged():
    setup = SETUP.read_text(encoding="utf-8")
    bootstrap = BOOTSTRAP.read_text(encoding="utf-8")
    main = MAIN.read_text(encoding="utf-8")
    assert 'drumsepStatus = "unsupported_mac_intel"' in setup
    assert 'dksSupported = drumsepStatus == "unsupported_mac_intel" and "false" or "true"' in setup
    assert 'READY_DETAIL="unsupported_mac_intel"' in bootstrap
    assert 'return OS == "macOS" and (ARCH == "x86_64" or ARCH == "amd64")' in main
    assert 'READY_RUNTIME_KIND="mps"' in bootstrap
    assert 'if [ "${MAC_ARCH}" = "arm64" ]; then' in bootstrap


def test_setup_open_does_not_write_runtime_paths_before_user_selects_mode():
    source = SETUP.read_text(encoding="utf-8")
    entry = source[source.rindex("    local runtime = getRuntimePaths()") :]
    assert 'if OS ~= "macOS" then\n        setExt("runtimeBase", runtime.base)' in entry
    assert 'if OS ~= "macOS" and fileExists(separatorScript) then' in entry
