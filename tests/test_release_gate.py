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


def test_contract_accepts_whitespace_and_comments(tmp_path: Path) -> None:
    p = _contract_path(
        tmp_path,
        "# a comment\n"
        "\n"
        "   \n"
        "  required\tcommon\tscripts/reaper/STEMwerk.lua  \n"
        "# trailing comment\n",
    )
    contract = release_gate.parse_production_payload_contract(p)
    assert contract.required["common"] == {"scripts/reaper/STEMwerk.lua"}


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
