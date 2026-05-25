from __future__ import annotations

from pathlib import Path

from tools import release_gate


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _mk_index(version: str, sources: list[str]) -> str:
    src_xml = "\n".join(
        f'        <source file="../{src}" type="file">https://raw.githubusercontent.com/example/repo/main/scripts/reaper/{src}</source>'
        for src in sources
    )
    return (
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        "<index version=\"1\" name=\"STEMwerk-reaper\">\n"
        "  <category name=\"STEMwerk-reaper\">\n"
        "    <reapack name=\"STEMwerk-reaper\" type=\"script\" desc=\"x\">\n"
        f"      <version name=\"{version}\" author=\"x\" time=\"1\">\n"
        f"{src_xml}\n"
        "      </version>\n"
        "    </reapack>\n"
        "  </category>\n"
        "</index>\n"
    )


def _mk_index_entries(version: str, entries: list[tuple[str, str]]) -> str:
    src_xml = "\n".join(
        f'        <source file="{file_attr}" type="file">https://raw.githubusercontent.com/example/repo/main/{url_path}</source>'
        for file_attr, url_path in entries
    )
    return (
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        "<index version=\"1\" name=\"STEMwerk-reaper\">\n"
        "  <category name=\"STEMwerk-reaper\">\n"
        "    <reapack name=\"STEMwerk-reaper\" type=\"script\" desc=\"x\">\n"
        f"      <version name=\"{version}\" author=\"x\" time=\"1\">\n"
        f"{src_xml}\n"
        "      </version>\n"
        "    </reapack>\n"
        "  </category>\n"
        "</index>\n"
    )


def _seed_required_top_level(root: Path, version: str) -> None:
    _write(
        root / "scripts/reaper/STEMwerk.lua",
        f'-- @version {version}\nlocal APP_VERSION = "{version}"\ndofile(script_path .. "_internal/STEMwerk_Timing.lua")\n',
    )
    _write(root / "scripts/reaper/STEMwerk-SETUP.lua", f"-- @version {version}\n")
    _write(root / "scripts/reaper/STEMwerk_Save_Support_Bundle.lua", f"-- @version {version}\n")


def _seed_canonical_languages(root: Path, suffix: str = "") -> None:
    keys = "\n".join(
        [
            '        tooltip_preset_drumkit = "x",',
            '        workflow_drumkit_label = "x",',
            '        workflow_edks_label = "x",',
            '        help_native_key_drumkit = "x",',
            '        help_native_key_edks = "x",',
            '        help_native_drumkit_split = "x",',
            '        help_native_drumkit_step_1 = "x",',
            '        help_native_drumkit_step_2 = "x",',
            '        help_native_drumkit_model_note = "x",',
            '        help_native_drumkit_guidance = "x",',
            '        drumkit_result_subtitle = "x",',
        ]
    )
    text = (
        "local LANGUAGES = {\n"
        "en = {\n"
        f"{keys}\n"
        f'        marker = "en{suffix}",\n'
        "},\n"
        "nl = {\n"
        f"{keys}\n"
        f'        marker = "nl{suffix}",\n'
        "},\n"
        "de = {\n"
        f"{keys}\n"
        f'        marker = "de{suffix}",\n'
        "},\n"
        "}\n"
    )
    _write(root / "scripts/reaper/i18n/languages.lua", text)


def test_missing_local_file_referenced_by_index_fails(tmp_path: Path) -> None:
    version = "2.2.2.2.2"
    _write(tmp_path / "VERSION", version + "\n")
    _seed_required_top_level(tmp_path, version)
    _write(tmp_path / "scripts/reaper/_internal/STEMwerk_Timing.lua", "-- timing\n")
    _write(tmp_path / "index.xml", _mk_index(version, ["STEMwerk.lua", "_internal/STEMwerk_Timing.lua", "missing.lua"]))

    sections, fail_count = release_gate.run_check(tmp_path)

    assert fail_count > 0
    msgs = "\n".join("\n".join(s.messages) for s in sections)
    assert "missing local files" in msgs
    assert "scripts/reaper/missing.lua" in msgs


def test_internal_dependency_missing_from_index_fails(tmp_path: Path) -> None:
    version = "2.2.2.2.2"
    _write(tmp_path / "VERSION", version + "\n")
    _seed_required_top_level(tmp_path, version)
    _write(tmp_path / "scripts/reaper/_internal/STEMwerk_Timing.lua", "-- timing\n")
    _write(tmp_path / "index.xml", _mk_index(version, ["STEMwerk.lua"]))

    sections, fail_count = release_gate.run_check(tmp_path)

    assert fail_count > 0
    msgs = "\n".join("\n".join(s.messages) for s in sections)
    assert "missing from index.xml payload" in msgs
    assert "scripts/reaper/_internal/STEMwerk_Timing.lua" in msgs


def test_valid_fixture_passes(tmp_path: Path) -> None:
    version = "2.2.2.2.2"
    _write(tmp_path / "VERSION", version + "\n")
    _seed_required_top_level(tmp_path, version)
    _write(tmp_path / "scripts/reaper/_internal/STEMwerk_Timing.lua", "-- timing\n")
    _write(tmp_path / "index.xml", _mk_index(version, ["STEMwerk.lua", "STEMwerk-SETUP.lua", "STEMwerk_Save_Support_Bundle.lua", "_internal/STEMwerk_Timing.lua"]))

    sections, fail_count = release_gate.run_check(tmp_path)

    assert fail_count == 0
    assert all(s.status in {"PASS", "WARN"} for s in sections)


def test_mismatched_duplicate_i18n_hash_and_root_payload_fails(tmp_path: Path) -> None:
    version = "2.2.2.2.2"
    _write(tmp_path / "VERSION", version + "\n")
    _seed_required_top_level(tmp_path, version)
    _write(tmp_path / "scripts/reaper/_internal/STEMwerk_Timing.lua", "-- timing\n")
    _seed_canonical_languages(tmp_path, suffix="-canonical")
    _write(tmp_path / "i18n/languages.lua", "local LANGUAGES = { en = {} }\n")
    _write(
        tmp_path / "index.xml",
        _mk_index_entries(
            version,
            [
                ("../STEMwerk.lua", "scripts/reaper/STEMwerk.lua"),
                ("../STEMwerk-SETUP.lua", "scripts/reaper/STEMwerk-SETUP.lua"),
                ("../STEMwerk_Save_Support_Bundle.lua", "scripts/reaper/STEMwerk_Save_Support_Bundle.lua"),
                ("../_internal/STEMwerk_Timing.lua", "scripts/reaper/_internal/STEMwerk_Timing.lua"),
                ("../i18n/languages.lua", "i18n/languages.lua"),
            ],
        ),
    )

    sections, fail_count = release_gate.run_check(tmp_path)

    assert fail_count > 0
    msgs = "\n".join("\n".join(s.messages) for s in sections)
    assert "duplicate i18n sources differ" in msgs
    assert "non-canonical root i18n appears in payload" in msgs


def test_dks_key_missing_in_locale_fails(tmp_path: Path) -> None:
    version = "2.2.2.2.2"
    _write(tmp_path / "VERSION", version + "\n")
    _seed_required_top_level(tmp_path, version)
    _write(
        tmp_path / "scripts/reaper/STEMwerk.lua",
        f'-- @version {version}\nlocal APP_VERSION = "{version}"\nlocal x = tr("workflow_edks_label")\n',
    )
    _write(tmp_path / "scripts/reaper/_internal/STEMwerk_Timing.lua", "-- timing\n")
    _seed_canonical_languages(tmp_path)
    lang = (tmp_path / "scripts/reaper/i18n/languages.lua").read_text(encoding="utf-8")
    lang = lang.replace('        help_native_drumkit_guidance = "x",\n', "")
    _write(tmp_path / "scripts/reaper/i18n/languages.lua", lang)
    _write(
        tmp_path / "index.xml",
        _mk_index_entries(
            version,
            [
                ("../STEMwerk.lua", "scripts/reaper/STEMwerk.lua"),
                ("../STEMwerk-SETUP.lua", "scripts/reaper/STEMwerk-SETUP.lua"),
                ("../STEMwerk_Save_Support_Bundle.lua", "scripts/reaper/STEMwerk_Save_Support_Bundle.lua"),
                ("../_internal/STEMwerk_Timing.lua", "scripts/reaper/_internal/STEMwerk_Timing.lua"),
                ("../i18n/languages.lua", "scripts/reaper/i18n/languages.lua"),
            ],
        ),
    )

    sections, fail_count = release_gate.run_check(tmp_path)

    assert fail_count > 0
    msgs = "\n".join("\n".join(s.messages) for s in sections)
    assert "locale missing DKS keys" in msgs
    assert "help_native_drumkit_guidance" in msgs


def test_prototype_script_in_payload_fails(tmp_path: Path) -> None:
    version = "2.2.2.2.2"
    _write(tmp_path / "VERSION", version + "\n")
    _seed_required_top_level(tmp_path, version)
    _write(tmp_path / "scripts/reaper/_internal/STEMwerk_Timing.lua", "-- timing\n")
    _write(tmp_path / "scripts/reaper/STEMwerk_DrumSep_Workflow_Prototype.lua", "-- proto\n")
    _write(
        tmp_path / "index.xml",
        _mk_index(
            version,
            [
                "STEMwerk.lua",
                "STEMwerk-SETUP.lua",
                "STEMwerk_Save_Support_Bundle.lua",
                "_internal/STEMwerk_Timing.lua",
                "STEMwerk_DrumSep_Workflow_Prototype.lua",
            ],
        ),
    )

    sections, fail_count = release_gate.run_check(tmp_path)

    assert fail_count > 0
    msgs = "\n".join("\n".join(s.messages) for s in sections)
    assert "prototype script must not be in public payload" in msgs
