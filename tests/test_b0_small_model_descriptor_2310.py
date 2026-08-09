"""2.3.1.0: B0 preflight must not reject valid small model descriptors.

Regression coverage for the RC2 false-positive where verifyProcessingAssetsReady()
(scripts/reaper/STEMwerk.lua) rejected a genuine, complete htdemucs.yaml descriptor
(21 bytes: "models: ['955717e8']\\n") because B0_requiredNormalModelAssets() applied
an arbitrary minBytes=64 floor to *.yaml descriptor entries. Required weights (~84MB,
minBytes=1024) were present and the runtime dependency state reported OK, so the
block was a pure false positive in the size heuristic, not a real missing-asset case.

These tests read the real STEMwerk.lua source for the current minBytes contract
(same source-text-assertion style already used by test_macos_online_repair_2310.py
for this file) and re-run the exact size-vs-threshold comparison performed by
verifyProcessingAssetsReady() against real temp files, so a regression on either
the contract or the comparison logic fails here without needing REAPER.
"""

import os
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAIN_LUA = ROOT / "scripts/reaper/STEMwerk.lua"

# The exact htdemucs.yaml content produced for a single-model Demucs bag.
VALID_HTDEMUCS_YAML = "models: ['955717e8']\n"
assert len(VALID_HTDEMUCS_YAML.encode("utf-8")) == 21, "fixture drifted from the documented 21-byte descriptor"


def _lua_source() -> str:
    return MAIN_LUA.read_text(encoding="utf-8")


def _min_bytes_for(lua_src: str, asset_name: str) -> int:
    pattern = re.compile(r'\{\s*name\s*=\s*"' + re.escape(asset_name) + r'"\s*,\s*minBytes\s*=\s*(\d+)\s*\}')
    match = pattern.search(lua_src)
    assert match, f"asset entry not found for {asset_name!r} in {MAIN_LUA}"
    return int(match.group(1))


def _file_size_bytes(path) -> int:
    # Mirrors fileSizeBytes() in STEMwerk.lua: -1 when the file can't be opened.
    try:
        return os.path.getsize(path)
    except OSError:
        return -1


def _b0_missing(model_dir: Path, assets: list) -> list:
    # Mirrors the per-asset loop in verifyProcessingAssetsReady():
    #   if size < tonumber(asset.minBytes or 1) then missing[...] = ...
    missing = []
    for name, min_bytes in assets:
        size = _file_size_bytes(model_dir / name)
        if size < min_bytes:
            missing.append(name)
    return missing


NORMAL_MODEL_YAML_NAMES = ("htdemucs.yaml", "htdemucs_ft.yaml", "htdemucs_6s.yaml")
NORMAL_MODEL_WEIGHT_NAMES = (
    "955717e8-8726e21a.th",
    "f7e0c4bc-ba3fe64a.th",
    "d12395a8-e57c48e6.th",
    "92cfc3b6-ef3bcb9c.th",
    "04573f0d-f3cf25b2.th",
    "5c90dfd2-34c22ccb.th",
)


def test_normal_model_yaml_descriptors_no_longer_use_arbitrary_size_floor():
    lua_src = _lua_source()
    for name in NORMAL_MODEL_YAML_NAMES:
        min_bytes = _min_bytes_for(lua_src, name)
        assert min_bytes <= 1, (
            f"{name} still uses an arbitrary size floor (minBytes={min_bytes}); "
            "a valid descriptor must only be required to be non-empty"
        )


def test_normal_model_weight_thresholds_unchanged():
    # The bug was in the *.yaml floor only; weight-file truncation detection
    # (minBytes=1024 for real ~84MB .th weights) must be untouched by the fix.
    lua_src = _lua_source()
    for name in NORMAL_MODEL_WEIGHT_NAMES:
        assert _min_bytes_for(lua_src, name) == 1024, f"weight threshold for {name} must stay 1024"


def test_direct_kit_and_kit_split_thresholds_untouched():
    # Absolute rule: do not touch Kit Split / Direct Kit asset checks for this fix.
    lua_src = _lua_source()
    assert _min_bytes_for(
        lua_src, "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt"
    ) == 1048576
    assert _min_bytes_for(
        lua_src, "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
    ) == 64


def test_valid_21_byte_htdemucs_yaml_passes_preflight(tmp_path):
    lua_src = _lua_source()
    assets = [
        ("htdemucs.yaml", _min_bytes_for(lua_src, "htdemucs.yaml")),
        ("955717e8-8726e21a.th", _min_bytes_for(lua_src, "955717e8-8726e21a.th")),
    ]
    (tmp_path / "htdemucs.yaml").write_text(VALID_HTDEMUCS_YAML, encoding="utf-8")
    (tmp_path / "955717e8-8726e21a.th").write_bytes(b"\x00" * 2000)  # stand-in for the real ~84MB weight

    missing = _b0_missing(tmp_path, assets)
    assert missing == [], f"valid small descriptor was incorrectly rejected: {missing}"


def test_larger_valid_descriptor_still_passes(tmp_path):
    lua_src = _lua_source()
    assets = [
        ("htdemucs_6s.yaml", _min_bytes_for(lua_src, "htdemucs_6s.yaml")),
        ("5c90dfd2-34c22ccb.th", _min_bytes_for(lua_src, "5c90dfd2-34c22ccb.th")),
    ]
    (tmp_path / "htdemucs_6s.yaml").write_text("models: ['5c90dfd2']\nsegment: 44\n", encoding="utf-8")
    (tmp_path / "5c90dfd2-34c22ccb.th").write_bytes(b"\x00" * 2000)

    assert _b0_missing(tmp_path, assets) == []


def test_missing_descriptor_still_fails(tmp_path):
    lua_src = _lua_source()
    assets = [("htdemucs.yaml", _min_bytes_for(lua_src, "htdemucs.yaml"))]
    # File intentionally not created.
    assert _b0_missing(tmp_path, assets) == ["htdemucs.yaml"]


def test_zero_byte_descriptor_still_fails(tmp_path):
    lua_src = _lua_source()
    assets = [("htdemucs.yaml", _min_bytes_for(lua_src, "htdemucs.yaml"))]
    (tmp_path / "htdemucs.yaml").write_bytes(b"")
    assert _b0_missing(tmp_path, assets) == ["htdemucs.yaml"]


def test_missing_required_weights_still_fails_even_with_valid_yaml(tmp_path):
    lua_src = _lua_source()
    assets = [
        ("htdemucs.yaml", _min_bytes_for(lua_src, "htdemucs.yaml")),
        ("955717e8-8726e21a.th", _min_bytes_for(lua_src, "955717e8-8726e21a.th")),
    ]
    (tmp_path / "htdemucs.yaml").write_text(VALID_HTDEMUCS_YAML, encoding="utf-8")
    # Weight file intentionally absent: a genuinely missing asset must still block.
    assert _b0_missing(tmp_path, assets) == ["955717e8-8726e21a.th"]


def test_truncated_weight_file_still_fails(tmp_path):
    lua_src = _lua_source()
    assets = [
        ("htdemucs.yaml", _min_bytes_for(lua_src, "htdemucs.yaml")),
        ("955717e8-8726e21a.th", _min_bytes_for(lua_src, "955717e8-8726e21a.th")),
    ]
    (tmp_path / "htdemucs.yaml").write_text(VALID_HTDEMUCS_YAML, encoding="utf-8")
    (tmp_path / "955717e8-8726e21a.th").write_bytes(b"\x00" * 10)  # far below minBytes=1024
    assert _b0_missing(tmp_path, assets) == ["955717e8-8726e21a.th"]
