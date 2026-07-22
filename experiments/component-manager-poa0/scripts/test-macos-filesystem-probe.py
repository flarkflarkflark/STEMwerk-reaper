#!/usr/bin/env python3
"""Twenty regression guards for the fail-closed MAC-001 adapter."""

from __future__ import annotations

import errno
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("macos-filesystem-probe.py")
SPEC = importlib.util.spec_from_file_location("macos_filesystem_probe", SCRIPT)
PROBE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = PROBE
SPEC.loader.exec_module(PROBE)


class MacOSFilesystemProbeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.parent = Path(self.temp.name)
        self.artifacts = self.parent / "artifacts"

    def tearDown(self):
        self.temp.cleanup()

    def run_probe(self, **kwargs):
        return PROBE.run_probe(self.parent, self.artifacts, **kwargs)

    def test_01_old_stat_probe_failure_reproduced(self):
        self.assertNotEqual(PROBE.legacy_stat_percent_t_output(self.parent), "apfs")

    def test_02_target_and_temp_same_volume(self):
        result = self.run_probe()
        self.assertTrue(result["same_volume"])

    def test_03_cross_volume_rejected_fail_closed(self):
        ops = PROBE.ProbeOps()
        original = ops.device
        ops.device = lambda path: original(path) + (1 if Path(path).name == "selector.tmp" else 0)
        with self.assertRaises(PROBE.ProbeFailure) as caught:
            self.run_probe(ops=ops)
        self.assertEqual(caught.exception.step, "same_volume")

    def test_04_directory_opened(self):
        self.assertEqual(self.run_probe()["steps"]["directory_open"], "PASS")

    def test_05_file_flushed(self):
        self.assertEqual(self.run_probe()["steps"]["file_flush"], "PASS")

    def test_06_existing_destination_replaced(self):
        self.assertEqual(self.run_probe()["steps"]["rename_replace"], "PASS")

    def test_07_directory_flushed(self):
        self.assertEqual(self.run_probe()["steps"]["directory_flush"], "PASS")

    def test_08_errno_preserved_immediately(self):
        ops = PROBE.ProbeOps()
        ops.fsync = mock.Mock(side_effect=OSError(errno.EIO, "injected"))
        with self.assertRaises(PROBE.ProbeFailure) as caught:
            self.run_probe(ops=ops)
        self.assertEqual(caught.exception.errno, errno.EIO)

    def test_09_cleanup_after_success(self):
        result = self.run_probe()
        self.assertFalse(Path(result["root_path"]).exists())

    def test_10_cleanup_failure_fails_closed(self):
        ops = PROBE.ProbeOps()
        ops.cleanup = mock.Mock(side_effect=OSError(errno.EACCES, "injected"))
        with self.assertRaises(PROBE.ProbeFailure) as caught:
            self.run_probe(ops=ops)
        self.assertEqual(caught.exception.step, "cleanup")

    def test_11_readonly_root_fails(self):
        ops = PROBE.ProbeOps()
        ops.open_file = mock.Mock(side_effect=OSError(errno.EROFS, "read-only"))
        with self.assertRaises(PROBE.ProbeFailure) as caught:
            self.run_probe(ops=ops)
        self.assertEqual(caught.exception.errno, errno.EROFS)

    def test_12_missing_parent_fails(self):
        with self.assertRaises(PROBE.ProbeFailure):
            PROBE.run_probe(self.parent / "missing", self.artifacts)

    def test_13_destination_exists_before_replace(self):
        self.assertTrue(self.run_probe()["destination_existed"])

    def test_14_unicode_path(self):
        parent = self.parent / "unicode-π"
        parent.mkdir()
        self.assertEqual(PROBE.run_probe(parent, self.artifacts)["result"], "PASS")

    def test_15_space_in_path(self):
        parent = self.parent / "space path"
        parent.mkdir()
        self.assertEqual(PROBE.run_probe(parent, self.artifacts)["result"], "PASS")

    def test_16_intel_route(self):
        self.assertEqual(self.run_probe(expected_arch="x86_64")["expected_arch"], "x86_64")

    def test_17_arm64_route(self):
        self.assertEqual(self.run_probe(expected_arch="arm64")["expected_arch"], "arm64")

    def test_18_rust_route(self):
        self.assertEqual(self.run_probe(implementation="rust")["implementation"], "rust")

    def test_19_go_route(self):
        self.assertEqual(self.run_probe(implementation="go")["implementation"], "go")

    def test_20_expectation_literal_unchanged(self):
        case_source = SCRIPT.parent.parent / "harness" / "platform-tests.sh"
        self.assertIn("check MAC-001 apfs-active-replace", case_source.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
