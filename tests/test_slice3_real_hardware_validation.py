"""Slice-3 real-hardware validation, formalized as a repeatable test.

Everything here is skipped, not failed, when the relevant hardware-facing
package or model file isn't available -- this file records what a real
managed STEMwerk runtime (or an isolated venv built to the same pins) can
prove on AMD Linux/ROCm, without ever claiming hardware PASS from a mock.
See docs/research/LINUX_ROCM_MAIN_RUNTIME_SLICE3_STATUS_2026-09-07.md for
the one-off manual validation this test reproduces in repeatable form.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"
INTERNAL = ROOT / "scripts" / "reaper" / "_internal"
CATALOG_DIR = ROOT / "scripts" / "reaper" / "catalog"

for path in (CORE_SRC, INTERNAL):
    if str(path) not in sys.path:
        sys.path.insert(0, str(path))

torch = pytest.importorskip("torch")


def _is_rocm_torch() -> bool:
    try:
        hip = getattr(getattr(torch, "version", None), "hip", None)
    except Exception:
        hip = None
    return bool(hip) or "rocm" in str(getattr(torch, "__version__", "")).lower()


def test_rocm_tensor_op_on_selected_device():
    if not (sys.platform.startswith("linux") and _is_rocm_torch() and torch.cuda.is_available()):
        pytest.skip("not a ROCm-flavored torch with a visible device")
    device = torch.device("cuda:0")
    a = torch.randn(256, 256, device=device)
    b = torch.randn(256, 256, device=device)
    c = a @ b
    torch.cuda.synchronize()
    assert c.device.type == "cuda"
    assert tuple(c.shape) == (256, 256)


def _default_model_cache_dir() -> Path:
    override = os.environ.get("AUDIO_SEPARATOR_MODEL_DIR")
    if override:
        return Path(override)
    return Path.home() / ".local" / "share" / "STEMwerk" / "models"


def test_real_htdemucs_separation_matches_contract_plan(tmp_path):
    audio_separator = pytest.importorskip("audio_separator")  # noqa: F401
    if not (sys.platform.startswith("linux") and _is_rocm_torch() and torch.cuda.is_available()):
        pytest.skip("not a ROCm-flavored torch with a visible device")

    model_dir = _default_model_cache_dir()
    if not (model_dir / "htdemucs.yaml").exists():
        pytest.skip(f"no local htdemucs model cache at {model_dir}; not downloading one")

    from stemwerk_core.runtime_resolution import resolve_execution_plan
    from stemwerk_core.separator import StemSeparator
    import stemwerk_runtime_seam as seam

    plan = resolve_execution_plan(
        "normal_stems", "htdemucs", "auto",
        catalog_dir=CATALOG_DIR, probe=seam.build_normal_stems_capability_probe(),
    )

    os.environ.setdefault("AUDIO_SEPARATOR_MODEL_DIR", str(model_dir))
    os.environ.setdefault("TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD", "1")

    input_path = tmp_path / "input.wav"
    import numpy as np
    import soundfile as sf

    samples = np.random.default_rng(0).uniform(-0.1, 0.1, size=(44100 * 2, 2)).astype("float32")
    sf.write(str(input_path), samples, 44100)

    output_dir = tmp_path / "out"
    output_dir.mkdir()
    cwd = os.getcwd()
    os.chdir(output_dir)
    try:
        sep = StemSeparator(model="htdemucs", device=plan.resolved_device)
        result = sep.separate(input_path, str(output_dir))
    finally:
        os.chdir(cwd)

    assert result.device_used == plan.resolved_device
    assert set(result.stems) == {"vocals", "drums", "bass", "other"}


def _production_runtime_base() -> Path:
    return Path.home() / ".local" / "share" / "STEMwerk"


def test_real_drumsep_explicit_rocm_and_fail_closed_against_production_runtime():
    runtime_base = _production_runtime_base()
    if not (runtime_base / "state" / "drumsep_runtime_rocm.env").exists():
        pytest.skip(f"no bootstrapped DrumSep ROCm runtime at {runtime_base}")

    import stemwerk_runtime_seam as seam

    legacy = seam._load_legacy_module()

    python_path, kind, info = legacy._select_drumsep_runtime("rocm", runtime_base)
    assert python_path is not None
    assert kind == "rocm"
    assert info.get("selection_policy") == "gpu_prefer_rocm"

    python_path, reason, info = legacy._select_drumsep_runtime("cuda:0", runtime_base)
    assert python_path is None
    assert reason in ("missing", "broken")
    assert info.get("selection_policy") == "explicit_cuda"
