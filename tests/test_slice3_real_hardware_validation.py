"""Slice-3 real-hardware validation, formalized as a repeatable test.

Everything here is skipped, not failed, when the relevant hardware-facing
package or model file isn't available -- this file records what a real
managed STEMwerk runtime (or an isolated venv built to the same pins) can
prove on AMD Linux/ROCm and CPU, without ever claiming hardware PASS from a
mock, and without downloading any model weights itself. See
docs/research/LINUX_ROCM_MAIN_RUNTIME_SLICE3_STATUS_2026-09-07.md for the
one-off manual validation this test reproduces in repeatable form.
"""

from __future__ import annotations

import os
import sys
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

_MODEL_STEM_SETS = {
    "htdemucs": frozenset({"vocals", "drums", "bass", "other"}),
    "htdemucs_ft": frozenset({"vocals", "drums", "bass", "other"}),
    "htdemucs_6s": frozenset({"vocals", "drums", "bass", "other", "guitar", "piano"}),
}

# hdemucs_mmi is deliberately excluded here: confirmed not locally available
# on this machine (no hdemucs_mmi.yaml / 75fc33f5-1941ce65.th under the
# model cache, only a download-catalog entry for it) -- see
# test_hdemucs_mmi_local_availability_is_recorded below and the Slice-3
# status doc. Per instruction, this test suite does not download it.


def _is_rocm_torch() -> bool:
    try:
        hip = getattr(getattr(torch, "version", None), "hip", None)
    except Exception:
        hip = None
    return bool(hip) or "rocm" in str(getattr(torch, "__version__", "")).lower()


def _has_rocm_device() -> bool:
    return sys.platform.startswith("linux") and _is_rocm_torch() and torch.cuda.is_available()


def test_rocm_tensor_op_on_selected_device():
    if not _has_rocm_device():
        pytest.skip("not a ROCm-flavored torch with a visible device")
    device = torch.device("cuda:0")
    a = torch.randn(256, 256, device=device)
    b = torch.randn(256, 256, device=device)
    c = a @ b
    torch.cuda.synchronize()
    assert c.device.type == "cuda"
    assert tuple(c.shape) == (256, 256)


def _production_model_source_dir() -> Path:
    """Where to READ existing model files from. Never write here -- see
    _stage_model_copy below, which is what execution actually points at."""
    override = os.environ.get("AUDIO_SEPARATOR_MODEL_DIR")
    if override:
        return Path(override)
    return Path.home() / ".local" / "share" / "STEMwerk" / "models"


def _model_locally_available(source_dir: Path, model_name: str) -> bool:
    return (source_dir / f"{model_name}.yaml").exists()


def _referenced_model_hashes(yaml_path: Path) -> list[str]:
    """Minimal parse of the `models: ['hash', ...]` line these descriptor
    yamls use -- avoids depending on PyYAML being installed just to run
    this test, matching the file's own trivial format."""
    import re

    text = yaml_path.read_text(encoding="utf-8")
    match = re.search(r"models:\s*\[([^\]]*)\]", text)
    if not match:
        return []
    return [h.strip("'\" ") for h in match.group(1).split(",") if h.strip("'\" ")]


def _stage_model_copy(source_dir: Path, model_name: str, dest_dir: Path) -> Path:
    """Copies only the yaml + the .th weight file(s) it references into a
    pytest-owned scratch directory, and returns that directory. Execution
    is pointed at this copy, never at the real model cache: audio-separator
    writes/updates a download_checks.json into whatever AUDIO_SEPARATOR_MODEL_DIR
    is set to even when loading an already-local model (observed directly
    in this slice's manual validation), so pointing it at a live production
    cache would mutate that cache."""
    import shutil

    dest_dir.mkdir(parents=True, exist_ok=True)
    yaml_src = source_dir / f"{model_name}.yaml"
    shutil.copy2(yaml_src, dest_dir / yaml_src.name)
    for prefix in _referenced_model_hashes(yaml_src):
        matches = list(source_dir.glob(f"{prefix}*.th"))
        assert matches, f"{model_name}.yaml references {prefix!r} but no matching .th file exists in {source_dir}"
        shutil.copy2(matches[0], dest_dir / matches[0].name)
    return dest_dir


def _make_test_clip(path: Path) -> None:
    import numpy as np
    import soundfile as sf

    samples = np.random.default_rng(0).uniform(-0.1, 0.1, size=(44100 * 2, 2)).astype("float32")
    sf.write(str(path), samples, 44100)


def _run_real_separation(model_name: str, requested_device: str, source_dir: Path, tmp_path: Path):
    """Runs one real separation, chdir'd into a pytest-owned tmp_path so no
    output can land outside the scratch tree (audio-separator writes stem
    files relative to CWD, not the output_dir argument, unless the caller
    chdirs first -- this mirrors what production code does), and against a
    staged copy of the model files so nothing is ever written back into the
    real model cache."""
    from stemwerk_core.runtime_resolution import resolve_execution_plan
    from stemwerk_core.separator import StemSeparator
    import stemwerk_runtime_seam as seam

    plan = resolve_execution_plan(
        "normal_stems", model_name, requested_device,
        catalog_dir=CATALOG_DIR, probe=seam.build_normal_stems_capability_probe(),
    )

    staged_model_dir = _stage_model_copy(source_dir, model_name, tmp_path / "models")

    input_path = tmp_path / f"input_{model_name}.wav"
    _make_test_clip(input_path)

    output_dir = tmp_path / f"out_{model_name}"
    output_dir.mkdir()
    cwd = os.getcwd()
    prior_model_dir = os.environ.get("AUDIO_SEPARATOR_MODEL_DIR")
    prior_weights_only = os.environ.get("TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD")
    os.environ["AUDIO_SEPARATOR_MODEL_DIR"] = str(staged_model_dir)
    os.environ["TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD"] = "1"
    os.chdir(output_dir)
    try:
        sep = StemSeparator(model=model_name, device=plan.resolved_device)
        result = sep.separate(input_path, str(output_dir))
    finally:
        os.chdir(cwd)
        _restore_env("AUDIO_SEPARATOR_MODEL_DIR", prior_model_dir)
        _restore_env("TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD", prior_weights_only)

    return plan, result


def _restore_env(name: str, prior_value) -> None:
    if prior_value is None:
        os.environ.pop(name, None)
    else:
        os.environ[name] = prior_value


def test_real_cpu_separation_htdemucs(tmp_path):
    """Mandatory real CPU validation: htdemucs, explicit device="cpu"."""
    pytest.importorskip("audio_separator")

    source_dir = _production_model_source_dir()
    if not _model_locally_available(source_dir, "htdemucs"):
        pytest.skip(f"no local htdemucs model cache at {source_dir}; not downloading one")

    plan, result = _run_real_separation("htdemucs", "cpu", source_dir, tmp_path)

    assert plan.requested_device == "cpu"
    assert plan.resolved_backend == "cpu"
    assert plan.resolved_device == "cpu"
    assert result.device_used == "cpu"
    assert result.device_used not in ("cuda:0", "rocm", "mps", "directml")
    assert set(result.stems) == _MODEL_STEM_SETS["htdemucs"]
    for name, path in result.stems.items():
        full = Path(path)
        full = full if full.is_absolute() else (tmp_path / f"out_htdemucs" / path)
        assert full.exists() and full.stat().st_size > 0


@pytest.mark.parametrize("model_name", sorted(_MODEL_STEM_SETS))
def test_real_rocm_separation_matches_contract_plan(model_name, tmp_path):
    pytest.importorskip("audio_separator")
    if not _has_rocm_device():
        pytest.skip("not a ROCm-flavored torch with a visible device")

    source_dir = _production_model_source_dir()
    if not _model_locally_available(source_dir, model_name):
        pytest.skip(f"no local {model_name} model cache at {source_dir}; not downloading one")

    plan, result = _run_real_separation(model_name, "auto", source_dir, tmp_path)

    assert plan.resolved_backend == "rocm"
    assert plan.resolved_device == "cuda:0"
    assert result.device_used == plan.resolved_device
    assert set(result.stems) == _MODEL_STEM_SETS[model_name]


def test_hdemucs_mmi_local_availability_is_recorded():
    """hdemucs_mmi: confirmed NOT locally available on this machine (no
    hdemucs_mmi.yaml, no 75fc33f5-1941ce65.th under the model cache -- only
    a download-catalog entry naming that single hybrid_transformer-family
    checkpoint). Per instruction this suite must not download it to close
    this gap; the Slice-2 catalog entry (role: internal, 4-stem) stays
    unchanged. This test documents that absence as a repeatable, checkable
    fact rather than only prose in a doc, and will start actually
    exercising the model (replacing the skip) the day it becomes locally
    available without anyone needing to remember to write this test then.
    """
    source_dir = _production_model_source_dir()
    if _model_locally_available(source_dir, "hdemucs_mmi"):
        pytest.skip(
            "hdemucs_mmi is now locally available -- this test should be "
            "extended into a real separation + stem-set assertion like the "
            "other models, and the finding fed back into the Slice-2 catalog."
        )
    assert not (source_dir / "hdemucs_mmi.yaml").exists()


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
