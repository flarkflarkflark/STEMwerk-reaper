"""DrumSep runtime asset (checkpoint + YAML config) supply-chain hardening.

Two DrumSep assets -- the Jarredou MDX23C checkpoint and its YAML config --
were previously fetched from mutable upstream URLs (a Hugging Face "main"
branch and a GitHub "main" branch) with no fail-closed content verification.
This pins both to immutable upstream commits and enforces the exact
validated SHA-256 after every download, evicting a mismatched cached file
instead of silently reusing it.

Ordinary tests below are fully hermetic: they use small controlled fixture
bytes and monkeypatch the expected-hash table to match, so they exercise the
real verification code path without touching the network or the real
~437 MB checkpoint. A separate, explicit network-gated audit at the bottom
(STEMWERK_NETWORK_TESTS=1) proves the real pinned URLs still reproduce the
real validated hashes -- it is not part of the ordinary hermetic run.
"""

from __future__ import annotations

import hashlib
import importlib.util
import os
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/reaper/audio_separator_process.py"
BOOTSTRAP_MACOS = ROOT / "scripts/reaper/STEMwerk_Bootstrap_macOS.sh"
BOOTSTRAP_LINUX = ROOT / "scripts/reaper/STEMwerk_Bootstrap_Linux.sh"
BOOTSTRAP_WINDOWS = ROOT / "scripts/reaper/STEMwerk_Bootstrap_Windows.ps1"

NETWORK = os.environ.get("STEMWERK_NETWORK_TESTS") == "1"
needs_network = pytest.mark.skipif(not NETWORK, reason="set STEMWERK_NETWORK_TESTS=1")

VALID_YAML = (
    "audio:\n  dim_f: 1024\n"
    "model:\n  act: gelu\n"
    "training:\n  instruments:\n    - Kick\n    - Snare\n    - Toms\n    - Hh\n    - Ride\n    - Crash\n"
    "  target_instrument: drums\n"
).encode("utf-8")


def _load_module():
    spec = importlib.util.spec_from_file_location("audio_separator_process_asset_integrity_test", SCRIPT)
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


def _patch_expected_hashes(module, monkeypatch, *, ckpt_bytes: bytes | None = None, yaml_bytes: bytes | None = None):
    """Point the expected-hash table at whatever fixture bytes this test
    actually serves, so the real verification code runs without needing the
    real (huge, network-fetched) production asset bytes."""
    expected = dict(module.DIRECT_DKS_MODEL_EXPECTED_SHA256)
    if ckpt_bytes is not None:
        expected[module.DIRECT_DKS_MODEL_FILENAME] = hashlib.sha256(ckpt_bytes).hexdigest()
    if yaml_bytes is not None:
        expected[module.DIRECT_DKS_MODEL_YAML] = hashlib.sha256(yaml_bytes).hexdigest()
    monkeypatch.setattr(module, "DIRECT_DKS_MODEL_EXPECTED_SHA256", expected)


def _mock_urlopen(module, monkeypatch, payloads: dict[str, bytes]):
    monkeypatch.setattr(
        module.urllib.request,
        "urlopen",
        lambda url, timeout=120: _FakeResponse(payloads[str(url)]),
    )


# --- A/C: exact known hash accepted --------------------------------------


def test_checkpoint_and_yaml_matching_hashes_are_accepted(tmp_path, monkeypatch):
    module = _load_module()
    monkeypatch.setattr(module, "_find_repo_download_checks_path", lambda: None)
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
    ok, requested, resolved, detail = module._direct_dks_preflight_check(module.DIRECT_DKS_MODEL_ALIAS, model_cache_dir)

    assert ok is True
    assert detail is None
    assert (model_cache_dir / module.DIRECT_DKS_MODEL_FILENAME).read_bytes() == ckpt_bytes
    assert (model_cache_dir / module.DIRECT_DKS_MODEL_YAML).read_bytes() == VALID_YAML


# --- B: checkpoint mismatch rejected --------------------------------------


def test_checkpoint_mismatched_hash_is_rejected_and_not_persisted(tmp_path, monkeypatch):
    module = _load_module()
    monkeypatch.setattr(module, "_find_repo_download_checks_path", lambda: None)
    served_ckpt_bytes = b"tampered-or-corrupted-checkpoint-bytes"
    # Expected hash deliberately does not match what will be served.
    _patch_expected_hashes(module, monkeypatch, ckpt_bytes=b"a-different-set-of-expected-bytes")
    _mock_urlopen(
        module,
        monkeypatch,
        {
            module.DIRECT_DKS_MODEL_MIRROR_CKPT_URL: served_ckpt_bytes,
            module.DIRECT_DKS_MODEL_YAML_URL: VALID_YAML,
        },
    )

    model_cache_dir = tmp_path / "models"
    ok, requested, resolved, detail = module._direct_dks_preflight_check(module.DIRECT_DKS_MODEL_ALIAS, model_cache_dir)

    assert ok is False
    assert "asset_integrity_mismatch" in str(detail)
    assert module.DIRECT_DKS_MODEL_FILENAME in str(detail)
    assert not (model_cache_dir / module.DIRECT_DKS_MODEL_FILENAME).exists()
    # No stray .part temp file left behind either.
    assert not any(model_cache_dir.glob("*.part")) if model_cache_dir.exists() else True


# --- D: YAML mismatch rejected --------------------------------------------


def test_yaml_mismatched_hash_is_rejected_and_not_persisted(tmp_path, monkeypatch):
    module = _load_module()
    monkeypatch.setattr(module, "_find_repo_download_checks_path", lambda: None)
    ckpt_bytes = b"controlled-fixture-checkpoint-bytes"
    served_yaml_bytes = VALID_YAML
    _patch_expected_hashes(module, monkeypatch, ckpt_bytes=ckpt_bytes, yaml_bytes=b"different-expected-yaml-bytes")
    _mock_urlopen(
        module,
        monkeypatch,
        {
            module.DIRECT_DKS_MODEL_MIRROR_CKPT_URL: ckpt_bytes,
            module.DIRECT_DKS_MODEL_YAML_URL: served_yaml_bytes,
        },
    )

    model_cache_dir = tmp_path / "models"
    ok, requested, resolved, detail = module._direct_dks_preflight_check(module.DIRECT_DKS_MODEL_ALIAS, model_cache_dir)

    assert ok is False
    assert "asset_integrity_mismatch" in str(detail)
    assert module.DIRECT_DKS_MODEL_YAML in str(detail)
    # Checkpoint (verified first, hash matched) is persisted; only the
    # mismatched yaml is withheld.
    assert (model_cache_dir / module.DIRECT_DKS_MODEL_FILENAME).exists()
    assert not (model_cache_dir / module.DIRECT_DKS_MODEL_YAML).exists()


# --- E: cached bad file rejected, not silently reused ---------------------


def test_cached_file_with_wrong_hash_is_evicted_not_reused(tmp_path, monkeypatch):
    module = _load_module()
    target = tmp_path / module.DIRECT_DKS_MODEL_FILENAME
    target.write_bytes(b"stale-corrupted-cache-contents")
    expected = hashlib.sha256(b"the-real-expected-bytes").hexdigest()
    monkeypatch.setitem(module.DIRECT_DKS_MODEL_EXPECTED_SHA256, module.DIRECT_DKS_MODEL_FILENAME, expected)

    ok, detail = module._direct_dks_asset_hash_ok(target, module.DIRECT_DKS_MODEL_FILENAME)
    assert ok is False
    assert "asset_integrity_mismatch" in detail

    evicted_ok = module._evict_direct_dks_asset_if_hash_mismatched(target, module.DIRECT_DKS_MODEL_FILENAME)
    assert evicted_ok is False
    assert not target.exists(), "mismatched cached file must be deleted, not silently reused"


def test_preflight_redownloads_after_evicting_bad_cache(tmp_path, monkeypatch):
    module = _load_module()
    monkeypatch.setattr(module, "_find_repo_download_checks_path", lambda: None)
    model_cache_dir = tmp_path / "models"
    model_cache_dir.mkdir()
    correct_ckpt_bytes = b"correct-freshly-downloaded-checkpoint-bytes"
    (model_cache_dir / module.DIRECT_DKS_MODEL_FILENAME).write_bytes(b"old-stale-wrong-bytes")

    _patch_expected_hashes(module, monkeypatch, ckpt_bytes=correct_ckpt_bytes, yaml_bytes=VALID_YAML)
    requests = []

    def fake_urlopen(url, timeout=120):
        requests.append(str(url))
        payloads = {
            module.DIRECT_DKS_MODEL_MIRROR_CKPT_URL: correct_ckpt_bytes,
            module.DIRECT_DKS_MODEL_YAML_URL: VALID_YAML,
        }
        return _FakeResponse(payloads[str(url)])

    monkeypatch.setattr(module.urllib.request, "urlopen", fake_urlopen)

    ok, requested, resolved, detail = module._direct_dks_preflight_check(module.DIRECT_DKS_MODEL_ALIAS, model_cache_dir)

    assert ok is True
    assert module.DIRECT_DKS_MODEL_MIRROR_CKPT_URL in requests, "bad cache must trigger a real re-download"
    assert (model_cache_dir / module.DIRECT_DKS_MODEL_FILENAME).read_bytes() == correct_ckpt_bytes


# --- F: immutable URLs, no floating refs -----------------------------------

_FLOATING_REF_RE = re.compile(r"/(main|master|latest|HEAD)/", re.IGNORECASE)
_GITHUB_COMMIT_RE = re.compile(r"^https://raw\.githubusercontent\.com/[^/]+/[^/]+/[0-9a-f]{40}/")
_HF_COMMIT_RE = re.compile(r"^https://huggingface\.co/[^/]+/[^/]+/resolve/[0-9a-f]{40}/")


def test_drumsep_yaml_url_is_pinned_to_an_immutable_commit():
    module = _load_module()
    url = module.DIRECT_DKS_MODEL_YAML_URL
    assert not _FLOATING_REF_RE.search(url), url
    assert _GITHUB_COMMIT_RE.match(url), url


def test_drumsep_checkpoint_mirror_url_is_pinned_to_an_immutable_commit():
    module = _load_module()
    url = module.DIRECT_DKS_MODEL_MIRROR_CKPT_URL
    assert not _FLOATING_REF_RE.search(url), url
    assert _HF_COMMIT_RE.match(url), url


def test_expected_hash_constants_match_the_validated_release_identities():
    module = _load_module()
    # These are the hashes proven against the real cross-platform-validated
    # local runtime cache; a change here must be a deliberate, reviewed
    # asset update, never an incidental edit.
    assert module.DIRECT_DKS_MODEL_CKPT_SHA256 == "d2a4aa53eb584d21eead358a4e66d1882ad182911be018f052b5da73be9096d0"
    assert module.DIRECT_DKS_MODEL_YAML_SHA256 == "440a13f67461b2cdad2bb1cb86c08ff27a8ec53093c4a24d4d7fc2c19cb9f5f5"
    assert module.DIRECT_DKS_MODEL_EXPECTED_SHA256[module.DIRECT_DKS_MODEL_FILENAME] == module.DIRECT_DKS_MODEL_CKPT_SHA256
    assert module.DIRECT_DKS_MODEL_EXPECTED_SHA256[module.DIRECT_DKS_MODEL_YAML] == module.DIRECT_DKS_MODEL_YAML_SHA256


# --- G: Windows primary path enforces hash ---------------------------------


def test_windows_bootstrap_pins_and_enforces_drumsep_hashes():
    text = BOOTSTRAP_WINDOWS.read_text(encoding="utf-8")
    assert '$drumsepModelCkptSha256 = "d2a4aa53eb584d21eead358a4e66d1882ad182911be018f052b5da73be9096d0"' in text
    assert '$drumsepModelYamlSha256 = "440a13f67461b2cdad2bb1cb86c08ff27a8ec53093c4a24d4d7fc2c19cb9f5f5"' in text
    assert "function Test-Sha256Match(" in text
    assert not _FLOATING_REF_RE.search(text.split("drumsepModelYamlUrl =")[1].splitlines()[0])

    # EnsureDrumsepAssets must call the verifier and fail closed on mismatch.
    start = text.index("function EnsureDrumsepAssets(")
    end = text.index("\nfunction ", start + 1)
    body = text[start:end]
    assert "Test-Sha256Match" in body
    assert "DrumsepAssetFailureReason" in body
    assert "Sha256 = $drumsepModelCkptSha256" in body
    assert "Sha256 = $drumsepModelYamlSha256" in body
    # A mismatched fresh download must be deleted, not left installed.
    assert "Remove-Item -Path $asset.Path -Force -ErrorAction SilentlyContinue" in body


# --- H: macOS/Linux fallback paths wire the same enforcement ---------------


def test_macos_and_linux_bootstraps_still_route_through_shared_preflight_and_classify_integrity():
    # macOS and Linux already used different prefixes for the sibling
    # "download failed"/"missing" reasons before this change
    # ("drumsep_model_download_failed" vs "model_download_failed"); the new
    # integrity reason follows each platform's own existing convention.
    macos_text = BOOTSTRAP_MACOS.read_text(encoding="utf-8")
    linux_text = BOOTSTRAP_LINUX.read_text(encoding="utf-8")
    for text, label in ((macos_text, "macOS"), (linux_text, "Linux")):
        assert "_direct_dks_preflight_check(" in text, label
        assert "asset_integrity_mismatch:*" in text, label
    assert "drumsep_model_integrity_failed" in macos_text
    assert '"model_integrity_failed"' in linux_text


# --- I: integrity mismatch classified distinctly from network failure -----


def test_reason_classifier_distinguishes_integrity_from_network_and_missing():
    module = _load_module()
    assert module._classify_direct_dks_preflight_reason("asset_integrity_mismatch:foo.ckpt:expected=a:actual=b") == (
        "drumsep_model_integrity_failed"
    )
    assert module._classify_direct_dks_preflight_reason(
        "asset_download_failed:foo.ckpt:target=/x:source=https://example.invalid:oserror: timed out"
    ) == "drumsep_model_download_failed"
    assert module._classify_direct_dks_preflight_reason("catalog_entry_empty") == "drumsep_model_missing"
    assert module._classify_direct_dks_preflight_reason("unsupported_requested_model") == "drumsep_model_missing"


def test_lua_surfaces_integrity_failure_reason_distinctly_from_download_failure():
    text = (ROOT / "scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")
    assert 'error_reason=drumsep_model_integrity_failed", 1, true' in text
    assert "did not match its expected checksum" in text


# --- network-gated audit: prove the real pins still resolve ---------------


@needs_network
def test_network_drumsep_yaml_pinned_url_matches_validated_hash():
    import urllib.request

    module = _load_module()
    with urllib.request.urlopen(module.DIRECT_DKS_MODEL_YAML_URL, timeout=60) as resp:
        data = resp.read()
    assert hashlib.sha256(data).hexdigest() == module.DIRECT_DKS_MODEL_YAML_SHA256


@needs_network
def test_network_drumsep_checkpoint_mirror_pinned_url_matches_validated_hash():
    import urllib.request

    module = _load_module()
    with urllib.request.urlopen(module.DIRECT_DKS_MODEL_MIRROR_CKPT_URL, timeout=120) as resp:
        data = resp.read()
    assert hashlib.sha256(data).hexdigest() == module.DIRECT_DKS_MODEL_CKPT_SHA256


@needs_network
def test_network_windows_primary_checkpoint_url_matches_validated_hash():
    import urllib.request

    text = BOOTSTRAP_WINDOWS.read_text(encoding="utf-8")
    match = re.search(r'\$drumsepModelCkptUrl = "([^"]+)"', text)
    assert match
    url = match.group(1)
    with urllib.request.urlopen(url, timeout=120) as resp:
        data = resp.read()
    assert hashlib.sha256(data).hexdigest() == "d2a4aa53eb584d21eead358a4e66d1882ad182911be018f052b5da73be9096d0"
