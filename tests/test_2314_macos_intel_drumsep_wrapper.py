"""Regression tests for the Intel macOS CPU DrumSep six-stem wrapper slice.

Real-hardware evidence (physical Intel MacBook Pro 11,2, macOS x86_64,
Python 3.12.13, torch 2.2.2, audio-separator 0.23.0, CPUExecutionProvider)
proved the managed macOS wrapper's UVR-equivalent MDXC reconstruction
(_internal/stemwerk_drumsep_process.py, route=wrapper) is CPU-capable
end-to-end, producing six real, distinct, non-silent stems -- not just on
Apple Silicon. But the product flow never reached that helper: the ONLY
gate standing in the way was `_should_use_drumsep_mps_direct_demix()`'s
architecture check (`machine not in {"arm64", "aarch64"}` ->
"machine_not_apple_silicon"), which caused `allow_six_stem_helper` to be
False for Intel, which in turn let `_direct_dks_preflight_check()` apply
`_direct_dks_backend_limit_payload()`'s synthetic audio-separator-0.23.0
"kick/snare only" rejection before any real inference ran.

The architecture check is removed; the Darwin check and every other
condition (device, runtime kind, audio-separator version, exact model,
MPS-specific sub-checks) are unchanged. This file proves the resulting
skip-the-synthetic-backend-limit behavior end-to-end through the real
`_direct_dks_preflight_check()` function (not a reimplementation), and that
Direct Kit and Kit Split share the identical decision via source-level
structural proof (both call sites use the exact same expression).

Gate-level behavioral coverage (Darwin+x86_64/amd64 now pass,
arm64+cpu/mps unchanged, non-Darwin unchanged, wrong version/model/runtime
unchanged) lives in tests/test_drumsep_mps_direct_demix.py, alongside this
slice's positive x86_64/amd64 case
(test_gate_no_longer_rejects_intel_x86_64_or_amd64) and the update to
test_gate_rejects_each_failed_condition removing the now-superseded
"machine_not_apple_silicon" case.
"""

from __future__ import annotations

import hashlib
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "reaper" / "audio_separator_process.py"

VALID_YAML = (
    "audio:\n  dim_f: 1024\n"
    "model:\n  act: gelu\n"
    "training:\n  instruments:\n    - Kick\n    - Snare\n    - Toms\n    - Hh\n    - Ride\n    - Crash\n"
    "  target_instrument: drums\n"
).encode("utf-8")


def _load_module():
    spec = importlib.util.spec_from_file_location("audio_separator_process_intel_drumsep_wrapper_test", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


class _FakeResponse:
    def __init__(self, payload: bytes):
        self.payload = payload

    def read(self) -> bytes:
        return self.payload

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        return False


def _patch_expected_hashes(module, monkeypatch, *, ckpt_bytes: bytes, yaml_bytes: bytes):
    expected = dict(module.DIRECT_DKS_MODEL_EXPECTED_SHA256)
    expected[module.DIRECT_DKS_MODEL_FILENAME] = hashlib.sha256(ckpt_bytes).hexdigest()
    expected[module.DIRECT_DKS_MODEL_YAML] = hashlib.sha256(yaml_bytes).hexdigest()
    monkeypatch.setattr(module, "DIRECT_DKS_MODEL_EXPECTED_SHA256", expected)


def _mock_urlopen(module, monkeypatch, payloads: dict[str, bytes]):
    monkeypatch.setattr(
        module.urllib.request,
        "urlopen",
        lambda url, timeout=120: _FakeResponse(payloads[str(url)]),
    )


def _stub_authoritative_catalog(module, monkeypatch):
    complete_catalog = {section: {} for section in module.AUDIO_SEPARATOR_REQUIRED_CATALOG_SECTIONS}
    monkeypatch.setattr(module, "_fetch_authoritative_audio_separator_catalog", lambda timeout=120: dict(complete_catalog))


def _prepared_preflight(tmp_path, monkeypatch):
    """Real assets on disk (via the same mocked-download fixture pattern
    tests/test_drumsep_asset_integrity.py already established), reaching
    exactly the point in _direct_dks_preflight_check where skip_backend_limit
    is decided."""
    module = _load_module()
    monkeypatch.setattr(module, "_find_repo_download_checks_path", lambda: None)
    _stub_authoritative_catalog(module, monkeypatch)
    ckpt_bytes = b"controlled-fixture-checkpoint-bytes"
    _patch_expected_hashes(module, monkeypatch, ckpt_bytes=ckpt_bytes, yaml_bytes=VALID_YAML)
    _mock_urlopen(
        module,
        monkeypatch,
        {
            module.DIRECT_DKS_MODEL_MIRROR_CKPT_URL: ckpt_bytes,
            module.DIRECT_DKS_MODEL_YAML_URL: VALID_YAML,
        },
    )
    model_cache_dir = tmp_path / "models"
    runtime_info = {"versions": {"audio-separator": "0.23.0"}}
    return module, model_cache_dir, runtime_info


# ---------------------------------------------------------------------------
# 9. Intel-supported case causes the preflight to SKIP the synthetic
#    audio-separator-0.23.0 kick/snare-only backend limit.
# ---------------------------------------------------------------------------
def test_allow_six_stem_helper_skips_the_synthetic_0230_backend_limit(tmp_path, monkeypatch):
    module, model_cache_dir, runtime_info = _prepared_preflight(tmp_path, monkeypatch)

    ok, requested, resolved, detail = module._direct_dks_preflight_check(
        module.DIRECT_DKS_MODEL_ALIAS,
        model_cache_dir,
        runtime_info=runtime_info,
        allow_six_stem_helper=True,
        allow_downloads=True,
    )

    assert ok is True, f"expected the synthetic backend limit to be skipped, got detail={detail!r}"
    assert detail is None
    assert resolved == module.DIRECT_DKS_MODEL_FILENAME


def test_without_allow_six_stem_helper_the_synthetic_0230_backend_limit_still_applies(tmp_path, monkeypatch):
    # Same exact fixture as above -- only allow_six_stem_helper differs.
    # Proves the skip is conditional on the gate's outcome, not
    # unconditional: an audio-separator 0.23.0 runtime that did NOT pass
    # through the Intel/arm64-eligible gate is still correctly blocked.
    module, model_cache_dir, runtime_info = _prepared_preflight(tmp_path, monkeypatch)

    ok, requested, resolved, detail = module._direct_dks_preflight_check(
        module.DIRECT_DKS_MODEL_ALIAS,
        model_cache_dir,
        runtime_info=runtime_info,
        allow_six_stem_helper=False,
        allow_downloads=True,
    )

    assert ok is False
    assert str(detail or "").startswith("backend_limited:")
    assert module.DRUMSEP_RUNTIME_LIMIT_REASON in str(detail)


def test_intel_gate_output_feeds_allow_six_stem_helper_end_to_end(tmp_path, monkeypatch):
    """The real gate function, called with the exact proven Intel CPU
    fixture, produces a reason that -- via the same
    `use_managed_wrapper = direct_demix_reason == DRUMSEP_UVR_EQUIVALENT_WRAPPER_REASON`
    expression the production caller uses -- yields allow_six_stem_helper
    True, and that True value, fed into the real preflight function,
    skips the synthetic backend limit. No caller logic is reimplemented;
    each production function is called for real."""
    module, model_cache_dir, runtime_info = _prepared_preflight(tmp_path, monkeypatch)
    runtime_info["kind"] = "cpu"
    runtime_info["mps_built"] = False
    runtime_info["mps_available"] = False
    runtime_info["mps_experimental"] = False
    monkeypatch.setattr(module.sys, "platform", "darwin")
    monkeypatch.setattr(module.platform, "machine", lambda: "x86_64")
    monkeypatch.delenv(module.MPS_FALLBACK_ENV, raising=False)

    use_direct_demix, direct_demix_reason = module._should_use_drumsep_mps_direct_demix(
        "dks_direct",
        "dks_direct",
        "cpu",
        runtime_info,
        module.DIRECT_DKS_MODEL_ALIAS,
    )
    use_managed_wrapper = direct_demix_reason == module.DRUMSEP_UVR_EQUIVALENT_WRAPPER_REASON
    assert use_managed_wrapper is True, f"expected Intel CPU to be gate-eligible, got reason={direct_demix_reason!r}"

    ok, requested, resolved, detail = module._direct_dks_preflight_check(
        module.DIRECT_DKS_MODEL_ALIAS,
        model_cache_dir,
        runtime_info=runtime_info,
        allow_six_stem_helper=(use_direct_demix or use_managed_wrapper),
        allow_downloads=True,
    )

    assert ok is True, f"expected end-to-end Intel eligibility to reach real processing, got detail={detail!r}"


# ---------------------------------------------------------------------------
# 10. The same shared Stage-2 decision applies to both Direct Kit and Kit
#     Split -- proven structurally: both call sites in main() invoke the
#     identical gate function with the identical derivation expression, so
#     there is exactly one decision function backing both workflows (not two
#     independently-maintained copies that could drift).
# ---------------------------------------------------------------------------
def test_direct_kit_and_kit_split_share_the_identical_gate_derivation():
    source = SCRIPT.read_text(encoding="utf-8")
    call_sites = [
        m.start()
        for m in __import__("re").finditer(r"use_direct_demix, direct_demix_reason = _should_use_drumsep_mps_direct_demix\(", source)
    ]
    assert len(call_sites) == 2, f"expected exactly 2 call sites (Direct Kit + Kit Split), found {len(call_sites)}"

    shared_fragment = (
        'use_managed_wrapper = direct_demix_reason == DRUMSEP_UVR_EQUIVALENT_WRAPPER_REASON'
    )
    assert source.count(shared_fragment) == 2

    shared_preflight_call = 'allow_six_stem_helper=(use_direct_demix or use_managed_wrapper),'
    assert source.count(shared_preflight_call) == 2


# ---------------------------------------------------------------------------
# Source-level proof of the exact contract: architecture check removed,
# Darwin check and every other check preserved verbatim.
# ---------------------------------------------------------------------------
def test_gate_source_no_longer_has_architecture_rejection_but_keeps_everything_else():
    source = SCRIPT.read_text(encoding="utf-8")
    start = source.index("def _should_use_drumsep_mps_direct_demix(")
    end = source.index("\ndef ", start + 1)
    fn = source[start:end]

    assert 'machine_not_apple_silicon' not in fn
    assert 'machine not in {"arm64", "aarch64"}' not in fn
    assert 'platform.machine()' not in fn

    # Everything else must remain authoritative.
    assert 'if sys.platform != "darwin":' in fn
    assert 'return False, "platform_not_darwin"' in fn
    assert 'if normalized_request not in {"auto", "cpu", "mps"}:' in fn
    assert 'if runtime_kind not in {"cpu", "mps"}:' in fn
    assert 'if str(versions.get("audio-separator") or "").strip() != "0.23.0":' in fn
    assert 'if str(resolved_model or "").strip() != DIRECT_DKS_MODEL_ALIAS:' in fn
    assert 'if runtime_kind == "mps":' in fn
    assert 'return False, "mps_not_built"' in fn
    assert 'return False, "mps_not_available"' in fn
    assert 'return False, "pytorch_mps_fallback_env_set"' in fn
    assert 'return False, "mps_experimental_policy_inactive"' in fn
    assert 'return False, DRUMSEP_UVR_EQUIVALENT_WRAPPER_REASON' in fn
