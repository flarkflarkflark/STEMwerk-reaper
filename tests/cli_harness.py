"""Real-subprocess harness shared by the Core CLI tests.

A CLI runs in its own interpreter with real pipes. A closed stream is a pipe
whose read end is closed before the child writes, so every write fails as it
does for a reader that went away early.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Mapping, Optional

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts/reaper/vendor/stemwerk-core/src"
CLI_TIMEOUT = 60


def child_env(
    base: Optional[Mapping[str, str]] = None, *, windows: Optional[bool] = None
) -> dict:
    """``base`` (default ``os.environ``) with exactly one PYTHONPATH: Core's source.

    Environment names are case-insensitive on Windows, so any spelling of
    PYTHONPATH is dropped there before the variable is set; elsewhere only the
    exact name is replaced.
    """

    base = os.environ if base is None else base
    windows = os.name == "nt" if windows is None else windows
    env = {
        name: value
        for name, value in base.items()
        if not (name.upper() == "PYTHONPATH" if windows else name == "PYTHONPATH")
    }
    env["PYTHONPATH"] = str(CORE_SRC)
    return env


def run_cli(
    arguments,
    *,
    closed: Optional[str] = None,
    isolated: bool = False,
    extra_env: Optional[Mapping[str, str]] = None,
):
    """Run ``python -B [arguments]``; ``closed`` names a stream to close early.

    ``isolated`` adds ``-I``: PYTHONPATH is then ignored, so callers must make
    Core importable themselves. ``extra_env`` adds or overrides variables.
    """

    streams = {"stdout": subprocess.PIPE, "stderr": subprocess.PIPE}
    write_end = None
    if closed is not None:
        read_end, write_end = os.pipe()
        os.close(read_end)
        streams[closed] = write_end
    flags = ["-I", "-B"] if isolated else ["-B"]
    try:
        return subprocess.run(
            [sys.executable, *flags, *arguments],
            env={**child_env(), **(extra_env or {})},
            stdin=subprocess.DEVNULL,
            timeout=CLI_TIMEOUT,
            **streams,
        )
    finally:
        if write_end is not None:
            os.close(write_end)


def assert_quiet(stream: bytes) -> None:
    assert b"Traceback" not in stream
    assert b"Exception ignored" not in stream


def single_json_line(stream: bytes):
    lines = stream.decode("utf-8").splitlines()
    assert len(lines) == 1, lines
    return json.loads(lines[0])
