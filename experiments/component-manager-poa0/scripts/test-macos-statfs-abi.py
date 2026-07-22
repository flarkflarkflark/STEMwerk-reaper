#!/usr/bin/env python3
"""Twenty ABI and decoding guards for the native Darwin statfs binding."""

from __future__ import annotations

import ctypes
import errno
import importlib.util
import inspect
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("macos-filesystem-probe.py")
SPEC = importlib.util.spec_from_file_location("macos_filesystem_probe_abi", SCRIPT)
PROBE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = PROBE
SPEC.loader.exec_module(PROBE)


class FakeFunction:
    def __init__(self, return_code=0, captured_errno=0):
        self.return_code = return_code
        self.captured_errno = captured_errno
        self.argtypes = None
        self.restype = None

    def __call__(self, _path, output):
        ctypes.set_errno(self.captured_errno)
        native = ctypes.cast(output, ctypes.POINTER(PROBE.DarwinStatFs64)).contents
        native.f_fstypename = b"apfs"
        native.f_mntonname = b"/System/Volumes/Data"
        native.f_mntfromname = b"/dev/disk3s5"
        return self.return_code


class FakeLibC:
    pass


class DarwinStatFsAbiTests(unittest.TestCase):
    def test_01_old_x86_binding_reproduces_empty_decode(self):
        legacy = PROBE.DarwinStatFsLegacy()
        legacy.f_fsid[0] = 16777222
        decoded = PROBE.decode_statfs64_buffer(bytes(legacy))
        self.assertEqual(decoded["filesystem_type"], "")
        self.assertEqual(decoded["mount_flags"], 16777222)

    def test_02_arm64_struct_size(self):
        self.assertEqual(PROBE.statfs_layout("arm64")["size"], 2168)

    def test_03_x86_64_struct_size(self):
        self.assertEqual(PROBE.statfs_layout("x86_64")["size"], 2168)

    def test_04_arm64_alignment(self):
        self.assertEqual(PROBE.statfs_layout("arm64")["alignment"], 8)

    def test_05_x86_64_alignment(self):
        self.assertEqual(PROBE.statfs_layout("x86_64")["alignment"], 8)

    def test_06_arm64_offsets(self):
        self.assertEqual(PROBE.statfs_layout("arm64")["offsets"], {"f_fstypename": 72, "f_mntonname": 88, "f_mntfromname": 1112})

    def test_07_x86_64_offsets(self):
        self.assertEqual(PROBE.statfs_layout("x86_64")["offsets"], {"f_fstypename": 72, "f_mntonname": 88, "f_mntfromname": 1112})

    def test_08_mfsnamelen(self):
        self.assertEqual(PROBE.MFSNAMELEN, 15)

    def test_09_mnamelen(self):
        self.assertEqual(PROBE.MNAMELEN, 1024)

    def test_10_nul_terminated_decode(self):
        self.assertEqual(PROBE.decode_c_field(b"apfs\0ignored"), "apfs")

    def test_11_full_field_decode(self):
        self.assertEqual(PROBE.decode_c_field(b"a" * 16), "a" * 16)

    def test_12_empty_fstypename_rejected(self):
        with self.assertRaises(PROBE.StatFsBindingError):
            PROBE.validate_statfs_metadata("", "/", "/dev/disk")

    def test_13_empty_mountpoint_rejected(self):
        with self.assertRaises(PROBE.StatFsBindingError):
            PROBE.validate_statfs_metadata("apfs", "", "/dev/disk")

    def test_14_nonzero_return_rejected(self):
        function = FakeFunction(return_code=-1, captured_errno=errno.EIO)
        with self.assertRaises(OSError):
            PROBE.call_statfs(Path("/"), "arm64", libc=self.libc(statfs=function))

    def test_15_errno_preserved(self):
        function = FakeFunction(return_code=-1, captured_errno=errno.EACCES)
        with self.assertRaises(OSError) as caught:
            PROBE.call_statfs(Path("/"), "arm64", libc=self.libc(statfs=function))
        self.assertEqual(caught.exception.errno, errno.EACCES)

    def test_16_arm64_apfs_decode(self):
        function = FakeFunction()
        metadata = PROBE.call_statfs(Path("/"), "arm64", libc=self.libc(statfs=function))
        self.assertEqual(metadata["filesystem_type"], "apfs")
        self.assertEqual(function.restype, ctypes.c_int)

    def test_17_x86_64_apfs_decode_uses_inode64_symbol(self):
        function = FakeFunction()
        metadata = PROBE.call_statfs(Path("/"), "x86_64", libc=self.libc(**{"statfs$INODE64": function}))
        self.assertEqual(metadata["filesystem_type"], "apfs")
        self.assertEqual(function.argtypes, [ctypes.c_char_p, ctypes.POINTER(PROBE.DarwinStatFs64)])

    def test_18_unicode_mountpoint_bytes_safe(self):
        self.assertEqual(PROBE.decode_c_field("/Volumes/π".encode()), "/Volumes/π")

    def test_19_space_mountpoint(self):
        self.assertEqual(PROBE.decode_c_field(b"/Volumes/Space Path"), "/Volumes/Space Path")

    def test_20_no_shell_fallback(self):
        body = inspect.getsource(PROBE.call_statfs)
        self.assertNotIn("subprocess", body)

    @staticmethod
    def libc(**symbols):
        library = FakeLibC()
        for name, value in symbols.items():
            setattr(library, name, value)
        return library


if __name__ == "__main__":
    unittest.main(verbosity=2)
