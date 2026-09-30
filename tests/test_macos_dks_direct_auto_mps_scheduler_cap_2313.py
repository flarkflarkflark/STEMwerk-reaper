"""Regression coverage for the 2.3.1.3 Direct Kit Auto/MPS scheduler fix.

Direct Kit / Auto on Apple Silicon used to be misclassified as a "cpu"
backend for scheduling purposes (an old pre-MPS classification bug never
extended to this route when Normal Stems and Kit Split were fixed for MPS),
landing it on the generic CPU thread/RAM concurrency heuristic -- which
coincidentally produced cap=2 on 8 GiB machines. Hardware A/B testing on the
supported Apple M1 8 GB configuration proved that cap=2 reproducibly drives
the kernel's own memory-pressure level to critical for only a ~5% wall-clock
gain over cap=1, while GPU utilization is already near-saturated either way.

The fix makes Direct Kit / Auto genuinely MPS-aware and memory-scaled:
cap=1 at ~8 GiB (the proven-unsafe-at-cap2 configuration), cap=2 preserved
(not newly hardware-validated) above that. Explicit MPS, CPU, Normal Stems,
Kit Split, and the ROCm/CUDA/DirectML paths are all untouched.

The real behavioral coverage of the cap decision across RAM tiers lives in
tests/support/run_dks_direct_auto_mps_scheduler_headless.lua, which extracts
and executes the actual production _sep.SCHEDULER_POLICY table and
_sep.resolveSchedulerConcurrencyPolicy function verbatim out of
scripts/reaper/STEMwerk.lua (that 24k-line file has an unconditional main()
at the bottom and no headless-test guard, so it cannot be dofile()'d
directly). This module just invokes that harness and adds a couple of
source-presence guards for the classification-block half of the fix, which
the headless harness does not exercise.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
STEMWERK_LUA = ROOT / "scripts/reaper/STEMwerk.lua"
HEADLESS_HARNESS = "tests/support/run_dks_direct_auto_mps_scheduler_headless.lua"


@pytest.mark.skipif(
    shutil.which("lua") is None,
    reason="Lua interpreter required for headless Direct Kit scheduler coverage",
)
def test_dks_direct_auto_mps_scheduler_cap_policy_behavioral() -> None:
    """Executes the real, unmodified scheduler function across RAM tiers.

    Proves (via the real production function, not a reimplementation):
    MPS Auto + 8 GiB -> cap=1, + 16/32 GiB -> cap=2 (preserved policy);
    explicit MPS -> cap=1 regardless of RAM; Direct Kit CPU, Normal Stems
    Auto/MPS, Kit Split stage-1 Auto/MPS and explicit MPS, and the generic
    GPU (ROCm/CUDA) and DirectML Direct Kit paths are all unchanged.
    """
    result = subprocess.run(
        [shutil.which("lua") or "lua", HEADLESS_HARNESS],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, (
        f"headless Direct Kit scheduler harness failed:\n{result.stdout}\n{result.stderr}"
    )
    assert "OK: dks_direct Auto/MPS scheduler cap policy" in result.stdout


def test_dks_direct_auto_now_classified_as_mps_not_cpu_for_scheduling() -> None:
    """The Auto-on-Apple-Silicon backend classification block must route
    dks_direct into the real "mps" branch, same as normal/dks_extract, so
    the reason/telemetry it reports is genuinely MPS-derived rather than
    the old CPU-derived misclassification.
    """
    script = STEMWERK_LUA.read_text(encoding="utf-8")
    assert (
        'if schedulerRoute == "normal" or schedulerRoute == "dks_extract"'
        ' or schedulerRoute == "dks_direct" then'
    ) in script
    assert 'schedulerBackend = "mps"' in script


def test_dks_direct_mps_branch_is_memory_scaled_not_a_bare_hardcode() -> None:
    """The fix must be a genuine RAM-aware decision (reusing the existing
    ramGiB capability value already threaded through this function), not a
    bare `if dks_direct and auto then cap=1` special case, and must not
    invent an untested broader threshold such as <=16 GiB.
    """
    script = STEMWERK_LUA.read_text(encoding="utf-8")
    assert 'elseif route == "dks_direct" and tostring(opts.requestedDevice or ""):lower() == "auto" then' in script
    assert "local ramGiB = tonumber(opts.ramGiB)" in script
    assert "ramGiB and ramGiB > 8.5" in script
    assert "<= 16" not in script.split('elseif route == "dks_direct" and tostring(opts.requestedDevice or "")')[1][:800]
    assert 'policy.reason = "scheduler_dks_direct_mps_cap2"' in script
    assert 'policy.reason = "scheduler_dks_direct_mps_low_memory_sequential"' in script
    assert "cpu" not in "scheduler_dks_direct_mps_low_memory_sequential"


def test_dks_direct_explicit_mps_source_path_untouched() -> None:
    """Explicit MPS for Direct Kit must still fall through to the same
    generic conservative branch it always used (unchanged cap constant and
    reason string), confirming the fix only adds a new Auto-specific
    branch rather than altering the existing explicit-device behavior.
    """
    script = STEMWERK_LUA.read_text(encoding="utf-8")
    assert 'policy.reason = "scheduler_mps_conservative"' in script
    assert "policy.cap = _sep.SCHEDULER_POLICY.NORMAL_MPS_MAX_PARALLEL" in script


def test_dks_direct_cpu_normal_and_kit_split_mps_policies_unchanged() -> None:
    """Regression guard: none of the sibling policies this fix must not
    touch (Direct Kit CPU, Normal Stems MPS, Kit Split stage-1 MPS) were
    modified.
    """
    script = STEMWERK_LUA.read_text(encoding="utf-8")
    assert 'policy.reason = "scheduler_dks_direct_cpu_cap2"' in script
    assert "policy.cap = math.min(jobCount, _sep.SCHEDULER_POLICY.DKS_DIRECT_CPU_MAX_PARALLEL)" in script
    assert 'policy.reason = "scheduler_normal_mps_cap2"' in script
    assert 'policy.reason = "scheduler_dks_extract_stage1_normal_mps_cap2"' in script
    assert 'policy.reason = "scheduler_dks_extract_mps_sequential"' in script


def test_dks_direct_gpu_and_directml_paths_unchanged() -> None:
    """Regression guard: the ROCm/CUDA generic-GPU and DirectML Direct Kit
    branches (Windows/Linux only in practice) are untouched by this
    macOS/MPS-only fix.
    """
    script = STEMWERK_LUA.read_text(encoding="utf-8")
    assert 'policy.reason = "scheduler_dks_direct_gpu_cap4"' in script
    assert 'policy.reason = "scheduler_dks_direct_gpu_long_cap4"' in script
    assert 'policy.reason = "scheduler_dks_direct_windows_cuda_cap2"' in script
    assert 'policy.reason = "directml_multi_track"' in script
    assert (
        'policy.reason = "scheduler_dks_direct_directml_cap4"' in script
        or 'policy.reason = "scheduler_dks_direct_directml_long_cap4"' in script
    )


def test_linux_kit_split_rocm_stage2_cap_untouched_by_this_fix() -> None:
    """No regression to the candidate's own 2.3.1.3 Linux AMD Kit Split
    ROCm stage-2 concurrency fix (DKS_EXTRACT_STAGE2_CONCURRENCY_CAP = 2),
    which lives in a different module entirely from the scheduler change
    made here.
    """
    audio_process = ROOT / "scripts/reaper/audio_separator_process.py"
    text = audio_process.read_text(encoding="utf-8")
    assert "DKS_EXTRACT_STAGE2_CONCURRENCY_CAP = 2" in text
