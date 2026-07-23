from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ISS = ROOT / "installer" / "windows" / "STEMwerk.iss"
PAYLOAD_ISS = ROOT / "installer" / "windows" / "STEMwerk_Windows_Payload.iss"
WINDOWS_DIR = ROOT / "installer" / "windows"


SOURCE_RE = re.compile(
    r'^Source: "(?P<source>[^"]+)"; DestDir: "(?P<dest>[^"]+)";',
    re.MULTILINE,
)


def payload_mappings() -> list[tuple[str, str]]:
    text = PAYLOAD_ISS.read_text(encoding="utf-8")
    return [(match["source"], match["dest"]) for match in SOURCE_RE.finditer(text)]


def destination_path(source: str, destination: str) -> str:
    return (destination.rstrip("\\") + "\\" + source.rsplit("\\", 1)[-1]).lower()


def test_windows_installer_uses_explicit_payload_include() -> None:
    text = ISS.read_text(encoding="utf-8")
    assert '#include "STEMwerk_Windows_Payload.iss"' in text
    assert 'Source: "..\\..\\scripts\\reaper\\*"' not in text


def test_windows_payload_has_no_platform_foreign_or_host_specific_sources() -> None:
    sources = [source.lower() for source, _ in payload_mappings()]
    forbidden = (
        "linux",
        "macos",
        "macos-intel",
        "._",
        "__macosx",
        "vendor\\wheels",
        ".whl",
    )
    assert not [source for source in sources if any(token in source for token in forbidden)]

    payload_text = PAYLOAD_ISS.read_text(encoding="utf-8")
    assert "/mnt/production" not in payload_text.lower()
    assert "/home/flark" not in payload_text.lower()
    assert "/users/flark" not in payload_text.lower()


def test_windows_payload_preserves_required_shared_and_windows_files() -> None:
    sources = {source.lower() for source, _ in payload_mappings()}
    required = {
        "..\\..\\scripts\\reaper\\stemwerk.lua",
        "..\\..\\scripts\\reaper\\stemwerk-setup.lua",
        "..\\..\\scripts\\reaper\\audio_separator_process.py",
        "..\\..\\scripts\\reaper\\stemwerk_bootstrap_windows.ps1",
        "..\\..\\scripts\\reaper\\_internal\\stemwerk_setup_internal.lua",
        "..\\..\\scripts\\reaper\\_internal\\stemwerk_managed_python.lua",
        "..\\..\\scripts\\reaper\\_internal\\stemwerk_drumsep_process.py",
        "..\\..\\scripts\\reaper\\constraints\\base.txt",
        "..\\..\\scripts\\reaper\\constraints\\cuda.txt",
        "..\\..\\scripts\\reaper\\constraints\\directml.txt",
        "..\\..\\i18n\\languages.lua",
        "..\\..\\i18n\\language_checks.py",
        "..\\..\\scripts\\reaper\\assets\\toolbar_icons\\readme.txt",
        "..\\..\\scripts\\reaper\\vendor\\julius\\src\\julius.py",
        "..\\..\\scripts\\reaper\\vendor\\stemwerk-core\\src\\stemwerk_core\\separator.py",
    }
    assert required <= sources


def test_windows_payload_sources_exist_and_are_explicit_files() -> None:
    mappings = payload_mappings()
    assert mappings
    for source, _ in mappings:
        assert "*" not in source
        source_path = WINDOWS_DIR / Path(source.replace("\\", "/"))
        assert source_path.resolve().is_file(), source


def test_windows_payload_has_no_duplicate_destination_paths() -> None:
    destinations = [destination_path(source, dest) for source, dest in payload_mappings()]
    assert len(destinations) == len(set(destinations))


def test_i18n_is_mapped_once_from_the_canonical_root() -> None:
    mappings = payload_mappings()
    i18n = [
        (source, destination_path(source, dest))
        for source, dest in mappings
        if "\\i18n\\" in source.lower()
    ]
    assert len(i18n) == 4
    assert all(source.lower().startswith("..\\..\\i18n\\") for source, _ in i18n)
    assert len({destination for _, destination in i18n}) == 4


def test_online_and_normal_bundled_payload_contract_remains_narrow() -> None:
    text = ISS.read_text(encoding="utf-8")
    assert 'payload\\python\\python-3.11.8-amd64.exe' in text
    assert 'payload\\ffmpeg\\ffmpeg-release-essentials.zip' in text
    assert "#if BundleRuntime == \"1\"" in text
    assert "STEMwerk_Offline_Patch" not in text
    assert "update-patch" not in text.lower()


def test_current_windows_release_documents_identify_2306() -> None:
    guides = [
        WINDOWS_DIR / "STEMwerk_Windows_Setup_Guide.md",
        WINDOWS_DIR / "STEMwerk_Windows_Setup_Guide.nl.md",
        WINDOWS_DIR / "STEMwerk_Windows_Setup_Guide.de.md",
    ]
    for guide in guides:
        first_section = "\n".join(guide.read_text(encoding="utf-8").splitlines()[:5])
        assert "2.3.0.6" in first_section, guide.name
        assert "2.3.0.4" not in first_section, guide.name

    license_text = (WINDOWS_DIR / "STEMwerk_License_Agreement.txt").read_text(
        encoding="utf-8"
    )
    assert "Version: 2.3.0.6" in license_text
    assert "Version: 2.3.0.4" not in license_text


def test_current_identity_has_no_2304_or_2305_but_history_is_preserved() -> None:
    english = (WINDOWS_DIR / "STEMwerk_Windows_Setup_Guide.md").read_text(
        encoding="utf-8"
    )
    assert "install `2.3.0.6` fresh" in english
    assert "latest Windows setup/runtime fixes from `2.3.0.4`" in english
    for path in (
        WINDOWS_DIR / "STEMwerk_Windows_Setup_Guide.md",
        WINDOWS_DIR / "STEMwerk_Windows_Setup_Guide.nl.md",
        WINDOWS_DIR / "STEMwerk_Windows_Setup_Guide.de.md",
        WINDOWS_DIR / "STEMwerk_License_Agreement.txt",
    ):
        assert "2.3.0.5" not in path.read_text(encoding="utf-8")
