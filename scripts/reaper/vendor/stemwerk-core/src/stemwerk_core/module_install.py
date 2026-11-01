"""Core module CLI: describe the installation contract, verify a module.

    python -I -B -m stemwerk_core.module_install --describe
    python -I -B -m stemwerk_core.module_install verify --module drum_kit

Both are read-only. Output follows the Core CLI contract: one JSON document
on stdout and exit 0 on success; a handled failure prints a versioned error
document on stderr and exits 2; any other ``Exception`` becomes an
``internal_error`` document on stderr with exit 3 and only the exception
type in its message; ``BaseException``s propagate. Every computed
installation state, including ``not_installed`` and ``repair_required``, is
a successful verification (exit 0). JSON on the streams is ASCII-only, so it
reads the same on any console or pipe code page. A reader that closes a stream
early does not change the exit code.
"""

from __future__ import annotations

import argparse
from importlib import metadata
import json
import platform
import sys
from typing import Any, Dict, Optional, Sequence

from . import install_events, module_descriptors, module_verify
from ._cli_io import _flush_cli_streams, _write_cli_document


CONTRACT_VERSION = "1.0.0"
DESCRIBE_KIND = "stemwerk_install_capabilities"
DESCRIBE_SCHEMA_VERSION = "1.0.0"
ERROR_KIND = "stemwerk_module_install_error"
ERROR_SCHEMA_VERSION = "1.0.0"
DISTRIBUTION_NAME = "stemwerk-core"

# Operations this Core can perform. A front end hides any it does not know
# (design section 9); install, plan and cancel are added by the slices that
# build them.
OPERATIONS = ("verify",)
# Platforms of the first route (design section 10.3).
PLATFORMS = ("linux-x86_64", "darwin-arm64", "win-x86_64")


def current_platform(
    system_platform: Optional[str] = None, machine: Optional[str] = None
) -> Optional[str]:
    """This process's route platform, or ``None`` outside the route.

    Uses the architecture of the running interpreter, so an x86_64 process
    translated by Rosetta on Apple Silicon is not ``darwin-arm64``.
    """

    system_platform = sys.platform if system_platform is None else system_platform
    machine = (platform.machine() if machine is None else machine).lower()
    if system_platform.startswith("linux") and machine in {"x86_64", "amd64"}:
        return "linux-x86_64"
    if system_platform == "darwin" and machine == "arm64":
        return "darwin-arm64"
    if system_platform == "win32" and machine in {"amd64", "x86_64"}:
        return "win-x86_64"
    return None


def core_version() -> Optional[str]:
    """Installed ``stemwerk-core`` version, or ``None`` when run from source."""

    try:
        return metadata.version(DISTRIBUTION_NAME)
    except metadata.PackageNotFoundError:
        return None


def describe() -> Dict[str, Any]:
    """The ``--describe`` document (design section 9)."""

    return {
        "kind": DESCRIBE_KIND,
        "contract_version": CONTRACT_VERSION,
        "event_protocol": install_events.EVENT_PROTOCOL,
        "core_version": core_version(),
        "modules": sorted(module_descriptors.MODULE_DESCRIPTORS),
        "operations": list(OPERATIONS),
        "platforms": list(PLATFORMS),
        "current_platform": current_platform(),
        "schemas": {
            "describe": DESCRIBE_SCHEMA_VERSION,
            "verification": module_verify.SCHEMA_VERSION,
            "error": ERROR_SCHEMA_VERSION,
            "events": install_events.EVENT_PROTOCOL,
            "result": install_events.RESULT_PROTOCOL,
            "started": install_events.STARTED_PROTOCOL,
        },
    }


def _error_document(code: str, message: str, module: Optional[str]) -> Dict[str, Any]:
    return {
        "kind": ERROR_KIND,
        "schema_version": ERROR_SCHEMA_VERSION,
        "error": {"code": code, "message": message, "module": module},
    }


def _dumps(document: Dict[str, Any]) -> str:
    return json.dumps(
        document, sort_keys=True, ensure_ascii=True, allow_nan=False, separators=(",", ":")
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m stemwerk_core.module_install",
        description="Describe the Core installation contract or verify a module (read-only).",
    )
    parser.add_argument(
        "--describe", action="store_true", help="print the capabilities document"
    )
    commands = parser.add_subparsers(dest="command", metavar="COMMAND")
    verify = commands.add_parser("verify", help="verify a module's installation state")
    verify.add_argument("--module", required=True, help="module id, for example drum_kit")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = _parser()
    try:
        args = parser.parse_args(argv)
        if args.describe == (args.command is not None):
            parser.error("use either --describe or the verify command")
    finally:
        _flush_cli_streams()
    module = getattr(args, "module", None)
    if module is not None and module not in module_descriptors.MODULE_DESCRIPTORS:
        _write_cli_document(
            _dumps(_error_document("unknown_module", f"unknown module {module!r}", module)),
            sys.stderr,
        )
        return 2
    try:
        document = describe() if args.describe else module_verify.verify_module(module)
    except Exception as exc:
        _write_cli_document(
            _dumps(
                _error_document(
                    "internal_error", f"unexpected internal error ({type(exc).__name__})", module
                )
            ),
            sys.stderr,
        )
        return 3
    _write_cli_document(_dumps(document), sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
