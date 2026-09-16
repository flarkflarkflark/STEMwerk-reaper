"""Regression test for the DrumSep amplification-threshold policy.

A controlled investigation (macOS M1 Kit Split low-energy stem audit,
2026-09-14) proved that audio-separator's own constructor default for
``amplification_threshold`` has drifted across versions -- 0.6 in 0.23.0
(the version bundled on macOS) versus 0.0 in 0.34.1 (bundled on
Windows/Linux) -- and that STEMwerk never pinned it, so naturally-quiet
DrumSep stems (Toms/Ride/Crash) were being force-amplified up to a ~0.6
peak on macOS only, while Windows/Linux left them at their natural level.

Passing ``amplification_threshold=0.0`` directly into ``Separator(...)``
is NOT a valid fix: 0.23.0's constructor explicitly rejects values <= 0
(``ValueError``), so a naive kwarg would crash macOS DrumSep entirely.

The proven, version-independent fix is a plain attribute write on the
constructed instance, after ``Separator()`` returns but before
``load_model()`` is called: ``load_model()`` reads the *current* value of
``self.amplification_threshold`` (not a value frozen at ``__init__`` time)
into the ``common_config`` dict it hands to the concrete architecture
class, so the override reaches the architecture model's own
``amplification_threshold`` without ever going through ``__init__``'s
validation -- proven directly against real 0.23.0 (an end-to-end run with
the real Jarredou checkpoint showed the Toms/Ride/Crash ~0.6 floor
disappear) and by source parity against 0.34.1 (byte-identical
``load_model``/``CommonSeparator.__init__`` propagation mechanics).

This test simulates both the old (0.23.0-shaped) and modern
(0.34.1-shaped) constructor contracts with fake Separator classes and
proves the real helper code applies the override before load_model,
regardless of which contract is installed -- no version or platform
check involved.
"""

import importlib.util
import sys
import types
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
DRUMSEP_HELPER = ROOT / "scripts" / "reaper" / "_internal" / "stemwerk_drumsep_process.py"


def _load_helper():
    spec = importlib.util.spec_from_file_location("stemwerk_drumsep_process_amplification_test", DRUMSEP_HELPER)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


class _AbortAfterLoad(RuntimeError):
    pass


def _make_fake_separator_class(*, default_amplification_threshold, reject_non_positive_explicit):
    """Build a fake Separator class shaped like a given audio-separator contract.

    reject_non_positive_explicit=True mimics 0.23.0 (constructor raises if
    amplification_threshold<=0 is passed explicitly); False mimics 0.34.1
    (0.0 is a valid explicit constructor argument, and is in fact its
    default).
    """

    class FakeSeparator:
        def __init__(self, **kwargs):
            requested = kwargs.get("amplification_threshold", default_amplification_threshold)
            if reject_non_positive_explicit and requested <= 0:
                raise ValueError("The amplification_threshold must be greater than 0 and less than or equal to 1.")
            self.amplification_threshold = requested
            self.model_instance = None
            self._loaded_model_filename = None

        def load_model(self, model_filename):
            # Mirrors the real Separator.load_model(): reads the CURRENT
            # value of self.amplification_threshold (not a value captured
            # at __init__ time) into the object handed to the architecture
            # class.
            self._loaded_model_filename = model_filename
            self.model_instance = SimpleNamespace(amplification_threshold=self.amplification_threshold)
            raise _AbortAfterLoad("stop right after load_model; propagation already captured")

    return FakeSeparator


def _install_fake_audio_separator(fake_separator_class, monkeypatch):
    fake_module = types.ModuleType("audio_separator.separator")
    fake_module.Separator = fake_separator_class
    fake_package = types.ModuleType("audio_separator")
    fake_package.separator = fake_module
    # monkeypatch.setitem (not a bare sys.modules[...] = ...) so this fake is
    # torn down after the test instead of leaking into later tests in the
    # same pytest session that import the real audio_separator.separator.
    monkeypatch.setitem(sys.modules, "audio_separator", fake_package)
    monkeypatch.setitem(sys.modules, "audio_separator.separator", fake_module)


def _run_with_fake_separator(module, fake_separator_class, tmp_path, monkeypatch):
    monkeypatch.setattr(
        module,
        "_resolve_managed_drumsep_checkpoint",
        lambda model_dir, requested_model: module.ManagedDrumSepResolution(
            "fake_model.ckpt", model_dir / "fake_model.ckpt", model_dir / "fake_model.yaml", "none"
        ),
    )
    monkeypatch.setattr(module, "_probe_gpu_device", lambda device: (True, "ok", {}))
    _install_fake_audio_separator(fake_separator_class, monkeypatch)

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

    captured = {}
    real_separator_new = fake_separator_class.__new__

    def wrapped_new(cls, *a, **kw):
        instance = real_separator_new(cls)
        return instance

    try:
        module.run(args)
    except _AbortAfterLoad:
        pass

    return captured


def test_old_contract_amplification_forced_to_zero_before_load_model(tmp_path, monkeypatch):
    """0.23.0-shaped contract: default 0.6, explicit 0.0 kwarg would raise."""
    module = _load_helper()
    fake_cls = _make_fake_separator_class(default_amplification_threshold=0.6, reject_non_positive_explicit=True)

    sep_holder: list = []
    orig_apply = module._apply_drumsep_amplification_policy

    def spying_apply(separator):
        orig_apply(separator)
        sep_holder.append(separator)

    monkeypatch.setattr(module, "_apply_drumsep_amplification_policy", spying_apply)

    _run_with_fake_separator(module, fake_cls, tmp_path, monkeypatch)

    assert len(sep_holder) == 1, "amplification policy helper must be invoked exactly once"
    sep = sep_holder[0]
    assert sep.amplification_threshold == 0.0
    assert sep.model_instance is not None, "load_model must have run"
    assert sep.model_instance.amplification_threshold == 0.0, (
        "load_model must propagate the pre-load override into the architecture model"
    )


def test_modern_contract_amplification_stays_zero_before_load_model(tmp_path, monkeypatch):
    """0.34.1-shaped contract: default already 0.0; same code path must still hold."""
    module = _load_helper()
    fake_cls = _make_fake_separator_class(default_amplification_threshold=0.0, reject_non_positive_explicit=False)

    sep_holder: list = []
    orig_apply = module._apply_drumsep_amplification_policy

    def spying_apply(separator):
        orig_apply(separator)
        sep_holder.append(separator)

    monkeypatch.setattr(module, "_apply_drumsep_amplification_policy", spying_apply)

    _run_with_fake_separator(module, fake_cls, tmp_path, monkeypatch)

    assert len(sep_holder) == 1
    sep = sep_holder[0]
    assert sep.amplification_threshold == 0.0
    assert sep.model_instance is not None
    assert sep.model_instance.amplification_threshold == 0.0


def test_separator_kwargs_never_pass_amplification_threshold_explicitly(tmp_path, monkeypatch):
    """The fix must not pass amplification_threshold as a constructor kwarg
    (that would crash 0.23.0's constructor); it must only be set as a
    post-construction attribute write.
    """
    module = _load_helper()
    fake_cls = _make_fake_separator_class(default_amplification_threshold=0.6, reject_non_positive_explicit=True)

    captured_kwargs: list[dict] = []
    real_init = fake_cls.__init__

    def capturing_init(self, **kwargs):
        captured_kwargs.append(dict(kwargs))
        real_init(self, **kwargs)

    fake_cls.__init__ = capturing_init

    _run_with_fake_separator(module, fake_cls, tmp_path, monkeypatch)

    assert len(captured_kwargs) == 1
    assert "amplification_threshold" not in captured_kwargs[0]
