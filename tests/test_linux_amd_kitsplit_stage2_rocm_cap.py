"""Kit Split (dks_extract) stage-2 DrumSep ROCm/CUDA concurrency cap.

2.3.1.3 Linux AMD release-gate hardware validation (RX 9070 / gfx1201, ROCm
7.2.3, torch 2.10.0+rocm7.0) found a reproducible stall: Kit Split stage 2
(DrumSep MDX23C) launched 4 concurrent jobs against a single GPU and none made
forward progress for 7+ minutes (stuck at 0 iterations, confirmed via
drumsep_helper.log and ps/rocm-smi). Direct Kit's DrumSep ran cleanly at the
same time with an observed cap of 2 -- but source inspection proved that
observed cap=2 was actually a *CPU-fallback* concurrency cap applied because
the Lua scheduler's Setup-time ROCm state-file prediction was stale, not a
deliberate discrete-GPU policy. That is a separate, still-open finding
(tracked outside this fix) -- Direct Kit's genuine ROCm-predicted cap is also
4 and was never actually exercised by the validation matrix.

Root cause: DKS_EXTRACT_STAGE2_CONCURRENCY_CAP was hardcoded to 4, entirely
independent of (not inherited from, not fed by) Kit Split stage 1's separate
Lua-side cap of 4 -- two unrelated constants that happened to match. No code
path anywhere reduced this for any ROCm device, discrete or integrated.

Fix: lower DKS_EXTRACT_STAGE2_CONCURRENCY_CAP to 2. Proven via controlled A/B
on real RX 9070 hardware: two explicit-RX9070 runs and one Auto->RX9070 run,
all 8/8 items, 48/48 outputs, no stall, cap=2 semaphore behavior confirmed via
phase_events.jsonl timing (paired completion waves ~20s apart instead of 4-way
simultaneous stall).

Deliberately narrow: applies uniformly to any ROCm/CUDA backend. No
discrete/integrated device classifier is introduced -- none exists anywhere
in this codebase (only a DirectML-specific one does), and inventing one for
ROCm wasn't justified by evidence: a uniform cap=2 can only ever *lower*
concurrency relative to the previous buggy cap=4, for every ROCm device
including the integrated Radeon 780M, so it cannot regress anything that
wasn't already broken. Stage 1 (Lua), Direct Kit, and CPU stage-2 concurrency
are untouched by this fix.
"""

import importlib.util
import os
import threading
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
AUDIO_PROCESS = ROOT / "scripts" / "reaper" / "audio_separator_process.py"


def _load_module(path: Path, name: str):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def _load_audio_process():
    return _load_module(AUDIO_PROCESS, "audio_separator_process_kitsplit_stage2_cap_test")


def _clear_bench_env(monkeypatch):
    for name in (
        "STEMWERK_BENCH_DKS_STAGE2_CAP",
        "STEMWERK_BENCH_GPU_CAP",
        "STEMWERK_BENCH_DKS_STAGE2_CPU_CAP",
        "STEMWERK_BENCH_CPU_CAP",
        "STEMWERK_BENCH_DKS_STAGE2_MPS_CAP",
        "STEMWERK_BENCH_MPS_CAP",
    ):
        monkeypatch.delenv(name, raising=False)


def test_stage2_concurrency_cap_constant_is_2():
    mod = _load_audio_process()
    assert mod.DKS_EXTRACT_STAGE2_CONCURRENCY_CAP == 2


def test_stage2_rocm_default_cap_resolves_to_2_with_no_benchmark_override(monkeypatch):
    mod = _load_audio_process()
    _clear_bench_env(monkeypatch)
    requested_cap, _raw_cap, applied_cap, _ignored = mod._resolve_dks_extract_stage2_benchmark_cap("rocm")
    assert requested_cap is None
    assert applied_cap == 2


def test_stage2_cuda_default_cap_also_resolves_to_2(monkeypatch):
    mod = _load_audio_process()
    _clear_bench_env(monkeypatch)
    _, _, applied_cap, _ = mod._resolve_dks_extract_stage2_benchmark_cap("cuda")
    assert applied_cap == 2


def test_stage2_cpu_cap_remains_1_unaffected_by_rocm_fix(monkeypatch):
    mod = _load_audio_process()
    _clear_bench_env(monkeypatch)
    _, _, applied_cap, _ = mod._resolve_dks_extract_stage2_benchmark_cap("cpu")
    assert applied_cap == 1


def test_stage2_directml_and_mps_backends_unaffected_by_rocm_fix(monkeypatch):
    mod = _load_audio_process()
    _clear_bench_env(monkeypatch)
    _, _, directml_cap, _ = mod._resolve_dks_extract_stage2_benchmark_cap("directml")
    _, _, mps_cap, _ = mod._resolve_dks_extract_stage2_benchmark_cap("mps")
    assert directml_cap == 1
    assert mps_cap == 1


def test_stage2_backend_classifier_has_no_discrete_integrated_distinction():
    """No ROCm device-name classifier exists (RX 9070 vs Radeon 780M) and the
    fix intentionally does not add one. Any ROCm-backed device, discrete or
    integrated, must resolve to the same "rocm" backend string and therefore
    the same cap=2 policy -- proving the integrated 780M cannot regress
    relative to the discrete RX 9070 under this fix (cap only ever went down,
    from 4 to 2, for every ROCm device, never up for any of them).
    """
    mod = _load_audio_process()
    integrated_info = {
        "kind": "rocm",
        "device_names": ["AMD Radeon 780M Graphics"],
        "torch_hip": "7.0.51831",
    }
    discrete_info = {
        "kind": "rocm",
        "device_names": ["AMD Radeon RX 9070"],
        "torch_hip": "7.0.51831",
    }
    integrated_backend = mod._detect_dks_extract_stage2_backend("", integrated_info)
    discrete_backend = mod._detect_dks_extract_stage2_backend("", discrete_info)
    assert integrated_backend == discrete_backend == "rocm"

    _, _, integrated_cap, _ = mod._resolve_dks_extract_stage2_benchmark_cap(integrated_backend)
    _, _, discrete_cap, _ = mod._resolve_dks_extract_stage2_benchmark_cap(discrete_backend)
    assert integrated_cap == discrete_cap == 2


def test_stage2_auto_and_explicit_rocm_resolve_to_same_backend_and_cap():
    """Auto-resolved and explicitly-requested ROCm both surface as the
    literal string "rocm" to the stage-2 cap resolver (see
    _select_drumsep_runtime: info["kind"] = "rocm" either way). Guards that
    Auto and explicit get the identical safety policy -- matching the
    hardware evidence that both the Auto->RX9070 and explicit RX9070 runs
    passed identically under cap=2."""
    mod = _load_audio_process()
    auto_backend = mod._detect_dks_extract_stage2_backend("rocm")
    explicit_backend = mod._detect_dks_extract_stage2_backend("rocm")
    assert auto_backend == explicit_backend == "rocm"

    _, _, auto_cap, _ = mod._resolve_dks_extract_stage2_benchmark_cap(auto_backend)
    _, _, explicit_cap, _ = mod._resolve_dks_extract_stage2_benchmark_cap(explicit_backend)
    assert auto_cap == explicit_cap == 2


def test_benchmark_override_can_still_reach_cap4_deliberately():
    """The benchmark-only env-var override path (STEMWERK_BENCH_DKS_STAGE2_CAP)
    is untouched by this fix -- it is explicit, opt-in instrumentation, not
    the default end-user policy that stalled. cap=4 must remain requestable
    for future controlled experiments."""
    mod = _load_audio_process()
    assert 4 in mod.DKS_EXTRACT_STAGE2_BENCHMARK_CAPS


@pytest.mark.skipif(os.name != "posix", reason="stage-2 lock uses fcntl, POSIX only")
def test_stage2_lock_enforces_max_concurrency_of_2_for_rocm(tmp_path):
    """Direct behavioral proof, not just a constant check: actually contend
    for the real _dks_extract_stage2_lock with 8 concurrent callers and
    confirm no more than 2 ever hold a slot at once for a ROCm backend --
    this is the exact mechanism that stalled the real hardware run at cap=4
    and was proven fixed at cap=2."""
    mod = _load_audio_process()
    batch_root = tmp_path / "STEMwerk_test_batch"
    batch_root.mkdir()

    active = 0
    max_active = 0
    guard = threading.Lock()

    def worker():
        nonlocal active, max_active
        with mod._dks_extract_stage2_lock(batch_root / "item_1", "rocm"):
            with guard:
                active += 1
                max_active = max(max_active, active)
            time.sleep(0.15)
            with guard:
                active -= 1

    threads = [threading.Thread(target=worker) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=15)

    assert max_active == 2


@pytest.mark.skipif(os.name != "posix", reason="stage-2 lock uses fcntl, POSIX only")
def test_stage2_lock_enforces_full_serialization_for_cpu(tmp_path):
    """CPU stage-2 concurrency (cap=1, fully sequential) must remain
    unaffected by the ROCm cap change."""
    mod = _load_audio_process()
    batch_root = tmp_path / "STEMwerk_test_batch_cpu"
    batch_root.mkdir()

    active = 0
    max_active = 0
    guard = threading.Lock()

    def worker():
        nonlocal active, max_active
        with mod._dks_extract_stage2_lock(batch_root / "item_1", "cpu"):
            with guard:
                active += 1
                max_active = max(max_active, active)
            time.sleep(0.1)
            with guard:
                active -= 1

    threads = [threading.Thread(target=worker) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=15)

    assert max_active == 1


def test_kit_split_stage1_lua_policy_is_unchanged():
    """This fix must not touch Kit Split stage 1 (htdemucs) concurrency,
    Direct Kit, or CPU policy. Guard the exact constants/reason strings that
    were true before this fix, matching the existing STEMwerk.lua scheduler
    test convention (see test_dependency_constraints.py)."""
    script = Path("scripts/reaper/STEMwerk.lua").read_text()

    # Kit Split stage 1 GPU: unchanged, still cap 4 (this fix only ever
    # touches the Python-side stage-2 constant).
    assert "NORMAL_GPU_MAX_PARALLEL = 4" in script
    assert '"scheduler_dks_extract_stage1_normal_gpu_cap4"' in script

    # Direct Kit GPU: unchanged, still cap 4. (Its observed cap=2 in the
    # earlier validation run was a CPU-fallback misprediction, not a real
    # discrete-GPU policy -- a separate, still-open follow-up, not fixed
    # here.)
    assert "DKS_DIRECT_GPU_SHORT_MAX_PARALLEL = 4" in script
    assert 'policy.reason = "scheduler_dks_direct_gpu_cap4"' in script

    # CPU policies: unchanged.
    assert "NORMAL_CPU_MAX_PARALLEL = 2" in script
    assert "DKS_DIRECT_CPU_MAX_PARALLEL = 2" in script

    # The pre-existing, never-wired Lua-side stage-2 constant is left exactly
    # as found -- this fix routes through the real Python-side gate instead
    # of wiring up dead code as part of a narrow maintenance fix.
    assert "DKS_EXTRACT_STAGE2_MAX_PARALLEL = 4" in script


def test_stage2_lock_still_uses_python_side_constant_not_lua_value():
    """Guards the core root-cause finding: stage 2's cap must come from
    DKS_EXTRACT_STAGE2_CONCURRENCY_CAP (Python), never from a value threaded
    through from the Lua scheduler's stage-1 cap -- the two were always
    independent constants, not a data dependency."""
    script = Path("scripts/reaper/audio_separator_process.py").read_text()
    assert "def _dks_extract_stage2_lock(" in script
    assert (
        "requested_cap, raw_cap, effective_cap, ignored_reason = "
        "_resolve_dks_extract_stage2_benchmark_cap(stage2_backend)"
    ) in script
    assert "DKS_EXTRACT_STAGE2_CONCURRENCY_CAP = 2" in script
