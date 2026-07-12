import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

import pytest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "reaper" / "audio_separator_process.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("audio_separator_process_vocals_hq_proof_test", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec is not None and spec.loader is not None
    spec.loader.exec_module(module)
    return module


def _normal_args(model="htdemucs"):
    return type("Args", (), {"model": model})()


def test_visible_model_passes_through_without_registry_io(monkeypatch):
    module = _load_module()
    monkeypatch.delenv(module.EXPERIMENTAL_MODELS_ENABLE_ENV, raising=False)
    monkeypatch.delenv(module.EXPERIMENTAL_MODEL_ID_ENV, raising=False)
    monkeypatch.setattr(
        module,
        "_load_runtime_registry_entry",
        lambda _model_id: (_ for _ in ()).throw(AssertionError("registry I/O should stay lazy")),
    )

    selection = module._resolve_normal_route_model_selection(_normal_args("htdemucs"))

    assert selection["requested_model_id"] == "htdemucs"
    assert selection["effective_model_id"] == "htdemucs"
    assert selection["model_for_separator"] == "htdemucs"
    assert selection["registry_entry"] is None
    assert selection["experimental_override_active"] is False


def test_normal_flow_ignores_corrupt_registry_without_env_gate(monkeypatch, tmp_path):
    module = _load_module()
    monkeypatch.delenv(module.EXPERIMENTAL_MODELS_ENABLE_ENV, raising=False)
    monkeypatch.delenv(module.EXPERIMENTAL_MODEL_ID_ENV, raising=False)
    bad_registry = tmp_path / "models.json"
    bad_registry.write_text("{ definitely-not-json", encoding="utf-8")
    monkeypatch.setattr(module, "_runtime_registry_path", lambda: bad_registry)

    selection = module._resolve_normal_route_model_selection(_normal_args("htdemucs"))

    assert selection["model_for_separator"] == "htdemucs"
    assert selection["registry_entry"] is None


def test_hidden_experimental_model_without_env_gate_fails(monkeypatch):
    module = _load_module()
    monkeypatch.delenv(module.EXPERIMENTAL_MODELS_ENABLE_ENV, raising=False)
    monkeypatch.delenv(module.EXPERIMENTAL_MODEL_ID_ENV, raising=False)

    with pytest.raises(RuntimeError, match="Hidden experimental model ids require the explicit env gate"):
        module._resolve_normal_route_model_selection(_normal_args("bs_roformer_viperx"))


def test_enable_without_model_id_fails_and_marks_half_configured(monkeypatch, capsys):
    module = _load_module()
    monkeypatch.setenv(module.EXPERIMENTAL_MODELS_ENABLE_ENV, "1")
    monkeypatch.delenv(module.EXPERIMENTAL_MODEL_ID_ENV, raising=False)

    with pytest.raises(RuntimeError) as excinfo:
        module._resolve_normal_route_model_selection(_normal_args("htdemucs"))

    assert module.EXPERIMENTAL_MODELS_ENABLE_ENV in str(excinfo.value)
    assert module.EXPERIMENTAL_MODEL_ID_ENV in str(excinfo.value)
    assert "experimental_env_gate=half_configured" in capsys.readouterr().err


def test_model_id_without_enable_fails_and_marks_half_configured(monkeypatch, capsys):
    module = _load_module()
    monkeypatch.delenv(module.EXPERIMENTAL_MODELS_ENABLE_ENV, raising=False)
    monkeypatch.setenv(module.EXPERIMENTAL_MODEL_ID_ENV, "bs_roformer_viperx")

    with pytest.raises(RuntimeError) as excinfo:
        module._resolve_normal_route_model_selection(_normal_args("htdemucs"))

    assert module.EXPERIMENTAL_MODELS_ENABLE_ENV in str(excinfo.value)
    assert module.EXPERIMENTAL_MODEL_ID_ENV in str(excinfo.value)
    assert "experimental_env_gate=half_configured" in capsys.readouterr().err


def test_hidden_experimental_model_resolves_to_registry_backend_arg(monkeypatch):
    module = _load_module()
    monkeypatch.setenv(module.EXPERIMENTAL_MODELS_ENABLE_ENV, "1")
    monkeypatch.setenv(module.EXPERIMENTAL_MODEL_ID_ENV, "bs_roformer_viperx")

    selection = module._resolve_normal_route_model_selection(_normal_args("htdemucs"))

    assert selection["requested_model_id"] == "htdemucs"
    assert selection["effective_model_id"] == "bs_roformer_viperx"
    assert selection["model_for_separator"] == "model_bs_roformer_ep_317_sdr_12.9755.ckpt"
    assert selection["experimental_override_active"] is True
    assert selection["registry_entry"]["family"] == "roformer"


def test_unknown_experimental_model_id_fails(monkeypatch):
    module = _load_module()
    monkeypatch.setenv(module.EXPERIMENTAL_MODELS_ENABLE_ENV, "1")
    monkeypatch.setenv(module.EXPERIMENTAL_MODEL_ID_ENV, "does_not_exist")

    with pytest.raises(RuntimeError, match="Unknown experimental model id"):
        module._resolve_normal_route_model_selection(_normal_args("htdemucs"))


def test_runtime_registry_reader_ignores_ui_and_presets(monkeypatch, tmp_path):
    module = _load_module()
    monkeypatch.setenv(module.EXPERIMENTAL_MODELS_ENABLE_ENV, "1")
    monkeypatch.setenv(module.EXPERIMENTAL_MODEL_ID_ENV, "bs_roformer_viperx")
    fake_registry = {
        "presets": "should_not_be_read",
        "models": [
            {
                "id": "bs_roformer_viperx",
                "kind": "primary",
                "hidden": True,
                "experimental": True,
                "engine": "audio_separator",
                "backend_arg": "model_bs_roformer_ep_317_sdr_12.9755.ckpt",
                "architecture": "mdxc",
                "family": "roformer",
                "output_contract": {"stems": ["vocals", "instrumental"], "stem_semantics": "complement", "expected_outputs": 2},
                "validation": {"expected_outputs": 2},
                "ui": {"fallback_label": "should be ignored"},
            }
        ],
    }
    registry_path = tmp_path / "models.json"
    registry_path.write_text(json.dumps(fake_registry), encoding="utf-8")
    monkeypatch.setattr(module, "_runtime_registry_path", lambda: registry_path)

    selection = module._resolve_normal_route_model_selection(_normal_args("htdemucs"))

    assert "ui" not in selection["registry_entry"]
    assert selection["registry_entry"]["backend_arg"] == "model_bs_roformer_ep_317_sdr_12.9755.ckpt"


def test_hidden_roformer_is_absent_from_normal_visible_registry_list():
    registry = json.loads((ROOT / "scripts" / "reaper" / "models.json").read_text(encoding="utf-8"))
    visible_ids = [entry["id"] for entry in registry["models"] if not entry.get("hidden")]
    assert "bs_roformer_viperx" not in visible_ids


@pytest.mark.parametrize("suffix", [".flac", ".wav"])
def test_complement_output_mapping_accepts_vocals_and_instrumental(tmp_path, suffix):
    module = _load_module()
    vocals = tmp_path / f"input_20s_(Vocals)_model_bs_roformer_ep_317_sdr_12{suffix}"
    instrumental = tmp_path / f"input_20s_(Instrumental)_model_bs_roformer_ep_317_sdr_12{suffix}"
    vocals.write_bytes(b"vocals")
    instrumental.write_bytes(b"instrumental")
    registry_entry = {
        "output_contract": {
            "stems": ["vocals", "instrumental"],
            "stem_semantics": "complement",
            "expected_outputs": 2,
        }
    }

    result = SimpleNamespace(stems={"vocals": str(vocals), "other": str(instrumental)})
    reaper_stems = module._map_reaper_stems_from_result(result, tmp_path, registry_entry=registry_entry)
    mapping_info = module._get_last_output_mapping_info()

    assert set(reaper_stems) == {"vocals", "other"}
    assert Path(reaper_stems["vocals"]).name == "vocals.wav"
    assert Path(reaper_stems["other"]).name == "other.wav"
    assert sorted(Path(p).name for p in mapping_info["raw_output_files"]) == sorted([vocals.name, instrumental.name])
    assert mapping_info["instrumental_as_other"] is True


def test_complement_output_mapping_requires_exactly_two_outputs(tmp_path):
    module = _load_module()
    vocals = tmp_path / "input_(Vocals).flac"
    instrumental = tmp_path / "input_(Instrumental).flac"
    extra = tmp_path / "input_(Drums).flac"
    for path in (vocals, instrumental, extra):
        path.write_bytes(b"x")
    registry_entry = {
        "output_contract": {
            "stems": ["vocals", "instrumental"],
            "stem_semantics": "complement",
            "expected_outputs": 2,
        }
    }
    result = SimpleNamespace(
        stems={"vocals": str(vocals), "other": str(instrumental), "drums": str(extra)}
    )

    with pytest.raises(RuntimeError, match="Complement output contract expected 2 outputs"):
        module._map_reaper_stems_from_result(result, tmp_path, registry_entry=registry_entry)
