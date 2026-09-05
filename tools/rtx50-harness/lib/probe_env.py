"""Reports real torch/CUDA/GPU state as JSON on stdout.

Used by the PowerShell harness for both the baseline capture and the
post-install verification. Never fakes anything - if torch is missing or
CUDA is unavailable, that is reported honestly as such.

A torch UserWarning on stderr (e.g. from torch/cuda/__init__.py) is normal
and does not affect the JSON on stdout or this script's exit code.
"""
import json
import sys

info = {}

try:
    import torch
    info["torch_version"] = torch.__version__
    info["torch_version_cuda"] = torch.version.cuda
    info["cuda_available"] = torch.cuda.is_available()
    try:
        info["arch_list"] = torch.cuda.get_arch_list()
    except Exception as e:
        info["arch_list_error"] = repr(e)
    if torch.cuda.is_available():
        try:
            info["device_name"] = torch.cuda.get_device_name(0)
            cap = torch.cuda.get_device_capability(0)
            info["device_capability"] = "%d.%d" % (cap[0], cap[1])
        except Exception as e:
            info["device_query_error"] = repr(e)
except Exception as e:
    info["torch_import_error"] = repr(e)

try:
    import torchvision
    info["torchvision_version"] = torchvision.__version__
except Exception as e:
    info["torchvision_import_error"] = repr(e)

try:
    import torchaudio
    info["torchaudio_version"] = torchaudio.__version__
except Exception as e:
    info["torchaudio_import_error"] = repr(e)

info["python_version"] = sys.version

print(json.dumps(info, indent=2))
