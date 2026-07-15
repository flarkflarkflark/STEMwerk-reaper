#!/usr/bin/env python3
"""
Keep all version references in sync with the repo VERSION file.
Use --check in CI and --write when bumping versions locally.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERSION_FILE = ROOT / "VERSION"


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write_text(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def update_index_xml(text: str, version: str) -> tuple[str, list[str], list[str]]:
    notes: list[str] = []
    errors: list[str] = []
    pattern = re.compile(r'(<version\s+name=")([^"]+)(")')
    matches = list(pattern.finditer(text))
    if not matches:
        errors.append("index.xml: missing <version name=\"...\">")
        return text, notes, errors
    current = {m.group(2) for m in matches}
    if current != {version}:
        notes.append(f"index.xml: version {sorted(current)} -> {version}")
        text = pattern.sub(lambda m: f"{m.group(1)}{version}{m.group(3)}", text)
    return text, notes, errors


def update_lua_version(text: str, version: str, label: str) -> tuple[str, list[str], list[str]]:
    notes: list[str] = []
    errors: list[str] = []
    pattern = re.compile(r'^(--\s*@version\s+)(\S+)(.*)$', re.M)
    matches = list(pattern.finditer(text))
    if not matches:
        errors.append(f"{label}: missing -- @version header")
        return text, notes, errors
    current = {m.group(2) for m in matches}
    if current != {version}:
        notes.append(f"{label}: @version {sorted(current)} -> {version}")
        text = pattern.sub(lambda m: f"{m.group(1)}{version}{m.group(3)}", text)
    return text, notes, errors


def update_app_version(text: str, version: str, label: str) -> tuple[str, list[str], list[str]]:
    notes: list[str] = []
    errors: list[str] = []
    pattern = re.compile(r'^(local\s+APP_VERSION\s+=\s+")(.*?)(")', re.M)
    match = pattern.search(text)
    if not match:
        errors.append(f"{label}: missing local APP_VERSION")
        return text, notes, errors
    current = match.group(2)
    if current != version:
        notes.append(f"{label}: APP_VERSION {current} -> {version}")
        text = pattern.sub(lambda m: f"{m.group(1)}{version}{m.group(3)}", text)
    return text, notes, errors


def update_setup_guide(text: str, version: str) -> tuple[str, list[str], list[str]]:
    notes: list[str] = []
    errors: list[str] = []
    pattern = re.compile("(STEMwerk/flarkAUDIO\\s+\\u2014\\s+v)([0-9.]+)(\\s+and later)")
    match = pattern.search(text)
    if not match:
        notes.append("tools/STEMwerk_Setup_Guide_Linux_macOS.md: no version marker found")
        return text, notes, errors
    current = match.group(2)
    if current != version:
        notes.append(f"tools/STEMwerk_Setup_Guide_Linux_macOS.md: {current} -> {version}")
        text = pattern.sub(lambda m: f"{m.group(1)}{version}{m.group(3)}", text)
    return text, notes, errors


def main() -> int:
    parser = argparse.ArgumentParser(description="Sync repo version references.")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="Validate only (default).")
    mode.add_argument("--write", action="store_true", help="Write changes to disk.")
    args = parser.parse_args()

    if not VERSION_FILE.exists():
        print("ERROR: VERSION file not found.", file=sys.stderr)
        return 2

    version = VERSION_FILE.read_text(encoding="utf-8").strip()
    if not version:
        print("ERROR: VERSION file is empty.", file=sys.stderr)
        return 2

    write_changes = args.write
    changes: list[str] = []
    errors: list[str] = []
    notes: list[str] = []

    def apply_update(path: Path, updater, label: str) -> None:
        nonlocal changes, errors, notes
        text = read_text(path)
        new_text, new_notes, new_errors = updater(text)
        notes.extend(new_notes)
        errors.extend(new_errors)
        if new_text != text:
            changes.append(str(path.relative_to(ROOT)))
            if write_changes:
                write_text(path, new_text)

    apply_update(ROOT / "index.xml", lambda t: update_index_xml(t, version), "index.xml")

    lua_version_files = [
        "scripts/reaper/STEMwerk.lua",
        "scripts/reaper/STEMwerk-SETUP.lua",
        "scripts/reaper/STEMwerk_Save_Support_Bundle.lua",
        "scripts/reaper/STEMwerk_AI_Separate.lua",
        "scripts/reaper/STEMwerk_Setup_Toolbar.lua",
        "scripts/reaper/STEMwerk_Explode_Takes.lua",
        "scripts/reaper/STEMwerk_All_Stems.lua",
        "scripts/reaper/STEMwerk_Vocals_Only.lua",
        "scripts/reaper/STEMwerk_Drums_Only.lua",
        "scripts/reaper/STEMwerk_Direct_Kit.lua",
        "scripts/reaper/STEMwerk_Drum_Kit_Split.lua",
        "scripts/reaper/STEMwerk_Bass_Only.lua",
        "scripts/reaper/STEMwerk_Karaoke.lua",
        "scripts/reaper/_internal/STEMwerk_Setup_Internal.lua",
    ]
    for rel in lua_version_files:
        path = ROOT / rel
        apply_update(path, lambda t, p=rel: update_lua_version(t, version, p), rel)

    app_version_path = ROOT / "scripts/reaper/STEMwerk.lua"
    apply_update(app_version_path, lambda t: update_app_version(t, version, "scripts/reaper/STEMwerk.lua"), "scripts/reaper/STEMwerk.lua")

    setup_guide = ROOT / "tools/STEMwerk_Setup_Guide_Linux_macOS.md"
    if setup_guide.exists():
        apply_update(setup_guide, lambda t: update_setup_guide(t, version), "tools/STEMwerk_Setup_Guide_Linux_macOS.md")

    if notes and not write_changes:
        for note in notes:
            print(note)

    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        return 1

    if changes and not write_changes:
        print("Version mismatch detected:")
        for item in changes:
            print(f" - {item}")
        print("Run: python tools/version_sync.py --write", file=sys.stderr)
        return 1

    if write_changes and changes:
        print("Updated:")
        for item in changes:
            print(f" - {item}")
    else:
        print("Version references are in sync.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
