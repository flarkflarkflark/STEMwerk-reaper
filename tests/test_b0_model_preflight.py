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
SIX_STEM_WEIGHT = "5c90dfd2-34c22ccb.th"
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


def _run_preflight_raw(
    tmp_path: Path,
    *,
    model: str = "htdemucs",
    workflow_mode: str = "",
    workflow_source: str = "",
    use_builder: str | None = None,
) -> dict:
    """Run the real B0 preflight source against a constructed runOptions table.

    By default runOptions is built from the raw workflow_mode/workflow_source
    strings passed in (used to prove legacy/invented literals are rejected).
    Pass use_builder="direct" or "extract" to instead construct runOptions via
    the real scripts/reaper/_internal/STEMwerk_DrumKit_Workflow.lua
    buildDirectRunOptions()/buildExtractRunOptions() production builders, so
    the test drives the actual producer contract rather than a hand-fed
    string. DKS_WORKFLOW is loaded from that same real module (not
    reimplemented here) so the harness's identity comparisons can never drift
    from production.
    """
    if not LUA:
        pytest.skip("no Lua interpreter available")

    if use_builder == "direct":
        options_expr = "DKS_WORKFLOW.buildDirectRunOptions()"
    elif use_builder == "extract":
        options_expr = "DKS_WORKFLOW.buildExtractRunOptions()"
    elif use_builder is not None:
        raise ValueError(f"unknown use_builder={use_builder!r}")
    else:
        options_expr = (
            "{ workflowMode = " + json.dumps(workflow_mode)
            + ", workflowSource = " + json.dumps(workflow_source) + " }"
        )

    harness = f"""
PATH_SEP = "/"
OS = "Linux"
SETTINGS = {{ model = {json.dumps(model)} }}
effectiveRunModel = function() return SETTINGS.model end
getRuntimePaths = function() return nil end
getHome = function() return "" end
local last_message = ""
local last_detail = ""
SW_LOG = {{
    logExecResult = function(msg, _, detail)
        if msg then last_message = tostring(msg) end
        if detail then last_detail = tostring(detail) end
    end
}}
debugLog = function(_) end
showMessage = function(_, _, _, _) end
DKS_WORKFLOW = dofile("scripts/reaper/_internal/STEMwerk_DrumKit_Workflow.lua")
{_b0_source()}
B0_getDefaultModelCacheDir = function() return {json.dumps(str(tmp_path))} end
local runOptions = {options_expr}
local ready = verifyProcessingAssetsReady(runOptions)
io.write("READY=" .. tostring(ready) .. "\\n")
io.write("DETAIL=" .. tostring(last_detail) .. "\\n")
io.write("MESSAGE=" .. tostring(last_message) .. "\\n")
io.write("SOURCE_IS_DIRECT=" .. tostring(runOptions.workflowSource == DKS_WORKFLOW.SOURCE_DIRECT) .. "\\n")
io.write("SOURCE_IS_EXTRACT=" .. tostring(runOptions.workflowSource == DKS_WORKFLOW.SOURCE_EXTRACT) .. "\\n")
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

    def _field(prefix: str) -> str:
        return next(
            (line.removeprefix(prefix) for line in output.splitlines() if line.startswith(prefix)),
            "",
        )

    return {
        "ready": "READY=true" in output,
        "detail": _field("DETAIL="),
        "message": _field("MESSAGE="),
        "source_is_direct": _field("SOURCE_IS_DIRECT=") == "true",
        "source_is_extract": _field("SOURCE_IS_EXTRACT=") == "true",
    }


def _run_preflight(
    tmp_path: Path,
    *,
    model: str = "htdemucs",
    workflow_mode: str = "",
    workflow_source: str = "",
) -> tuple[bool, str]:
    result = _run_preflight_raw(
        tmp_path,
        model=model,
        workflow_mode=workflow_mode,
        workflow_source=workflow_source,
    )
    return result["ready"], result["detail"]


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
    # Matches the real installed htdemucs_ft.yaml shape exactly: one bracketed,
    # comma-terminated weight row per declared model (4 models -> 4 rows), each
    # row as wide as every other row. The previous single-line, 2-row fixture
    # here was itself structurally invalid under the real BagOfModels contract
    # (len(weights) must equal len(models)) -- it only "passed" because the
    # 185a386 validator never inspected the weights block at all.
    descriptor = (
        b"models: ['f7e0c4bc', 'd12395a8', '92cfc3b6', '04573f0d']\n"
        b"weights: [\n"
        b"  [1., 0., 0., 0.],\n"
        b"  [0., 1., 0., 0.],\n"
        b"  [0., 0., 1., 0.],\n"
        b"  [0., 0., 0., 1.],\n"
        b"]"
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
        (b"   \n\t\n  ", "descriptor_empty"),
        (b"this is not a models descriptor, despite being comfortably over sixty-four bytes", "descriptor_malformed"),
        (b"models: ['some_other_model'] # valid-looking but references no installed weight", "descriptor_missing_reference"),
        (b"models: ['955717e8', 'weight_that_is_not_installed']", "descriptor_missing_reference"),
        (b"models: ['955717e8', '955717e8']", "descriptor_missing_reference"),
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
    # Driven through the real buildDirectRunOptions() producer, not a
    # hand-fed "direct" string -- see test_legacy_direct_literal_is_not_the_
    # production_direct_identity below for why that distinction matters.
    source = MAIN_LUA.read_text(encoding="utf-8", errors="replace")
    direct_start = source.index("function B0_directKitAssets()")
    direct_end = source.index("\nend", direct_start)
    direct_source = source[direct_start:direct_end]
    assert f'{{ name = "{DIRECT_CKPT}", minBytes = 1048576 }}' in direct_source
    assert f'{{ name = "{DIRECT_YAML}", minBytes = 64 }}' in direct_source

    _write(tmp_path / DIRECT_CKPT, b"c" * 1048576)
    _write(tmp_path / DIRECT_YAML, b"too small")
    result = _run_preflight_raw(tmp_path, use_builder="direct")
    assert not result["ready"]

    _write(tmp_path / DIRECT_YAML, b"d" * 64)
    result = _run_preflight_raw(tmp_path, use_builder="direct")
    assert result["ready"], result["detail"]


def test_direct_run_options_carry_production_source_identity(tmp_path):
    # Proves buildDirectRunOptions().workflowSource actually equals
    # DKS_WORKFLOW.SOURCE_DIRECT (the constant B0 now compares against),
    # end to end through the same harness B0 itself runs under.
    _install_direct_assets(tmp_path)

    result = _run_preflight_raw(tmp_path, use_builder="direct")

    assert result["source_is_direct"]
    assert not result["source_is_extract"]


def test_extract_run_options_carry_production_source_identity(tmp_path):
    _write(tmp_path / "htdemucs.yaml", b"models: ['955717e8']")
    _install_normal_weight(tmp_path)
    _install_direct_assets(tmp_path)

    result = _run_preflight_raw(tmp_path, use_builder="extract")

    assert result["source_is_extract"]
    assert not result["source_is_direct"]


def test_direct_kit_real_run_options_select_direct_kit_branch_only(tmp_path):
    # Regression for the invented-literal bug: real Direct Kit run options
    # (workflowSource == "dks_direct") must land B0 on the Direct Kit asset
    # family alone. No normal Demucs descriptor/weight is installed here --
    # if B0 fell through to the generic Demucs branch (the pre-fix bug),
    # this would report not-ready demanding htdemucs.yaml/955717e8 instead.
    _install_direct_assets(tmp_path)

    result = _run_preflight_raw(tmp_path, use_builder="direct")

    assert result["ready"], result["detail"]
    assert "routes=Direct Kit" in result["message"]
    assert "Normal Stems" not in result["message"]


def test_kit_split_real_run_options_require_both_stage_assets(tmp_path):
    # Regression for the invented-literal bug: real Kit Split run options
    # (workflowSource == "dks_extract") must require BOTH the stage-1 Demucs
    # assets AND the stage-2 DrumSep assets before the worker launches.
    result = _run_preflight_raw(tmp_path, use_builder="extract")
    assert not result["ready"], "neither stage's assets are installed yet"

    _write(tmp_path / "htdemucs.yaml", b"models: ['955717e8']")
    _install_normal_weight(tmp_path)
    result = _run_preflight_raw(tmp_path, use_builder="extract")
    assert not result["ready"], "stage-2 DrumSep assets are still missing"
    assert DIRECT_CKPT in result["detail"]

    _install_direct_assets(tmp_path)
    result = _run_preflight_raw(tmp_path, use_builder="extract")
    assert result["ready"], result["detail"]
    assert "routes=Normal Stems,Kit Split" in result["message"]


def test_legacy_direct_literal_is_not_the_production_direct_identity(tmp_path):
    # The old contract-fake tests fed the invented "direct" string, which
    # buildDirectRunOptions() never actually produces (it produces
    # "dks_direct"). After the fix that legacy literal must NOT be accepted
    # as the Direct Kit identity -- it must fall through to the generic
    # model preflight branch instead.
    _install_direct_assets(tmp_path)

    result = _run_preflight_raw(
        tmp_path, workflow_mode="drumkit", workflow_source="direct"
    )

    assert not result["ready"], (
        "legacy 'direct' literal was incorrectly accepted as the production "
        "Direct Kit identity"
    )
    assert "Normal Stems" in result["detail"]


def test_legacy_extract_literal_is_not_the_production_extract_identity(tmp_path):
    # Mirror of the above for "extract" vs. the real "dks_extract" value.
    # If the legacy literal were (wrongly) treated as production identity,
    # this would fail demanding the DrumSep stage-2 assets even though only
    # the normal Demucs assets are installed.
    _write(tmp_path / "htdemucs.yaml", b"models: ['955717e8']")
    _install_normal_weight(tmp_path)

    result = _run_preflight_raw(
        tmp_path, workflow_mode="drumkit", workflow_source="extract"
    )

    assert result["ready"], result["detail"]
    assert "routes=Normal Stems" in result["message"]
    assert "Kit Split" not in result["message"]


def test_valid_models_line_followed_by_unterminated_weights_block_blocks(tmp_path):
    # Independent-review blocker: a valid "models:" line followed by corrupt/
    # incomplete trailing content (here, a "weights: [" that never closes)
    # must not silently pass just because the first line parsed cleanly.
    _write(tmp_path / "htdemucs.yaml", b"models: ['955717e8']\nweights: [\n")
    _install_normal_weight(tmp_path)

    ready, detail = _run_preflight(tmp_path)

    assert not ready
    assert "descriptor_malformed" in detail


def test_valid_models_line_followed_by_garbage_after_closed_weights_blocks(tmp_path):
    descriptor = (
        b"models: ['f7e0c4bc', 'd12395a8', '92cfc3b6', '04573f0d']\n"
        b"weights: [\n"
        b"  [1., 0., 0., 0.],\n"
        b"  [0., 1., 0., 0.],\n"
        b"  [0., 0., 1., 0.],\n"
        b"  [0., 0., 0., 1.],\n"
        b"]\n"
        b"not part of the supported grammar\n"
    )
    _write(tmp_path / "htdemucs_ft.yaml", descriptor)
    for weight in QUALITY_WEIGHTS:
        _write(tmp_path / weight, b"w" * 1024)

    ready, detail = _run_preflight(tmp_path, model="htdemucs_ft")

    assert not ready
    assert "descriptor_malformed" in detail


def test_quality_weights_row_count_mismatch_blocks(tmp_path):
    # 4 models declared but only 2 weight rows: violates the real
    # BagOfModels contract (len(weights) must equal len(models)).
    descriptor = (
        b"models: ['f7e0c4bc', 'd12395a8', '92cfc3b6', '04573f0d']\n"
        b"weights: [\n"
        b"  [1., 0., 0., 0.],\n"
        b"  [0., 1., 0., 0.],\n"
        b"]"
    )
    _write(tmp_path / "htdemucs_ft.yaml", descriptor)
    for weight in QUALITY_WEIGHTS:
        _write(tmp_path / weight, b"w" * 1024)

    ready, detail = _run_preflight(tmp_path, model="htdemucs_ft")

    assert not ready
    assert "descriptor_malformed" in detail


def test_quality_weights_wrong_column_count_blocks(tmp_path):
    # 4 rows (matches model count) but each row has 1 column instead of the
    # 4 columns the installed htdemucs_ft.yaml actually uses: syntactically
    # fine YAML, structurally wrong for this descriptor.
    descriptor = (
        b"models: ['f7e0c4bc', 'd12395a8', '92cfc3b6', '04573f0d']\n"
        b"weights: [\n"
        b"  [1.],\n"
        b"  [1.],\n"
        b"  [1.],\n"
        b"  [1.],\n"
        b"]"
    )
    _write(tmp_path / "htdemucs_ft.yaml", descriptor)
    for weight in QUALITY_WEIGHTS:
        _write(tmp_path / weight, b"w" * 1024)

    ready, detail = _run_preflight(tmp_path, model="htdemucs_ft")

    assert not ready
    assert "descriptor_malformed" in detail


def test_quality_weights_ragged_rows_block(tmp_path):
    descriptor = (
        b"models: ['f7e0c4bc', 'd12395a8', '92cfc3b6', '04573f0d']\n"
        b"weights: [\n"
        b"  [1., 0., 0., 0.],\n"
        b"  [0., 1.],\n"
        b"  [0., 0., 1., 0.],\n"
        b"  [0., 0., 0., 1.],\n"
        b"]"
    )
    _write(tmp_path / "htdemucs_ft.yaml", descriptor)
    for weight in QUALITY_WEIGHTS:
        _write(tmp_path / weight, b"w" * 1024)

    ready, detail = _run_preflight(tmp_path, model="htdemucs_ft")

    assert not ready
    assert "descriptor_malformed" in detail


def test_crlf_variant_of_valid_descriptor_is_ready(tmp_path):
    _write(tmp_path / "htdemucs.yaml", b"models: ['955717e8']\r\n")
    _install_normal_weight(tmp_path)

    ready, detail = _run_preflight(tmp_path)

    assert ready, detail


def test_real_installed_6s_descriptor_passes_through_real_harness(tmp_path):
    # The exact byte-for-byte content of the currently installed
    # htdemucs_6s.yaml (single model, no weights block).
    _write(tmp_path / "htdemucs_6s.yaml", b"models: ['5c90dfd2']\n")
    _write(tmp_path / "5c90dfd2-34c22ccb.th", b"w" * 1024)

    ready, detail = _run_preflight(tmp_path, model="htdemucs_6s")

    assert ready, detail


def test_block_list_yaml_form_is_intentionally_unsupported(tmp_path):
    # STEMwerk's Lua preflight is a strict parser for the one narrow grammar
    # every shipped descriptor actually uses (a single-line flow list, plus
    # an optional multi-line flow-list-of-flow-lists "weights:" block) -- not
    # a general YAML parser. A PyYAML-valid block-list spelling of the same
    # data is a real compatibility gap (tracked, not silently pretended to
    # work) rather than a supported input.
    descriptor = b"models:\n  - '955717e8'\n"
    _write(tmp_path / "htdemucs.yaml", descriptor)
    _install_normal_weight(tmp_path)

    ready, detail = _run_preflight(tmp_path)

    assert not ready
    assert "descriptor_malformed" in detail


def test_fast_descriptor_without_weights_is_ready(tmp_path):
    # htdemucs is a 1-submodel bag; the real installed descriptor has no
    # weights block at all, and that remains valid (BagOfModels defaults
    # weights to all-ones when absent).
    _write(tmp_path / "htdemucs.yaml", b"models: ['955717e8']\n")
    _install_normal_weight(tmp_path)

    ready, detail = _run_preflight(tmp_path)

    assert ready, detail


def test_fast_descriptor_with_correct_weight_width_is_ready(tmp_path):
    # Loading the real installed 955717e8 checkpoint via the vendored
    # demucs.repo.BagOnlyRepo confirms htdemucs.sources has 4 entries
    # (drums, bass, other, vocals), so a 1x4 weights row is the only
    # semantically valid optional shape for this descriptor.
    _write(tmp_path / "htdemucs.yaml", b"models: ['955717e8']\nweights: [\n  [1., 1., 1., 1.],\n]")
    _install_normal_weight(tmp_path)

    ready, detail = _run_preflight(tmp_path)

    assert ready, detail


def test_fast_descriptor_with_wrong_weight_width_blocks(tmp_path):
    _write(tmp_path / "htdemucs.yaml", b"models: ['955717e8']\nweights: [\n  [1.],\n]")
    _install_normal_weight(tmp_path)

    ready, detail = _run_preflight(tmp_path)

    assert not ready
    assert "descriptor_malformed" in detail


def test_fast_descriptor_weight_row_count_mismatch_blocks(tmp_path):
    # 1 model declared but 2 weight rows.
    _write(
        tmp_path / "htdemucs.yaml",
        b"models: ['955717e8']\nweights: [\n  [1., 1., 1., 1.],\n  [1., 1., 1., 1.],\n]",
    )
    _install_normal_weight(tmp_path)

    ready, detail = _run_preflight(tmp_path)

    assert not ready
    assert "descriptor_malformed" in detail


def test_six_stem_descriptor_without_weights_is_ready(tmp_path):
    _write(tmp_path / "htdemucs_6s.yaml", b"models: ['5c90dfd2']\n")
    _write(tmp_path / SIX_STEM_WEIGHT, b"w" * 1024)

    ready, detail = _run_preflight(tmp_path, model="htdemucs_6s")

    assert ready, detail


def test_six_stem_descriptor_with_correct_weight_width_is_ready(tmp_path):
    # The real installed 5c90dfd2 checkpoint has 6 sources (drums, bass,
    # other, vocals, guitar, piano), confirmed via demucs.repo.BagOnlyRepo,
    # so a 1x6 weights row is the only semantically valid optional shape.
    _write(
        tmp_path / "htdemucs_6s.yaml",
        b"models: ['5c90dfd2']\nweights: [\n  [1., 1., 1., 1., 1., 1.],\n]",
    )
    _write(tmp_path / SIX_STEM_WEIGHT, b"w" * 1024)

    ready, detail = _run_preflight(tmp_path, model="htdemucs_6s")

    assert ready, detail


def test_six_stem_descriptor_with_wrong_weight_width_blocks(tmp_path):
    _write(tmp_path / "htdemucs_6s.yaml", b"models: ['5c90dfd2']\nweights: [\n  [1.],\n]")
    _write(tmp_path / SIX_STEM_WEIGHT, b"w" * 1024)

    ready, detail = _run_preflight(tmp_path, model="htdemucs_6s")

    assert not ready
    assert "descriptor_malformed" in detail


def test_six_stem_descriptor_weight_row_count_mismatch_blocks(tmp_path):
    _write(
        tmp_path / "htdemucs_6s.yaml",
        b"models: ['5c90dfd2']\nweights: [\n  [1., 1., 1., 1., 1., 1.],\n  [1., 1., 1., 1., 1., 1.],\n]",
    )
    _write(tmp_path / SIX_STEM_WEIGHT, b"w" * 1024)

    ready, detail = _run_preflight(tmp_path, model="htdemucs_6s")

    assert not ready
    assert "descriptor_malformed" in detail


def test_quality_descriptor_with_correct_weight_width_is_ready(tmp_path):
    # Already covered by test_valid_larger_quality_descriptor_is_ready; this
    # is an explicit companion asserting the FT-specific wrong-width case
    # stays enforced after the Fast/6-Stem table extension.
    descriptor = (
        b"models: ['f7e0c4bc', 'd12395a8', '92cfc3b6', '04573f0d']\n"
        b"weights: [\n  [1.],\n  [1.],\n  [1.],\n  [1.],\n]"
    )
    _write(tmp_path / "htdemucs_ft.yaml", descriptor)
    for weight in QUALITY_WEIGHTS:
        _write(tmp_path / weight, b"w" * 1024)

    ready, detail = _run_preflight(tmp_path, model="htdemucs_ft")

    assert not ready
    assert "descriptor_malformed" in detail


def test_kit_split_still_requires_its_stage_two_assets(tmp_path):
    # Driven through the real buildExtractRunOptions() producer, not a
    # hand-fed "extract" string -- see
    # test_kit_split_real_run_options_require_both_stage_assets for the
    # fuller regression covering both stages together.
    _write(tmp_path / "htdemucs.yaml", b"models: ['955717e8']")
    _install_normal_weight(tmp_path)

    result = _run_preflight_raw(tmp_path, use_builder="extract")
    assert not result["ready"]
    assert DIRECT_CKPT in result["detail"]

    _install_direct_assets(tmp_path)
    result = _run_preflight_raw(tmp_path, use_builder="extract")
    assert result["ready"], result["detail"]
