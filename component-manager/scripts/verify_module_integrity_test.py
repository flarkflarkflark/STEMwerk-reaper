#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("verify_module_integrity.py")


FAKE_GO = r'''import os
from pathlib import Path
import sys

args = sys.argv[1:]
mode = os.environ.get("FAKE_GO_MODE", "unchanged")
marker = Path(".fake-tidy-ran")
if args == ["mod", "verify"]:
    print("all modules verified")
elif args == ["list", "-m", "all"]:
    print("example.test/module")
    print("example.test/dependency v1.0.0")
    if mode == "dependency_drift" and marker.exists():
        print("example.test/added v1.0.0")
elif args == ["mod", "tidy"]:
    marker.write_text("yes", encoding="utf-8")
    if mode == "crlf_only":
        for name in ("go.mod", "go.sum"):
            path = Path(name)
            path.write_bytes(path.read_bytes().replace(b"\r\n", b"\n"))
    elif mode == "go_mod_drift":
        Path("go.mod").write_text(Path("go.mod").read_text() + "\nrequire example.test/added v1.0.0\n")
    elif mode == "go_sum_drift":
        Path("go.sum").write_text(Path("go.sum").read_text() + "example.test/added v1.0.0 h1:changed\n")
    elif mode == "trailing_whitespace":
        Path("go.mod").write_text(Path("go.mod").read_text() + " \n")
else:
    print("unexpected fake go command", args, file=sys.stderr)
    sys.exit(2)
'''


class ModuleIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.module = self.root / "module"
        self.module.mkdir()
        (self.module / "go.mod").write_text(
            "module example.test/module\n\ngo 1.24.0\n\nrequire example.test/dependency v1.0.0\n",
            encoding="utf-8",
        )
        (self.module / "go.sum").write_text(
            "example.test/dependency v1.0.0 h1:checksum\n",
            encoding="utf-8",
        )
        (self.root / "README.md").write_text("fixture\n", encoding="utf-8")
        self.fake_go = self.root / "fake_go.py"
        self.fake_go.write_text(FAKE_GO, encoding="utf-8")
        self.run_git("init", "-q")
        self.run_git("config", "user.email", "tests@example.test")
        self.run_git("config", "user.name", "Verifier Tests")
        self.run_git("config", "core.autocrlf", "false")
        self.run_git("add", ".")
        self.run_git("commit", "-qm", "fixture")

    def tearDown(self):
        self.temp.cleanup()

    def run_git(self, *args):
        subprocess.run(["git", *args], cwd=self.root, check=True)

    def run_verifier(self, mode="unchanged", module=None):
        evidence = self.root / "evidence"
        env = os.environ.copy()
        env["FAKE_GO_MODE"] = mode
        env["MODULE_INTEGRITY_GO_COMMAND"] = json.dumps([sys.executable, str(self.fake_go)])
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--module-dir", str(module or self.module), "--evidence-dir", str(evidence)],
            cwd=self.root,
            env=env,
            text=True,
            capture_output=True,
        )

    def assert_pass(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        summary = json.loads((self.root / "evidence" / "module-integrity-summary.json").read_text())
        self.assertEqual(summary["result"], "PASS")

    def assert_fail(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_lf_unchanged_passes(self):
        self.assert_pass(self.run_verifier())

    def test_crlf_only_representation_passes(self):
        for name in ("go.mod", "go.sum"):
            path = self.module / name
            path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
        self.assert_pass(self.run_verifier("crlf_only"))

    def test_real_go_mod_drift_fails(self):
        self.assert_fail(self.run_verifier("go_mod_drift"))

    def test_real_go_sum_drift_fails(self):
        self.assert_fail(self.run_verifier("go_sum_drift"))

    def test_dependency_set_drift_fails(self):
        self.assert_fail(self.run_verifier("dependency_drift"))

    def test_tidy_generated_trailing_whitespace_fails(self):
        self.assert_fail(self.run_verifier("trailing_whitespace"))

    def test_removed_required_module_fails_before_tidy_can_restore_it(self):
        path = self.module / "go.mod"
        path.write_text("module example.test/module\n\ngo 1.24.0\n", encoding="utf-8")
        self.assert_fail(self.run_verifier())

    def test_missing_module_file_fails_closed(self):
        (self.module / "go.sum").unlink()
        self.assert_fail(self.run_verifier())

    def test_git_index_unavailable_fails_closed(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "go.mod").write_text("module outside\n", encoding="utf-8")
        (outside / "go.sum").write_text("", encoding="utf-8")
        self.assert_fail(self.run_verifier(module=outside))

    def test_malformed_summary_validation_fails_closed(self):
        malformed = self.root / "malformed.json"
        malformed.write_text("{not-json", encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--validate-summary", str(malformed)],
            text=True,
            capture_output=True,
        )
        self.assert_fail(result)

    def test_unrelated_file_change_does_not_create_module_drift(self):
        (self.root / "README.md").write_text("unrelated change\n", encoding="utf-8")
        self.assert_pass(self.run_verifier())


if __name__ == "__main__":
    unittest.main()
