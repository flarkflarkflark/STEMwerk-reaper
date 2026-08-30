from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ISS = ROOT / "installer" / "windows" / "STEMwerk.iss"
PAYLOAD_ISS = ROOT / "installer" / "windows" / "STEMwerk_Windows_Payload.iss"
WINDOWS_DIR = ROOT / "installer" / "windows"
VERSION = (ROOT / "VERSION").read_text(encoding="utf-8").strip()


SOURCE_RE = re.compile(
    r'^Source: "(?P<source>[^"]+)"; DestDir: "(?P<dest>[^"]+)";',
    re.MULTILINE,
)


def payload_mappings() -> list[tuple[str, str]]:
    text = PAYLOAD_ISS.read_text(encoding="utf-8")
    return [(match["source"], match["dest"]) for match in SOURCE_RE.finditer(text)]


def destination_path(source: str, destination: str) -> str:
    return (destination.rstrip("\\") + "\\" + source.rsplit("\\", 1)[-1]).lower()


def installed_repo_relative_paths() -> set[str]:
    """Map each payload Source/DestDir pair to its scripts/reaper/-relative
    installed identity ({app} maps 1:1 to scripts/reaper/). Some assets
    (e.g. i18n/) are sourced from a different repo-relative mirror than
    where they end up installed, so this compares by destination, not
    source path.
    """
    installed = set()
    for source, dest in payload_mappings():
        filename = source.replace("\\", "/").rsplit("/", 1)[-1]
        dest_posix = dest.replace("\\", "/")
        if dest_posix == "{app}":
            installed.add(f"scripts/reaper/{filename}")
        elif dest_posix.startswith("{app}/"):
            installed.add(f"scripts/reaper/{dest_posix[len('{app}/'):]}/{filename}")
    return installed


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


def test_windows_payload_satisfies_production_payload_contract() -> None:
    from tools import release_gate

    contract = release_gate.parse_production_payload_contract(release_gate.PRODUCTION_PAYLOAD_CONTRACT)
    required = release_gate.required_files_for_platform(contract, "windows")

    installed = installed_repo_relative_paths()
    missing = sorted(req for req in required if req not in installed)
    assert not missing, f"Windows payload missing production payload contract entries: {missing}"


def test_windows_payload_contains_all_statically_detected_internal_dependencies() -> None:
    from tools import release_gate

    deps: set[str] = set()
    for lua_file in release_gate.iter_lua_files(ROOT):
        text = release_gate.read_text(lua_file)
        found, _ = release_gate.extract_internal_deps(ROOT, lua_file, text)
        deps.update(found)
    deps.update(release_gate.collect_dynamic_production_dependencies(ROOT))

    installed = installed_repo_relative_paths()
    missing = sorted(dep for dep in deps if dep not in installed)
    assert not missing, f"Windows payload missing statically detected or declared dynamic-dispatch runtime deps: {missing}"


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


def test_current_windows_release_documents_match_repository_version() -> None:
    guides = [
        WINDOWS_DIR / "STEMwerk_Windows_Setup_Guide.md",
        WINDOWS_DIR / "STEMwerk_Windows_Setup_Guide.nl.md",
        WINDOWS_DIR / "STEMwerk_Windows_Setup_Guide.de.md",
    ]
    for guide in guides:
        first_section = "\n".join(guide.read_text(encoding="utf-8").splitlines()[:5])
        assert VERSION in first_section, guide.name
        assert "2.3.0.6" not in first_section, guide.name

    license_text = (WINDOWS_DIR / "STEMwerk_License_Agreement.txt").read_text(
        encoding="utf-8"
    )
    assert f"Version: {VERSION}" in license_text
    assert "Version: 2.3.0.6" not in license_text


def test_current_identity_matches_version_and_allmodels_history_is_preserved() -> None:
    english = (WINDOWS_DIR / "STEMwerk_Windows_Setup_Guide.md").read_text(
        encoding="utf-8"
    )
    assert f"install `{VERSION}` fresh" in english
    assert f"latest Windows setup/runtime fixes from `{VERSION}`" in english
    assert "`2.3.0.0` release line" in english
    for path in (
        WINDOWS_DIR / "STEMwerk_Windows_Setup_Guide.md",
        WINDOWS_DIR / "STEMwerk_Windows_Setup_Guide.nl.md",
        WINDOWS_DIR / "STEMwerk_Windows_Setup_Guide.de.md",
        WINDOWS_DIR / "STEMwerk_License_Agreement.txt",
    ):
        assert "2.3.0.5" not in path.read_text(encoding="utf-8")


def test_version_sync_covers_current_windows_installer_identity_fields() -> None:
    from tools import version_sync

    configured = {rel: fields for rel, fields in version_sync.WINDOWS_CURRENT_VERSION_FIELDS}
    expected = {
        "installer/windows/STEMwerk_Windows_Setup_Guide.md",
        "installer/windows/STEMwerk_Windows_Setup_Guide.nl.md",
        "installer/windows/STEMwerk_Windows_Setup_Guide.de.md",
        "installer/windows/STEMwerk_License_Agreement.txt",
    }
    assert set(configured) == expected

    for rel, fields in configured.items():
        original = (ROOT / rel).read_text(encoding="utf-8")
        for field_name, pattern in fields:
            match = pattern.search(original)
            assert match is not None, f"{rel} ({field_name})"
            start, end = match.span("version")
            stale = original[:start] + "9.9.9.9" + original[end:]
            updated, notes, errors = version_sync.update_current_version_fields(
                stale, VERSION, rel, fields
            )
            assert not errors
            assert updated == original
            assert f"{rel} ({field_name}): expected {VERSION}, found 9.9.9.9" in notes

            unrelated = "\nHistorical fixture version: 9.9.9.9\n"
            updated, notes, errors = version_sync.update_current_version_fields(
                stale + unrelated, VERSION, rel, fields
            )
            assert not errors
            assert updated == original + unrelated
            assert "Historical fixture version: 9.9.9.9" in updated


def test_version_sync_rejects_missing_or_duplicate_windows_fields_without_partial_update() -> None:
    from tools import version_sync

    for rel, fields in version_sync.WINDOWS_CURRENT_VERSION_FIELDS:
        original = (ROOT / rel).read_text(encoding="utf-8")
        first_name, first_pattern = fields[0]
        first_match = first_pattern.search(original)
        assert first_match is not None

        duplicate_base = original
        if len(fields) > 1:
            second_match = fields[1][1].search(duplicate_base)
            assert second_match is not None
            start, end = second_match.span("version")
            duplicate_base = duplicate_base[:start] + "9.9.9.9" + duplicate_base[end:]
        duplicate = duplicate_base + "\n" + first_match.group(0) + "\n"
        updated, _, errors = version_sync.update_current_version_fields(
            duplicate, VERSION, rel, fields
        )
        assert updated == duplicate
        assert f"{rel} ({first_name}): expected exactly one current-version field, found 2" in errors

        missing = first_pattern.sub("", original, count=1)
        if len(fields) > 1:
            second_pattern = fields[1][1]
            second_match = second_pattern.search(missing)
            assert second_match is not None
            start, end = second_match.span("version")
            missing = missing[:start] + "9.9.9.9" + missing[end:]
        updated, _, errors = version_sync.update_current_version_fields(
            missing, VERSION, rel, fields
        )
        assert updated == missing
        assert f"{rel} ({first_name}): expected exactly one current-version field, found 0" in errors


def _tree_sha256(root: Path) -> dict[str, str]:
    return {
        str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in root.rglob("*")
        if path.is_file()
    }


def test_version_sync_write_prevalidates_all_files_before_any_write(
    tmp_path: Path,
) -> None:
    repo = tmp_path / "repo"
    shutil.copytree(
        ROOT,
        repo,
        symlinks=True,
        ignore=shutil.ignore_patterns(".git", ".pytest_cache", "__pycache__", "*.pyc"),
    )
    script = repo / "tools" / "version_sync.py"
    env = os.environ.copy()
    env["PYTHONPYCACHEPREFIX"] = str(tmp_path / "pycache")

    early_paths = (
        repo / "index.xml",
        repo / "scripts" / "reaper" / "STEMwerk.lua",
    )
    early_paths[0].write_text(
        early_paths[0].read_text(encoding="utf-8").replace(
            f'<version name="{VERSION}"', '<version name="9.9.9.9"'
        ),
        encoding="utf-8",
    )
    early_paths[1].write_text(
        early_paths[1].read_text(encoding="utf-8").replace(
            f"-- @version {VERSION}", "-- @version 9.9.9.9", 1
        ),
        encoding="utf-8",
    )

    guide = repo / "installer" / "windows" / "STEMwerk_Windows_Setup_Guide.md"
    historical_fixture = "\nHistorical fixture version: 9.9.9.9\n"
    guide.write_text(
        guide.read_text(encoding="utf-8") + historical_fixture,
        encoding="utf-8",
    )

    license_path = repo / "installer" / "windows" / "STEMwerk_License_Agreement.txt"
    valid_license = license_path.read_bytes()
    version_line = f"Version: {VERSION}"

    for late_failure, expected_count in (("missing", 0), ("duplicate", 2)):
        license_text = valid_license.decode("utf-8")
        if late_failure == "missing":
            license_text = license_text.replace(version_line, "", 1)
        else:
            license_text += f"\n{version_line}\n"
        license_path.write_text(license_text, encoding="utf-8")

        protected_paths = (*early_paths, guide, license_path)
        protected_bytes = {path: path.read_bytes() for path in protected_paths}
        before = _tree_sha256(repo)
        failed = subprocess.run(
            [sys.executable, str(script), "--write"],
            cwd=repo,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )

        assert failed.returncode == 1
        assert (
            "installer/windows/STEMwerk_License_Agreement.txt (license header): "
            f"expected exactly one current-version field, found {expected_count}"
        ) in failed.stderr
        assert _tree_sha256(repo) == before
        assert {path: path.read_bytes() for path in protected_paths} == protected_bytes

        license_path.write_bytes(valid_license)

    written = subprocess.run(
        [sys.executable, str(script), "--write"],
        cwd=repo,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert written.returncode == 0, written.stderr
    assert "Updated:" in written.stdout
    assert f'<version name="{VERSION}"' in early_paths[0].read_text(encoding="utf-8")
    assert f"-- @version {VERSION}" in early_paths[1].read_text(encoding="utf-8")
    assert guide.read_text(encoding="utf-8").endswith(historical_fixture)

    after_write = _tree_sha256(repo)
    repeated = subprocess.run(
        [sys.executable, str(script), "--write"],
        cwd=repo,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert repeated.returncode == 0, repeated.stderr
    assert "Version references are in sync." in repeated.stdout
    assert _tree_sha256(repo) == after_write

    checked = subprocess.run(
        [sys.executable, str(script), "--check"],
        cwd=repo,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert checked.returncode == 0, checked.stderr
    assert _tree_sha256(repo) == after_write
