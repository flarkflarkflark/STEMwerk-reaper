#!/usr/bin/env python3
"""Fail-closed local SLICE-1 fast gate.

Orchestrates the existing read-only verification steps in a fixed fail-fast
order. This script implements no product semantics itself and writes nothing
into the repository; every helper summary is redirected to a temporary
directory outside the worktree.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

GATE = "slice1_fast_gate"
PHASES = ("pre-commit", "pre-push")
MODES = ("review", "approved", "authorized")
SCRIPTS = "component-manager/scripts"
MODULE = "component-manager"
SCHEMA_AUTHORITY_DIR = "experiments/component-manager-poa0/contract-v1/schemas"
SCHEMA_EMBEDDED_DIR = "component-manager/schemas"
SCHEMA_MANIFEST = "component-manager/schemas/SHA256SUMS"
SCHEMA_EXPECTED_COUNT = "21"
SLICE1_PACKAGES = ("artifact", "provenance", "compatibility", "resolution")
IMPORT_GRAPH_RULES = {
    "compatibility": ("pkg/generation",),
    "resolution": ("pkg/generation", "pkg/state", "pkg/trust", "pkg/revocation", "pkg/signature", "internal/store"),
    "artifact": ("pkg/catalog",),
    "provenance": (),
}
FORBIDDEN_IMPORTS = {
    "os", "os/exec", "io/fs", "path/filepath", "net", "net/http", "database/sql",
    "time", "math/rand", "syscall", "unsafe",
}
FORBIDDEN_IMPORT_PREFIXES = ("crypto/", "golang.org/x/sys")
IMPORT_BLOCK = re.compile(r'import\s*\(([^)]*)\)|import\s+"([^"]+)"', re.DOTALL)
IMPORT_PATH = re.compile(r'"([^"]+)"')

STEP_NAMES = [
    "preflight",
    "documentation_checker",
    "changed_paths",
    "gofmt",
    "go_vet",
    "go_test",
    "module_integrity",
    "schema_contract_drift",
    "import_packagegraph_guard",
    "forbidden_import_guard",
    "worktree_hygiene",
]


class GateFailure(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


class JSONArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise GateFailure("cli_invalid", message)


def go_environment() -> dict[str, str]:
    env = dict(os.environ)
    # Read-only module policy: never rewrite go.mod/go.sum, never download.
    env["GOFLAGS"] = "-mod=readonly"
    env["GOPROXY"] = "off"
    return env


def run_command(command: list[str], cwd: Path, env: dict[str, str] | None = None) -> tuple[int, str]:
    try:
        result = subprocess.run(command, cwd=cwd, text=True, capture_output=True, env=env, check=False)
    except FileNotFoundError:
        return 127, f"tool missing: {command[0]}"
    except OSError as error:
        return 127, f"tool unavailable: {error}"
    output = (result.stdout + result.stderr).strip().splitlines()
    summary = output[-1][:300] if output else f"exit {result.returncode}"
    return result.returncode, summary


def git(root: Path, *arguments: str) -> tuple[int, str]:
    return run_command(["git", *arguments], cwd=root)


def slice1_go_files(root: Path) -> list[Path]:
    files: list[Path] = []
    for package in SLICE1_PACKAGES:
        directory = root / MODULE / "pkg" / package
        if directory.is_dir():
            files.extend(sorted(directory.rglob("*.go")))
    return files


def imports_of(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8")
    found: set[str] = set()
    for block, single in IMPORT_BLOCK.findall(text):
        if single:
            found.add(single)
        for candidate in IMPORT_PATH.findall(block):
            found.add(candidate)
    return found


def main(argv: list[str] | None = None) -> int:
    base_ref: str | None = None
    mode: str | None = None
    phase: str | None = None
    head: str | None = None
    steps: list[dict[str, object]] = []
    errors: list[dict[str, str]] = []

    def record(name: str, result: str, exit_code: int | None, summary: str) -> bool:
        steps.append({"name": name, "result": result, "exit_code": exit_code, "summary": summary})
        return result == "PASS"

    try:
        # No argparse help exit: every invocation must emit exactly one JSON result.
        parser = JSONArgumentParser(add_help=False)
        parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
        parser.add_argument("--base-ref")
        parser.add_argument("--documentation-mode")
        parser.add_argument("--phase")
        parser.add_argument("--head-ref", default="HEAD")
        args = parser.parse_args(argv)
        mode = args.documentation_mode
        if not mode:
            raise GateFailure("documentation_mode_missing", "--documentation-mode is required: review|approved")
        if mode not in MODES:
            raise GateFailure("documentation_mode_invalid", f"unknown documentation mode {mode!r}")
        phase = args.phase
        if not phase:
            raise GateFailure("phase_missing", "--phase is required: pre-commit|pre-push")
        if phase not in PHASES:
            raise GateFailure("phase_invalid", f"unknown phase {phase!r}")
        base_ref = args.base_ref
        if not base_ref:
            raise GateFailure("base_ref_missing", "--base-ref is required")
        root = args.repository.resolve()
        module_dir = root / MODULE
        scripts_dir = root / SCRIPTS
        go_env = go_environment()

        def step_preflight() -> tuple[int, str]:
            code, out = git(root, "rev-parse", "--show-toplevel")
            if code:
                return code, "not a git repository: " + out
            code, head_sha = git(root, "rev-parse", args.head_ref)
            if code:
                return code, "head ref invalid: " + head_sha
            nonlocal head
            head = head_sha.strip()
            code, out = git(root, "rev-parse", "--verify", f"{base_ref}^{{commit}}")
            if code:
                return code, "base ref invalid: " + out
            code, out = git(root, "merge-base", "--is-ancestor", base_ref, args.head_ref)
            if code:
                return code, f"base ref {base_ref} is not an ancestor of {args.head_ref}"
            return 0, f"head={head} base={base_ref}"

        def step_documentation_checker() -> tuple[int, str]:
            return run_command(
                [sys.executable, str(scripts_dir / "verify_slice1_documentation.py"),
                 "--repository", str(root), "--mode", mode, "--base-ref", base_ref],
                cwd=root,
            )

        def step_changed_paths() -> tuple[int, str]:
            return run_command(
                [sys.executable, str(scripts_dir / "verify_slice1_changed_paths.py"),
                 "--repository", str(root), "--base-ref", base_ref,
                 "--head-ref", args.head_ref, "--phase", phase],
                cwd=root,
            )

        def step_gofmt() -> tuple[int, str]:
            if shutil.which("gofmt") is None:
                return 127, "tool missing: gofmt"
            try:
                result = subprocess.run(["gofmt", "-l", "."], cwd=module_dir, text=True, capture_output=True, env=go_env, check=False)
            except OSError as error:
                return 127, f"tool unavailable: {error}"
            if result.returncode:
                return result.returncode, "gofmt failed: " + result.stderr.strip()[:300]
            listed = result.stdout.strip()
            if listed:
                return 1, "unformatted files: " + listed.replace("\n", ",")[:300]
            return 0, "all Go files formatted"

        def step_go_vet() -> tuple[int, str]:
            if shutil.which("go") is None:
                return 127, "tool missing: go"
            return run_command(["go", "vet", "./..."], cwd=module_dir, env=go_env)

        def step_go_test() -> tuple[int, str]:
            if shutil.which("go") is None:
                return 127, "tool missing: go"
            return run_command(["go", "test", "./..."], cwd=module_dir, env=go_env)

        def step_module_integrity() -> tuple[int | None, str]:
            if phase == "pre-commit":
                tracked = subprocess.run(
                    ["git", "status", "--porcelain", "--untracked-files=no"],
                    cwd=root, text=True, capture_output=True, check=False,
                )
                if tracked.returncode == 0 and tracked.stdout.strip():
                    # verify_module_integrity requires a clean tracked worktree;
                    # pre-push enforces it unconditionally.
                    return None, "deferred to pre-push: tracked worktree has open changes"
            evidence = temporary / "module-integrity"
            return run_command(
                [sys.executable, str(scripts_dir / "verify_module_integrity.py"),
                 "--module-dir", str(module_dir), "--evidence-dir", str(evidence)],
                cwd=root,
            )

        def step_schema_contract_drift() -> tuple[int, str]:
            return run_command(
                [sys.executable, str(scripts_dir / "verify_schema_authority.py"),
                 "--repository", str(root),
                 "--authority-dir", SCHEMA_AUTHORITY_DIR,
                 "--embedded-dir", SCHEMA_EMBEDDED_DIR,
                 "--manifest", SCHEMA_MANIFEST,
                 "--expected-count", SCHEMA_EXPECTED_COUNT,
                 "--summary", str(temporary / "schema-authority.json")],
                cwd=root,
            )

        def step_import_packagegraph_guard() -> tuple[int, str]:
            files = slice1_go_files(root)
            if not files:
                return 0, "no SLICE-1 package sources present"
            violations: list[str] = []
            for path in files:
                package = path.relative_to(root / MODULE / "pkg").parts[0]
                banned = IMPORT_GRAPH_RULES.get(package, ())
                for imported in imports_of(path):
                    if any(rule in imported for rule in banned):
                        violations.append(f"{path.relative_to(root)} imports {imported}")
            if violations:
                return 1, "; ".join(violations)[:300]
            return 0, f"{len(files)} files clean"

        def step_forbidden_import_guard() -> tuple[int, str]:
            files = slice1_go_files(root)
            if not files:
                return 0, "no SLICE-1 package sources present"
            violations: list[str] = []
            for path in files:
                for imported in imports_of(path):
                    if imported in FORBIDDEN_IMPORTS or any(imported.startswith(prefix) for prefix in FORBIDDEN_IMPORT_PREFIXES):
                        violations.append(f"{path.relative_to(root)} imports {imported}")
            if violations:
                return 1, "; ".join(violations)[:300]
            return 0, f"{len(files)} files clean"

        def step_worktree_hygiene() -> tuple[int, str]:
            try:
                result = subprocess.run(["git", "status", "--porcelain"], cwd=root, text=True, capture_output=True, check=False)
            except OSError as error:
                return 127, f"worktree status unavailable: {error}"
            if result.returncode:
                return result.returncode, "worktree status unavailable: " + result.stderr.strip()[:300]
            entries = [line for line in result.stdout.splitlines() if line]
            if phase == "pre-push" and entries:
                return 1, f"worktree not clean: {len(entries)} entries"
            return 0, f"{len(entries)} open entries (phase {phase})"

        step_functions = {
            "preflight": step_preflight,
            "documentation_checker": step_documentation_checker,
            "changed_paths": step_changed_paths,
            "gofmt": step_gofmt,
            "go_vet": step_go_vet,
            "go_test": step_go_test,
            "module_integrity": step_module_integrity,
            "schema_contract_drift": step_schema_contract_drift,
            "import_packagegraph_guard": step_import_packagegraph_guard,
            "forbidden_import_guard": step_forbidden_import_guard,
            "worktree_hygiene": step_worktree_hygiene,
        }

        with tempfile.TemporaryDirectory(prefix="slice1-fast-gate-") as temporary_directory:
            temporary = Path(temporary_directory)
            failed = False
            for name in STEP_NAMES:
                if failed:
                    record(name, "NOT_RUN", None, "skipped after earlier failure")
                    continue
                code, summary = step_functions[name]()
                if code is None:
                    record(name, "NOT_RUN", None, summary)
                elif code == 0:
                    record(name, "PASS", code, summary)
                else:
                    record(name, "FAIL", code, summary)
                    errors.append({"code": "step_failed", "message": f"{name}: {summary}"})
                    failed = True
    except GateFailure as error:
        errors = [{"code": error.code, "message": str(error)}]
    except Exception as error:  # Last-resort fail-closed boundary.
        errors = [{"code": "internal_gate_error", "message": str(error)}]

    payload = {
        "result": "FAIL" if errors else "PASS",
        "gate": GATE,
        "phase": phase,
        "documentation_mode": mode,
        "base_ref": base_ref,
        "head": head,
        "steps": steps,
        "errors": errors,
    }
    sys.stdout.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    return 0 if payload["result"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
