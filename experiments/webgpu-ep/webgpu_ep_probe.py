"""
Step 1 of the WebGPU EP experiment: prove the EP is available, initializes,
and correctly identifies the target GPU -- independent of any real model.

Usage:
    python webgpu_ep_probe.py

Distinguishes:
  - EP beschikbaar        -> plugin library registers, ort.get_ep_devices() lists it
  - EP initialisatie geslaagd -> InferenceSession() succeeds against a specific device
  - GPU-inferentie aangetoond -> onnxruntime's own node-placement log shows the op
                                  ran on WebGpuExecutionProvider, not CPU fallback
  - Numeriek gevalideerd  -> output matches CPUExecutionProvider within float tolerance
"""
import numpy as np
import onnx
import onnxruntime as ort
import onnxruntime_ep_webgpu as webgpu_ep
from onnx import helper, TensorProto

ort.register_execution_provider_library("webgpu", webgpu_ep.get_library_path())

devices = ort.get_ep_devices()
webgpu_devices = [d for d in devices if d.ep_name == webgpu_ep.get_ep_name()]
print(f"EP beschikbaar: {len(webgpu_devices) > 0} ({len(webgpu_devices)} GPU device(s) found)")
for d in webgpu_devices:
    print(f"  - vendor_id={d.device.vendor_id} device_id={d.device.device_id} metadata={dict(d.device.metadata)}")

# AMD vendor_id = 0x1002 = 4098 decimal. Pick by PCI bus id to target a specific card
# on multi-GPU systems (this machine has an RX 9070 discrete GPU + a Phoenix iGPU).
target = None
for d in webgpu_devices:
    if d.device.metadata.get("pci_bus_id") == "0000:03:00.0":  # RX 9070, see lspci
        target = d
        break
assert target is not None, "RX 9070 WebGPU device not found -- adjust pci_bus_id for your system"

# Minimal Conv graph -- representative op family for MDX-Net (UNet-style Conv2d stack).
X = helper.make_tensor_value_info("X", TensorProto.FLOAT, [1, 3, 8, 8])
W = helper.make_tensor_value_info("W", TensorProto.FLOAT, [4, 3, 3, 3])
Y = helper.make_tensor_value_info("Y", TensorProto.FLOAT, [1, 4, 8, 8])
conv = helper.make_node("Conv", ["X", "W"], ["Y"], kernel_shape=[3, 3], pads=[1, 1, 1, 1])
graph = helper.make_graph([conv], "conv_probe", [X, W], [Y])
model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 17)])
model.ir_version = 8
onnx.checker.check_model(model)
onnx.save(model, "/tmp/webgpu_ep_probe_model.onnx")

so = ort.SessionOptions()
so.log_severity_level = 0  # verbose: emits "All nodes placed on [...]" line
so.add_provider_for_devices([target], {})
session = ort.InferenceSession("/tmp/webgpu_ep_probe_model.onnx", sess_options=so)
print(f"EP initialisatie geslaagd: session providers = {session.get_providers()}")

np.random.seed(0)
x = np.random.randn(1, 3, 8, 8).astype(np.float32)
w = np.random.randn(4, 3, 3, 3).astype(np.float32)
out_gpu = session.run(None, {"X": x, "W": w})[0]

sess_cpu = ort.InferenceSession("/tmp/webgpu_ep_probe_model.onnx", providers=["CPUExecutionProvider"])
out_cpu = sess_cpu.run(None, {"X": x, "W": w})[0]

diff = np.abs(out_cpu - out_gpu)
corr = np.corrcoef(out_cpu.flatten(), out_gpu.flatten())[0, 1]
print(f"Numeriek gevalideerd: max_abs_diff={diff.max():.2e} correlation={corr:.10f}")
