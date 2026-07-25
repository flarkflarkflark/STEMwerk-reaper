#!/usr/bin/env python3
"""Tests for the SLICE-1 local fast gate using controlled stub repositories and tools."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GATE = ROOT / "component-manager/scripts/run_slice1_fast_gate.py"
APPROVAL_HEAD = "0199c870ef143d67017571b777b2193b1ed80902"
STUB_PASS = "#!/usr/bin/env python3\nimport sys\nsys.exit(0)\n"
STUB_FAIL = "#!/usr/bin/env python3\nimport sys\nsys.exit(1)\n"
STUB_SCRIPTS = (
    "verify_slice1_documentation.py",
    "verify_slice1_changed_paths.py",
    "verify_module_integrity.py",
    "verify_schema_authority.py",
)


class FastGateTests(unittest.TestCase):
    def fixture(self) -> tuple[Path, Path, str]:
        temporary = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temporary)
        scripts = temporary / "component-manager/scripts"
        scripts.mkdir(parents=True)
        for name in STUB_SCRIPTS:
            (scripts / name).write_text(STUB_PASS, encoding="utf-8")
        (temporary / "component-manager/go.mod").write_text("module stub\n\ngo 1.24.0\n", encoding="utf-8")
        bindir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, bindir)
        self.make_tool(bindir, "go", "#!/bin/sh\nexit 0\n")
        self.make_tool(bindir, "gofmt", "#!/bin/sh\nexit 0\n")
        git_real = shutil.which("git")
        os.symlink(git_real, bindir / "git")
        subprocess.run(["git", "init", "-q"], cwd=temporary, check=True)
        subprocess.run(["git", "config", "user.name", "Fixture"], cwd=temporary, check=True)
        subprocess.run(["git", "config", "user.email", "fixture@example.invalid"], cwd=temporary, check=True)
        subprocess.run(["git", "add", "."], cwd=temporary, check=True)
        subprocess.run(["git", "commit", "-qm", "baseline"], cwd=temporary, check=True)
        base = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=temporary, check=True, text=True, capture_output=True,
        ).stdout.strip()
        return temporary, bindir, base

    def make_tool(self, bindir: Path, name: str, content: str) -> None:
        path = bindir / name
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)

    def run_gate(self, root: Path, bindir: Path | None, base: str | None, mode: str | None = "approved", phase: str | None = "pre-push") -> subprocess.CompletedProcess[str]:
        command = [sys.executable, str(GATE), "--repository", str(root)]
        if base is not None:
            command.extend(["--base-ref", base])
        if mode is not None:
            command.extend(["--documentation-mode", mode])
        if phase is not None:
            command.extend(["--phase", phase])
        env = dict(os.environ)
        if bindir is not None:
            env["PATH"] = str(bindir)
        return subprocess.run(command, text=True, capture_output=True, env=env)

    def payload(self, result: subprocess.CompletedProcess[str]) -> dict:
        return json.loads(result.stdout)

    def assert_fail(self, root: Path, bindir: Path | None, base: str | None, mode: str | None = "approved", phase: str | None = "pre-push") -> dict:
        result = self.run_gate(root, bindir, base, mode, phase)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        data = self.payload(result)
        self.assertEqual(data["result"], "FAIL")
        return data

    def step(self, data: dict, name: str) -> dict:
        for entry in data["steps"]:
            if entry["name"] == name:
                return entry
        self.fail(f"step {name} missing: {data['steps']}")

    def test_all_steps_green(self) -> None:
        root, bindir, base = self.fixture()
        before = subprocess.run(["git", "status", "--porcelain"], cwd=root, text=True, capture_output=True).stdout
        result = self.run_gate(root, bindir, base)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        data = self.payload(result)
        self.assertEqual(data["result"], "PASS")
        self.assertEqual(len(data["steps"]), 11)
        self.assertTrue(all(entry["result"] == "PASS" for entry in data["steps"]))
        after = subprocess.run(["git", "status", "--porcelain"], cwd=root, text=True, capture_output=True).stdout
        self.assertEqual(before, after, "fast gate wrote into the repository")

    def test_documentation_checker_failure_stops_later_steps(self) -> None:
        root, bindir, base = self.fixture()
        (root / "component-manager/scripts/verify_slice1_documentation.py").write_text(STUB_FAIL, encoding="utf-8")
        data = self.assert_fail(root, bindir, base)
        self.assertEqual(self.step(data, "documentation_checker")["result"], "FAIL")
        for entry in data["steps"][2:]:
            self.assertEqual(entry["result"], "NOT_RUN", entry)

    def test_changed_paths_failure_stops_later_steps(self) -> None:
        root, bindir, base = self.fixture()
        (root / "component-manager/scripts/verify_slice1_changed_paths.py").write_text(STUB_FAIL, encoding="utf-8")
        data = self.assert_fail(root, bindir, base)
        self.assertEqual(self.step(data, "changed_paths")["result"], "FAIL")
        for entry in data["steps"][3:]:
            self.assertEqual(entry["result"], "NOT_RUN", entry)

    def test_gofmt_failure(self) -> None:
        root, bindir, base = self.fixture()
        self.make_tool(bindir, "gofmt", "#!/bin/sh\necho bad.go\nexit 0\n")
        data = self.assert_fail(root, bindir, base)
        self.assertEqual(self.step(data, "gofmt")["result"], "FAIL")
        self.assertEqual(self.step(data, "go_vet")["result"], "NOT_RUN")

    def test_go_vet_failure(self) -> None:
        root, bindir, base = self.fixture()
        self.make_tool(bindir, "go", "#!/bin/sh\nif [ \"$1\" = vet ]; then exit 1; fi\nexit 0\n")
        data = self.assert_fail(root, bindir, base)
        self.assertEqual(self.step(data, "go_vet")["result"], "FAIL")
        self.assertEqual(self.step(data, "go_test")["result"], "NOT_RUN")

    def test_go_test_failure(self) -> None:
        root, bindir, base = self.fixture()
        self.make_tool(bindir, "go", "#!/bin/sh\nif [ \"$1\" = test ]; then exit 1; fi\nexit 0\n")
        data = self.assert_fail(root, bindir, base)
        self.assertEqual(self.step(data, "go_test")["result"], "FAIL")
        self.assertEqual(self.step(data, "module_integrity")["result"], "NOT_RUN")

    def test_module_integrity_failure(self) -> None:
        root, bindir, base = self.fixture()
        (root / "component-manager/scripts/verify_module_integrity.py").write_text(STUB_FAIL, encoding="utf-8")
        data = self.assert_fail(root, bindir, base)
        self.assertEqual(self.step(data, "module_integrity")["result"], "FAIL")

    def test_schema_drift_failure(self) -> None:
        root, bindir, base = self.fixture()
        (root / "component-manager/scripts/verify_schema_authority.py").write_text(STUB_FAIL, encoding="utf-8")
        data = self.assert_fail(root, bindir, base)
        self.assertEqual(self.step(data, "schema_contract_drift")["result"], "FAIL")

    def test_import_packagegraph_failure(self) -> None:
        root, bindir, base = self.fixture()
        target = root / "component-manager/pkg/compatibility"
        target.mkdir(parents=True)
        (target / "bad.go").write_text(
            "package compatibility\n\nimport \"example.com/stemwerk/component-manager/pkg/generation\"\n",
            encoding="utf-8",
        )
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", "bad import"], cwd=root, check=True)
        data = self.assert_fail(root, bindir, base)
        self.assertEqual(self.step(data, "import_packagegraph_guard")["result"], "FAIL")
        self.assertEqual(self.step(data, "worktree_hygiene")["result"], "NOT_RUN")

    def test_forbidden_import_failure(self) -> None:
        root, bindir, base = self.fixture()
        target = root / "component-manager/pkg/resolution"
        target.mkdir(parents=True)
        (target / "bad.go").write_text("package resolution\n\nimport \"os\"\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", "bad import"], cwd=root, check=True)
        data = self.assert_fail(root, bindir, base)
        self.assertEqual(self.step(data, "import_packagegraph_guard")["result"], "PASS")
        self.assertEqual(self.step(data, "forbidden_import_guard")["result"], "FAIL")

    def test_missing_tool_fails(self) -> None:
        root, bindir, base = self.fixture()
        (bindir / "gofmt").unlink()
        data = self.assert_fail(root, bindir, base)
        self.assertEqual(self.step(data, "gofmt")["result"], "FAIL")
        self.assertEqual(self.step(data, "gofmt")["exit_code"], 127)

    def test_invalid_base_ref_fails_closed(self) -> None:
        root, bindir, base = self.fixture()
        data = self.assert_fail(root, bindir, "not-a-ref")
        self.assertEqual(self.step(data, "preflight")["result"], "FAIL")
        for entry in data["steps"][1:]:
            self.assertEqual(entry["result"], "NOT_RUN", entry)

    def test_missing_base_ref_fails_closed(self) -> None:
        root, bindir, base = self.fixture()
        data = self.assert_fail(root, bindir, None)
        self.assertEqual(data["errors"][0]["code"], "base_ref_missing")

    def test_invalid_phase_fails_closed(self) -> None:
        root, bindir, base = self.fixture()
        data = self.assert_fail(root, bindir, base, phase="sideways")
        self.assertEqual(data["errors"][0]["code"], "phase_invalid")

    def test_missing_documentation_mode_fails_closed(self) -> None:
        root, bindir, base = self.fixture()
        data = self.assert_fail(root, bindir, base, mode=None)
        self.assertEqual(data["errors"][0]["code"], "documentation_mode_missing")

    def test_invalid_documentation_mode_fails_closed(self) -> None:
        root, bindir, base = self.fixture()
        data = self.assert_fail(root, bindir, base, mode="sideways")
        self.assertEqual(data["errors"][0]["code"], "documentation_mode_invalid")

    def test_pre_push_dirty_worktree_fails(self) -> None:
        root, bindir, base = self.fixture()
        target = root / "component-manager/pkg/artifact"
        target.mkdir(parents=True)
        (target / "dirty.go").write_text("package artifact\n", encoding="utf-8")
        data = self.assert_fail(root, bindir, base)
        self.assertEqual(self.step(data, "worktree_hygiene")["result"], "FAIL")

    def test_pre_commit_allows_open_changes(self) -> None:
        root, bindir, base = self.fixture()
        target = root / "component-manager/pkg/artifact"
        target.mkdir(parents=True)
        (target / "open.go").write_text("package artifact\n", encoding="utf-8")
        result = self.run_gate(root, bindir, base, phase="pre-commit")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_json_shape(self) -> None:
        root, bindir, base = self.fixture()
        data = self.payload(self.run_gate(root, bindir, base))
        for key in ("result", "gate", "phase", "base_ref", "head", "steps"):
            self.assertIn(key, data)
        self.assertEqual(data["gate"], "slice1_fast_gate")
        for entry in data["steps"]:
            for key in ("name", "result", "exit_code", "summary"):
                self.assertIn(key, entry)

    def test_real_repository_approval_head_passes(self) -> None:
        result = subprocess.run(
            [sys.executable, str(GATE), "--repository", str(ROOT),
             "--documentation-mode", "approved", "--base-ref", APPROVAL_HEAD, "--phase", "pre-commit"],
            text=True, capture_output=True,
        )
        data = json.loads(result.stdout)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(data["result"], "PASS")
        self.assertEqual(data["head"], subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True, capture_output=True, check=True,
        ).stdout.strip())


if __name__ == "__main__":
    unittest.main()
