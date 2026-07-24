#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("verify_go_format.py")
FORMATTED = 'package example\n\nimport "fmt"\n\nfunc Example() {\n\tfmt.Println("ok")\n}\n'


class GoFormatVerifierTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.module = self.root / "module"
        self.module.mkdir()
        self.write("main.go", FORMATTED)
        (self.module / "README.md").write_text("fixture\n", encoding="utf-8", newline="\n")
        self.run_git("init", "-q")
        self.run_git("config", "user.email", "tests@example.test")
        self.run_git("config", "user.name", "Verifier Tests")
        self.run_git("config", "core.autocrlf", "false")
        self.commit("fixture")

    def tearDown(self):
        self.temp.cleanup()

    def write(self, name, content):
        path = self.module / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content.encode("utf-8"))
        return path

    def run_git(self, *args):
        subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def commit(self, message):
        self.run_git("add", ".")
        self.run_git("commit", "-qm", message)

    def run_verifier(self, gofmt_command=None):
        summary = self.root / "format-summary.json"
        env = os.environ.copy()
        if gofmt_command is not None:
            env["GO_FORMAT_GOFMT_COMMAND"] = json.dumps(gofmt_command)
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--module-dir", str(self.module), "--summary", str(summary)],
            cwd=self.root,
            env=env,
            text=True,
            capture_output=True,
        )
        payload = json.loads(summary.read_text(encoding="utf-8")) if summary.exists() else None
        return result, payload

    def fake_gofmt(self, source):
        path = self.root / "fake_gofmt.py"
        path.write_text(source, encoding="utf-8", newline="\n")
        return [sys.executable, str(path)]

    def assert_pass(self, result, payload):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(payload["result"], "PASS")
        self.assertEqual(payload["nonconformant_files"], [])
        self.assertEqual(payload["files_rewritten"], 0)

    def assert_format_fail(self, result, payload, expected):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(payload["result"], "FAIL")
        self.assertEqual(payload["nonconformant_files"], expected)

    def assert_infra_fail(self, result, payload):
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(payload["result"], "ERROR")

    def test_lf_formatted_blob_passes(self):
        self.assert_pass(*self.run_verifier())

    def test_crlf_worktree_representation_passes(self):
        path = self.module / "main.go"
        path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
        self.assert_pass(*self.run_verifier())

    def test_spacing_drift_fails(self):
        self.write("main.go", 'package example\n\nfunc Example(){println("bad")}\n')
        self.commit("spacing drift")
        self.assert_format_fail(*self.run_verifier(), ["main.go"])

    def test_import_group_drift_fails(self):
        self.write("main.go", 'package example\n\nimport (\n"os"\n"fmt"\n)\n\nvar _ = os.Args\nvar _ = fmt.Println\n')
        self.commit("import drift")
        self.assert_format_fail(*self.run_verifier(), ["main.go"])

    def test_multiple_nonconformant_files_are_reported(self):
        self.write("main.go", "package example\nfunc Example(){}\n")
        self.write("other.go", "package example\nfunc Other(){}\n")
        self.commit("multiple drift")
        self.assert_format_fail(*self.run_verifier(), ["main.go", "other.go"])

    def test_path_with_spaces_passes(self):
        self.write("path with spaces/file.go", FORMATTED)
        self.commit("space path")
        self.assert_pass(*self.run_verifier())

    def test_no_go_files_passes(self):
        self.run_git("rm", "module/main.go")
        self.run_git("commit", "-qm", "no go files")
        result, payload = self.run_verifier()
        self.assert_pass(result, payload)
        self.assertEqual(payload["tracked_go_file_count"], 0)

    def test_missing_gofmt_fails_closed(self):
        self.assert_infra_fail(*self.run_verifier([str(self.root / "missing-gofmt")]))

    def test_gofmt_subprocess_failure_fails_closed(self):
        command = self.fake_gofmt("import sys\nsys.stdin.buffer.read()\nsys.exit(7)\n")
        self.assert_infra_fail(*self.run_verifier(command))

    def test_malformed_gofmt_diff_fails_closed(self):
        command = self.fake_gofmt('import sys\nsys.stdin.buffer.read()\nsys.stdout.write("not-a-gofmt-diff\\n")\n')
        self.assert_infra_fail(*self.run_verifier(command))

    def test_verifier_does_not_rewrite_sources(self):
        before = {path: path.read_bytes() for path in self.module.rglob("*.go")}
        self.assert_pass(*self.run_verifier())
        after = {path: path.read_bytes() for path in self.module.rglob("*.go")}
        self.assertEqual(after, before)


if __name__ == "__main__":
    unittest.main()
