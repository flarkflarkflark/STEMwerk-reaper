"""
Phase L6: Demucs-compatible shift-averaging around the existing (unmodified)
demucs-onnx ONNX inference session -- no changes to demucs-onnx's own package code,
no changes to the ONNX graph/weights.

Exact algorithm, transcribed from the REAL production implementation (audio-separator's
vendored `uvr_lib_v5/demucs/apply.py`, function `apply_model`, the `if shifts:` branch,
lines ~202-214 -- read directly, not approximated) -- see README.md / DEMUCS_SHIFT_PARITY.md
"L6.1" for the full trace:

    max_shift = int(0.5 * samplerate)                    # 22050 samples @ 44.1kHz, a
                                                           # FIXED constant, not a range
    padded = zero-pad(mix, max_shift, max_shift)          # symmetric pad both sides
    out = 0
    for _ in range(shifts):
        offset = random.randint(0, max_shift)             # Python's global `random`,
                                                           # NOT seeded internally --
                                                           # genuinely stochastic unless
                                                           # the CALLER seeds it first
        seg_len = length + max_shift - offset
        shifted = padded[:, offset : offset + seg_len]
        shifted_out = <normal chunked/overlap-add inference>(shifted)   # shifts=0
        out += shifted_out[..., max_shift - offset :]     # crop back to `length`
    out /= shifts

Shift-averaging operates entirely ABOVE demucs-onnx's own fixed-343980-sample ONNX
graph -- it wraps `_chunked_separate_single` (demucs-onnx's own existing, unmodified,
arbitrary-length chunked overlap-add function), calling it once per shift on a
variable-length padded/offset input, exactly as production PyTorch's `apply_model`
recursively calls itself with `shifts=0` on each shifted window. No ONNX-specific
changes were needed for this reason.
"""
import random

import numpy as np

from demucs_onnx.inference import _chunked_separate_single, SAMPLE_RATE

MAX_SHIFT_SECONDS = 0.5


def apply_model_with_shifts(session, sources, mix, *, shifts=2, wanted=None,
                             verbose=False, progress=False):
    """
    Demucs-compatible shift-averaged inference on a single ONNX session.

    Args:
        session: an already-constructed `onnxruntime.InferenceSession` (CPU or WebGPU
            -- this function is provider-agnostic; the caller controls which backend
            by how they constructed `session`, exactly like demucs-onnx's own code).
        sources: the model's stem ordering, e.g. `("drums","bass","other","vocals")`
            -- same as `demucs_onnx._hub.MODEL_REGISTRY["htdemucs"].sources`.
        mix: `(channels=2, samples)` float32/float64 numpy array.
        shifts: 0 reproduces L5's baseline exactly (delegates straight to
            `_chunked_separate_single`, demucs-onnx's own unmodified function, with no
            wrapper overhead or behavior change whatsoever). >0 performs Demucs-
            compatible shift-averaging as transcribed above.
        wanted: optional subset of stems to compute (passed straight through).

    Returns:
        (stems_dict, offsets_used) -- `stems_dict` matches `_chunked_separate_single`'s
        own return shape/dtype exactly (`{stem: (2, samples) float32 array}`);
        `offsets_used` is the list of `shifts` random offsets actually drawn, returned
        for logging/reproducibility inspection (not needed to reproduce a run -- that
        requires re-seeding `random` identically, see `run_with_seed` below).

    Reproducibility: mirrors production exactly -- this function does NOT seed
    `random` itself. Call `random.seed(N)` immediately before invoking this function
    (with `shifts>0`) for a controlled/reproducible offset sequence, exactly as you
    would need to do to get reproducible offsets from the real
    `audio_separator...demucs.apply.apply_model` too (it has no internal seeding
    either -- confirmed by reading its source, not assumed).
    """
    if mix.ndim != 2 or mix.shape[0] != 2:
        raise ValueError(f"expected (channels=2, samples), got {mix.shape}")

    if shifts == 0:
        return (
            _chunked_separate_single(session, sources, mix, wanted=wanted,
                                      verbose=verbose, progress=progress),
            [],
        )

    channels, length = mix.shape
    max_shift = int(MAX_SHIFT_SECONDS * SAMPLE_RATE)
    if SAMPLE_RATE != 44100:
        raise AssertionError(
            f"demucs_onnx.inference.SAMPLE_RATE changed to {SAMPLE_RATE} since this "
            f"wrapper was written against 44100 -- max_shift depends on it, re-verify."
        )

    padded = np.pad(mix, ((0, 0), (max_shift, max_shift)), mode="constant")

    keep = list(wanted) if wanted else list(sources)
    accum = {s: np.zeros((channels, length), dtype=np.float64) for s in keep}
    offsets_used = []

    for i in range(shifts):
        offset = random.randint(0, max_shift)
        offsets_used.append(offset)
        seg_len = length + max_shift - offset
        shifted = padded[:, offset:offset + seg_len]

        shifted_out = _chunked_separate_single(
            session, sources, shifted, wanted=wanted,
            verbose=verbose, progress=progress,
        )

        crop_start = max_shift - offset
        for s in keep:
            cropped = shifted_out[s][:, crop_start:crop_start + length]
            if cropped.shape[1] != length:
                raise AssertionError(
                    f"shift {i}: cropped length {cropped.shape[1]} != expected {length} "
                    f"(offset={offset}, seg_len={seg_len}, crop_start={crop_start}) -- "
                    f"algorithm transcription error, do not silently proceed."
                )
            accum[s] += cropped.astype(np.float64)

    out = {s: (accum[s] / shifts).astype(np.float32) for s in keep}
    return out, offsets_used


def run_with_seed(session, sources, mix, *, shifts, seed, wanted=None,
                   verbose=False, progress=False):
    """Convenience: seed Python's global `random` immediately before the shift draws,
    for controlled cross-route comparison (see DEMUCS_SHIFT_PARITY.md L6.3). Seeding
    here rather than in the caller keeps the seed-then-call adjacency exact and
    avoids any other `random` usage sneaking in between seed and draw."""
    random.seed(seed)
    return apply_model_with_shifts(session, sources, mix, shifts=shifts,
                                    wanted=wanted, verbose=verbose, progress=progress)
