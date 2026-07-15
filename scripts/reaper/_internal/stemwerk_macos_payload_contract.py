#!/usr/bin/env python3
"""Validate and emit the manifest-driven macOS arm64 payload contract."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

try:
    from packaging.utils import canonicalize_name, parse_wheel_filename
except ImportError:
    from pip._vendor.packaging.utils import canonicalize_name, parse_wheel_filename


EXPECTED_OVERRIDE = {
    "package": "samplerate",
    "upstream_required": "0.1.0",
    "project_override": "0.2.4",
    "scope": "macos-arm64",
}
NON_CLOSURE_PACKAGES = {canonicalize_name(name) for name in ("pip", "setuptools", "wheel", "stemwerk-core")}
TORCH_SYMPY_POLICY = {"torch": "2.5.1", "sympy": "1.13.1"}


def fail(reason: str, detail: str = "") -> None:
    suffix = f":{detail}" if detail else ""
    raise RuntimeError(f"{reason}{suffix}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def wheel_requirement(path: Path) -> str:
    try:
        name, version, _build, _tags = parse_wheel_filename(path.name)
    except Exception as exc:
        fail("override_contract_invalid", f"invalid_wheel={path.name}:{exc}")
    return f"{canonicalize_name(name)}=={version}"


def validate_contract(manifest_path: Path, wheels_dir: Path, expected_core: list[str]) -> tuple[list[str], list[str]]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("platform") != "macos-apple-silicon" or manifest.get("architecture") != "arm64":
        fail("override_contract_invalid", "platform")
    core = manifest.get("target_core_requirements")
    closure = manifest.get("dependency_closure_requirements")
    if sorted(core or []) != sorted(expected_core) or not isinstance(closure, list):
        fail("override_contract_invalid", "requirements")
    if manifest.get("dependency_overrides") != [EXPECTED_OVERRIDE]:
        fail("override_contract_invalid", "dependency_overrides")
    if manifest.get("forbidden_requirements") != ["samplerate==0.1.0", "sympy==1.14.0"]:
        fail("override_contract_invalid", "forbidden_requirements")
    if "samplerate==0.2.4" not in core:
        fail("samplerate_override_missing")

    inventory = manifest.get("wheel_inventory", [])
    inventory_by_name = {item.get("filename", ""): item for item in inventory}
    if len(inventory) != len(inventory_by_name):
        fail("override_contract_invalid", "duplicate_inventory")
    physical = {path.name: path for path in wheels_dir.iterdir() if path.is_file() and path.suffix.lower() == ".whl"}
    physical_requirements = {wheel_requirement(path) for path in physical.values()}
    if "samplerate==0.1.0" in physical_requirements:
        fail("forbidden_samplerate_0_1_0_present")
    torch_requirement = f"torch=={TORCH_SYMPY_POLICY['torch']}"
    sympy_requirement = f"sympy=={TORCH_SYMPY_POLICY['sympy']}"
    if torch_requirement not in core or sympy_requirement not in closure:
        fail("dependency_closure_core_conflict", f"{torch_requirement}_requires_{sympy_requirement}")
    if any(requirement.startswith("sympy==") and requirement != sympy_requirement for requirement in physical_requirements):
        fail("dependency_closure_core_conflict", "torch_sympy_pin_mismatch")
    if set(inventory_by_name) != set(physical):
        missing_files = set(inventory_by_name) - set(physical)
        missing_requirements = {wheel_requirement(Path(filename)) for filename in missing_files}
        if "samplerate==0.2.4" in missing_requirements:
            fail("samplerate_override_missing")
        fail("dependency_closure_missing", "manifest_filesystem_mismatch")
    core_names = {canonicalize_name(requirement.split("==", 1)[0]) for requirement in core}
    physical_closure = sorted(
        requirement
        for requirement in physical_requirements
        if canonicalize_name(requirement.split("==", 1)[0]) not in core_names | NON_CLOSURE_PACKAGES
    )
    if closure != physical_closure:
        fail("dependency_closure_missing", "manifest_closure_mismatch")
    for requirement in [*core, *closure]:
        if requirement not in physical_requirements:
            reason = "samplerate_override_missing" if requirement == "samplerate==0.2.4" else "dependency_closure_missing"
            fail(reason, requirement)
    for filename, item in inventory_by_name.items():
        path = physical[filename]
        if item.get("size") != path.stat().st_size or item.get("sha256") != sha256_file(path):
            fail("dependency_closure_missing", f"fingerprint={filename}")
    return core, closure


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--wheelhouse", required=True)
    parser.add_argument("--expected-core", action="append", default=[])
    args = parser.parse_args()
    try:
        core, closure = validate_contract(Path(args.manifest), Path(args.wheelhouse), args.expected_core)
    except (OSError, ValueError, RuntimeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print("CORE_REQUIREMENTS=" + " ".join(core))
    print("CLOSURE_REQUIREMENTS=" + " ".join(closure))
    print("OVERRIDE=samplerate:upstream=0.1.0:project=0.2.4:scope=macos-arm64")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
