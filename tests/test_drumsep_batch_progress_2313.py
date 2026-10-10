"""DrumSep must report real inference progress, and that progress must stay
inside the band reserved for inference.

STEMwerk's UVR-equivalent MDXC reconstruction replaces audio-separator's own
tqdm-instrumented demix with a hand-rolled batch loop, so DrumSep emitted no
progress at all: live helper logs showed tqdm_lines=0 while normal separation
showed real samples. The caller's scraper therefore never found a percentage
and fell back to a synthetic 1%-per-10s ramp capped at 12, which is why Direct
Kit showed 0 -> 1 -> 2 -> 3 -> 95 and Kit Split stage 2 sat flat at 50%.

The loop iterable is now wrapped in tqdm -- iteration count, order and every
tensor operation are untouched. tqdm legitimately reports 100% when the loop
finishes, which means "inference done", NOT "job done": reconstruction and six
WAV writes still follow. The caller maps that 0..99 into 1..90 so that 95
remains "Writing drum tracks" and 100 remains genuine completion only.

The reconstruction is numerically sensitive (it exists to preserve UVR's Snare
correlation), so the central guard here is bit-exact output equivalence against
an uninstrumented reference implementation.
"""

from __future__ import annotations

import ast
import importlib.util
import io
import math
import re
import sys
import types
from contextlib import redirect_stderr
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "reaper" / "_internal" / "stemwerk_drumsep_process.py"
CALLER = ROOT / "scripts" / "reaper" / "audio_separator_process.py"
PROGRESS_LUA = ROOT / "scripts" / "reaper" / "_internal" / "STEMwerk_Progress_Render.lua"

torch = pytest.importorskip("torch", reason="torch required to exercise the reconstruction")
pytest.importorskip("tqdm", reason="tqdm required by the instrumented loop")


def _load_helper():
    spec = importlib.util.spec_from_file_location("stemwerk_drumsep_process_progress_test", HELPER)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


# --- deterministic stand-in for the real MDXC model --------------------------


class _FakeModelRun:
    """Shaped like concrete.model_run: returns one deterministic tensor per
    chunk in the batch, and records how it was called."""

    def __init__(self, num_stems: int, chunk_size: int):
        self.num_target_instruments = num_stems
        self.chunk_size = chunk_size
        self.calls: list[int] = []
        self.batches_seen: list[float] = []
        self.raise_on_call: int | None = None

    def __call__(self, batch):
        index = len(self.calls)
        self.calls.append(int(batch.shape[0]))
        # Order fingerprint: first sample of the first chunk in this batch.
        self.batches_seen.append(float(batch[0, 0, 0]))
        if self.raise_on_call is not None and index == self.raise_on_call:
            raise RuntimeError("synthetic model failure")
        out = []
        for offset in range(int(batch.shape[0])):
            seed = index * 100 + offset
            ramp = torch.arange(self.chunk_size, dtype=torch.float32) * 1e-4
            stems = torch.stack([torch.stack([ramp + seed, ramp - seed]) for _ in range(self.num_target_instruments)])
            out.append(stems)
        return torch.stack(out) if len(out) > 1 else out[0].unsqueeze(0)


class _Cfg(dict):
    __getattr__ = dict.get


def _make_concrete(num_stems: int = 6, batch_size: int = 1, overlap: int = 8, hop_length: int = 512, dim_t: int = 16):
    chunk_size = hop_length * (dim_t - 1)
    concrete = types.SimpleNamespace()
    concrete.model_run = _FakeModelRun(num_stems, chunk_size)
    concrete.override_model_segment_size = False
    concrete.segment_size = dim_t
    concrete.batch_size = batch_size
    concrete.overlap = overlap
    concrete.torch_device = torch.device("cpu")
    concrete.model_data_cfgdict = _Cfg(
        audio=_Cfg(hop_length=hop_length, sample_rate=44100),
        inference=_Cfg(dim_t=dim_t),
        training=_Cfg(instruments=[f"s{i}" for i in range(num_stems)]),
    )
    return concrete


def _mix(seconds: float = 0.6, sample_rate: int = 44100):
    total = int(seconds * sample_rate)
    base = torch.arange(total, dtype=torch.float32) * 1e-5
    return torch.stack([base, base * -1.0])


def _reference_reconstruction_source() -> str:
    """The committed function with the tqdm wrapper removed -- an uninstrumented
    reference built from the real source, not a hand-copied duplicate."""
    text = HELPER.read_text(encoding="utf-8")
    start = text.index("def _uvr_equivalent_mdxc_reconstruction(")
    end = text.index("\ndef _run_uvr_equivalent_mdxc_separation(", start)
    body = text[start:end]
    assert "for batch in tqdm(batches):" in body
    body = body.replace("for batch in tqdm(batches):", "for batch in batches:")
    body = body.replace("    from tqdm import tqdm\n", "")
    # Only executable references matter; the explanatory comment still says tqdm.
    executable = "\n".join(line for line in body.splitlines() if not line.lstrip().startswith("#"))
    assert "tqdm" not in executable
    return body.replace("_uvr_equivalent_mdxc_reconstruction", "_reference_reconstruction")


def _load_reference():
    module = types.ModuleType("uninstrumented_reference")
    exec(compile(_reference_reconstruction_source(), "<reference>", "exec"), module.__dict__)
    return module._reference_reconstruction


# --- A. iteration and output invariance --------------------------------------


@pytest.mark.parametrize("seconds, batch_size", [(0.20, 1), (0.60, 1), (0.60, 4), (1.20, 8)])
def test_output_is_bit_identical_to_the_uninstrumented_reference(seconds, batch_size):
    """The central guard: wrapping the iterable must not perturb the numerics
    this reconstruction exists to protect."""
    helper = _load_helper()
    reference = _load_reference()
    mix = _mix(seconds)

    with redirect_stderr(io.StringIO()):
        instrumented = helper._uvr_equivalent_mdxc_reconstruction(_make_concrete(batch_size=batch_size), mix.clone())
    expected = reference(_make_concrete(batch_size=batch_size), mix.clone())

    assert set(instrumented) == set(expected)
    for key in expected:
        assert instrumented[key].shape == expected[key].shape
        assert (instrumented[key] == expected[key]).all(), f"stem {key} diverged"


@pytest.mark.parametrize("seconds, batch_size", [(0.20, 1), (0.60, 1), (0.60, 4)])
def test_model_run_call_count_and_batch_order_are_unchanged(seconds, batch_size):
    helper = _load_helper()
    reference = _load_reference()
    instrumented_concrete = _make_concrete(batch_size=batch_size)
    reference_concrete = _make_concrete(batch_size=batch_size)

    with redirect_stderr(io.StringIO()):
        helper._uvr_equivalent_mdxc_reconstruction(instrumented_concrete, _mix(seconds))
    reference(reference_concrete, _mix(seconds))

    assert instrumented_concrete.model_run.calls == reference_concrete.model_run.calls
    assert instrumented_concrete.model_run.batches_seen == reference_concrete.model_run.batches_seen


def test_single_batch_case_is_safe():
    helper = _load_helper()
    concrete = _make_concrete(batch_size=64)
    with redirect_stderr(io.StringIO()) as err:
        result = helper._uvr_equivalent_mdxc_reconstruction(concrete, _mix(0.2))
    assert len(concrete.model_run.calls) == 1
    assert len(result) == 6
    assert "%|" in err.getvalue()


def test_exception_during_model_run_propagates_unchanged():
    helper = _load_helper()
    reference = _load_reference()

    instrumented_concrete = _make_concrete()
    instrumented_concrete.model_run.raise_on_call = 2
    with redirect_stderr(io.StringIO()), pytest.raises(RuntimeError, match="synthetic model failure"):
        helper._uvr_equivalent_mdxc_reconstruction(instrumented_concrete, _mix(0.6))

    reference_concrete = _make_concrete()
    reference_concrete.model_run.raise_on_call = 2
    with pytest.raises(RuntimeError, match="synthetic model failure"):
        reference(reference_concrete, _mix(0.6))

    assert instrumented_concrete.model_run.calls == reference_concrete.model_run.calls


def test_only_the_iterable_is_wrapped():
    """Structural guard: the loop body must be untouched and tqdm must appear
    exactly once, around `batches`."""
    source = HELPER.read_text(encoding="utf-8")
    assert source.count("tqdm(") == 1
    assert "for batch in tqdm(batches):" in source
    tree = ast.parse(source)
    func = next(
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.FunctionDef) and node.name == "_uvr_equivalent_mdxc_reconstruction"
    )
    loop = next(node for node in ast.walk(func) if isinstance(node, ast.For) and isinstance(node.iter, ast.Call))
    assert loop.iter.func.id == "tqdm"
    assert loop.iter.args[0].id == "batches"
    assert not loop.iter.keywords, "no tqdm options that could alter output volume/semantics"


# --- B. progress protocol -----------------------------------------------------


def _caller_namespace():
    """Exec just the two progress helpers out of the caller, without importing
    the whole processing module."""
    source = CALLER.read_text(encoding="utf-8")
    start = source.index("    def helper_inference_band_percent(raw_percent: int) -> int:")
    end = source.index("\n    def helper_file_signature(", start)
    namespace: dict = {}
    exec(compile(re.sub(r"^    ", "", source[start:end], flags=re.M), "<caller>", "exec"), namespace)
    return namespace


def _scrape(text: str):
    matches = list(re.finditer(r"(\d{1,3})%\|", text))
    if not matches:
        return None
    return max(0, min(99, int(matches[-1].group(1))))


def test_helper_emits_tqdm_progress_the_existing_scraper_recognizes():
    helper = _load_helper()
    buffer = io.StringIO()
    with redirect_stderr(buffer):
        helper._uvr_equivalent_mdxc_reconstruction(_make_concrete(), _mix(0.6))
    emitted = buffer.getvalue()
    assert "%|" in emitted, "no tqdm-format progress was produced"
    assert _scrape(emitted) is not None, "the existing helper_log_percent regex must recognize it"


def test_scraped_percentages_are_monotonic_and_bounded():
    helper = _load_helper()
    buffer = io.StringIO()
    with redirect_stderr(buffer):
        helper._uvr_equivalent_mdxc_reconstruction(_make_concrete(), _mix(1.2))
    values = [int(m.group(1)) for m in re.finditer(r"(\d{1,3})%\|", buffer.getvalue())]
    assert values == sorted(values), values
    assert all(0 <= v <= 100 for v in values)
    assert _scrape(buffer.getvalue()) <= 99, "the scraper clamps to 99 as before"


@pytest.mark.parametrize(
    "raw, expected", [(0, 1), (10, 9), (25, 23), (50, 45), (75, 68), (90, 81), (99, 90)]
)
def test_caller_mapping_matches_the_agreed_contract(raw, expected):
    assert _caller_namespace()["helper_inference_band_percent"](raw) == expected


def test_inference_completion_can_never_exceed_ninety():
    band = _caller_namespace()["helper_inference_band_percent"]
    values = [band(p) for p in range(0, 101)]
    assert max(values) == 90, "inference must not reach 95 (writing) or 100 (done)"
    assert min(values) >= 1
    assert values == sorted(values), "mapping must stay monotonic"


@pytest.mark.parametrize("raw", [-10, 0, 100, 999])
def test_caller_mapping_is_defensively_bounded(raw):
    assert 1 <= _caller_namespace()["helper_inference_band_percent"](raw) <= 90


def test_tqdm_hundred_percent_becomes_at_most_ninety_end_to_end():
    """Real tqdm DOES emit 100% when the loop finishes; prove that completion of
    inference cannot present itself as job completion."""
    helper = _load_helper()
    buffer = io.StringIO()
    with redirect_stderr(buffer):
        helper._uvr_equivalent_mdxc_reconstruction(_make_concrete(), _mix(0.6))
    emitted = buffer.getvalue()
    assert "100%|" in emitted, "tqdm is expected to report 100% for its own loop"
    band = _caller_namespace()["helper_inference_band_percent"]
    assert band(_scrape(emitted)) <= 90


def test_writing_and_completion_markers_are_untouched():
    source = CALLER.read_text(encoding="utf-8")
    assert source.count('PROGRESS:95:Writing drum tracks...') == 2, "writing still owns 95"
    assert "PROGRESS:100:" not in source, "nothing may claim 100 from the helper signal"


# --- C. synthetic fallback ----------------------------------------------------


def test_synthetic_ramp_is_unchanged_and_only_used_without_real_progress():
    source = CALLER.read_text(encoding="utf-8")
    assert "percent = min(12, 1 + elapsed // 10)" in source, "the fallback must stay as-is"
    block = source[source.index("observed_progress = helper_log_percent()") :][:400]
    assert "if observed_progress is None:" in block
    assert "percent = helper_inference_band_percent(observed_progress)" in block, (
        "real helper progress must be used as soon as it exists"
    )


def test_first_real_sample_below_the_ramp_cannot_move_visible_progress_backwards():
    """P1b's monotonic latch must absorb ramp(12) -> first real mapped sample."""
    band = _caller_namespace()["helper_inference_band_percent"]
    first_real = band(_scrape("  1%|# | 1/39"))
    assert first_real < 12, "precondition: the first real sample is below the ramp ceiling"
    latched = max(12, first_real)
    assert latched == 12, "P1b latches the previous value, so nothing regresses"


# --- D. P1b integration -------------------------------------------------------


def _normalize(raw: int, stage: str, workflow: str, previous: int) -> int:
    """Mirror of normalizeMultiTrackProgress for dks_extract/dks_direct, kept in
    step with the Lua by the source assertions below."""
    percent = max(0, min(99, raw))
    if workflow == "dks_extract":
        lower = stage.lower()
        if "stage 1" in lower or "extracting drums" in lower:
            percent = min(49, percent)
        elif any(token in lower for token in ("stage 2", "splitting drum kit", "writing drum tracks", "queued for drumsep")):
            if "splitting drum kit" in lower:
                percent = 50 + math.floor(percent * 0.45)
            elif "writing drum tracks" in lower:
                percent = max(95, percent)
            else:
                percent = max(50, percent)
    return max(previous, max(0, min(99, percent)))


def test_mirror_matches_the_real_lua_mapping():
    lua = PROGRESS_LUA.read_text(encoding="utf-8")
    assert "percent = math.min(49, percent)" in lua
    assert "percent = 50 + math.floor(percent * 0.45)" in lua
    assert "percent = math.max(95, percent)" in lua
    assert "percent = math.max(50, percent)" in lua


@pytest.mark.parametrize(
    "helper_raw, direct_kit, kit_split",
    [(10, 9, 54), (25, 23, 60), (50, 45, 70), (75, 68, 80), (90, 81, 86)],
)
def test_p1b_visible_values_for_direct_kit_and_kit_split(helper_raw, direct_kit, kit_split):
    band = _caller_namespace()["helper_inference_band_percent"]
    mapped = band(helper_raw)
    assert _normalize(mapped, "Splitting drum kit...", "dks_direct", 0) == direct_kit
    assert _normalize(mapped, "Splitting drum kit...", "dks_extract", 50) == kit_split


def test_full_run_sequences_stay_monotonic_and_reserve_completion():
    band = _caller_namespace()["helper_inference_band_percent"]
    helper_samples = [0, 10, 25, 50, 75, 90, 99]

    for workflow, stage1 in (("dks_direct", []), ("dks_extract", [(1, "Extracting drums..."), (48, "Extracting drums...")])):
        previous = 0
        seen = []
        for raw, stage in stage1:
            previous = _normalize(raw, stage, workflow, previous)
            seen.append(previous)
        for raw in helper_samples:
            previous = _normalize(band(raw), "Splitting drum kit...", workflow, previous)
            seen.append(previous)
        previous = _normalize(95, "Writing drum tracks...", workflow, previous)
        seen.append(previous)
        assert seen == sorted(seen), f"{workflow} regressed: {seen}"
        assert max(seen) == 95, f"{workflow} must end the reported phase at 95, not 100: {seen}"
        assert all(value < 100 for value in seen)


def test_kit_split_stage_two_now_sweeps_instead_of_sitting_flat():
    """The observed defect: stage 2 pinned at 50 for the whole separation."""
    band = _caller_namespace()["helper_inference_band_percent"]
    previous = 50
    values = []
    for raw in (5, 20, 40, 60, 80, 99):
        previous = _normalize(band(raw), "Splitting drum kit...", "dks_extract", previous)
        values.append(previous)
    assert len(set(values)) > 1, "stage 2 must actually advance"
    assert values[0] >= 50 and values[-1] >= 85, values
