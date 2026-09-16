from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest


ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"
PROCESS_SCRIPT = ROOT / "scripts" / "reaper" / "audio_separator_process.py"

if str(CORE_SRC) not in sys.path:
    sys.path.insert(0, str(CORE_SRC))

from stemwerk_core.separator import (  # noqa: E402
    _map_separator_output_files,
    _separator_output_stem_identity,
)


EXPECTED = ("bass", "drums", "other", "vocals")


def _outputs(source_name: str) -> list[str]:
    return [f"{source_name}_({stem.title()})_htdemucs.wav" for stem in EXPECTED]


@pytest.mark.parametrize(
    "source_name",
    (
        "test_source_drum_rich",
        "canonical_input",
        "bass_test",
        "vocals_mix",
        "other_song",
        "snare_and_drums",
    ),
)
def test_source_basename_cannot_change_htdemucs_mapping(source_name, tmp_path):
    mapped = _map_separator_output_files(_outputs(source_name), tmp_path, EXPECTED)

    assert set(mapped) == set(EXPECTED)
    assert mapped["drums"].name == f"{source_name}_(Drums)_htdemucs.wav"
    for identity, path in mapped.items():
        assert f"_({identity.title()})_" in path.name


@pytest.mark.parametrize(
    "token,expected",
    (
        ("Vocals", "vocals"),
        ("dRuMs", "drums"),
        ("BASS", "bass"),
        ("other", "other"),
    ),
)
def test_exact_generated_token_determines_identity(token, expected):
    path = Path("C:/source-like/drums/vocals_mix") / f"bass_other_({token})_htdemucs.wav"

    assert _separator_output_stem_identity(path) == expected


def test_all_four_htdemucs_stems_map_exactly_once(tmp_path):
    mapped = _map_separator_output_files(_outputs("song"), tmp_path, EXPECTED)

    assert tuple(sorted(mapped)) == EXPECTED
    assert len(set(mapped.values())) == 4


def test_duplicate_authoritative_drums_outputs_fail_closed(tmp_path):
    outputs = [
        "song_(Drums)_htdemucs.wav",
        "song_(DRUMS)_second-model.wav",
    ]

    with pytest.raises(ValueError, match="Duplicate separator output stem identity 'drums'"):
        _map_separator_output_files(outputs, tmp_path, ("drums",))


def test_missing_required_drums_fails_closed(tmp_path):
    outputs = ["drums_in_source_(Other)_htdemucs.wav"]

    with pytest.raises(RuntimeError, match="Missing required.*drums"):
        _map_separator_output_files(outputs, tmp_path, ("drums",))


def test_unknown_output_cannot_overwrite_known_stem(tmp_path):
    outputs = [
        "song_(Drums)_htdemucs.wav",
        "drums_in_source_(Ambience)_htdemucs.wav",
    ]

    mapped = _map_separator_output_files(outputs, tmp_path, ("drums",))

    assert mapped == {"drums": tmp_path / "song_(Drums)_htdemucs.wav"}


def test_benign_generated_filename_preserves_expected_behavior(tmp_path):
    mapped = _map_separator_output_files(
        ["song_(Bass)_htdemucs.wav", "drums.wav"],
        tmp_path,
    )

    assert mapped == {
        "bass": tmp_path / "song_(Bass)_htdemucs.wav",
        "drums": tmp_path / "drums.wav",
    }


def test_reaper_mapping_uses_authoritative_identity_not_source_basename(tmp_path):
    spec = importlib.util.spec_from_file_location("stage1_mapping_process", PROCESS_SCRIPT)
    assert spec is not None and spec.loader is not None
    process = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(process)
    raw_drums = tmp_path / "vocals_mix_(Drums)_htdemucs.wav"
    raw_drums.write_bytes(b"genuine drums")

    mapped = process._map_reaper_stems_from_result(
        SimpleNamespace(stems={"drums": raw_drums}), tmp_path
    )

    assert mapped == {"drums": str(tmp_path / "drums.wav")}
    assert (tmp_path / "drums.wav").read_bytes() == b"genuine drums"
    assert not (tmp_path / "vocals.wav").exists()
