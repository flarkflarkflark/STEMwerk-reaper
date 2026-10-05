"""Normal Stems explicit DirectML selection of a named discrete adapter (e.g.
an AMD RX 9070) must schedule and report identically to Auto resolving to that
same adapter.

Two independent, previously-unfixed defects combined to produce the observed
symptom on real Windows AMD hardware (Ryzen 7840HS, RX 9070 + 780M, DirectML):

1. Scheduling divergence: classifySchedulerBackend returns the generic "gpu"
   for Auto but the specific "directml" for an explicit DirectML selection, so
   Auto never reaches the backend == "directml" branch in
   resolveSchedulerConcurrencyPolicy at all. That branch already had an
   adapter-class-aware carve-out for route == "dks_extract" (Kit Split stage
   1), proving the discrete-vs-integrated distinction was architecturally the
   right layer -- it simply had never been extended to route == "normal"
   (Normal Stems), which fell into the blanket sequential/cap1 "DirectML
   multi-track stability mode" fallback regardless of adapter.

2. Completion mis-reporting: preferredRuntimeSelection() and
   formatUserFacingProcessingDeviceLabel() collect their evidence candidates
   into a Lua table and iterate it with ipairs(). ipairs() stops at the first
   nil it finds counting up from index 1. Normal Stems' own runtime-evidence
   log lines never populate info.runtimeSelected (only
   backend_runtime=<kind>, selected_device=<id> and
   selected_device_name=<name> -- there is no bare runtime_selected= match in
   parseRuntimeMetadataFromLogFile, only the DrumSep-prefixed
   drumsep_runtime_selected=), so that field is always a bare Lua nil in the
   very first candidate slot. ipairs() then stopped before ever examining the
   later slots that did carry the real "directml" evidence, silently
   discarding it and falling back to whatever weaker, generic signal (or none)
   happened to be available -- an entirely different kind of bug from a
   genuinely requested CPU run, and one that fires for Auto too (Auto loses
   its Backend/Device line instead of losing the whole Method), not only for
   the explicit path.

Both fixes are verified here against the real, unmodified production Lua,
extracted verbatim by source position/declaration (same technique as the
sibling DKS/Kit Split scheduler-cap test files), and against real
runtime-evidence log lines captured from an actual separation run on the
validated RX 9070 + 780M hardware (see the Task B investigation notes), not
hand-written approximations of what the log "should" look like.
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


def _declaration_index(lines: list[str], name: str) -> int:
    prefixes = (f"function {name}(", f"local function {name}(")
    for index, line in enumerate(lines):
        if line.startswith(prefixes):
            return index
    raise AssertionError(f"no top-level declaration of {name}() in {STEMWERK_LUA.name}")


def _extract_top_level_function(text: str, name: str) -> str:
    lines = text.splitlines(keepends=True)
    start = _declaration_index(lines, name)
    for index in range(start + 1, len(lines)):
        if lines[index].rstrip("\r\n") == "end":
            return "".join(lines[start : index + 1])
    raise AssertionError(f"no column-0 'end' terminates {name}()")


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
    script = tmp_path / "normalstems_harness.lua"
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


def _policy(tmp_path: Path, **opts) -> tuple[str, str, str, str]:
    fields = ", ".join(f"{k} = {_lua_value(v)}" for k, v in opts.items())
    out = _run_lua(
        tmp_path,
        f"local p = _sep.resolveSchedulerConcurrencyPolicy({{ {fields} }})\n"
        "io.write('cap=', tostring(p.cap), '\\n', 'sequential=', tostring(p.sequentialMode), '\\n',"
        " 'reason=', tostring(p.reason), '\\n', 'backend=', tostring(p.backend), '\\n')",
    )
    return out["cap"], out["sequential"], out["reason"], out["backend"]


def _normal_auto(tmp_path: Path, job_count=2):
    """Auto resolving to a discrete adapter is classified generic "gpu" (the
    real production call site passes effectiveRunDevice(), i.e. the literal
    requested string "auto", through classifySchedulerBackend before Auto is
    ever resolved to a concrete adapter)."""
    return _policy(
        tmp_path,
        route="normal",
        backend="gpu",
        requestedParallel=True,
        jobCount=job_count,
        cpuCount=16,
        ramGiB=64,
    )


def _normal_explicit_directml(tmp_path: Path, adapter_class, job_count=2):
    return _policy(
        tmp_path,
        route="normal",
        backend="directml",
        directmlAdapterClass=adapter_class,
        requestedParallel=True,
        jobCount=job_count,
        cpuCount=16,
        ramGiB=64,
    )


# --- 1 & 2: Auto and explicit RX 9070 share the same concurrency policy ------


@pytest.mark.parametrize("job_count, cap", [(2, "2"), (4, "4"), (6, "4")])
def test_auto_and_explicit_discrete_directml_share_the_same_cap(tmp_path, job_count, cap):
    auto_cap, auto_seq, _auto_reason, _auto_backend = _normal_auto(tmp_path, job_count)
    explicit_cap, explicit_seq, explicit_reason, _explicit_backend = _normal_explicit_directml(
        tmp_path, "discrete", job_count
    )
    assert (auto_cap, auto_seq) == (cap, "false")
    assert (explicit_cap, explicit_seq) == (cap, "false")
    assert explicit_reason == "scheduler_normal_directml_discrete_cap4"


def test_explicit_discrete_directml_is_not_forced_sequential_solely_for_being_explicit(tmp_path):
    cap, sequential, reason, _backend = _normal_explicit_directml(tmp_path, "discrete", job_count=2)
    assert sequential == "false", "explicit selection of the same resolved device must not demote it to sequential"
    assert reason != "directml_multi_track"
    assert cap != "1"


# --- 5: integrated (780M) intentionally stays conservative --------------------


@pytest.mark.parametrize("adapter_class", ["integrated", "unknown"])
def test_integrated_and_unknown_directml_adapters_keep_the_stability_cap(tmp_path, adapter_class):
    """780M (integrated) and any unrecognised adapter are NOT covered by the
    fix: there is no real Auto-resolved-to-780M hardware evidence that an
    integrated DirectML adapter tolerates concurrent Normal Stems jobs, and
    the architecture already treats integrated DirectML adapters cautiously
    elsewhere (Direct Kit's own dks_direct branch above this one). Pinning
    this keeps the fix narrowly scoped to the one adapter class that is
    actually proven safe."""
    cap, sequential, reason, _backend = _normal_explicit_directml(tmp_path, adapter_class, job_count=2)
    assert (cap, sequential, reason) == ("1", "true", "directml_multi_track")


# --- 4: CPU is untouched -------------------------------------------------------


def test_cpu_keeps_its_established_concurrency_policy(tmp_path):
    cap, sequential, reason, _backend = _policy(
        tmp_path,
        route="normal",
        backend="cpu",
        requestedParallel=True,
        jobCount=2,
        cpuCount=16,
        ramGiB=64,
    )
    assert (cap, sequential, reason) == ("2", "false", "scheduler_normal_cpu_cap2")


# --- 6: DKS / Kit Split scheduling is unchanged --------------------------------


def test_direct_kit_discrete_directml_policy_is_unchanged(tmp_path):
    cap, sequential, reason, _backend = _policy(
        tmp_path,
        route="dks_direct",
        backend="directml",
        directmlAdapterClass="discrete",
        requestedParallel=True,
        jobCount=2,
        cpuCount=16,
        ramGiB=64,
    )
    assert (cap, sequential, reason) == ("2", "false", "scheduler_dks_direct_directml_cap4")


def test_kit_split_stage1_discrete_directml_policy_is_unchanged(tmp_path):
    cap, sequential, reason, _backend = _policy(
        tmp_path,
        route="dks_extract",
        stage="stage1_normal",
        backend="directml",
        directmlAdapterClass="discrete",
        requestedParallel=True,
        jobCount=2,
        cpuCount=16,
        ramGiB=64,
    )
    assert (cap, sequential, reason) == ("2", "false", "scheduler_dks_extract_stage1_directml_discrete_cap4")


# --- 3: completion reporting reads the real per-job evidence ------------------
#
# Real stderr lines captured from an actual separation run on the validated
# RX 9070 (directml:0) hardware. backend=gpu is the generic preview line
# printed before the device is bound; backend_runtime/selected_device/
# selected_device_name are StemSeparator's own post-configuration evidence,
# printed last. There is no bare "runtime_selected=" line for Normal Stems.
_REAL_DIRECTML_LOG = """\
normal_workflow_backend_preview_name=AMD Radeon RX 9070
device=directml:0
backend=gpu
STEMWERK_DIAG selected_device=directml:0
STEMWERK_DIAG effective_device=directml:0
runtime_selected=directml
backend_runtime=directml
selected_device=directml:0
selected_device_name=AMD Radeon RX 9070
"""

_REAL_CPU_LOG = """\
device=cpu
backend=cpu
runtime_selected=cpu
backend_runtime=cpu
selected_device=cpu
selected_device_name=CPU
"""


def _reporting_source() -> str:
    text = STEMWERK_LUA.read_text(encoding="utf-8")
    names = [
        "formatUserFacingProcessingDeviceLabel",
        "preferredRuntimeSelection",
        "parseRuntimeMetadataFromLogFile",
        "updateMultiTrackJobRuntimeMetadata",
        "sanitizeUserFacingMethodLabel",
        "resolveResultMethodLabel",
        "resolveResultDeviceName",
        "resolveResultReportingTriple",
    ]
    return "\n".join(_extract_top_level_function(text, name) for name in names)


def _run_reporting(tmp_path: Path, log_text: str, device_request: str) -> tuple[str, str, str]:
    log_path = tmp_path / "separation_log.txt"
    log_path.write_text(log_text, encoding="utf-8", newline="\n")
    script = tmp_path / "reporting_harness.lua"
    log_escaped = str(log_path).replace("\\", "/")
    script.write_text(
        "function T(key) return nil end\n"
        "function trSafeValue(key, fallback) return fallback end\n"
        + _reporting_source()
        + "\n"
        "multiTrackQueue = {}\n"
        f'local job = {{ logFile = "{log_escaped}" }}\n'
        "updateMultiTrackJobRuntimeMetadata(job)\n"
        "local resultData = {\n"
        f'    deviceRequest = "{device_request}",\n'
        "    runtimeSelected = tostring(multiTrackQueue.runtimeSelected or \"\"),\n"
        "    backendRuntime = tostring(multiTrackQueue.backendRuntime or \"\"),\n"
        "    effectiveDevice = tostring(multiTrackQueue.effectiveDevice or \"\"),\n"
        "    deviceName = tostring(multiTrackQueue.deviceName or \"\"),\n"
        "}\n"
        "local method, backend, device = resolveResultReportingTriple(resultData)\n"
        "io.write('method=', method, '\\n', 'backend=', backend, '\\n', 'device=', device, '\\n')\n",
        encoding="utf-8",
    )
    done = subprocess.run([LUA, str(script)], capture_output=True, text=True, timeout=30)
    assert done.returncode == 0, done.stderr
    out = dict(line.split("=", 1) for line in done.stdout.splitlines() if "=" in line)
    return out["method"], out["backend"], out["device"]


def test_real_directml_evidence_reports_gpu_directml_not_cpu(tmp_path):
    method, backend, device = _run_reporting(tmp_path, _REAL_DIRECTML_LOG, "directml:0")
    assert method == "GPU", "a successful DirectML run must never report Method: CPU"
    assert backend == "DirectML"
    assert device == "AMD Radeon RX 9070"


def test_real_cpu_evidence_still_reports_cpu(tmp_path):
    method, backend, device = _run_reporting(tmp_path, _REAL_CPU_LOG, "cpu")
    assert (method, backend, device) == ("CPU", "", "")


def test_auto_and_explicit_report_identically_from_equivalent_evidence(tmp_path):
    """Auto resolving to directml:0 and explicit directml:0 produce the exact
    same per-job log evidence (StemSeparator binds the same resolved device
    either way) and must therefore report identically."""
    auto = _run_reporting(tmp_path, _REAL_DIRECTML_LOG, "auto")
    explicit = _run_reporting(tmp_path, _REAL_DIRECTML_LOG, "directml:0")
    assert auto == explicit == ("GPU", "DirectML", "AMD Radeon RX 9070")
