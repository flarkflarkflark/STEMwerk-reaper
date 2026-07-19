#!/usr/bin/env python3
"""Release gate for ReaPack/package completeness and runtime dependency safety."""
from __future__ import annotations

import argparse
import hashlib
import json
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
MODEL_REGISTRY_LUA = "scripts/reaper/_internal/STEMwerk_Model_Registry.lua"
MODEL_REGISTRY_MANIFEST = "scripts/reaper/models.json"
BOOTSTRAP_MACOS = "scripts/reaper/STEMwerk_Bootstrap_macOS.sh"
BOOTSTRAP_LINUX = "scripts/reaper/STEMwerk_Bootstrap_Linux.sh"
SAMPLERATE_GUARD_REL = "_internal/stemwerk_samplerate_guard.py"
SAMPLERATE_GUARD_PAYLOAD_PATH = f"scripts/reaper/{SAMPLERATE_GUARD_REL}"
DRUMSEP_COMPAT_ASSET = "tools/assets/drumsep/config_drumsep_mdx23c.yaml"
DRUMSEP_COMPAT_CONTRACT_PATH = "tools/assets/drumsep/compatibility_config_contract.json"
LINUX_MANAGED_DIFFQ_WHEEL_NAME = "diffq-0.2.4-cp312-cp312-linux_x86_64.whl"
LINUX_MANAGED_DIFFQ_REPOSITORY_SOURCE = (
    f"scripts/reaper/vendor/wheels/linux-x86_64-cp312/{LINUX_MANAGED_DIFFQ_WHEEL_NAME}"
)
LINUX_MANAGED_DIFFQ_STAGED_TARGET = (
    f"vendor/wheels/linux-x86_64-cp312/{LINUX_MANAGED_DIFFQ_WHEEL_NAME}"
)
LINUX_MANAGED_DIFFQ_SHA256 = "b829202cba2df9883815f95323f1d40294d657dd9c7a7d1c9706b57932d0a203"


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

    # Paired data dependency: de model registry (Lua) hard-failt bij startup
    # als scripts/reaper/models.json ontbreekt. Zodra de registry-module in
    # gebruik is (lokaal aanwezig, als dep gedetecteerd of in de payload),
    # MOET het manifest lokaal bestaan en in de index.xml payload zitten.
    registry_in_use = (
        (root / MODEL_REGISTRY_LUA).exists()
        or MODEL_REGISTRY_LUA in deps
        or MODEL_REGISTRY_LUA in payload_paths
    )
    if registry_in_use:
        if not (root / MODEL_REGISTRY_MANIFEST).exists():
            section.fail(
                f"model registry guard: {MODEL_REGISTRY_LUA} in use but local manifest missing: {MODEL_REGISTRY_MANIFEST}"
            )
        if MODEL_REGISTRY_MANIFEST not in payload_paths:
            section.fail(
                f"model registry guard: missing index.xml payload entry for {MODEL_REGISTRY_MANIFEST}"
            )
        if section.status != "FAIL":
            section.note(f"model registry manifest paired with {MODEL_REGISTRY_LUA}: OK")

    section.note(f"statically detected internal runtime deps: {len(deps)}")
    return section


def check_bootstrap_guard_payload(root: Path, payload_paths: set[str]) -> Section:
    section = Section("D. Bootstrap helper payload linkage")
    bootstrap_path = root / BOOTSTRAP_MACOS
    if not bootstrap_path.exists():
        section.fail(f"missing bootstrap script: {BOOTSTRAP_MACOS}")
        return section

    bootstrap_text = read_text(bootstrap_path)
    if SAMPLERATE_GUARD_REL not in bootstrap_text:
        section.note(
            f"{BOOTSTRAP_MACOS} does not reference {SAMPLERATE_GUARD_REL}; guard linkage check not required"
        )
        return section

    if not (root / SAMPLERATE_GUARD_PAYLOAD_PATH).exists():
        section.fail(f"bootstrap references missing local helper: {SAMPLERATE_GUARD_PAYLOAD_PATH}")

    if SAMPLERATE_GUARD_PAYLOAD_PATH not in payload_paths:
        section.fail(
            "bootstrap references helper missing from index.xml payload: "
            f"{SAMPLERATE_GUARD_PAYLOAD_PATH}"
        )
    else:
        section.note(f"payload includes bootstrap helper: {SAMPLERATE_GUARD_PAYLOAD_PATH}")

    return section


def check_drumsep_compat_asset_contract(root: Path) -> Section:
    section = Section("E. Shared DrumSep compatibility payload")
    windows_builder = root / "tools/build_windows_drumsep_payload.py"
    if not windows_builder.exists():
        section.note("Windows DrumSep payload builder not present; shared asset check not required")
        return section
    asset = root / DRUMSEP_COMPAT_ASSET
    contract_path = root / DRUMSEP_COMPAT_CONTRACT_PATH
    if not asset.is_file() or not contract_path.is_file():
        section.fail("shared DrumSep compatibility asset or contract is missing")
        return section
    try:
        contract = json.loads(read_text(contract_path))
        payload = asset.read_bytes()
        expected = contract["canonical"]
    except (OSError, KeyError, TypeError, ValueError) as exc:
        section.fail(f"shared DrumSep compatibility contract is invalid: {exc}")
        return section
    actual_sha = hashlib.sha256(payload).hexdigest()
    if len(payload) != expected.get("size") or actual_sha != expected.get("sha256"):
        section.fail("shared DrumSep compatibility asset fingerprint does not match its contract")
    if payload.count(b"\n") != expected.get("lf_count") or payload.count(b"\r") != expected.get("cr_count"):
        section.fail("shared DrumSep compatibility asset newline contract mismatch")
    references = (
        (root / "tools/build_macos_apple_silicon_payload.py", DRUMSEP_COMPAT_ASSET),
        (windows_builder, DRUMSEP_COMPAT_CONTRACT_PATH),
        (root / "installer/windows/STEMwerk.iss", DRUMSEP_COMPAT_ASSET),
    )
    for path, required_reference in references:
        if not path.is_file() or required_reference not in read_text(path).replace("\\", "/"):
            section.fail(f"shared DrumSep compatibility asset is not required by {posix_path(path.relative_to(root))}")
    if section.status != "FAIL":
        section.note(f"validated shared compatibility asset size={len(payload)} sha256={actual_sha}")
    return section


def check_linux_online_drumsep_distribution(root: Path) -> Section:
    section = Section("F. Linux online DrumSep compatibility distribution")
    contract_path = root / DRUMSEP_COMPAT_CONTRACT_PATH
    if not contract_path.is_file():
        section.note("shared DrumSep compatibility contract not present; Linux online check not required")
        return section
    try:
        contract = json.loads(read_text(contract_path))
        inventory = contract["online_inventories"]["linux_reapack"]
        canonical = contract["canonical"]
        filename = contract["filename"]
        repository_source = inventory["repository_source_path"]
        installed_source = inventory["installed_source_path_relative_to_scripts"]
    except (OSError, KeyError, TypeError, ValueError) as exc:
        section.fail(f"Linux online inventory is invalid: {exc}")
        return section

    if Path(repository_source).name != filename or Path(installed_source).name != filename:
        section.fail("Linux online inventory filename does not match the shared contract")
    asset = root / repository_source
    if not asset.is_file():
        section.fail(f"Linux online inventory source is missing: {repository_source}")
    else:
        payload = asset.read_bytes()
        actual_sha = hashlib.sha256(payload).hexdigest()
        if len(payload) != canonical.get("size") or actual_sha != canonical.get("sha256"):
            section.fail("Linux online inventory source fingerprint does not match the shared contract")

    tree, _raw, errors = parse_index(root / inventory["index_path"])
    for error in errors:
        section.fail(error)
    matching_sources: list[SourceEntry] = []
    if tree is not None:
        sources, warnings = collect_sources(tree)
        for warning in warnings:
            section.warn(warning)
        wanted_file = f"../{installed_source}"
        matching_sources = [
            source
            for source in sources
            if source.file_attr == wanted_file and source.repo_path == repository_source
        ]
    if len(matching_sources) != 1:
        section.fail("index.xml must contain exactly one contract-matching Linux online DrumSep source")

    bootstrap = root / BOOTSTRAP_LINUX
    if not bootstrap.is_file():
        section.fail(f"missing Linux materializer entrypoint: {BOOTSTRAP_LINUX}")
    else:
        bootstrap_text = read_text(bootstrap)
        required_literals = (
            str(PurePosixPath(installed_source).parent),
            filename,
            str(canonical["size"]),
            canonical["sha256"],
            str(contract["legacy_crlf"]["size"]),
            contract["legacy_crlf"]["sha256"],
            "materialize_drumsep_compat_yaml",
        )
        for literal in required_literals:
            if literal not in bootstrap_text:
                section.fail(f"Linux bootstrap is missing contract inventory literal: {literal}")
    if section.status != "FAIL":
        section.note(
            f"validated Linux ReaPack source {repository_source} -> {installed_source}"
        )
    return section


def is_linux_managed_diffq_wheel_name(filename: str) -> bool:
    return filename == LINUX_MANAGED_DIFFQ_WHEEL_NAME


def check_linux_managed_diffq_distribution(root: Path) -> Section:
    section = Section("G. Linux managed diffq wheel distribution")
    bootstrap = root / BOOTSTRAP_LINUX
    if not bootstrap.is_file():
        section.note("Linux bootstrap not present; managed diffq wheel check not required")
        return section
    bootstrap_text = read_text(bootstrap)
    if "find_managed_diffq_wheel" not in bootstrap_text:
        section.note("Linux bootstrap has no managed diffq lookup; wheel check not required")
        return section

    source_path = root / LINUX_MANAGED_DIFFQ_REPOSITORY_SOURCE
    if not source_path.is_file():
        section.fail(f"managed diffq wheel source is missing: {LINUX_MANAGED_DIFFQ_REPOSITORY_SOURCE}")
    elif hashlib.sha256(source_path.read_bytes()).hexdigest() != LINUX_MANAGED_DIFFQ_SHA256:
        section.fail("managed diffq wheel fingerprint does not match the distribution contract")

    tree, _raw, errors = parse_index(root / "index.xml")
    for error in errors:
        section.fail(error)
    candidates: list[SourceEntry] = []
    exact: list[SourceEntry] = []
    if tree is not None:
        sources, warnings = collect_sources(tree)
        for warning in warnings:
            section.warn(warning)
        candidates = [
            source
            for source in sources
            if source.file_attr.startswith("../vendor/wheels/linux-x86_64-cp312/diffq-")
            and source.file_attr.endswith(".whl")
        ]
        exact = [
            source
            for source in candidates
            if source.file_attr == f"../{LINUX_MANAGED_DIFFQ_STAGED_TARGET}"
            and source.repo_path == LINUX_MANAGED_DIFFQ_REPOSITORY_SOURCE
        ]
    if len(candidates) != 1 or len(exact) != 1:
        section.fail("index.xml must contain exactly one contract-matching Linux managed diffq wheel source")

    required_literals = (
        '"${SCRIPT_DIR}/vendor/wheels/linux-x86_64-cp312"',
        '"${wheel_dir}"/diffq-*.whl',
        LINUX_MANAGED_DIFFQ_STAGED_TARGET,
    )
    for literal in required_literals:
        if literal not in bootstrap_text:
            section.fail(f"Linux bootstrap is missing managed diffq contract literal: {literal}")

    if section.status != "FAIL":
        section.note(
            "validated Linux managed diffq source "
            f"{LINUX_MANAGED_DIFFQ_REPOSITORY_SOURCE} -> {LINUX_MANAGED_DIFFQ_STAGED_TARGET}"
        )
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
    sections.append(check_bootstrap_guard_payload(root, payload_paths))
    sections.append(check_drumsep_compat_asset_contract(root))
    sections.append(check_linux_online_drumsep_distribution(root))
    sections.append(check_linux_managed_diffq_distribution(root))

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
