"""Behavioral contracts for the no-download B0 model preflight.

Normal Demucs descriptor files are small metadata documents.  Their validity
is determined by the model references they contain, not an arbitrary byte
floor.  Weight files and the Direct Kit assets retain their existing size
guards.
"""

import json
import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
MAIN_LUA = ROOT / "scripts" / "reaper" / "STEMwerk.lua"
LUA = shutil.which("lua") or shutil.which("lua5.4") or shutil.which("luajit")

NORMAL_WEIGHT = "955717e8-8726e21a.th"
QUALITY_WEIGHTS = (
    "f7e0c4bc-ba3fe64a.th",
    "d12395a8-e57c48e6.th",
    "92cfc3b6-ef3bcb9c.th",
    "04573f0d-f3cf25b2.th",
)
DIRECT_CKPT = "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt"
DIRECT_YAML = "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"


def _b0_source() -> str:
    source = MAIN_LUA.read_text(encoding="utf-8", errors="replace")
    start = source.index("local function fileSizeBytes(p)")
    end = source.index("local TIMING_UNIX_OFFSET", start)
    return source[start:end]


def _write(path: Path, content: bytes) -> None:
    path.write_bytes(content)


def _run_preflight(
    tmp_path: Path,
    *,
    model: str = "htdemucs",
    workflow_mode: str = "",
    workflow_source: str = "",
) -> tuple[bool, str]:
    if not LUA:
        pytest.skip("no Lua interpreter available")

    harness = f"""
PATH_SEP = "/"
OS = "Linux"
SETTINGS = {{ model = {json.dumps(model)} }}
effectiveRunModel = function() return SETTINGS.model end
getRuntimePaths = function() return nil end
getHome = function() return "" end
local last_detail = ""
SW_LOG = {{
    logExecResult = function(_, _, detail)
        if detail then last_detail = tostring(detail) end
    end
}}
debugLog = function(_) end
showMessage = function(_, _, _, _) end
{_b0_source()}
B0_getDefaultModelCacheDir = function() return {json.dumps(str(tmp_path))} end
local ready = verifyProcessingAssetsReady({{
    workflowMode = {json.dumps(workflow_mode)},
    workflowSource = {json.dumps(workflow_source)},
}})
io.write("READY=" .. tostring(ready) .. "\\n")
io.write("DETAIL=" .. tostring(last_detail) .. "\\n")
"""
    harness_path = tmp_path / "b0_harness.lua"
    harness_path.write_text(harness, encoding="utf-8")
    proc = subprocess.run(
        [LUA, str(harness_path)],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=30,
    )
    output = proc.stdout + proc.stderr
    assert proc.returncode == 0, output
    ready = "READY=true" in output
    detail = next(
        (line.removeprefix("DETAIL=") for line in output.splitlines() if line.startswith("DETAIL=")),
        "",
    )
    return ready, detail


def _install_normal_weight(tmp_path: Path) -> None:
    _write(tmp_path / NORMAL_WEIGHT, b"w" * 1024)


def _install_direct_assets(tmp_path: Path) -> None:
    _write(tmp_path / DIRECT_CKPT, b"c" * 1048576)
    _write(tmp_path / DIRECT_YAML, b"d" * 64)


def test_valid_21_byte_normal_descriptor_is_ready(tmp_path):
    descriptor = b"models: ['955717e8']\n"
    assert len(descriptor) == 21
    _write(tmp_path / "htdemucs.yaml", descriptor)
    _install_normal_weight(tmp_path)

    ready, detail = _run_preflight(tmp_path)

    assert ready, detail


def test_valid_larger_quality_descriptor_is_ready(tmp_path):
    descriptor = (
        b"models: ['f7e0c4bc', 'd12395a8', '92cfc3b6', '04573f0d']\n"
        b"weights: [[1., 0., 0., 0.], [0., 1., 0., 0.]]\n"
    )
    _write(tmp_path / "htdemucs_ft.yaml", descriptor)
    for weight in QUALITY_WEIGHTS:
        _write(tmp_path / weight, b"w" * 1024)

    ready, detail = _run_preflight(tmp_path, model="htdemucs_ft")

    assert ready, detail


@pytest.mark.parametrize(
    ("content", "reason"),
    [
        (None, "descriptor_missing"),
        (b"", "descriptor_empty"),
        (b"this is not a models descriptor, despite being comfortably over sixty-four bytes", "descriptor_malformed"),
        (b"models: ['some_other_model'] # valid-looking but references no installed weight", "descriptor_missing_reference"),
        (b"models: ['955717e8', 'weight_that_is_not_installed']", "descriptor_missing_reference"),
    ],
)
def test_invalid_normal_descriptor_blocks_with_reason(tmp_path, content, reason):
    if content is not None:
        _write(tmp_path / "htdemucs.yaml", content)
    _install_normal_weight(tmp_path)

    ready, detail = _run_preflight(tmp_path)

    assert not ready
    assert reason in detail


def test_missing_normal_weight_still_blocks(tmp_path):
    _write(tmp_path / "htdemucs.yaml", b"models: ['955717e8']")

    ready, detail = _run_preflight(tmp_path)

    assert not ready
    assert "955717e8-8726e21a.th" in detail


def test_direct_kit_size_guards_are_unchanged(tmp_path):
    source = MAIN_LUA.read_text(encoding="utf-8", errors="replace")
    direct_start = source.index("function B0_directKitAssets()")
    direct_end = source.index("\nend", direct_start)
    direct_source = source[direct_start:direct_end]
    assert f'{{ name = "{DIRECT_CKPT}", minBytes = 1048576 }}' in direct_source
    assert f'{{ name = "{DIRECT_YAML}", minBytes = 64 }}' in direct_source

    _write(tmp_path / DIRECT_CKPT, b"c" * 1048576)
    _write(tmp_path / DIRECT_YAML, b"too small")
    ready, _ = _run_preflight(
        tmp_path, workflow_mode="drumkit", workflow_source="direct"
    )
    assert not ready

    _write(tmp_path / DIRECT_YAML, b"d" * 64)
    ready, detail = _run_preflight(
        tmp_path, workflow_mode="drumkit", workflow_source="direct"
    )
    assert ready, detail


def test_kit_split_still_requires_its_stage_two_assets(tmp_path):
    _write(tmp_path / "htdemucs.yaml", b"models: ['955717e8']")
    _install_normal_weight(tmp_path)

    ready, detail = _run_preflight(
        tmp_path, workflow_mode="drumkit", workflow_source="extract"
    )
    assert not ready
    assert DIRECT_CKPT in detail

    _install_direct_assets(tmp_path)
    ready, detail = _run_preflight(
        tmp_path, workflow_mode="drumkit", workflow_source="extract"
    )
    assert ready, detail
