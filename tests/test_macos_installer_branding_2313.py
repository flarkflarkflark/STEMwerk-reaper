from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET

import pytest


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "installer/macos/build_pkg.sh"
DISTRIBUTION = ROOT / "installer/macos/Distribution.xml"
CANONICAL_LOGO = ROOT / "installer/assets/stemwerk.png"


def _png_dimensions(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    assert data[:16] == b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


def test_distribution_declares_native_stemwerk_installer_branding() -> None:
    root = ET.parse(DISTRIBUTION).getroot()
    assert root.tag == "installer-gui-script"
    assert root.findtext("title") == "STEMwerk"
    background = root.find("background")
    assert background is not None
    assert background.attrib == {
        "file": "stemwerk.png",
        "mime-type": "image/png",
        "alignment": "bottomleft",
        "scaling": "none",
    }
    package_ref = root.findall("pkg-ref")[-1]
    assert package_ref.attrib["id"] == "com.flarkaudio.stemwerk"
    assert package_ref.text == "STEMwerk-component.pkg"


def test_shared_macos_builder_wraps_both_variants_as_branded_products() -> None:
    script = BUILD_SCRIPT.read_text(encoding="utf-8")
    assert CANONICAL_LOGO.is_file()
    assert 'BRANDING_ASSET="$ROOT_DIR/installer/assets/stemwerk.png"' in script
    assert 'cp -p "$BRANDING_ASSET" "$INSTALLER_RESOURCES/stemwerk.png"' in script
    assert 'sips -Z 128 "$INSTALLER_RESOURCES/stemwerk.png"' in script
    assert 'pkgbuild \\' in script
    assert '"$COMPONENT_PKG"' in script
    assert 'productbuild \\' in script
    assert '--distribution "$DISTRIBUTION_FILE"' in script
    assert '--resources "$INSTALLER_RESOURCES"' in script
    assert '--package-path "$BUILD_DIR"' in script
    assert script.index("pkgbuild \\") < script.index("productbuild \\")
    assert script.index("productbuild \\") < script.index('python3 "$PACKAGE_AUDITOR"')
    assert 'online)' in script
    assert 'bundled-apple-silicon)' in script


@pytest.mark.skipif(shutil.which("pkgutil") is None, reason="macOS package tools required")
@pytest.mark.parametrize(
    "package_name",
    ["STEMwerk-2.3.1.3.pkg", "STEMwerk-2.3.1.3-bundled-apple-silicon.pkg"],
)
def test_built_product_contains_branded_distribution_and_unchanged_component_contract(
    tmp_path: Path, package_name: str
) -> None:
    package = ROOT / "installer/macos/dist" / package_name
    if not package.is_file():
        pytest.skip(f"package not built: {package}")
    expanded = tmp_path / "expanded"
    subprocess.run(["pkgutil", "--expand", str(package), str(expanded)], check=True)

    distribution = ET.parse(expanded / "Distribution").getroot()
    assert distribution.findtext("title") == "STEMwerk"
    background = distribution.find("background")
    assert background is not None
    assert background.attrib["file"] == "stemwerk.png"
    assert background.attrib["alignment"] == "bottomleft"
    assert background.attrib["scaling"] == "none"
    assert _png_dimensions(expanded / "Resources/stemwerk.png") == (128, 128)

    package_info = ET.parse(expanded / "STEMwerk-component.pkg/PackageInfo").getroot()
    assert package_info.attrib["identifier"] == "com.flarkaudio.stemwerk"
    assert package_info.attrib["version"] == "2.3.1.3"
