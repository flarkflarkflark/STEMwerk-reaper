import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"

if str(CORE_SRC) not in sys.path:
    sys.path.insert(0, str(CORE_SRC))

from stemwerk_core.models import resolve_audio_separator_model_id, resolve_model_name
from stemwerk_core.separator import _disable_separator_downloads, _resolve_audio_separator_model_name


def test_demucs_model_aliases_stay_as_identifiers():
    assert resolve_model_name("htdemucs") == "htdemucs"
    assert resolve_model_name("htdemucs_ft") == "htdemucs_ft"
    assert resolve_model_name("htdemucs_6s") == "htdemucs_6s"
    assert resolve_model_name("hdemucs_mmi") == "hdemucs_mmi"


def test_unknown_model_names_pass_through():
    assert resolve_model_name("MDX23C-DrumSep-aufr33-jarredou.ckpt") == "MDX23C-DrumSep-aufr33-jarredou.ckpt"


def test_demucs_model_ids_map_to_yaml_assets_for_audio_separator():
    assert resolve_audio_separator_model_id("htdemucs") == "htdemucs.yaml"
    assert resolve_audio_separator_model_id("htdemucs_ft") == "htdemucs_ft.yaml"
    assert resolve_audio_separator_model_id("htdemucs_6s") == "htdemucs_6s.yaml"


def test_demucs_model_loader_prefers_yaml_even_when_catalog_lists_alias():
    class FakeSeparator:
        model_file_dir = str(CORE_SRC)

        @staticmethod
        def list_supported_model_files():
            return {"Demucs": {"Demucs v4: htdemucs": {"htdemucs": "https://example.invalid/htdemucs"}}}

    assert _resolve_audio_separator_model_name(FakeSeparator(), "htdemucs") == "htdemucs.yaml"


def test_demucs_model_loader_uses_local_yaml_when_catalog_only_has_yaml(tmp_path):
    (tmp_path / "htdemucs.yaml").write_text("models: ['955717e8']\n", encoding="utf-8")

    class FakeSeparator:
        model_file_dir = str(tmp_path)

        @staticmethod
        def list_supported_model_files():
            return {}

    assert _resolve_audio_separator_model_name(FakeSeparator(), "htdemucs") == "htdemucs.yaml"


def test_processing_download_hook_blocks_audio_separator_downloads():
    class FakeSeparator:
        def download_model_files(self, _model_filename):
            return "unexpected"

    sep = FakeSeparator()
    _disable_separator_downloads(sep)
    try:
        sep.download_model_files("missing.th")
    except RuntimeError as exc:
        assert "processing_download_blocked" in str(exc)
    else:
        raise AssertionError("download hook did not block")
