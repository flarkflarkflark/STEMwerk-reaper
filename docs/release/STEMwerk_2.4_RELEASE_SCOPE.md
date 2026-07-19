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

## Setup & Component Manager contract

STEMwerk 2.4 must deliver a usable first version of the **STEMwerk Setup &
Component Manager**. This is required release scope, not future-only work.

The primary user choices are the seven release flows. Technical model names are
advanced details rather than the primary setup UX. During installation, users
must be able to select flows/components. After installation, they must be able
to add components, remove them when safe, repair and verify selected
components, refresh installed state, see required download and installed size,
see a recommended backend, and be prevented from selecting incompatible
choices.

### Shared component contract

The cross-platform contract must cover:

- a flow/component registry and dependency graph;
- shared components and reference-aware removal policy;
- backend/provider, platform, and architecture compatibility;
- conflicts and incompatible selections;
- checksums and source validation;
- download size and installed size;
- machine-readable installed state;
- install, add, remove, repair, verify, and refresh-status policy.

```text
COMPONENT_MANAGER_REQUIRED_FOR_2_4=yes
COMPONENT_MANAGER_MINIMUM_SCOPE_INCLUDES=hardware_detection,flow_selection,install_plan,install,add,remove,repair,verify,refresh_status,installed_state,platform_specific_execution
REAPER_IS_CONTROL_SURFACE=yes
REAPER_IS_PACKAGE_MANAGER=no
ONLINE_SELECTIVE_INSTALL_REQUIRED=yes
```

REAPER may show status and available flows, start Setup, monitor progress,
refresh state, and present actionable failures. Heavy installation or runtime
replacement must execute outside the REAPER/Lua process.

### Platform-specific execution

- **Windows:** use an external Setup executable/component manager. It must
  account for UAC, Defender, file locking, and native-helper failures, and must
  perform complete runtime replacement outside REAPER. REAPER may start and
  monitor Setup.
- **macOS:** define separate Intel CPU and Apple Silicon MPS contracts, using a
  signed/notarized helper or `.pkg`. Account for Gatekeeper, quarantine, and
  architecture. Heavy mutations execute outside REAPER.
- **Linux:** use a user-space helper/bootstrap process, started and monitored
  from REAPER where appropriate. Detect CPU, ROCm, and CUDA; keep lifecycle
  operations transactional; do not perform heavy installation in Lua.

```text
WINDOWS_EXTERNAL_COMPONENT_MANAGER_REQUIRED=yes
MACOS_INTEL_AND_SILICON_EXECUTION_EXPLICIT=yes
LINUX_HELPER_PROCESS_REQUIRED=yes
```

### Minimum 2.4 capabilities

1. Hardware and OS detection for Windows CPU/DirectML/CUDA, macOS Intel
   CPU/Apple Silicon MPS, and Linux CPU/ROCm/CUDA.
2. Selection of exactly the seven release flows.
3. An install plan listing runtimes, models, configs, providers, shared
   dependencies, download size, and installed size.
4. Install, Add, Remove, Repair, Verify, and Refresh status lifecycle actions.
5. Fail-closed safety: validate source before target, verify checksums, install
   transactionally, never silently fall back to another backend, never silently
   go online in offline mode, preserve referenced shared components, and use
   rollback or preserve-only behavior with consistent state and logs.
6. Online selective installation with on-demand components and deduplicated
   models/runtimes. Normal installers do not need to contain every model by
   default.

Advanced capabilities may remain later extensions, but these minimum
capabilities are P1 implementation gaps for 2.4 until implemented and accepted.

## Artifact scope

Required normal 2.4 artifact families:

1. Windows online installer
2. Windows bundled installer
3. macOS online `.pkg`
4. Linux online package family

Optional 2.4 artifact families:

1. macOS Apple Silicon bundled `.pkg`
2. Linux bundled package family

Offline runtime and offline/all-models artifact families are not an immediate
implementation requirement. They are also not definitively excluded from 2.4:
their final classification is a mandatory release-candidate decision gate.

Required and optional normal/bundled artifacts must carry the product code,
model download contracts, checksum/integrity contracts, and distribution rules
needed by all seven flows. Online/on-demand model acquisition is allowed where
that is the selected normal installer contract. One shared payload/reference
must serve every flow that uses the same model or runtime.

### Offline/all-models release-candidate review

The review occurs after all seven flows are implemented, the Component Manager
is functional, normal installers have been built, platform-smoke evidence is
available, and payload sizes and hosting constraints are known.

It must separately assess Windows CPU/DirectML/CUDA, macOS Intel CPU/Apple
Silicon MPS, and Linux CPU/ROCm/CUDA. Each variant receives exactly one final
classification:

- `REQUIRED_FOR_2_4`;
- `OPTIONAL_FOR_2_4`;
- `DEFERRED_AFTER_2_4`;
- `NOT_READY`;
- `UNSUPPORTED`.

The decision must consider payload closure, checksums, licenses, native smoke,
no-network installation, artifact size, external hosting availability,
reproducible inhouse builds, upload/download practicality, release-note links,
SHA256 publication, support load, and hardware coverage.

Normal and smaller artifacts continue to use GitHub Releases. Large offline or
all-models artifacts may be built inhouse, hosted externally, linked from the
GitHub release description, and accompanied by published SHA256 manifests.
GitHub chunking is not the default policy.

```text
OFFLINE_ALLMODELS_2_4_FINAL_DECISION=DEFERRED_UNTIL_RELEASE_CANDIDATE_REVIEW
OFFLINE_REVIEW_REQUIRED_BEFORE_RELEASE=yes
OFFLINE_IMPLEMENTATION_REQUIRED_NOW=no
OFFLINE_ARTIFACT_PUBLICATION_REQUIRED_NOW=no
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
11. Implement the cross-platform Component Manager minimum scope, shared
    registry, dependency graph, and installed-state contract.
12. Implement platform-specific helpers/frontends and flow selection with
    install, add, remove, repair, verify, and refresh-status lifecycle actions.
13. Add checksum-verified transactional materialization and shared-component
    protection.
14. Extend normal/bundled packaging for the seven-flow and Component Manager
    contracts.
15. Extend release gates to make all required models, flows, and component
    lifecycle contracts auditable.

The following P1 release revalidation remains after implementation:

1. Revalidate Windows current-main routes.
2. Revalidate macOS current-main routes.
3. Revalidate Linux CPU and CUDA current-main routes.
4. Validate every intended flow/backend combination independently.
5. Validate the Component Manager on every platform contract.
6. Run current-main native smokes and build selected candidate artifacts.

Implementing every offline/all-models artifact now, GitHub chunking, and one
identical universal frontend across all operating systems are not immediate
blockers. The per-platform offline/all-models decision remains a mandatory
final release gate.

## 2.4 implementation phases

The phases below order the required minimum work; they do not commit 2.4 to
advanced functionality beyond that minimum.

- **Phase A:** component registry and installed-state contract.
- **Phase B:** read-only detection and install plan.
- **Phase C:** Linux helper and component lifecycle.
- **Phase D:** Windows external Setup/component manager.
- **Phase E:** macOS Intel and Apple Silicon helper/package execution.
- **Phase F:** REAPER control-surface integration.
- **Phase G:** seven-flow component mapping.
- **Phase H:** cross-platform install/add/remove/repair/verify acceptance.
- **Phase I:** release-candidate offline/all-models review.

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
COMPONENT_MANAGER_REQUIRED_FOR_2_4=yes
ONLINE_SELECTIVE_INSTALL_REQUIRED=yes
REAPER_IS_CONTROL_SURFACE=yes
REAPER_IS_PACKAGE_MANAGER=no
WINDOWS_EXTERNAL_COMPONENT_MANAGER_REQUIRED=yes
MACOS_INTEL_AND_SILICON_EXECUTION_EXPLICIT=yes
LINUX_HELPER_PROCESS_REQUIRED=yes
OFFLINE_REVIEW_REQUIRED_BEFORE_RELEASE=yes
OFFLINE_IMPLEMENTATION_REQUIRED_NOW=no
OFFLINE_ARTIFACT_PUBLICATION_REQUIRED_NOW=no
OFFLINE_ALLMODELS_2_4_FINAL_DECISION=DEFERRED_UNTIL_RELEASE_CANDIDATE_REVIEW
```
