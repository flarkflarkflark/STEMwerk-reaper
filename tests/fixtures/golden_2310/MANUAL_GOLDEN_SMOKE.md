# STEMwerk 2.3.1.0 manual golden smoke

Status: **TESTED on Linux 2026-08-24** against Slice 0 commit
`8670921b00095758773195fc97b4a8fd80607b73`.

The smoke characterized the unmodified public `2.3.1.0` behavior from commit
`c7c812633c0a82dd36e9f829eeb6845e989e47a6` using this protocol:

1. Start with a disposable REAPER project and one deterministic, selected audio item on a named track. Record the project, track, item, and active-take names; do not record live pointer values.
2. Select Normal Stems, Fast (`htdemucs`), Auto device, all four standard stems, New Tracks, Per Item, no folder, and keep the source unchanged.
3. Run separation with `STEMWERK_PROCESSING_MAY_DOWNLOAD=no`. Record physical network isolation separately; do not describe the run as fully offline without independent network-level evidence.
4. Record requested and worker-reported actual model/device evidence separately. Confirm success evidence uses stdout/stderr, exit code, and `done.txt` rather than an inferred UI state.
5. Confirm exactly Vocals, Drums, Bass, Other are imported in that order; verify filenames and the source-track/source-item/stem naming pattern. Confirm no folder is created and the source stays unchanged.
6. Repeat from a fresh disposable project with In-place selected and post-processing set to None. Confirm one replacement item contains the ordered takes `Take 1/4: Item - Vocals`, `Take 2/4: Item - Drums`, `Take 3/4: Item - Bass`, and `Take 4/4: Item - Other`, and no new stem tracks are created.
7. During each run, switch to another project tab and then close the origin tab in a separate repeat. Confirm imports target the captured origin while it remains open and fail closed after it closes; never serialize or compare a project pointer by text.
8. Compare observations with the two normalized JSON fixtures. Record platform, REAPER version, resolved runtime device, deviations, and evidence paths outside the repository.

## Recorded Linux evidence

- Platform: EndeavourOS, Linux kernel 6.18.45; REAPER 7.78; STEMwerk 2.3.1.0.
- Run 1, Normal Stems / New Tracks: **PASS**.
- Run 2, Normal Stems / In-place: product **PASS**; corrected golden **PASS**.
- Run 3, origin project closed before import: **PASS**, fail-closed.
- Runtime: `htdemucs`; requested device `auto`; resolved device `cuda:0` via ROCm; `runtime_selected=rocm`; `backend_runtime=rocm`; AMD Radeon RX 9070.
- `PROCESSING_MAY_DOWNLOAD=no`: **PASS** as application-policy evidence.
- Physical network isolation: **NOT TESTED**. These runs are not claimed to have been fully offline.
- Run 3 used the source-exact plural wording: “Processing completed successfully, but the REAPER project that requested it is no longer available. Stems were not imported. Outputs remain available at:”. No serialized REAPER project pointer was shown.

The static word `Item` in the in-place take names records observed legacy 2.3.1.0 behavior only. The legacy source removes the source item before looking up its name, so the lookup falls back to `Item`. This is neither desired 2.4 naming nor a documented intentional product choice.

## Evidence bundles

| Run | Bundle | Size | SHA-256 |
|---|---|---:|---|
| 1 | `STEMwerk-support-bundle-20260824-195503.zip` | 312623 bytes | `6d9ce598654a81abfabe83ea52ee76acf320acc0dc3551884ee7449a5bdbeac2` |
| 2 | `STEMwerk-support-bundle-20260824-200431.zip` | 295665 bytes | `7c11000aca2336072e930cef5202f56550c631450d1d525e6b8b26c17facd410` |
| 3 | `STEMwerk-support-bundle-20260824-202027.zip` | 290334 bytes | `5e8e1888d62744f31c973b954107bb1eaacc2359833ab8a3dd54a6c18c6c9f9f` |
