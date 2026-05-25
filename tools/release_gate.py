#!/usr/bin/env python3
"""Release gate for ReaPack/package completeness and runtime dependency safety."""
from __future__ import annotations

import argparse
import hashlib
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Iterable
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
INDEX_XML = ROOT / "index.xml"
VERSION_FILE = ROOT / "VERSION"

REQUIRED_TOP_LEVEL_SCRIPTS = (
    "scripts/reaper/STEMwerk.lua",
    "scripts/reaper/STEMwerk-SETUP.lua",
    "scripts/reaper/STEMwerk_Save_Support_Bundle.lua",
)

RUNTIME_DEP_REGRESSION_TARGET = "scripts/reaper/_internal/STEMwerk_Timing.lua"
CANONICAL_REAPER_I18N = "scripts/reaper/i18n/languages.lua"
ROOT_I18N = "i18n/languages.lua"
PROTOTYPE_SCRIPTS = (
    "STEMwerk_DrumSep_Workflow_Prototype.lua",
    "STEMwerk_DrumSep_Import_Prototype.lua",
    "STEMwerk_DrumSep_Workflow_AB_Prototype.lua",
)
DKS_REQUIRED_KEYS = (
    "tooltip_preset_drumkit",
    "workflow_drumkit_label",
    "workflow_edks_label",
    "help_native_key_drumkit",
    "help_native_key_edks",
    "help_native_drumkit_split",
    "help_native_drumkit_step_1",
    "help_native_drumkit_step_2",
    "help_native_drumkit_model_note",
    "help_native_drumkit_guidance",
    "drumkit_result_subtitle",
)
DKS_TRIGGER_TOKENS = DKS_REQUIRED_KEYS + ("workflow_edks",)


@dataclass
class Section:
    name: str
    status: str = "PASS"  # PASS | WARN | FAIL
    messages: list[str] = field(default_factory=list)

    def fail(self, msg: str) -> None:
        self.status = "FAIL"
        self.messages.append(msg)

    def warn(self, msg: str) -> None:
        if self.status != "FAIL":
            self.status = "WARN"
        self.messages.append(msg)

    def note(self, msg: str) -> None:
        self.messages.append(msg)


@dataclass
class SourceEntry:
    file_attr: str
    url: str
    repo_path: str | None


def posix_path(path: Path) -> str:
    return path.as_posix().lstrip("./")


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_index(index_path: Path) -> tuple[ET.ElementTree | None, str, list[str]]:
    warnings: list[str] = []
    raw = ""
    try:
        raw = read_text(index_path)
    except FileNotFoundError:
        return None, raw, [f"index.xml not found at {index_path}"]
    except OSError as exc:
        return None, raw, [f"failed reading index.xml: {exc}"]

    try:
        tree = ET.parse(index_path)
    except ET.ParseError as exc:
        return None, raw, [f"index.xml XML parse error: {exc}"]

    return tree, raw, warnings


def infer_repo_path(file_attr: str, url: str) -> str | None:
    file_attr = (file_attr or "").strip()
    url = (url or "").strip()

    if url:
        parsed = urlparse(url)
        parts = [p for p in parsed.path.split("/") if p]
        if len(parts) >= 5 and parts[0] and parts[1]:
            # raw.githubusercontent.com/<owner>/<repo>/<ref>/<path...>
            if "raw.githubusercontent.com" in (parsed.netloc or ""):
                suffix = parts[3:]
                if suffix:
                    return str(PurePosixPath(*suffix))

    if file_attr:
        rel = file_attr
        while rel.startswith("../"):
            rel = rel[3:]
        rel = rel.lstrip("./")
        if not rel:
            return None
        if rel.startswith("_internal/") or rel.startswith("constraints/") or rel.startswith("vendor/") or rel.startswith("assets/"):
            return str(PurePosixPath("scripts/reaper") / rel)
        if rel.startswith("i18n/"):
            return str(PurePosixPath(rel))
        if "/" not in rel:
            return str(PurePosixPath("scripts/reaper") / rel)
        return str(PurePosixPath(rel))

    return None


def collect_sources(tree: ET.ElementTree) -> tuple[list[SourceEntry], list[str]]:
    warnings: list[str] = []
    entries: list[SourceEntry] = []
    for src in tree.findall(".//source"):
        file_attr = src.get("file", "")
        url = (src.text or "").strip()
        repo_path = infer_repo_path(file_attr, url)
        if repo_path is None:
            warnings.append(f"could not infer repo path for source file='{file_attr}' url='{url}'")
        entries.append(SourceEntry(file_attr=file_attr, url=url, repo_path=repo_path))
    return entries, warnings


def iter_lua_files(root: Path) -> Iterable[Path]:
    yield from sorted((root / "scripts/reaper").glob("*.lua"))
    yield from sorted((root / "scripts/reaper/_internal").glob("*.lua"))


def extract_internal_deps(root: Path, lua_path: Path, text: str) -> tuple[set[str], list[str]]:
    deps: set[str] = set()
    warnings: list[str] = []
    rel = posix_path(lua_path.relative_to(root))

    patterns = {
        "dofile_or_loadfile": re.compile(r"\b(?:dofile|loadfile)\s*\(([^)]*)\)"),
        "pcall_dofile": re.compile(r"\bpcall\s*\(\s*dofile\s*,\s*([^)]+)\)"),
        "loadModule": re.compile(r"\bloadModule\s*\(\s*([^,\n]+)"),
    }

    def add_from_expr(expr: str) -> bool:
        found = False
        literals = re.findall(r"['\"]([^'\"]+)['\"]", expr)
        for lit in literals:
            lit = lit.replace("\\", "/")
            if "_internal/" in lit and lit.endswith(".lua"):
                sub = lit[lit.find("_internal/") :]
                deps.add(str(PurePosixPath("scripts/reaper") / sub))
                found = True
            elif lit.endswith(".lua") and rel.startswith("scripts/reaper/_internal/") and "/" not in lit:
                deps.add(str(PurePosixPath("scripts/reaper/_internal") / lit))
                found = True
        return found

    for tag, rx in patterns.items():
        for m in rx.finditer(text):
            expr = m.group(1).strip()
            if not add_from_expr(expr):
                if "_internal" in expr:
                    warnings.append(f"{rel}: dynamic {tag} expression not statically resolved: {expr}")

    return deps, warnings


def check_xml_and_version(root: Path, tree: ET.ElementTree | None, index_raw: str) -> Section:
    section = Section("A. XML/index sanity")
    if tree is None:
        section.fail("index.xml missing or invalid XML")
        return section

    if not VERSION_FILE.exists():
        section.fail("VERSION file is missing")
        return section

    version = VERSION_FILE.read_text(encoding="utf-8").strip()
    if not version:
        section.fail("VERSION file is empty")
        return section

    if version in index_raw:
        section.note(f"VERSION value '{version}' found in index.xml")
    else:
        section.warn(f"VERSION value '{version}' not found in index.xml text")

    main_lua = root / "scripts/reaper/STEMwerk.lua"
    if main_lua.exists():
        lua_raw = read_text(main_lua)
        if version not in lua_raw:
            section.warn(f"VERSION value '{version}' not found in scripts/reaper/STEMwerk.lua")
    else:
        section.fail("scripts/reaper/STEMwerk.lua missing")

    return section


def check_payload_completeness(root: Path, sources: list[SourceEntry], source_warnings: list[str]) -> tuple[Section, set[str]]:
    section = Section("B. ReaPack payload completeness")
    for w in source_warnings:
        section.warn(w)

    if not sources:
        section.fail("index.xml has no <source> entries")
        return section, set()

    payload_paths: set[str] = set()
    scripts_reaper_sources = 0
    missing: list[str] = []

    for s in sources:
        if not s.repo_path:
            continue
        payload_paths.add(s.repo_path)
        if s.repo_path.startswith("scripts/reaper/"):
            scripts_reaper_sources += 1
        if not (root / s.repo_path).exists():
            missing.append(s.repo_path)

    if scripts_reaper_sources == 0:
        section.fail("no scripts/reaper sources found in index.xml payload")

    if missing:
        section.fail("index.xml references missing local files:")
        for path in sorted(missing):
            section.note(f" - {path}")

    for rel in REQUIRED_TOP_LEVEL_SCRIPTS:
        if not (root / rel).exists():
            section.fail(f"required top-level script missing: {rel}")

    if not missing and scripts_reaper_sources > 0:
        section.note(f"validated {len(payload_paths)} payload paths ({scripts_reaper_sources} under scripts/reaper)")

    return section, payload_paths


def check_runtime_dependencies(root: Path, payload_paths: set[str]) -> Section:
    section = Section("C. Runtime dependency completeness")
    deps: set[str] = set()
    dynamic_warnings: list[str] = []

    for lua_file in iter_lua_files(root):
        text = read_text(lua_file)
        found, warns = extract_internal_deps(root, lua_file, text)
        deps.update(found)
        dynamic_warnings.extend(warns)

    missing_local = sorted([d for d in deps if not (root / d).exists()])
    if missing_local:
        section.fail("statically detected runtime dependencies missing locally:")
        for d in missing_local:
            section.note(f" - {d}")

    missing_in_payload = sorted([d for d in deps if d not in payload_paths])
    if missing_in_payload:
        section.fail("statically detected runtime dependencies missing from index.xml payload:")
        for d in missing_in_payload:
            section.note(f" - {d}")

    if dynamic_warnings:
        for w in dynamic_warnings:
            section.warn(w)

    timing_path = RUNTIME_DEP_REGRESSION_TARGET
    if not (root / timing_path).exists():
        section.fail(f"regression guard: missing local dependency {timing_path}")
    if timing_path not in payload_paths:
        section.fail(f"regression guard: missing index.xml payload entry for {timing_path}")

    section.note(f"statically detected internal runtime deps: {len(deps)}")
    return section


def _locale_block(lua_text: str, locale: str) -> str | None:
    tokens = ("en", "nl", "de")
    start_marker = f"{locale} = {{"
    start = lua_text.find(start_marker)
    if start < 0:
        return None
    ends: list[int] = []
    for other in tokens:
        if other == locale:
            continue
        idx = lua_text.find(f"{other} = {{", start + len(start_marker))
        if idx >= 0:
            ends.append(idx)
    end = min(ends) if ends else len(lua_text)
    return lua_text[start:end]


def check_i18n_release_consistency(root: Path, payload_paths: set[str], index_raw: str) -> Section:
    section = Section("D. i18n release consistency")
    canonical_path = root / CANONICAL_REAPER_I18N
    root_path = root / ROOT_I18N
    canonical_exists = canonical_path.exists()
    root_exists = root_path.exists()

    if canonical_exists and root_exists:
        canonical_hash = sha256_file(canonical_path)
        root_hash = sha256_file(root_path)
        if canonical_hash != root_hash:
            section.fail(
                f"duplicate i18n sources differ: {CANONICAL_REAPER_I18N} ({canonical_hash}) != {ROOT_I18N} ({root_hash})"
            )
        else:
            section.note(f"duplicate i18n sources match hash {canonical_hash}")

    if canonical_exists and payload_paths:
        if CANONICAL_REAPER_I18N not in payload_paths:
            section.fail(f"canonical ReaPack i18n missing from payload: {CANONICAL_REAPER_I18N}")
        if ROOT_I18N in payload_paths:
            section.fail(f"non-canonical root i18n appears in payload: {ROOT_I18N}")
    elif canonical_exists:
        section.warn("skipped payload canonicality check because payload paths are unavailable")

    if "scripts/reaper/i18n" not in index_raw and payload_paths:
        section.warn("index.xml does not appear to reference scripts/reaper/i18n paths")

    return section


def check_dks_i18n_keys(root: Path) -> Section:
    section = Section("E. DKS/EDKS key coverage")
    stemwerk_path = root / "scripts/reaper/STEMwerk.lua"
    if not stemwerk_path.exists():
        section.fail("scripts/reaper/STEMwerk.lua missing")
        return section

    stemwerk_text = read_text(stemwerk_path)
    if not any(token in stemwerk_text for token in DKS_TRIGGER_TOKENS):
        section.note("DKS/EDKS keys not referenced by STEMwerk.lua; check skipped")
        return section

    lang_path = root / CANONICAL_REAPER_I18N
    if not lang_path.exists():
        section.fail(f"missing canonical languages file: {CANONICAL_REAPER_I18N}")
        return section

    lang_text = read_text(lang_path)
    for locale in ("en", "nl", "de"):
        block = _locale_block(lang_text, locale)
        if block is None:
            section.fail(f"locale block missing in {CANONICAL_REAPER_I18N}: {locale}")
            continue
        missing = [key for key in DKS_REQUIRED_KEYS if re.search(rf"\b{re.escape(key)}\s*=", block) is None]
        if missing:
            section.fail(f"{locale} locale missing DKS keys: {', '.join(missing)}")

    return section


def check_no_public_prototypes(payload_paths: set[str], index_raw: str) -> Section:
    section = Section("F. Prototype payload exclusion")
    payload_names = {PurePosixPath(p).name for p in payload_paths}
    for name in PROTOTYPE_SCRIPTS:
        if name in payload_names or name in index_raw:
            section.fail(f"prototype script must not be in public payload: {name}")
    if section.status == "PASS":
        section.note("no blocked prototype scripts found in public payload")
    return section


def run_check(root: Path) -> tuple[list[Section], int]:
    sections: list[Section] = []
    tree, index_raw, parse_errors = parse_index(root / "index.xml")

    sanity = check_xml_and_version(root, tree, index_raw)
    for err in parse_errors:
        sanity.fail(err)
    sections.append(sanity)

    sources: list[SourceEntry] = []
    payload_paths: set[str] = set()
    if tree is not None:
        sources, source_warnings = collect_sources(tree)
        payload_section, payload_paths = check_payload_completeness(root, sources, source_warnings)
    else:
        payload_section = Section("B. ReaPack payload completeness")
        payload_section.fail("skipped: index.xml could not be parsed")
    sections.append(payload_section)

    runtime_section = check_runtime_dependencies(root, payload_paths)
    sections.append(runtime_section)
    sections.append(check_i18n_release_consistency(root, payload_paths, index_raw))
    sections.append(check_dks_i18n_keys(root))
    sections.append(check_no_public_prototypes(payload_paths, index_raw))

    fail_count = sum(1 for s in sections if s.status == "FAIL")
    return sections, fail_count


def print_report(sections: list[Section], fail_count: int) -> None:
    for sec in sections:
        print(f"[{sec.status}] {sec.name}")
        if sec.messages:
            for msg in sec.messages:
                print(f"  - {msg}")
        else:
            print("  - ok")
    warn_count = sum(1 for s in sections if s.status == "WARN")
    print()
    if fail_count:
        print(f"SUMMARY: FAIL ({fail_count} failing section(s), {warn_count} warning section(s))")
    else:
        print(f"SUMMARY: PASS ({warn_count} warning section(s))")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="STEMwerk release gate / ReaPack payload audit")
    parser.add_argument("--check", action="store_true", help="Run release gate checks")
    args = parser.parse_args(argv)

    if not args.check:
        parser.error("only --check is supported")

    sections, fail_count = run_check(ROOT)
    print_report(sections, fail_count)
    return 1 if fail_count else 0


if __name__ == "__main__":
    raise SystemExit(main())
