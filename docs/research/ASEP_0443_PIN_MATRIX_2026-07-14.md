# audio-separator 0.44.3 pin-matrix R&D (2026-07-14)

## Summary / verdict

ASEP_0443_PIN_MATRIX_READY_FOR_SPLIT_BRANCHES. audio-separator 0.44.3 is
promising, but not as a single big-bang runtime upgrade.

- Platform/backend pins must be split and smoked independently.
- Runtime unification stays out of scope until the platform pins are proven.
- DrumSep/DKS stays on the existing release runtime for now because the
  0.44.3 catalog/model rename creates install and upgrade risk.
- This note is docs-only research. It does not change bootstrap, installers,
  wheelhouses, constraints, runtime behavior, tags, or releases.

Upstream stemwerk-core sync remains parked because the separate upstream repo
was not available locally during the earlier sync pass.

## Current production pins

Linux main runtime:

- audio-separator: 0.23.0, GPU extra uses `audio-separator[gpu]==0.23.0`
- torch / torchaudio: 2.5.1
- torchvision: 0.20.1
- numpy: 1.26.4
- numba: 0.59.1
- llvmlite: 0.42.0
- onnxruntime: unpinned `onnxruntime`
- Python target: managed Linux Python 3.12.13 for payload builds/runtime

macOS Apple Silicon payload:

- audio-separator: 0.23.0
- torch / torchaudio: 2.5.1
- torchvision: 0.20.1
- numpy: 1.26.4
- numba: 0.59.1
- llvmlite: 0.42.0
- onnxruntime: generic/fallback `onnxruntime` as currently implemented, not
  `onnxruntime-silicon` in the payload builder
- Python target: native Python 3.12 wheel downloads

Windows main runtime:

- audio-separator: 0.24.4
- torch / torchaudio: 2.4.1
- torchvision: 0.19.1
- CUDA suffix: `+cu121` where applicable
- torch-directml: 0.2.5.dev240914
- onnxruntime-directml: 1.24.4
- normal onnxruntime policy: backend-scoped; DirectML pinned, generic
  `onnxruntime` for normal CPU/CUDA dependency policy
- Windows wheelhouse target: CPython 3.11 / Python 3.11.8 installer payload

DrumSep/DKS runtimes:

- audio-separator: 0.34.1
- onnxruntime: 1.26.0 for CPU/ROCm where current
- onnxruntime-gpu: 1.24.4 for Windows CUDA where current
- DirectML ORT: 1.24.4
- torch stacks are platform-specific:
  - Linux DrumSep CPU: torch 2.12.0+cpu, torchvision 0.27.0+cpu
  - Linux DrumSep CUDA: torch/torchaudio 2.4.1+cu121, torchvision 0.19.1+cu121
  - Linux DrumSep ROCm default: torch/torchaudio 2.9.1+rocm6.4,
    torchvision 0.24.1+rocm6.4
  - Linux DrumSep ROCm gfx1201/RX 9070: torch/torchaudio 2.10.0+rocm7.0,
    torchvision 0.25.0+rocm7.0
  - Windows DrumSep CPU: torch 2.12.0, torchvision 0.27.0
  - Windows DrumSep CUDA: torch/torchaudio 2.4.1+cu121,
    torchvision 0.19.1+cu121
  - Windows DrumSep DirectML: torch 2.4.1, torchvision 0.19.1,
    torch-directml 0.2.5.dev240914

## Evidence matrix

| Platform | Backend | Python | audio-separator | torch / torchaudio / torchvision | onnxruntime | numpy / numba / llvmlite | Workflows/models tested | Result | Confidence | Source/evidence root |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Linux RX 9070 | ROCm | 3.12.13 | 0.44.3 | torch 2.10.0+rocm7.0 / torchaudio 2.10.0+rocm7.0 / torchvision 0.25.0+rocm7.0 present/bycatch | 1.27.0 | beartype 0.18.5; numpy/numba/llvmlite not the failure axis in the R&D note | htdemucs_ft, DKS real entrypoint, Viperx rerun | PASS; Viperx Python 3.14 failure classified as beartype/toolchain artifact, not model/backend failure | High | `docs/research/MAC_LINUX_ROFORMER_ASEP_0443_RND.md`; R&D/chat smoke evidence |
| Linux RTX 3060 Laptop | CUDA | 3.11.14 | 0.44.3 | torch 2.13.0+cu130 / torchaudio absent in that R&D runtime / torchvision not recorded | onnxruntime-gpu 1.27.0; providers included TensorRT, CUDA, CPU | not recorded | htdemucs, htdemucs_ft, htdemucs_6s, Viperx, DKS CUDA, PR68 process path with `cuda:0` | PASS in R&D stack; current main device-routing smoke used production ASEP 0.23.0 + torch 2.5.1+cu124 and proves routing only | High for R&D stack; needs short current-main reconfirmation before pin PR | R&D/chat smoke evidence; current main routing smoke root outside repo |
| Windows native | CPU | 3.11.0 | 0.44.3 | torch 2.13.0+cpu / torchaudio unknown or absent / torchvision not recorded | onnxruntime 1.27.0; onnxruntime-directml 1.24.4 available only as provider probe | not recorded | htdemucs, htdemucs_ft, htdemucs_6s, Viperx CPU, PR68 process path | PASS for main CPU routes; DKS skipped in isolated root | High for Windows CPU main routes; low for DKS | R&D/chat smoke evidence |
| macOS Apple Silicon | MPS | exact R&D Python not recovered in repo | 0.44.3 | modern torch in R&D; exact version not recovered in repo; torch 2.5.1 MPS was bad/slow for RoFormer and must not be carried into new RoFormer policy | exact R&D ORT not recovered in repo | not recorded | Demucs, Viperx/RoFormer, PR68 process path | PASS; 0.44.3 fixed Demucs safeload issue seen with 0.23.0 + modern torch | Medium/high after exact version recovery | `docs/research/MAC_LINUX_ROFORMER_ASEP_0443_RND.md`; macOS R&D/chat evidence |
| Windows native | DirectML | current target 3.11 | current release pins only | current release pins only | provider-probe only | current release pins only | provider probe | No processing smoke for ASEP 0.44.3 | Low | repo policy + R&D/chat context |
| Windows native | NVIDIA CUDA | open | open | open | open | open | none for native Windows CUDA ASEP 0.44.3 | Do not infer from Linux NVIDIA | Low | missing evidence |
| Windows native | AMD ROCm | open | open | open | open | open | none | Out of scope; Windows AMD remains DirectML path | Low | repo docs/policy |
| DrumSep/DKS | CPU/CUDA/ROCm/DirectML/MPS | mixed | current release 0.34.1; ROCm R&D observed 0.44.3 PASS | mixed platform stacks | mixed platform ORT pins | mixed platform pins | DKS ROCm R&D with 0.44.3; current release DKS with 0.34.1 | 0.44.3 R&D PASS exists, but release migration blocked by model/catalog rename | Medium for R&D; low for release migration | `docs/research/MAC_LINUX_ROFORMER_ASEP_0443_RND.md`; DKS R&D/chat evidence |

Current main device-normalization evidence is separate from the 0.44.3 pin
evidence. The NVIDIA CUDA smoke on current main proved device routing with the
production runtime (`audio-separator 0.23.0`, torch 2.5.1+cu124), not the
0.44.3 candidate stack.

## Candidate pin recommendations

### Candidate / likely: Linux ROCm

Proposed first branch candidate:

- Python: 3.12.13
- audio-separator: 0.44.3
- torch: 2.10.0+rocm7.0
- torchaudio: 2.10.0+rocm7.0
- torchvision: 0.25.0+rocm7.0 only if required by resolved payload/tests
- onnxruntime: 1.27.0, or keep the current unpinned policy if it resolves to
  1.27.0 in the target environment
- numpy: keep 1.26.4 for the main runtime first branch
- numba: keep 0.59.1 for the main runtime first branch
- llvmlite: keep 0.42.0 for the main runtime first branch
- beartype: 0.18.5 is acceptable on Python 3.12; Python 3.14 is known-bad for
  Viperx with this beartype/toolchain combination

Evidence confidence is high. The branch still needs normal installer/bootstrap
smokes because wheelhouse and offline payload behavior are separate from R&D
throwaway-runtime success.

### Candidate / needs short reconfirmation: Linux NVIDIA CUDA

Do not propose keeping old torch 2.5.1 as the 0.44.3 candidate.

Proven R&D candidate:

- Python: 3.11.14
- audio-separator: 0.44.3
- torch: 2.13.0+cu130
- torchaudio: absent in smoke
- onnxruntime-gpu: 1.27.0
- ORT providers: TensorRT/CUDA/CPU observed in R&D smoke

Before installer pin:

- rerun a short current-main smoke with warm cache
- include htdemucs, htdemucs_ft, htdemucs_6s, Viperx, and DKS CUDA
- decide explicitly whether Linux bootstrap should keep requiring torchaudio
  for NVIDIA, or whether the assertion should be relaxed for this stack

### Candidate / needs exact version recovery: macOS Apple Silicon MPS

Candidate direction:

- audio-separator: 0.44.3
- torch: modern torch from R&D, not 2.5.1 for RoFormer policy
- Python/torch/ORT exact versions: recover from R&D logs before any pin PR

Known constraints:

- 0.44.3 fixed the Demucs safeload issue seen with 0.23.0 + modern torch.
- torch 2.5.1 MPS was bad/slow for RoFormer and must not be carried into the
  RoFormer policy.
- Existing MPS cap/policy R&D remains useful, but it is not a substitute for an
  exact 0.44.3 payload pin smoke.

### Candidate / needs isolated branch: Windows CPU

Do not propose keeping old torch 2.4.1 as the initial 0.44.3 candidate.

Proven CPU candidate:

- Python: 3.11.0
- audio-separator: 0.44.3
- torch: 2.13.0+cpu
- onnxruntime: 1.27.0

Scope:

- main CPU routes only at first
- DKS remains unproven in the isolated root and should stay out of the first
  Windows CPU pin PR

### Do not change yet

Windows DirectML:

- provider-probe only
- no ASEP 0.44.3 processing smoke
- keep current policy and pins

Windows NVIDIA CUDA:

- do not infer from Linux NVIDIA
- needs native Windows CUDA ASEP 0.44.3 smoke

Windows AMD ROCm:

- no release-ready evidence
- remains out of scope
- Windows AMD path remains DirectML

DrumSep/DKS release runtimes:

- keep current release runtime at audio-separator 0.34.1
- 0.44.3 DKS ROCm R&D PASS exists, but release migration is blocked by catalog
  and model filename changes

## DrumSep/DKS catalog rename blocker

audio-separator 0.44.3 changes the DrumSep catalog/model names observed in
R&D:

- `MDX23C-DrumSep-aufr33-jarredou.ckpt`
- `config_drumsep_mdx23c.yaml`

Current STEMwerk release paths expect:

- `aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt`
- `aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml`

Do not pin DKS to audio-separator 0.44.3 until these scenarios pass:

- old cache
- fresh install
- mixed upgrade state, matching the real user case

Likely later code/data surfaces:

- `scripts/reaper/_internal/stemwerk_drumsep_process.py`
- `scripts/reaper/models.json`
- runtime-managed asset aliases
- offline/bundled model asset expectations
- old-cache/fresh-install/mixed-upgrade tests

## Risks and constraints

onnxruntime:

- Current repo policy deliberately keeps Linux main generic/unpinned while
  DrumSep and DirectML pins are platform-scoped.
- Do not normalize ORT across all platforms in the first pin branches.
- `onnxruntime 1.27.0` is proven in the ROCm and Windows CPU R&D stacks, and
  `onnxruntime-gpu 1.27.0` is proven in the Linux NVIDIA R&D stack.

torchaudio:

- Current Linux bootstrap asserts torch and torchaudio pins.
- The Linux NVIDIA 0.44.3 R&D smoke had torchaudio absent.
- A NVIDIA pin branch must either add torchaudio to the candidate stack and
  smoke it, or intentionally relax the assertion with tests.

numpy:

- Main runtime should stay on the NumPy 1.26 side of the boundary for the first
  ASEP 0.44.3 branches.
- DrumSep currently uses a separate NumPy 2.x stack and should not be merged
  into main runtime policy.

numba / llvmlite:

- Keep the known-compatible pairs together.
- Main runtime: numba 0.59.1 with llvmlite 0.42.0.
- Windows main wheelhouse currently has numba 0.66.0 with llvmlite 0.48.0.
- Windows DrumSep CPU currently has numba 0.65.1 with llvmlite 0.47.0.

Python:

- Python 3.12.13 is proven for Linux ROCm 0.44.3.
- Python 3.11.14 is proven for Linux NVIDIA R&D.
- Python 3.11.0 is proven for Windows CPU R&D.
- Python 3.14/beartype failure is a toolchain artifact, but it is still a
  hard pin boundary for Viperx until proven otherwise.

Demucs:

- Do not introduce a separate pip `demucs` pin.
- Use audio-separator's managed/vendored Demucs path.

Runtime unification:

- Do not unify main/DKS/runtime stacks before platform pins are proven.
- Keep platform-specific payload and fallback behavior explicit.

Offline payloads / wheelhouses:

- Every package pin change has offline wheelhouse impact.
- The first pin branches must update payload completeness checks and dependency
  guard tests together with the relevant platform only.

## Recommended PR order

1. Docs-only R&D record: this note.
2. Linux ROCm ASEP 0.44.3 pin branch.
3. Linux NVIDIA ASEP 0.44.3 pin branch after short current-main reconfirmation.
4. macOS Apple Silicon ASEP 0.44.3 pin branch after exact Python/torch/ORT
   recovery.
5. Windows CPU ASEP 0.44.3 pin branch.
6. Windows DirectML and Windows CUDA R&D branches.
7. DrumSep/DKS 0.44.3 migration branch only after catalog rename scenarios pass.
8. Unified runtime R&D only after the platform pins above are proven.

## Non-goals for this note

- No installer changes.
- No bootstrap changes.
- No constraints or package pin changes.
- No runtime cleanup.
- No setup/repair.
- No model pack changes.
- No tags, releases, or installer builds.
