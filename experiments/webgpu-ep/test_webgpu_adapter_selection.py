import unittest
from types import SimpleNamespace
from unittest.mock import patch

from webgpu_adapter import GpuExecutionNotProvenError, select_device


def _ep_device(device_id, **metadata):
    return SimpleNamespace(device=SimpleNamespace(device_id=device_id, metadata=metadata))


class SelectDeviceTests(unittest.TestCase):
    def setUp(self):
        self.amd = _ep_device(5688, LUID="59967")
        self.nvidia = _ep_device(9504, LUID="64318")

    def select(self, **kwargs):
        with patch("webgpu_adapter.list_webgpu_devices", return_value=[self.amd, self.nvidia]):
            return select_device(**kwargs)

    def test_exact_adapter_luid_selects_unique_physical_device(self):
        self.assertIs(self.select(adapter_luid="64318"), self.nvidia)

    def test_adapter_luid_is_normalized_to_discovery_decimal(self):
        self.assertIs(self.select(adapter_luid="059967"), self.amd)

    def test_missing_adapter_luid_fails_closed(self):
        with self.assertRaisesRegex(GpuExecutionNotProvenError, "No WebGPU device"):
            self.select(adapter_luid="1")

    def test_ambiguous_adapter_luid_fails_closed(self):
        duplicate = _ep_device(9999, LUID="64318")
        with patch("webgpu_adapter.list_webgpu_devices",
                   return_value=[self.nvidia, duplicate]):
            with self.assertRaisesRegex(GpuExecutionNotProvenError, "matched 2"):
                select_device(adapter_luid="64318")

    def test_invalid_or_out_of_range_adapter_luid_fails_closed(self):
        for value in ("-1", "+1", " 1", "1junk", str(1 << 64)):
            with self.subTest(value=value), self.assertRaises(GpuExecutionNotProvenError):
                self.select(adapter_luid=value)

    def test_ambiguous_device_id_fails_closed(self):
        duplicate = _ep_device(9504, LUID="70000")
        with patch("webgpu_adapter.list_webgpu_devices",
                   return_value=[self.nvidia, duplicate]):
            with self.assertRaisesRegex(GpuExecutionNotProvenError, "matched 2"):
                select_device(device_id=9504)

    def test_multiple_selector_types_are_rejected(self):
        with self.assertRaisesRegex(GpuExecutionNotProvenError, "exactly one"):
            self.select(device_id=9504, adapter_luid="64318")

    def test_no_selector_is_rejected_when_multiple_devices_exist(self):
        with self.assertRaisesRegex(GpuExecutionNotProvenError, "refusing to guess"):
            self.select()

    def test_no_selector_accepts_single_device(self):
        with patch("webgpu_adapter.list_webgpu_devices", return_value=[self.amd]):
            self.assertIs(select_device(), self.amd)


if __name__ == "__main__":
    unittest.main()
