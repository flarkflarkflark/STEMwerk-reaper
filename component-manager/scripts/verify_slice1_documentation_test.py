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
REVIEW_HEAD = "856b5bc0643fe3fc6effb824b195d15fa3abf758"
DOCUMENTATION_BASE = "ab59eef7d00de7e0d6e4d2467fb815a3d0975eb3"
APPROVAL_HEAD = "0199c870ef143d67017571b777b2193b1ed80902"
PREAUTH_HEAD = "e0fe346e8f643a2643f97bcb50cd6616769e1362"
AUTHORIZATION_HEAD = "12dd6a3d4ece3a3bc30cd377f742632458f34a3c"
FILES = [
    "experiments/component-manager-poa0/production-readiness/VERTICAL_SLICES.md",
    "experiments/component-manager-poa0/production-readiness/READINESS_TRACEABILITY.md",
    "experiments/component-manager-poa0/production-readiness/GO_PACKAGE_PLAN.md",
    "experiments/component-manager-poa0/production-readiness/SLICE_1_AND_ROADMAP_ARCHITECTURE_DECISION.md",
    "component-manager/docs/SLICE_1_SCOPE.md",
    "experiments/component-manager-poa0/contract-v1/COMPONENT_MANAGER_CONTRACT_V1.md",
    "component-manager/schemas/artifact.schema.json",
    "component-manager/pkg/contract/error.go",
    "experiments/component-manager-poa0/production-readiness/PUBLIC_API_BOUNDARIES.md",
    "experiments/component-manager-poa0/production-readiness/README.md",
    "experiments/component-manager-poa0/production-readiness/FIRST_SLICE_SCOPE.md",
]


class DocumentationCheckerTests(unittest.TestCase):
    def fixture(self, ref: str | None = REVIEW_HEAD) -> tuple[Path, str]:
        temporary = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temporary)
        for relative in FILES:
            target = temporary / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if ref is None:
                shutil.copy2(ROOT / relative, target)
            else:
                content = subprocess.run(
                    ["git", "-C", str(ROOT), "show", f"{ref}:{relative}"],
                    check=True, capture_output=True,
                ).stdout
                target.write_bytes(content)
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

    def run_checker(self, root: Path, base: str | None, mode: str | None = "review") -> subprocess.CompletedProcess[str]:
        command = [sys.executable, str(CHECKER), "--repository", str(root)]
        if base is not None:
            command.extend(["--base-ref", base])
        if mode is not None:
            command.extend(["--mode", mode])
        return subprocess.run(command, text=True, capture_output=True)

    def mutate(self, root: Path, relative: str, old: str, new: str) -> None:
        path = root / relative
        text = path.read_text(encoding="utf-8")
        self.assertIn(old, text)
        path.write_text(text.replace(old, new, 1), encoding="utf-8")

    def assert_fails(self, root: Path, base: str, mode: str = "review") -> subprocess.CompletedProcess[str]:
        result = self.run_checker(root, base, mode)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["result"], "FAIL")
        return result

    def assert_error_code(self, root: Path, base: str, mode: str, code: str) -> None:
        result = self.assert_fails(root, base, mode)
        codes = {error["code"] for error in json.loads(result.stdout)["errors"]}
        self.assertIn(code, codes, result.stdout)

    def commit(self, root: Path, message: str) -> None:
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", message], cwd=root, check=True)

    def test_current_documents_pass_authorized_mode(self) -> None:
        result = self.run_checker(ROOT, AUTHORIZATION_HEAD, "authorized")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["mode"], "authorized")

    def test_authorized_mode_passes_on_authorized_documents(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        result = self.run_checker(root, base, "authorized")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_approved_mode_passes_on_preauthorization_documents(self) -> None:
        root, base = self.fixture(PREAUTH_HEAD)
        result = self.run_checker(root, base, "approved")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["mode"], "approved")

    def test_review_mode_passes_on_immutable_review_head_documents(self) -> None:
        root, base = self.fixture(REVIEW_HEAD)
        result = self.run_checker(root, base, "review")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)["mode"], "review")

    def test_missing_mode_fails_closed(self) -> None:
        root, base = self.fixture()
        result = self.run_checker(root, base, None)
        self.assertNotEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["result"], "FAIL")
        self.assertEqual(payload["errors"][0]["code"], "mode_missing")

    def test_unknown_mode_fails_closed(self) -> None:
        root, base = self.fixture()
        result = self.run_checker(root, base, "sideways")
        self.assertNotEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["result"], "FAIL")
        self.assertEqual(payload["errors"][0]["code"], "mode_invalid")

    def test_review_mode_rejects_approved_documents(self) -> None:
        root, base = self.fixture(PREAUTH_HEAD)
        self.assert_error_code(root, base, "review", "review_status_invalid")

    def test_review_mode_rejects_checked_owner_controls(self) -> None:
        root, base = self.fixture(PREAUTH_HEAD)
        self.assert_error_code(root, base, "review", "review_checkbox_state_invalid")

    def test_review_mode_rejects_authorized_documents(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.assert_error_code(root, base, "review", "review_status_invalid")

    def test_approved_mode_rejects_authorized_documents(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.assert_error_code(root, base, "approved", "implementation_authorization_overclaim")

    def test_authorized_mode_rejects_review_documents(self) -> None:
        root, base = self.fixture(REVIEW_HEAD)
        self.assert_error_code(root, base, "authorized", "authorized_status_invalid")

    def test_authorized_mode_rejects_approved_documents(self) -> None:
        root, base = self.fixture(PREAUTH_HEAD)
        self.assert_error_code(root, base, "authorized", "authorized_checkbox_state_invalid")

    def test_approved_mode_rejects_proposed_status(self) -> None:
        root, base = self.fixture(PREAUTH_HEAD)
        self.mutate(root, FILES[3], "Status: APPROVED_BY_OWNER", "Status: PROPOSED_FOR_OWNER_APPROVAL")
        self.assert_error_code(root, base, "approved", "approved_status_invalid")

    def test_approved_mode_rejects_zero_checked_controls(self) -> None:
        root, base = self.fixture(PREAUTH_HEAD)
        path = root / FILES[3]
        path.write_text(path.read_text().replace("- [x]", "- [ ]"), encoding="utf-8")
        self.assert_error_code(root, base, "approved", "approved_checkbox_state_invalid")

    def test_approved_mode_rejects_six_checked_controls(self) -> None:
        root, base = self.fixture(PREAUTH_HEAD)
        self.mutate(root, FILES[3], "- [x] Total HYBRID roadmap approved", "- [ ] Total HYBRID roadmap approved")
        self.assert_error_code(root, base, "approved", "approved_checkbox_state_invalid")

    def test_approved_mode_rejects_checked_implementation_control(self) -> None:
        root, base = self.fixture(PREAUTH_HEAD)
        self.mutate(root, FILES[3], "- [ ] Implementation may be authorized", "- [x] Implementation may be authorized")
        self.assert_error_code(root, base, "approved", "approved_checkbox_state_invalid")

    def test_approved_mode_rejects_implementation_authorized_yes(self) -> None:
        root, base = self.fixture(PREAUTH_HEAD)
        self.mutate(root, FILES[4], "IMPLEMENTATION_AUTHORIZED=no", "IMPLEMENTATION_AUTHORIZED=yes")
        self.assert_fails(root, base, "approved")

    def test_approved_mode_rejects_authorized_implementation_status(self) -> None:
        root, base = self.fixture(PREAUTH_HEAD)
        self.mutate(root, FILES[3], "SLICE1_IMPLEMENTATION_STATUS=NOT_AUTHORIZED", "SLICE1_IMPLEMENTATION_STATUS=AUTHORIZED")
        self.assert_error_code(root, base, "approved", "implementation_authorization_overclaim")

    def test_approved_mode_rejects_missing_review_head(self) -> None:
        root, base = self.fixture(PREAUTH_HEAD)
        self.mutate(root, FILES[3], "OWNER_APPROVED_REVIEW_HEAD=856b5bc0643fe3fc6effb824b195d15fa3abf758\n\n", "")
        self.assert_error_code(root, base, "approved", "approved_review_head_invalid")

    def test_approved_mode_rejects_malformed_review_head(self) -> None:
        root, base = self.fixture(PREAUTH_HEAD)
        self.mutate(root, FILES[3], "OWNER_APPROVED_REVIEW_HEAD=856b5bc0643fe3fc6effb824b195d15fa3abf758", "OWNER_APPROVED_REVIEW_HEAD=856b5bc")
        self.assert_error_code(root, base, "approved", "approved_review_head_invalid")

    def test_approved_mode_rejects_missing_approval_date(self) -> None:
        root, base = self.fixture(PREAUTH_HEAD)
        self.mutate(root, FILES[3], "OWNER_APPROVAL_DATE=2026-07-25\n\n", "")
        self.assert_error_code(root, base, "approved", "approval_date_invalid")

    def test_approved_mode_rejects_malformed_approval_date(self) -> None:
        root, base = self.fixture(PREAUTH_HEAD)
        self.mutate(root, FILES[3], "OWNER_APPROVAL_DATE=2026-07-25", "OWNER_APPROVAL_DATE=2026-13-99")
        self.assert_error_code(root, base, "approved", "approval_date_invalid")

    def test_approved_mode_still_detects_architecture_drift(self) -> None:
        root, base = self.fixture(PREAUTH_HEAD)
        self.mutate(root, FILES[4], "Compatible:true; Incompatible:false", "Compatible:false; Incompatible:true")
        self.assert_fails(root, base, "approved")

    def test_approved_mode_still_detects_forbidden_path(self) -> None:
        root, base = self.fixture(PREAUTH_HEAD)
        self.mutate(root, FILES[5], "# STEMwerk", "# Changed STEMwerk")
        self.commit(root, "change contract")
        self.assert_error_code(root, base, "approved", "changed_path_forbidden")

    def test_approved_mode_still_detects_packagegraph_drift(self) -> None:
        root, base = self.fixture(PREAUTH_HEAD)
        self.mutate(root, FILES[2], "| component, platform values, schemaversion, contract |", "| component, generation, platform values, schemaversion, contract |")
        self.assert_fails(root, base, "approved")

    def test_approved_mode_rejects_facts_removal(self) -> None:
        root, base = self.fixture(PREAUTH_HEAD)
        self.mutate(root, FILES[4], "future compatibility.Facts; ", "")
        self.assert_error_code(root, base, "approved", "allowed_types_invalid")

    def test_base_ref_is_required(self) -> None:
        root, _ = self.fixture()
        result = self.run_checker(root, None)
        self.assertNotEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["result"], "FAIL")
        self.assertEqual(payload["errors"][0]["code"], "base_ref_missing")

    def test_invalid_base_ref_is_machine_readable(self) -> None:
        root, _ = self.fixture()
        result = self.run_checker(root, "not-a-ref")
        self.assertNotEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["errors"][0]["code"], "base_ref_invalid")

    def test_help_like_cli_exit_is_machine_readable(self) -> None:
        result = subprocess.run(
            [sys.executable, str(CHECKER), "--help"], text=True, capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["errors"][0]["code"], "cli_invalid")

    def test_non_ancestor_base_ref_fails_closed(self) -> None:
        root, _ = self.fixture()
        subprocess.run(["git", "checkout", "--orphan", "unrelated"], cwd=root, check=True, capture_output=True)
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", "unrelated"], cwd=root, check=True)
        unrelated = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root, check=True, text=True, capture_output=True).stdout.strip()
        subprocess.run(["git", "checkout", "-q", "master"], cwd=root, check=True)
        result = self.run_checker(root, unrelated)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout)["errors"][0]["code"], "base_ref_not_ancestor")

    def test_committed_unknown_product_path_fails_closed(self) -> None:
        root, base = self.fixture()
        path = root / "component-manager/cmd/new_product.go"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("package main\n")
        self.commit(root, "add product")
        self.assert_fails(root, base)

    def test_committed_workflow_fails_closed(self) -> None:
        root, base = self.fixture()
        path = root / ".github/workflows/new.yml"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("name: forbidden\n")
        self.commit(root, "add workflow")
        self.assert_fails(root, base)

    def test_committed_installer_path_fails_closed(self) -> None:
        root, base = self.fixture()
        path = root / "installer/new.txt"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("forbidden\n")
        self.commit(root, "add installer")
        self.assert_fails(root, base)

    def test_staged_product_path_fails_closed(self) -> None:
        root, base = self.fixture()
        path = root / "component-manager/cmd/staged.go"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("package main\n")
        subprocess.run(["git", "add", str(path.relative_to(root))], cwd=root, check=True)
        self.assert_fails(root, base)

    def test_unstaged_product_path_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[7], "package contract", "package changed")
        self.assert_fails(root, base)

    def test_untracked_product_path_fails_closed(self) -> None:
        root, base = self.fixture()
        path = root / "component-manager/cmd/untracked.go"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("package main\n")
        self.assert_fails(root, base)

    def test_catalog_revocation_dependency_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[2], "component, artifact, provenance, contract |", "component, artifact, provenance, revocation, contract |")
        self.assert_fails(root, base)

    def test_resolution_state_dependency_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[2], "canonicaljson, contract | generation", "canonicaljson, state, contract | generation")
        self.assert_fails(root, base)

    def test_resolution_storage_dependency_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[2], "canonicaljson, contract | generation", "canonicaljson, storage, contract | generation")
        self.assert_fails(root, base)

    def test_resolution_network_dependency_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[2], "canonicaljson, contract | generation", "canonicaljson, network, contract | generation")
        self.assert_fails(root, base)

    def test_resolution_time_dependency_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[2], "canonicaljson, contract | generation", "canonicaljson, time, contract | generation")
        self.assert_fails(root, base)

    def test_resolution_random_dependency_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[2], "canonicaljson, contract | generation", "canonicaljson, random, contract | generation")
        self.assert_fails(root, base)

    def test_duplicate_artifact_owner_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[2], "ARTIFACT_NORMATIVE_OWNER=pkg/artifact", "ARTIFACT_NORMATIVE_OWNER=pkg/artifact;pkg/catalog")
        self.assert_fails(root, base)

    def test_later_effect_package_in_pure_graph_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[2], "SLICE1_PURE_PACKAGES=artifact;provenance;catalog;component;compatibility;resolution", "SLICE1_PURE_PACKAGES=artifact;provenance;catalog;component;compatibility;resolution;lifecycle")
        self.assert_fails(root, base)

    def test_context_field_removed_fails_closed(self) -> None:
        root, base = self.fixture()
        path = root / FILES[4]
        lines = [line for line in path.read_text().splitlines() if not line.startswith("| Backend |")]
        path.write_text("\n".join(lines) + "\n")
        self.assert_fails(root, base)

    def test_extra_context_field_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "| SchemaVersion |", "| Extra | `string` | none | optional | Unknown | exact | `extra_unknown` |\n| SchemaVersion |")
        self.assert_fails(root, base)

    def test_fact_field_removed_fails_closed(self) -> None:
        root, base = self.fixture()
        path = root / FILES[4]
        lines = [line for line in path.read_text().splitlines() if not line.startswith("| Provenance facts |")]
        path.write_text("\n".join(lines) + "\n")
        self.assert_fails(root, base)

    def test_extra_fact_field_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "| ComponentID |", "| ExtraFact | none | yes | no | none | forbidden |\n| ComponentID |")
        self.assert_fails(root, base)

    def test_reason_code_removed_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "; incompatible_declared_constraint", "")
        self.assert_fails(root, base)

    def test_duplicate_reason_priority_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "incompatible_declared_constraint", "platform_unknown")
        self.assert_fails(root, base)

    def test_runnable_mapping_reversal_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "Compatible:true; Incompatible:false", "Compatible:false; Incompatible:true")
        self.assert_fails(root, base)

    def test_unknown_removed_from_preview_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "compatibility `ContractStatus`, `Runnable` and ordered typed reasons", "compatibility `Runnable` and ordered typed reasons")
        self.assert_fails(root, base)

    def test_unknown_context_policy_removal_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "UNKNOWN_CONTEXT_FIELD_POLICY=", "REMOVED_UNKNOWN_CONTEXT_FIELD_POLICY=")
        self.assert_fails(root, base)

    def test_model_digest_removal_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "; `ArtifactDigest digest.Digest`", "")
        self.assert_fails(root, base)

    def test_selector_field_addition_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "SELECTOR_FIELDS=ComponentID identity.ComponentID; Version resolution.VersionSelector", "SELECTOR_FIELDS=ComponentID identity.ComponentID; Version resolution.VersionSelector; Channel string")
        self.assert_fails(root, base)

    def test_oversized_mapping_removal_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "| oversized input | `schema_invalid` |", "| oversized input | `catalog_invalid` |")
        self.assert_fails(root, base)

    def test_unsupported_major_mapping_removal_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "| unsupported schema major | `schema_invalid` |", "| unsupported schema major | `catalog_invalid` |")
        self.assert_fails(root, base)

    def test_canonicalization_mapping_removal_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "| canonicalization failure | `schema_invalid or internal_error` |", "| canonicalization failure | `catalog_invalid` |")
        self.assert_fails(root, base)

    def test_preview_digest_artifact_error_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "| resolution-preview digest mismatch | `CI/gate failure; no product category` |", "| resolution-preview digest mismatch | `artifact_digest_mismatch` |")
        self.assert_fails(root, base)

    def test_compatibility_resolver_generation_conflict_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[8], "GenerationCompatibilityCoordinator / generation", "CompatibilityResolver / compatibility")
        self.mutate(root, FILES[8], "EvaluateCandidate(GenerationCandidate,CompatibilityContext)", "Resolve(Target,Generation)")
        self.assert_fails(root, base)

    def test_stale_slice0_status_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[9], "CURRENT_STATUS=SLICE_0_IMPLEMENTED_AND_GATED", "CURRENT_STATUS=READY_FOR_FIRST_VERTICAL_SLICE")
        self.assert_fails(root, base)

    def test_implementation_approval_overclaim_fails_closed(self) -> None:
        root, base = self.fixture()
        self.mutate(root, FILES[4], "IMPLEMENTATION_AUTHORIZED=no", "IMPLEMENTATION_AUTHORIZED=APPROVED")
        self.assert_fails(root, base)

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

    # --- authorized lifecycle mode ---

    def test_authorized_mode_rejects_seven_checked_controls(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[3], "- [x] Governance approved", "- [ ] Governance approved")
        self.assert_error_code(root, base, "authorized", "authorized_checkbox_state_invalid")

    def test_authorized_mode_rejects_six_checked_controls(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[3], "- [x] Governance approved", "- [ ] Governance approved")
        self.mutate(root, FILES[3], "- [x] Exit evidence approved", "- [ ] Exit evidence approved")
        self.assert_error_code(root, base, "authorized", "authorized_checkbox_state_invalid")

    def test_authorized_mode_rejects_unchecked_implementation_control(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[3], "- [x] Implementation may be authorized", "- [ ] Implementation may be authorized")
        self.assert_error_code(root, base, "authorized", "authorized_checkbox_state_invalid")

    def test_authorized_mode_rejects_not_authorized_status(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[3], "SLICE1_IMPLEMENTATION_STATUS=AUTHORIZED_NOT_STARTED", "SLICE1_IMPLEMENTATION_STATUS=NOT_AUTHORIZED")
        self.assert_error_code(root, base, "authorized", "authorized_implementation_status_invalid")

    def test_authorized_mode_rejects_implementation_flag_no(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[3], "SLICE1_IMPLEMENTATION_AUTHORIZED=yes", "SLICE1_IMPLEMENTATION_AUTHORIZED=no")
        self.assert_error_code(root, base, "authorized", "authorized_implementation_flag_invalid")

    def test_authorized_mode_rejects_scope_flag_no(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[4], "IMPLEMENTATION_AUTHORIZED=yes", "IMPLEMENTATION_AUTHORIZED=no")
        self.assert_error_code(root, base, "authorized", "authorized_implementation_flag_invalid")

    def test_authorized_mode_rejects_started_yes(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[3], "SLICE1_IMPLEMENTATION_STARTED=no", "SLICE1_IMPLEMENTATION_STARTED=yes")
        self.assert_error_code(root, base, "authorized", "authorized_started_state_invalid")

    def test_authorized_mode_rejects_missing_authorization_date(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[3], "OWNER_IMPLEMENTATION_AUTHORIZATION_DATE=2026-07-25\n\n", "")
        self.assert_error_code(root, base, "authorized", "authorization_date_invalid")

    def test_authorized_mode_rejects_malformed_authorization_date(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[3], "OWNER_IMPLEMENTATION_AUTHORIZATION_DATE=2026-07-25", "OWNER_IMPLEMENTATION_AUTHORIZATION_DATE=2026-13-99")
        self.assert_error_code(root, base, "authorized", "authorization_date_invalid")

    def test_authorized_mode_rejects_missing_baseline(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[3], "OWNER_IMPLEMENTATION_BASELINE=e0fe346e8f643a2643f97bcb50cd6616769e1362\n\n", "")
        self.assert_error_code(root, base, "authorized", "authorization_baseline_invalid")

    def test_authorized_mode_rejects_malformed_baseline(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[3], "OWNER_IMPLEMENTATION_BASELINE=e0fe346e8f643a2643f97bcb50cd6616769e1362", "OWNER_IMPLEMENTATION_BASELINE=e0fe346")
        self.assert_error_code(root, base, "authorized", "authorization_baseline_invalid")

    def test_authorized_mode_rejects_wrong_baseline(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[3], "OWNER_IMPLEMENTATION_BASELINE=e0fe346e8f643a2643f97bcb50cd6616769e1362", "OWNER_IMPLEMENTATION_BASELINE=ffffffffffffffffffffffffffffffffffffffff")
        self.assert_error_code(root, base, "authorized", "authorization_baseline_invalid")

    def test_authorized_mode_rejects_missing_branch(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[3], "OWNER_IMPLEMENTATION_BRANCH=slice/1-read-only-resolution-preview\n\n", "")
        self.assert_error_code(root, base, "authorized", "authorization_branch_invalid")

    def test_authorized_mode_rejects_wrong_branch(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[3], "OWNER_IMPLEMENTATION_BRANCH=slice/1-read-only-resolution-preview", "OWNER_IMPLEMENTATION_BRANCH=slice/2-immutable-local-store")
        self.assert_error_code(root, base, "authorized", "authorization_branch_invalid")

    def test_authorized_mode_rejects_missing_owner_sentence(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[3], "I authorize implementation of SLICE-1 — Read-only catalog and component", "I note SLICE-1")
        self.assert_error_code(root, base, "authorized", "authorization_text_invalid")

    def test_authorized_mode_rejects_owner_sentence_without_slice2_exclusion(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[3], "This authorization does not extend to\nSLICE-2 or later capabilities.", "This authorization covers all slices.")
        self.assert_error_code(root, base, "authorized", "authorization_text_invalid")

    def test_authorized_mode_rejects_owner_sentence_wrong_baseline(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(
            root, FILES[3],
            "from approved governance baseline\ne0fe346e8f643a2643f97bcb50cd6616769e1362, on branch",
            "from approved governance baseline\nffffffffffffffffffffffffffffffffffffffff, on branch",
        )
        self.assert_error_code(root, base, "authorized", "authorization_text_invalid")

    def test_authorized_mode_rejects_owner_sentence_wrong_branch(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(
            root, FILES[3],
            ", on branch\nslice/1-read-only-resolution-preview, under",
            ", on branch\nslice/9-wrong-branch, under",
        )
        self.assert_error_code(root, base, "authorized", "authorization_text_invalid")

    def test_authorized_mode_rejects_slice2_overclaim(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[3], "SLICE-2 and later slices are not authorized", "SLICE-2 and later slices are authorized")
        self.assert_error_code(root, base, "authorized", "later_slice_authorization_overclaim")

    def test_authorized_mode_rejects_exit_overclaim(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[3], "No exit claim is permitted", "Exit claim is permitted")
        self.assert_error_code(root, base, "authorized", "exit_or_release_overclaim")

    def test_authorized_mode_rejects_release_overclaim(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[3], "No release is permitted", "Release is permitted")
        self.assert_error_code(root, base, "authorized", "exit_or_release_overclaim")

    def test_authorized_mode_still_detects_architecture_drift(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[4], "Compatible:true; Incompatible:false", "Compatible:false; Incompatible:true")
        self.assert_fails(root, base, "authorized")

    def test_authorized_mode_still_detects_selector_drift(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[4], "SELECTOR_FIELDS=ComponentID identity.ComponentID; Version resolution.VersionSelector", "SELECTOR_FIELDS=ComponentID identity.ComponentID; Version resolution.VersionSelector; Channel string")
        self.assert_fails(root, base, "authorized")

    def test_authorized_mode_still_detects_error_result_drift(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[4], "| oversized input | `schema_invalid` |", "| oversized input | `catalog_invalid` |")
        self.assert_fails(root, base, "authorized")

    def test_authorized_mode_still_detects_packagegraph_drift(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[2], "| component, platform values, schemaversion, contract |", "| component, generation, platform values, schemaversion, contract |")
        self.assert_fails(root, base, "authorized")

    def test_authorized_mode_rejects_facts_removal(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[4], "future compatibility.Facts; ", "")
        self.assert_error_code(root, base, "authorized", "allowed_types_invalid")

    def test_authorized_mode_still_detects_forbidden_product_path(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        path = root / "component-manager/cmd/new_product.go"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("package main\n")
        self.commit(root, "add product")
        self.assert_error_code(root, base, "authorized", "changed_path_forbidden")

    def test_authorized_mode_still_detects_contract_drift(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[5], "# STEMwerk", "# Changed STEMwerk")
        self.commit(root, "change contract")
        self.assert_error_code(root, base, "authorized", "changed_path_forbidden")

    def test_authorized_mode_still_detects_schema_drift(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        self.mutate(root, FILES[6], '"title":', '"description": "changed",\n  "title":')
        self.commit(root, "change schema")
        self.assert_error_code(root, base, "authorized", "changed_path_forbidden")

    def test_authorized_mode_still_detects_dependency_drift(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        path = root / "component-manager/go.mod"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("module changed\n")
        self.commit(root, "change go.mod")
        self.assert_error_code(root, base, "authorized", "changed_path_forbidden")

    def test_authorized_mode_still_detects_workflow_drift(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        path = root / ".github/workflows/other.yml"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("name: forbidden\n")
        self.commit(root, "add workflow")
        self.assert_error_code(root, base, "authorized", "changed_path_forbidden")

    def test_authorized_mode_rejects_unknown_governance_script_path(self) -> None:
        root, base = self.fixture(AUTHORIZATION_HEAD)
        path = root / "component-manager/scripts/evil_gate.py"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("print('evil')\n")
        self.commit(root, "add unknown script")
        self.assert_error_code(root, base, "authorized", "changed_path_forbidden")


if __name__ == "__main__":
    unittest.main()
