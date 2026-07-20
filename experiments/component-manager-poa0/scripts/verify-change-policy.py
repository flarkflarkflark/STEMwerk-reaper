#!/usr/bin/env python3
"""Fail-closed change-domain policy for the disposable POA-0 verifier."""

from __future__ import annotations

import argparse
import hashlib
import subprocess
import sys
from pathlib import Path

BASELINE = "9bf06029f2c1b24db0fd4e680f8d8e2e289dcd6b"
TARGET = "ec14fdf523524bbd9aec34d429f0b6a5b673a701"


def implementation_path(path: str) -> bool:
    return path in {
        "experiments/component-manager-poa0/rust/Cargo.toml",
        "experiments/component-manager-poa0/rust/Cargo.lock",
    } or path.startswith(
        (
            "experiments/component-manager-poa0/rust/src/",
            "experiments/component-manager-poa0/rust/tests/",
        )
    )


def orchestration_path(path: str) -> bool:
    return path == ".github/workflows/component-manager-poa0-native.yml"


def documentation_path(path: str) -> bool:
    return path == (
        "experiments/component-manager-poa0/reports/"
        "WINDOWS_RUST_IN_PROCESS_SHA256_FIX.md"
    )


FEATURE_RULES = {
    "IMPLEMENTATION_SOURCE_RUST": implementation_path,
    "TEST_ORCHESTRATION": orchestration_path,
    "DOCUMENTATION": documentation_path,
}

POLICY_PATHS = {
    ".github/workflows/component-manager-poa0-native.yml",
    "experiments/component-manager-poa0/reports/FROZEN_VERIFIER_DOMAIN_SEPARATION_V2.md",
    "experiments/component-manager-poa0/scripts/run-native-matrix.ps1",
    "experiments/component-manager-poa0/scripts/run-native-matrix.sh",
    "experiments/component-manager-poa0/scripts/test-verifier-policy.py",
    "experiments/component-manager-poa0/scripts/verify-change-policy.py",
    "experiments/component-manager-poa0/scripts/verify-frozen-fixtures.ps1",
    "experiments/component-manager-poa0/scripts/verify-frozen-fixtures.sh",
}


class PolicyError(RuntimeError):
    pass


def classify(path: str, rules=FEATURE_RULES) -> str:
    normalized = path.replace("\\", "/")
    matches = [name for name, predicate in rules.items() if predicate(normalized)]
    if len(matches) != 1:
        raise PolicyError(
            f"path must classify exactly once: {normalized} (matches={','.join(matches) or 'none'})"
        )
    return matches[0]


def validate_feature_paths(paths: list[str]) -> dict[str, list[str]]:
    classified = {name: [] for name in FEATURE_RULES}
    for path in paths:
        classified[classify(path)].append(path.replace("\\", "/"))
    return classified


def validate_post_target_paths(paths: list[str]) -> None:
    forbidden = sorted({path.replace("\\", "/") for path in paths} - POLICY_PATHS)
    if forbidden:
        raise PolicyError(f"forbidden post-target policy path: {','.join(forbidden)}")


def validate_mode(mode: str) -> None:
    if mode not in {"strict", "rust-implementation-fix"}:
        raise PolicyError(f"invalid verification mode: {mode}")


def validate_changed_paths(mode: str, paths: list[str]) -> dict[str, list[str]]:
    validate_mode(mode)
    if mode == "strict":
        if paths:
            raise PolicyError("strict mode rejects repository drift")
        return {name: [] for name in FEATURE_RULES}
    return validate_feature_paths(paths)


def verify_digest(path: Path, expected: str) -> None:
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != expected:
        raise PolicyError(f"manifest hash drift: expected {expected}, actual {actual}")


def git_paths(repo: Path, older: str, newer: str) -> list[str]:
    output = subprocess.run(
        ["git", "diff", "--name-only", older, newer],
        cwd=repo,
        check=True,
        text=True,
        capture_output=True,
    ).stdout
    return [line for line in output.splitlines() if line]


def git_output(repo: Path, *arguments: str) -> str:
    return subprocess.run(
        ["git", *arguments],
        cwd=repo,
        check=True,
        text=True,
        capture_output=True,
    ).stdout.strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", required=True)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--baseline", default="")
    parser.add_argument("--target", default="")
    parser.add_argument("--workflow-head", default="")
    args = parser.parse_args()
    try:
        validate_mode(args.mode)
        if args.mode == "strict":
            print("CHANGE_POLICY_VERIFY=PASS mode=strict")
            return 0
        if args.baseline != BASELINE or args.target != TARGET:
            raise PolicyError("implementation-fix baseline or target is not authorized")
        actual_head = git_output(args.repo, "rev-parse", "HEAD")
        if not args.workflow_head or args.workflow_head != actual_head:
            raise PolicyError("workflow head does not match checked-out HEAD")
        classified = validate_changed_paths(
            args.mode,
            git_paths(args.repo, args.baseline, args.target)
        )
        validate_post_target_paths(git_paths(args.repo, args.target, args.workflow_head))
        print(f"FEATURE_DIFF_BASELINE={args.baseline}")
        print(f"FEATURE_DIFF_TARGET={args.target}")
        print(f"WORKFLOW_HEAD_POLICY_DIFF_BASE={args.target}")
        for domain, paths in classified.items():
            print(f"{domain}_PATHS={','.join(paths)}")
        print("FEATURE_DIFF_PATHS_ALLOWED=yes")
        print("POST_TARGET_POLICY_PATHS_ALLOWED=yes")
        print("CHANGE_POLICY_VERIFY=PASS mode=rust-implementation-fix")
        return 0
    except (PolicyError, subprocess.CalledProcessError, OSError) as error:
        print(f"CHANGE_POLICY_VERIFY=FAIL {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
