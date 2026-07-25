#!/usr/bin/env python3
"""Fail-closed, read-only changed-path gate for the SLICE-1 implementation branch.

The allowed and forbidden path sets are parsed exclusively from the approved
normative source ``component-manager/docs/SLICE_1_SCOPE.md``. This script never
invents its own allowlist; any parse failure, overlap, unknown path or
forbidden path fails closed with exactly one machine-readable JSON result.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

GATE = "slice1_changed_paths"
PHASES = ("pre-commit", "pre-push", "exit")
SCOPE_DOCUMENT = "component-manager/docs/SLICE_1_SCOPE.md"
EXIT_REQUIRED_PATH_CLASSES = {
    "new_pkg_artifact": "component-manager/pkg/artifact/",
    "new_pkg_provenance": "component-manager/pkg/provenance/",
    "new_pkg_compatibility": "component-manager/pkg/compatibility/",
    "new_pkg_resolution": "component-manager/pkg/resolution/",
    "exit_workflow": ".github/workflows/component-manager-slice1-cross-platform.yml",
}


class GateFailure(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


class JSONArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise GateFailure("cli_invalid", message)


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


def parse_path_set(values: dict[str, str], key: str) -> set[str]:
    raw = values.get(key)
    if raw is None:
        raise GateFailure("scope_path_set_invalid", f"missing normative key {key}")
    patterns = {entry.strip() for entry in raw.split(";") if entry.strip()}
    if not patterns:
        raise GateFailure("scope_path_set_invalid", f"empty normative path set {key}")
    for pattern in patterns:
        if "*" in pattern and not pattern.endswith("/**"):
            raise GateFailure("scope_path_set_invalid", f"unsupported pattern form: {pattern}")
    return patterns


def load_scope(root: Path) -> tuple[set[str], set[str], set[str]]:
    try:
        text = (root / SCOPE_DOCUMENT).read_text(encoding="utf-8")
    except OSError as error:
        raise GateFailure("scope_document_unavailable", str(error)) from error
    values = assignments(text)
    allowed = parse_path_set(values, "ALLOWED_PATHS")
    future = parse_path_set(values, "FUTURE_ALLOWED_PATHS")
    forbidden = parse_path_set(values, "FORBIDDEN_PATHS")
    if not future <= allowed:
        raise GateFailure("scope_path_set_invalid", "FUTURE_ALLOWED_PATHS is not a subset of ALLOWED_PATHS")
    if allowed & forbidden:
        raise GateFailure("scope_path_overlap", "allowed and forbidden paths overlap: " + ",".join(sorted(allowed & forbidden)))
    return allowed, future, forbidden


def matches(pattern: str, path: str) -> bool:
    if pattern.endswith("/**"):
        return path.startswith(pattern[:-3] + "/")
    return path == pattern


def classify(path: str, allowed: set[str], forbidden: set[str]) -> str | None:
    """Return a violation reason or None when the path is explicitly allowed."""
    if any(matches(pattern, path) for pattern in forbidden):
        return "forbidden"
    if any(matches(pattern, path) for pattern in allowed):
        return None
    return "unknown"


def path_sets(root: Path, base_ref: str, head_ref: str) -> dict[str, list[str]]:
    return {
        "committed": sorted(filter(None, git(root, "diff", "--name-only", base_ref, head_ref).splitlines())),
        "staged": sorted(filter(None, git(root, "diff", "--cached", "--name-only").splitlines())),
        "unstaged": sorted(filter(None, git(root, "diff", "--name-only").splitlines())),
        "untracked": sorted(filter(None, git(root, "ls-files", "--others", "--exclude-standard").splitlines())),
    }


def run_gate(root: Path, base_ref: str, head_ref: str, phase: str) -> tuple[dict[str, str], list[dict[str, str]], dict[str, list[str]], list[dict[str, str]]]:
    checks: dict[str, str] = {}
    errors: list[dict[str, str]] = []
    violations: list[dict[str, str]] = []

    def record(name: str, passed: bool, code: str, message: str) -> None:
        checks[name] = "PASS" if passed else "FAIL"
        if not passed:
            errors.append({"code": code, "message": message})

    allowed, _future, forbidden = load_scope(root)
    record("scope_path_sets", True, "scope_path_set_invalid", "")

    git(root, "rev-parse", "--verify", f"{base_ref}^{{commit}}", failure_code="base_ref_invalid")
    git(root, "rev-parse", "--verify", f"{head_ref}^{{commit}}", failure_code="head_ref_invalid")
    try:
        git(root, "merge-base", "--is-ancestor", base_ref, head_ref, failure_code="base_ref_not_ancestor")
        record("base_ancestor", True, "base_ref_not_ancestor", "")
    except GateFailure as error:
        if error.code == "base_ref_not_ancestor":
            raise GateFailure("base_ref_not_ancestor", f"base ref {base_ref} is not an ancestor of {head_ref}") from error
        raise

    sets = path_sets(root, base_ref, head_ref)
    for category, paths in sets.items():
        for path in paths:
            reason = classify(path, allowed, forbidden)
            if reason is not None:
                violations.append({"path": path, "category": category, "reason": reason})
        bad = [v for v in violations if v["category"] == category]
        record(
            f"{category}_paths",
            not bad,
            "path_forbidden" if any(v["reason"] == "forbidden" for v in bad) else "path_unknown",
            "; ".join(f"{v['reason']}: {v['path']}" for v in bad),
        )

    dirty = sets["staged"] + sets["unstaged"] + sets["untracked"]
    if phase in ("pre-push", "exit"):
        record("worktree_clean", not dirty, "worktree_dirty", "staged/unstaged/untracked paths present: " + ",".join(dirty))
    else:
        record("worktree_clean", True, "worktree_dirty", "")

    if phase == "exit":
        # The workflow class is an exact file; package classes are prefixes.
        missing = []
        for name, prefix in EXIT_REQUIRED_PATH_CLASSES.items():
            if prefix.endswith("/"):
                present = any(path.startswith(prefix) for path in sets["committed"])
            else:
                present = prefix in sets["committed"]
            if not present:
                missing.append(name)
        record("exit_required_paths", not missing, "exit_required_path_missing", "missing: " + ",".join(missing))

    return checks, errors, sets, violations


def result_payload(phase: str | None, base_ref: str | None, head_ref: str | None, errors: list[dict[str, str]], checks: dict[str, str], sets: dict[str, list[str]], violations: list[dict[str, str]]) -> dict[str, object]:
    return {
        "result": "FAIL" if errors else "PASS",
        "gate": GATE,
        "phase": phase,
        "base_ref": base_ref,
        "head_ref": head_ref,
        "committed_paths": sets.get("committed", []),
        "staged_paths": sets.get("staged", []),
        "unstaged_paths": sets.get("unstaged", []),
        "untracked_paths": sets.get("untracked", []),
        "violations": violations,
        "checks": checks,
        "errors": errors,
    }


def main(argv: list[str] | None = None) -> int:
    phase: str | None = None
    base_ref: str | None = None
    head_ref: str | None = None
    checks: dict[str, str] = {}
    errors: list[dict[str, str]] = []
    sets: dict[str, list[str]] = {}
    violations: list[dict[str, str]] = []
    try:
        # No argparse help exit: every invocation must emit exactly one JSON result.
        parser = JSONArgumentParser(add_help=False)
        parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
        parser.add_argument("--base-ref")
        parser.add_argument("--head-ref", default="HEAD")
        parser.add_argument("--phase")
        args = parser.parse_args(argv)
        phase = args.phase
        if not phase:
            raise GateFailure("phase_missing", "--phase is required: pre-commit|pre-push|exit")
        if phase not in PHASES:
            raise GateFailure("phase_invalid", f"unknown phase {phase!r}: expected pre-commit|pre-push|exit")
        base_ref = args.base_ref
        if not base_ref:
            raise GateFailure("base_ref_missing", "--base-ref is required")
        head_ref = args.head_ref
        root = args.repository.resolve()
        git(root, "rev-parse", "--show-toplevel", failure_code="git_repository_unavailable")
        checks, errors, sets, violations = run_gate(root, base_ref, head_ref, phase)
    except GateFailure as error:
        errors = [{"code": error.code, "message": str(error)}]
    except Exception as error:  # Last-resort fail-closed boundary.
        errors = [{"code": "internal_gate_error", "message": str(error)}]
    payload = result_payload(phase, base_ref, head_ref, errors, checks, sets, violations)
    sys.stdout.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    return 0 if payload["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
