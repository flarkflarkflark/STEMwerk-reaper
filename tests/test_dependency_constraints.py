"""
STEMwerk — dependency constraints regression tests.

Target branch: ci/macos-apple-silicon-backend-smoke (post-v2.2.2.1)

These tests guard against the torch >=2.6 weights_only regression that broke
Demucs model loading on user systems (reported by Jon Tidey, Mac Studio,
2026-05-01). They run in CI on every push and locally via pytest.

DESIGN NOTES — what is hard-asserted vs informational
=====================================================
Hard assertions (will fail the build):
  - platform.machine() == "arm64"   (only when running on Darwin)
  - torch <2.6
  - torch >=2.1
  - torchaudio matches torch's major.minor
  - audio-separator == 0.23.0
  - torch wheel was built with MPS support  (is_built() — a wheel property)

Informational only (printed, never asserted):
  - torch.backends.mps.is_available()
    Why: GitHub-hosted macOS arm64 runners use Apple Virtualization Framework,
    which may not expose Metal Performance Shaders even though the underlying
    chip is M1. Asserting this on hosted CI causes false-red builds.
  - stemwerk_core.select_device("auto") result
    Why: same reason — on hosted CI the device may legitimately be "cpu"
    instead of "mps", and that is not a regression.

The strict MPS-runtime tests are reserved for a future self-hosted real Mac
workflow where Metal access is guaranteed.

DO NOT relax the hard constraints without:
  1. Verifying audio-separator's downstream torch.load() calls handle the
     PyTorch 2.6+ weights_only=True default correctly, and
  2. Running a full Mac/Windows/Linux separation smoke test, not just imports.
"""

import os
import platform
from importlib.metadata import PackageNotFoundError, version

import pytest


def _parse_version(v):
    """Stdlib-only semver parse — strips local version (e.g. '+cpu')."""
    base = v.split("+")[0]
    parts = base.split(".")
    return tuple(int(p) for p in parts[:3])


def _on_github_hosted_ci():
    return os.environ.get("GITHUB_ACTIONS") == "true"


def _on_apple_silicon():
    return platform.system() == "Darwin" and platform.machine() == "arm64"


# ── HARD: platform sanity ────────────────────────────────────────────────────

def test_arm64_when_on_darwin():
    """On macOS, the runner must be arm64. x86_64 macOS is out of scope for
    the Apple Silicon backend smoke."""
    if platform.system() != "Darwin":
        pytest.skip("Not on macOS")
    assert platform.machine() == "arm64", (
        f"Expected arm64 macOS runner, got {platform.machine()!r}. "
        f"GitHub may have shifted the macos-14 label — check runner image docs."
    )


# ── HARD: torch ──────────────────────────────────────────────────────────────

def test_torch_below_2_6():
    """torch must be <2.6 for STEMwerk v2.2.2.1.

    PyTorch 2.6 flipped torch.load(weights_only) default to True, which
    breaks audio-separator 0.23.0's Demucs htdemucs checkpoint loading
    with: _pickle.UnpicklingError: Weights only load failed.
    """
    import torch
    v = _parse_version(torch.__version__)
    assert v < (2, 6, 0), (
        f"\n\n"
        f"  ╳ REGRESSION: torch {torch.__version__} is >=2.6\n\n"
        f"  STEMwerk requires torch <2.6 because PyTorch 2.6 sets\n"
        f"  torch.load(weights_only=True) by default, which fails on the\n"
        f"  Demucs htdemucs.yaml checkpoints used by audio-separator 0.23.0.\n\n"
        f"  Fix: pin torch==2.5.1 in the installer/bootstrap.\n"
    )


def test_torch_minimum_version():
    """torch must be at least 2.1 for stable MPS support."""
    import torch
    v = _parse_version(torch.__version__)
    assert v >= (2, 1, 0), (
        f"torch {torch.__version__} is too old; need >=2.1 for stable MPS"
    )


def test_torch_exactly_2_5_1():
    """For v2.2.2.1, the pinned version is exactly 2.5.1.
    Looser bounds (<2.6) are covered by test_torch_below_2_6; this one
    catches drift away from the chosen pin."""
    import torch
    v = _parse_version(torch.__version__)
    assert v == (2, 5, 1), (
        f"torch {torch.__version__} drifted from the v2.2.2.1 pin (2.5.1)"
    )


# ── HARD: torchaudio ─────────────────────────────────────────────────────────

def test_torchaudio_matches_torch_minor():
    """torchaudio must track torch's major.minor — ABI mismatches cause
    silent crashes on model load."""
    import torch
    import torchaudio
    torch_v = _parse_version(torch.__version__)
    audio_v = _parse_version(torchaudio.__version__)
    assert torch_v[:2] == audio_v[:2], (
        f"torch {torch.__version__} and torchaudio {torchaudio.__version__} "
        f"major.minor mismatch — pin both to 2.5.1."
    )


def test_torchaudio_exactly_2_5_1():
    """For v2.2.2.1, torchaudio is pinned to 2.5.1."""
    import torchaudio
    v = _parse_version(torchaudio.__version__)
    assert v == (2, 5, 1), (
        f"torchaudio {torchaudio.__version__} drifted from the v2.2.2.1 pin (2.5.1)"
    )


# ── HARD: audio-separator ────────────────────────────────────────────────────

def test_audio_separator_pinned_at_0_23_0():
    """audio-separator must be exactly 0.23.0 for v2.2.2.1.

    Newer audio-separator releases change Demucs routing, model file paths,
    and output naming. Upgrading is a v2.2.3-dev investigation, not a hotfix.
    """
    try:
        v = version("audio-separator")
    except PackageNotFoundError:
        pytest.fail("audio-separator is not installed")
    assert v == "0.23.0", (
        f"\n\n"
        f"  ╳ REGRESSION: audio-separator {v} is not the v2.2.2.1 pinned version.\n\n"
        f"  Expected: 0.23.0\n"
        f"  Upgrades require full Mac/Windows/Linux separation smoke tests,\n"
        f"  not just imports. Move to v2.2.3-dev branch for that work.\n"
    )


def test_audio_separator_imports():
    """audio-separator must be importable, not just installed metadata-wise."""
    import audio_separator  # noqa: F401


# ── HARD: stemwerk-core ──────────────────────────────────────────────────────

def test_stemwerk_core_imports():
    """stemwerk_core must be installable and importable."""
    import stemwerk_core  # noqa: F401


# ── HARD: onnxruntime ────────────────────────────────────────────────────────

def test_onnxruntime_imports():
    """Either onnxruntime-silicon or standard onnxruntime must be importable.
    The bootstrap installs silicon first with a fallback to standard."""
    import onnxruntime  # noqa: F401


# ── HARD: torch wheel was built with MPS ─────────────────────────────────────

def test_torch_wheel_was_built_with_mps():
    """torch.backends.mps.is_built() is a property of the wheel itself.
    The official Apple Silicon torch wheel must always have this True.
    If it's False on arm64 macOS, the wrong wheel was installed."""
    if not _on_apple_silicon():
        pytest.skip("Not on Apple Silicon")
    import torch
    assert torch.backends.mps.is_built(), (
        "torch wheel was not built with MPS support — wrong wheel installed?"
    )


# ── INFORMATIONAL: MPS runtime availability ──────────────────────────────────

def test_mps_runtime_available_informational(capsys):
    """torch.backends.mps.is_available() depends on the runtime environment.

    On GitHub-hosted macOS arm64 runners, MPS may NOT be available because
    Apple Virtualization Framework does not always expose Metal Performance
    Shaders to the guest, even though the host chip is M1.

    This test PRINTS the result but does not assert. A self-hosted real Mac
    workflow should add a strict variant of this check.
    """
    import torch
    available = torch.backends.mps.is_available()
    print(f"\n[informational] torch.backends.mps.is_available() = {available}")
    if _on_github_hosted_ci() and not available:
        print("[informational] MPS unavailable on GitHub-hosted runner — expected, not a failure")


# ── INFORMATIONAL: STEMwerk's selected device ────────────────────────────────

def test_stemwerk_selected_device_informational(capsys):
    """stemwerk_core.select_device('auto') returns (device_id, device_name).
    May return ('mps', ...) on a real Mac and ('cpu', ...) on GitHub-hosted CI.
    This test prints the result without asserting — the strict MPS-required
    variant belongs in a self-hosted workflow."""
    from stemwerk_core import select_device

    device_id, device_name = select_device("auto")
    print(f"\n[informational] stemwerk_core select_device('auto') = "
          f"({device_id!r}, {device_name!r})")
    if _on_github_hosted_ci() and device_id != "mps":
        print(f"[informational] device_id={device_id!r} on GitHub-hosted runner — "
              f"likely cpu fallback, not a regression")
