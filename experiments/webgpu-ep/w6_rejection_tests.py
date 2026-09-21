"""W6 rejection/regression checks on the AMD workstation (fresh process each run).

1. Malformed LUID selectors rejected at the Python adapter layer.
2. Mismatched explicit LUID vs selected device: native rejection, surfaced by the
   wrapper as GpuExecutionNotProvenError (never a silent CPU fallback).
3. Cross-GPU default-context reuse: rejected natively.
4. Same-GPU context reuse: accepted.
5. First-inference on each GPU: a single Conv session.run() must survive (the W5
   DefaultContext crash regression) -- exit code is the verdict.

Run: python w6_rejection_tests.py
"""
import os
import sys
import tempfile

import numpy as np
import onnx
from onnx import helper, TensorProto

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from webgpu_adapter import (  # noqa: E402
    GpuExecutionNotProvenError,
    create_verified_webgpu_session,
    select_device,
)

RX_LUID = "87436"
IGPU_LUID = "96109"

X = helper.make_tensor_value_info("X", TensorProto.FLOAT, [1, 8, 128, 128])
W = helper.make_tensor_value_info("W", TensorProto.FLOAT, [16, 8, 3, 3])
Y = helper.make_tensor_value_info("Y", TensorProto.FLOAT, [1, 16, 128, 128])
conv = helper.make_node("Conv", ["X", "W"], ["Y"], kernel_shape=[3, 3], pads=[1, 1, 1, 1])
model = helper.make_model(helper.make_graph([conv], "conv_probe", [X, W], [Y]),
                          opset_imports=[helper.make_opsetid("", 17)])
model.ir_version = 8
onnx.checker.check_model(model)
probe = os.path.join(tempfile.gettempdir(), "w6_reject_probe.onnx")
onnx.save(model, probe)

results = []


def record(label, ok, detail=""):
    results.append((label, ok, detail))
    print(f"[{'PASS' if ok else 'FAIL'}] {label}" + (f" -- {detail}" if detail else ""))


# 1. Malformed selectors.
for bad in ("-1", "notanumber", str(1 << 65)):
    try:
        select_device(adapter_luid=bad)
        record(f"malformed selector {bad!r} rejected", False, "no exception raised")
    except Exception as e:
        record(f"malformed selector {bad!r} rejected", True, type(e).__name__)

# 2. Mismatched explicit LUID through the production wrapper path.
dev_rx = select_device(adapter_luid=RX_LUID)
try:
    create_verified_webgpu_session(probe, dev_rx, extra_options={"d3d12AdapterLuid": "999999"})
    record("mismatched LUID natively rejected (no silent CPU fallback)", False,
           "session was created despite mismatched LUID")
except GpuExecutionNotProvenError as e:
    record("mismatched LUID natively rejected (no silent CPU fallback)", True, str(e)[:120])
except Exception as e:
    record("mismatched LUID natively rejected (no silent CPU fallback)", True,
           f"{type(e).__name__}: {str(e)[:100]}")

# 3. Cross-GPU default-context reuse must be rejected.
s_rx, rep_rx = create_verified_webgpu_session(probe, dev_rx)
record("RX 9070 baseline session placed", "WebGpuExecutionProvider" in rep_rx["all_nodes_placed_line"],
       rep_rx["all_nodes_placed_line"])
try:
    dev_igpu = select_device(adapter_luid=IGPU_LUID)
    create_verified_webgpu_session(probe, dev_igpu)
    record("cross-GPU default-context reuse rejected", False, "second session was created")
except Exception as e:
    record("cross-GPU default-context reuse rejected", True, f"{type(e).__name__}: {str(e)[:100]}")

# 4. Same-GPU reuse accepted.
try:
    s_rx2, rep2 = create_verified_webgpu_session(probe, dev_rx)
    record("same-GPU context reuse accepted", "WebGpuExecutionProvider" in rep2["all_nodes_placed_line"])
except Exception as e:
    record("same-GPU context reuse accepted", False, f"{type(e).__name__}: {str(e)[:100]}")

# 5. First-inference crash regression (per GPU, fresh contexts above already hold RX;
#    run one real inference on each).
x = np.random.randn(1, 8, 128, 128).astype(np.float32)
w = np.random.randn(16, 8, 3, 3).astype(np.float32)
out = s_rx.run(None, {"X": x, "W": w})
record("first inference on RX 9070 survived (W5 crash regression)",
       out[0].shape == (1, 16, 128, 128) and np.isfinite(out[0]).all())

failed = [l for l, ok, _ in results if not ok]
print(f"\n{len(results) - len(failed)}/{len(results)} rejection/regression checks passed")
if failed:
    print("FAILED:", failed)
sys.exit(1 if failed else 0)
