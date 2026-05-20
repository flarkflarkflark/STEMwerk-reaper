import importlib.util
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]


def _load_audio_separator_process_module():
    path = ROOT / "scripts" / "reaper" / "audio_separator_process.py"
    spec = importlib.util.spec_from_file_location("audio_separator_process_drumsep_test", path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def _touch(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"stub")


def test_drumsep_aliases_map_to_hihat():
    module = _load_audio_separator_process_module()
    assert module._normalize_drumsep_alias("hh") == "hihat"
    assert module._normalize_drumsep_alias("hi_hat") == "hihat"
    assert module._normalize_drumsep_alias("hi-hat") == "hihat"


def test_classify_drumsep_hh_and_crash():
    module = _load_audio_separator_process_module()
    assert module._classify_drumsep_stem(Path("drums_(hh)_model.wav")) == "hihat"
    assert module._classify_drumsep_stem(Path("drums_(crash)_model.wav")) == "crash"


def test_demucs_drums_file_not_treated_as_drumsep_substem():
    module = _load_audio_separator_process_module()
    assert module._classify_drumsep_stem(Path("drums.wav")) is None


def test_finalize_drumsep_outputs_partial_with_missing_diagnostics(tmp_path, capsys):
    module = _load_audio_separator_process_module()
    _touch(tmp_path / "drums_(kick)_Model.wav")
    _touch(tmp_path / "drums_(snare)_Model.wav")

    result = module._finalize_drumsep_outputs(tmp_path, {})

    assert set(result.keys()) == {"kick", "snare"}
    assert (tmp_path / "kick.wav").exists()
    assert (tmp_path / "snare.wav").exists()
    err = capsys.readouterr().err
    assert "STEMWERK_DRUMSEP_CONTRACT_STATUS=partial" in err
    assert "STEMWERK_DRUMSEP_MISSING=" in err


def test_finalize_drumsep_outputs_fails_when_no_substems(tmp_path):
    module = _load_audio_separator_process_module()
    _touch(tmp_path / "drums.wav")

    with pytest.raises(RuntimeError, match="no mappable drum stems"):
        module._finalize_drumsep_outputs(tmp_path, {})
