"""S4 read-only plan and consent checks with controlled host observations."""
from __future__ import annotations

from pathlib import Path
import sys
from types import SimpleNamespace

import pytest

CORE_SRC = Path(__file__).resolve().parents[1] / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import install_preflight  # noqa: E402

pytestmark = pytest.mark.portable


def host(platform_id="linux-x86_64", **changes):
    values = dict(platform_id=platform_id, os_version="6.8", glibc_version="2.39",
                  free_bytes=20 * 1024**3, vcpp_runtime_present=True)
    values.update(changes)
    return install_preflight.HostFacts(**values)


def verification(state="not_installed", lock="free", lookup="fixture_registry"):
    return {"lookup": lookup, "installation_state": state, "lock_status": lock,
            "operation_in_progress": lock == "held", "operation_id": None}


def test_disk_minimum_and_estimate_have_different_outcomes(tmp_path):
    root = tmp_path / "root"
    baseline = install_preflight.plan("drum_kit", root, host())
    minimum = baseline["space"]["known_minimum_bytes"]
    estimate = baseline["space"]["estimate_bytes"]
    assert 0 < minimum < estimate
    assert minimum == install_preflight.ASSET_BYTES
    assert baseline["space"]["storage"]["final"]["ffmpeg_bytes"] is None
    assert baseline["space"]["storage"]["final"]["candidate_ffmpeg_bytes"] > 0
    assert estimate == sum(baseline["space"]["estimate_items"].values())
    assert baseline["space"]["estimate_items"]["ffmpeg_static_pair_bytes"] > 0
    below = install_preflight.plan("drum_kit", root, host(free_bytes=minimum - 1))
    at_minimum = install_preflight.plan("drum_kit", root, host(free_bytes=minimum))
    assert "insufficient_known_space" in below["blockers"]
    assert "insufficient_known_space" not in at_minimum["blockers"]
    assert "below_provisional_estimate" in at_minimum["warnings"]
    assert at_minimum["preflight_result"] == "incomplete"


def test_windows_full_tree_is_incomplete_even_when_known_paths_fit(tmp_path):
    result = install_preflight.plan("drum_kit", tmp_path / "root",
                                    host("win-x86_64", os_version="10.0.19045"))
    assert result["path_budget"]["status"] == "incomplete"
    assert result["path_budget"]["full_tree_max_length"] is None
    assert "windows_full_path_unmeasured" in result["incomplete"]


def test_unknown_os_and_vcpp_evidence_are_incomplete_not_too_old(tmp_path):
    linux = install_preflight.plan("drum_kit", tmp_path / "root",
                                    host(os_version="not-a-kernel", glibc_version=None))
    assert "os_version_unknown" in linux["incomplete"]
    assert "glibc_version_unknown" in linux["incomplete"]
    assert "os_too_old" not in linux["blockers"]
    windows = install_preflight.plan("drum_kit", tmp_path / "root",
                                      host("win-x86_64", os_version="10.0.19045",
                                           vcpp_runtime_present=None))
    assert "vcpp_runtime_unknown" in windows["incomplete"]
    assert "vcpp_runtime_missing" not in windows["blockers"]


def test_kernel_suffix_is_parsed_and_macos_compat_version_is_unknown(tmp_path):
    linux = install_preflight.plan("drum_kit", tmp_path / "root",
                                    host(os_version="6.6.32_1", glibc_version="2.39"))
    assert "os_version_unknown" not in linux["incomplete"]
    mac = install_preflight.plan("drum_kit", tmp_path / "root",
                                  host("darwin-arm64", os_version="10.16"))
    assert "os_version_unknown" in mac["incomplete"]
    assert "os_too_old" not in mac["blockers"]


def test_installed_state_lock_and_legacy_candidates_are_reported_without_mutation(tmp_path):
    root = tmp_path / "root"
    second = tmp_path / "other"
    for base in (root, second):
        marker = base / "state" / "ready_to_go.env"
        marker.parent.mkdir(parents=True)
        marker.write_text("legacy marker\n")
    before = {(base / "state" / "ready_to_go.env").read_bytes() for base in (root, second)}
    result = install_preflight.plan("drum_kit", root, host(),
        verification=verification(state="installed", lock="held"), legacy_roots=(root, second))
    assert result["installation"]["status"] == "installed"
    assert "existing_installation_detected" in result["warnings"]
    assert result["lock"]["status"] == "held"
    assert "lock_held" in result["blockers"]
    assert result["legacy_payloads"]["duplicate_status"] == "observed"
    assert "duplicate_legacy_payload" in result["warnings"]
    assert before == {(base / "state" / "ready_to_go.env").read_bytes() for base in (root, second)}
    assert all(sorted(p.name for p in base.iterdir()) == ["state"] for base in (root, second))


def test_unreadable_lock_and_no_registry_are_incomplete(tmp_path):
    result = install_preflight.plan("drum_kit", tmp_path / "root", host(),
        verification=verification(state="not_installed", lock="unreadable", lookup="no_registry"))
    assert result["installation"]["status"] == "unknown"
    assert "existing_installation_unknown" in result["incomplete"]
    assert "lock_state_unknown" in result["incomplete"]
    assert "lock_held" not in result["blockers"]


def test_known_planned_subpaths_are_checked(tmp_path, monkeypatch):
    root = tmp_path / "root"
    python = root / "runtimes" / "python"
    python.parent.mkdir(parents=True)
    target = tmp_path / "target"
    target.mkdir()
    try:
        python.symlink_to(target, target_is_directory=True)
    except (OSError, NotImplementedError):
        pytest.skip("directory symlinks unavailable")
    result = install_preflight.plan("drum_kit", root, host())
    assert "path_ineligible" in result["blockers"]
    python.unlink()
    real_access = install_preflight.os.access
    monkeypatch.setattr(install_preflight.os, "access",
        lambda path, mode: False if Path(path) == python.parent else real_access(path, mode))
    result = install_preflight.plan("drum_kit", root, host())
    assert "path_unwritable" in result["blockers"]


def test_non_ascii_consent_and_undecodable_root_are_named(tmp_path):
    result = install_preflight.plan("drum_kit", tmp_path / "root", host())
    with pytest.raises(install_preflight.PreflightError, match="plan_changed"):
        install_preflight.require_current_plan("é" * 64, "drum_kit", tmp_path / "root", host())
    if sys.platform != "win32":
        with pytest.raises(install_preflight.PreflightError, match="path_encoding_unsupported"):
            install_preflight.plan("drum_kit", tmp_path / "bad\udcff", host())


def test_registry_presence_is_not_proof_of_vcpp_functionality(monkeypatch):
    class Key:
        def __enter__(self):
            return self
        def __exit__(self, *_):
            return False
    fake = SimpleNamespace(HKEY_LOCAL_MACHINE=1, KEY_READ=1,
        KEY_WOW64_64KEY=2, KEY_WOW64_32KEY=4,
        OpenKey=lambda *_: Key(), QueryValueEx=lambda *_: (1, None))
    monkeypatch.setitem(sys.modules, "winreg", fake)
    assert install_preflight._windows_vcpp_registry() == (None, "registry_installed_unverified")
    fake.OpenKey = lambda *_: (_ for _ in ()).throw(FileNotFoundError())
    assert install_preflight._windows_vcpp_registry() == (None, "registry_missing_unverified")


def test_plan_is_read_only_and_fingerprint_excludes_free_space(tmp_path):
    root = tmp_path / "é-root"
    first = install_preflight.plan("drum_kit", root, host())
    second = install_preflight.plan("drum_kit", root, host(free_bytes=21 * 1024**3))
    assert not root.exists()
    assert first["preflight_result"] == "incomplete"
    assert not first["blockers"]
    assert first["fingerprint"] == second["fingerprint"]
    assert first["space"]["available_bytes"] != second["space"]["available_bytes"]
    assert first["space"]["estimate_items"]["ffmpeg_static_pair_bytes"] > 0
    assert first["space"]["estimate_items"]["drumsep_assets_bytes"] >= 2 * 437_655_116
    assert first["scope"] == "s4_assessment"
    assert [step["phase"] for step in first["actions"]["steps"]] == [
        "create_environment", "install_packages", "fetch_ffmpeg", "verify_ffmpeg",
        "fetch_assets", "verify_assets",
        "publish", "activate", "verify_module"]
    assert first["actions"]["steps"][2]["estimate_bytes"] == first["space"]["estimate_items"]["ffmpeg_static_pair_bytes"]


def test_low_space_has_required_and_available_figures(tmp_path):
    result = install_preflight.plan("drum_kit", tmp_path / "root", host(free_bytes=1))
    assert result["preflight_result"] == "blocked"
    assert result["space"]["known_minimum_bytes"] > result["space"]["available_bytes"]
    assert "insufficient_known_space" in result["blockers"]


@pytest.mark.parametrize("facts,reason", [
    (host(os_version="4.17"), "os_too_old"),
    (host(glibc_version="2.27"), "glibc_too_old"),
    (host("darwin-arm64", os_version="13.7"), "os_too_old"),
    (host("win-x86_64", os_version="10.0.19044"), "os_too_old"),
    (host("win-x86_64", os_version="10.0.19045", vcpp_runtime_present=False), "vcpp_runtime_missing"),
    (host("linux-arm64"), "unsupported_platform"),
])
def test_platform_floors(tmp_path, facts, reason):
    result = install_preflight.plan("drum_kit", tmp_path / "root", facts)
    assert reason in result["blockers"]
    assert result["preflight_result"] == "blocked"


@pytest.mark.parametrize("facts", [
    host(os_version="4.18", glibc_version="2.28"),
    host("darwin-arm64", os_version="14.0"),
    host("win-x86_64", os_version="10.0.19045"),
    host("win-x86_64", os_version="10.0.22000"),
])
def test_exact_platform_floors_and_newer_windows_pass(tmp_path, facts):
    result = install_preflight.plan("drum_kit", tmp_path / "root", facts)
    assert not result["blockers"]
    assert result["platform_check"]["required"] is not None


def test_windows_path_budget_blocks_known_overlong_path(tmp_path):
    root = tmp_path / ("x" * 150)
    result = install_preflight.plan("drum_kit", root,
        host("win-x86_64", os_version="10.0.19045"))
    assert "known_path_too_long" in result["blockers"]
    assert max(p["length"] for p in result["path_budget"]["known_paths"]) > result["path_budget"]["maximum_length"]


def test_windows_known_path_boundary_is_inclusive(tmp_path):
    facts = host("win-x86_64", os_version="10.0.19045")
    exact = None
    for length in range(1, 220):
        root = tmp_path / ("x" * length)
        report = install_preflight.plan("drum_kit", root, facts)
        if max(entry["length"] for entry in report["path_budget"]["known_paths"]) == 259:
            exact = root
            assert "known_path_too_long" not in report["blockers"]
            break
    assert exact is not None
    over = install_preflight.plan("drum_kit", tmp_path / (exact.name + "x"), facts)
    assert "known_path_too_long" in over["blockers"]


def test_fingerprint_binds_actions_and_rejects_changed_plan(tmp_path):
    original = install_preflight.plan("drum_kit", tmp_path / "root", host())
    with pytest.raises(install_preflight.PreflightError, match="preflight_incomplete"):
        install_preflight.require_current_plan(
            original["fingerprint"], "drum_kit", tmp_path / "root", host())
    assert install_preflight.plan("drum_kit", tmp_path / "root",
                                   host(free_bytes=21 * 1024**3))["fingerprint"] == original["fingerprint"]
    with pytest.raises(install_preflight.PreflightError, match="plan_changed"):
        install_preflight.require_current_plan(original["fingerprint"], "drum_kit",
                                               tmp_path / "other", host())
    with pytest.raises(install_preflight.PreflightError, match="preflight_blocked"):
        install_preflight.require_current_plan(
            original["fingerprint"], "drum_kit", tmp_path / "root", host(free_bytes=1))
    other_platform = install_preflight.plan("drum_kit", tmp_path / "root",
        host("darwin-arm64", os_version="14.0"))
    assert other_platform["fingerprint"] != original["fingerprint"]
    windows = install_preflight.plan("drum_kit", tmp_path / "root",
        host("win-x86_64", os_version="10.0.19045"))
    assert windows["space"]["estimate_items"] == other_platform["space"]["estimate_items"]
    assert windows["fingerprint"] != other_platform["fingerprint"]


def test_link_inside_root_is_a_named_refusal_and_no_files_are_written(tmp_path):
    root = tmp_path / "root"
    root.mkdir()
    target = tmp_path / "target"
    target.mkdir()
    try:
        (root / "state").symlink_to(target, target_is_directory=True)
    except (OSError, NotImplementedError):
        pytest.skip("directory symlinks unavailable")
    result = install_preflight.plan("drum_kit", root, host())
    assert "path_ineligible" in result["blockers"]
    assert sorted(p.name for p in root.iterdir()) == ["state"]


def test_relative_and_dangling_root_paths_are_refused(tmp_path):
    with pytest.raises(install_preflight.PreflightError, match="path_ineligible"):
        install_preflight.plan("drum_kit", "relative/root", host())
    dangling = tmp_path / "dangling"
    try:
        dangling.symlink_to(tmp_path / "missing", target_is_directory=True)
    except (OSError, NotImplementedError):
        pytest.skip("directory symlinks unavailable")
    result = install_preflight.plan("drum_kit", dangling, host())
    assert "path_ineligible" in result["blockers"]


def test_fingerprint_includes_pinned_asset_details(tmp_path):
    result = install_preflight.plan("drum_kit", tmp_path / "root", host())
    actions = result["actions"]
    changed = {**actions, "components": [dict(c) for c in actions["components"]]}
    changed["components"][-2] = dict(changed["components"][-2])
    changed["components"][-2]["assets"] = [dict(p) for p in changed["components"][-2]["assets"]]
    changed["components"][-2]["assets"][0]["sha256"] = "0" * 64
    assert install_preflight.fingerprint(changed) != result["fingerprint"]
