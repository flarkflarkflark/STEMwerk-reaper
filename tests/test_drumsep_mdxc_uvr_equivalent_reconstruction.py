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

    def make_separator(*, is_roformer=False, target_instrument="", instruments=("Kick", "Snare")):
        concrete = SimpleNamespace(
            is_roformer=is_roformer,
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

    # No model_instance yet (load_model() not called) must not raise.
    assert module._run_uvr_equivalent_mdxc_separation(SimpleNamespace(model_instance=None), Path("x.wav"), Path(".")) is None


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
