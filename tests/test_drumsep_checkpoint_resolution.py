"""Focused regression coverage for read-only DrumSep checkpoint resolution."""

import importlib.util
from pathlib import Path

import pytest


def _load_helper():
    path = Path("scripts/reaper/_internal/stemwerk_drumsep_process.py")
    spec = importlib.util.spec_from_file_location("stemwerk_drumsep_checkpoint_resolution_test", path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def _managed_cache(tmp_path, *, alias_bytes=None):
    helper = _load_helper()
    canonical = tmp_path / helper.DRUMSEP_MODEL_FILENAME
    config = tmp_path / helper.ASEP_0443_DRUMSEP_CONFIG_FILENAME
    canonical.write_bytes(b"managed-canonical-checkpoint")
    config.write_text("audio: {}\nmodel: {}\ntraining: {}\n", encoding="utf-8")
    if alias_bytes is not None:
        (tmp_path / helper.ASEP_0443_DRUMSEP_MODEL_FILENAME).write_bytes(alias_bytes)
    return helper, canonical, config


def _inventory(root):
    return {
        path.name: (
            path.stat().st_size,
            path.stat().st_ctime_ns,
            path.stat().st_mtime_ns,
            path.read_bytes(),
        )
        for path in root.iterdir()
        if path.is_file()
    }


def _resolve(helper, root, requested=None):
    return helper._resolve_drumsep_catalog_cache_for_runtime(
        root,
        requested or helper.DRUMSEP_MODEL_ALIAS,
        expected_legacy_sha256="",
        expected_config_sha256="",
    )


def test_canonical_checkpoint_is_selected_without_creating_alias(tmp_path):
    helper, canonical, _config = _managed_cache(tmp_path)
    before = _inventory(tmp_path)

    result = _resolve(helper, tmp_path)

    assert result.model_name == helper.DRUMSEP_MODEL_FILENAME
    assert result.resolved_model_file == canonical
    assert result.action == "use_canonical"
    assert _inventory(tmp_path) == before
    assert not (tmp_path / helper.ASEP_0443_DRUMSEP_MODEL_FILENAME).exists()
    print("DKS_CANONICAL_CHECKPOINT_RESOLUTION_TEST=PASS")
    print("DKS_PROCESSING_NO_ALIAS_COPY_TEST=PASS")


def test_byte_identical_alias_is_tolerated_but_canonical_remains_deterministic(tmp_path):
    helper, canonical, _config = _managed_cache(tmp_path)
    alias = tmp_path / helper.ASEP_0443_DRUMSEP_MODEL_FILENAME
    alias.write_bytes(canonical.read_bytes())
    before = _inventory(tmp_path)

    result = _resolve(helper, tmp_path)

    assert result.action == "use_canonical_alias_compatible"
    assert result.resolved_model_file == canonical
    assert _inventory(tmp_path) == before


def test_unknown_alias_hash_fails_closed_without_overwrite(tmp_path):
    helper, _canonical, _config = _managed_cache(tmp_path, alias_bytes=b"unknown-alias")
    before = _inventory(tmp_path)

    with pytest.raises(helper.DirectDemixValidationError) as exc_info:
        _resolve(helper, tmp_path)

    assert exc_info.value.reason == "drumsep_checkpoint_alias_checksum_mismatch"
    assert _inventory(tmp_path) == before
    print("DKS_UNKNOWN_ALIAS_HASH_FAIL_CLOSED_TEST=PASS")


@pytest.mark.parametrize(
    ("route", "marker"),
    [
        ("direct_kit", "DKS_DIRECT_PROCESSING_IMMUTABILITY_TEST=PASS"),
        ("kit_split", "DKS_SPLIT_PROCESSING_IMMUTABILITY_TEST=PASS"),
    ],
)
def test_processing_routes_share_read_only_resolution(tmp_path, route, marker):
    helper, canonical, _config = _managed_cache(tmp_path)
    before = _inventory(tmp_path)

    result = _resolve(helper, tmp_path)

    assert route in {"direct_kit", "kit_split"}
    assert result.resolved_model_file == canonical
    assert result.markers["dks_model_migration_action"] == "use_canonical"
    assert _inventory(tmp_path) == before
    print(marker)


def test_second_processing_resolution_is_idempotent(tmp_path):
    helper, _canonical, _config = _managed_cache(tmp_path)
    before = _inventory(tmp_path)

    first = _resolve(helper, tmp_path)
    second = _resolve(helper, tmp_path)

    assert first.action == second.action == "use_canonical"
    assert first.resolved_model_file == second.resolved_model_file
    assert _inventory(tmp_path) == before


@pytest.mark.parametrize("requested", ["MDX23C-DrumSep-aufr33-jarredou.ckpt", "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt"])
def test_checkpoint_resolution_handles_platform_paths_and_spaces(tmp_path, requested):
    cache = tmp_path / "runtime model cache"
    cache.mkdir()
    helper, canonical, _config = _managed_cache(cache)

    result = _resolve(helper, cache, requested)

    assert result.resolved_model_file == canonical
    assert str(result.resolved_model_file).endswith(helper.DRUMSEP_MODEL_FILENAME)


def test_managed_catalog_adapter_uses_canonical_path_without_network(tmp_path):
    helper, canonical, config = _managed_cache(tmp_path)
    resolution = _resolve(helper, tmp_path)
    fallback_calls = []

    class FakeSeparator:
        def download_model_files(self, model_filename):
            fallback_calls.append(model_filename)
            raise AssertionError("managed DrumSep resolution must not use catalog/network fallback")

    separator = FakeSeparator()
    helper._configure_managed_drumsep_checkpoint(separator, resolution)
    resolved = separator.download_model_files(helper.DRUMSEP_MODEL_ALIAS)

    assert resolved == (
        helper.DRUMSEP_MODEL_FILENAME,
        "MDXC",
        "STEMwerk managed DrumSep 6stem",
        str(canonical),
        config.name,
    )
    assert fallback_calls == []
    print("DKS_NO_NETWORK_ALIAS_RESOLUTION_TEST=PASS")


def test_checkpoint_resolution_contract_is_cross_platform_and_has_no_copy_action(tmp_path):
    helper, canonical, _config = _managed_cache(tmp_path)
    source = Path(helper.__file__).read_text(encoding="utf-8")
    before = _inventory(tmp_path)

    result = _resolve(helper, tmp_path)

    assert result.resolved_model_file == canonical
    assert "shutil.copy2(canonical_model" not in source
    assert result.markers["dks_model_migration_action"] != "copy_alias"
    assert _inventory(tmp_path) == before
    print("DKS_CROSS_PLATFORM_CHECKPOINT_RESOLUTION_TEST=PASS")
