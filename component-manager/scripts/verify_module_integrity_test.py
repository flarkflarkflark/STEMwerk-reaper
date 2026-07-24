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
    if mode == "verify_failure":
        sys.exit(41)
    print("all modules verified")
elif args == ["list", "-m", "all"]:
    if mode == "dependency_list_before_failure" and not marker.exists():
        sys.exit(42)
    if mode == "dependency_list_after_failure" and marker.exists():
        sys.exit(43)
    print("example.test/module")
    print("example.test/dependency v1.0.0")
    if mode == "dependency_drift" and marker.exists():
        print("example.test/added v1.0.0")
elif args == ["mod", "tidy"]:
    marker.write_text("yes", encoding="utf-8")
    if mode == "tidy_failure":
        sys.exit(44)
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
    elif mode == "real_checkout_mutation":
        Path(os.environ["REAL_CHECKOUT_MUTATION_PATH"]).write_text("changed during verification\n")
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
        (self.module / "go.mod").write_bytes(
            b"module example.test/module\n\ngo 1.24.0\n\nrequire example.test/dependency v1.0.0\n",
        )
        (self.module / "go.sum").write_bytes(
            b"example.test/dependency v1.0.0 h1:checksum\n",
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

    def run_verifier(self, mode="unchanged", module=None, fault=None, extra_env=None):
        evidence = self.root / "evidence"
        env = os.environ.copy()
        env["FAKE_GO_MODE"] = mode
        env["MODULE_INTEGRITY_GO_COMMAND"] = json.dumps([sys.executable, str(self.fake_go)])
        if fault:
            env["MODULE_INTEGRITY_FAULT"] = fault
        if extra_env:
            env.update(extra_env)
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

    def tracked_bytes(self):
        return {
            path: (self.root / path).read_bytes()
            for path in ("module/go.mod", "module/go.sum", "README.md")
            if (self.root / path).is_file()
        }

    def assert_checkout_unchanged_and_clean(self, before):
        self.assertEqual(self.tracked_bytes(), before)
        status = subprocess.run(
            ["git", "status", "--porcelain=v1", "--untracked-files=no"],
            cwd=self.root,
            check=True,
            text=True,
            capture_output=True,
        )
        self.assertEqual(status.stdout, "")

    def test_lf_unchanged_passes(self):
        before = self.tracked_bytes()
        self.assert_pass(self.run_verifier())
        self.assert_checkout_unchanged_and_clean(before)

    def test_crlf_only_representation_passes(self):
        (self.root / ".gitattributes").write_text(
            "module/go.mod text eol=crlf\nmodule/go.sum text eol=crlf\n",
            encoding="utf-8",
        )
        for name in ("go.mod", "go.sum"):
            path = self.module / name
            path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
        self.run_git("add", ".gitattributes", "module/go.mod", "module/go.sum")
        self.run_git("commit", "-qm", "CRLF checkout fixture")
        before = self.tracked_bytes()
        self.assert_pass(self.run_verifier("crlf_only"))
        self.assert_checkout_unchanged_and_clean(before)

    def test_real_go_mod_drift_fails(self):
        before = self.tracked_bytes()
        self.assert_fail(self.run_verifier("go_mod_drift"))
        self.assert_checkout_unchanged_and_clean(before)

    def test_real_go_sum_drift_fails(self):
        before = self.tracked_bytes()
        self.assert_fail(self.run_verifier("go_sum_drift"))
        self.assert_checkout_unchanged_and_clean(before)

    def test_dependency_set_drift_fails(self):
        before = self.tracked_bytes()
        self.assert_fail(self.run_verifier("dependency_drift"))
        self.assert_checkout_unchanged_and_clean(before)

    def test_tidy_generated_trailing_whitespace_fails(self):
        before = self.tracked_bytes()
        self.assert_fail(self.run_verifier("trailing_whitespace"))
        self.assert_checkout_unchanged_and_clean(before)

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

    def test_pass_summary_requires_non_mutating_execution_claims(self):
        invalid = self.root / "invalid-pass-summary.json"
        invalid.write_text(
            json.dumps(
                {
                    "schema_version": "1.0.0",
                    "result": "PASS",
                    "go_mod_semantic_drift": False,
                    "go_sum_semantic_drift": False,
                    "dependency_set_changed": False,
                    "module_check_execution_location": "real_checkout",
                    "real_checkout_clean_after_module_check": False,
                    "tracked_bytes_changed_by_module_check": 1,
                }
            ),
            encoding="utf-8",
        )
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--validate-summary", str(invalid)],
            text=True,
            capture_output=True,
        )
        self.assert_fail(result)

    def test_preexisting_unrelated_tracked_change_fails_closed(self):
        (self.root / "README.md").write_text("unrelated change\n", encoding="utf-8")
        self.assert_fail(self.run_verifier())

    def test_go_mod_verify_failure_leaves_checkout_clean(self):
        before = self.tracked_bytes()
        self.assert_fail(self.run_verifier("verify_failure"))
        self.assert_checkout_unchanged_and_clean(before)

    def test_go_mod_tidy_failure_leaves_checkout_clean(self):
        before = self.tracked_bytes()
        self.assert_fail(self.run_verifier("tidy_failure"))
        self.assert_checkout_unchanged_and_clean(before)

    def test_dependency_list_before_failure_leaves_checkout_clean(self):
        before = self.tracked_bytes()
        self.assert_fail(self.run_verifier("dependency_list_before_failure"))
        self.assert_checkout_unchanged_and_clean(before)

    def test_dependency_list_after_failure_leaves_checkout_clean(self):
        before = self.tracked_bytes()
        self.assert_fail(self.run_verifier("dependency_list_after_failure"))
        self.assert_checkout_unchanged_and_clean(before)

    def test_tempdir_creation_failure_fails_closed(self):
        before = self.tracked_bytes()
        self.assert_fail(self.run_verifier(fault="tempdir_create"))
        self.assert_checkout_unchanged_and_clean(before)

    def test_copy_failure_fails_closed(self):
        before = self.tracked_bytes()
        self.assert_fail(self.run_verifier(fault="copy"))
        self.assert_checkout_unchanged_and_clean(before)

    def test_git_blob_read_failure_fails_closed(self):
        before = self.tracked_bytes()
        self.assert_fail(self.run_verifier(fault="git_blob_read"))
        self.assert_checkout_unchanged_and_clean(before)

    def test_summary_write_failure_fails_closed(self):
        before = self.tracked_bytes()
        self.assert_fail(self.run_verifier(fault="summary_write"))
        self.assert_checkout_unchanged_and_clean(before)

    def test_cleanup_failure_fails_closed(self):
        before = self.tracked_bytes()
        self.assert_fail(self.run_verifier(fault="cleanup"))
        self.assert_checkout_unchanged_and_clean(before)

    def test_tracked_file_changed_during_verification_fails_closed(self):
        target = self.root / "README.md"
        result = self.run_verifier(
            "real_checkout_mutation",
            extra_env={"REAL_CHECKOUT_MUTATION_PATH": str(target)},
        )
        self.assert_fail(result)
        self.assertIn("changed during verification", target.read_text())


if __name__ == "__main__":
    unittest.main()
