"""Output helpers shared by the Core command-line interfaces.

A CLI writes one JSON document to stdout or stderr and keeps the exit code of
its operation even when the reader of a stream has gone away (closed-stream
handling of slice S0). Moved here unchanged from ``asset_materialization``.
"""

from __future__ import annotations

import errno
import os
import sys
from typing import Any


def _is_closed_stream_error(exc: BaseException, *, windows: bool | None = None) -> bool:
    # The reader of a CLI stream went away. Windows can report a closed pipe as
    # EINVAL; elsewhere EINVAL means something else and is not treated as closed.
    if isinstance(exc, BrokenPipeError):
        return True
    if windows is None:
        windows = os.name == "nt"
    return windows and isinstance(exc, OSError) and exc.errno == errno.EINVAL


def _discard_closed_stream(stream: Any) -> None:
    # Python's documented pattern for a closed pipe: point the descriptor at
    # os.devnull so the interpreter's final flush stays silent.
    try:
        fd = stream.fileno()
    except (AttributeError, OSError, ValueError):
        return
    devnull = os.open(os.devnull, os.O_WRONLY)
    try:
        os.dup2(devnull, fd)
    finally:
        os.close(devnull)


def _flush_cli_stream(stream: Any) -> None:
    try:
        stream.flush()
    except OSError as exc:
        if _is_closed_stream_error(exc):
            _discard_closed_stream(stream)
        # Any other error leaves the output buffered, so the interpreter's
        # final flush reports it as it did before.


def _flush_cli_streams() -> None:
    _flush_cli_stream(sys.stdout)
    _flush_cli_stream(sys.stderr)


def _write_cli_document(text: str, stream: Any) -> None:
    """Write one CLI output document; a closed reader never changes the exit code."""

    try:
        print(text, file=stream)
    except OSError as exc:
        if not _is_closed_stream_error(exc):
            raise
        _discard_closed_stream(stream)
        return
    _flush_cli_stream(stream)
