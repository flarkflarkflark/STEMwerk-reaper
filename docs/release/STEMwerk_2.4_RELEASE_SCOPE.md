# STEMwerk 2.4 release-core scope

Status: accepted product-owner scope decision; implementation and release validation remain open.

Basis: `d22e67e36b3d0b4ef014dbfa91a4f6ad8541708a`.

## Decision

STEMwerk 2.4 has exactly seven required user-facing flows:

1. Normal Stems
2. 6-Stem
3. Direct Kit
4. Kit Split
5. Vocals HQ
6. De-Reverb
7. Vocal De-Reverb

All seven flows are release scope. Missing implementation, distribution,
licensing, packaging, tests, or native evidence is a release gap and does not
defer a flow from 2.4.

The product name is STEMwerk. Existing repository action and UI names remain
authoritative. A missing final action name is recorded as `TO_BE_DEFINED`;
this decision does not invent action or script names.

## Required flow contract

| flow | release_required | engine | model | outputs | action_name | main_window_control | shortcut | dependencies | current_implementation | model_distribution | license_status | platform_support | native_evidence | release_gap | notes |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Normal Stems | yes | audio-separator / Demucs | user-selected `htdemucs` or `htdemucs_ft` | Vocals, Drums, Bass, Other | `STEMwerk: Main` | current | none | managed main runtime | implemented and user-facing | active models are online-downloadable, installer-aware, and release-gated | existing repository provenance | current CPU/GPU backend contracts | current-main evidence is strongest on Linux ROCm; other targets require current-main revalidation | current-main native revalidation outside Linux ROCm | Preserve current model, quality, action, and UI naming. |
| 6-Stem | yes | audio-separator / Demucs | `htdemucs_6s` | Vocals, Drums, Bass, Other, Guitar, Piano | `STEMwerk: Main` | current model choice | S | managed main runtime | implemented and user-facing | online-downloadable, installer-aware, and release-gated | existing repository provenance | current CPU/GPU backend contracts | current-main seven-platform/backend smoke matrix is incomplete | platform/backend native revalidation | Preserve existing action and UI naming. |
| Direct Kit | yes | STEMwerk DKS runtime | `stemwerk_dks` managed CKPT and canonical YAML | Kick, Snare, Toms, Hi-Hat, Ride, Crash | `Stemwerk: Direct Kit` | current `Direct Kit` control | Z | DKS-capable managed runtime | implemented and user-facing | release-gated managed model/config distribution | existing payload provenance; license follow-up already documented | current contract excludes Intel Mac and supports the other managed routes | Linux ROCm is current-main matched; other supported routes require revalidation | supported-platform native revalidation | Direct split of source audio; preserve repository naming. |
| Kit Split | yes | Demucs stage 1 plus STEMwerk DKS stage 2 | selected primary model plus `stemwerk_dks` | Kick, Snare, Toms, Hi-Hat, Ride, Crash | `Stemwerk: Drum Kit Split` | current `Kit Split` control | X | Normal Stems plus DKS-capable managed runtime | implemented and user-facing | both stages are release-gated | existing model and payload provenance | current contract excludes Intel Mac and supports the other managed routes | Linux ROCm is current-main matched; other supported routes require revalidation | supported-platform native revalidation | Stage 1 isolates drums; stage 2 splits only the isolated drums. |
| Vocals HQ | yes | BS-Roformer | BS-Roformer-Viperx-1297; `model_bs_roformer_ep_317_sdr_12.9755.ckpt` | Vocals, Other | `TO_BE_DEFINED` | required `Vocals HQ` control | `TO_BE_DEFINED` | audio-separator MDXC runtime | dev-only runtime proof exists; registry id `bs_roformer_viperx` is hidden and experimental; no user-facing activation | online download metadata exists, but installer coverage and release gate are absent | `TODO_VERIFY_BEFORE_ACTIVATION` in current registry | current registry lists CPU and CUDA; DirectML, ROCm, and MPS are experimental and all targets need release validation | contract tests exist; no release-grade native matrix | user-facing activation, registry promotion, distribution, license review, packaging, release gate, and native smokes | Functional output names are `Vocals` and `Other`; the upstream instrumental complement maps to `Other`. |
| De-Reverb | yes | MDX-Net | Reverb HQ By FoxJoy; `Reverb_HQ_By_FoxJoy.onnx` | Dry, Reverb | `TO_BE_DEFINED` | required `De-Reverb` control | R | shared De-Reverb engine/runtime | not implemented or registered | missing model mapping, download contract, checksum, packaging, and release gate | provenance and redistribution license review required | unsupported by current product contract until implemented; all eight targets require validation | not run | full implementation, model registry, output contract, UI, i18n, distribution, license, packaging, tests, release gate, and smokes | Direct two-way split of the complete source. |
| Vocal De-Reverb | yes | two-stage BS-Roformer then MDX-Net | stage 1 `model_bs_roformer_ep_317_sdr_12.9755.ckpt`; stage 2 `Reverb_HQ_By_FoxJoy.onnx` | Dry Vocal, Vocal Reverb, Other | `TO_BE_DEFINED` | required `Vocal De-Reverb` control | E | reuses Vocals HQ and the De-Reverb engine | not implemented or registered | shares the two model references; composite packaging and release-gate coverage are missing | inherits both model reviews; no additional license assumption | unsupported by current product contract until implemented; all eight targets require validation | not run | transactional pipeline, routing, cleanup, UI, i18n, packaging, tests, release gate, and smokes | Only `Vocals` enters stage 2; stage-1 `Other` is preserved unchanged. |

## Fixed model and output contracts

### Vocals HQ

```text
FLOW_ID=vocals_hq
DISPLAY_NAME=Vocals HQ
ENGINE=BS-Roformer
MODEL_FAMILY=BS-Roformer-Viperx-1297
MODEL_FILENAME=model_bs_roformer_ep_317_sdr_12.9755.ckpt
OUTPUTS=Vocals,Other
```

Current repository state:

- internal model id: `bs_roformer_viperx`;
- hidden and experimental: yes;
- activation: explicit development environment gate only;
- action and main-window control: absent;
- distribution: online audio-separator metadata exists, but no bundled payload
  or release gate;
- license: unresolved before activation;
- runtime profiles: CPU and CUDA listed; DirectML, ROCm, and MPS experimental;
- tests: development routing, gating, complement mapping, and exact two-output
  validation exist.

The 2.4 implementation must make this flow user-facing, distribution-covered,
licensed, packaged, tested, and release-gated.

### De-Reverb

```text
FLOW_ID=de_reverb
DISPLAY_NAME=De-Reverb
ENGINE=MDX-Net
MODEL_FAMILY=Reverb HQ By FoxJoy
MODEL_FILENAME=Reverb_HQ_By_FoxJoy.onnx
OUTPUTS=Dry,Reverb
ACTION_NAME=TO_BE_DEFINED
MAIN_WINDOW_CONTROL=required
SHORTCUT_LABEL=R
```

The current repository has general ONNX runtime infrastructure but no
De-Reverb model entry, mapping, output contract, action, main-window control,
translation, tooltip, package rule, checksum, provenance decision, test, or
release gate. General ONNX support is not proof that this model or flow works.

### Vocal De-Reverb

```text
FLOW_ID=vocal_de_reverb
DISPLAY_NAME=Vocal De-Reverb
PIPELINE_TYPE=two_stage
STAGE1_FLOW=vocals_hq
STAGE1_MODEL=model_bs_roformer_ep_317_sdr_12.9755.ckpt
STAGE2_ENGINE=MDX-Net
STAGE2_MODEL=Reverb_HQ_By_FoxJoy.onnx
STAGE2_INPUT=Vocals
OUTPUTS=Dry Vocal,Vocal Reverb,Other
ACTION_NAME=TO_BE_DEFINED
MAIN_WINDOW_CONTROL=required
SHORTCUT_LABEL=E
```

Required functional pipeline:

```text
source
-> Vocals HQ
   |-> Vocals
   |   -> Reverb HQ By FoxJoy
   |      |-> Dry Vocal
   |      `-> Vocal Reverb
   `-> Other
-> final: Dry Vocal + Vocal Reverb + Other
```

Pipeline invariants:

- only `Vocals` is passed to stage 2;
- `Other` is the stage-1 complement and bypasses the De-Reverb engine;
- the final result contains exactly three files/tracks, ordered `Dry Vocal`,
  `Vocal Reverb`, `Other`;
- this flow never applies full-mix De-Reverb;
- intermediate files are private to the transaction and are removed on success
  or failure according to the established temporary-file policy;
- failure publishes no partial result and imports no partial track set;
- undo, track-folder, channel, sample-rate, duration, and output-count behavior
  must be validated before import;
- both model/runtime references are shared with their owning flows rather than
  installed or distributed twice.

```text
VOCALS_HQ_SHARED_BY_VOCAL_DEREVERB=yes
DEREVERB_ENGINE_SHARED_BY_BOTH_DEREVERB_FLOWS=yes
```

## User-facing access contract

| flow | ACTION_NAME | MAIN_WINDOW_CONTROL | SHORTCUT_LABEL | implementation_status |
|---|---|---|---|---|
| Normal Stems | `STEMwerk: Main` | current | none | implemented |
| 6-Stem | `STEMwerk: Main` | current model choice | S | implemented |
| Direct Kit | `Stemwerk: Direct Kit` | current | Z | implemented |
| Kit Split | `Stemwerk: Drum Kit Split` | current | X | implemented |
| Vocals HQ | `TO_BE_DEFINED` | required | `TO_BE_DEFINED` | required activation |
| De-Reverb | `TO_BE_DEFINED` | required | R | implementation required |
| Vocal De-Reverb | `TO_BE_DEFINED` | required | E | implementation required |

## Platform/backend implementation and validation matrix

Each cell describes current status, not desired final support. A required flow
remains in 2.4 scope when a cell is not yet green.

| flow | Windows CPU | Windows DirectML | Windows CUDA | macOS Intel CPU | macOS MPS | Linux CPU | Linux ROCm | Linux CUDA |
|---|---|---|---|---|---|---|---|---|
| Normal Stems | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | NATIVE_SMOKE_REQUIRED | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | PASS_CURRENT_MAIN | PASS_OLDER_HEAD_REVALIDATION_REQUIRED |
| 6-Stem | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | NATIVE_SMOKE_REQUIRED | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | NATIVE_SMOKE_REQUIRED | PASS_OLDER_HEAD_REVALIDATION_REQUIRED |
| Direct Kit | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | UNSUPPORTED_BY_CURRENT_CONTRACT | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | PASS_CURRENT_MAIN | PASS_OLDER_HEAD_REVALIDATION_REQUIRED |
| Kit Split | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | UNSUPPORTED_BY_CURRENT_CONTRACT | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | PASS_OLDER_HEAD_REVALIDATION_REQUIRED | PASS_CURRENT_MAIN | PASS_OLDER_HEAD_REVALIDATION_REQUIRED |
| Vocals HQ | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED |
| De-Reverb | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED |
| Vocal De-Reverb | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED | IMPLEMENTATION_REQUIRED |

For the three newly required flows, implementation is the first gate. After
implementation, every intended backend separately requires model distribution,
license, packaging, release-gate, and native-smoke evidence. No support claim is
created merely by listing a generic runtime provider.

## Artifact scope

Required normal 2.4 artifact families:

1. Windows online installer
2. Windows bundled installer
3. macOS online `.pkg`
4. Linux online package family

Optional 2.4 artifact families:

1. macOS Apple Silicon bundled `.pkg`
2. Linux bundled package family

Not required for 2.4:

- new Linux offline installers;
- new Linux all-models installers;
- rebuilt Windows or macOS offline all-models families;
- the future Component Manager.

Required and optional normal/bundled artifacts must carry the product code,
model download contracts, checksum/integrity contracts, and distribution rules
needed by all seven flows. Online/on-demand model acquisition is allowed where
that is the selected normal installer contract. One shared payload/reference
must serve every flow that uses the same model or runtime.

```text
LINUX_OFFLINE_REQUIRED_FOR_2_4=no
LINUX_OFFLINE_ALLMODELS_REQUIRED_FOR_2_4=no
COMPONENT_MANAGER_REQUIRED_FOR_2_4=no
```

## Outstanding release gates

The corrected scope decision itself is resolved by this document. The
following P1 implementation work remains:

1. Promote Vocals HQ from the hidden development route to a user-facing flow.
2. Implement the direct De-Reverb flow.
3. Implement the transactional Vocal De-Reverb pipeline.
4. Extend model registry, mappings, output semantics, and shared dependencies.
5. Add model acquisition/distribution contracts, checksums, and deduplication.
6. Resolve model provenance, redistribution, and license status.
7. Define and implement the three missing action/script entry points without
   assuming their final names.
8. Add main-window controls, including De-Reverb `R` and Vocal De-Reverb `E`.
9. Add translations and tooltips.
10. Add output, pipeline, cleanup, transaction, and regression tests.
11. Extend normal/bundled packaging for the seven-flow contract.
12. Extend release gates to make all required models and flows auditable.

The following P1 release revalidation remains after implementation:

1. Validate every intended flow/backend combination independently.
2. Run current-main native smokes on required platform/backend targets.
3. Build and validate the selected candidate artifact families.

Neither the Component Manager nor new offline/all-models productisation is a
P0 or P1 requirement for this release.

## Acceptance markers

```text
AUDIT_SCOPE_OVERRIDE=yes
RELEASE_FLOW_COUNT=7
REQUIRED_FLOWS=Normal Stems,6-Stem,Direct Kit,Kit Split,Vocals HQ,De-Reverb,Vocal De-Reverb
VOCALS_HQ_REQUIRED_FOR_2_4=yes
DEREVERB_REQUIRED_FOR_2_4=yes
VOCAL_DEREVERB_REQUIRED_FOR_2_4=yes
VOCALS_HQ_MODEL=model_bs_roformer_ep_317_sdr_12.9755.ckpt
DEREVERB_MODEL=Reverb_HQ_By_FoxJoy.onnx
DEREVERB_OUTPUT_COUNT=2
VOCAL_DEREVERB_OUTPUT_COUNT=3
DE_REVERB_SHORTCUT=R
VOCAL_DE_REVERB_SHORTCUT=E
VOCALS_HQ_SHARED_BY_VOCAL_DEREVERB=yes
DEREVERB_ENGINE_SHARED_BY_BOTH_DEREVERB_FLOWS=yes
```
