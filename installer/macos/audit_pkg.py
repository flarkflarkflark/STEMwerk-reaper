#!/usr/bin/env python3
"""Fail-closed audit of a definitive flat macOS STEMwerk package."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
PAYLOAD_AUDITOR = REPO_ROOT / "installer/macos/audit_payload.py"
EXPECTED_PAYLOAD_ROOT = Path("Users/Shared/STEMwerk-reaper")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _inventory_contract(data: dict[str, object]) -> dict[str, tuple[object, ...]]:
    records = data.get("files")
    if not isinstance(records, list):
        raise RuntimeError("Payload inventory has no files list")
    result: dict[str, tuple[object, ...]] = {}
    for record in records:
        if not isinstance(record, dict) or not isinstance(record.get("path"), str):
            raise RuntimeError("Payload inventory contains an invalid record")
        path = record["path"]
        if path in result:
            raise RuntimeError(f"Duplicate inventory path: {path}")
        mode = record.get("mode")
        if not isinstance(mode, str) or re.fullmatch(r"[0-7]{4}", mode) is None:
            raise RuntimeError(f"Payload inventory record has no valid POSIX mode: {path}")
        result[path] = (
            record.get("type"), mode, record.get("size"), record.get("sha256"), record.get("link_target")
        )
    return result


def compare_inventories(expected: Path, actual: Path) -> None:
    expected_data = json.loads(expected.read_text(encoding="utf-8"))
    actual_data = json.loads(actual.read_text(encoding="utf-8"))
    expected_contract = _inventory_contract(expected_data)
    actual_contract = _inventory_contract(actual_data)
    if expected_contract != actual_contract:
        missing = sorted(expected_contract.keys() - actual_contract.keys())
        added = sorted(actual_contract.keys() - expected_contract.keys())
        changed = sorted(
            path for path in expected_contract.keys() & actual_contract.keys()
            if expected_contract[path] != actual_contract[path]
        )
        raise RuntimeError(
            "Final package payload differs from audited staging inventory: "
            f"missing={missing[:20]}, added={added[:20]}, changed={changed[:20]}"
        )


def audit_package(
    package: Path,
    *,
    variant: str,
    expected_identifier: str,
    expected_version: str,
    expected_inventory: Path,
    report: Path,
) -> dict[str, object]:
    if not package.is_file():
        raise RuntimeError(f"Package does not exist: {package}")
    if not expected_inventory.is_file():
        raise RuntimeError(f"Expected staging inventory does not exist: {expected_inventory}")
    temp_parent = Path(os.environ.get("TMPDIR", "/tmp")).resolve()
    temp_parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="stemwerk-final-pkg-audit-", dir=temp_parent) as temp_name:
        temp = Path(temp_name)
        expanded = temp / "expanded"
        subprocess.run(["pkgutil", "--expand-full", str(package), str(expanded)], check=True)
        package_infos = list(expanded.rglob("PackageInfo"))
        if len(package_infos) != 1:
            raise RuntimeError(f"Expected one PackageInfo, found {len(package_infos)}")
        root = ET.parse(package_infos[0]).getroot()
        identifier = root.attrib.get("identifier", "")
        version = root.attrib.get("version", "")
        if identifier != expected_identifier:
            raise RuntimeError(f"Unexpected package identifier: {identifier!r}")
        if version != expected_version:
            raise RuntimeError(f"Unexpected package version: {version!r}")
        payload_roots = [path for path in expanded.rglob("Payload") if path.is_dir()]
        if len(payload_roots) != 1:
            raise RuntimeError(f"Expected one expanded Payload directory, found {len(payload_roots)}")
        payload_root = payload_roots[0] / EXPECTED_PAYLOAD_ROOT
        if not payload_root.is_dir():
            raise RuntimeError(f"Expected package payload root is missing: {EXPECTED_PAYLOAD_ROOT}")
        scripts = list(expanded.rglob("Scripts/postinstall"))
        source_postinstall = REPO_ROOT / "installer/macos/scripts/postinstall"
        if len(scripts) != 1 or sha256_file(scripts[0]) != sha256_file(source_postinstall):
            raise RuntimeError("Final package postinstall differs from the reviewed source script")
        actual_inventory = temp / "final-payload-inventory.json"
        env = os.environ.copy()
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        subprocess.run(
            [
                sys.executable, str(PAYLOAD_AUDITOR), "--root", str(payload_root),
                "--variant", variant, "--inventory", str(actual_inventory),
            ],
            check=True,
            env=env,
        )
        compare_inventories(expected_inventory, actual_inventory)
        actual_data = json.loads(actual_inventory.read_text(encoding="utf-8"))
        result = {
            "package": package.name,
            "package_sha256": sha256_file(package),
            "package_size": package.stat().st_size,
            "identifier": identifier,
            "version": version,
            "variant": variant,
            "payload_entry_count": len(actual_data["files"]),
            "payload_file_count": sum(
                record.get("type") == "file" for record in actual_data["files"]
            ),
            "payload_directory_count": sum(
                record.get("type") == "directory" for record in actual_data["files"]
            ),
            "payload_symlink_count": sum(
                record.get("type") == "symlink" for record in actual_data["files"]
            ),
            "staging_inventory_match": True,
            "final_payload_audit": "passed",
        }
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--variant", required=True)
    parser.add_argument("--expected-identifier", required=True)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--expected-inventory", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    result = audit_package(
        args.package.resolve(),
        variant=args.variant,
        expected_identifier=args.expected_identifier,
        expected_version=args.expected_version,
        expected_inventory=args.expected_inventory.resolve(),
        report=args.report.resolve(),
    )
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
