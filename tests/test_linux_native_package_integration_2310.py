import hashlib
import os
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "installer/linux/stemwerk-integrate-reaper"
HELPER_COMMAND = "stemwerk-integrate-reaper"
EXCLUDED_DEV_SCRIPTS = {
    "STEMwerk_Benchmark_Flashy_Idle.lua",
    "STEMwerk_Benchmark_REAPER_Native_Idle.lua",
    "STEMwerk_Dev_Prepare_Benchmark_State.lua",
    "STEMwerk_Dev_Project_State_Snapshot.lua",
}


def _stage_payload(destination: Path) -> None:
    command = (
        f'source "{ROOT / "installer/linux/stage_payload.sh"}"; '
        f'copy_linux_payload "{ROOT}" "{destination}"'
    )
    subprocess.run(("bash", "-c", command), cwd=ROOT, check=True)


def _run_helper(source: Path, resource: Path, home: Path) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment.update(
        {
            "HOME": str(home),
            "REAPER_RESOURCE_PATH": str(resource),
            "STEMWERK_INTEGRATION_SOURCE": str(source),
        }
    )
    return subprocess.run(
        (str(HELPER),),
        cwd=ROOT,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )


def _tree_manifest(root: Path) -> dict[str, str]:
    return {
        path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in root.rglob("*")
        if path.is_file()
    }


def test_fresh_user_gets_complete_clean_linux_payload(tmp_path):
    from tools import release_gate

    source = tmp_path / "source"
    resource = tmp_path / "reaper-resource"
    home = tmp_path / "home"
    _stage_payload(source)

    result = _run_helper(source, resource, home)

    assert result.returncode == 0, result.stderr
    target = resource / "Scripts/STEMwerk-reaper"
    setup = (target / "STEMwerk-SETUP.lua").read_text(encoding="utf-8")
    assert "-- @version 2.3.1.0" in setup

    contract = release_gate.parse_production_payload_contract(release_gate.PRODUCTION_PAYLOAD_CONTRACT)
    required = release_gate.required_files_for_platform(contract, "linux")
    missing = sorted(
        path for path in required if not (target / path.removeprefix("scripts/reaper/")).is_file()
    )
    assert missing == []
    assert not any((target / name).exists() for name in EXCLUDED_DEV_SCRIPTS)
    assert list(target.glob("vendor/wheels/darwin-*/*.whl")) == []


def test_default_target_uses_existing_linux_reaper_resource_fallback(tmp_path):
    source = tmp_path / "source"
    home = tmp_path / "home"
    _stage_payload(source)
    environment = os.environ.copy()
    environment.update({"HOME": str(home), "STEMWERK_INTEGRATION_SOURCE": str(source)})
    environment.pop("REAPER_RESOURCE_PATH", None)

    result = subprocess.run(
        (str(HELPER),),
        cwd=ROOT,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert home.joinpath(
        ".config/REAPER/Scripts/STEMwerk-reaper/STEMwerk-SETUP.lua"
    ).is_file()


def test_existing_install_is_replaced_without_touching_runtime_or_models(tmp_path):
    source = tmp_path / "source"
    resource = tmp_path / "reaper-resource"
    home = tmp_path / "home"
    target = resource / "Scripts/STEMwerk-reaper"
    runtime = home / ".local/share/STEMwerk"
    target.mkdir(parents=True)
    runtime.joinpath("models").mkdir(parents=True)
    target.joinpath("STEMwerk-SETUP.lua").write_text("-- @version 2.3.0.7\n", encoding="utf-8")
    target.joinpath("stale-package-owned.lua").write_text("obsolete\n", encoding="utf-8")
    runtime.joinpath("models/model.th").write_bytes(b"existing-model")
    runtime.joinpath("state.env").write_text("READY=yes\n", encoding="utf-8")
    runtime_before = _tree_manifest(runtime)
    _stage_payload(source)

    result = _run_helper(source, resource, home)

    assert result.returncode == 0, result.stderr
    assert "-- @version 2.3.1.0" in target.joinpath("STEMwerk-SETUP.lua").read_text()
    assert not target.joinpath("stale-package-owned.lua").exists()
    assert _tree_manifest(runtime) == runtime_before


def test_repeated_integration_is_idempotent(tmp_path):
    source = tmp_path / "source"
    resource = tmp_path / "reaper-resource"
    home = tmp_path / "home"
    _stage_payload(source)

    first = _run_helper(source, resource, home)
    target = resource / "Scripts/STEMwerk-reaper"
    first_manifest = _tree_manifest(target)
    second = _run_helper(source, resource, home)

    assert first.returncode == 0, first.stderr
    assert second.returncode == 0, second.stderr
    assert _tree_manifest(target) == first_manifest


@pytest.mark.parametrize("resource", (Path("relative-resource"), Path("/")))
def test_unsafe_resource_paths_are_rejected(tmp_path, resource):
    source = tmp_path / "source"
    _stage_payload(source)

    result = _run_helper(source, resource, tmp_path / "home")

    assert result.returncode != 0
    assert "unsafe REAPER resource path" in result.stderr


def test_symlinked_target_is_rejected(tmp_path):
    source = tmp_path / "source"
    resource = tmp_path / "reaper-resource"
    external = tmp_path / "external"
    scripts = resource / "Scripts"
    scripts.mkdir(parents=True)
    external.mkdir()
    scripts.joinpath("STEMwerk-reaper").symlink_to(external, target_is_directory=True)
    _stage_payload(source)

    result = _run_helper(source, resource, tmp_path / "home")

    assert result.returncode != 0
    assert "unsafe integration target" in result.stderr
    assert list(external.iterdir()) == []


def test_symlinked_scripts_directory_is_rejected(tmp_path):
    source = tmp_path / "source"
    resource = tmp_path / "reaper-resource"
    external = tmp_path / "external"
    resource.mkdir()
    external.mkdir()
    resource.joinpath("Scripts").symlink_to(external, target_is_directory=True)
    _stage_payload(source)

    result = _run_helper(source, resource, tmp_path / "home")

    assert result.returncode != 0
    assert "unsafe integration target" in result.stderr
    assert list(external.iterdir()) == []


def test_source_nested_below_target_is_rejected_before_copy(tmp_path):
    resource = tmp_path / "reaper-resource"
    target = resource / "Scripts/STEMwerk-reaper"
    source = target / "package-source"
    _stage_payload(source)

    result = _run_helper(source, resource, tmp_path / "home")

    assert result.returncode != 0
    assert "source and target overlap" in result.stderr
    assert source.joinpath("STEMwerk-SETUP.lua").is_file()


def test_helper_is_user_context_only_and_writes_no_runtime_state():
    helper = HELPER.read_text(encoding="utf-8")
    assert "EUID" in helper and "must not be run as root" in helper
    assert ".local/share/STEMwerk" not in helper
    assert "sudo" not in helper


def test_native_package_routes_install_helper_and_show_exact_command():
    deb = (ROOT / "installer/linux/build_deb.sh").read_text(encoding="utf-8")
    rpm_builder = (ROOT / "installer/linux/build_rpm.sh").read_text(encoding="utf-8")
    rpm_spec = (ROOT / "installer/linux/rpm/stemwerk.spec").read_text(encoding="utf-8")
    arch_builder = (ROOT / "installer/linux/build_archpkg.sh").read_text(encoding="utf-8")
    pkgbuild = (ROOT / "installer/linux/arch/PKGBUILD").read_text(encoding="utf-8")
    arch_install = (ROOT / "installer/linux/arch/stemwerk.install").read_text(encoding="utf-8")

    assert HELPER.is_file() and os.access(HELPER, os.X_OK)
    assert 'usr/bin/stemwerk-integrate-reaper' in deb
    assert "Depends: rsync" in deb
    assert HELPER_COMMAND in deb
    assert 'stemwerk-integrate-reaper' in rpm_builder
    assert '/usr/bin/stemwerk-integrate-reaper' in rpm_spec
    assert "Requires:       rsync" in rpm_spec
    assert HELPER_COMMAND in rpm_spec
    assert 'stemwerk-integrate-reaper' in arch_builder
    assert '/usr/bin/stemwerk-integrate-reaper' in pkgbuild
    assert "depends=('rsync')" in pkgbuild
    assert HELPER_COMMAND in arch_install
    for message_source in (deb, rpm_spec, arch_install):
        assert "Actions -> Show action list -> ReaScript: Load" in message_source
        assert "STEMwerk_Setup_Toolbar.lua" in message_source


def test_appimage_keeps_equivalent_user_copy_behavior():
    appimage = (ROOT / "installer/linux/build_appimage.sh").read_text(encoding="utf-8")
    assert 'REAPER_SCRIPTS="$HOME/.config/REAPER/Scripts"' in appimage
    assert 'DEST="$REAPER_SCRIPTS/STEMwerk-reaper"' in appimage
    assert 'rsync -a --delete "$SRC/" "$DEST/"' in appimage
    assert "STEMwerk_Setup_Toolbar.lua" not in appimage or "Load ReaScript" in appimage
