# Linux NVIDIA CUDA bootstrap ASEP 0.44.3 evidence (2026-07-15)

## Verdict

LINUX_NVIDIA_CUDA_BOOTSTRAP_ASEP0443_PASS.

This was a docs-only validation run on the Linux NVIDIA laptop. It used a
throwaway runtime root only and did not mutate the production runtime. No code
changes, tags, releases, or installer builds were made.

## Scope

- Repository: `/home/flark/GIT/STEMwerk`
- Main commit: `fb284760e13624f66c0a7251d399dc11777929e7`
- Throwaway root:
  `/home/flark/stemwerk-rnd/linux-nvidia-cuda-bootstrap-asep0443-20260715T031109Z`
- Runtime base:
  `/home/flark/stemwerk-rnd/linux-nvidia-cuda-bootstrap-asep0443-20260715T031109Z/runtime`
- Bootstrap command: `sh scripts/reaper/STEMwerk_Bootstrap_Linux.sh`
- Bootstrap result: exit 0
- Bootstrap elapsed time: 410s

## Host

- GPU: NVIDIA GeForce RTX 3060 Laptop GPU
- NVIDIA driver: 610.43.02
- CUDA UMD: 13.3

## Runtime state

- Managed Python: 3.12.13
- `READY_TO_GO_STATUS=ok`
- `PROFILE=linux-cuda`
- `BACKEND=cuda`
- `RUNTIME_VERIFY_DETAIL=ok`

## Main runtime package evidence

| Package | Version |
| --- | --- |
| audio-separator | 0.44.3 |
| numpy | 2.4.4 |
| scipy | 1.18.0 |
| numba | 0.66.0 |
| llvmlite | 0.48.0 |
| torch | 2.5.1+cu124 |
| torchaudio | 2.5.1 |
| torchvision | 0.20.1 |
| onnxruntime | 1.27.0 |
| beartype | 0.18.5 |

`python -m pip check`: PASS.

## CUDA probe

- `torch.version.cuda=12.4`
- `torch.version.hip=None`
- `torch.cuda.is_available=True`
- `torch.cuda.device_count=1`
- Device: NVIDIA GeForce RTX 3060 Laptop GPU

## Parent-route processing smokes

All smokes used `scripts/reaper/audio_separator_process.py` from the current
main checkout and the throwaway main `.venv`.

| Model/device | Result | Time |
| --- | --- | --- |
| `htdemucs --device cuda` | PASS | 16s |
| `htdemucs_ft --device cuda` | PASS | 7s |
| `htdemucs_6s --device cuda` | PASS | 5s |
| `htdemucs --device cuda:0` | PASS | 6s |
| `htdemucs --device cuda:9` | expected FAIL, exit 2 | 1s |

The negative `cuda:9` smoke failed with
`cuda_index_out_of_range:index=9:count=1`, as expected on a one-GPU host.

## Marker evidence

Positive CUDA smokes reported:

- `normalized_device=cuda:0`
- `effective_backend=cuda`
- `selected_device=cuda:0`
- `effective_device=cuda:0`
- `torch_cuda_device_name=NVIDIA GeForce RTX 3060 Laptop GPU`

The negative `cuda:9` smoke reported:

- `normalized_device=cuda:9`
- `effective_backend=cuda`
- `cpu_fallback_blocked=true`
- `device_normalization_error_reason=cuda_index_out_of_range:index=9:count=1`

No positive CPU fallback was observed.

## DrumSep/DKS observation

- `DRUMSEP_READY_RUNTIME=cpu`
- `DRUMSEP_READY_RUNTIME_STATUS=ok`
- No ROCm state file was created.
- ROCm-only `main_unified` logic did not interfere with Linux NVIDIA/CUDA
  bootstrap or normal CUDA processing.

This does not force NVIDIA runtime unification and does not change DrumSep/DKS
release policy.

## Final scope confirmation

- Production runtime mutation: none
- Code changes: none
- Tags: none
- Releases: none
- Installer builds: none
