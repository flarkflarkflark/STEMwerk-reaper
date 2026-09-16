"""Regression test for the DrumSep output-normalization policy.

A controlled experiment (STEMwerk issue #118 DrumSep quality follow-up,
performed after the UVR-equivalent MDXC reconstruction fix in commit
9fd824e) proved that audio-separator's own default
``normalization_threshold`` of 0.9 pre-attenuates any input mix already at
or near full scale (this repo's canonical test source peaks at 0.999969)
before MDXC inference ever sees it, unnecessarily discarding ~10-12% of
headroom on realistic, already-mastered sources. Raising it to 1.0 leaves
such sources unscaled while retaining audio-separator's existing
downscale-if-over-full-scale safety behavior (no observed clipping; max
observed stem peak ~0.98 across all six DrumSep stems).

This is a separate, deliberate loudness/headroom policy decision -- not a
re-litigation of the Snare reconstruction fix, which this test does not
touch.
"""

import importlib.util
import sys
import types
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
DRUMSEP_HELPER = ROOT / "scripts" / "reaper" / "_internal" / "stemwerk_drumsep_process.py"


def _load_helper():
    spec = importlib.util.spec_from_file_location("stemwerk_drumsep_process_normalization_test", DRUMSEP_HELPER)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


class _AbortAfterCapture(RuntimeError):
    pass


def _install_fake_audio_separator(captured_kwargs, monkeypatch):
    class FakeSeparator:
        def __init__(self, **kwargs):
            captured_kwargs.append(kwargs)
            raise _AbortAfterCapture("stop before real separation; kwargs already captured")

    fake_module = types.ModuleType("audio_separator.separator")
    fake_module.Separator = FakeSeparator
    fake_package = types.ModuleType("audio_separator")
    fake_package.separator = fake_module
    # monkeypatch.setitem (not a bare sys.modules[...] = ...) so this fake is
    # torn down after the test instead of leaking into later tests in the
    # same pytest session that import the real audio_separator.separator.
    monkeypatch.setitem(sys.modules, "audio_separator", fake_package)
    monkeypatch.setitem(sys.modules, "audio_separator.separator", fake_module)


def test_run_explicitly_passes_normalization_threshold_1_0_to_separator(tmp_path, monkeypatch):
    module = _load_helper()

    monkeypatch.setattr(
        module,
        "_resolve_managed_drumsep_checkpoint",
        lambda model_dir, requested_model: module.ManagedDrumSepResolution(
            "fake_model.ckpt", model_dir / "fake_model.ckpt", model_dir / "fake_model.yaml", "none"
        ),
    )
    monkeypatch.setattr(module, "_probe_gpu_device", lambda device: (True, "ok", {}))

    captured_kwargs: list[dict] = []
    _install_fake_audio_separator(captured_kwargs, monkeypatch)

    args = SimpleNamespace(
        input=str(tmp_path / "in.wav"),
        output_dir=str(tmp_path / "out"),
        model_dir=str(tmp_path / "models"),
        model="fake_model.ckpt",
        result_json=str(tmp_path / "result.json"),
        log_file="",
        route="wrapper",
        device="cuda",
        requested_device="",
        backend_runtime="",
    )

    module.run(args)

    assert len(captured_kwargs) == 1, "Separator must be constructed exactly once on this path"
    assert captured_kwargs[0].get("normalization_threshold") == 1.0


def test_uvr_equivalent_reconstruction_path_remains_wired_in(tmp_path, monkeypatch):
    # Guards against the normalization change accidentally being paired with
    # a regression that drops the already-proven (commit 9fd824e)
    # UVR-equivalent MDXC reconstruction call out of the main run() path.
    module = _load_helper()
    script = DRUMSEP_HELPER.read_text(encoding="utf-8")
    assert "raw_outputs = _run_uvr_equivalent_mdxc_separation(sep, input_path, output_dir)" in script
    assert hasattr(module, "_uvr_equivalent_mdxc_reconstruction")
    assert hasattr(module, "_run_uvr_equivalent_mdxc_separation")
