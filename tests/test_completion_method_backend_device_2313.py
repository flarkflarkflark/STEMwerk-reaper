"""Completion reporting must describe CPU vs GPU as the Method, name the
implementation as the Backend, and only ever show a Device it actually knows.

Before this slice the single-item path collapsed the resolved backend label to
a bare "GPU"/"CPU" while the multi-item path printed the backend label itself as
the Method, so the very same run reported "Method: GPU" or "Method: DirectML"
purely depending on how many items were selected.

Both paths now read one resolver, so:
    Method: GPU | Backend: DirectML | Device: AMD Radeon RX 9070
and CPU stays a bare "Method: CPU" with no Backend line -- a CPU-via-DirectML or
CPU-via-ROCm fallback must never claim an accelerator it did not use.

Device is deliberately omitted unless a trustworthy friendly name exists: the
DrumSep helper reports no adapter name at all, so anything empty, a bare device
id echo, or a generic placeholder is dropped rather than guessed at.

The Lua under test is extracted verbatim from production by function name (the
same declaration-anchored technique as the DrumSep reporting tests).
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
MAIN_LUA = ROOT / "scripts" / "reaper" / "STEMwerk.lua"

LUA = shutil.which("lua5.4") or shutil.which("lua5.3") or shutil.which("lua") or shutil.which("luajit")
pytestmark = pytest.mark.skipif(LUA is None, reason="no lua interpreter available")


def _declaration_index(lines: list[str], name: str) -> int:
    prefixes = (f"function {name}(", f"local function {name}(")
    for index, line in enumerate(lines):
        if line.startswith(prefixes):
            return index
    raise AssertionError(f"no top-level declaration of {name}() in {MAIN_LUA.name}")


def _extract_lua_span(text: str, first_name: str, last_name: str) -> str:
    lines = text.splitlines(keepends=True)
    start = _declaration_index(lines, first_name)
    last_start = _declaration_index(lines, last_name)
    assert last_start >= start, f"{last_name}() is declared before {first_name}()"
    for index in range(last_start + 1, len(lines)):
        if lines[index].rstrip("\r\n") == "end":
            return "".join(lines[start : index + 1])
    raise AssertionError(f"no column-0 'end' terminates {last_name}()")


def _extract_lua_function(text: str, name: str) -> str:
    return _extract_lua_span(text, name, name)


T_STUB = """
function T(key) return nil end
function trSafeValue(key, fallback)
    local v = T(key)
    if not v or v == "" then return fallback end
    local raw = tostring(key or "")
    local value = tostring(v)
    if value == raw or value == raw:gsub("_", " ") then return fallback end
    return value
end
"""


def _harness(driver: str) -> str:
    src = MAIN_LUA.read_text(encoding="utf-8", errors="replace")
    return "\n".join(
        [
            T_STUB,
            _extract_lua_function(src, "formatUserFacingProcessingDeviceLabel"),
            _extract_lua_span(src, "sanitizeUserFacingMethodLabel", "resolveSingleTrackMethodLabel"),
            _extract_lua_function(src, "resultMethodReportingText"),
            _extract_lua_function(src, "formatFailedJobIndices"),
            _extract_lua_function(src, "failedJobsLine"),
            _extract_lua_function(src, "dksSeparationFailureTitle"),
            driver,
        ]
    )


def _run(driver: str) -> str:
    assert LUA is not None
    done = subprocess.run([LUA, "-"], input=_harness(driver), text=True, capture_output=True, timeout=20)
    assert done.returncode == 0, done.stderr
    # rstrip only: the Method suffix is intentionally " | Method: ..." with a
    # leading space, so stripping both ends would hide a real formatting change.
    return done.stdout.rstrip("\r\n")


def _lua_table(fields: dict[str, str]) -> str:
    inner = ", ".join(f'{k} = "{v}"' for k, v in fields.items())
    return "{ " + inner + " }"


def _triple(**fields: str) -> tuple[str, str, str]:
    out = _run(
        f"local m, b, d = resolveResultReportingTriple({_lua_table(fields)})\n"
        'print(m .. "|" .. b .. "|" .. d)'
    )
    method, backend, device = out.split("|")
    return method, backend, device


# --- Method + Backend per accelerator ----------------------------------------


@pytest.mark.parametrize(
    "fields, backend",
    [
        ({"backendRuntime": "directml", "effectiveDevice": "privateuseone:0"}, "DirectML"),
        ({"backend": "directml"}, "DirectML"),
        ({"runtimeSelected": "cuda", "effectiveDevice": "cuda:0"}, "NVIDIA CUDA"),
        ({"backendRuntime": "cuda:0"}, "NVIDIA CUDA"),
        ({"runtimeSelected": "rocm"}, "AMD ROCm"),
        ({"backendRuntime": "rocm", "effectiveDevice": "cuda:0"}, "AMD ROCm"),
        ({"runtimeSelected": "mps"}, "Apple MPS"),
    ],
    ids=["directml", "directml-backend", "cuda", "cuda-indexed", "rocm", "rocm-over-hip-alias", "mps"],
)
def test_gpu_backends_report_method_gpu_and_their_backend(fields, backend):
    method, resolved_backend, _device = _triple(**fields)
    assert method == "GPU", "Method must describe CPU vs GPU, not the implementation"
    assert resolved_backend == backend


@pytest.mark.parametrize(
    "fields",
    [
        {"backendRuntime": "cpu"},
        {"runtimeSelected": "cpu", "backend": "cpu"},
        # CPU served from a GPU-capable runtime: the historic mis-reporting risk.
        {"runtimeSelected": "cpu", "backendRuntime": "cpu", "effectiveDevice": "cpu", "deviceRequest": "cpu"},
    ],
    ids=["cpu", "cpu-explicit", "cpu-via-gpu-capable-runtime"],
)
def test_cpu_reports_method_cpu_with_no_backend_and_no_device(fields):
    method, backend, device = _triple(**fields)
    assert method == "CPU"
    assert backend == "", "CPU must never claim an accelerator backend"
    assert device == ""


def test_generic_gpu_intent_reports_gpu_without_inventing_a_backend():
    method, backend, _device = _triple(backend="gpu")
    assert method == "GPU"
    assert backend == "", "a generic GPU intent is not evidence of a specific backend"


def test_absent_metadata_reports_nothing_at_all():
    assert _triple() == ("", "", "")


# --- Device trust -------------------------------------------------------------


@pytest.mark.parametrize(
    "device_name",
    ["AMD Radeon RX 9070", "AMD Radeon 780M Graphics", "NVIDIA GeForce RTX 4070", "Apple M1 Max"],
)
def test_trustworthy_device_name_is_shown(device_name):
    _method, _backend, device = _triple(backendRuntime="directml", deviceName=device_name)
    assert device == device_name


@pytest.mark.parametrize(
    "device_name",
    ["", "   ", "gpu", "GPU 0", "DirectML 0", "DirectML GPU 1", "directml:1", "cuda:0", "privateuseone:0", "auto", "cpu"],
)
def test_untrustworthy_device_names_are_never_shown(device_name):
    _method, _backend, device = _triple(backendRuntime="directml", deviceName=device_name)
    assert device == "", f"{device_name!r} is not a real adapter name and must not be presented as one"


def test_drumsep_style_run_without_device_name_shows_backend_but_no_device():
    method, backend, device = _triple(backendRuntime="directml", runtimeSelected="directml")
    assert (method, backend, device) == ("GPU", "DirectML", "")


# --- single-item and multi-item agree -----------------------------------------


def test_single_item_method_matches_the_shared_resolver():
    """resolveSingleTrackMethodLabel is what the single-item branch prints; it
    must now be exactly the Method of the shared triple, not a separate rule."""
    out = _run(
        'local data = { backendRuntime = "directml", deviceName = "AMD Radeon RX 9070" }\n'
        "local single = resolveSingleTrackMethodLabel(data)\n"
        "local method = resolveResultReportingTriple(data)\n"
        'print(single .. "|" .. method)'
    )
    single, method = out.split("|")
    assert single == method == "GPU"


def test_rendered_suffix_and_detail_are_shared_by_every_branch():
    out = _run(
        'local suffix, detail = resultMethodReportingText({ backendRuntime = "directml",'
        ' deviceName = "AMD Radeon RX 9070" })\n'
        'print(suffix .. "@@" .. detail)'
    )
    suffix, detail = out.split("@@")
    assert suffix == " | Method: GPU"
    assert detail == "Backend: DirectML | Device: AMD Radeon RX 9070"


def test_cpu_renders_no_detail_line():
    out = _run('local s, d = resultMethodReportingText({ backendRuntime = "cpu" })\nprint(s .. "@@" .. d)')
    suffix, detail = out.split("@@")
    assert suffix == " | Method: CPU"
    assert detail == "", "CPU must not emit a Backend/Device line"


def test_backend_without_device_renders_backend_only():
    out = _run('local s, d = resultMethodReportingText({ runtimeSelected = "rocm" })\nprint(s .. "@@" .. d)')
    suffix, detail = out.split("@@")
    assert suffix == " | Method: GPU"
    assert detail == "Backend: AMD ROCm"


def test_all_completion_branches_use_the_shared_reporting_helper():
    src = MAIN_LUA.read_text(encoding="utf-8")
    body = src[src.index("function buildResultMessageLines()") :]
    body = body[: body.index("\ndrawGlossyPill")]
    assert body.count("resultMethodReportingText(data)") == 3, (
        "multi_new_tracks, multi_in_place and single must all use the shared helper"
    )
    assert "resolveResultMethodLabel(data)" not in body, "no branch may bypass the shared helper"


# --- failed job ids -----------------------------------------------------------


@pytest.mark.parametrize(
    "raw, expected",
    [("2", "Failed job: #2"), ("1", "Failed job: #1"), ("1,2", "Failed jobs: #1, #2"), ("1,2,5", "Failed jobs: #1, #2, #5")],
)
def test_failed_job_ids_render_with_hash_and_correct_plural(raw, expected):
    assert _run(f'print(failedJobsLine("{raw}"))') == expected


def test_failed_job_line_is_empty_when_nothing_failed():
    assert _run('print("[" .. failedJobsLine("") .. "]")') == "[]"


def test_failed_job_ids_keep_their_raw_order_and_values():
    assert _run('local ids, n = formatFailedJobIndices("3,1")\nprint(ids .. "|" .. n)') == "#3, #1|2"


# --- workflow-specific failure titles -----------------------------------------


@pytest.mark.parametrize(
    "lower_log, is_direct_cmd, expected",
    [
        ("workflow_source=dks_direct\nerror_reason=drumsep_separate_failed", "false", "Direct Kit separation failed."),
        ("workflow_source=dks_extract\nerror_reason=drumsep_separate_failed", "false", "Kit Split separation failed."),
        # Windows/sh wrappers can omit the source inline; the command line covers it.
        ("error_reason=drumsep_separate_failed", "true", "Direct Kit separation failed."),
        ("error_reason=drumsep_separate_failed", "false", "Drum Kit separation failed."),
    ],
    ids=["direct-from-log", "kit-split-from-log", "direct-from-cmdline", "unknown-workflow"],
)
def test_failure_title_names_the_workflow_actually_run(lower_log, is_direct_cmd, expected):
    escaped = lower_log.replace("\n", "\\n")
    assert _run(f'print(dksSeparationFailureTitle("{escaped}", {is_direct_cmd}))') == expected


def test_direct_kit_failure_never_says_drum_kit_split():
    title = _run('print(dksSeparationFailureTitle("workflow_source=dks_direct", false))')
    assert "Drum Kit Split" not in title


def test_production_failure_branch_uses_the_workflow_aware_title():
    src = MAIN_LUA.read_text(encoding="utf-8")
    assert '"Drum Kit Split separation failed.\\n"' not in src, "the hardcoded generic title must be gone"
    assert "dksSeparationFailureTitle(lowerLog, isDirectDksCmd)" in src


# --- localization -------------------------------------------------------------

LANG_COPIES = (ROOT / "scripts" / "reaper" / "i18n" / "languages.lua", ROOT / "i18n" / "languages.lua")
NEW_KEYS = ("result_backend_line", "result_device_line", "dks_multi_failed_job_one")


@pytest.mark.parametrize("key", NEW_KEYS)
def test_new_keys_exist_in_all_three_languages(key):
    text = LANG_COPIES[0].read_text(encoding="utf-8")
    assert text.count(f"{key} = ") == 3, f"{key} must be defined for en, nl and de"


@pytest.mark.parametrize("key", NEW_KEYS + ("result_method_line", "mode_reason_label"))
def test_changed_keys_keep_their_format_placeholder_contract(key):
    text = LANG_COPIES[0].read_text(encoding="utf-8")
    values = re.findall(rf'{key} = "([^"]*)"', text)
    assert len(values) == 3
    placeholders = {value.count("%s") for value in values}
    assert len(placeholders) == 1, f"{key} has inconsistent %s placeholders across languages: {values}"


def test_mode_reason_label_no_longer_collides_with_the_backend_line():
    """The reason line used to be labelled "Backend", which would now read as a
    second, contradictory Backend line next to the real one."""
    text = LANG_COPIES[0].read_text(encoding="utf-8")
    assert re.findall(r'mode_reason_label = "([^"]*)"', text).count("Backend") == 0


def test_both_language_copies_stay_byte_identical():
    first, second = (path.read_bytes() for path in LANG_COPIES)
    assert first == second, "scripts/reaper/i18n/languages.lua and i18n/languages.lua must not drift"
