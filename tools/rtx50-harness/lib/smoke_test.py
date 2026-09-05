"""Runs real CUDA smoke tests plus STEMwerk-relevant imports, reporting
everything as JSON on stdout.

IMPORTANT: these smoke tests run on whatever PHYSICAL GPU is actually in
this machine. On this development machine that is an RTX 3060 Laptop GPU,
not Blackwell hardware. A pass here proves the installed torch/CUDA build
is functional on THIS machine's real GPU - it does NOT prove sm_120 /
Blackwell execution. That distinction must be preserved verbatim in the
harness report.

A torch UserWarning on stderr is normal and must not be treated as
failure; only the JSON result / process exit code matters.
"""
import json
import sys
import traceback

result = {
    "ok": True,
    "steps": {},
    "errors": [],
}


def step(name, fn):
    try:
        fn()
        result["steps"][name] = "pass"
    except Exception as e:
        result["ok"] = False
        result["steps"][name] = "fail"
        result["errors"].append({"step": name, "error": repr(e), "trace": traceback.format_exc()})


try:
    import torch
except Exception as e:
    result["ok"] = False
    result["errors"].append({"step": "import_torch", "error": repr(e)})
    print(json.dumps(result, indent=2))
    sys.exit(1)

result["cuda_available"] = torch.cuda.is_available()

if not torch.cuda.is_available():
    result["ok"] = False
    result["errors"].append({"step": "cuda_available", "error": "torch.cuda.is_available() is False"})
    print(json.dumps(result, indent=2))
    sys.exit(1)

_tensor_holder = {}


def _alloc():
    _tensor_holder["a"] = torch.randn(1024, 1024, device="cuda")
    _tensor_holder["b"] = torch.randn(1024, 1024, device="cuda")


def _elementwise():
    _tensor_holder["c"] = _tensor_holder["a"] + _tensor_holder["b"]


def _matmul():
    _tensor_holder["d"] = torch.matmul(_tensor_holder["a"], _tensor_holder["b"])


def _reduction():
    _tensor_holder["e"] = torch.sum(_tensor_holder["d"])


def _sync():
    torch.cuda.synchronize()


step("cuda_tensor_allocation", _alloc)
step("cuda_elementwise_op", _elementwise)
step("cuda_matmul", _matmul)
step("cuda_reduction", _reduction)
step("cuda_synchronize", _sync)

# STEMwerk-relevant imports (mirrors what tools/separate.py and the
# audio-separator based pipeline actually depend on).
stemwerk_imports = ["torch", "torchaudio", "torchvision", "audio_separator", "librosa", "soundfile", "onnxruntime", "numpy"]
import_results = {}
for mod in stemwerk_imports:
    try:
        __import__(mod)
        import_results[mod] = "ok"
    except Exception as e:
        import_results[mod] = "FAILED: %r" % (e,)
        result["ok"] = False

result["stemwerk_imports"] = import_results

print(json.dumps(result, indent=2))
sys.exit(0 if result["ok"] else 1)
