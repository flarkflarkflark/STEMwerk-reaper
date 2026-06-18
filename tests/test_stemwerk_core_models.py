import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"

if str(CORE_SRC) not in sys.path:
    sys.path.insert(0, str(CORE_SRC))

from stemwerk_core.models import resolve_model_name
from stemwerk_core.separator import _resolve_audio_separator_model_name


def test_demucs_model_aliases_stay_as_identifiers():
    assert resolve_model_name("htdemucs") == "htdemucs"
    assert resolve_model_name("htdemucs_ft") == "htdemucs_ft"
    assert resolve_model_name("htdemucs_6s") == "htdemucs_6s"
    assert resolve_model_name("hdemucs_mmi") == "hdemucs_mmi"


def test_unknown_model_names_pass_through():
    assert resolve_model_name("MDX23C-DrumSep-aufr33-jarredou.ckpt") == "MDX23C-DrumSep-aufr33-jarredou.ckpt"


def test_demucs_model_loader_uses_identifier_when_catalog_supports_it():
    class FakeSeparator:
        model_file_dir = str(CORE_SRC)

        @staticmethod
        def list_supported_model_files():
            return {"Demucs": {"Demucs v4: htdemucs": {"htdemucs": "https://example.invalid/htdemucs"}}}

    assert _resolve_audio_separator_model_name(FakeSeparator(), "htdemucs") == "htdemucs"


def test_demucs_model_loader_uses_local_yaml_when_catalog_only_has_yaml(tmp_path):
    (tmp_path / "htdemucs.yaml").write_text("models: ['955717e8']\n", encoding="utf-8")

    class FakeSeparator:
        model_file_dir = str(tmp_path)

        @staticmethod
        def list_supported_model_files():
            return {}

    assert _resolve_audio_separator_model_name(FakeSeparator(), "htdemucs") == "htdemucs.yaml"
