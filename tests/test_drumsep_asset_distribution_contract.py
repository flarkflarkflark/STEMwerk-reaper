"""Repository conformance for the shared DrumSep compatibility-config contract."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

import pytest


ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = ROOT / "tools/assets/drumsep/compatibility_config_contract.json"
ASSET_PATH = ROOT / "tools/assets/drumsep/config_drumsep_mdx23c.yaml"
REQUIRED_PLATFORM_FIELDS = {
    "distribution_required",
    "distribution_channels",
    "required_payload_variants",
    "canonical_source_required",
    "materializer_required",
    "materializer_entrypoint",
    "migration_supported",
    "migration_source_ids",
    "canonical_noop_required",
    "unknown_checksum_fail_closed",
    "no_network_required",
    "inventory_audit_required",
    "release_gate_required",
}


def _contract() -> dict:
    return json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))


def _text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def _linux_online_inventory_conforms() -> bool:
    inventory = _contract()["online_inventories"]["linux_reapack"]
    wanted_file = f'../{inventory["installed_source_path_relative_to_scripts"]}'
    wanted_suffix = f'/main/{inventory["repository_source_path"]}'
    sources = ET.parse(ROOT / inventory["index_path"]).findall(".//source")
    return sum(
        source.get("file") == wanted_file and (source.text or "").strip().endswith(wanted_suffix)
        for source in sources
    ) == 1


def _linux_materializer_conforms() -> bool:
    bootstrap = _text("scripts/reaper/STEMwerk_Bootstrap_Linux.sh")
    if "materialize_drumsep_compat_yaml" not in bootstrap:
        return False
    body = _materializer_body(bootstrap, "materialize_drumsep_compat_yaml")
    required_markers = (
        "linux_drumsep_config_source_path",
        "linux_drumsep_config_source_size",
        "linux_drumsep_config_source_sha256",
        "linux_drumsep_config_source_status",
        "migrated_known_legacy_crlf",
        "existing_checksum_mismatch",
        "atomic_replace_failed",
    )
    return (
        all(marker in body for marker in required_markers)
        and "curl" not in body
        and "wget" not in body
        and body.index("linux_drumsep_config_source_status=canonical")
        < body.index('if [ -e "${_target}" ]')
    )


def test_shared_contract_schema_and_canonical_asset_are_closed() -> None:
    contract = _contract()
    payload = ASSET_PATH.read_bytes()

    assert ASSET_PATH.name == contract["filename"]
    assert len(payload) == contract["canonical"]["size"] == 2331
    assert hashlib.sha256(payload).hexdigest() == contract["canonical"]["sha256"]
    assert payload.count(b"\n") == contract["canonical"]["lf_count"] == 86
    assert payload.count(b"\r") == contract["canonical"]["cr_count"] == 0
    assert contract["legacy_crlf"] == {
        "size": 2417,
        "sha256": "17d1649a227f841165bdb4c11a42082898192a1ea3ceab7e7e0b9293d6589dd6",
        "status": "supported_migration_source",
        "newlines": "CRLF",
    }
    assert set(contract["platforms"]) == {"macos", "windows", "linux"}
    assert contract["online_inventories"]["linux_reapack"] == {
        "index_path": "index.xml",
        "repository_source_path": "tools/assets/drumsep/config_drumsep_mdx23c.yaml",
        "installed_source_path_relative_to_scripts": "assets/drumsep/config_drumsep_mdx23c.yaml",
        "marker_prefix": "linux_drumsep_config",
    }

    for platform_name, obligations in contract["platforms"].items():
        assert set(obligations) == REQUIRED_PLATFORM_FIELDS, platform_name
        for list_field in (
            "distribution_channels",
            "required_payload_variants",
            "migration_source_ids",
        ):
            values = obligations[list_field]
            assert values and all(isinstance(value, str) and value for value in values)
            assert len(values) == len(set(values)), f"{platform_name}.{list_field} must be unique"
        for required_true in (
            "distribution_required",
            "canonical_source_required",
            "materializer_required",
            "migration_supported",
            "canonical_noop_required",
            "unknown_checksum_fail_closed",
            "no_network_required",
            "inventory_audit_required",
            "release_gate_required",
        ):
            assert obligations[required_true] is True, f"{platform_name}.{required_true} must be true"
        assert obligations["migration_source_ids"] == ["legacy_crlf"]
        assert (ROOT / obligations["materializer_entrypoint"]).is_file()


def test_macos_distribution_conforms_to_contract() -> None:
    obligations = _contract()["platforms"]["macos"]
    builder = _text("tools/build_macos_apple_silicon_payload.py")
    stage = _text("installer/macos/build_pkg.sh")
    bootstrap = _text(obligations["materializer_entrypoint"])
    release_gate = _text("tools/release_gate.py")

    assert obligations["required_payload_variants"] == [
        "bundled-apple-silicon",
        "offline-bundled-apple-silicon-mps-allmodels",
    ]
    assert "DRUMSEP_COMPAT_ASSET" in builder
    assert "drumsep_file_inventory" in builder
    for variant in obligations["required_payload_variants"]:
        assert variant in stage
    for marker in (
        "materialized_from_payload",
        "already_materialized",
        "migrated_known_legacy_crlf",
        "existing_checksum_mismatch",
        "atomic_replace_failed",
    ):
        assert marker in bootstrap
    assert "curl" not in _materializer_body(bootstrap, "materialize_drumsep_compat_yaml")
    assert "wget" not in _materializer_body(bootstrap, "materialize_drumsep_compat_yaml")
    assert "tools/build_macos_apple_silicon_payload.py" in release_gate
    assert "DRUMSEP_COMPAT_ASSET" in release_gate


def test_windows_distribution_conforms_to_contract() -> None:
    obligations = _contract()["platforms"]["windows"]
    iss = _text("installer/windows/STEMwerk.iss")
    online_builder = _text("installer/windows/build_online_installers.ps1")
    offline_builder = _text("installer/windows/build_bundled_model_installers.ps1")
    payload_builder = _text("tools/build_windows_drumsep_payload.py")
    bootstrap = _text(obligations["materializer_entrypoint"])
    release_gate = _text("tools/release_gate.py")

    assert obligations["required_payload_variants"] == [
        "online",
        "online-bundled",
        "offline-bundled-cpu-allmodels",
        "offline-bundled-amd-gpu-allmodels",
        "offline-bundled-nvidia-gpu-allmodels",
    ]
    assert 'Source: "..\\..\\tools\\assets\\drumsep\\config_drumsep_mdx23c.yaml"' in iss
    assert 'Build-OnlineVariant $isccPath ""' in online_builder
    assert 'Build-OnlineVariant $isccPath "-bundled"' in online_builder
    for flavor in ('"cpu"', '"amd"', '"nvidia"'):
        assert f"Build-Flavor {flavor}" in offline_builder
    assert "DRUMSEP_COMPAT_CONTRACT" in payload_builder
    assert "DRUMSEP_MODEL_POLICY" in payload_builder
    assert "audit_payload" in payload_builder
    for marker in (
        "created_from_bundled_payload",
        "canonical_checksum_match",
        "migrated_known_legacy_crlf",
        "existing_checksum_mismatch",
        "atomic_materialization_failed",
    ):
        assert marker in bootstrap
    materializer = _materializer_body(bootstrap, "MaterializeDrumsepCompatYaml")
    assert "Invoke-WebRequest" not in materializer
    assert "Start-BitsTransfer" not in materializer
    assert "installer/windows/STEMwerk.iss" in release_gate
    assert "DRUMSEP_COMPAT_CONTRACT_PATH" in release_gate


def _materializer_body(source: str, function_name: str) -> str:
    start = source.index(function_name)
    next_function = source.find("\nfunction ", start + len(function_name))
    return source[start:] if next_function == -1 else source[start:next_function]


LINUX_GAPS = (
    (
        "online-minimal",
        _linux_online_inventory_conforms,
        "Linux online-minimal payload does not distribute the canonical DrumSep compatibility config required by the shared contract.",
    ),
    (
        "offline-cpu",
        lambda: "config_drumsep_mdx23c.yaml" in _text("tools/build_linux_variant_payload.py"),
        "Linux offline CPU payload does not distribute the canonical DrumSep compatibility config required by the shared contract.",
    ),
    (
        "offline-rocm",
        lambda: "config_drumsep_mdx23c.yaml" in _text("tools/build_linux_variant_payload.py"),
        "Linux offline ROCm payload does not distribute the canonical DrumSep compatibility config required by the shared contract.",
    ),
    (
        "offline-nvidia",
        lambda: "config_drumsep_mdx23c.yaml" in _text("tools/build_linux_variant_payload.py"),
        "Linux offline NVIDIA payload does not distribute the canonical DrumSep compatibility config required by the shared contract.",
    ),
    (
        "materializer",
        _linux_materializer_conforms,
        "Linux bootstrap does not implement the contract-declared legacy CRLF to canonical LF migration.",
    ),
    (
        "release-gate",
        lambda: "STEMwerk_Bootstrap_Linux.sh" in _text("tools/release_gate.py")
        and "config_drumsep_mdx23c.yaml" in _text("tools/release_gate.py"),
        "Release gate does not enforce Linux online DrumSep compatibility-config distribution and materialization.",
    ),
)


@pytest.mark.parametrize("_gap,evidence,message", LINUX_GAPS, ids=[gap[0] for gap in LINUX_GAPS])
def test_linux_distribution_conforms_to_contract(_gap: str, evidence, message: str) -> None:
    obligations = _contract()["platforms"]["linux"]
    assert obligations["required_payload_variants"] == [
        "online-minimal",
        "offline-bundled-cpu-allmodels",
        "offline-bundled-rocm-allmodels",
        "offline-bundled-cuda-allmodels",
    ]
    assert evidence(), message


def test_linux_offline_gap_tracking_remains_explicit_and_red() -> None:
    offline_gaps = {gap: evidence for gap, evidence, _message in LINUX_GAPS if gap.startswith("offline-")}

    assert set(offline_gaps) == {"offline-cpu", "offline-rocm", "offline-nvidia"}
    assert {gap: evidence() for gap, evidence in offline_gaps.items()} == {
        "offline-cpu": False,
        "offline-rocm": False,
        "offline-nvidia": False,
    }


def test_ci_fast_selects_only_linux_offline_gap_meta_test() -> None:
    module_path = "tests/test_drumsep_asset_distribution_contract.py"
    meta_test_name = "test_linux_offline_gap_tracking_remains_explicit_and_red"
    meta_node_id = f"{module_path}::{meta_test_name}"
    workflow = _text(".github/workflows/ci-full.yml")
    ci_fast_selection = workflow.split("- name: Run curated fast pytest coverage", 1)[1].split(
        "\n      - name:", 1
    )[0]
    distribution_selections = re.findall(
        rf"{re.escape(module_path)}(?:::[A-Za-z0-9_\[\]-]+)?", ci_fast_selection
    )

    assert re.search(rf"^def {meta_test_name}\(.*\).*:$", _text(module_path), re.MULTILINE)
    assert distribution_selections.count(meta_node_id) == 1
    assert module_path not in distribution_selections
    assert not {
        f"{module_path}::test_linux_distribution_conforms_to_contract[{gap}]"
        for gap in ("offline-cpu", "offline-rocm", "offline-nvidia")
    }.intersection(distribution_selections)
