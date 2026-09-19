# STEMwerk Model Compatibility Matrix — Phase L3

Status date: 2026-09-19. Companion document to `README.md`'s Phase L3 section. Built from
direct inspection of this repository (`experiment/webgpu-ep`, based on `origin/main` @
`c0f1d3294`) and the installed `audio-separator==0.47.0` package's own model catalog —
**not** from memory or assumption. See "Sources" at the bottom for exactly what was
inspected.

## Reading this matrix

Three distinct populations, per the brief's required distinction — **do not conflate
them**:

1. **Production** — a model STEMwerk's actual REAPER UI can currently cause to run.
2. **Catalog** — a model `audio-separator` (STEMwerk's inference dependency) knows how
   to download and run, but that no STEMwerk workflow currently selects.
3. **External** — a model not in either of the above, considered here only as a
   feasibility question (Demucs/RoFormer ONNX conversion, §9 of the README).

## A. Production models (what STEMwerk's UI actually runs today)

| Model | STEMwerk workflow | Model family | Format | Existing inference runtime | Existing GPU route | ONNX available | WebGPU tested | Conversion needed | Major obstacle |
|---|---|---|---|---|---|---|---|---|---|
| `htdemucs` | All Stems, Vocals/Bass/Drums Only, Karaoke (stem-selection preset only — see note), AI Separate (default) | Demucs (Hybrid Transformer) | PyTorch (native `demucs` package weights) | PyTorch, native (not onnx2torch, not onnxruntime) | CUDA / ROCm (via torch) / MPS / CPU | **No** (no first-party ONNX release; see §9) | No | **Yes, unverified** | Complex64 STFT + attention ops with no native ONNX symbolic (per unverified 2026 community report, §9) |
| `htdemucs_ft` | AI Separate (user-selectable) | Demucs (Hybrid Transformer, fine-tuned) | PyTorch | PyTorch, native | CUDA / ROCm / MPS / CPU | **No** (same caveat) | No | Yes, unverified | Same as `htdemucs` |
| `htdemucs_6s` | AI Separate (user-selectable) | Demucs (Hybrid Transformer, 6-stem) | PyTorch | PyTorch, native | CUDA / ROCm / MPS / CPU | No | No | Yes, unverified | Same as `htdemucs`, plus larger/more complex head (6 stems) |
| `hdemucs_mmi` | Alias exists in `stemwerk_core/models.py`, **not offered in the actual UI radio list** (`STEMwerk.lua` `MODELS` table has only the three above) | Demucs (Hybrid, MMI-trained) | PyTorch | PyTorch, native | CUDA / ROCm / MPS / CPU | No | No | Yes, unverified | Same as `htdemucs`; also currently unreachable from the UI regardless |
| `MDX23C-DrumSep-aufr33-jarredou.ckpt` (→ `aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt`) | Drum Kit Split (stage 2, after Demucs stage 1 isolates Drums) | MDXC (MDX23C architecture) | PyTorch `.ckpt` + `.yaml` config (`config_drumsep_mdx23c.yaml`, confirms `act: gelu`, subband/instrument config) | PyTorch (audio-separator's MDXC-checkpoint loader — **not independently re-traced line-by-line in this phase**, carried forward from the Phase L1 architecture finding that MDXC/`.ckpt` models bypass onnxruntime) | CUDA / ROCm / MPS / CPU | **No** | No | Yes, unverified | Attention-based MDXC architecture; no ONNX export attempted by anyone found in this research |

**Karaoke note**: `STEMwerk_Karaoke.lua` does **not** select a dedicated karaoke model
(e.g. `UVR_MDXNET_KARA_2`) — it applies a stem-selection preset (`applyPresetKaraoke`,
deselecting Vocals, keeping Drums+Bass+Other) on top of whatever the default separation
model (`htdemucs`) already produced. This means STEMwerk's "Karaoke" feature and the
`UVR_MDXNET_KARA_2.onnx` model this experiment has been testing since Phase L1 are
**unrelated** — same English word, different model, different code path entirely.

## B. Catalog models (in `audio-separator`, not wired into any STEMwerk workflow)

`audio-separator`'s own catalog (`Separator.list_supported_model_files()`) has **169
total entries**, of which **39 have a real `.onnx` filename** — all 39 are exclusively
**MDX-Net** family models (see README.md Phase L3 §2 for why this is an important,
honestly-reported limitation: there is no architectural diversity in the ONNX-native
catalog, only shape/weight/task diversity within one graph template). None of the 39 are
selectable from any current STEMwerk UI or CLI path that is actually reachable — see
below.

| Model | Source | Reachable from STEMwerk UI? | Format | WebGPU tested (this experiment) | Notes |
|---|---|---|---|---|---|
| `UVR_MDXNET_KARA_2.onnx` | `audio-separator` catalog (Phase L1/L2 primary test model) | No | ONNX | **Yes — PASS** (L1, L2, M1, L3 regression) | 185/185 nodes on WebGPU across all 4 test rounds |
| `Kim_Vocal_2.onnx` | `audio-separator` catalog | **No** — appears only inside `audio_separator_process.py`'s `--list-models` CLI help text (line ~4412); no `.lua` script ever invokes `--list-models` or passes `--model Kim_Vocal_2` | ONNX | Not tested (out of L3's selected-3 scope; architecturally identical to KARA_2/Inst_HQ_5, no new information expected) | Confirmed via dedicated repo research this phase, not assumed |
| `Reverb_HQ_By_FoxJoy.onnx` | `audio-separator` catalog (Phase L3 new test model) | No | ONNX | **Yes — PASS** | Native `dim_t=512` ≠ default `segment_size=256` — silently uses PyTorch/onnx2torch unless `segment_size` is explicitly overridden to 512 (see README §"segment_size / dim_t routing trap") |
| `kuielab_a_bass.onnx` | `audio-separator` catalog (Phase L3 new test model) | No | ONNX | **Yes — PASS** | Same `segment_size` override needed as above; `n_fft=16384`, the largest FFT size tested |
| `UVR-MDX-NET-Inst_HQ_5.onnx` | `audio-separator` catalog (Phase L3 new test model) | No | ONNX | **Yes — PASS** | `dim_t=256` matches default `segment_size` — reaches onnxruntime without any override; most "production-relevant" of the 3 (general vocals/instrumental split, latest HQ tier) |
| (35 other MDX-Net `.onnx` entries) | `audio-separator` catalog | No | ONNX | Not tested | All confirmed to share the identical 178-node / 8-op-type graph topology as the 4 tested models (verified via `onnx.load` + `Counter(op_type)` on all 4 downloaded files) — untested ones are not assumed identical in *behavior*, only in static graph shape, per the brief's own warning against assuming file-extension/architecture proves anything beyond what was actually run |
| ~130 VR-Arch (`.pth`) / MDXC & RoFormer (`.ckpt`) / Demucs-alias catalog entries | `audio-separator` catalog | No (VR-Arch/MDXC never wired into any STEMwerk workflow) | PyTorch (`.pth`/`.ckpt`) | No — out of scope (not ONNX) | Confirmed zero `.onnx` entries in VR-Arch or MDXC categories in this catalog snapshot |

## C. External candidates (not in STEMwerk or the current `audio-separator` catalog)

None downloaded or tested in this phase — see README.md §9 for the Demucs/RoFormer/
DrumSep-to-ONNX feasibility discussion (research only, no conversion performed, per the
brief's explicit instruction).

## Segment_size / dim_t routing trap (cross-cutting finding, applies to B above)

Discovered directly by this phase's own test run, not predicted in advance: MDX-Net
`.onnx` models whose native `dim_t` doesn't equal `audio-separator`'s configured
`segment_size` (default `256`) get **silently routed through `onnx2torch`→PyTorch
instead of onnxruntime**, regardless of `onnx_execution_provider`. This is invisible
from the catalog listing, the filename, or `get_providers()` — it only shows up as
`MDXSeparator.uses_pytorch_inference == True` and a debug-level log line ("Model
converted from onnx to pytorch due to segment size not matching dim_t"). Of the 4 models
tested in this experiment: `UVR_MDXNET_KARA_2` and `UVR-MDX-NET-Inst_HQ_5` (both
`dim_t=256`) reach onnxruntime under the default config; `Reverb_HQ_By_FoxJoy` and
`kuielab_a_bass` (both `dim_t=512`) do not, unless `segment_size` is explicitly set to
match. Setting it is a legitimate, pre-existing `audio-separator` config parameter, not
a model-graph edit — this experiment's `end_to_end_pipeline_test.py` now supports an
explicit `mdx_segment_size` override for exactly this reason. **Any future STEMwerk
WebGPU integration would need to auto-detect and apply the correct `segment_size` per
model, or every non-`dim_t=256` MDX-Net model would silently never touch WebGPU at all
while still reporting successful separation.**

## Sources (exactly what was inspected, no filling-in-from-memory)

- `scripts/reaper/vendor/stemwerk-core/src/stemwerk_core/models.py` (Demucs alias map,
  4 entries)
- `scripts/reaper/vendor/stemwerk-core/src/stemwerk_core/separator.py`
- `scripts/reaper/_internal/stemwerk_drumsep_process.py`
- `scripts/reaper/audio_separator_process.py` (incl. `DIRECT_DKS_MODEL_*` constants,
  `--list-models` CLI branch)
- `scripts/reaper/STEMwerk.lua` (`MODELS` table, `checkQuickPreset`,
  `DRUMKIT_STEMS`)
- `scripts/reaper/STEMwerk_All_Stems.lua`, `STEMwerk_Vocals_Only.lua`,
  `STEMwerk_Bass_Only.lua`, `STEMwerk_Drums_Only.lua`, `STEMwerk_Karaoke.lua`,
  `STEMwerk_Drum_Kit_Split.lua`, `STEMwerk_AI_Separate.lua`
- `tools/assets/macos/drumsep/config_drumsep_mdx23c.yaml`
- `tests/test_dependency_constraints.py`, `tests/test_stemwerk_core_models.py`,
  `tests/test_b0_model_preflight.py`, `tests/test_b0_small_model_descriptor_2310.py`,
  `tests/test_model_failure_classification.py`
- Installed `audio-separator==0.47.0`'s `Separator.list_supported_model_files()` (169
  entries, live-enumerated in this phase, not from documentation)
- `mdx_model_data.json` / `download_checks.json` (cached alongside the downloaded
  models, part of `audio-separator`'s own catalog metadata, not a STEMwerk file)
- Direct `onnx.load()` + `onnx.checker.check_model()` + `Counter(node.op_type)` on all 4
  downloaded `.onnx` files this phase
- Direct execution: `l3_model_compatibility_test.py` against the real RX 9070 (see
  README.md Phase L3 §5 for full results)
