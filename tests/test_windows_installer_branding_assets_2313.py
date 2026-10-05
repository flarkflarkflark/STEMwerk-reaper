"""Regression test for the Windows installer branding defect: both
STEMwerk-Setup-2.3.1.3.exe and STEMwerk-Setup-2.3.1.3-bundled.exe shipped
with the wrong EXE/setup icon, the wrong large wizard-side image, and the
wrong small upper-right wizard image.

Root cause: `.github/workflows/release-installers.yml`'s `windows-exe` job
had a "Generate installer assets from SVG" step that unconditionally
regenerated installer/assets/stemwerk.png (and, from that, stemwerk.ico and
stemwerk-wizard.bmp) from installer/assets/stemwerk.svg -- a 1024x512
white-background two-tone wordmark banner, not the square colourful STEMwerk
application icon -- every time `stemwerk.svg` exists (which it always does,
as a committed file). This ran before Inno Setup compiled either installer
variant, silently overwriting the correct, already-committed canonical
artwork (restored once before, in f208398a3, but the generator step was
never updated to stop re-breaking it).

All three observed defects share this one root cause: STEMwerk.iss's
SetupIconFile points at stemwerk.ico (derived from the overwritten png),
WizardImageFile at stemwerk-wizard.bmp (same), and WizardSmallImageFile
points at stemwerk.png directly -- so clobbering that one file alone was
enough to break all three branding surfaces at once.

These are source/workflow contract tests, not pixel comparisons: the actual
visual result still needs a real ISCC compile (see
test_windows_installer_welcome_finish_2313.py's test_installer_compiles_with_the_real_iscc)
and, ultimately, a human launching the built installer.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_PATH = ROOT / ".github" / "workflows" / "release-installers.yml"
ISS_PATH = ROOT / "installer" / "windows" / "STEMwerk.iss"
ASSETS_DIR = ROOT / "installer" / "assets"

CANONICAL_ASSETS = (
    "stemwerk.ico",
    "stemwerk.png",
    "stemwerk-wizard.bmp",
)


def _workflow_text() -> str:
    return WORKFLOW_PATH.read_text(encoding="utf-8")


def _windows_exe_job() -> dict:
    workflow = yaml.safe_load(_workflow_text())
    return workflow["jobs"]["windows-exe"]


def _step_run_texts(job: dict) -> list[str]:
    return [step.get("run", "") for step in job["steps"] if "run" in step]


# --- CI must not regenerate/overwrite the canonical assets ----------------------


def test_ci_no_longer_regenerates_assets_from_the_svg():
    """The exact regression: a step that ran `magick ... stemwerk.svg ...
    stemwerk.png` (etc.) before every Inno Setup compile must not exist."""
    runs = _step_run_texts(_windows_exe_job())
    combined = "\n".join(runs)
    assert "stemwerk.svg" not in combined, (
        "a CI step still derives installer assets from stemwerk.svg -- "
        "this is exactly what overwrote the canonical branding"
    )
    assert "magick" not in combined.lower(), "ImageMagick asset generation must not run in this job"
    assert "Generate installer assets from SVG" not in _workflow_text()


def test_ci_no_longer_installs_the_now_unused_imagemagick_dependency():
    runs = _step_run_texts(_windows_exe_job())
    assert not any("imagemagick" in r.lower() for r in runs), (
        "imagemagick was only installed for the removed asset-generation step"
    )


def test_ci_never_writes_to_the_canonical_asset_paths():
    """Broader guard than just the removed step: no `run:` block in this job
    may write to any of the three canonical branding files, by any means."""
    for run in _step_run_texts(_windows_exe_job()):
        for name in CANONICAL_ASSETS:
            # A reference alone (e.g. reading it) is fine; what must never
            # reappear is a write targeting these specific filenames.
            for write_marker in (f'"{name}"', f"'{name}'", name):
                if write_marker not in run:
                    continue
                # Only flag if this looks like an output target, not a plain
                # mention (Inno Setup's own compile step legitimately runs
                # with STEMwerk.iss, which just *references* these names).
                assert not re.search(rf">\s*.*{re.escape(name)}", run), (
                    f"a workflow step appears to write to canonical asset {name!r}"
                )


# --- STEMwerk.iss must reference the intended, committed assets -----------------


def _iss_text() -> str:
    return ISS_PATH.read_text(encoding="utf-8")


def test_iss_setup_icon_points_at_the_canonical_ico():
    assert "SetupIconFile=..\\assets\\stemwerk.ico" in _iss_text()


def test_iss_large_wizard_image_points_at_the_canonical_bmp():
    text = _iss_text()
    assert "WizardImageFile=..\\assets\\stemwerk-wizard.bmp" in text
    assert "WizardImageFileDynamicDark=..\\assets\\stemwerk-wizard.bmp" in text


def test_iss_small_wizard_image_points_at_the_canonical_png():
    """The small/top-right wizard image is WizardSmallImageFile, and in this
    installer it is the same stemwerk.png used for the large image's source
    -- so overwriting stemwerk.png alone was enough to break this surface
    too, independent of stemwerk.ico/stemwerk-wizard.bmp."""
    text = _iss_text()
    assert "WizardSmallImageFile=..\\assets\\stemwerk.png" in text
    assert "WizardSmallImageFileDynamicDark=..\\assets\\stemwerk.png" in text


def test_iss_never_references_the_wordmark_svg_or_its_derived_small_bmp():
    text = _iss_text()
    assert "stemwerk.svg" not in text
    assert "stemwerk-wizard-small.bmp" not in text, (
        "this file was only ever produced by the removed generator step and "
        "is not Inno's WizardSmallImageFile source -- it must not become a "
        "dependency of the real build"
    )


# --- Canonical assets must actually exist as committed binary files -------------


@pytest.mark.parametrize("name", CANONICAL_ASSETS)
def test_canonical_asset_exists_and_is_nonempty(name):
    path = ASSETS_DIR / name
    assert path.is_file(), f"missing canonical installer asset: {path}"
    assert path.stat().st_size > 1024, f"{name} is suspiciously small for real artwork"


def test_canonical_icon_is_square_like_an_app_icon_not_the_wide_wordmark():
    """ico files start with a 6-byte ICONDIR header (reserved=0, type=1,
    count=N) followed by ICONDIRENTRY records whose first two bytes are the
    (square) width/height in pixels (0 means 256). This is a structural
    sanity check, not a pixel comparison: the point is to catch a banner-like
    non-square image being swapped back in, not to validate exact pixels."""
    data = (ASSETS_DIR / "stemwerk.ico").read_bytes()
    reserved, img_type, count = int.from_bytes(data[0:2], "little"), int.from_bytes(data[2:4], "little"), int.from_bytes(data[4:6], "little")
    assert reserved == 0 and img_type == 1 and count >= 1, "not a well-formed .ico file"
    width, height = data[6], data[7]
    width = width or 256
    height = height or 256
    assert width == height, f"stemwerk.ico's first image is {width}x{height}, not square"


def test_canonical_png_is_square_like_an_app_icon_not_the_wide_wordmark():
    """PNG IHDR (bytes 16-23 of a valid PNG) holds width/height as two
    big-endian uint32s. The regression's replacement was 512x512 *rendered
    from* a 1024x512 source, which is square too, so this alone would not
    have caught it -- it is a baseline sanity check, paired with the ico
    structural check and the workflow/`.iss` contract tests above, which are
    what actually assert the SVG pipeline is gone."""
    data = (ASSETS_DIR / "stemwerk.png").read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a well-formed PNG file"
    width = int.from_bytes(data[16:20], "big")
    height = int.from_bytes(data[20:24], "big")
    assert width == height, f"stemwerk.png is {width}x{height}, not square"
    assert width >= 256, f"stemwerk.png is only {width}px -- too small for a crisp installer icon"
