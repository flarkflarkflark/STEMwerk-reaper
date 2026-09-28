"""Regression coverage for the post-install guide wording (issue #122).

The guide's "What the installer just did" section stated installer outcomes
as unconditional fact even when setup had actually failed partway through.
This asserts the section is now framed conditionally and points the reader
at the real setup log, consistently across all three language variants.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WINDOWS_DIR = ROOT / "installer" / "windows"

GUIDES = {
    "en": (WINDOWS_DIR / "STEMwerk_Windows_Setup_Guide.md", "If setup completed without errors", "bootstrap.log"),
    "de": (WINDOWS_DIR / "STEMwerk_Windows_Setup_Guide.de.md", "Wenn das Setup ohne Fehler abgeschlossen wurde", "bootstrap.log"),
    "nl": (WINDOWS_DIR / "STEMwerk_Windows_Setup_Guide.nl.md", "Als de setup zonder fouten is voltooid", "bootstrap.log"),
}

STALE_HEADINGS = (
    "What the installer just did",
    "Was der Installer gerade gemacht hat",
    "Wat de installer zojuist heeft gedaan",
)


def test_no_stale_unconditional_heading_remains():
    for path, _conditional_phrase, _log_marker in GUIDES.values():
        text = path.read_text(encoding="utf-8-sig")
        for stale in STALE_HEADINGS:
            assert stale not in text, f"{path.name} still contains the unconditional heading {stale!r}"


def test_each_language_guide_uses_conditional_wording_and_points_to_the_log():
    for lang, (path, conditional_phrase, log_marker) in GUIDES.items():
        text = path.read_text(encoding="utf-8-sig")
        assert conditional_phrase in text, f"{lang} guide missing conditional phrase {conditional_phrase!r}"
        assert log_marker in text, f"{lang} guide does not point the reader at {log_marker!r}"
