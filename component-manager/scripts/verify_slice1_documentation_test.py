#!/usr/bin/env python3
"""Negative-fixture tests for the read-only SLICE-1 documentation checker."""

from __future__ import annotations

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
    "component-manager/docs/SLICE_1_SCOPE.md",
]


class DocumentationCheckerTests(unittest.TestCase):
    def fixture(self) -> Path:
        temporary = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temporary)
        for relative in FILES:
            target = temporary / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, target)
        subprocess.run(["git", "init", "-q"], cwd=temporary, check=True)
        subprocess.run(["git", "add", "."], cwd=temporary, check=True)
        return temporary

    def run_checker(self, root: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(CHECKER), "--repository", str(root)], text=True, capture_output=True
        )

    def test_current_documents_pass(self) -> None:
        result = self.run_checker(ROOT)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_slice_fails_closed(self) -> None:
        root = self.fixture()
        path = root / FILES[0]
        path.write_text(path.read_text().replace("### SLICE-10", "### OMITTED"))
        self.assertNotEqual(self.run_checker(root).returncode, 0)

    def test_to_be_defined_fails_closed(self) -> None:
        root = self.fixture()
        path = root / FILES[3]
        path.write_text(path.read_text() + "\nOPEN=TO_BE_DEFINED\n")
        self.assertNotEqual(self.run_checker(root).returncode, 0)

    def test_path_overlap_fails_closed(self) -> None:
        root = self.fixture()
        path = root / FILES[3]
        text = path.read_text().replace(
            "FORBIDDEN_PATHS=", "FORBIDDEN_PATHS=component-manager/pkg/artifact/**; "
        )
        path.write_text(text)
        self.assertNotEqual(self.run_checker(root).returncode, 0)


if __name__ == "__main__":
    unittest.main()
