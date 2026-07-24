#!/usr/bin/env python3
"""Negative-fixture tests for the fail-closed SLICE-1 documentation checker."""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "component-manager/scripts/verify_slice1_documentation.py"
FILES = [
    "experiments/component-manager-poa0/production-readiness/VERTICAL_SLICES.md",
    "experiments/component-manager-poa0/production-readiness/READINESS_TRACEABILITY.md",
    "experiments/component-manager-poa0/production-readiness/GO_PACKAGE_PLAN.md",
    "experiments/component-manager-poa0/production-readiness/SLICE_1_AND_ROADMAP_ARCHITECTURE_DECISION.md",
    "component-manager/docs/SLICE_1_SCOPE.md",
    "experiments/component-manager-poa0/contract-v1/COMPONENT_MANAGER_CONTRACT_V1.md",
    "component-manager/schemas/artifact.schema.json",
    "component-manager/pkg/contract/error.go",
]


class DocumentationCheckerTests(unittest.TestCase):
    def fixture(self) -> tuple[Path, str]:
        temporary = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temporary)
        for relative in FILES:
            target = temporary / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, target)
        subprocess.run(["git", "init", "-q"], cwd=temporary, check=True)
        subprocess.run(["git", "config", "user.name", "Fixture"], cwd=temporary, check=True)
        subprocess.run(["git", "config", "user.email", "fixture@example.invalid"], cwd=temporary, check=True)
        subprocess.run(["git", "add", "."], cwd=temporary, check=True)
        subprocess.run(["git", "commit", "-qm", "baseline"], cwd=temporary, check=True)
        base = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=temporary, check=True,
            text=True, capture_output=True,
        ).stdout.strip()
        return temporary, base

    def run_checker(self, root: Path, base: str | None) -> subprocess.CompletedProcess[str]:
        command = [sys.executable, str(CHECKER), "--repository", str(root)]
        if base is not None:
            command.extend(["--base-ref", base])
        return subprocess.run(command, text=True, capture_output=True)

    def mutate(self, root: Path, relative: str, old: str, new: str) -> None:
        path = root / relative
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    def assert_fails(self, root: Path, base: str) -> None:
        result = self.run_checker(root, base)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["result"], "FAIL")

    def commit(self, root: Path, message: str) -> None:
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", message], cwd=root, check=True)

    def test_current_documents_pass(self) -> None:
        result = self.run_checker(ROOT, "ab59eef7d00de7e0d6e4d2467fb815a3d0975eb3")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_base_ref_is_required(self) -> None:
        root, _ = self.fixture()
        self.assertNotEqual(self.run_checker(root, None).returncode, 0)

    def test_missing_slice_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[0], "### SLICE-10", "### OMITTED")
        self.assert_fails(root, base)

    def test_to_be_defined_fails_closed(self) -> None:
        root, base = self.fixture()
        (root / FILES[4]).write_text((root / FILES[4]).read_text() + "\nOPEN=TO_BE_DEFINED\n")
        self.assert_fails(root, base)

    def test_path_overlap_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "FORBIDDEN_PATHS=", "FORBIDDEN_PATHS=component-manager/pkg/artifact/**; ")
        self.assert_fails(root, base)

    def test_committed_contract_change_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[5], "# STEMwerk", "# Changed STEMwerk")
        self.commit(root, "change contract")
        self.assert_fails(root, base)

    def test_committed_schema_change_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[6], '"title":', '"description": "changed",\n  "title":')
        self.commit(root, "change schema")
        self.assert_fails(root, base)

    def test_unstaged_contract_change_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[5], "# STEMwerk", "# Unstaged STEMwerk")
        self.assert_fails(root, base)

    def test_staged_schema_change_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[6], '"title":', '"description": "staged",\n  "title":')
        subprocess.run(["git", "add", FILES[6]], cwd=root, check=True)
        self.assert_fails(root, base)

    def test_untracked_frozen_path_fails_closed(self) -> None:
        root, base = self.fixture()
        path = root / "component-manager/internal/new_effect.go"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("package internal\n")
        self.assert_fails(root, base)

    def test_missing_split_row_fails_closed(self) -> None:
        root, base = self.fixture()
        path = root / FILES[1]
        lines = [line for line in path.read_text().splitlines() if not line.startswith("| CMV1-FAIL-005 | SLICE-")]
        path.write_text("\n".join(lines) + "\n")
        self.assert_fails(root, base)

    def test_missing_first_exercised_slice_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[1], "| CMV1-FAIL-003 | SLICE-1 | SLICE-1 | SLICE-3 | SLICE-1 |", "| CMV1-FAIL-003 | SLICE-1 | SLICE-1 | SLICE-3 |  |")
        self.assert_fails(root, base)

    def test_missing_reverified_slices_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[1], "| CMV1-FAIL-004 | SLICE-1 | SLICE-1 | SLICE-3 | SLICE-1 | SLICE-3 |", "| CMV1-FAIL-004 | SLICE-1 | SLICE-1 | SLICE-3 | SLICE-1 |  |")
        self.assert_fails(root, base)

    def test_decision_scope_output_divergence_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[3], "ResolutionPreview", "DifferentPreview")
        self.assert_fails(root, base)

    def test_checked_owner_checkbox_fails_closed(self) -> None:
        root, base = self.fixture()
        path = root / FILES[3]
        path.write_text(path.read_text() + "\n- [x] Owner approved\n")
        self.assert_fails(root, base)

    def test_missing_owner_checkbox_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[3], "- [ ] Exact SLICE-1 scope and vertical demonstration accepted\n", "")
        self.assert_fails(root, base)

    def test_compatibility_generation_dependency_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[2], "| component, platform values, schemaversion, contract |", "| component, generation, platform values, schemaversion, contract |")
        self.assert_fails(root, base)

    def test_catalog_trust_dependency_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[2], "| component, artifact, provenance, contract |", "| component, artifact, provenance, trust, contract |")
        self.assert_fails(root, base)

    def test_resolution_effect_dependency_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[2], "identity, version, digest, canonicaljson, contract |", "identity, version, digest, canonicaljson, state, contract |")
        self.assert_fails(root, base)

    def test_artifact_catalog_dependency_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[2], "identity, version, digest, contract | store", "identity, version, digest, catalog, contract | store")
        self.assert_fails(root, base)

    def test_unknown_incompatible_distinction_removal_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "Unknown", "Incompatible")
        self.assert_fails(root, base)

    def test_contract_status_collapsed_to_bool_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "COMPATIBILITY_STATUS_MODEL=Compatible|Incompatible|Unknown", "COMPATIBILITY_STATUS_MODEL=bool")
        self.assert_fails(root, base)

    def test_reason_order_removal_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "REASON_PRIORITY_ORDER=", "REMOVED_REASON_PRIORITY_ORDER=")
        self.assert_fails(root, base)

    def test_generic_resolution_selector_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "resolution.ComponentSelector", "resolution.Selector")
        self.assert_fails(root, base)

    def test_malformed_signature_policy_removal_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[3], "A malformed envelope returns a typed fail-closed error", "A malformed envelope is accepted")
        self.assert_fails(root, base)

    def test_trusted_representation_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "only constructible SLICE-1 value is\n`UNVERIFIED`", "constructible SLICE-1 values are\n`UNVERIFIED` and `Trusted`")
        self.assert_fails(root, base)

    def test_duplicate_artifact_type_policy_removal_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[3], "Independent duplicate artifact domain types are forbidden", "Independent artifact types are permitted")
        self.assert_fails(root, base)


if __name__ == "__main__":
    unittest.main()
