#!/usr/bin/env python3
"""Fail-closed, read-only consistency checks for the proposed SLICE-1 documents."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

SLICE_IDS = [f"SLICE-{number}" for number in range(11)]
SPLIT_IDS = {"CMV1-STATE-001", *(f"CMV1-FAIL-{number:03d}" for number in range(1, 13))}
REQUIRED_SCOPE_KEYS = {
    "OFFICIAL_NAME", "ONE_SENTENCE_GOAL", "VERTICAL_DEMO", "INPUTS", "OUTPUTS",
    "IN_SCOPE_REQUIREMENTS", "OUT_OF_SCOPE_REQUIREMENTS", "SPLIT_REQUIREMENTS",
    "ALLOWED_PACKAGES", "ALLOWED_TYPES", "ALLOWED_FUNCTIONS", "FORBIDDEN_APIS",
    "ALLOWED_PATHS", "FORBIDDEN_PATHS", "DEPENDENCY_POLICY", "ENTRY_GATES",
    "EXIT_GATES", "STOP_CONDITIONS", "ARTIFACT_CONTENTS", "MACHINE_READABLE_SUMMARY",
}


def git_changed(root: Path) -> list[str]:
    result = subprocess.run(
        ["git", "status", "--porcelain=v1"], cwd=root, text=True,
        check=True, capture_output=True,
    )
    return [line[3:] for line in result.stdout.splitlines() if len(line) >= 4]


def check(root: Path) -> dict[str, object]:
    readiness = root / "experiments/component-manager-poa0/production-readiness"
    scope_path = root / "component-manager/docs/SLICE_1_SCOPE.md"
    vertical = (readiness / "VERTICAL_SLICES.md").read_text(encoding="utf-8")
    trace = (readiness / "READINESS_TRACEABILITY.md").read_text(encoding="utf-8")
    packages = (readiness / "GO_PACKAGE_PLAN.md").read_text(encoding="utf-8")
    scope = scope_path.read_text(encoding="utf-8")
    failures: list[str] = []

    for slice_id in SLICE_IDS:
        if not re.search(rf"^### {re.escape(slice_id)}\b", vertical, re.MULTILINE):
            failures.append(f"missing slice: {slice_id}")

    requirement_rows = re.findall(r"^\| (CMV1-[A-Z0-9-]+) \|", trace, re.MULTILINE)
    base_rows = requirement_rows[len(SPLIT_IDS):]
    if len(base_rows) != 65 or len(set(base_rows)) != 65:
        failures.append(f"traceability base row count is {len(base_rows)}, expected 65 unique")
    for requirement_id in SPLIT_IDS:
        pattern = rf"^\| {re.escape(requirement_id)} \| SLICE-[^|]+\| SLICE-[^|]+\| SLICE-[^|]+\|"
        if not re.search(pattern, trace, re.MULTILINE):
            failures.append(f"missing realization split: {requirement_id}")

    assignments = dict(re.findall(r"^([A-Z0-9_]+)=(.*)$", scope, re.MULTILINE))
    missing_keys = sorted(REQUIRED_SCOPE_KEYS - assignments.keys())
    if missing_keys:
        failures.append("missing scope keys: " + ",".join(missing_keys))
    if "TO_BE_DEFINED" in scope:
        failures.append("TO_BE_DEFINED remains in SLICE-1 scope")

    allowed = {item.strip() for item in assignments.get("ALLOWED_PATHS", "").split(";")}
    forbidden = {item.strip() for item in assignments.get("FORBIDDEN_PATHS", "").split(";")}
    overlap = sorted((allowed & forbidden) - {""})
    if overlap:
        failures.append("path-set overlap: " + ",".join(overlap))

    for required in ("| resolution |", "compatibility | declarative compatibility over caller-supplied facts"):
        if required not in packages:
            failures.append(f"package graph missing: {required}")
    compatibility_row = next(
        (line for line in packages.splitlines() if line.startswith("| compatibility |")), ""
    )
    compatibility_dependencies = compatibility_row.split("|")[4] if compatibility_row else ""
    if re.search(r"\bgeneration\b", compatibility_dependencies):
        failures.append("compatibility imports generation")

    changed = git_changed(root)
    frozen_changes = [path for path in changed if
                      path.startswith("experiments/component-manager-poa0/contract-v1/") or
                      path.startswith("component-manager/schemas/")]
    if frozen_changes:
        failures.append("frozen Contract-v1/schema changes: " + ",".join(frozen_changes))

    return {
        "check": "slice1-documentation-consistency",
        "result": "PASS" if not failures else "FAIL",
        "slice_count": len(SLICE_IDS),
        "requirement_count": len(base_rows),
        "split_requirement_count": len(SPLIT_IDS),
        "to_be_defined_count": scope.count("TO_BE_DEFINED"),
        "frozen_change_count": len(frozen_changes),
        "failures": failures,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    result = check(args.repository.resolve())
    encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
    sys.stdout.write(encoded)
    return 0 if result["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
