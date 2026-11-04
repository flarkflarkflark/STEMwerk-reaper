"""Tests for the read-only module CLI and the shared CLI output helpers."""
from __future__ import annotations

import errno
from importlib import metadata
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import _cli_io  # noqa: E402
from stemwerk_core import asset_acquisition, asset_materialization, asset_preparation  # noqa: E402
from stemwerk_core import install_events, module_descriptors, module_install  # noqa: E402
from stemwerk_core import module_verify  # noqa: E402
from tests.cli_harness import (  # noqa: E402
    CLI_TIMEOUT,
    assert_quiet,
    child_env,
    run_cli,
    single_json_line,
)

pytestmark = pytest.mark.portable


@pytest.fixture(autouse=True)
def isolated_runtime_root(tmp_path, monkeypatch):
    """verify reads the install lock under <root>: never the real user's root."""

    root = tmp_path / "isolated-runtime-root"
    monkeypatch.setenv("STEMWERK_RUNTIME_ROOT", str(root))
    return root

CLI_MODULE = "stemwerk_core.module_install"
VERIFY = ["verify", "--module", "drum_kit"]
LEAKY_MESSAGE = "secret token https://example.invalid/boom"

# Child interpreter with the verification or describe step replaced.
# argv: core_src, mode, payload, target, CLI arguments...
CLI_CHILD = """
import json
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from stemwerk_core import module_install
from stemwerk_core import module_verify as mv

mode, payload, target = sys.argv[2], sys.argv[3], sys.argv[4]
if mode == "states":
    spec = json.loads(payload)

    def locate(self, module_id, component_id):
        path = spec["locate"].get(component_id)
        return None if path is None else mv.ComponentLocation(Path(path))

    def stub(component_class, reason):
        return lambda component, location: mv.ComponentVerdict(component_class, reason)

    mv.NoRegistryLookup.locate = locate
    mv.DEFAULT_VERIFIERS = {kind: stub(*verdict) for kind, verdict in spec["verifiers"].items()}
else:
    def fail(*args, **kwargs):
        if mode == "interrupt":
            raise KeyboardInterrupt
        error = RuntimeError(payload)
        if hasattr(error, "add_note"):
            error.add_note(payload)
        raise error

    if target == "verify":
        mv.verify_module = fail
    else:
        module_install.describe = fail
raise SystemExit(module_install.main(sys.argv[5:]))
"""


def run_child(mode, payload, target, arguments, *, closed=None):
    return run_cli(
        ["-c", CLI_CHILD, str(CORE_SRC), mode, payload, target, *arguments], closed=closed
    )


def run_module(arguments, *, closed=None):
    return run_cli(["-m", CLI_MODULE, *arguments], closed=closed)


# --- describe ------------------------------------------------------------------


def test_describe_document_matches_the_code():
    document = module_install.describe()
    assert document == {
        "kind": "stemwerk_install_capabilities",
        "contract_version": "1.0.0",
        "event_protocol": "stemwerk-install-events/1",
        "core_version": module_install.core_version(),
        "modules": ["drum_kit"],
        "operations": ["plan", "verify"],
        "platforms": ["linux-x86_64", "darwin-arm64", "win-x86_64"],
        "current_platform": module_install.current_platform(),
        "schemas": {
            "describe": "1.0.0",
            "verification": module_verify.SCHEMA_VERSION,
            "plan": "1.0.0",
            "error": "1.0.0",
            "events": install_events.EVENT_PROTOCOL,
            "result": install_events.RESULT_PROTOCOL,
            "started": install_events.STARTED_PROTOCOL,
        },
    }
    assert document["modules"] == sorted(module_descriptors.MODULE_DESCRIPTORS)
    assert document["current_platform"] in document["platforms"] + [None]


@pytest.mark.native_publication
def test_describe_shows_the_verification_schema_the_code_writes():
    assert module_install.describe()["schemas"]["verification"] == "1.1.0"
    assert module_verify.verify_module("drum_kit")["schema_version"] == "1.1.0"


def test_describe_lists_exactly_the_operations_the_cli_offers():
    parser = module_install._parser()
    commands = next(
        action for action in parser._actions if action.dest == "command"
    ).choices
    assert sorted(commands) == sorted(module_install.describe()["operations"])


@pytest.mark.parametrize(
    ("system_platform", "machine", "expected"),
    [
        ("linux", "x86_64", "linux-x86_64"),
        ("linux", "aarch64", None),
        ("darwin", "arm64", "darwin-arm64"),
        ("darwin", "x86_64", None),  # Intel Mac, or an x86_64 process under Rosetta
        ("win32", "AMD64", "win-x86_64"),
        ("win32", "ARM64", None),
        ("freebsd14", "amd64", None),
    ],
)
def test_current_platform(system_platform, machine, expected):
    assert module_install.current_platform(system_platform, machine) == expected


def test_core_version_is_null_without_distribution_metadata(monkeypatch):
    def missing(name):
        raise metadata.PackageNotFoundError(name)

    monkeypatch.setattr(module_install.metadata, "version", missing)
    assert module_install.core_version() is None
    assert module_install.describe()["core_version"] is None


@pytest.mark.native_publication
def test_cli_child_describe_is_deterministic_and_matches_the_library():
    first = run_module(["--describe"])
    second = run_module(["--describe"])
    assert first.returncode == 0
    assert first.stderr == b""
    assert first.stdout == second.stdout
    assert single_json_line(first.stdout) == module_install.describe()


@pytest.mark.native_publication
def test_cli_child_documented_isolated_entry_point_runs():
    # The design's entry is `python -I -B -m stemwerk_core.module_install`;
    # -I ignores PYTHONPATH, so the child adds Core's source itself.
    script = (
        "import runpy, sys; sys.path.insert(0, sys.argv[1]); "
        "sys.argv = ['module_install', '--describe']; "
        "runpy.run_module('stemwerk_core.module_install', run_name='__main__', alter_sys=True)"
    )
    result = run_cli(["-c", script, str(CORE_SRC)], isolated=True)
    assert result.returncode == 0
    assert single_json_line(result.stdout)["operations"] == ["plan", "verify"]


@pytest.mark.native_publication
def test_cli_plan_is_read_only_and_reports_the_consent_fingerprint(isolated_runtime_root):
    result = run_module(["plan", "--module", "drum_kit"])
    assert result.returncode == 0
    assert result.stderr == b""
    document = single_json_line(result.stdout)
    assert document["kind"] == "stemwerk_module_install_plan"
    assert document["schema_version"] == "1.0.0"
    assert document["preflight_result"] == "incomplete"
    assert "ready" not in document
    assert "actual_pinned_install_space" in document["incomplete"]
    assert len(document["fingerprint"]) == 64
    assert document["actions"]["root"] == str(isolated_runtime_root)
    assert not isolated_runtime_root.exists()


# --- verify --------------------------------------------------------------------


@pytest.mark.native_publication
def test_cli_child_real_verify_is_not_installed_with_exit_0():
    result = run_module(VERIFY)
    assert result.returncode == 0
    assert result.stderr == b""
    document = single_json_line(result.stdout)
    assert document == module_verify.verify_module("drum_kit")
    assert document["installation_state"] == "not_installed"
    assert document["lookup"] == "no_registry"


ALL_COMPONENTS = [c.component_id for c in module_descriptors.DIRECT_KIT.components]
PASS = ["present_passing", "stub_verified"]
STATE_SPECS = {
    "not_installed": ({}, {}),
    "partial": (["drumsep_assets"], {"asset": PASS}),
    "installed": (
        ALL_COMPONENTS,
        {"runtime": PASS, "ffmpeg": PASS, "asset": PASS, "activation": PASS},
    ),
    "repair_required": (["drumsep_assets"], {"asset": ["present_failing", "asset_integrity_mismatch"]}),
    "unknown": (["ffmpeg"], {}),
}


@pytest.mark.native_publication
@pytest.mark.parametrize("state", sorted(STATE_SPECS))
def test_cli_child_every_state_exits_0_with_the_document_on_stdout(tmp_path, state):
    located, verifiers = STATE_SPECS[state]
    spec = {
        "locate": {component_id: str(tmp_path / component_id) for component_id in located},
        "verifiers": verifiers,
    }
    result = run_child("states", json.dumps(spec), "verify", VERIFY)
    assert result.returncode == 0
    assert result.stderr == b""
    document = single_json_line(result.stdout)
    assert document["kind"] == "stemwerk_module_verification"
    assert document["installation_state"] == state


@pytest.mark.native_publication
@pytest.mark.parametrize(("arguments", "closed"), [(VERIFY, "stdout"), (["--describe"], "stdout")])
def test_cli_child_success_with_closed_stdout_keeps_exit_0(arguments, closed):
    result = run_module(arguments, closed=closed)
    assert result.returncode == 0
    assert result.stderr == b""


# --- handled errors and usage ----------------------------------------------------


@pytest.mark.native_publication
@pytest.mark.parametrize("closed", [None, "stderr"])
def test_cli_child_unknown_module_is_a_handled_error(closed):
    result = run_module(["verify", "--module", "vocals_hq"], closed=closed)
    assert result.returncode == 2
    assert result.stdout == b""
    if closed is None:
        assert_quiet(result.stderr)
        assert single_json_line(result.stderr) == {
            "kind": "stemwerk_module_install_error",
            "schema_version": "1.0.0",
            "error": {
                "code": "unknown_module",
                "message": "unknown module 'vocals_hq'",
                "module": "vocals_hq",
            },
        }


@pytest.mark.native_publication
@pytest.mark.parametrize(
    "arguments",
    [
        [],
        ["verify"],
        ["--describe", "verify", "--module", "drum_kit"],
        ["install", "--module", "drum_kit"],
        ["--frobnicate"],
    ],
)
def test_cli_child_usage_errors_exit_2_with_argparse_usage(arguments):
    result = run_module(arguments)
    assert result.returncode == 2
    assert result.stdout == b""
    assert result.stderr.startswith(b"usage:")
    assert_quiet(result.stderr)


@pytest.mark.native_publication
@pytest.mark.parametrize(
    ("arguments", "closed", "status"),
    [(["--help"], "stdout", 0), ([], "stderr", 2), (["verify"], "stderr", 2)],
)
def test_cli_child_argparse_output_with_a_closed_stream_keeps_its_status(arguments, closed, status):
    result = run_module(arguments, closed=closed)
    assert result.returncode == status
    assert (result.stderr if closed == "stdout" else result.stdout) == b""


# --- internal errors and interrupts ------------------------------------------------


@pytest.mark.native_publication
@pytest.mark.parametrize(("target", "arguments"), [("verify", VERIFY), ("describe", ["--describe"])])
def test_cli_child_internal_error_is_one_redacted_document(tmp_path, target, arguments):
    secret = f"{LEAKY_MESSAGE} {tmp_path / 'secret-root'}"
    result = run_child("internal", secret, target, arguments)
    assert result.returncode == 3
    assert result.stdout == b""
    assert_quiet(result.stderr)
    text = result.stderr.decode("utf-8")
    document = single_json_line(result.stderr)
    assert document["kind"] == "stemwerk_module_install_error"
    assert document["error"]["code"] == "internal_error"
    assert document["error"]["message"] == "unexpected internal error (RuntimeError)"
    assert document["error"]["module"] == ("drum_kit" if target == "verify" else None)
    for leaked in ("secret", "token", "example.invalid", "boom", str(tmp_path)):
        assert leaked not in text


@pytest.mark.native_publication
def test_cli_child_internal_error_with_stderr_closed_keeps_exit_3():
    result = run_child("internal", LEAKY_MESSAGE, "verify", VERIFY, closed="stderr")
    assert result.returncode == 3
    assert result.stdout == b""


@pytest.mark.native_publication
@pytest.mark.parametrize(("target", "arguments"), [("verify", VERIFY), ("describe", ["--describe"])])
def test_cli_child_keyboard_interrupt_is_not_converted(target, arguments):
    result = run_child("interrupt", "", target, arguments)
    assert result.returncode not in (0, 2, 3)
    assert result.stdout == b""
    assert b"KeyboardInterrupt" in result.stderr
    assert b"internal_error" not in result.stderr


def test_keyboard_interrupt_and_system_exit_propagate_in_process(monkeypatch, capsys):
    for raised in (KeyboardInterrupt(), SystemExit(7)):
        def fail(module_id, _raised=raised):
            raise _raised

        monkeypatch.setattr(module_install.module_verify, "verify_module", fail)
        with pytest.raises(type(raised)):
            module_install.main(VERIFY)
    captured = capsys.readouterr()
    assert (captured.out, captured.err) == ("", "")


@pytest.mark.skipif(not os.path.exists("/dev/full"), reason="requires /dev/full")
def test_cli_child_other_os_errors_keep_the_interpreter_report():
    # ENOSPC is not a closed reader (S0 decision D): the output stays buffered
    # and the interpreter's final flush reports it.
    with open("/dev/full", "wb") as full:
        result = subprocess.run(
            [sys.executable, "-B", "-m", CLI_MODULE, *VERIFY],
            env=child_env(),
            stdin=subprocess.DEVNULL,
            stdout=full,
            stderr=subprocess.PIPE,
            timeout=CLI_TIMEOUT,
        )
    assert result.returncode == 120
    assert result.stderr.startswith(b"Exception ignored")
    assert b"No space left on device" in result.stderr


# --- shared CLI output helpers (moved from asset_materialization) -------------------


def test_cli_helpers_have_one_implementation_shared_by_every_cli():
    for name in ("_flush_cli_streams", "_write_cli_document"):
        shared = getattr(_cli_io, name)
        assert shared.__module__ == "stemwerk_core._cli_io"
        for module in (asset_materialization, asset_acquisition, asset_preparation, module_install):
            assert getattr(module, name) is shared, (module.__name__, name)
    assert asset_materialization._is_closed_stream_error is _cli_io._is_closed_stream_error


@pytest.mark.parametrize(
    ("error", "windows", "closed"),
    [
        (BrokenPipeError(errno.EPIPE, "broken pipe"), False, True),
        (BrokenPipeError(errno.EPIPE, "broken pipe"), True, True),
        (OSError(errno.EINVAL, "invalid argument"), False, False),
        (OSError(errno.EINVAL, "invalid argument"), True, True),
        (OSError(errno.ENOSPC, "no space left"), True, False),
        (ValueError("not an OSError"), True, False),
    ],
)
def test_shared_closed_stream_classification(error, windows, closed):
    assert _cli_io._is_closed_stream_error(error, windows=windows) is closed


# --- shared test harness (review note F-1) -------------------------------------------


def test_child_env_has_exactly_one_pythonpath():
    base = {"PythonPath": "/elsewhere", "OTHER": "1"}
    windows = child_env(base, windows=True)
    assert sorted(windows) == ["OTHER", "PYTHONPATH"]
    assert windows["PYTHONPATH"] == str(CORE_SRC)
    posix = child_env({"PYTHONPATH": "/elsewhere", "PythonPath": "/x"}, windows=False)
    assert posix == {"PythonPath": "/x", "PYTHONPATH": str(CORE_SRC)}
    env = child_env()
    assert env["PYTHONPATH"] == str(CORE_SRC)
    if os.name == "nt":
        assert sum(name.upper() == "PYTHONPATH" for name in env) == 1
