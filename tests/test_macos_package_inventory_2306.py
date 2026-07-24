import importlib.util
import json
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
AUDITOR = ROOT / "installer/macos/audit_payload.py"
MANIFEST = ROOT / "installer/macos/payload-manifest.txt"


def load_auditor():
    spec = importlib.util.spec_from_file_location("macos_payload_auditor", AUDITOR)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


def manifest_destinations():
    return {
        line.split("\t", 1)[1]
        for line in MANIFEST.read_text().splitlines()
        if line and not line.startswith("#")
    }


@pytest.mark.parametrize("name", [
    "STEMwerk_Bootstrap_Windows.ps1", "STEMwerk_Bootstrap_Linux.sh",
    "STEMwerk_Bootstrap_Linux_Launcher.sh", "vendor/wheels/linux-x86_64-cp312/bad.whl",
    "bad-win_amd64.whl", "._payload", "update-patch/data", "allmodels/model.bin",
])
def test_forbidden_content_is_not_allowlisted(name):
    assert name not in manifest_destinations()


def test_required_target_neutral_and_macos_files_are_allowlisted():
    destinations = manifest_destinations()
    assert {"STEMwerk.lua", "audio_separator_process.py", "STEMwerk_Bootstrap_macOS.sh"} <= destinations
    assert {"_internal/STEMwerk_Helpers.lua", "_internal/STEMwerk_Managed_Python.lua"} <= destinations
    assert {"vendor/stemwerk-core/src/stemwerk_core/models.py", "i18n/languages.lua"} <= destinations


def test_manifest_destinations_are_unique():
    destinations = [
        line.split("\t", 1)[1]
        for line in MANIFEST.read_text().splitlines()
        if line and not line.startswith("#")
    ]
    assert len(destinations) == len(set(destinations))


@pytest.mark.parametrize("relative", ["bad-manylinux.whl", "bad-linux_x86_64.whl"])
def test_linux_wheel_injection_is_rejected(tmp_path, relative):
    path = tmp_path / relative
    path.write_bytes(b"wheel")
    _, counts = load_auditor().inventory(tmp_path)
    assert counts["linux_wheels"] == 1


def test_windows_launcher_injection_is_rejected(tmp_path):
    (tmp_path / "STEMwerk_Bootstrap_Windows.ps1").write_text("bad")
    _, counts = load_auditor().inventory(tmp_path)
    assert counts["windows"] == 1


def test_appledouble_injection_is_rejected(tmp_path):
    (tmp_path / "._payload").write_bytes(b"bad")
    records, counts = load_auditor().inventory(tmp_path)
    assert records[0]["classification"] == "unknown"
    assert counts["appledouble"] == 1


@pytest.mark.parametrize("variant", ["online", "bundled-apple-silicon"])
def test_clean_staged_inventory_contract(variant):
    inventory = ROOT / f"installer/macos/build/{variant}/payload-inventory.json"
    if not inventory.is_file():
        pytest.skip("dry stage has not been built")
    data = json.loads(inventory.read_text())
    assert not any(data["counts"].values())
    paths = {item["path"] for item in data["files"]}
    assert "STEMwerk_Bootstrap_macOS.sh" in paths
    assert "_internal/STEMwerk_Helpers.lua" in paths
    assert "vendor/stemwerk-core/src/stemwerk_core/models.py" in paths
    if variant == "online":
        assert not any(path.startswith("_bundled/") for path in paths)
    else:
        assert "_bundled/macos/apple-silicon/manifest.json" in paths


def test_builder_starts_from_empty_stage_and_keeps_receipt_version():
    script = (ROOT / "installer/macos/build_pkg.sh").read_text()
    assert script.index('rm -rf "$STAGE"') < script.index('mkdir -p "$OUT_DIR"')
    assert '--version "$VERSION"' in script


def test_manifest_has_no_duplicate_destination_fixture(tmp_path):
    fixture = tmp_path / "manifest"
    fixture.write_text("one\tsame\ntwo\tsame\n")
    result = subprocess.run(
        ["awk", "-F", "\\t", "{if (seen[$2]++) exit 1}", str(fixture)]
    )
    assert result.returncode != 0
