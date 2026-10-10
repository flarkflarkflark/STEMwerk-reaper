"""Regression coverage for the Windows installer disk-space preflight constants
(issue #120). A non-bundled/online install reported the real runtime
footprint reaching 4GB+ against the previously advertised 3GB, and later
failed mid-bootstrap with "No space left on device" while the installer
still went on to imply a normal completion.

These are static checks against the .iss source (no Inno Setup Compiler is
available on this Linux dev machine), mirroring the string/regex-assertion
style already used in tests/test_windows_payload_contract_2306.py.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ISS = ROOT / "installer" / "windows" / "STEMwerk.iss"

# Real observed footprint was 4GB+; require a floor with real headroom above that.
MIN_REQUIRED_MB_FLOOR = 4096

DEFINE_RE = re.compile(
    r'#if BundleRuntime == "1"\s*'
    r'.*?#define MinimumFreeSpaceMB "(?P<bundled_mb>\d+)"\s*'
    r'.*?#define ExtraDiskSpaceRequiredBytes "(?P<bundled_extra>\d+)"\s*'
    r'#else\s*'
    r'.*?#define MinimumFreeSpaceMB "(?P<plain_mb>\d+)"\s*'
    r'.*?#define ExtraDiskSpaceRequiredBytes "(?P<plain_extra>\d+)"\s*'
    r'#endif',
    re.DOTALL,
)


def _constants() -> dict[str, int]:
    text = ISS.read_text(encoding="utf-8")
    match = DEFINE_RE.search(text)
    assert match, "could not locate BundleRuntime disk-space #define block in STEMwerk.iss"
    return {key: int(value) for key, value in match.groupdict().items()}


def test_non_bundled_minimum_free_space_has_real_headroom():
    constants = _constants()
    assert constants["plain_mb"] >= MIN_REQUIRED_MB_FLOOR, (
        f"non-bundled MinimumFreeSpaceMB={constants['plain_mb']} is at or below the "
        f"real observed 4GB+ footprint from issue #120; needs headroom above {MIN_REQUIRED_MB_FLOOR}MB"
    )


def test_non_bundled_extra_disk_space_matches_minimum_free_space():
    constants = _constants()
    assert constants["plain_extra"] == constants["plain_mb"] * 1024 * 1024, (
        "non-bundled ExtraDiskSpaceRequiredBytes must equal MinimumFreeSpaceMB "
        "expressed in bytes, so Inno's own native check isn't laxer than the "
        "custom soft preflight check"
    )


def test_bundled_extra_disk_space_not_lower_than_non_bundled():
    constants = _constants()
    assert constants["bundled_extra"] >= constants["plain_extra"], (
        f"bundled ExtraDiskSpaceRequiredBytes={constants['bundled_extra']} is lower than "
        f"non-bundled's {constants['plain_extra']}, even though both build flavors run the "
        "same post-copy bootstrap (venv creation, pip installs, DrumSep runtime setup) -- "
        "the bundled flavor must not need less headroom for that shared work"
    )
