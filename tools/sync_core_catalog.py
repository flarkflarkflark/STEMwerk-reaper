#!/usr/bin/env python3
"""Synchronize the packaged stemwerk_core catalog copy with the canonical source.

The canonical workflow/capability/model catalogs live at
``scripts/reaper/catalog/`` (shared by the production contract gates, the
Lua side, and the diagnostics harness). ``stemwerk_core.readiness`` must also
load them as package resources so the Core API works without a REAPER
installation or repository checkout, so a byte-identical copy is distributed
inside the package at
``scripts/reaper/vendor/stemwerk-core/src/stemwerk_core/catalog/``.

There is exactly one canonical source; the packaged copy is generated, never
edited independently. Use ``--write`` (default) after changing the canonical
catalogs and ``--check`` in CI to fail on drift. Comparison covers the
relative file set and byte content of every catalog JSON document, including
the contract schemas.
"""
from __future__ import annotations

import argparse
import filecmp
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CANONICAL_DIR = ROOT / "scripts" / "reaper" / "catalog"
PACKAGED_DIR = (
    ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src" / "stemwerk_core" / "catalog"
)


def _catalog_files(root: Path) -> list[Path]:
    if not root.is_dir():
        return []
    return sorted(path for path in root.rglob("*.json") if path.is_file())


def _relative_set(root: Path) -> list[str]:
    return [str(path.relative_to(root)) for path in _catalog_files(root)]


def collect_drift() -> list[str]:
    """Return human-readable drift descriptions (empty when in sync)."""

    drift: list[str] = []
    if not CANONICAL_DIR.is_dir():
        return [f"canonical catalog directory missing: {CANONICAL_DIR}"]
    canonical = _relative_set(CANONICAL_DIR)
    packaged = _relative_set(PACKAGED_DIR)
    for missing in sorted(set(canonical) - set(packaged)):
        drift.append(f"packaged copy missing: {missing}")
    for extra in sorted(set(packaged) - set(canonical)):
        drift.append(f"packaged copy has untracked file: {extra}")
    for relative in sorted(set(canonical) & set(packaged)):
        if not filecmp.cmp(CANONICAL_DIR / relative, PACKAGED_DIR / relative, shallow=False):
            drift.append(f"content drift: {relative}")
    return drift


def write() -> list[str]:
    """Regenerate the packaged copy from the canonical source. Returns the
    list of synced relative paths."""

    canonical = _catalog_files(CANONICAL_DIR)
    if not canonical:
        raise SystemExit(f"no catalog documents found under {CANONICAL_DIR}")
    for stale in sorted(set(_relative_set(PACKAGED_DIR)) - set(_relative_set(CANONICAL_DIR))):
        (PACKAGED_DIR / stale).unlink()
    synced: list[str] = []
    for source in canonical:
        relative = source.relative_to(CANONICAL_DIR)
        target = PACKAGED_DIR / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        synced.append(str(relative))
    return sorted(synced)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true", help="regenerate the packaged copy (default)")
    mode.add_argument("--check", action="store_true", help="fail if the packaged copy drifts")
    args = parser.parse_args(argv)

    if args.check:
        drift = collect_drift()
        if drift:
            for line in drift:
                print(f"DRIFT: {line}", file=sys.stderr)
            print(
                "packaged stemwerk_core catalog is out of sync; run: python3 tools/sync_core_catalog.py --write",
                file=sys.stderr,
            )
            return 1
        print("packaged stemwerk_core catalog is in sync")
        return 0

    synced = write()
    for relative in synced:
        print(f"synced: {relative}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
