#!/usr/bin/env python3
"""Fail-closed, read-only consistency gate for SLICE-1 documents.

Lifecycle modes:
- ``review``: the documentation closure is PROPOSED with 0/8 owner controls
  checked. This mode is frozen to the immutable review-head semantics.
- ``approved``: the documentation closure is APPROVED_BY_OWNER with exactly
  7/8 owner controls checked and implementation NOT_AUTHORIZED.
- ``authorized``: implementation is authorized (8/8 owner controls checked)
  but not started, on branch slice/1-read-only-resolution-preview from
  governance baseline e0fe346e8f643a2643f97bcb50cd6616769e1362.

The mode is explicit and required; unknown or missing modes fail closed.
"""

from __future__ import annotations

import argparse
import datetime
import json
import re
import subprocess
import sys
from pathlib import Path

GATE = "slice1_documentation"
SLICE_IDS = [f"SLICE-{number}" for number in range(11)]
SPLIT_IDS = {"CMV1-STATE-001", *(f"CMV1-FAIL-{number:03d}" for number in range(1, 13))}
SINGLE_SLICE = re.compile(r"SLICE-(?:0|[1-9]|10)\Z")
SLICE_LIST = re.compile(r"SLICE-(?:0|[1-9]|10)(?:,SLICE-(?:0|[1-9]|10))*\Z")

ALLOWED_CHANGED_PATHS = {
    "component-manager/README.md",
    "component-manager/docs/SLICE_1_SCOPE.md",
    "component-manager/scripts/verify_slice1_documentation.py",
    "component-manager/scripts/verify_slice1_documentation_test.py",
    "experiments/component-manager-poa0/production-readiness/DEPENDENCY_POLICY.md",
    "experiments/component-manager-poa0/production-readiness/FIRST_SLICE_SCOPE.md",
    "experiments/component-manager-poa0/production-readiness/GO_PACKAGE_PLAN.md",
    "experiments/component-manager-poa0/production-readiness/IMPLEMENTATION_GATES.md",
    "experiments/component-manager-poa0/production-readiness/PUBLIC_API_BOUNDARIES.md",
    "experiments/component-manager-poa0/production-readiness/READINESS_TRACEABILITY.md",
    "experiments/component-manager-poa0/production-readiness/README.md",
    "experiments/component-manager-poa0/production-readiness/SLICE_1_AND_ROADMAP_ARCHITECTURE_DECISION.md",
    "experiments/component-manager-poa0/production-readiness/TEST_AND_CI_PLAN.md",
    "experiments/component-manager-poa0/production-readiness/VERTICAL_SLICES.md",
}
# Post-approval governance-only paths, valid exclusively in approved mode.
APPROVED_EXTRA_ALLOWED_CHANGED_PATHS = {
    "component-manager/scripts/verify_slice1_changed_paths.py",
    "component-manager/scripts/verify_slice1_changed_paths_test.py",
    "component-manager/scripts/run_slice1_fast_gate.py",
    "component-manager/scripts/run_slice1_fast_gate_test.py",
}
AUTHORIZED_BASELINE = "e0fe346e8f643a2643f97bcb50cd6616769e1362"
AUTHORIZED_BRANCH = "slice/1-read-only-resolution-preview"
REQUIRED_SCOPE_KEYS = {
    "OFFICIAL_NAME", "ONE_SENTENCE_GOAL", "VERTICAL_DEMO", "INPUTS", "OUTPUTS",
    "IN_SCOPE_REQUIREMENTS", "OUT_OF_SCOPE_REQUIREMENTS", "SPLIT_REQUIREMENTS",
    "ALLOWED_PACKAGES", "ALLOWED_TYPES", "ALLOWED_FUNCTIONS", "FORBIDDEN_APIS",
    "ALLOWED_PATHS", "FORBIDDEN_PATHS", "FUTURE_ALLOWED_PATHS", "DEPENDENCY_POLICY",
    "ENTRY_GATES", "EXIT_GATES", "STOP_CONDITIONS", "ARTIFACT_CONTENTS",
    "MACHINE_READABLE_SUMMARY", "SELECTOR_TYPE", "SELECTOR_FIELDS",
    "COMPATIBILITY_STATUS_MODEL", "RUNNABLE_MAPPING", "REASON_PRIORITY_ORDER",
    "UNKNOWN_CONTEXT_FIELD_POLICY",
}
CONTEXT_FIELDS = {"Platform", "Architecture", "Backend", "ComponentKind", "SchemaVersion"}
FACT_FIELDS = {
    "ComponentID", "ComponentKind", "SoftwareVersion or ModelRevision",
    "ArtifactID and Digest", "Provenance facts", "Platform/Architecture/Backend predicates",
    "SchemaVersion predicate", "Runtime/Python/component/model/flow relations",
}
REASON_CODES = [
    "platform_unknown", "platform_mismatch", "architecture_unknown", "architecture_mismatch",
    "backend_unknown", "backend_mismatch", "component_kind_unknown",
    "component_kind_mismatch", "schema_capability_unknown", "required_relation_unknown",
    "incompatible_declared_constraint",
]
PACKAGEGRAPH_CHECKS = [
    "compatibility_no_generation", "catalog_no_concrete_trust", "catalog_no_revocation",
    "resolution_no_state", "resolution_no_storage", "resolution_no_network",
    "resolution_no_time", "resolution_no_random", "artifact_no_catalog",
    "single_artifact_owner", "pure_graph_no_later_effect_package",
]
LATER_EFFECT_PACKAGES = {
    "state", "lifecycle", "lease", "runpin", "gc", "clock", "journal", "internal/app",
    "internal/store/files", "internal/store/sqlite", "internal/platform", "internal/helper",
    "internal/transport/cli",
}
ERROR_CASES = {
    "malformed JSON", "oversized input", "unsupported schema major", "invalid identity",
    "duplicate identity", "same-version/different-digest", "artifact digest mismatch",
    "missing selector", "multiple selector matches", "malformed provenance",
    "malformed signature", "compatibility Compatible", "compatibility Incompatible",
    "compatibility Unknown", "canonicalization failure", "resolution-preview digest mismatch",
}


class GateFailure(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


class JSONArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        code = "base_ref_missing" if "--base-ref" in message else "cli_invalid"
        raise GateFailure(code, message)


def git(root: Path, *arguments: str, failure_code: str = "git_command_failed") -> str:
    try:
        result = subprocess.run(
            ["git", *arguments], cwd=root, text=True, capture_output=True, check=False,
        )
    except OSError as error:
        raise GateFailure("git_repository_unavailable", str(error)) from error
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise GateFailure(failure_code, f"git {' '.join(arguments)} failed: {detail}")
    return result.stdout


def assignments(text: str) -> dict[str, str]:
    return dict(re.findall(r"^([A-Z0-9_]+)=(.*)$", text, re.MULTILINE))


def valid_iso_date(value: str) -> bool:
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        return False
    try:
        datetime.date.fromisoformat(value)
    except ValueError:
        return False
    return True


def table_rows(text: str) -> list[list[str]]:
    rows: list[list[str]] = []
    for line in text.splitlines():
        if line.startswith("|") and not re.match(r"^\|[-: |]+\|$", line):
            rows.append([cell.strip().strip("`") for cell in line.strip().strip("|").split("|")])
    return rows


def table_with_header(text: str, header: list[str]) -> list[list[str]]:
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if not line.startswith("|"):
            continue
        row = [cell.strip().replace("`", "") for cell in line.strip().strip("|").split("|")]
        if row == header:
            result: list[list[str]] = []
            for candidate_line in lines[index + 2:]:
                if not candidate_line.startswith("|"):
                    break
                candidate = [cell.strip().replace("`", "") for cell in candidate_line.strip().strip("|").split("|")]
                if len(candidate) != len(header):
                    raise GateFailure("document_structure_invalid", "invalid row width: " + "|".join(header))
                result.append(candidate)
            return result
    raise GateFailure("document_structure_invalid", "missing table: " + "|".join(header))


def package_rows(text: str) -> dict[str, list[str]]:
    header = ["Package", "Responsibility", "Public API", "Internal dependencies", "Forbidden dependencies", "Platform", "Pure", "Side effect", "Test boundary"]
    rows = table_with_header(text, header)
    graph = {row[0]: row for row in rows}
    if len(graph) != len(rows):
        raise GateFailure("packagegraph_invalid", "duplicate package row")
    return graph


def path_sets(root: Path, base_ref: str) -> dict[str, set[str]]:
    return {
        "committed": set(filter(None, git(root, "diff", "--name-only", f"{base_ref}...HEAD").splitlines())),
        "staged": set(filter(None, git(root, "diff", "--cached", "--name-only").splitlines())),
        "unstaged": set(filter(None, git(root, "diff", "--name-only").splitlines())),
        "untracked": set(filter(None, git(root, "ls-files", "--others", "--exclude-standard").splitlines())),
    }


def add_error(errors: list[dict[str, str]], code: str, message: str) -> None:
    errors.append({"code": code, "message": message})


def run_check(root: Path, base_ref: str, head: str, mode: str) -> tuple[dict[str, str], list[dict[str, str]], dict[str, object]]:
    checks: dict[str, str] = {}
    errors: list[dict[str, str]] = []
    metrics: dict[str, object] = {}

    def record(name: str, passed: bool, code: str, message: str) -> None:
        checks[name] = "PASS" if passed else "FAIL"
        if not passed:
            add_error(errors, code, message)

    readiness = root / "experiments/component-manager-poa0/production-readiness"
    try:
        scope = (root / "component-manager/docs/SLICE_1_SCOPE.md").read_text(encoding="utf-8")
        decision = (readiness / "SLICE_1_AND_ROADMAP_ARCHITECTURE_DECISION.md").read_text(encoding="utf-8")
        vertical = (readiness / "VERTICAL_SLICES.md").read_text(encoding="utf-8")
        trace = (readiness / "READINESS_TRACEABILITY.md").read_text(encoding="utf-8")
        packages = (readiness / "GO_PACKAGE_PLAN.md").read_text(encoding="utf-8")
        public_api = (readiness / "PUBLIC_API_BOUNDARIES.md").read_text(encoding="utf-8")
        readiness_readme = (readiness / "README.md").read_text(encoding="utf-8")
        first_scope = (readiness / "FIRST_SLICE_SCOPE.md").read_text(encoding="utf-8")
    except OSError as error:
        raise GateFailure("document_unavailable", str(error)) from error

    scope_values = assignments(scope)
    decision_values = assignments(decision)
    package_values = assignments(packages)
    readme_values = assignments(readiness_readme)
    first_values = assignments(first_scope)

    record("slice_inventory", all(re.search(rf"^### {re.escape(item)}\b", vertical, re.MULTILINE) for item in SLICE_IDS), "slice_inventory_invalid", "expected SLICE-0 through SLICE-10")
    base_rows = re.findall(r"^\| (CMV1-[A-Z0-9-]+) \| (?:none|ADR-)", trace, re.MULTILINE)
    record("traceability_inventory", len(base_rows) == 65 and len(set(base_rows)) == 65, "traceability_invalid", "expected 65 unique requirement rows")
    split_rows = {row[0]: row for row in table_rows(trace) if len(row) == 8 and row[0] in SPLIT_IDS}
    split_ok = set(split_rows) == SPLIT_IDS
    for row in split_rows.values():
        split_ok &= all(SINGLE_SLICE.fullmatch(row[index]) is not None for index in (1, 2, 3, 4))
        split_ok &= SLICE_LIST.fullmatch(row[5]) is not None and bool(row[6]) and bool(row[7])
    record("realization_splits", split_ok, "realization_split_invalid", "all 13 split rows require eight valid fields")

    missing = REQUIRED_SCOPE_KEYS - scope_values.keys()
    record("scope_keys", not missing, "scope_key_missing", "missing: " + ",".join(sorted(missing)))
    record("no_to_be_defined", "TO_BE_DEFINED" not in scope, "scope_unresolved", "TO_BE_DEFINED remains")
    allowed = {value.strip() for value in scope_values.get("ALLOWED_PATHS", "").split(";") if value.strip()}
    forbidden = {value.strip() for value in scope_values.get("FORBIDDEN_PATHS", "").split(";") if value.strip()}
    record("scope_path_sets", not (allowed & forbidden), "scope_path_overlap", "allowed and forbidden paths overlap")

    context_header = ["CONTEXT_FIELD", "TYPE", "SOURCE_REQUIREMENT", "REQUIRED_OR_OPTIONAL", "UNKNOWN_BEHAVIOR", "COMPARISON_RULE", "REASON_CODE"]
    context_rows = table_with_header(scope, context_header)
    context_names = [row[0] for row in context_rows]
    context_ok = set(context_names) == CONTEXT_FIELDS and len(context_names) == 5 and all(all(row) for row in context_rows)
    record("compatibility_context_fields", context_ok, "compatibility_context_invalid", "expected exactly five complete context fields")

    fact_header = ["COMPATIBILITY_FACT_FIELD", "SOURCE", "PROJECTED_IN_SLICE1", "EVALUATED_IN_SLICE1", "DEFERRED_SLICE", "RATIONALE"]
    fact_rows = table_with_header(scope, fact_header)
    fact_names = [row[0] for row in fact_rows]
    fact_ok = set(fact_names) == FACT_FIELDS and len(fact_names) == 8 and all(all(row) for row in fact_rows)
    record("compatibility_fact_fields", fact_ok, "compatibility_facts_invalid", "expected exactly eight complete fact fields")

    statuses = scope_values.get("COMPATIBILITY_STATUS_MODEL", "").split("|")
    record("compatibility_status", statuses == ["Compatible", "Incompatible", "Unknown"], "compatibility_status_invalid", "ContractStatus must be exact tri-state")
    mapping = {}
    for item in scope_values.get("RUNNABLE_MAPPING", "").split(";"):
        if ":" in item:
            key, value = item.strip().split(":", 1)
            mapping[key] = value
    record("runnable_mapping", mapping == {"Compatible": "true", "Incompatible": "false", "Unknown": "false"}, "runnable_mapping_invalid", "Runnable matrix is not exact")
    reasons = [item.strip() for item in scope_values.get("REASON_PRIORITY_ORDER", "").split(";") if item.strip()]
    record("reason_priority", reasons == REASON_CODES and len(set(reasons)) == 11 and "then lexically by code" in scope, "reason_priority_invalid", "reason priority must contain eleven unique ordered codes and lexical tie-break")
    unknown_result = "`Unknown` remains distinct" in scope and "compatibility `ContractStatus`, `Runnable` and ordered typed reasons" in scope
    record("unknown_preserved_in_result_preview", unknown_result, "unknown_visibility_invalid", "Unknown must remain explicit in Result and ResolutionPreview")
    record("empty_compatibility", "empty, structurally valid compatibility\npredicate object produces `Compatible`, `Runnable=true`, and an empty reason list" in scope, "empty_compatibility_invalid", "empty compatibility outcome missing")
    record("unknown_context_policy", scope_values.get("UNKNOWN_CONTEXT_FIELD_POLICY") == "typed Go Context is closed and cannot represent unknown fields; JSON context fixtures reject unknown properties; generic map[string]any is forbidden", "unknown_context_policy_invalid", "unknown context-field policy missing or changed")

    selector_header = ["Variant", "Fields", "Exact comparison"]
    selector_rows = table_with_header(scope, selector_header)
    selector_ok = (
        scope_values.get("SELECTOR_TYPE") == "resolution.ComponentSelector"
        and scope_values.get("SELECTOR_FIELDS") == "ComponentID identity.ComponentID; Version resolution.VersionSelector"
        and len(selector_rows) == 2 and [row[0] for row in selector_rows] == ["Software", "Model"]
        and selector_rows[0][1] == "SoftwareVersion version.SoftwareVersion"
        and selector_rows[1][1] == "ModelRevision version.ModelRevision; ArtifactDigest digest.Digest"
        and "closed discriminated union with exactly one active variant" in scope
        and "Zero or multiple matches fail closed" in scope
        and "checks run before selection" in scope
        and "resolution.Selector` is forbidden" in public_api
        and "generation selector" in scope
    )
    record("component_selector", selector_ok, "component_selector_invalid", "ComponentSelector contract is incomplete")

    graph = package_rows(packages)
    required_packages = {"artifact", "catalog", "compatibility", "resolution"}
    record("packagegraph_parse", required_packages <= graph.keys(), "packagegraph_invalid", "required package rows missing")
    manifest = [item for item in package_values.get("SLICE1_PACKAGEGRAPH_INVARIANTS", "").split(";") if item]
    record("packagegraph_invariant_manifest", manifest == PACKAGEGRAPH_CHECKS, "packagegraph_manifest_invalid", "packagegraph invariant manifest must enumerate the exact eleven checks")
    graph_results: dict[str, bool] = {}
    if required_packages <= graph.keys():
        deps = {name: {item.strip() for item in graph[name][3].split(",")} for name in required_packages}
        graph_results = {
            "compatibility_no_generation": "generation" not in deps["compatibility"],
            "catalog_no_concrete_trust": "trust" not in deps["catalog"],
            "catalog_no_revocation": "revocation" not in deps["catalog"],
            "resolution_no_state": "state" not in deps["resolution"],
            "resolution_no_storage": not ({"store", "stores", "storage"} & deps["resolution"]),
            "resolution_no_network": "network" not in deps["resolution"],
            "resolution_no_time": not ({"time", "clock"} & deps["resolution"]),
            "resolution_no_random": "random" not in deps["resolution"],
            "artifact_no_catalog": "catalog" not in deps["artifact"],
            "single_artifact_owner": (
                package_values.get("ARTIFACT_NORMATIVE_OWNER") == "pkg/artifact"
                and "`pkg/artifact` is the normative owner" in decision
                and "Independent duplicate artifact domain types are forbidden" in decision
            ),
            "pure_graph_no_later_effect_package": not (set(filter(None, package_values.get("SLICE1_PURE_PACKAGES", "").split(";"))) & LATER_EFFECT_PACKAGES),
        }
    for name in PACKAGEGRAPH_CHECKS:
        record("packagegraph_" + name, graph_results.get(name, False), "packagegraph_" + name, name + " failed")
    metrics["packagegraph_structural_check_count"] = sum(graph_results.get(name, False) for name in PACKAGEGRAPH_CHECKS)

    resolver_ok = (
        "CompatibilityResolver / compatibility" not in public_api
        and "Resolve(Target,Generation)" not in public_api.replace(" ", "")
        and "GenerationCompatibilityCoordinator / generation" in public_api
        and "compatibility.Evaluate(Facts, Context)" in public_api
    )
    record("compatibility_ownership", resolver_ok, "compatibility_ownership_invalid", "generation orchestration must not be owned by compatibility")

    error_header = ["FAILURE_OR_RESULT", "CATEGORY_OR_STATUS", "ERROR_OR_DOMAIN_RESULT", "SOURCE", "STABLE_REASON", "NOTES"]
    error_rows = table_with_header(scope, error_header)
    error_names = {row[0] for row in error_rows}
    error_ok = error_names == ERROR_CASES and len(error_rows) == 16 and all(all(row) for row in error_rows)
    required_error_rows = {row[0]: row for row in error_rows}
    error_ok &= required_error_rows.get("oversized input", [None, None])[1] == "schema_invalid"
    error_ok &= required_error_rows.get("unsupported schema major", [None, None])[1] == "schema_invalid"
    error_ok &= required_error_rows.get("canonicalization failure", [None, None])[1] == "schema_invalid or internal_error"
    error_ok &= required_error_rows.get("resolution-preview digest mismatch", [None, None])[1] == "CI/gate failure; no product category"
    record("error_result_table", error_ok, "error_result_table_invalid", "expected sixteen exact error/result rows")

    status_ok = (
        readme_values.get("CURRENT_STATUS") == "SLICE_0_IMPLEMENTED_AND_GATED"
        and readme_values.get("HISTORICAL_READINESS_GATE_RECORD") == "PRODUCTION_READINESS_GATE.md"
        and first_values.get("CURRENT_STATUS") == "SLICE_0_IMPLEMENTED_AND_GATED"
        and first_values.get("HISTORICAL_SCOPE_RECORD") == "yes"
        and "production core has not started" not in readiness_readme.lower()
        and first_values.get("FIRST_SLICE_READY_FOR_SEPARATE_IMPLEMENTATION_TASK") == "no"
    )
    record("slice0_status", status_ok, "slice0_status_stale", "SLICE-0 current status is stale or inconsistent")

    cross = {
        "roadmap is HYBRID": decision_values.get("ROADMAP_OPTION") == "HYBRID",
        "official name": scope_values.get("OFFICIAL_NAME") == "Read-only catalog and component validation",
        "output": decision_values.get("SLICE1_VERTICAL_OUTPUT") == "ResolutionPreview" and "ResolutionPreview" in scope_values.get("OUTPUTS", ""),
        "malformed signature": "A malformed envelope returns a typed fail-closed error" in decision and "malformed is never a successful preview state" in scope,
        "trust unverified": "only constructible SLICE-1 value is\n`UNVERIFIED`" in scope and "cannot construct\n`trusted` or `verified`" in decision,
        "no new dependencies": "no new external dependency" in scope_values.get("DEPENDENCY_POLICY", ""),
    }
    for name, passed in cross.items():
        record("cross_" + name.replace(" ", "_"), passed, "cross_document_invariant", name + " failed")
    box_lines = re.findall(r"^\s*- \[([ xX])\] (.+)$", decision + "\n" + scope, re.MULTILINE)
    all_boxes = len(box_lines)
    checked_boxes = sum(1 for mark, _ in box_lines if mark in "xX")

    if mode == "review":
        record(
            "lifecycle_status",
            "Status: PROPOSED_FOR_OWNER_APPROVAL" in decision
            and scope_values.get("STATUS") == "PROPOSED_FOR_OWNER_APPROVAL",
            "review_status_invalid",
            "review mode requires PROPOSED_FOR_OWNER_APPROVAL decision and scope status",
        )
        record("owner_checkboxes", all_boxes == 8 and checked_boxes == 0, "review_checkbox_state_invalid", f"owner checkboxes {checked_boxes}/{all_boxes}")
        record(
            "no_approval_overclaim",
            not re.search(r"(?:Status:|STATUS=)\s*APPROVED", decision + "\n" + scope),
            "implementation_authorization_overclaim",
            "documentation claims approval",
        )
        record(
            "cross_implementation_unauthorized",
            scope_values.get("IMPLEMENTATION_AUTHORIZED") == "no",
            "cross_document_invariant",
            "implementation unauthorized failed",
        )
    elif mode == "approved":
        record(
            "lifecycle_status",
            "Status: APPROVED_BY_OWNER" in decision
            and scope_values.get("STATUS") == "APPROVED_BY_OWNER"
            and decision_values.get("DOCUMENTATION_CLOSURE_STATUS") == "APPROVED_BY_OWNER",
            "approved_status_invalid",
            "approved mode requires APPROVED_BY_OWNER decision, scope and closure status",
        )
        unchecked = [text for mark, text in box_lines if mark == " "]
        record(
            "owner_checkboxes",
            all_boxes == 8
            and checked_boxes == 7
            and len(unchecked) == 1
            and "Implementation may be authorized" in unchecked[0],
            "approved_checkbox_state_invalid",
            f"owner checkboxes {checked_boxes}/{all_boxes}; implementation control must remain unchecked",
        )
        record(
            "implementation_not_authorized",
            decision_values.get("SLICE1_IMPLEMENTATION_STATUS") == "NOT_AUTHORIZED"
            and decision_values.get("SLICE1_IMPLEMENTATION_AUTHORIZED") == "no",
            "implementation_authorization_overclaim",
            "SLICE-1 implementation must remain NOT_AUTHORIZED",
        )
        record(
            "cross_implementation_unauthorized",
            scope_values.get("IMPLEMENTATION_AUTHORIZED") == "no",
            "cross_document_invariant",
            "implementation unauthorized failed",
        )
        approved_head = decision_values.get("OWNER_APPROVED_REVIEW_HEAD", "")
        record(
            "approved_review_head",
            bool(re.fullmatch(r"[0-9a-f]{40}", approved_head)),
            "approved_review_head_invalid",
            "OWNER_APPROVED_REVIEW_HEAD must be a 40-character lowercase hex SHA",
        )
        approval_date = decision_values.get("OWNER_APPROVAL_DATE", "")
        record(
            "approval_date",
            valid_iso_date(approval_date),
            "approval_date_invalid",
            "OWNER_APPROVAL_DATE must be a valid ISO calendar date",
        )
    else:
        record(
            "lifecycle_status",
            "Status: APPROVED_BY_OWNER" in decision
            and scope_values.get("STATUS") == "APPROVED_BY_OWNER"
            and decision_values.get("DOCUMENTATION_CLOSURE_STATUS") == "APPROVED_BY_OWNER",
            "authorized_status_invalid",
            "authorized mode requires APPROVED_BY_OWNER decision, scope and closure status",
        )
        unchecked = [text for mark, text in box_lines if mark == " "]
        impl_box_checked = any(
            mark in "xX" and "Implementation may be authorized" in text for mark, text in box_lines
        )
        record(
            "owner_checkboxes",
            all_boxes == 8 and checked_boxes == 8 and not unchecked and impl_box_checked,
            "authorized_checkbox_state_invalid",
            f"owner checkboxes {checked_boxes}/{all_boxes}; all eight controls must be checked",
        )
        record(
            "implementation_status",
            decision_values.get("SLICE1_IMPLEMENTATION_STATUS") == "AUTHORIZED_NOT_STARTED",
            "authorized_implementation_status_invalid",
            "SLICE1_IMPLEMENTATION_STATUS must be AUTHORIZED_NOT_STARTED",
        )
        record(
            "implementation_flag",
            decision_values.get("SLICE1_IMPLEMENTATION_AUTHORIZED") == "yes"
            and scope_values.get("IMPLEMENTATION_AUTHORIZED") == "yes",
            "authorized_implementation_flag_invalid",
            "SLICE1_IMPLEMENTATION_AUTHORIZED and IMPLEMENTATION_AUTHORIZED must be yes",
        )
        record(
            "started_state",
            decision_values.get("SLICE1_IMPLEMENTATION_STARTED") == "no",
            "authorized_started_state_invalid",
            "SLICE1_IMPLEMENTATION_STARTED must be no",
        )
        record(
            "authorization_date",
            valid_iso_date(decision_values.get("OWNER_IMPLEMENTATION_AUTHORIZATION_DATE", "")),
            "authorization_date_invalid",
            "OWNER_IMPLEMENTATION_AUTHORIZATION_DATE must be a valid ISO calendar date",
        )
        record(
            "authorization_baseline",
            decision_values.get("OWNER_IMPLEMENTATION_BASELINE") == AUTHORIZED_BASELINE,
            "authorization_baseline_invalid",
            f"OWNER_IMPLEMENTATION_BASELINE must be exactly {AUTHORIZED_BASELINE}",
        )
        record(
            "authorization_branch",
            decision_values.get("OWNER_IMPLEMENTATION_BRANCH") == AUTHORIZED_BRANCH,
            "authorization_branch_invalid",
            f"OWNER_IMPLEMENTATION_BRANCH must be exactly {AUTHORIZED_BRANCH}",
        )
        owner_text_ok = (
            "I authorize implementation of SLICE-1 — Read-only catalog and component\nvalidation" in decision
            and "from approved governance baseline\n" + AUTHORIZED_BASELINE + ", on branch\n" + AUTHORIZED_BRANCH in decision
            and "component-manager/docs/SLICE_1_SCOPE.md" in decision
            and "does not extend to\nSLICE-2 or later capabilities" in decision
        )
        record(
            "authorization_text",
            owner_text_ok,
            "authorization_text_invalid",
            "owner authorization sentence must name SLICE-1, the exact baseline and branch, the scope document and the SLICE-2 exclusion",
        )
        later_overclaim = any(
            "SLICE-2" in line
            and re.search(r"\bauthorized\b", line)
            and "not authorized" not in line
            and "does not extend" not in line
            for line in (decision + "\n" + scope).splitlines()
        )
        record(
            "no_later_slice_overclaim",
            "SLICE-2 and later slices are not authorized" in decision and not later_overclaim,
            "later_slice_authorization_overclaim",
            "SLICE-2 or later slices must not be claimed authorized",
        )
        exit_release_overclaim = bool(
            re.search(
                r"EXIT_PASS|RELEASE_READY|SLICE1_IMPLEMENTATION_STARTED=yes|IMPLEMENTATION_STARTED=yes|\bIMPLEMENTED\b|\bCOMPLETE\b",
                decision + "\n" + scope,
            )
        )
        record(
            "no_exit_or_release_overclaim",
            "No exit claim is permitted" in decision
            and "No release is permitted" in decision
            and not exit_release_overclaim,
            "exit_or_release_overclaim",
            "no started, implemented, complete, exit-pass or release-ready claim is permitted",
        )

    if mode in ("approved", "authorized"):
        allowed_types = {entry.strip() for entry in scope_values.get("ALLOWED_TYPES", "").split(";") if entry.strip()}
        record(
            "allowed_types_facts",
            "future compatibility.Facts" in allowed_types,
            "allowed_types_invalid",
            "ALLOWED_TYPES must contain future compatibility.Facts",
        )

    allowed_changed = set(ALLOWED_CHANGED_PATHS)
    if mode in ("approved", "authorized"):
        allowed_changed |= APPROVED_EXTRA_ALLOWED_CHANGED_PATHS
    paths = path_sets(root, base_ref)
    for category, values in paths.items():
        unknown = sorted(values - allowed_changed)
        record(f"changed_paths_{category}", not unknown, "changed_path_forbidden", f"{category}: " + ",".join(unknown))

    metrics.update({
        "checked_owner_checkbox_count": checked_boxes,
        "owner_checkbox_count": all_boxes,
        "requirement_count": len(base_rows),
        "slice_count": len(SLICE_IDS),
        "split_requirement_count": len(split_rows),
        "to_be_defined_count": scope.count("TO_BE_DEFINED"),
    })
    return checks, errors, metrics


def result_payload(base_ref: str | None, head: str | None, mode: str | None, errors: list[dict[str, str]], checks: dict[str, str], metrics: dict[str, object] | None = None) -> dict[str, object]:
    payload: dict[str, object] = {
        "result": "FAIL" if errors else "PASS",
        "gate": GATE,
        "mode": mode,
        "base_ref": base_ref,
        "head": head,
        "errors": errors,
        "checks": checks,
    }
    if metrics:
        payload["metrics"] = metrics
    return payload


def main(argv: list[str] | None = None) -> int:
    base_ref: str | None = None
    head: str | None = None
    mode: str | None = None
    checks: dict[str, str] = {}
    errors: list[dict[str, str]] = []
    metrics: dict[str, object] = {}
    try:
        # No argparse help exit: every invocation must emit exactly one JSON result.
        parser = JSONArgumentParser(add_help=False)
        parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
        parser.add_argument("--base-ref")
        parser.add_argument("--mode")
        args = parser.parse_args(argv)
        mode = args.mode
        if not mode:
            raise GateFailure("mode_missing", "--mode is required: review|approved|authorized")
        if mode not in ("review", "approved", "authorized"):
            raise GateFailure("mode_invalid", f"unknown mode {mode!r}: expected review|approved|authorized")
        base_ref = args.base_ref
        if not base_ref:
            raise GateFailure("base_ref_missing", "--base-ref is required")
        root = args.repository.resolve()
        git(root, "rev-parse", "--show-toplevel", failure_code="git_repository_unavailable")
        head = git(root, "rev-parse", "HEAD").strip()
        git(root, "rev-parse", "--verify", f"{base_ref}^{{commit}}", failure_code="base_ref_invalid")
        try:
            git(root, "merge-base", "--is-ancestor", base_ref, "HEAD", failure_code="base_ref_not_ancestor")
        except GateFailure as error:
            if error.code == "base_ref_not_ancestor":
                raise GateFailure("base_ref_not_ancestor", f"base ref {base_ref} is not an ancestor of HEAD") from error
            raise
        checks, errors, metrics = run_check(root, base_ref, head, mode)
    except GateFailure as error:
        errors = [{"code": error.code, "message": str(error)}]
    except Exception as error:  # Last-resort fail-closed boundary.
        errors = [{"code": "internal_checker_error", "message": str(error)}]
    payload = result_payload(base_ref, head, mode, errors, checks, metrics)
    sys.stdout.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    return 0 if payload["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
