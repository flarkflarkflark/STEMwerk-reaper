#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("verify_schema_authority.py")
SCHEMA = b'{\n  "$schema": "https://json-schema.org/draft/2020-12/schema",\n  "type": "object"\n}\n'


class SchemaAuthorityVerifierTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.authority = self.root / "authority"
        self.embedded = self.root / "embedded"
        self.authority.mkdir()
        self.embedded.mkdir()
        self.write(self.authority / "artifact.schema.json", SCHEMA)
        self.write(self.embedded / "artifact.schema.json", SCHEMA)
        self.write_manifest([self.entry("artifact.schema.json", SCHEMA)])
        self.git("init", "-q")
        self.git("config", "user.email", "tests@example.test")
        self.git("config", "user.name", "Verifier Tests")
        self.git("config", "core.autocrlf", "false")
        self.commit("fixture")

    def tearDown(self):
        self.temp.cleanup()

    def write(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def entry(self, name, data):
        return f"{hashlib.sha256(data).hexdigest()}  {name}"

    def write_manifest(self, lines):
        self.write(self.embedded / "SHA256SUMS", ("\n".join(lines) + "\n").encode())

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-qm", message)

    def run_verifier(self, git_command=None, validate=None):
        summary = self.root / "summary.json"
        env = os.environ.copy()
        if git_command is not None:
            env["SCHEMA_AUTHORITY_GIT_COMMAND"] = json.dumps(git_command)
        command = [sys.executable, str(SCRIPT)]
        if validate is not None:
            command.extend(["--validate-summary", str(validate)])
        else:
            command.extend([
                "--repository", str(self.root), "--authority-dir", "authority",
                "--embedded-dir", "embedded", "--manifest", "embedded/SHA256SUMS",
                "--expected-count", "1", "--summary", str(summary),
            ])
        result = subprocess.run(command, cwd=self.root, env=env, text=True, capture_output=True)
        payload = json.loads(summary.read_text()) if summary.exists() else None
        return result, payload

    def assert_pass(self, result, payload):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(payload["result"], "PASS")
        self.assertEqual(payload["files_rewritten"], 0)

    def assert_fail(self, result, payload=None):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        if payload is not None:
            self.assertEqual(payload["result"], "FAIL")

    def test_lf_worktree_passes(self):
        self.assert_pass(*self.run_verifier())

    def test_crlf_worktree_passes(self):
        path = self.embedded / "artifact.schema.json"
        path.write_bytes(path.read_bytes().replace(b"\n", b"\r\n"))
        self.assert_pass(*self.run_verifier())

    def test_git_blob_drift_fails(self):
        self.write(self.authority / "artifact.schema.json", SCHEMA.replace(b"object", b"string"))
        self.commit("authority drift")
        self.assert_fail(*self.run_verifier())

    def test_embedded_drift_fails(self):
        self.write(self.embedded / "artifact.schema.json", SCHEMA.replace(b"object", b"string"))
        self.commit("embedded drift")
        self.assert_fail(*self.run_verifier())

    def test_manifest_digest_drift_fails(self):
        self.write_manifest(["0" * 64 + "  artifact.schema.json"])
        self.commit("digest drift")
        self.assert_fail(*self.run_verifier())

    def test_missing_manifest_entry_fails(self):
        self.write_manifest([])
        self.commit("missing manifest")
        self.assert_fail(*self.run_verifier())

    def test_extra_manifest_entry_fails(self):
        self.write_manifest([self.entry("artifact.schema.json", SCHEMA), self.entry("extra.schema.json", SCHEMA)])
        self.commit("extra manifest")
        self.assert_fail(*self.run_verifier())

    def test_duplicate_manifest_entry_fails(self):
        entry = self.entry("artifact.schema.json", SCHEMA)
        self.write_manifest([entry, entry])
        self.commit("duplicate manifest")
        self.assert_fail(*self.run_verifier())

    def test_malformed_digest_fails(self):
        self.write_manifest(["not-a-digest  artifact.schema.json"])
        self.commit("malformed digest")
        self.assert_fail(*self.run_verifier())

    def test_missing_embedded_schema_fails(self):
        self.git("rm", "embedded/artifact.schema.json")
        self.git("commit", "-qm", "missing embedded")
        self.assert_fail(*self.run_verifier())

    def test_missing_git_schema_fails(self):
        self.git("rm", "authority/artifact.schema.json")
        self.git("commit", "-qm", "missing authority")
        self.assert_fail(*self.run_verifier())

    def test_manifest_path_traversal_fails(self):
        self.write_manifest([self.entry("../artifact.schema.json", SCHEMA)])
        self.commit("traversal")
        self.assert_fail(*self.run_verifier())

    def test_git_command_unavailable_fails_closed(self):
        self.assert_fail(*self.run_verifier([str(self.root / "missing-git")]))

    def test_unresolvable_head_fails_closed(self):
        command = [sys.executable, "-c", "import sys; sys.exit(128)"]
        self.assert_fail(*self.run_verifier(command))

    def test_malformed_machine_summary_fails_validation(self):
        malformed = self.root / "malformed.json"
        malformed.write_text("{not-json", encoding="utf-8")
        result, _ = self.run_verifier(validate=malformed)
        self.assert_fail(result)

    def test_verifier_does_not_rewrite_files(self):
        before = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file() and ".git" not in p.parts}
        self.assert_pass(*self.run_verifier())
        after = {p: p.read_bytes() for p in before}
        self.assertEqual(after, before)


if __name__ == "__main__":
    unittest.main()
