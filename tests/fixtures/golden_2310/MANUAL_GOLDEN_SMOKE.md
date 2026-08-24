# STEMwerk 2.3.1.0 manual golden smoke

Status: **NOT TESTED** in Slice 0. Live REAPER execution is outside this authorization.

Run this later against the unmodified public `2.3.1.0` build at commit
`c7c812633c0a82dd36e9f829eeb6845e989e47a6`:

1. Start with a disposable REAPER project and one deterministic, selected audio item on a named track. Record the project, track, item, and active-take names; do not record live pointer values.
2. Select Normal Stems, Fast (`htdemucs`), Auto device, all four standard stems, New Tracks, Per Item, no folder, and keep the source unchanged.
3. Run separation with network access disabled. Confirm the worker receives the input/output positional arguments, `--model htdemucs`, `--device auto`, run/job identity environment, and `STEMWERK_PROCESSING_MAY_DOWNLOAD=no`.
4. Record requested and worker-reported actual model/device evidence separately. Confirm success evidence uses stdout/stderr, exit code, and `done.txt` rather than an inferred UI state.
5. Confirm exactly Vocals, Drums, Bass, Other are imported in that order; verify filenames and the source-track/source-item/stem naming pattern. Confirm no folder is created and the source stays unchanged.
6. Repeat from a fresh disposable project with In-place selected and post-processing set to None. Confirm one replacement item contains four ordered takes named `Take 1/4` through `Take 4/4` with Vocals, Drums, Bass, Other labels, and no new stem tracks are created.
7. During each run, switch to another project tab and then close the origin tab in a separate repeat. Confirm imports target the captured origin while it remains open and fail closed after it closes; never serialize or compare a project pointer by text.
8. Compare observations with the two normalized JSON fixtures. Record platform, REAPER version, resolved runtime device, deviations, and evidence paths outside the repository.
