"""Windows DirectML: Direct Kit must not run DrumSep jobs in parallel on an
integrated DirectML adapter.

Real-hardware evidence (Ryzen 7 7840HS, RX 9070 = directml:0, Radeon 780M =
directml:1): with explicit directml:1, every Direct Kit run at the scheduler's
DirectML parallel cap 2 lost the device in at least one job ("The GPU will not
respond to more commands", 5 of 8 jobs over 4 runs), while every sequential or
single-item 780M run, Kit Split stage 2 (cap 1), and RX 9070 at cap 2 passed.

Direct Kit was the only DirectML route that ran in parallel: Normal Stems and
Kit Split already use the "directml_multi_track" stability cap of 1. The device
probe exposes only adapter names for DirectML (no memory size or adapter
type), so Direct Kit now keeps its parallel cap only when the adapter it will
run on is positively named as a discrete GPU; everything else falls back to
the existing stability cap.

These tests run the real scheduler functions, extracted verbatim from
STEMwerk.lua, under a Lua interpreter.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
STEMWERK_LUA = ROOT / "scripts" / "reaper" / "STEMwerk.lua"

LUA = shutil.which("lua5.4") or shutil.which("lua5.3") or shutil.which("lua") or shutil.which("luajit")
pytestmark = pytest.mark.skipif(LUA is None, reason="no lua interpreter available on this host")

RX_9070 = "AMD Radeon RX 9070"
RADEON_780M = "AMD Radeon 780M Graphics"

_TOKEN_RE = re.compile(
    r'--\[(=*)\[|--.*|\[(=*)\[|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|\b(function|if|for|while|end)\b'
)


def _lua_block(source: str, start_marker: str) -> str:
    """Extract a function definition starting at start_marker by matching
    function/if/for/while ... end nesting, skipping strings and comments."""
    start = source.index(start_marker)
    pos = start
    depth = 0
    opened = False
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
    script = tmp_path / "scheduler_harness.lua"
    script.write_text(
        'OS = "Windows"\n_sep = {}\n'
        + _scheduler_source()
        + "\n"
        + "local function emit(key, value) io.write(key, '=', tostring(value), '\\n') end\n"
        + body,
        encoding="utf-8",
    )
    proc = subprocess.run([LUA, str(script)], capture_output=True, text=True, timeout=30)
    assert proc.returncode == 0, proc.stderr
    result = {}
    for line in proc.stdout.splitlines():
        key, _, value = line.partition("=")
        result[key] = value
    return result


def _lua_str(value) -> str:
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def _policy(tmp_path: Path, **opts) -> dict[str, str]:
    fields = ", ".join(f"{key} = {_lua_str(value)}" for key, value in opts.items())
    return _run_lua(
        tmp_path,
        f"local p = _sep.resolveSchedulerConcurrencyPolicy({{ {fields} }})\n"
        "emit('cap', p.cap)\nemit('sequential', p.sequentialMode)\nemit('reason', p.reason)\n"
        "emit('backend', p.backend)\nemit('route', p.route)\n",
    )


def _host_devices_lua(*directml: tuple[str, str]) -> str:
    rows = [
        '{ id = "auto", name = "Auto", type = "auto" }',
        '{ id = "cpu", name = "CPU", type = "cpu" }',
    ]
    for dev_id, name in directml:
        short = name.replace("AMD Radeon ", "").replace(" Graphics", "")
        rows.append(
            f'{{ id = {_lua_str(dev_id)}, name = {_lua_str(name)}, fullName = {_lua_str(name)}, '
            f'uiName = {_lua_str(short)}, type = "directml" }}'
        )
    return "{ " + ", ".join(rows) + " }"


# --- adapter classification ---------------------------------------------------


@pytest.mark.parametrize(
    "name, expected",
    [
        (RX_9070, "discrete"),
        ("AMD Radeon RX 7900 XTX", "discrete"),
        ("AMD Radeon RX 7600M XT", "discrete"),
        ("AMD Radeon(TM) RX 6500 XT", "discrete"),
        (RADEON_780M, "integrated"),
        ("AMD Radeon 760M Graphics", "integrated"),
        ("AMD Radeon(TM) Graphics", "integrated"),
        ("AMD Radeon(TM) RX Vega 11 Graphics", "integrated"),
        ("Intel(R) UHD Graphics 770", "integrated"),
        ("Intel(R) Iris(R) Xe Graphics", "integrated"),
        ("Intel(R) Arc(TM) A770 Graphics", "integrated"),
        ("NVIDIA GeForce RTX 4070", "unknown"),
        ("AMD Radeon Pro W7900", "unknown"),
        ("Radeon Proxima", "unknown"),
        ("DirectML 0", "unknown"),
        ("DirectML GPU 1", "unknown"),
        ("", "unknown"),
    ],
)
def test_classify_directml_scheduler_adapter(tmp_path, name, expected):
    out = _run_lua(tmp_path, f"emit('class', _sep.classifyDirectmlSchedulerAdapter({_lua_str(name)}))\n")
    assert out["class"] == expected


# --- which adapter a DirectML run targets -------------------------------------


@pytest.mark.parametrize(
    "requested, expected_id, expected_name",
    [
        ("directml:0", "directml:0", RX_9070),
        ("directml:1", "directml:1", RADEON_780M),
        ("auto", "directml:0", RX_9070),
        ("directml:5", "", ""),
        ("cpu", "", ""),
        ("cuda:0", "", ""),
    ],
)
def test_resolve_adapter_on_rx9070_plus_780m_host(tmp_path, requested, expected_id, expected_name):
    devices = _host_devices_lua(("directml:0", RX_9070), ("directml:1", RADEON_780M))
    out = _run_lua(
        tmp_path,
        f"local id, name = _sep.resolveDirectmlSchedulerAdapter({_lua_str(requested)}, {devices})\n"
        "emit('id', id)\nemit('name', name)\n",
    )
    assert out["id"] == expected_id, "explicit adapter identity must be preserved, never remapped"
    assert out["name"] == expected_name


def test_resolve_adapter_uses_full_name_not_short_ui_label(tmp_path):
    devices = (
        '{ { id = "directml:1", name = "raw", fullName = "AMD Radeon 780M Graphics", uiName = "780M", type = "directml" } }'
    )
    out = _run_lua(
        tmp_path,
        f'local id, name = _sep.resolveDirectmlSchedulerAdapter("directml:1", {devices})\nemit("name", name)\n',
    )
    assert out["name"] == RADEON_780M


def test_resolve_adapter_single_unindexed_directml_device(tmp_path):
    devices = _host_devices_lua(("directml", RADEON_780M))
    out = _run_lua(
        tmp_path,
        f"local a = {{ _sep.resolveDirectmlSchedulerAdapter('auto', {devices}) }}\n"
        f"local b = {{ _sep.resolveDirectmlSchedulerAdapter('directml', {devices}) }}\n"
        "emit('auto_id', a[1])\nemit('auto_name', a[2])\nemit('bare_id', b[1])\n",
    )
    assert out["auto_id"] == "directml"
    assert out["auto_name"] == RADEON_780M
    assert out["bare_id"] == "directml"


# --- Direct Kit DirectML cap ---------------------------------------------------


def _dks_direct_directml(tmp_path, adapter_class, job_count=2, **extra):
    return _policy(
        tmp_path,
        route="dks_direct",
        stage="single_stage",
        backend="directml",
        directmlAdapterClass=adapter_class,
        requestedParallel=True,
        jobCount=job_count,
        cpuCount=16,
        ramGiB=64,
        **extra,
    )


@pytest.mark.parametrize("adapter_class", ["integrated", "unknown", "", None])
def test_direct_kit_non_discrete_directml_is_capped_to_one(tmp_path, adapter_class):
    out = _dks_direct_directml(tmp_path, adapter_class)
    assert out["cap"] == "1"
    assert out["sequential"] == "true"
    assert out["reason"] == "directml_multi_track", "reuses the existing DirectML stability mode"
    assert out["backend"] == "directml"


def test_direct_kit_non_discrete_directml_cap_holds_for_long_and_large_batches(tmp_path):
    out = _dks_direct_directml(tmp_path, "integrated", job_count=6, longWorkload=True)
    assert (out["cap"], out["sequential"], out["reason"]) == ("1", "true", "directml_multi_track")


@pytest.mark.parametrize(
    "job_count, long_workload, cap, reason",
    [
        (2, False, "2", "scheduler_dks_direct_directml_cap4"),
        (4, False, "4", "scheduler_dks_direct_directml_cap4"),
        (6, False, "4", "scheduler_dks_direct_directml_cap4"),
        (2, True, "2", "scheduler_dks_direct_directml_long_cap4"),
    ],
)
def test_direct_kit_discrete_directml_keeps_existing_parallel_cap(tmp_path, job_count, long_workload, cap, reason):
    out = _dks_direct_directml(tmp_path, "discrete", job_count=job_count, longWorkload=long_workload)
    assert (out["cap"], out["sequential"], out["reason"]) == (cap, "false", reason)


@pytest.mark.parametrize("adapter_class", ["discrete", "integrated", "unknown"])
def test_single_item_and_user_sequential_are_unchanged(tmp_path, adapter_class):
    single = _dks_direct_directml(tmp_path, adapter_class, job_count=1)
    assert (single["cap"], single["sequential"], single["reason"]) == ("nil", "true", "user_parallel")
    sequential = _policy(
        tmp_path,
        route="dks_direct",
        backend="directml",
        directmlAdapterClass=adapter_class,
        requestedParallel=False,
        jobCount=2,
    )
    assert (sequential["cap"], sequential["sequential"], sequential["reason"]) == ("nil", "true", "user_sequential")


# --- other DirectML routes and non-DirectML backends are unaffected ------------


@pytest.mark.parametrize(
    "route, adapter_class",
    [
        # normal + discrete and dks_extract + discrete are both deliberately
        # excluded: an explicitly-selected named discrete adapter now matches
        # the cap Auto already used for the identical execution (see
        # test_normal_discrete_directml_matches_auto_parallel_cap below and
        # test_windows_dks_extract_directml_discrete_cap).
        ("normal", "integrated"),
        ("normal", "unknown"),
        ("dks_extract", "integrated"),
        ("dks_extract", "unknown"),
    ],
)
def test_normal_and_kit_split_directml_stay_on_stability_cap(tmp_path, route, adapter_class):
    out = _policy(tmp_path, route=route, backend="directml", directmlAdapterClass=adapter_class, requestedParallel=True, jobCount=2)
    assert (out["cap"], out["sequential"], out["reason"]) == ("1", "true", "directml_multi_track")


@pytest.mark.parametrize(
    "job_count, cap",
    [(2, "2"), (4, "4"), (6, "4")],
)
def test_normal_discrete_directml_matches_auto_parallel_cap(tmp_path, job_count, cap):
    """Explicit Normal Stems selection of a named discrete DirectML adapter
    (e.g. an AMD RX 9070) must resolve to the same parallel cap Auto already
    uses for that adapter via the generic GPU branch, not the generic
    single-adapter stability fallback. Mirrors the existing dks_extract
    discrete-adapter carve-out one block above."""
    out = _policy(
        tmp_path,
        route="normal",
        backend="directml",
        directmlAdapterClass="discrete",
        requestedParallel=True,
        jobCount=job_count,
    )
    assert (out["cap"], out["sequential"], out["reason"]) == (
        cap,
        "false",
        "scheduler_normal_directml_discrete_cap4",
    )


@pytest.mark.parametrize(
    "route, backend, extra, cap, sequential, reason",
    [
        ("dks_direct", "gpu", {}, "2", "false", "scheduler_dks_direct_gpu_cap4"),
        ("dks_direct", "gpu", {"drumsepSchedulerBackend": "cuda"}, "2", "false", "scheduler_dks_direct_windows_cuda_cap2"),
        ("dks_direct", "cpu", {}, "2", "false", "scheduler_dks_direct_cpu_cap2"),
        ("dks_direct", "mps", {}, "2", "true", "scheduler_mps_conservative"),
        ("normal", "gpu", {}, "2", "false", "scheduler_normal_gpu_cap4"),
        ("normal", "cpu", {}, "2", "false", "scheduler_normal_cpu_cap2"),
        ("normal", "mps", {}, "2", "false", "scheduler_normal_mps_cap2"),
        ("dks_extract", "gpu", {}, "2", "false", "scheduler_dks_extract_stage1_normal_gpu_cap4"),
        ("dks_extract", "cpu", {}, "2", "false", "scheduler_dks_extract_stage1_normal_cpu_cap2"),
        ("dks_extract", "mps", {"requestedDevice": "mps"}, "1", "true", "scheduler_dks_extract_mps_sequential"),
    ],
)
@pytest.mark.parametrize("adapter_class", ["integrated", "unknown"])
def test_cpu_cuda_rocm_mps_scheduling_ignores_directml_adapter_class(
    tmp_path, route, backend, extra, cap, sequential, reason, adapter_class
):
    out = _policy(
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
    assert (out["cap"], out["sequential"], out["reason"]) == (cap, sequential, reason)


# --- end to end on the validated hardware layout -------------------------------


@pytest.mark.parametrize(
    "devices, requested, cap, reason",
    [
        ((("directml:0", RX_9070), ("directml:1", RADEON_780M)), "directml:0", "2", "scheduler_dks_direct_directml_cap4"),
        ((("directml:0", RX_9070), ("directml:1", RADEON_780M)), "directml:1", "1", "directml_multi_track"),
        ((("directml:0", RX_9070), ("directml:1", RADEON_780M)), "auto", "2", "scheduler_dks_direct_directml_cap4"),
        ((("directml", RADEON_780M),), "auto", "1", "directml_multi_track"),
        ((("directml", RX_9070),), "auto", "2", "scheduler_dks_direct_directml_cap4"),
    ],
    ids=["rx9070_explicit", "780m_explicit", "auto_on_dual_gpu_host", "auto_on_780m_only_host", "auto_on_rx9070_only_host"],
)
def test_direct_kit_scheduling_on_real_device_layouts(tmp_path, devices, requested, cap, reason):
    out = _run_lua(
        tmp_path,
        f"local _, name = _sep.resolveDirectmlSchedulerAdapter({_lua_str(requested)}, {_host_devices_lua(*devices)})\n"
        "local p = _sep.resolveSchedulerConcurrencyPolicy({ route = 'dks_direct', stage = 'single_stage', "
        "backend = 'directml', directmlAdapterClass = _sep.classifyDirectmlSchedulerAdapter(name), "
        f"requestedDevice = {_lua_str(requested)}, requestedParallel = true, jobCount = 2 }})\n"
        "emit('cap', p.cap)\nemit('reason', p.reason)\n",
    )
    assert (out["cap"], out["reason"]) == (cap, reason)


def test_call_site_classifies_the_run_device_and_logs_it():
    text = STEMWERK_LUA.read_text(encoding="utf-8")
    call = text[text.index("local directmlSchedulerAdapterId, directmlSchedulerAdapterName, directmlSchedulerAdapterClass") :]
    call = call[: call.index("longWorkload = _sep.schedulerHasLongWorkload")]
    assert 'if schedulerBackend == "directml"' in call
    # Normal Stems Auto is classified generic "gpu" (classifySchedulerBackend
    # cannot see which concrete device Auto will resolve to), so the adapter
    # must also be resolved for route == "normal" + backend == "gpu", or Auto
    # never learns whether it landed on a discrete or integrated adapter.
    assert 'or (schedulerRoute == "normal" and schedulerBackend == "gpu")' in call
    assert "_sep.resolveDirectmlSchedulerAdapter(effectiveRunDevice(), RUNTIME_DEVICES or DEVICES)" in call
    assert "directmlAdapterClass = directmlSchedulerAdapterClass," in call
    assert "directmlSchedulerAdapterId = directmlSchedulerAdapterId," in call
    for key in (
        "scheduler_policy_directml_adapter=",
        "scheduler_policy_directml_adapter_name=",
        "scheduler_policy_directml_adapter_class=",
    ):
        assert key in text
