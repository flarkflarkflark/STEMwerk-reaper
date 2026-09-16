"""Regression tests for the UVR-equivalent MDX-C overlap-add reconstruction.

Forensic investigation (STEMwerk issue #118 DrumSep quality follow-up) proved
-- by holding checkpoint bytes, YAML config, device, and input audio all
identical between UVR 5.6.0 and audio-separator 0.34.1 -- that audio-separator's
own MDXC reconstruction (chunking via mix.unfold(), a non-contiguous strided
view, combined with an indexed range-add accumulation) diverges meaningfully
from UVR's own numerics specifically for the Snare stem of the Jarredou
MDX23C DrumSep model (correlation ~0.68 vs >0.99 for every other stem).
Reproducing UVR's own chunk-building (explicit contiguous slicing) together
with its sequential incremental overlap-add merge fixed this (correlation
>0.9997 for every stem including Snare; verified on real RTX 3060 hardware
against real UVR 5.6.0 output).

These tests guard the fix without requiring the real 437MB checkpoint or a
GPU: a source-shape test (this file is what actually shipped, not a
re-derivation) and a small synthetic-tensor accumulation-math test.
"""

import importlib.util
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[1]
DRUMSEP_HELPER = ROOT / "scripts" / "reaper" / "_internal" / "stemwerk_drumsep_process.py"


def _load_helper():
    spec = importlib.util.spec_from_file_location("stemwerk_drumsep_process_uvr_recon_test", DRUMSEP_HELPER)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def test_source_does_not_use_unfold_for_mdxc_chunk_building():
    # mix.unfold() returns a non-contiguous strided view that was the proven
    # cause (together with the accumulation order) of the Snare divergence
    # from UVR. This guards against silently reintroducing it in the
    # UVR-equivalent reconstruction path specifically.
    script = DRUMSEP_HELPER.read_text(encoding="utf-8")
    start = script.index("def _uvr_equivalent_mdxc_reconstruction(")
    end = script.index("\ndef _run_uvr_equivalent_mdxc_separation(")
    func_text = script[start:end]
    # Skip the docstring (which explains the proven-buggy unfold() approach
    # in prose) and only scan the executable code below it for the literal
    # call pattern that must never reappear.
    docstring_end = func_text.index('"""', func_text.index('"""') + 3) + 3
    body = func_text[docstring_end:]
    assert "unfold(" not in body
    assert "while pos + chunk_size <= mix.shape[1]:" in body
    assert "torch.stack(chunk_list)" in body
    # The corrected accumulation: sequential incremental merge, not an
    # indexed range-add into a pre-sized buffer.
    assert "accumulator[..., -overlap_width:] + individual_output_cpu[..., :overlap_width]" in body
    assert "torch.cat([accumulator[..., :-overlap_width], merged_head, fresh_tail], -1)" in body


def test_run_uvr_equivalent_mdxc_separation_guards_return_none_for_unsupported_models():
    module = _load_helper()

    def make_separator(*, is_roformer=False, pitch_shift=0, target_instrument="", instruments=("Kick", "Snare")):
        concrete = SimpleNamespace(
            is_roformer=is_roformer,
            pitch_shift=pitch_shift,
            model_data_cfgdict=SimpleNamespace(
                training=SimpleNamespace(target_instrument=target_instrument, instruments=list(instruments))
            ),
        )
        return SimpleNamespace(model_instance=concrete)

    # Roformer models are not used by DrumSep and must fall back to the
    # stock audio-separator path unchanged.
    assert module._run_uvr_equivalent_mdxc_separation(make_separator(is_roformer=True), Path("x.wav"), Path(".")) is None

    # A model with a single target_instrument (primary/secondary style) is
    # not the 6-instrument multi-target shape this fix targets.
    assert (
        module._run_uvr_equivalent_mdxc_separation(
            make_separator(target_instrument="Vocals", instruments=("Vocals", "Instrumental")), Path("x.wav"), Path(".")
        )
        is None
    )

    # A 2-stem (or fewer) instrument list is the primary/secondary shape,
    # not the multi-target shape this fix targets.
    assert (
        module._run_uvr_equivalent_mdxc_separation(
            make_separator(instruments=("Kick", "Snare")), Path("x.wav"), Path(".")
        )
        is None
    )

    # A pitch-shifted model is out of scope for this fix (evidence-derived
    # guard shared with the CUDA-specific investigation: this reconstruction
    # was only proven against pitch_shift == 0).
    assert (
        module._run_uvr_equivalent_mdxc_separation(
            make_separator(pitch_shift=1, instruments=module.DIRECT_DEMIX_KEYS), Path("x.wav"), Path(".")
        )
        is None
    )

    # Any instrument set other than the exact six-target DrumSep contract,
    # in its exact order, must not be routed through this reconstruction --
    # even if it happens to have more than two instruments.
    assert (
        module._run_uvr_equivalent_mdxc_separation(
            make_separator(instruments=("Snare", "Kick", "Toms", "Hh", "Ride", "Crash")), Path("x.wav"), Path(".")
        )
        is None
    )

    # No model_instance yet (load_model() not called) must not raise.
    assert module._run_uvr_equivalent_mdxc_separation(SimpleNamespace(model_instance=None), Path("x.wav"), Path(".")) is None


def test_run_uvr_equivalent_mdxc_separation_is_never_conditioned_on_device():
    # This helper script is exclusively the DrumSep stage2 process (see its
    # module docstring); the "wrapper" route it implements has no device
    # parameter of its own. A CUDA-only build of this same reconstruction
    # (hotfix/2.3.1.2-windows-blackwell@631fb808) proved that gating the
    # fix on device=="cuda" silently disables it on ROCm, regressing DrumSep
    # quality back to the pre-fix, corrupted-Snare-stem stock reconstruction.
    # This guards against that regression class: the dispatch to this
    # function must never be wrapped in an args.device check.
    script = DRUMSEP_HELPER.read_text(encoding="utf-8")
    call_site = script.index("raw_outputs = _run_uvr_equivalent_mdxc_separation(")
    enclosing_else = script.rindex("\n        else:\n", 0, call_site)
    between_else_and_call = script[enclosing_else:call_site]
    assert "args.device" not in between_else_and_call


def test_six_target_reconstruction_matches_known_good_and_preserves_order_regardless_of_device():
    torch = pytest.importorskip("torch")
    module = _load_helper()

    class FakeModelRun:
        num_target_instruments = len(module.DIRECT_DEMIX_KEYS)

        def __call__(self, batch):
            outputs = torch.zeros(batch.shape[0], len(module.DIRECT_DEMIX_KEYS), *batch.shape[1:], dtype=batch.dtype)
            for target_index in range(len(module.DIRECT_DEMIX_KEYS)):
                outputs[:, target_index] = batch * (target_index + 1)
            return outputs

    concrete = SimpleNamespace(
        model_run=FakeModelRun(),
        override_model_segment_size=False,
        model_data_cfgdict=SimpleNamespace(
            inference=SimpleNamespace(dim_t=5),
            audio=SimpleNamespace(hop_length=4),
            training=SimpleNamespace(target_instrument="", instruments=list(module.DIRECT_DEMIX_KEYS)),
        ),
        overlap=4,
        batch_size=2,
        torch_device=torch.device("cpu"),
        is_roformer=False,
        pitch_shift=0,
    )
    left = torch.arange(37, dtype=torch.float32) / 4
    right = -(torch.arange(37, dtype=torch.float32) + 1) / 8
    mix = torch.stack([left, right])

    actual = module._uvr_equivalent_mdxc_reconstruction(concrete, mix)

    import numpy as np

    assert tuple(actual) == module.DIRECT_DEMIX_KEYS
    for target_index, name in enumerate(module.DIRECT_DEMIX_KEYS):
        np.testing.assert_array_equal(actual[name], mix.numpy() * (target_index + 1))


def test_snare_one_hot_cannot_leak_into_any_other_target():
    torch = pytest.importorskip("torch")
    module = _load_helper()

    class FakeModelRun:
        num_target_instruments = len(module.DIRECT_DEMIX_KEYS)

        def __call__(self, batch):
            outputs = torch.zeros(batch.shape[0], len(module.DIRECT_DEMIX_KEYS), *batch.shape[1:], dtype=batch.dtype)
            outputs[:, 1] = batch * 2 + 20  # Snare is index 1 in DIRECT_DEMIX_KEYS
            return outputs

    concrete = SimpleNamespace(
        model_run=FakeModelRun(),
        override_model_segment_size=False,
        model_data_cfgdict=SimpleNamespace(
            inference=SimpleNamespace(dim_t=5),
            audio=SimpleNamespace(hop_length=4),
            training=SimpleNamespace(target_instrument="", instruments=list(module.DIRECT_DEMIX_KEYS)),
        ),
        overlap=4,
        batch_size=2,
        torch_device=torch.device("cpu"),
    )
    left = torch.arange(37, dtype=torch.float32) / 4
    right = -(torch.arange(37, dtype=torch.float32) + 1) / 8
    mix = torch.stack([left, right])

    actual = module._uvr_equivalent_mdxc_reconstruction(concrete, mix)

    import numpy as np

    np.testing.assert_array_equal(actual["Snare"], mix.numpy() * 2 + 20)
    for name in ("Kick", "Toms", "Hh", "Ride", "Crash"):
        np.testing.assert_array_equal(actual[name], np.zeros((2, 37), dtype=np.float32))


def test_uvr_equivalent_mdxc_reconstruction_accumulates_each_position_exactly_overlap_times():
    torch = pytest.importorskip("torch")
    module = _load_helper()

    # Tiny synthetic scenario: hop_size=2, overlap(N)=2 -> chunk_size=4.
    # A trivial "model" that returns a constant-valued tensor per chunk lets
    # us hand-verify the expected accumulated result: every interior sample
    # should be summed from exactly N=2 overlapping chunk outputs, then
    # divided by N, i.e. the constant value C should come back out as C
    # (not 2*C or C/2), proving the accumulation loop's bookkeeping (not
    # just its floating-point behavior) is correct.
    hop_length = 2
    dim_t = 3  # chunk_size = hop_length * (dim_t - 1) = 4
    overlap = 2
    # Multi-stem (>2), matching the actual constraint
    # _run_uvr_equivalent_mdxc_separation enforces before this function is
    # ever reached in production (DrumSep always has 6 instruments) -- a
    # single-instrument model takes a structurally different branch in the
    # original audio-separator code this was adapted from and is out of
    # scope for this fix.
    instruments = ["StemA", "StemB", "StemC"]

    class FakeModelRun:
        num_target_instruments = len(instruments)

        def __call__(self, batch):
            # batch shape: (batch_len, 2, chunk_size) -> return constant 5.0
            return torch.full((batch.shape[0], len(instruments), 2, batch.shape[-1]), 5.0, dtype=torch.float32)

    concrete = SimpleNamespace(
        model_run=FakeModelRun(),
        override_model_segment_size=False,
        model_data_cfgdict=SimpleNamespace(
            inference=SimpleNamespace(dim_t=dim_t),
            audio=SimpleNamespace(hop_length=hop_length),
            training=SimpleNamespace(instruments=instruments),
        ),
        overlap=overlap,
        batch_size=1,
        torch_device=torch.device("cpu"),
    )

    mix = torch.zeros(2, 10, dtype=torch.float32)
    sources = module._uvr_equivalent_mdxc_reconstruction(concrete, mix)

    assert set(sources.keys()) == set(instruments)
    import numpy as np

    for name in instruments:
        result = sources[name]
        # A constant-output "model" summed over exactly `overlap`
        # contributions and divided by `overlap` must reproduce the same
        # constant exactly, everywhere except any residual edge artifacts
        # from padding trim.
        interior = result[..., 2:-2]
        assert interior.shape[-1] > 0
        assert np.allclose(interior, 5.0, atol=1e-5), f"{name}: accumulation math incorrect"
