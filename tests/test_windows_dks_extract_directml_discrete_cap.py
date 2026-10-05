"""Kit Split stage 1 must not be slower just because the adapter was chosen
explicitly rather than by Auto.

Measured back-to-back on the validated Windows AMD host, same two items, same
resolved execution (dks_extract_stage1_device=directml:0, AMD Radeon RX 9070,
effective_device=privateuseone:0) in both runs:

    explicit directml:0 -> backend "directml", cap 1, directml_multi_track,
                           items ran back to back, ~54.5 s
    auto                -> backend "gpu",      cap 2, ...stage1_normal_gpu_cap4,
                           items overlapped,   ~29.9 s

classifySchedulerBackend matches on the REQUESTED device string before Auto is
resolved, so Auto never looks like DirectML and takes the generic GPU branch,
while an explicit request hits the blanket DirectML stability cap. That cap
predates adapter awareness: the run above logged
scheduler_policy_directml_adapter_class=discrete, so the classifier had already
identified the adapter correctly -- the branch simply never consulted it.

Only Kit Split stage 1 is changed here. Stage 2 (the DrumSep helper, the one
workload that actually lost the device under concurrency) stays capped at 1 by
independent code in audio_separator_process.py, Direct Kit keeps the 07b708ff
policy, and Normal Stems is deliberately left alone.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
STEMWERK_LUA = ROOT / "scripts" / "reaper" / "STEMwerk.lua"
CALLER_PY = ROOT / "scripts" / "reaper" / "audio_separator_process.py"

LUA = shutil.which("lua5.4") or shutil.which("lua5.3") or shutil.which("lua") or shutil.which("luajit")
pytestmark = pytest.mark.skipif(LUA is None, reason="no lua interpreter available")

_TOKEN_RE = re.compile(
    r'--\[(=*)\[|--.*|\[(=*)\[|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|\b(function|if|for|while|end)\b'
)


def _lua_block(source: str, start_marker: str) -> str:
    start = source.index(start_marker)
    pos, depth, opened = start, 0, False
    while True:
        m = _TOKEN_RE.search(source, pos)
        if not m:
            raise AssertionError(start_marker)
        if m.group(1) is not None or m.group(2) is not None:
            level = m.group(1) if m.group(1) is not None else m.group(2)
            close = "]" + level + "]"
            pos = source.index(close, m.end()) + len(close)
            continue
        word = m.group(3)
        pos = m.end()
        if word is None:
            continue
        if word in ("function", "if", "for", "while"):
            depth += 1
            opened = True
        elif word == "end":
            depth -= 1
            if opened and depth == 0:
                return source[start:pos]


def _scheduler_source() -> str:
    text = STEMWERK_LUA.read_text(encoding="utf-8")
    table_start = text.index("_sep.SCHEDULER_POLICY = {")
    table = text[table_start : text.index("\n}\n", table_start) + 3]
    functions = [
        _lua_block(text, f"_sep.{name} = function(")
        for name in (
            "classifySchedulerBackend",
            "classifyDirectmlSchedulerAdapter",
            "resolveDirectmlSchedulerAdapter",
            "resolveSchedulerConcurrencyPolicy",
        )
    ]
    return "\n".join([table, *functions])


def _run_lua(tmp_path: Path, body: str) -> dict[str, str]:
    script = tmp_path / "p1d_harness.lua"
    script.write_text('OS = "Windows"\n_sep = {}\n' + _scheduler_source() + "\n" + body, encoding="utf-8")
    done = subprocess.run([LUA, str(script)], capture_output=True, text=True, timeout=30)
    assert done.returncode == 0, done.stderr
    return dict(line.split("=", 1) for line in done.stdout.splitlines() if "=" in line)


def _lua_value(value) -> str:
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    return '"' + str(value) + '"'


def _policy(tmp_path: Path, **opts) -> tuple[str, str, str]:
    fields = ", ".join(f"{k} = {_lua_value(v)}" for k, v in opts.items())
    out = _run_lua(
        tmp_path,
        f"local p = _sep.resolveSchedulerConcurrencyPolicy({{ {fields} }})\n"
        "io.write('cap=', tostring(p.cap), '\\n', 'sequential=', tostring(p.sequentialMode), '\\n',"
        " 'reason=', tostring(p.reason), '\\n')",
    )
    return out["cap"], out["sequential"], out["reason"]


def _kit_split(tmp_path: Path, adapter_class, job_count=2, backend="directml", **extra):
    return _policy(
        tmp_path,
        route="dks_extract",
        stage="stage1_normal",
        backend=backend,
        directmlAdapterClass=adapter_class,
        requestedParallel=True,
        jobCount=job_count,
        cpuCount=16,
        ramGiB=64,
        **extra,
    )


# --- the fix: explicit discrete now matches Auto ------------------------------


def test_kit_split_explicit_discrete_directml_runs_parallel(tmp_path):
    cap, sequential, reason = _kit_split(tmp_path, "discrete")
    assert (cap, sequential) == ("2", "false")
    assert reason == "scheduler_dks_extract_stage1_directml_discrete_cap4"


@pytest.mark.parametrize("jobs, expected_cap", [(2, "2"), (3, "3"), (4, "4"), (6, "4"), (12, "4")])
def test_kit_split_discrete_respects_the_existing_normal_gpu_ceiling(tmp_path, jobs, expected_cap):
    cap, sequential, _ = _kit_split(tmp_path, "discrete", job_count=jobs)
    assert (cap, sequential) == (expected_cap, "false")


def test_explicit_discrete_and_auto_agree_for_the_validated_rx_case(tmp_path):
    """The invariant: same adapter + same workflow => same concurrency policy,
    regardless of how the device was requested."""
    explicit_cap, explicit_sequential, _ = _kit_split(tmp_path, "discrete")
    auto_cap, auto_sequential, _ = _kit_split(tmp_path, "", backend="gpu")
    assert (explicit_cap, explicit_sequential) == (auto_cap, auto_sequential)


# --- protections that must survive --------------------------------------------


@pytest.mark.parametrize("adapter_class", ["integrated", "unknown", "", None])
def test_kit_split_non_discrete_directml_stays_capped_at_one(tmp_path, adapter_class):
    cap, sequential, reason = _kit_split(tmp_path, adapter_class)
    assert (cap, sequential, reason) == ("1", "true", "directml_multi_track")


def test_auto_generic_gpu_path_is_unchanged(tmp_path):
    cap, sequential, reason = _kit_split(tmp_path, "", backend="gpu")
    assert (cap, sequential, reason) == ("2", "false", "scheduler_dks_extract_stage1_normal_gpu_cap4")


@pytest.mark.parametrize(
    "adapter_class, expected",
    [
        ("discrete", ("2", "false", "scheduler_dks_direct_directml_cap4")),
        ("integrated", ("1", "true", "directml_multi_track")),
        ("unknown", ("1", "true", "directml_multi_track")),
    ],
)
def test_direct_kit_policy_is_untouched(tmp_path, adapter_class, expected):
    assert (
        _policy(
            tmp_path,
            route="dks_direct",
            stage="single_stage",
            backend="directml",
            directmlAdapterClass=adapter_class,
            requestedParallel=True,
            jobCount=2,
        )
        == expected
    )


def test_direct_kit_long_workload_variant_is_untouched(tmp_path):
    cap, sequential, reason = _policy(
        tmp_path,
        route="dks_direct",
        backend="directml",
        directmlAdapterClass="discrete",
        requestedParallel=True,
        jobCount=2,
        longWorkload=True,
    )
    assert (cap, sequential, reason) == ("2", "false", "scheduler_dks_direct_directml_long_cap4")


@pytest.mark.parametrize("adapter_class", ["integrated", "unknown", ""])
def test_normal_stems_directml_remains_cap_one(tmp_path, adapter_class):
    """Integrated/unknown DirectML adapters keep the stability cap for Normal
    Stems. A named discrete adapter no longer does -- see
    test_normal_stems_discrete_directml_matches_auto_parallel_cap below."""
    cap, sequential, reason = _policy(
        tmp_path,
        route="normal",
        backend="directml",
        directmlAdapterClass=adapter_class,
        requestedParallel=True,
        jobCount=2,
    )
    assert (cap, sequential, reason) == ("1", "true", "directml_multi_track")


def test_normal_stems_discrete_directml_matches_auto_parallel_cap(tmp_path):
    """Explicit Normal Stems selection of a named discrete adapter (e.g. RX
    9070) must resolve to the same parallel cap Auto already uses for that
    adapter via the generic GPU branch -- selecting the identical adapter
    explicitly must not be slower than Auto for identical execution."""
    cap, sequential, reason = _policy(
        tmp_path,
        route="normal",
        backend="directml",
        directmlAdapterClass="discrete",
        requestedParallel=True,
        jobCount=2,
    )
    assert (cap, sequential, reason) == ("2", "false", "scheduler_normal_directml_discrete_cap4")


@pytest.mark.parametrize("adapter_class", ["discrete", "integrated", "unknown"])
def test_single_item_and_user_sequential_unchanged(tmp_path, adapter_class):
    single = _kit_split(tmp_path, adapter_class, job_count=1)
    assert single == ("nil", "true", "user_parallel")
    sequential = _policy(
        tmp_path,
        route="dks_extract",
        backend="directml",
        directmlAdapterClass=adapter_class,
        requestedParallel=False,
        jobCount=2,
    )
    assert sequential == ("nil", "true", "user_sequential")


@pytest.mark.parametrize(
    "route, backend, extra, expected",
    [
        ("dks_extract", "cpu", {}, ("2", "false", "scheduler_dks_extract_stage1_normal_cpu_cap2")),
        ("dks_extract", "mps", {"requestedDevice": "mps"}, ("1", "true", "scheduler_dks_extract_mps_sequential")),
        ("dks_extract", "gpu", {"drumsepStage2SchedulerBackend": "cuda"}, ("2", "false", "scheduler_dks_extract_stage1_windows_cuda_cap2")),
        ("dks_direct", "cpu", {}, ("2", "false", "scheduler_dks_direct_cpu_cap2")),
        ("dks_direct", "gpu", {}, ("2", "false", "scheduler_dks_direct_gpu_cap4")),
        ("normal", "gpu", {}, ("2", "false", "scheduler_normal_gpu_cap4")),
        ("normal", "cpu", {}, ("2", "false", "scheduler_normal_cpu_cap2")),
        ("normal", "mps", {}, ("2", "false", "scheduler_normal_mps_cap2")),
    ],
)
@pytest.mark.parametrize("adapter_class", ["discrete", "integrated"])
def test_other_backends_ignore_the_directml_adapter_class(tmp_path, route, backend, extra, expected, adapter_class):
    assert (
        _policy(
            tmp_path,
            route=route,
            backend=backend,
            directmlAdapterClass=adapter_class,
            requestedParallel=True,
            jobCount=2,
            cpuCount=16,
            ramGiB=64,
            **extra,
        )
        == expected
    )


# --- classifier must not widen to other vendors -------------------------------


@pytest.mark.parametrize(
    "name, expected",
    [
        ("AMD Radeon RX 9070", "discrete"),
        ("AMD Radeon RX 7900 XTX", "discrete"),
        ("AMD Radeon 780M Graphics", "integrated"),
        ("Intel(R) Arc(TM) A770 Graphics", "integrated"),
        ("Intel(R) Arc(TM) A770", "unknown"),
        ("Intel(R) UHD Graphics 770", "integrated"),
        ("NVIDIA GeForce RTX 4070", "unknown"),
        ("AMD Radeon Pro W7900", "unknown"),
        ("", "unknown"),
    ],
)
def test_classifier_behaviour_is_unchanged_and_vendor_narrow(tmp_path, name, expected):
    """Pins the pre-P1d classifier exactly: only AMD 'Radeon RX' names reach
    'discrete', so P1d cannot silently grant parallel DirectML to Intel or
    NVIDIA adapters."""
    out = _run_lua(tmp_path, f'io.write("class=", _sep.classifyDirectmlSchedulerAdapter("{name}"), "\\n")')
    assert out["class"] == expected


def test_classifier_source_is_untouched_by_this_slice():
    text = STEMWERK_LUA.read_text(encoding="utf-8")
    body = _lua_block(text, "_sep.classifyDirectmlSchedulerAdapter = function(name)")
    assert 'if lower:find("graphics", 1, true) then return "integrated" end' in body
    assert 'if lower:find("radeon", 1, true) and lower:find("%f[%w]rx%f[%W]") then return "discrete" end' in body
    assert body.count("return") == 4, "classifier gained or lost a branch"


# --- stage 2 stays serialized -------------------------------------------------


def test_kit_split_stage_two_is_capped_independently_of_this_change():
    """Stage 2 concurrency lives in the Python caller, not in the Lua policy
    this slice edits, so DrumSep cannot be parallelized by it."""
    caller = CALLER_PY.read_text(encoding="utf-8")
    assert 'return requested_cap, raw_cap, applied_cap, "directml_fixed_cap1", env_name' in caller
    lua = STEMWERK_LUA.read_text(encoding="utf-8")
    block = lua[lua.index('    if backend == "directml" then') :]
    block = block[: block.index('    if backend == "mps" then')]
    assert "stage2" not in block.lower(), "the edited branch must not reason about stage 2 at all"
