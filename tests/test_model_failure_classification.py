from pathlib import Path
import importlib.util


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "reaper" / "audio_separator_process.py"

spec = importlib.util.spec_from_file_location("audio_separator_process", SCRIPT)
mod = importlib.util.module_from_spec(spec)
assert spec is not None and spec.loader is not None
spec.loader.exec_module(mod)


def test_model_checksum_failure_classification():
    text = "Invalid checksum for file /tmp/955717e8-8726e21a.th"
    result = mod._classify_model_failure_text(text)
    assert result is not None
    assert result["error_class"] == "model_checksum_failed"


def test_model_download_timeout_classification():
    text = "HTTPSConnectionPool(host='dl.fbaipublicfiles.com', port=443): Read timed out"
    result = mod._classify_model_failure_text(text)
    assert result is not None
    assert result["error_class"] == "model_download_timeout"


def test_model_download_failed_dns_classification():
    text = "ConnectionError: Temporary failure in name resolution while reaching dl.fbaipublicfiles.com"
    result = mod._classify_model_failure_text(text)
    assert result is not None
    assert result["error_class"] == "model_download_failed"


def test_unsupported_internal_model_id_is_not_classified_as_network_failure():
    text = "ValueError: Model file htdemucs not found in supported model files"
    result = mod._classify_model_failure_text(text)
    assert result is not None
    assert result["error_class"] == "model_mapping_failed"
    assert "not an internet" in result["model_cache_hint"]


def test_unsupported_yaml_model_id_is_not_classified_as_network_failure():
    text = "ValueError: Model file htdemucs_ft.yaml not found in supported model files"
    result = mod._classify_model_failure_text(text)
    assert result is not None
    assert result["error_class"] == "model_mapping_failed"
    assert "not an internet" in result["model_cache_hint"]


def test_ordinary_no_stems_not_model_download_classified():
    text = "No stems were created. exit_code=1"
    assert mod._classify_model_failure_text(text) is None


def test_user_cancel_not_model_download_classified():
    text = "reason: user_cancel"
    assert mod._classify_model_failure_text(text) is None
