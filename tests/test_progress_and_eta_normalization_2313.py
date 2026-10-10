"""Progress must never move backwards, and the ETA must stay silent rather than
lie.

Progress: the drum workflows emit STAGE-LOCAL percentages. Kit Split stage 1
counts 1..48, stage 2 then restarts its own counter from ~1, and Direct Kit
ramps 1..12 before real tqdm output takes over from a lower value. The
multi-item queue already ran every sample through normalizeMultiTrackProgress,
which folds stage 2 into the second half and latches the running maximum -- but
the single-item path assigned the raw percentage straight onto the bar, so the
same run looked coherent with two items selected and jumped 26% -> 3% with one.

ETA: the queue estimate divided remaining audio by a throughput measured from
queue start, so model load and warm-up were counted as processing time; queued
jobs contributed their full duration to the remaining work while contributing
nothing to the completed term. Early on that produced a confident, wildly high
number (16:18 at 4%), and the moment a job finished the ratio inverted to ~0:01.
There was no confidence gate, no smoothing, and no reseed at job boundaries.

Both fixes are reporting-only: no worker, scheduler or device behaviour changes.
Lua is extracted from production by declaration anchor, never by line number.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MAIN_LUA = ROOT / "scripts" / "reaper" / "STEMwerk.lua"
PROGRESS_LUA = ROOT / "scripts" / "reaper" / "_internal" / "STEMwerk_Progress_Render.lua"
WORKFLOW_LUA = ROOT / "scripts" / "reaper" / "_internal" / "STEMwerk_Workflow.lua"

LUA = shutil.which("lua5.4") or shutil.which("lua5.3") or shutil.which("lua") or shutil.which("luajit")
pytestmark = pytest.mark.skipif(LUA is None, reason="no lua interpreter available")


def _declaration_index(lines: list[str], name: str) -> int:
    prefixes = (f"function {name}(", f"local function {name}(")
    for index, line in enumerate(lines):
        if line.startswith(prefixes):
            return index
    raise AssertionError(f"no top-level declaration of {name}()")


def _extract_lua_function(text: str, name: str) -> str:
    lines = text.splitlines(keepends=True)
    start = _declaration_index(lines, name)
    for index in range(start + 1, len(lines)):
        if lines[index].rstrip("\r\n") == "end":
            return "".join(lines[start : index + 1])
    raise AssertionError(f"no column-0 'end' terminates {name}()")


def _run(preamble: str, driver: str) -> str:
    assert LUA is not None
    done = subprocess.run([LUA, "-"], input=preamble + "\n" + driver, text=True, capture_output=True, timeout=20)
    assert done.returncode == 0, done.stderr
    return done.stdout.strip()


def _progress_preamble() -> str:
    """normalizeMultiTrackProgress plus the stage classifier it calls."""
    src = PROGRESS_LUA.read_text(encoding="utf-8", errors="replace")
    return "\n".join(
        [
            _extract_lua_function(src, "inferDrumKitStageIndex"),
            _extract_lua_function(src, "normalizeMultiTrackProgress"),
        ]
    )


def _eta_preamble() -> str:
    return _extract_lua_function(MAIN_LUA.read_text(encoding="utf-8", errors="replace"), "estimateQueueEta")


def _normalize_sequence(samples: list[tuple[int, str]], workflow: str) -> list[int]:
    """Feed raw (percent, stage) samples through the normalizer exactly as the
    UI does, carrying the previous displayed value forward each time."""
    entries = ", ".join(f'{{ {p}, "{s}" }}' for p, s in samples)
    out = _run(
        _progress_preamble(),
        f"local samples = {{ {entries} }}\n"
        "local prev = 0\nlocal out = {}\n"
        "for _, s in ipairs(samples) do\n"
        f'  prev = normalizeMultiTrackProgress(s[1], s[2], "{workflow}", prev)\n'
        "  out[#out + 1] = tostring(prev)\nend\n"
        'print(table.concat(out, ","))',
    )
    return [int(value) for value in out.split(",")]


# --- Kit Split: the reported stage-1 -> stage-2 regression -------------------

KIT_SPLIT_RUN = [
    (1, "Extracting drums..."),
    (12, "Extracting drums..."),
    (26, "Extracting drums..."),
    (48, "Extracting drums..."),
    (50, "Stage 2 queued for DrumSep..."),
    (1, "Starting Drum Kit runtime [Stage 2]..."),
    (3, "Splitting drum kit..."),
    (12, "Splitting drum kit..."),
    (60, "Splitting drum kit..."),
    (99, "Splitting drum kit..."),
    (95, "Writing drum tracks..."),
]


def test_kit_split_progress_never_moves_backwards():
    values = _normalize_sequence(KIT_SPLIT_RUN, "dks_extract")
    assert values == sorted(values), f"progress regressed: {values}"


def test_kit_split_stage2_starts_in_the_second_half_not_near_zero():
    values = _normalize_sequence(KIT_SPLIT_RUN, "dks_extract")
    stage2 = values[5:]
    assert min(stage2) >= 50, f"stage 2 restarted below the halfway mark: {stage2}"
    # The exact regression that was reported: 26% followed by a raw 3%.
    assert values[6] >= values[2]


def test_kit_split_stage1_stays_below_the_halfway_mark():
    values = _normalize_sequence(KIT_SPLIT_RUN, "dks_extract")
    assert max(values[:4]) <= 49


def test_kit_split_writing_tracks_reaches_the_high_end():
    assert _normalize_sequence(KIT_SPLIT_RUN, "dks_extract")[-1] >= 95


# --- Direct Kit ---------------------------------------------------------------

DIRECT_KIT_RUN = [
    (0, "Preparing Direct Drum Kit..."),
    (1, "Starting Drum Kit runtime..."),
    (12, "Splitting drum kit..."),
    (4, "Splitting drum kit..."),  # real tqdm takes over below the synthetic ramp
    (40, "Splitting drum kit..."),
    (99, "Splitting drum kit..."),
    (95, "Writing drum tracks..."),
]


def test_direct_kit_progress_is_monotonic_across_the_ramp_handover():
    values = _normalize_sequence(DIRECT_KIT_RUN, "dks_direct")
    assert values == sorted(values), f"progress regressed: {values}"
    assert values[3] >= values[2], "the tqdm handover must not drop the bar"


def test_direct_kit_keeps_raw_scale_rather_than_second_half_mapping():
    """Direct Kit is single-stage, so it must not be shifted into 50..95 the way
    Kit Split stage 2 is -- only clamped and latched."""
    values = _normalize_sequence([(40, "Splitting drum kit...")], "dks_direct")
    assert values == [40]


# --- coarse / repeated samples ------------------------------------------------


def test_repeated_and_coarse_samples_stay_monotonic():
    samples = [(12, "Splitting drum kit...")] * 5 + [(12, "Splitting drum kit..."), (11, "Splitting drum kit...")]
    values = _normalize_sequence(samples, "dks_direct")
    assert values == sorted(values)
    assert len(set(values)) == 1, "a coarse plateau must not be embellished with fake movement"


def test_terminal_100_is_never_produced_by_normalization():
    for workflow in ("dks_extract", "dks_direct", "normal"):
        values = _normalize_sequence([(100, "Writing drum tracks..."), (100, "Complete")], workflow)
        assert max(values) <= 99, f"{workflow} reported 100% from a progress sample"


def test_normal_stems_progress_is_not_reshaped():
    samples = [(5, "Processing chunk 1/8"), (45, "Processing chunk 3/8"), (92, "Writing stems")]
    assert _normalize_sequence(samples, "normal") == [5, 45, 92]


# --- single-item path now uses the same normalizer ----------------------------


def test_single_item_path_applies_the_shared_normalizer():
    body = _extract_lua_function(WORKFLOW_LUA.read_text(encoding="utf-8"), "WORKFLOW.updateProgressFromFile")
    assert "C.normalizeProgressPercent(" in body, "single-item progress must go through the shared normalizer"
    assert 'workflowSource == "dks_extract" or workflowSource == "dks_direct"' in body
    assert "C.progressState.rawPercent = lastProgress.percent" in body, "raw backend progress must stay available"


def test_single_item_normalizer_is_wired_from_the_shared_module():
    src = MAIN_LUA.read_text(encoding="utf-8")
    assert "normalizeProgressPercent      = UI_PROGRESS.normalizeMultiTrackProgress," in src, (
        "the single-item path must reuse the queue normalizer, not a second implementation"
    )


def test_single_and_multi_item_call_sites_share_one_normalizer_contract():
    """Both call sites must pass the same four arguments in the same order, with
    the previous DISPLAYED value as the monotonic carry -- the queue passes
    job.percent, the single path passes progressState.percent."""
    src = MAIN_LUA.read_text(encoding="utf-8")
    assert (
        "UI_PROGRESS.normalizeMultiTrackProgress(rawPercent, stage, workflowSource, job and job.percent)" in src
    ), "the multi-item call site changed shape"
    workflow = _extract_lua_function(WORKFLOW_LUA.read_text(encoding="utf-8"), "WORKFLOW.updateProgressFromFile")
    for argument in ("lastProgress.percent,", "lastProgress.stage,", "workflowSource,", "prevPercent"):
        assert argument in workflow, f"single-item call site missing {argument}"


# --- ETA ----------------------------------------------------------------------


def _eta(**opts) -> int:
    fields = []
    for key, value in opts.items():
        if isinstance(value, bool):
            fields.append(f"{key} = {'true' if value else 'false'}")
        else:
            fields.append(f"{key} = {value}")
    return int(_run(_eta_preamble(), f"print(estimateQueueEta({{ {', '.join(fields)} }}))"))


def test_the_reported_absurd_early_eta_is_now_suppressed():
    """elapsed 95s, 4% overall, one job barely started: previously 16:18."""
    assert _eta(totalAudioDur=44.0, completedAudioDur=1.8, elapsedSinceFirstJob=95, overallProgress=4) == 0


@pytest.mark.parametrize(
    "elapsed, progress",
    [(5, 40), (19, 40), (60, 2), (60, 9), (0, 0)],
    ids=["too-early", "just-under-elapsed-gate", "barely-any-progress", "just-under-progress-gate", "nothing-yet"],
)
def test_insufficient_samples_produce_no_number(elapsed, progress):
    assert _eta(totalAudioDur=44.0, completedAudioDur=5.0, elapsedSinceFirstJob=elapsed, overallProgress=progress) == 0


def test_eta_appears_once_the_signal_is_stable():
    eta = _eta(totalAudioDur=44.0, completedAudioDur=22.0, elapsedSinceFirstJob=60, overallProgress=50)
    assert eta > 0
    # half the audio took 60s, so the remaining half should be near 60s.
    assert 45 <= eta <= 75, eta


def test_unknown_pending_duration_suppresses_the_estimate():
    assert _eta(
        totalAudioDur=44.0,
        completedAudioDur=22.0,
        elapsedSinceFirstJob=60,
        overallProgress=50,
        pendingUnknownDuration=True,
    ) == 0


def test_a_finishing_queue_never_reports_an_absurdly_small_eta():
    """The 0:01 flash at the job boundary: remaining work is tiny but non-zero."""
    eta = _eta(totalAudioDur=44.0, completedAudioDur=43.9, elapsedSinceFirstJob=90, overallProgress=99)
    assert eta == 0 or eta >= 5, eta


def test_completed_queue_reports_no_eta():
    assert _eta(totalAudioDur=44.0, completedAudioDur=44.0, elapsedSinceFirstJob=90, overallProgress=100) == 0


def test_smoothing_damps_a_sudden_jump_but_still_tracks():
    stale = _eta(
        totalAudioDur=44.0, completedAudioDur=22.0, elapsedSinceFirstJob=60, overallProgress=50, previousEta=600
    )
    fresh = _eta(totalAudioDur=44.0, completedAudioDur=22.0, elapsedSinceFirstJob=60, overallProgress=50)
    assert fresh < stale < 600, "a stale estimate must be pulled toward the fresh one, not adopted or ignored"


@pytest.mark.parametrize(
    "opts",
    [
        {"totalAudioDur": 0, "completedAudioDur": 0, "elapsedSinceFirstJob": 60, "overallProgress": 50},
        {"totalAudioDur": 44.0, "completedAudioDur": 0, "elapsedSinceFirstJob": 60, "overallProgress": 50},
        {"totalAudioDur": 44.0, "completedAudioDur": 44.0, "elapsedSinceFirstJob": 0, "overallProgress": 50},
        {"totalAudioDur": 10.0, "completedAudioDur": 44.0, "elapsedSinceFirstJob": 60, "overallProgress": 50},
    ],
    ids=["no-audio", "nothing-completed", "no-elapsed", "completed-exceeds-total"],
)
def test_no_division_by_zero_nan_or_negative_eta(opts):
    value = _eta(**opts)
    assert value >= 0 and value == value, value


def test_eta_is_reseeded_at_job_boundaries():
    src = MAIN_LUA.read_text(encoding="utf-8")
    assert "multiTrackQueue.etaCompletedJobs ~= completedJobs" in src
    assert "multiTrackQueue.etaSmoothed = nil" in src, "a finished job must not carry its estimate forward"


def test_eta_throughput_excludes_queue_warmup():
    src = MAIN_LUA.read_text(encoding="utf-8")
    assert "elapsedSinceFirstJob = (firstJobStartTime and (os.time() - firstJobStartTime)) or 0," in src, (
        "throughput must be measured from the first started job, not from queue creation"
    )


def test_old_unguarded_percent_extrapolation_is_gone():
    src = MAIN_LUA.read_text(encoding="utf-8")
    assert "local totalEstimate = globalElapsed * 100 / overallProgress" not in src


# --- regression guards --------------------------------------------------------


def test_scheduler_and_device_selection_are_untouched_by_this_slice():
    src = MAIN_LUA.read_text(encoding="utf-8")
    for anchor in (
        "_sep.classifyDirectmlSchedulerAdapter = function(name)",
        "_sep.resolveDirectmlSchedulerAdapter = function(requestedDevice, runtimeDevices)",
        'policy.reason = "directml_multi_track"',
        'policy.reason = "scheduler_dks_direct_directml_cap4"',
    ):
        assert anchor in src, f"scheduler/device anchor missing: {anchor}"


def test_p1a_reporting_helpers_still_present():
    src = MAIN_LUA.read_text(encoding="utf-8")
    for anchor in ("function resolveResultReportingTriple(data)", "function resultMethodReportingText(data)"):
        assert anchor in src
