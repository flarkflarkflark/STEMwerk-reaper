"""Schema/gate-validatie voor scripts/reaper/models.json (registry schema v2).

Commit-1 scope: dit bestand valideert UITSLUITEND het registry-artifact.
Het importeert geen runtime-code, wijzigt geen gedrag en draait mee in de
bestaande pytest-suite. De checks implementeren release_gate.checks uit
models.json zelf, voor zover mechanisch checkbaar.

Verwachte locatie van de registry: scripts/reaper/models.json
(naast STEMwerk.lua, zodat de latere Lua-registry hem relatief kan laden).
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
REGISTRY_PATH = REPO_ROOT / "scripts" / "reaper" / "models.json"

REQUIRED_MODEL_FIELDS = (
    "id", "kind", "engine", "backend_arg", "default", "hidden",
    "experimental", "output_contract", "validation", "runtime",
    "download", "packaging", "ui", "provenance",
)
REQUIRED_CONTRACT_FIELDS = ("stems", "stem_semantics", "expected_outputs")


@pytest.fixture(scope="module")
def registry() -> dict:
    assert REGISTRY_PATH.is_file(), f"registry ontbreekt: {REGISTRY_PATH}"
    with REGISTRY_PATH.open(encoding="utf-8") as fh:
        return json.load(fh)


def _active_models(reg: dict) -> list[dict]:
    return [m for m in reg["models"] if not m.get("hidden", False)]


def _gate_required_internal_stages(reg: dict) -> list[dict]:
    """Hidden internal_stage entries die door gate-required presets gebruikt
    worden vallen BINNEN de gate, hidden status notwithstanding."""
    referenced: set[str] = set()
    for preset in reg.get("presets", []):
        if not preset.get("release_gate_required", False):
            continue
        for stage in (preset.get("workflow") or {}).get("stages", []):
            referenced.add(stage.get("stage", ""))
    return [
        m for m in reg["models"]
        if m.get("kind") == "internal_stage" and m["id"] in referenced
    ]


def _gate_scope(reg: dict) -> list[dict]:
    return _active_models(reg) + _gate_required_internal_stages(reg)


def test_schema_version(registry):
    assert registry.get("schema_version") == 2


def test_exactly_one_active_default(registry):
    defaults = [m["id"] for m in _active_models(registry) if m.get("default")]
    assert defaults == ["htdemucs"], f"verwacht exact één actieve default, kreeg: {defaults}"


def test_all_required_fields_present_in_gate_scope(registry):
    for model in _gate_scope(registry):
        for field in REQUIRED_MODEL_FIELDS:
            assert field in model, f"{model.get('id', '?')}: veld '{field}' ontbreekt"


def test_output_contracts_complete_and_consistent(registry):
    for model in _gate_scope(registry):
        contract = model["output_contract"]
        for field in REQUIRED_CONTRACT_FIELDS:
            assert field in contract, f"{model['id']}: output_contract.{field} ontbreekt"
        assert contract["expected_outputs"] == len(contract["stems"]), (
            f"{model['id']}: expected_outputs != len(stems)"
        )
        assert model["validation"]["expected_outputs"] == contract["expected_outputs"], (
            f"{model['id']}: validation.expected_outputs wijkt af van output_contract"
        )
        assert contract["stem_semantics"] in registry["stem_semantics_types"], (
            f"{model['id']}: onbekende stem_semantics '{contract['stem_semantics']}'"
        )


def test_runtime_profiles_are_known(registry):
    known = set(registry["runtime_profiles"].keys()) - {"$comment"}
    for model in _gate_scope(registry):
        for profile in model["runtime"]["profiles"]:
            assert profile in known, f"{model['id']}: onbekend runtime profile '{profile}'"
        for profile in model["runtime"].get("experimental_on", []):
            assert profile in known, f"{model['id']}: onbekend experimental profile '{profile}'"


def test_model_file_dir_structure(registry):
    mfd = registry["paths"]["model_file_dir"]
    assert mfd.get("env_override") == "AUDIO_SEPARATOR_MODEL_DIR"
    assert "%LOCALAPPDATA%/STEMwerk/models" in mfd["windows"]
    assert "Application Support/STEMwerk/models" in mfd["macos"]
    linux = mfd["linux"]
    assert linux["xdg_env"] == "XDG_DATA_HOME"
    assert linux["xdg_relative"] == "STEMwerk/models"
    assert linux["fallback"] == "~/.local/share/STEMwerk/models"


def test_dks_presets_resolve_to_stemwerk_dks(registry):
    model_ids = {m["id"] for m in registry["models"]}
    for preset in registry.get("presets", []):
        for stage in (preset.get("workflow") or {}).get("stages", []):
            stage_id = stage["stage"]
            assert stage_id in model_ids, f"preset {preset['id']}: onbekende stage '{stage_id}'"
            stage_model = next(m for m in registry["models"] if m["id"] == stage_id)
            assert stage_model["kind"] == "internal_stage", (
                f"preset {preset['id']}: stage '{stage_id}' is geen internal_stage"
            )
        if preset["id"] in ("direct_kit", "drum_kit_split"):
            stages = [s["stage"] for s in preset["workflow"]["stages"]]
            assert stages == ["stemwerk_dks"], (
                f"DKS-preset {preset['id']} moet exact naar stemwerk_dks verwijzen, kreeg: {stages}"
            )


def test_dks_contract_matches_runtime_constants(registry):
    """Pin het DKS-contract op DIRECT_DKS_EXPECTED_STEMS en de key_to_reaper
    bestandsnamen. Wijzigt de runtime, dan hoort deze test bewust te breken."""
    dks = next(m for m in registry["models"] if m["id"] == "stemwerk_dks")
    assert dks["output_contract"]["stems"] == ["kick", "snare", "toms", "hihat", "ride", "crash"]
    assert dks["validation"]["expected_filenames"] == [
        "kick.wav", "snare.wav", "toms.wav", "hi-hat.wav", "ride.wav", "crash.wav",
    ]


def test_ui_labels_resolvable(registry):
    for model in _active_models(registry):
        ui = model["ui"]
        assert ui.get("label_key") or ui.get("fallback_label"), (
            f"{model['id']}: geen label_key en geen fallback_label"
        )


def test_no_todo_in_gate_scope(registry):
    for model in _gate_scope(registry):
        blob = json.dumps(model)
        assert not re.search(r"TODO_", blob), f"{model['id']}: TODO_ placeholder in gate-scope"
    for preset in registry.get("presets", []):
        if preset.get("release_gate_required"):
            assert not re.search(r"TODO_", json.dumps(preset)), (
                f"preset {preset['id']}: TODO_ placeholder in gate-required preset"
            )


def test_hidden_experimental_primaries_outside_gate(registry):
    """Sanity: viperx mag TODO's bevatten en wordt door bovenstaande checks
    genegeerd — deze test documenteert dat dat bewust is."""
    viperx = next(m for m in registry["models"] if m["id"] == "bs_roformer_viperx")
    assert viperx["hidden"] is True
    assert viperx["experimental"] is True
    assert viperx["packaging"]["release_gate_required"] is False
    assert viperx not in _gate_scope(registry)


def test_registry_policy_hard_fail(registry):
    policy = registry["registry_policy"]
    assert policy["unknown_model_id"] == "hard_fail"
    assert policy["silent_fallback_to_default"] is False
