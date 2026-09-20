"""
Phase W2 decisive device-selection probe.

Requests a specific physical GPU via webgpu_adapter.select_device(device_id=...) --
the exact, unmodified, shared adapter code every prior phase (W1, L1-L11) has used --
then repeatedly runs real WebGPU inference against it (a small Conv graph, same op
family as MDX-Net's UNet) inside a tight loop for several seconds, while
windows_gpu_monitor.GpuEngineMonitor independently samples \\GPU Engine(*) OS
performance counters for THIS process's own PID, keyed by DXGI adapter LUID.

Running this process's own PID and the monitor in the SAME process removes any
subprocess-PID-correlation uncertainty and keeps a tight, dense inference loop
running continuously for several seconds -- both changes were necessary in practice
(see WINDOWS_MULTI_GPU_SELECTION.md "Monitoring methodology and its limits"): the
real MDX-Net pipeline's bursty, sub-3-second WebGPU calls were too short and too
infrequent for Get-Counter's ~1.3-1.6s single-shot sampling cadence to reliably catch,
even though genuine GPU execution was independently confirmed by nvidia-smi whole-GPU
utilization and near-identical output/timing in that case (see the same doc). This
script is the tool that DID reliably catch it, and is the source of this phase's
decisive per-process, per-physical-adapter evidence.

Usage: python w2_device_selection_probe.py <device_id>
  device_id=9504 -> NVIDIA GeForce RTX 3060 Laptop GPU on this machine
  device_id=5688 -> AMD Radeon(TM) Graphics (integrated) on this machine
(Use webgpu_ep_probe.py or list_webgpu_devices() to re-discover these on another
machine -- do not assume these numbers are portable.)
"""
import os
import sys
import tempfile
import time

import numpy as np
import onnx
from onnx import helper, TensorProto

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from webgpu_adapter import select_device, create_verified_webgpu_session
from windows_gpu_monitor import GpuEngineMonitor, enumerate_dxgi_adapters

device_id = int(sys.argv[1]) if len(sys.argv) > 1 else 9504
pid = os.getpid()
print(f"PID={pid} requesting device_id={device_id}")

adapters = enumerate_dxgi_adapters()
device = select_device(device_id=device_id)
print(f"select_device() returned: vendor_id={device.device.vendor_id} device_id={device.device.device_id} "
      f"metadata={dict(device.device.metadata)}")

# Bigger Conv graph, repeated many times, to give perf counters a wide window to sample.
X = helper.make_tensor_value_info("X", TensorProto.FLOAT, [1, 16, 256, 256])
W = helper.make_tensor_value_info("W", TensorProto.FLOAT, [32, 16, 3, 3])
Y = helper.make_tensor_value_info("Y", TensorProto.FLOAT, [1, 32, 256, 256])
conv = helper.make_node("Conv", ["X", "W"], ["Y"], kernel_shape=[3, 3], pads=[1, 1, 1, 1])
graph = helper.make_graph([conv], "conv_probe", [X, W], [Y])
model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 17)])
model.ir_version = 8
onnx.checker.check_model(model)
probe_model_path = os.path.join(tempfile.gettempdir(), "w2_diag_probe_model.onnx")
onnx.save(model, probe_model_path)

with GpuEngineMonitor(interval_ms=150) as mon:
    print("Idle segment (2s)...")
    time.sleep(2)

    session, report = create_verified_webgpu_session(probe_model_path, device)
    print(f"Session created. Placement: {report['all_nodes_placed_line']}")

    np.random.seed(0)
    x = np.random.randn(1, 16, 256, 256).astype(np.float32)
    w = np.random.randn(32, 16, 3, 3).astype(np.float32)

    print("Running 300 repeated inferences over ~8s...")
    t_end = time.time() + 8.0
    n = 0
    while time.time() < t_end:
        session.run(None, {"X": x, "W": w})
        n += 1
    print(f"Completed {n} inference calls.")
    time.sleep(1.5)

print(f"\nn_ticks_total={mon.n_ticks} total_nonzero_samples={len(mon.samples)}")
pids_seen = sorted(set(s["pid"] for s in mon.samples))
print(f"All PIDs with ANY nonzero GPU-engine sample during the whole window: {pids_seen}")
print(f"Our own PID: {pid} -- {'PRESENT' if pid in pids_seen else 'ABSENT'} in that list")

summary = mon.summary_for_pid(pid, adapters=adapters)
print(f"\nGPU engine summary attributed to our own PID {pid}:")
import json
print(json.dumps(summary, indent=2))
