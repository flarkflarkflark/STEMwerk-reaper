"""Release-chain regression gates for the issue #111 macOS FFmpeg hotfix."""

from __future__ import annotations

import json
import os
import stat
from pathlib import Path
from types import SimpleNamespace

import pytest

from installer.macos import audit_payload, audit_pkg
from tools import build_macos_apple_silicon_payload as payload_builder
from tools import macos_ffmpeg


ROOT = Path(__file__).resolve().parents[1]


def test_release_workflow_builds_official_source_online_and_bundled_packages() -> None:
    workflow = (ROOT / ".github/workflows/release-installers.yml").read_text(encoding="utf-8")
    macos_job = workflow[workflow.index("  macos-pkg:"):workflow.index("  linux-packages:")]
    assert "runs-on: macos-14" in macos_job
    assert "tools/build_macos_apple_silicon_payload.py" in macos_job
    assert "tools/macos_managed_python.py --print-artifact-field" in macos_job
    assert "--managed-python-artifact" in macos_job
    assert "--release-mode" in macos_job
    assert "--allow-development-ffmpeg-override" not in macos_job
    assert "--ffmpeg" not in macos_job and "--ffprobe" not in macos_job
    assert "bash installer/macos/build_pkg.sh\n" in macos_job
    assert "bash installer/macos/build_pkg.sh --variant bundled-apple-silicon" in macos_job
    assert "source/ffmpeg-8.0.3.tar.xz" in macos_job
    assert "final-package-audit.json" in macos_job


def test_package_builder_makes_final_audit_mandatory_after_repack() -> None:
    script = (ROOT / "installer/macos/build_pkg.sh").read_text(encoding="utf-8")
    repack = script.index("repack_pkg_without_appledouble\n", script.index("pkgbuild \\"))
    final_audit = script.index('python3 "$PACKAGE_AUDITOR"', repack)
    built = script.index('echo "Built: $OUTPUT_PKG"', final_audit)
    assert repack < final_audit < built
    assert "--expected-inventory \"$PAYLOAD_INVENTORY\"" in script


def test_release_mode_refuses_overrides_and_development_requires_opt_in(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    ffmpeg = tmp_path / "incoming/ffmpeg"
    ffmpeg.parent.mkdir()
    ffmpeg.write_bytes(b"ffmpeg")
    ffprobe = ffmpeg.parent / "ffprobe"
    ffprobe.write_bytes(b"ffprobe")
    monkeypatch.setattr(
        payload_builder,
        "validate_ffmpeg_pair",
        lambda *_args, **_kwargs: {"versions": {"ffmpeg": "ffmpeg version development fixture"}},
    )
    with pytest.raises(RuntimeError, match="require --allow-development"):
        payload_builder.prepare_portable_ffmpeg(tmp_path / "denied", str(ffmpeg), str(ffprobe))
    with pytest.raises(RuntimeError, match="Release mode refuses"):
        payload_builder.prepare_portable_ffmpeg(
            tmp_path / "release-denied", str(ffmpeg), str(ffprobe),
            release_mode=True, allow_development_override=True,
        )
    supplied = ffmpeg.parent / "SOURCE_PROVENANCE.json"
    supplied.write_text(json.dumps({
        "source_url": macos_ffmpeg.FFMPEG_SOURCE_URL,
        "source_sha256": macos_ffmpeg.FFMPEG_SOURCE_SHA256,
        "license": macos_ffmpeg.FFMPEG_LICENSE,
    }), encoding="utf-8")
    provenance = payload_builder.prepare_portable_ffmpeg(
        tmp_path / "development", str(ffmpeg), str(ffprobe),
        allow_development_override=True,
    )
    assert provenance["build_mode"] == "development-override"
    assert provenance["official_source_build"] is False
    assert provenance["release_eligible"] is False
    assert provenance["source_url"] == "development-override"


def _official_fixture(root: Path) -> tuple[Path, dict[str, object], dict[str, object]]:
    root.mkdir()
    (root / "ffmpeg").write_bytes(b"official ffmpeg")
    (root / "ffprobe").write_bytes(b"official ffprobe")
    (root / "COPYING.LGPLv2.1").write_text(
        "GNU LESSER GENERAL PUBLIC LICENSE\n", encoding="utf-8"
    )
    notice_values = (
        f"{macos_ffmpeg.FFMPEG_VERSION}\n{macos_ffmpeg.FFMPEG_SOURCE_URL}\n"
        f"{macos_ffmpeg.FFMPEG_SOURCE_SHA256}\n{macos_ffmpeg.FFMPEG_LICENSE}\n"
    )
    (root / "THIRD_PARTY_NOTICES.md").write_text(notice_values, encoding="utf-8")
    (root / "PROVENANCE.md").write_text(notice_values, encoding="utf-8")
    validation = {"closure": {"ffmpeg": [], "ffprobe": []}, "versions": {}}
    provenance: dict[str, object] = {
        "component": "FFmpeg",
        "build_mode": "official-source",
        "official_source_build": True,
        "release_eligible": True,
        "version": macos_ffmpeg.FFMPEG_VERSION,
        "license": macos_ffmpeg.FFMPEG_LICENSE,
        "source_url": macos_ffmpeg.FFMPEG_SOURCE_URL,
        "source_sha256": macos_ffmpeg.FFMPEG_SOURCE_SHA256,
        "deployment_target": macos_ffmpeg.MACOS_DEPLOYMENT_TARGET,
        "configure": ["./configure", *macos_ffmpeg.FFMPEG_CONFIGURE_FLAGS],
        "build_command": ["make", "-j1", "ffmpeg", "ffprobe"],
        "configuration_macros": {"CONFIG_GPL": 0, "CONFIG_NONFREE": 0},
        "toolchain": {
            "macos_version": "14.7", "macos_build": "fixture", "developer_dir": "/Developer",
            "xcode": "exit=0; Xcode fixture",
            "apple_clang": "Apple clang fixture", "sdk_path": "/SDK", "sdk_version": "14.5",
            "host_architecture": "arm64", "deployment_target": "12.0",
        },
        "reproducibility": (
            "pinned source and auditable build inputs; byte-identical reproducibility is not claimed"
        ),
        "source_artifact": {
            "filename": f"ffmpeg-{macos_ffmpeg.FFMPEG_VERSION}.tar.xz",
            "sha256": macos_ffmpeg.FFMPEG_SOURCE_SHA256,
        },
        "notices": {
            name: {"sha256": macos_ffmpeg.sha256_file(root / name), "size": (root / name).stat().st_size}
            for name in ("COPYING.LGPLv2.1", "THIRD_PARTY_NOTICES.md", "PROVENANCE.md")
        },
        "binaries": {
            name: {"sha256": macos_ffmpeg.sha256_file(root / name), "size": (root / name).stat().st_size}
            for name in ("ffmpeg", "ffprobe")
        },
        "validation": validation,
    }
    (root / "SOURCE_PROVENANCE.json").write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    manifest: dict[str, object] = {
        "source_provenance": {
            "ffmpeg_version": macos_ffmpeg.FFMPEG_VERSION,
            "ffmpeg_license": macos_ffmpeg.FFMPEG_LICENSE,
            "ffmpeg_source_url": macos_ffmpeg.FFMPEG_SOURCE_URL,
            "ffmpeg_source_sha256": macos_ffmpeg.FFMPEG_SOURCE_SHA256,
        },
        "ffmpeg": provenance,
        "contains": {"ffmpeg": True},
    }
    return root, provenance, manifest


@pytest.mark.parametrize(
    "mutation,match",
    [
        ("source_url", "source_url"),
        ("license", "license"),
        ("source_sha256", "source_sha256"),
        ("binary_hash", "binary integrity"),
        ("binary_size", "binary integrity"),
        ("manifest", "Manifest/provenance mismatch"),
        ("notice_missing", "Missing FFmpeg notice"),
        ("validation", "recorded validation/closure"),
    ],
)
def test_official_provenance_rejects_tampering(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, mutation: str, match: str
) -> None:
    ffmpeg_dir, provenance, manifest = _official_fixture(tmp_path / "ffmpeg")
    monkeypatch.setattr(macos_ffmpeg, "validate_ffmpeg_pair", lambda *_a, **_k: {
        "closure": {"ffmpeg": [], "ffprobe": []}, "versions": {}
    })
    if mutation in {"source_url", "license", "source_sha256"}:
        provenance[mutation] = "tampered"
    elif mutation == "binary_hash":
        provenance["binaries"]["ffmpeg"]["sha256"] = "0" * 64
    elif mutation == "binary_size":
        provenance["binaries"]["ffprobe"]["size"] = 0
    elif mutation == "manifest":
        manifest["source_provenance"]["ffmpeg_source_url"] = "tampered"
    elif mutation == "notice_missing":
        (ffmpeg_dir / "PROVENANCE.md").unlink()
    elif mutation == "validation":
        provenance["validation"] = {"tampered": True}
    (ffmpeg_dir / "SOURCE_PROVENANCE.json").write_text(json.dumps(provenance), encoding="utf-8")
    manifest["ffmpeg"] = provenance
    with pytest.raises(RuntimeError, match=match):
        macos_ffmpeg.validate_official_provenance(ffmpeg_dir, manifest=manifest)


def test_minimum_os_and_rpaths_are_read_from_real_load_command_shape(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    output = """Load command 10
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 1
    minos 11.0
      sdk 14.5
Load command 11
      cmd LC_RPATH
  cmdsize 40
     path /opt/homebrew/lib (offset 12)
"""
    monkeypatch.setattr(
        macos_ffmpeg, "_run", lambda *_args, **_kwargs: SimpleNamespace(stdout=output)
    )
    metadata = macos_ffmpeg.macho_build_metadata(tmp_path / "ffmpeg")
    assert metadata == {"minimum_os": "11.0", "sdk": "14.5", "rpaths": ["/opt/homebrew/lib"]}


def test_buildconf_parser_normalizes_ffmpeg_shell_quotes() -> None:
    output = """  configuration:
    --arch=arm64
    --extra-cflags='-arch arm64 -mmacosx-version-min=12.0'
"""
    assert macos_ffmpeg.parse_buildconf_flags(output) == [
        "--arch=arm64", "--extra-cflags=-arch arm64 -mmacosx-version-min=12.0"
    ]


def test_official_pair_rejects_wrong_minimum_os(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    ffmpeg = tmp_path / "ffmpeg"
    ffprobe = tmp_path / "ffprobe"
    for path in (ffmpeg, ffprobe):
        path.write_bytes(b"fixture")
        path.chmod(0o755)
    monkeypatch.setattr(macos_ffmpeg, "audit_macho_closure", lambda *_a, **_k: [])
    monkeypatch.setattr(
        macos_ffmpeg, "macho_build_metadata",
        lambda _path: {"minimum_os": "11.0", "sdk": "14.5", "rpaths": []},
    )
    monkeypatch.setattr(macos_ffmpeg, "embedded_forbidden_paths", lambda _path: ())

    def fake_run(command, **_kwargs):
        label = Path(command[0]).name
        if command[1] == "-version":
            return SimpleNamespace(returncode=0, stdout=f"{label} version 8.0.3 fixture\n", stderr="")
        if command[1] == "-buildconf":
            return SimpleNamespace(
                returncode=0,
                stdout="\n".join(macos_ffmpeg.FFMPEG_CONFIGURE_FLAGS),
                stderr="",
            )
        return SimpleNamespace(returncode=0, stdout="GNU Lesser General Public", stderr="")

    monkeypatch.setattr(macos_ffmpeg.subprocess, "run", fake_run)
    with pytest.raises(RuntimeError, match="minimum macOS: 11.0"):
        macos_ffmpeg.validate_ffmpeg_pair(
            ffmpeg, ffprobe,
            expected_deployment_target=macos_ffmpeg.MACOS_DEPLOYMENT_TARGET,
            require_official_build=True,
        )


def test_inventory_comparison_detects_binary_change_and_payload_loss(tmp_path: Path) -> None:
    expected = tmp_path / "expected.json"
    actual = tmp_path / "actual.json"
    files = [
        {"path": "ffmpeg/ffmpeg", "type": "file", "mode": "0755", "size": 10, "sha256": "a", "link_target": None},
        {"path": "ffmpeg/ffprobe", "type": "file", "mode": "0755", "size": 11, "sha256": "b", "link_target": None},
    ]
    expected.write_text(json.dumps({"files": files}), encoding="utf-8")
    actual.write_text(json.dumps({"files": [dict(item) for item in files]}), encoding="utf-8")
    audit_pkg.compare_inventories(expected, actual)
    changed = [dict(item) for item in files]
    changed[0]["sha256"] = "tampered"
    actual.write_text(json.dumps({"files": changed}), encoding="utf-8")
    with pytest.raises(RuntimeError, match="changed=.*ffmpeg/ffmpeg"):
        audit_pkg.compare_inventories(expected, actual)
    actual.write_text(json.dumps({"files": files[:1]}), encoding="utf-8")
    with pytest.raises(RuntimeError, match="missing=.*ffmpeg/ffprobe"):
        audit_pkg.compare_inventories(expected, actual)


def test_payload_inventory_records_lstat_posix_modes_for_all_entry_types(tmp_path: Path) -> None:
    root = tmp_path / "payload"
    directory = root / "bin"
    directory.mkdir(parents=True)
    regular = directory / "tool"
    regular.write_bytes(b"identical bytes")
    link = root / "tool-link"
    link.symlink_to("bin/tool")
    root.chmod(0o750)
    directory.chmod(0o710)
    regular.chmod(0o755)

    records, _counts = audit_payload.inventory(root)
    by_path = {record["path"]: record for record in records}

    assert by_path["."]["type"] == "directory"
    assert by_path["."]["mode"] == "0750"
    assert by_path["bin"]["type"] == "directory"
    assert by_path["bin"]["mode"] == "0710"
    assert by_path["bin/tool"]["type"] == "file"
    assert by_path["bin/tool"]["mode"] == "0755"
    assert by_path["tool-link"]["type"] == "symlink"
    assert by_path["tool-link"]["mode"] == format(stat.S_IMODE(link.lstat().st_mode), "04o")
    assert by_path["tool-link"]["link_target"] == "bin/tool"
    assert by_path["tool-link"]["sha256"] is None


@pytest.mark.parametrize(
    "entry_type,before,after",
    [
        ("file", "0755", "0644"),
        ("file", "0644", "0755"),
        ("directory", "0755", "0700"),
        ("symlink", "0777", "0755"),
    ],
)
def test_inventory_comparison_rejects_mode_only_mutation(
    tmp_path: Path, entry_type: str, before: str, after: str
) -> None:
    expected = tmp_path / "expected.json"
    actual = tmp_path / "actual.json"
    common = {
        "path": f"payload/{entry_type}",
        "type": entry_type,
        "size": 15 if entry_type != "directory" else None,
        "sha256": "same-content-hash" if entry_type == "file" else None,
        "link_target": "target" if entry_type == "symlink" else None,
    }
    expected.write_text(json.dumps({"files": [{**common, "mode": before}]}), encoding="utf-8")
    actual.write_text(json.dumps({"files": [{**common, "mode": before}]}), encoding="utf-8")
    audit_pkg.compare_inventories(expected, actual)

    actual.write_text(json.dumps({"files": [{**common, "mode": after}]}), encoding="utf-8")
    with pytest.raises(RuntimeError, match=f"changed=.*payload/{entry_type}"):
        audit_pkg.compare_inventories(expected, actual)


def test_real_final_package_passes_post_repack_audit_when_requested(tmp_path: Path) -> None:
    package_value = os.environ.get("STEMWERK_2310_HOTFIX_PKG")
    if not package_value:
        pytest.skip("set STEMWERK_2310_HOTFIX_PKG after building the technical candidate")
    package = Path(package_value)
    inventory = ROOT / "installer/macos/build/bundled-apple-silicon/payload-inventory.json"
    result = audit_pkg.audit_package(
        package,
        variant="bundled-apple-silicon",
        expected_identifier="com.flarkaudio.stemwerk",
        expected_version=(ROOT / "VERSION").read_text(encoding="utf-8").strip(),
        expected_inventory=inventory,
        report=tmp_path / "audit.json",
    )
    assert result["final_payload_audit"] == "passed"
    assert result["staging_inventory_match"] is True
