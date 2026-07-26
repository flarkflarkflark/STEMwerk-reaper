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
