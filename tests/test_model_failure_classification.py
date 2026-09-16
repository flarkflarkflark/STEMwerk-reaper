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


def test_cuda_architecture_unsupported_classification():
    text = (
        "RuntimeError: CUDA error: no kernel image is available for execution on the device\n"
        "CUDA kernel errors might be asynchronously reported at some other API call"
    )
    failure = mod._classify_runtime_failure(
        RuntimeError(text), text, "cuda:0", "cuda:0", "htdemucs_ft", {}
    )
    assert failure is not None
    assert failure["error_reason"] == "cuda_architecture_unsupported"


def test_final_handler_prefers_cuda_architecture_failure_over_download_markers():
    # A real "no kernel image" RuntimeError's traceback should never be
    # re-labeled as a model-download failure even if unrelated download-like
    # text happens to appear nearby in the same output.
    text = (
        "RuntimeError: CUDA error: no kernel image is available for execution on the device\n"
        "unrelated log line mentioning certificate verify failed earlier in this run"
    )
    failure, model_failure = mod._classify_final_failure(
        RuntimeError(text), text, "cuda:0", "cuda:0", "htdemucs_ft", {}
    )
    assert failure is not None
    assert failure["error_reason"] == "cuda_architecture_unsupported"
    assert model_failure is None

    # Confirm the arbitration matters: the looser classifier alone matches the
    # same traceback, but the final handler seam suppresses that misleading result.
    isolated_model_failure = mod._classify_model_failure_text(text)
    assert isolated_model_failure is not None
    assert isolated_model_failure["error_class"] == "model_download_failed"


def test_genuine_download_failure_is_not_reclassified_as_cuda_architecture():
    text = "ConnectionError: Temporary failure in name resolution while reaching dl.fbaipublicfiles.com"
    failure, model_failure = mod._classify_final_failure(
        RuntimeError(text), text, "cuda:0", "cuda:0", "htdemucs_ft", {}
    )
    assert failure is None
    assert model_failure is not None
    assert model_failure["error_class"] == "model_download_failed"
