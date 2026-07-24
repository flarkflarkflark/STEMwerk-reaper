#!/usr/bin/env python3
"""Fail-closed, read-only consistency checks for proposed SLICE-1 documents."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

SLICE_IDS = [f"SLICE-{number}" for number in range(11)]
SPLIT_IDS = {"CMV1-STATE-001", *(f"CMV1-FAIL-{number:03d}" for number in range(1, 13))}
SINGLE_SLICE = re.compile(r"SLICE-(?:0|[1-9]|10)\Z")
SLICE_LIST = re.compile(r"SLICE-(?:0|[1-9]|10)(?:,SLICE-(?:0|[1-9]|10))*\Z")
REQUIRED_SCOPE_KEYS = {
    "OFFICIAL_NAME", "ONE_SENTENCE_GOAL", "VERTICAL_DEMO", "INPUTS", "OUTPUTS",
    "IN_SCOPE_REQUIREMENTS", "OUT_OF_SCOPE_REQUIREMENTS", "SPLIT_REQUIREMENTS",
    "ALLOWED_PACKAGES", "ALLOWED_TYPES", "ALLOWED_FUNCTIONS", "FORBIDDEN_APIS",
    "ALLOWED_PATHS", "FORBIDDEN_PATHS", "FUTURE_ALLOWED_PATHS", "DEPENDENCY_POLICY",
    "ENTRY_GATES", "EXIT_GATES", "STOP_CONDITIONS", "ARTIFACT_CONTENTS",
    "MACHINE_READABLE_SUMMARY", "SELECTOR_TYPE", "SELECTOR_FIELDS",
    "COMPATIBILITY_STATUS_MODEL", "RUNNABLE_MAPPING", "REASON_PRIORITY_ORDER",
}
FROZEN_EXACT = {"component-manager/go.mod", "component-manager/go.sum"}
FROZEN_PREFIXES = (
    "experiments/component-manager-poa0/contract-v1/",
    "component-manager/schemas/",
    "component-manager/pkg/",
    "component-manager/internal/",
    ".github/workflows/",
)


def git(root: Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", *arguments], cwd=root, text=True, capture_output=True,
    )
    if result.returncode:
        raise RuntimeError(f"git {' '.join(arguments)} failed: {result.stderr.strip()}")
    return result.stdout


def changed_paths(root: Path, base_ref: str) -> tuple[set[str], set[str]]:
    git(root, "rev-parse", "--show-toplevel")
    git(root, "rev-parse", "--verify", f"{base_ref}^{{commit}}")
    committed = set(filter(None, git(root, "diff", "--name-only", f"{base_ref}...HEAD").splitlines()))
    staged = set(filter(None, git(root, "diff", "--cached", "--name-only").splitlines()))
    unstaged = set(filter(None, git(root, "diff", "--name-only").splitlines()))
    untracked = set(filter(None, git(root, "ls-files", "--others", "--exclude-standard").splitlines()))
    return committed, staged | unstaged | untracked


def is_frozen(path: str) -> bool:
    return path in FROZEN_EXACT or path.startswith(FROZEN_PREFIXES)


def assignments(text: str) -> dict[str, str]:
    return dict(re.findall(r"^([A-Z0-9_]+)=(.*)$", text, re.MULTILINE))


def table_rows(text: str) -> list[list[str]]:
    rows = []
    for line in text.splitlines():
        if line.startswith("|") and not re.match(r"^\|[-: |]+\|$", line):
            rows.append([cell.strip() for cell in line.strip().strip("|").split("|")])
    return rows


def package_rows(text: str) -> dict[str, list[str]]:
    rows: dict[str, list[str]] = {}
    for row in table_rows(text):
        if len(row) == 9 and row[0] not in {"Package", ""}:
            rows[row[0]] = row
    return rows


def check(root: Path, base_ref: str) -> dict[str, object]:
    readiness = root / "experiments/component-manager-poa0/production-readiness"
    scope = (root / "component-manager/docs/SLICE_1_SCOPE.md").read_text(encoding="utf-8")
    decision = (readiness / "SLICE_1_AND_ROADMAP_ARCHITECTURE_DECISION.md").read_text(encoding="utf-8")
    vertical = (readiness / "VERTICAL_SLICES.md").read_text(encoding="utf-8")
    trace = (readiness / "READINESS_TRACEABILITY.md").read_text(encoding="utf-8")
    packages = (readiness / "GO_PACKAGE_PLAN.md").read_text(encoding="utf-8")
    failures: list[str] = []

    for slice_id in SLICE_IDS:
        if not re.search(rf"^### {re.escape(slice_id)}\b", vertical, re.MULTILINE):
            failures.append(f"missing slice: {slice_id}")

    split_rows = {row[0]: row for row in table_rows(trace) if len(row) == 8 and row[0] in SPLIT_IDS}
    base_rows = re.findall(r"^\| (CMV1-[A-Z0-9-]+) \| (?:none|ADR-)", trace, re.MULTILINE)
    if len(base_rows) != 65 or len(set(base_rows)) != 65:
        failures.append(f"traceability base row count is {len(base_rows)}, expected 65 unique")
    for requirement_id in sorted(SPLIT_IDS):
        row = split_rows.get(requirement_id)
        if row is None:
            failures.append(f"missing realization split: {requirement_id}")
            continue
        if len(row) != 8:
            failures.append(f"split row has {len(row)} fields, expected 8: {requirement_id}")
            continue
        for index, field_name in ((1, "TYPE_LEVEL_SLICE"), (2, "POLICY_LEVEL_SLICE"),
                                  (3, "CAPABILITY_LEVEL_SLICE"), (4, "FIRST_EXERCISED_SLICE")):
            if not SINGLE_SLICE.fullmatch(row[index]):
                failures.append(f"invalid {field_name}: {requirement_id}")
        if not SLICE_LIST.fullmatch(row[5]):
            failures.append(f"invalid REVERIFIED_IN_SLICES: {requirement_id}")
        if not row[6]:
            failures.append(f"missing RATIONALE: {requirement_id}")
        if not row[7]:
            failures.append(f"missing SOURCE_SECTION: {requirement_id}")

    scope_values = assignments(scope)
    decision_values = assignments(decision)
    missing_keys = sorted(REQUIRED_SCOPE_KEYS - scope_values.keys())
    if missing_keys:
        failures.append("missing scope keys: " + ",".join(missing_keys))
    if "TO_BE_DEFINED" in scope:
        failures.append("TO_BE_DEFINED remains in SLICE-1 scope")
    allowed = {item.strip() for item in scope_values.get("ALLOWED_PATHS", "").split(";")}
    forbidden = {item.strip() for item in scope_values.get("FORBIDDEN_PATHS", "").split(";")}
    overlap = sorted((allowed & forbidden) - {""})
    if overlap:
        failures.append("path-set overlap: " + ",".join(overlap))

    invariants = {
        "decision status remains proposed": "Status: PROPOSED_FOR_OWNER_APPROVAL" in decision,
        "roadmap is HYBRID": "ROADMAP_OPTION=HYBRID" in decision,
        "official name matches": scope_values.get("OFFICIAL_NAME") == "Read-only catalog and component validation",
        "ResolutionPreview cross-document": decision_values.get("SLICE1_VERTICAL_OUTPUT") == "ResolutionPreview" and "ResolutionPreview" in scope_values.get("OUTPUTS", ""),
        "ComponentSelector cross-document": "ComponentSelector" in decision and scope_values.get("SELECTOR_TYPE") == "resolution.ComponentSelector",
        "compatibility tri-state": scope_values.get("COMPATIBILITY_STATUS_MODEL") == "Compatible|Incompatible|Unknown",
        "unknown is not runnable": "Unknown:false" in scope_values.get("RUNNABLE_MAPPING", "") and "Unknown" in decision,
        "incompatible is distinct": "Incompatible:false" in scope_values.get("RUNNABLE_MAPPING", ""),
        "malformed signature fails closed": "A malformed envelope returns a typed fail-closed error" in decision and "malformed is never a successful preview state" in scope,
        "trust is only unverified": "only constructible SLICE-1 value is\n`UNVERIFIED`" in scope and "cannot construct\n`trusted` or `verified`" in decision,
        "artifact owner": "`pkg/artifact` is the normative owner" in decision,
        "duplicate artifact types forbidden": "Independent duplicate artifact domain types are forbidden" in decision,
        "no new dependencies": "no new external dependency" in scope_values.get("DEPENDENCY_POLICY", ""),
        "implementation unauthorized": scope_values.get("IMPLEMENTATION_AUTHORIZED") == "no",
        "entry and exit gates": bool(scope_values.get("ENTRY_GATES")) and "SLICE1_EXIT=PASS" in scope_values.get("EXIT_GATES", ""),
        "selector match semantics": "exactly one match is\nrequired" in scope and "Zero or multiple matches fail closed" in scope,
        "typed reason order": scope_values.get("REASON_PRIORITY_ORDER", "").count(";") == 10 and "then lexically by code" in scope,
    }
    for label, passed in invariants.items():
        if not passed:
            failures.append(f"decision/scope invariant failed: {label}")
    all_boxes = len(re.findall(r"^\s*- \[[ xX]\]", decision + "\n" + scope, re.MULTILINE))
    checked_boxes = len(re.findall(r"^\s*- \[[xX]\]", decision + "\n" + scope, re.MULTILINE))
    if all_boxes != 8:
        failures.append(f"owner checkbox count is {all_boxes}, expected 8")
    if checked_boxes:
        failures.append(f"owner checkbox checked: {checked_boxes}")
    if re.search(r"(?:Status:|STATUS=)\s*APPROVED", decision + "\n" + scope):
        failures.append("documentation claims approval")

    graph = package_rows(packages)
    required_packages = {"artifact", "catalog", "compatibility", "resolution"}
    if not required_packages.issubset(graph):
        failures.append("package graph missing required SLICE-1 package")
    else:
        dependency_checks = {
            "compatibility imports generation": ("generation", graph["compatibility"][3]),
            "catalog imports trust": ("trust", graph["catalog"][3]),
            "catalog imports revocation": ("revocation", graph["catalog"][3]),
            "artifact imports catalog": ("catalog", graph["artifact"][3]),
        }
        for label, (term, dependency_cell) in dependency_checks.items():
            if re.search(rf"\b{term}\b", dependency_cell):
                failures.append(label)
        for term in ("state", "store", "storage", "network", "clock", "random", "generation"):
            if re.search(rf"\b{term}\b", graph["resolution"][3]):
                failures.append(f"resolution imports forbidden dependency: {term}")

    committed, worktree = changed_paths(root, base_ref)
    committed_frozen = sorted(path for path in committed if is_frozen(path))
    worktree_frozen = sorted(path for path in worktree if is_frozen(path))
    if committed_frozen:
        failures.append("committed frozen changes: " + ",".join(committed_frozen))
    if worktree_frozen:
        failures.append("worktree frozen changes: " + ",".join(worktree_frozen))

    return {
        "base_ref": base_ref,
        "check": "slice1-documentation-consistency",
        "checked_owner_checkbox_count": checked_boxes,
        "owner_checkbox_count": all_boxes,
        "committed_frozen_change_count": len(committed_frozen),
        "failures": failures,
        "packagegraph_structural_check_count": 11,
        "requirement_count": len(base_rows),
        "result": "PASS" if not failures else "FAIL",
        "slice_count": len(SLICE_IDS),
        "split_requirement_count": len(split_rows),
        "to_be_defined_count": scope.count("TO_BE_DEFINED"),
        "worktree_frozen_change_count": len(worktree_frozen),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--base-ref", required=True)
    args = parser.parse_args()
    try:
        result = check(args.repository.resolve(), args.base_ref)
    except Exception as error:  # Fail closed with machine-readable evidence.
        result = {
            "base_ref": args.base_ref,
            "check": "slice1-documentation-consistency",
            "failures": [str(error)],
            "result": "FAIL",
        }
    sys.stdout.write(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return 0 if result["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
