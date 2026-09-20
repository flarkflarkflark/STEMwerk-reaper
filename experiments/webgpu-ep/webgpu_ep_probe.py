"""
Step 1 of the WebGPU EP experiment: prove the EP is available, initializes,
and correctly identifies the target GPU -- independent of any real model.

Usage:
    python webgpu_ep_probe.py [--pci-bus-id 0000:xx:00.0]

Distinguishes:
  - EP beschikbaar        -> plugin library registers, ort.get_ep_devices() lists it
  - EP initialisatie geslaagd -> InferenceSession() succeeds against a specific device
  - GPU-inferentie aangetoond -> onnxruntime's own node-placement log shows the op
                                  ran on WebGpuExecutionProvider, not CPU fallback
  - Numeriek gevalideerd  -> output matches CPUExecutionProvider within float tolerance

Device selection (--pci-bus-id, optional) is delegated to webgpu_adapter.select_device()
-- the same shared, cross-platform selector end_to_end_pipeline_test.py and
benchmark_resources.py use (Linux/multi-GPU: pass --pci-bus-id explicitly; macOS/single-GPU:
omit it, the one available device is used automatically). This used to duplicate its own
inline PCI-bus-id-only matching here; now it reuses the one adapter function instead.
"""
import argparse
import os
import tempfile

import numpy as np
import onnx
import onnxruntime as ort
from onnx import helper, TensorProto

from webgpu_adapter import create_verified_webgpu_session, list_webgpu_devices, select_device

ap = argparse.ArgumentParser()
ap.add_argument("--pci-bus-id", default=None, help="Linux/multi-GPU only; omit on macOS/single-GPU systems")
ap.add_argument("--device-id", type=int, default=None,
                 help="Windows/multi-GPU only (no pci_bus_id metadata under Dawn/D3D12); "
                      "omit on macOS/single-GPU systems")
args = ap.parse_args()

webgpu_devices = list_webgpu_devices()
print(f"EP beschikbaar: {len(webgpu_devices) > 0} ({len(webgpu_devices)} GPU device(s) found)")
for d in webgpu_devices:
    print(f"  - vendor_id={d.device.vendor_id} device_id={d.device.device_id} metadata={dict(d.device.metadata)}")

target = select_device(pci_bus_id=args.pci_bus_id, device_id=args.device_id)

# Minimal Conv graph -- representative op family for MDX-Net (UNet-style Conv2d stack).
X = helper.make_tensor_value_info("X", TensorProto.FLOAT, [1, 3, 8, 8])
W = helper.make_tensor_value_info("W", TensorProto.FLOAT, [4, 3, 3, 3])
Y = helper.make_tensor_value_info("Y", TensorProto.FLOAT, [1, 4, 8, 8])
conv = helper.make_node("Conv", ["X", "W"], ["Y"], kernel_shape=[3, 3], pads=[1, 1, 1, 1])
graph = helper.make_graph([conv], "conv_probe", [X, W], [Y])
model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 17)])
model.ir_version = 8
onnx.checker.check_model(model)
probe_model_path = os.path.join(tempfile.gettempdir(), "webgpu_ep_probe_model.onnx")
onnx.save(model, probe_model_path)

# create_verified_webgpu_session() proves placement via onnxruntime's own C++ log (not
# just get_providers()) -- see webgpu_adapter.py / README.md section 3.
session, report = create_verified_webgpu_session(probe_model_path, target)
print(f"EP initialisatie geslaagd: session providers = {session.get_providers()}")
print(f"GPU-inferentie aangetoond: {report['all_nodes_placed_line']}")

np.random.seed(0)
x = np.random.randn(1, 3, 8, 8).astype(np.float32)
w = np.random.randn(4, 3, 3, 3).astype(np.float32)
out_gpu = session.run(None, {"X": x, "W": w})[0]

sess_cpu = ort.InferenceSession(probe_model_path, providers=["CPUExecutionProvider"])
out_cpu = sess_cpu.run(None, {"X": x, "W": w})[0]

diff = np.abs(out_cpu - out_gpu)
corr = np.corrcoef(out_cpu.flatten(), out_gpu.flatten())[0, 1]
print(f"Numeriek gevalideerd: max_abs_diff={diff.max():.2e} correlation={corr:.10f}")
