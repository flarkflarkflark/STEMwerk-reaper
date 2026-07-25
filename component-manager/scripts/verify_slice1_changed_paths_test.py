#!/usr/bin/env python3
"""Fail-closed tests for the SLICE-1 changed-path gate using real temporary Git repositories."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "component-manager/scripts/verify_slice1_changed_paths.py"
SCOPE = "component-manager/docs/SLICE_1_SCOPE.md"
EXIT_PACKAGE_PATHS = [
    "component-manager/pkg/artifact/artifact.go",
    "component-manager/pkg/provenance/provenance.go",
    "component-manager/pkg/compatibility/evaluate.go",
    "component-manager/pkg/resolution/preview.go",
]
EXIT_WORKFLOW = ".github/workflows/component-manager-slice1-cross-platform.yml"


class ChangedPathGateTests(unittest.TestCase):
    def fixture(self) -> tuple[Path, str]:
        temporary = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temporary)
        target = temporary / SCOPE
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / SCOPE, target)
        self.git(temporary, "init", "-q")
        self.git(temporary, "config", "user.name", "Fixture")
        self.git(temporary, "config", "user.email", "fixture@example.invalid")
        self.git(temporary, "add", ".")
        self.git(temporary, "commit", "-qm", "baseline")
        base = self.git(temporary, "rev-parse", "HEAD").stdout.strip()
        return temporary, base

    def git(self, root: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(["git", *arguments], cwd=root, text=True, capture_output=True, check=True)

    def run_gate(self, root: Path, base: str | None, phase: str | None = "pre-push", head: str | None = None) -> subprocess.CompletedProcess[str]:
        command = [sys.executable, str(GATE), "--repository", str(root)]
        if base is not None:
            command.extend(["--base-ref", base])
        if phase is not None:
            command.extend(["--phase", phase])
        if head is not None:
            command.extend(["--head-ref", head])
        return subprocess.run(command, text=True, capture_output=True)

    def payload(self, result: subprocess.CompletedProcess[str]) -> dict:
        return json.loads(result.stdout)

    def assert_pass(self, root: Path, base: str, phase: str = "pre-push") -> dict:
        result = self.run_gate(root, base, phase)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return self.payload(result)

    def assert_fail(self, root: Path, base: str | None, phase: str | None = "pre-push", head: str | None = None) -> dict:
        result = self.run_gate(root, base, phase, head)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        data = self.payload(result)
        self.assertEqual(data["result"], "FAIL")
        return data

    def write(self, root: Path, relative: str, content: str = "x\n") -> None:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def commit_paths(self, root: Path, paths: list[str], message: str = "change") -> None:
        for relative in paths:
            self.write(root, relative)
        self.git(root, "add", ".")
        self.git(root, "commit", "-qm", message)

    # --- positive: explicitly allowed paths ---

    def test_allowed_new_package_path_passes(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, ["component-manager/pkg/artifact/artifact.go"])
        self.assert_pass(root, base)

    def test_allowed_existing_package_change_passes(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, ["component-manager/pkg/catalog/catalog.go"])
        self.assert_pass(root, base)

    def test_allowed_testdata_path_passes(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, ["component-manager/testdata/slice1/case.json"])
        self.assert_pass(root, base)

    def test_allowed_script_change_passes(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, ["component-manager/scripts/extra_gate.py"])
        self.assert_pass(root, base)

    def test_allowed_exact_workflow_passes(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, [EXIT_WORKFLOW])
        self.assert_pass(root, base)

    def test_pre_commit_with_staged_and_committed_allowed_passes(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, ["component-manager/pkg/resolution/preview.go"])
        self.write(root, "component-manager/pkg/artifact/artifact.go")
        self.git(root, "add", "component-manager/pkg/artifact/artifact.go")
        self.assert_pass(root, base, "pre-commit")

    # --- negative: forbidden and unknown paths per category ---

    def test_committed_contract_v1_fails(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, ["experiments/component-manager-poa0/contract-v1/CHANGED.md"])
        data = self.assert_fail(root, base)
        self.assertEqual(data["violations"][0]["reason"], "forbidden")

    def test_committed_schema_fails(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, ["component-manager/schemas/artifact.schema.json"])
        self.assert_fail(root, base)

    def test_committed_go_mod_fails(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, ["component-manager/go.mod"])
        self.assert_fail(root, base)

    def test_committed_go_sum_fails(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, ["component-manager/go.sum"])
        self.assert_fail(root, base)

    def test_committed_internal_store_fails(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, ["component-manager/internal/store/files/store.go"])
        self.assert_fail(root, base)

    def test_committed_helper_fails(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, ["component-manager/internal/helper/client.go"])
        self.assert_fail(root, base)

    def test_committed_other_workflow_fails(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, [".github/workflows/other.yml"])
        data = self.assert_fail(root, base)
        self.assertEqual(data["violations"][0]["reason"], "unknown")

    def test_unknown_top_level_path_fails(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, ["installer/new.txt"])
        data = self.assert_fail(root, base)
        self.assertEqual(data["violations"][0]["reason"], "unknown")

    def test_product_path_outside_allowlist_fails(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, ["component-manager/cmd/new_product.go"])
        self.assert_fail(root, base)

    def test_staged_forbidden_fails(self) -> None:
        root, base = self.fixture()
        self.write(root, "component-manager/go.mod")
        self.git(root, "add", "component-manager/go.mod")
        data = self.assert_fail(root, base, "pre-commit")
        self.assertEqual(data["violations"][0]["category"], "staged")

    def test_unstaged_forbidden_fails(self) -> None:
        root, base = self.fixture()
        # Track a forbidden path in a new baseline so only the unstaged
        # modification is visible to the gate.
        self.commit_paths(root, ["component-manager/go.sum"], "track forbidden file")
        tracked_base = self.git(root, "rev-parse", "HEAD").stdout.strip()
        self.write(root, "component-manager/go.sum", "mutated\n")
        data = self.assert_fail(root, tracked_base, "pre-commit")
        self.assertEqual(data["violations"][0]["category"], "unstaged")
        self.assertEqual(data["violations"][0]["reason"], "forbidden")

    def test_untracked_forbidden_fails(self) -> None:
        root, base = self.fixture()
        self.write(root, "component-manager/internal/store/new.go")
        data = self.assert_fail(root, base, "pre-commit")
        self.assertEqual(data["violations"][0]["category"], "untracked")

    def test_committed_forbidden_fails(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, ["component-manager/go.mod"])
        data = self.assert_fail(root, base)
        self.assertEqual(data["violations"][0]["category"], "committed")

    # --- negative: git and cli failure modes ---

    def test_non_ancestor_base_fails_closed(self) -> None:
        root, base = self.fixture()
        self.git(root, "checkout", "-q", "--orphan", "unrelated")
        self.git(root, "add", ".")
        self.git(root, "commit", "-qm", "unrelated")
        unrelated = self.git(root, "rev-parse", "HEAD").stdout.strip()
        self.git(root, "checkout", "-q", "master")
        data = self.assert_fail(root, unrelated)
        self.assertEqual(data["errors"][0]["code"], "base_ref_not_ancestor")

    def test_invalid_base_ref_fails_closed(self) -> None:
        root, base = self.fixture()
        data = self.assert_fail(root, "not-a-ref")
        self.assertEqual(data["errors"][0]["code"], "base_ref_invalid")

    def test_missing_base_ref_fails_closed(self) -> None:
        root, _ = self.fixture()
        data = self.assert_fail(root, None)
        self.assertEqual(data["errors"][0]["code"], "base_ref_missing")

    def test_invalid_head_ref_fails_closed(self) -> None:
        root, base = self.fixture()
        data = self.assert_fail(root, base, head="not-a-head")
        self.assertEqual(data["errors"][0]["code"], "head_ref_invalid")

    def test_invalid_phase_fails_closed(self) -> None:
        root, base = self.fixture()
        data = self.assert_fail(root, base, phase="sideways")
        self.assertEqual(data["errors"][0]["code"], "phase_invalid")

    def test_missing_phase_fails_closed(self) -> None:
        root, base = self.fixture()
        data = self.assert_fail(root, base, phase=None)
        self.assertEqual(data["errors"][0]["code"], "phase_missing")

    # --- negative: normative path set integrity ---

    def test_path_overlap_injection_fails_closed(self) -> None:
        root, base = self.fixture()
        scope_path = root / SCOPE
        text = scope_path.read_text(encoding="utf-8")
        scope_path.write_text(text.replace("FORBIDDEN_PATHS=", "FORBIDDEN_PATHS=component-manager/pkg/artifact/**; ", 1), encoding="utf-8")
        data = self.assert_fail(root, base)
        self.assertEqual(data["errors"][0]["code"], "scope_path_overlap")

    def test_malformed_scope_document_fails_closed(self) -> None:
        root, base = self.fixture()
        scope_path = root / SCOPE
        text = scope_path.read_text(encoding="utf-8")
        scope_path.write_text(text.replace("ALLOWED_PATHS=", "REMOVED_ALLOWED_PATHS=", 1), encoding="utf-8")
        data = self.assert_fail(root, base)
        self.assertEqual(data["errors"][0]["code"], "scope_path_set_invalid")

    # --- negative: phase-specific cleanliness and exit requirements ---

    def test_dirty_worktree_pre_push_fails(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, ["component-manager/pkg/artifact/artifact.go"])
        self.write(root, "component-manager/pkg/catalog/dirty.go")
        data = self.assert_fail(root, base, "pre-push")
        self.assertEqual(data["checks"]["worktree_clean"], "FAIL")

    def test_dirty_worktree_exit_fails(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, EXIT_PACKAGE_PATHS + [EXIT_WORKFLOW])
        self.write(root, "component-manager/pkg/catalog/dirty.go")
        data = self.assert_fail(root, base, "exit")
        self.assertEqual(data["checks"]["worktree_clean"], "FAIL")

    def test_exit_with_all_required_path_classes_passes(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, EXIT_PACKAGE_PATHS + [EXIT_WORKFLOW])
        data = self.assert_pass(root, base, "exit")
        self.assertEqual(data["checks"]["exit_required_paths"], "PASS")

    def test_exit_missing_required_package_fails(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, EXIT_PACKAGE_PATHS[:3] + [EXIT_WORKFLOW])
        data = self.assert_fail(root, base, "exit")
        self.assertEqual(data["checks"]["exit_required_paths"], "FAIL")

    def test_exit_missing_workflow_fails(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, EXIT_PACKAGE_PATHS)
        data = self.assert_fail(root, base, "exit")
        self.assertEqual(data["checks"]["exit_required_paths"], "FAIL")

    def test_machine_readable_shape(self) -> None:
        root, base = self.fixture()
        self.commit_paths(root, ["component-manager/go.mod"])
        data = self.assert_fail(root, base)
        for key in ("result", "gate", "phase", "base_ref", "head_ref", "committed_paths", "staged_paths", "unstaged_paths", "untracked_paths", "violations", "checks"):
            self.assertIn(key, data)
        self.assertEqual(data["gate"], "slice1_changed_paths")


if __name__ == "__main__":
    unittest.main()
