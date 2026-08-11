from __future__ import annotations

from pathlib import Path

import pytest

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


def _seed_required_top_level(root: Path, version: str) -> None:
    _write(
        root / "scripts/reaper/STEMwerk.lua",
        f'-- @version {version}\nlocal APP_VERSION = "{version}"\ndofile(script_path .. "_internal/STEMwerk_Timing.lua")\n',
    )
    _write(
        root / "scripts/reaper/STEMwerk-SETUP.lua",
        f"-- @version {version}\n",
    )
    _write(root / "scripts/reaper/STEMwerk_Save_Support_Bundle.lua", f"-- @version {version}\n")
    _write(
        root / "scripts/reaper/STEMwerk_Bootstrap_macOS.sh",
        "#!/bin/sh\n"
        "_guard_script=\"${SCRIPT_DIR}/_internal/stemwerk_samplerate_guard.py\"\n",
    )


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
    _write(tmp_path / "scripts/reaper/_internal/stemwerk_samplerate_guard.py", "# guard\n")
    _write(
        tmp_path / "tools/production_payload_contract.txt",
        "\n".join(
            f"required\tcommon\tscripts/reaper/{rel}"
            for rel in (
                "STEMwerk.lua",
                "STEMwerk-SETUP.lua",
                "STEMwerk_Save_Support_Bundle.lua",
                "_internal/STEMwerk_Timing.lua",
                "_internal/stemwerk_samplerate_guard.py",
            )
        )
        + "\n",
    )
    _write(
        tmp_path / "index.xml",
        _mk_index(
            version,
            [
                "STEMwerk.lua",
                "STEMwerk-SETUP.lua",
                "STEMwerk_Save_Support_Bundle.lua",
                "_internal/STEMwerk_Timing.lua",
                "_internal/stemwerk_samplerate_guard.py",
            ],
        ),
    )

    sections, fail_count = release_gate.run_check(tmp_path)

    assert fail_count == 0
    assert all(s.status in {"PASS", "WARN"} for s in sections)


def test_samplerate_guard_referenced_by_bootstrap_must_be_in_payload(tmp_path: Path) -> None:
    version = "2.2.2.2.2"
    _write(tmp_path / "VERSION", version + "\n")
    _seed_required_top_level(tmp_path, version)
    _write(tmp_path / "scripts/reaper/_internal/STEMwerk_Timing.lua", "-- timing\n")
    _write(tmp_path / "scripts/reaper/_internal/stemwerk_samplerate_guard.py", "# guard\n")
    _write(
        tmp_path / "index.xml",
        _mk_index(
            version,
            [
                "STEMwerk.lua",
                "STEMwerk-SETUP.lua",
                "STEMwerk_Save_Support_Bundle.lua",
                "_internal/STEMwerk_Timing.lua",
            ],
        ),
    )

    sections, fail_count = release_gate.run_check(tmp_path)

    assert fail_count > 0
    msgs = "\n".join("\n".join(s.messages) for s in sections)
    assert "bootstrap references helper missing from index.xml payload" in msgs
    assert "scripts/reaper/_internal/stemwerk_samplerate_guard.py" in msgs


def _contract_path(tmp_path: Path, text: str) -> Path:
    p = tmp_path / "contract.txt"
    p.write_text(text, encoding="utf-8")
    return p


# --- valid contract lines --------------------------------------------------


def test_contract_accepts_required_common(tmp_path: Path) -> None:
    p = _contract_path(tmp_path, "required\tcommon\tscripts/reaper/STEMwerk.lua\n")
    contract = release_gate.parse_production_payload_contract(p)
    assert contract.required["common"] == {"scripts/reaper/STEMwerk.lua"}


def test_contract_accepts_required_platform_specific(tmp_path: Path) -> None:
    p = _contract_path(tmp_path, "required\tmacos\tscripts/reaper/STEMwerk_Bootstrap_macOS.sh\n")
    contract = release_gate.parse_production_payload_contract(p)
    assert contract.required["macos"] == {"scripts/reaper/STEMwerk_Bootstrap_macOS.sh"}
    assert contract.required["common"] == set()


def test_contract_accepts_optional_platform_specific(tmp_path: Path) -> None:
    p = _contract_path(tmp_path, "optional\twindows\tscripts/reaper/foo.png\n")
    contract = release_gate.parse_production_payload_contract(p)
    assert contract.optional["windows"] == {"scripts/reaper/foo.png"}
    assert contract.required["windows"] == set()


def test_contract_accepts_blank_lines_and_comments(tmp_path: Path) -> None:
    p = _contract_path(
        tmp_path,
        "# a comment\n"
        "\n"
        "   \n"
        "  # indented comment\n"
        "required\tcommon\tscripts/reaper/STEMwerk.lua\n"
        "# trailing comment\n",
    )
    contract = release_gate.parse_production_payload_contract(p)
    assert contract.required["common"] == {"scripts/reaper/STEMwerk.lua"}


def test_contract_rejects_leading_whitespace_before_data_line(tmp_path: Path) -> None:
    # Blank/comment lines are still detected permissively, but a real data
    # line with stray edge whitespace is no longer silently trimmed -- the
    # leading spaces become part of the "requirement" field and fail exact
    # match against the known class set.
    p = _contract_path(tmp_path, "  required\tcommon\tscripts/reaper/STEMwerk.lua\n")
    with pytest.raises(ValueError, match="unknown requirement class"):
        release_gate.parse_production_payload_contract(p)


def test_contract_rejects_trailing_whitespace_after_data_line(tmp_path: Path) -> None:
    p = _contract_path(tmp_path, "required\tcommon\tscripts/reaper/STEMwerk.lua  \n")
    with pytest.raises(ValueError, match="whitespace"):
        release_gate.parse_production_payload_contract(p)


def test_contract_accepts_crlf(tmp_path: Path) -> None:
    p = _contract_path(tmp_path, "required\tcommon\tscripts/reaper/STEMwerk.lua\r\n")
    contract = release_gate.parse_production_payload_contract(p)
    assert contract.required["common"] == {"scripts/reaper/STEMwerk.lua"}


def test_contract_accepts_same_path_under_two_different_specific_platforms(tmp_path: Path) -> None:
    p = _contract_path(
        tmp_path,
        "required\tmacos\tscripts/reaper/_internal/STEMwerk_Managed_Python.sh\n"
        "required\tlinux\tscripts/reaper/_internal/STEMwerk_Managed_Python.sh\n",
    )
    contract = release_gate.parse_production_payload_contract(p)
    assert "scripts/reaper/_internal/STEMwerk_Managed_Python.sh" in contract.required["macos"]
    assert "scripts/reaper/_internal/STEMwerk_Managed_Python.sh" in contract.required["linux"]


# --- invalid contract lines: must fail closed -------------------------------


@pytest.mark.parametrize(
    "bad_path",
    [
        "../foo",
        "a/../../foo",
        "scripts/../etc/passwd",
        "a/./b",
    ],
)
def test_contract_rejects_path_traversal(tmp_path: Path, bad_path: str) -> None:
    p = _contract_path(tmp_path, f"required\tcommon\t{bad_path}\n")
    with pytest.raises(ValueError, match="traversal|not normalized"):
        release_gate.parse_production_payload_contract(p)


def test_contract_rejects_absolute_path(tmp_path: Path) -> None:
    p = _contract_path(tmp_path, "required\tcommon\t/etc/passwd\n")
    with pytest.raises(ValueError, match="absolute"):
        release_gate.parse_production_payload_contract(p)


def test_contract_rejects_backslash_path(tmp_path: Path) -> None:
    p = _contract_path(tmp_path, "required\tcommon\tscripts\\reaper\\STEMwerk.lua\n")
    with pytest.raises(ValueError, match="backslash"):
        release_gate.parse_production_payload_contract(p)


def test_contract_rejects_empty_path(tmp_path: Path) -> None:
    p = _contract_path(tmp_path, "required\tcommon\t\n")
    with pytest.raises(ValueError, match="empty path|expected"):
        release_gate.parse_production_payload_contract(p)


def test_contract_rejects_unknown_platform(tmp_path: Path) -> None:
    p = _contract_path(tmp_path, "required\tfreebsd\tscripts/reaper/STEMwerk.lua\n")
    with pytest.raises(ValueError, match="unknown platform"):
        release_gate.parse_production_payload_contract(p)


def test_contract_rejects_unknown_requirement_class(tmp_path: Path) -> None:
    p = _contract_path(tmp_path, "mandatory\tcommon\tscripts/reaper/STEMwerk.lua\n")
    with pytest.raises(ValueError, match="unknown requirement class"):
        release_gate.parse_production_payload_contract(p)


def test_contract_rejects_malformed_field_count(tmp_path: Path) -> None:
    p = _contract_path(tmp_path, "common\tscripts/reaper/STEMwerk.lua\n")
    with pytest.raises(ValueError, match="expected"):
        release_gate.parse_production_payload_contract(p)


def test_contract_rejects_exact_duplicate_entry(tmp_path: Path) -> None:
    p = _contract_path(
        tmp_path,
        "required\tcommon\tscripts/reaper/STEMwerk.lua\n"
        "required\tcommon\tscripts/reaper/STEMwerk.lua\n",
    )
    with pytest.raises(ValueError, match="duplicate"):
        release_gate.parse_production_payload_contract(p)


def test_contract_rejects_same_path_different_requirement_class(tmp_path: Path) -> None:
    p = _contract_path(
        tmp_path,
        "required\tcommon\tscripts/reaper/STEMwerk.lua\n"
        "optional\tcommon\tscripts/reaper/STEMwerk.lua\n",
    )
    with pytest.raises(ValueError, match="already declared"):
        release_gate.parse_production_payload_contract(p)


def test_contract_rejects_common_and_specific_platform_conflict(tmp_path: Path) -> None:
    p = _contract_path(
        tmp_path,
        "required\tcommon\tscripts/reaper/STEMwerk_Set_FFmpegPath.lua\n"
        "required\tlinux\tscripts/reaper/STEMwerk_Set_FFmpegPath.lua\n",
    )
    with pytest.raises(ValueError, match="common"):
        release_gate.parse_production_payload_contract(p)


def test_contract_rejects_specific_platform_and_common_conflict_reversed_order(tmp_path: Path) -> None:
    p = _contract_path(
        tmp_path,
        "required\tmacos\tscripts/reaper/foo.lua\n"
        "required\tcommon\tscripts/reaper/foo.lua\n",
    )
    with pytest.raises(ValueError, match="common"):
        release_gate.parse_production_payload_contract(p)


@pytest.mark.parametrize(
    "colliding_path",
    [
        "scripts//reaper/STEMwerk.lua",
        "scripts/reaper/STEMwerk.lua/",
    ],
)
def test_contract_rejects_normalization_collisions(tmp_path: Path, colliding_path: str) -> None:
    p = _contract_path(tmp_path, f"required\tcommon\t{colliding_path}\n")
    with pytest.raises(ValueError, match="empty segment|not normalized"):
        release_gate.parse_production_payload_contract(p)


# --- Windows drive-letter paths --------------------------------------------


@pytest.mark.parametrize(
    "drive_path",
    [
        "C:/absolute/path",
        "c:/absolute/path",
        "C:relative/path",
        "z:foo/bar",
    ],
)
def test_contract_rejects_windows_drive_paths(tmp_path: Path, drive_path: str) -> None:
    p = _contract_path(tmp_path, f"required\tcommon\t{drive_path}\n")
    with pytest.raises(ValueError, match="drive-letter"):
        release_gate.parse_production_payload_contract(p)


# --- edge/embedded whitespace, including Unicode --------------------------


@pytest.mark.parametrize(
    "whitespace_char,label",
    [
        (" ", "ascii-space"),
        ("\t", "tab"),  # note: a literal tab would actually split fields;
        ("\xa0", "nbsp"),
        ("\u2003", "em-space"),
        ("\u2028", "line-separator"),
        ("\u2029", "paragraph-separator"),
    ],
)
def test_contract_rejects_whitespace_prefixed_path(tmp_path: Path, whitespace_char: str, label: str) -> None:
    raw_path = f"{whitespace_char}scripts/reaper/STEMwerk.lua"
    p = _contract_path(tmp_path, f"required\tcommon\t{raw_path}\n")
    with pytest.raises(ValueError):
        release_gate.parse_production_payload_contract(p)


@pytest.mark.parametrize(
    "whitespace_char",
    [" ", "\xa0", "\u2003", "\u2028", "\u2029"],
)
def test_contract_rejects_whitespace_suffixed_path(tmp_path: Path, whitespace_char: str) -> None:
    raw_path = f"scripts/reaper/STEMwerk.lua{whitespace_char}"
    p = _contract_path(tmp_path, f"required\tcommon\t{raw_path}\n")
    with pytest.raises(ValueError, match="whitespace"):
        release_gate.parse_production_payload_contract(p)


def test_contract_rejects_nbsp_prefixed_path_specifically(tmp_path: Path) -> None:
    p = _contract_path(tmp_path, "required\tcommon\t\xa0scripts/reaper/STEMwerk.lua\n")
    with pytest.raises(ValueError, match="whitespace"):
        release_gate.parse_production_payload_contract(p)


def test_contract_rejects_nbsp_suffixed_path_specifically(tmp_path: Path) -> None:
    p = _contract_path(tmp_path, "required\tcommon\tscripts/reaper/STEMwerk.lua\xa0\n")
    with pytest.raises(ValueError, match="whitespace"):
        release_gate.parse_production_payload_contract(p)


def test_contract_rejects_unicode_line_separator_embedded_mid_path(tmp_path: Path) -> None:
    p = _contract_path(tmp_path, "required\tcommon\tscripts/reaper/STEM\u2028werk.lua\n")
    with pytest.raises(ValueError, match="whitespace"):
        release_gate.parse_production_payload_contract(p)


def test_contract_rejects_unicode_paragraph_separator_embedded_mid_path(tmp_path: Path) -> None:
    p = _contract_path(tmp_path, "required\tcommon\tscripts/reaper/STEM\u2029werk.lua\n")
    with pytest.raises(ValueError, match="whitespace"):
        release_gate.parse_production_payload_contract(p)


# --- control characters and DEL --------------------------------------------


@pytest.mark.parametrize(
    "control_char,codepoint_label",
    [
        ("\x00", "NUL"),
        ("\x01", "0x01"),
        ("\x08", "0x08"),
        ("\x0b", "0x0B"),
        ("\x0c", "0x0C"),
        ("\x1f", "0x1F"),
        ("\x7f", "DEL"),
    ],
)
def test_contract_rejects_control_and_del_characters(tmp_path: Path, control_char: str, codepoint_label: str) -> None:
    raw_path = f"scripts/reaper/STEM{control_char}werk.lua"
    p = _contract_path(tmp_path, f"required\tcommon\t{raw_path}\n")
    with pytest.raises(ValueError):
        release_gate.parse_production_payload_contract(p)


def test_contract_rejects_embedded_nul_specifically(tmp_path: Path) -> None:
    p = _contract_path(tmp_path, "required\tcommon\tscripts/reaper/STEM\x00werk.lua\n")
    with pytest.raises(ValueError, match="control character U\\+0000"):
        release_gate.parse_production_payload_contract(p)


# --- no silent normalization: prove failure, not silent repair -------------


def test_contract_whitespace_corrupted_field_does_not_silently_become_valid(tmp_path: Path) -> None:
    """A path that WOULD be a legitimate required entry once trimmed must
    still fail -- the parser must not trim-then-accept. pytest.raises
    itself is the proof: were the whitespace silently normalized, this
    call would return a ProductionPayloadContract instead of raising, and
    the test would fail with "DID NOT RAISE"."""
    p = _contract_path(tmp_path, "required\tcommon\t scripts/reaper/STEMwerk.lua \n")
    with pytest.raises(ValueError, match="whitespace"):
        release_gate.parse_production_payload_contract(p)


def test_contract_nbsp_corrupted_field_does_not_silently_become_valid(tmp_path: Path) -> None:
    p = _contract_path(tmp_path, "required\tcommon\t\xa0scripts/reaper/STEMwerk.lua\xa0\n")
    with pytest.raises(ValueError, match="whitespace"):
        release_gate.parse_production_payload_contract(p)


def test_contract_windows_drive_path_does_not_silently_become_valid(tmp_path: Path) -> None:
    p = _contract_path(tmp_path, "required\tcommon\tC:/scripts/reaper/STEMwerk.lua\n")
    with pytest.raises(ValueError):
        release_gate.parse_production_payload_contract(p)


# --- the real contract file must still parse cleanly -----------------------


def test_real_production_payload_contract_still_parses(tmp_path: Path) -> None:
    contract = release_gate.parse_production_payload_contract(release_gate.PRODUCTION_PAYLOAD_CONTRACT)
    required = release_gate.required_files_for_platform(contract, "reapack")
    assert len(required) == 84
