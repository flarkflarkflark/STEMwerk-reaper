#!/usr/bin/env python3
"""Twenty bounded regression guards for verify-change-policy.py."""

from __future__ import annotations

import hashlib
import importlib.util
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("verify-change-policy.py")
SPEC = importlib.util.spec_from_file_location("verify_change_policy", SCRIPT)
assert SPEC and SPEC.loader
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)


class VerifierPolicyTests(unittest.TestCase):
    def rejected(self, paths: list[str]) -> None:
        with self.assertRaises(POLICY.PolicyError):
            POLICY.validate_feature_paths(paths)

    def test_01_strict_no_drift(self):
        POLICY.validate_changed_paths("strict", [])

    def test_02_strict_rust_drift_rejected(self):
        with self.assertRaises(POLICY.PolicyError):
            POLICY.validate_changed_paths("strict", ["experiments/component-manager-poa0/rust/src/main.rs"])

    def test_03_strict_workflow_drift_rejected(self):
        with self.assertRaises(POLICY.PolicyError):
            POLICY.validate_changed_paths("strict", [".github/workflows/component-manager-poa0-native.yml"])

    def test_04_strict_documentation_drift_rejected(self):
        with self.assertRaises(POLICY.PolicyError):
            POLICY.validate_changed_paths("strict", ["experiments/component-manager-poa0/reports/WINDOWS_RUST_IN_PROCESS_SHA256_FIX.md"])

    def test_05_authorized_rust_drift_accepted(self):
        result = POLICY.validate_feature_paths(
            ["experiments/component-manager-poa0/rust/src/main.rs"]
        )
        self.assertEqual(len(result["IMPLEMENTATION_SOURCE_RUST"]), 1)

    def test_06_authorized_workflow_drift_accepted(self):
        result = POLICY.validate_feature_paths(
            [".github/workflows/component-manager-poa0-native.yml"]
        )
        self.assertEqual(len(result["TEST_ORCHESTRATION"]), 1)

    def test_07_authorized_documentation_drift_accepted(self):
        result = POLICY.validate_feature_paths(
            ["experiments/component-manager-poa0/reports/WINDOWS_RUST_IN_PROCESS_SHA256_FIX.md"]
        )
        self.assertEqual(len(result["DOCUMENTATION"]), 1)

    def test_08_fixture_drift_rejected(self):
        self.rejected(["experiments/component-manager-poa0/fixtures/catalog.json"])

    def test_09_expected_drift_rejected(self):
        self.rejected(["experiments/component-manager-poa0/fixtures/expected/results/errors.json"])

    def test_10_schema_drift_rejected(self):
        self.rejected(["experiments/component-manager-poa0/schemas/result.schema.json"])

    def test_11_fault_drift_rejected(self):
        self.rejected(["experiments/component-manager-poa0/harness/run-matrix.sh"])

    def test_12_go_drift_rejected(self):
        self.rejected(["experiments/component-manager-poa0/go/main.go"])

    def test_13_other_workflow_drift_rejected(self):
        self.rejected([".github/workflows/release.yml"])

    def test_14_other_documentation_drift_rejected(self):
        self.rejected(["experiments/component-manager-poa0/reports/OTHER.md"])

    def test_15_harness_core_drift_rejected(self):
        self.rejected(["experiments/component-manager-poa0/harness/contract-smoke.sh"])

    def test_16_unknown_rust_path_rejected(self):
        self.rejected(["experiments/component-manager-poa0/rust/build.rs"])

    def test_17_double_classification_rejected(self):
        rules = {"one": lambda _path: True, "two": lambda _path: True}
        with self.assertRaises(POLICY.PolicyError):
            POLICY.classify("duplicate", rules)

    def test_18_invalid_mode_rejected(self):
        with self.assertRaises(POLICY.PolicyError):
            POLICY.validate_mode("skip")

    def test_19_manifest_sha_mismatch_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "manifest.json")
            path.write_bytes(b"manifest")
            with self.assertRaises(POLICY.PolicyError):
                POLICY.verify_digest(path, hashlib.sha256(b"other").hexdigest())

    def test_20_post_target_forbidden_path_rejected(self):
        with self.assertRaises(POLICY.PolicyError):
            POLICY.validate_post_target_paths(["experiments/component-manager-poa0/rust/src/main.rs"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
