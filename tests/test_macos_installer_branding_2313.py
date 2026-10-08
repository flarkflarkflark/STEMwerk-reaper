from pathlib import Path
import hashlib
import shutil
import struct
import subprocess
import sys
import xml.etree.ElementTree as ET
import zlib

import pytest


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "installer/macos/build_pkg.sh"
DISTRIBUTION = ROOT / "installer/macos/Distribution.xml"
CANONICAL_LOGO = ROOT / "installer/assets/stemwerk.png"
LOGO_RENDERER = ROOT / "installer/macos/render_installer_logo.py"
EXPECTED_CANONICAL_LOGO_SHA256 = (
    "7254f171d6b9809131f1b89c532463741f14c91e16ac256d45b93fdc558c7cb8"
)
MASK_RADIUS = 18
MASK_SAMPLES_PER_AXIS = 16


def _png_dimensions(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    assert data[:16] == b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"
    return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")


def _decode_rgba_png(path: Path) -> tuple[int, int, list[tuple[int, int, int, int]]]:
    data = path.read_bytes()
    assert data.startswith(b"\x89PNG\r\n\x1a\n")
    offset = 8
    idat = []
    while offset < len(data):
        length = int.from_bytes(data[offset : offset + 4], "big")
        kind = data[offset + 4 : offset + 8]
        payload = data[offset + 8 : offset + 8 + length]
        offset += length + 12
        if kind == b"IHDR":
            width, height, depth, color_type, compression, filtering, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
            assert (depth, color_type, compression, filtering, interlace) == (8, 6, 0, 0, 0)
        elif kind == b"IDAT":
            idat.append(payload)
        elif kind == b"IEND":
            break

    stride = width * 4
    filtered = zlib.decompress(b"".join(idat))
    rows = []
    previous = bytearray(stride)
    source_offset = 0
    for _ in range(height):
        filter_type = filtered[source_offset]
        source_offset += 1
        source = filtered[source_offset : source_offset + stride]
        source_offset += stride
        row = bytearray(stride)
        for index, value in enumerate(source):
            left = row[index - 4] if index >= 4 else 0
            above = previous[index]
            upper_left = previous[index - 4] if index >= 4 else 0
            if filter_type == 0:
                decoded = value
            elif filter_type == 1:
                decoded = value + left
            elif filter_type == 2:
                decoded = value + above
            elif filter_type == 3:
                decoded = value + ((left + above) // 2)
            elif filter_type == 4:
                estimate = left + above - upper_left
                distances = (
                    abs(estimate - left),
                    abs(estimate - above),
                    abs(estimate - upper_left),
                )
                decoded = value + (left, above, upper_left)[distances.index(min(distances))]
            else:
                raise AssertionError(f"unexpected filter type {filter_type}")
            row[index] = decoded & 0xFF
        rows.extend(tuple(row[index : index + 4]) for index in range(0, stride, 4))
        previous = row
    return width, height, rows


def _expected_mask_coverage(x: int, y: int) -> int:
    samples = MASK_SAMPLES_PER_AXIS
    scale = 2 * samples
    size = 128 * scale
    radius = MASK_RADIUS * scale
    left = x < MASK_RADIUS
    right = x >= 128 - MASK_RADIUS
    top = y < MASK_RADIUS
    bottom = y >= 128 - MASK_RADIUS
    if not ((left or right) and (top or bottom)):
        return samples * samples

    covered = 0
    for sample_y in range(samples):
        vertical = y * scale + 2 * sample_y + 1
        if bottom:
            vertical = size - vertical
        for sample_x in range(samples):
            horizontal = x * scale + 2 * sample_x + 1
            if right:
                horizontal = size - horizontal
            total = horizontal + vertical
            inside = total >= radius or 4 * horizontal * vertical >= (radius - total) ** 2
            covered += int(inside)
    return covered


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
    assert hashlib.sha256(CANONICAL_LOGO.read_bytes()).hexdigest() == EXPECTED_CANONICAL_LOGO_SHA256
    assert 'BRANDING_ASSET="$ROOT_DIR/installer/assets/stemwerk.png"' in script
    assert 'BRANDING_RENDERER="$ROOT_DIR/installer/macos/render_installer_logo.py"' in script
    resize = 'sips -Z 128 "$BRANDING_ASSET" --out "$BRANDING_RESIZE"'
    mask = 'python3 "$BRANDING_RENDERER" \\\n  "$BRANDING_RESIZE" \\\n  "$INSTALLER_RESOURCES/stemwerk.png"'
    assert resize in script
    assert mask in script
    assert script.index(resize) < script.index(mask)
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


@pytest.mark.skipif(shutil.which("sips") is None, reason="macOS sips required")
def test_installer_logo_renderer_is_alpha_only_and_deterministic(tmp_path: Path) -> None:
    baseline = tmp_path / "baseline.png"
    subprocess.run(
        ["sips", "-Z", "128", str(CANONICAL_LOGO), "--out", str(baseline)],
        check=True,
        capture_output=True,
        text=True,
    )
    outputs = [tmp_path / f"masked-{index}.png" for index in range(3)]
    for output in outputs:
        subprocess.run([sys.executable, str(LOGO_RENDERER), str(baseline), str(output)], check=True)

    output_bytes = [output.read_bytes() for output in outputs]
    assert output_bytes[0] == output_bytes[1] == output_bytes[2]
    assert len({hashlib.sha256(data).hexdigest() for data in output_bytes}) == 1

    baseline_width, baseline_height, baseline_pixels = _decode_rgba_png(baseline)
    width, height, masked_pixels = _decode_rgba_png(outputs[0])
    assert (baseline_width, baseline_height) == (width, height) == (128, 128)
    assert len(baseline_pixels) == len(masked_pixels) == 128 * 128
    assert all(before[:3] == after[:3] for before, after in zip(baseline_pixels, masked_pixels))

    expected_alphas = []
    for y in range(128):
        for x in range(128):
            coverage = _expected_mask_coverage(x, y)
            source_alpha = baseline_pixels[y * 128 + x][3]
            expected_alphas.append(
                (source_alpha * coverage + (MASK_SAMPLES_PER_AXIS**2 // 2))
                // MASK_SAMPLES_PER_AXIS**2
            )
    assert [pixel[3] for pixel in masked_pixels] == expected_alphas

    corners = (0, 127, 127 * 128, 128 * 128 - 1)
    assert all(masked_pixels[index][3] == 0 for index in corners)
    center = 64 * 128 + 64
    assert masked_pixels[center] == baseline_pixels[center]
    for x, y in ((64, 2), (1, 64), (126, 64), (64, 126)):
        index = y * 128 + x
        assert masked_pixels[index][:3] == baseline_pixels[index][:3]
        assert masked_pixels[index][3] == baseline_pixels[index][3] > 0

    partial = [
        index
        for index, pixel in enumerate(masked_pixels)
        if 0 < pixel[3] < baseline_pixels[index][3]
    ]
    assert partial
    assert all(
        (index % 128 < MASK_RADIUS or index % 128 >= 128 - MASK_RADIUS)
        and (index // 128 < MASK_RADIUS or index // 128 >= 128 - MASK_RADIUS)
        for index in partial
    )

    inspected = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", str(outputs[0])],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    assert "pixelWidth: 128" in inspected
    assert "pixelHeight: 128" in inspected
    assert "hasAlpha: yes" in inspected


def test_installer_logo_renderer_rejects_an_unresized_input(tmp_path: Path) -> None:
    output = tmp_path / "must-not-exist.png"
    result = subprocess.run(
        [sys.executable, str(LOGO_RENDERER), str(CANONICAL_LOGO), str(output)],
        capture_output=True,
        text=True,
    )
    assert result.returncode != 0
    assert "unsupported sips PNG format" in result.stderr
    assert not output.exists()


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
