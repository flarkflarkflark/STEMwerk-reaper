from __future__ import annotations

import os
from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "scripts/reaper/STEMwerk_Bootstrap_Linux.sh"
STATUS_VALUES = {
    "not_required",
    "removed",
    "partial_unexpected",
    "blocked_anomaly",
    "failed",
}


def _venv(runtime_base: Path) -> Path:
    venv = runtime_base / ".venv"
    (venv / "bin").mkdir(parents=True)
    (venv / "bin/python").write_text("#!/bin/sh\n", encoding="utf-8")
    (venv / "bin/python").chmod(0o755)
    return venv


def _allowlist_parents(venv: Path) -> tuple[Path, Path]:
    core = venv / "lib/python3.12/site-packages/librosa/core/__pycache__"
    util = venv / "lib/python3.12/site-packages/librosa/util/__pycache__"
    core.mkdir(parents=True, exist_ok=True)
    util.mkdir(parents=True, exist_ok=True)
    return core, util


def _runner(venv: Path) -> Path:
    script = BOOTSTRAP.read_text(encoding="utf-8")
    start = script.index("cleanup_legacy_numba_caches() {")
    end = script.index("# END NUMBA LEGACY CACHE CLEANUP POLICY")
    runner = venv.parent / "numba-cleanup-runner.sh"
    runner.parent.mkdir(parents=True, exist_ok=True)
    runner.write_text(
        "#!/bin/sh\nset -u\n"
        + script[start:end]
        + '\ncleanup_legacy_numba_caches "$1"\n',
        encoding="utf-8",
    )
    runner.chmod(0o755)
    return runner


def _run(venv: Path, *, env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    run_env = os.environ.copy()
    if env:
        run_env.update(env)
    return subprocess.run(
        ["/bin/sh", str(_runner(venv)), str(venv)],
        cwd=ROOT,
        env=run_env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )


def _markers(result: subprocess.CompletedProcess[str]) -> dict[str, str]:
    markers: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if line.startswith("NUMBA_LEGACY_CACHE_") and "=" in line:
            key, value = line.split("=", 1)
            markers[key] = value
    return markers


def _assert_common(markers: dict[str, str]) -> None:
    assert markers["NUMBA_LEGACY_CACHE_RUNTIME_CACHE_TOUCHED"] == "no"
    assert markers["NUMBA_LEGACY_CACHE_CLEANUP_STATUS"] in STATUS_VALUES


def test_no_caches_is_not_required(tmp_path: Path) -> None:
    venv = _venv(tmp_path / "runtime")
    _allowlist_parents(venv)

    result = _run(venv)
    markers = _markers(result)

    assert result.returncode == 0, result.stdout
    assert markers["NUMBA_LEGACY_CACHE_DETECTED"] == "0"
    assert markers["NUMBA_LEGACY_CACHE_REMOVED"] == "0"
    assert markers["NUMBA_LEGACY_CACHE_UNEXPECTED_PATHS"] == "0"
    assert markers["NUMBA_LEGACY_CACHE_ANOMALIES"] == "0"
    assert markers["NUMBA_LEGACY_CACHE_POSTCHECK_REMAINING"] == "0"
    assert markers["NUMBA_LEGACY_CACHE_CLEANUP_STATUS"] == "not_required"
    _assert_common(markers)


def test_one_core_nbc_is_removed(tmp_path: Path) -> None:
    venv = _venv(tmp_path / "runtime")
    core, _ = _allowlist_parents(venv)
    cache = core / "audio.fn-1.py312.1.nbc"
    cache.write_bytes(b"cache")

    result = _run(venv)
    markers = _markers(result)

    assert result.returncode == 0, result.stdout
    assert not cache.exists()
    assert markers["NUMBA_LEGACY_CACHE_DETECTED"] == "1"
    assert markers["NUMBA_LEGACY_CACHE_REMOVED"] == "1"
    assert markers["NUMBA_LEGACY_CACHE_NOT_REMOVED"] == "0"
    assert markers["NUMBA_LEGACY_CACHE_POSTCHECK_REMAINING"] == "0"
    assert markers["NUMBA_LEGACY_CACHE_CLEANUP_STATUS"] == "removed"


def test_arbitrary_valid_caches_across_both_parents_are_removed(tmp_path: Path) -> None:
    venv = _venv(tmp_path / "runtime")
    core, util = _allowlist_parents(venv)
    caches = [
        core / "a.py312.1.nbc",
        core / "a.py312.nbi",
        util / "b.py312.1.nbc",
        util / "b.py312.nbi",
        util / "c.py312.7.nbc",
    ]
    for index, cache in enumerate(caches):
        cache.write_bytes(f"cache-{index}".encode())

    result = _run(venv)
    markers = _markers(result)

    assert result.returncode == 0, result.stdout
    assert all(not cache.exists() for cache in caches)
    assert int(markers["NUMBA_LEGACY_CACHE_DETECTED"]) == len(caches)
    assert int(markers["NUMBA_LEGACY_CACHE_REMOVED"]) == len(caches)
    assert markers["NUMBA_LEGACY_CACHE_CLEANUP_STATUS"] == "removed"


def test_allowlist_caches_removed_but_unexpected_caches_preserved(tmp_path: Path) -> None:
    venv = _venv(tmp_path / "runtime")
    core, _ = _allowlist_parents(venv)
    allowed = core / "allowed.py312.1.nbc"
    unexpected = venv / "lib/python3.12/site-packages/other/__pycache__/other.py312.nbi"
    unexpected.parent.mkdir(parents=True)
    allowed.write_bytes(b"allowed")
    unexpected.write_bytes(b"unexpected")

    result = _run(venv)
    markers = _markers(result)

    assert result.returncode == 0, result.stdout
    assert not allowed.exists()
    assert unexpected.read_bytes() == b"unexpected"
    assert markers["NUMBA_LEGACY_CACHE_UNEXPECTED_PATHS"] == "1"
    assert markers["NUMBA_LEGACY_CACHE_CLEANUP_STATUS"] == "partial_unexpected"


def test_only_unexpected_caches_are_preserved(tmp_path: Path) -> None:
    venv = _venv(tmp_path / "runtime")
    unexpected = venv / "lib/python3.12/site-packages/other/cache.nbc"
    unexpected.parent.mkdir(parents=True)
    unexpected.write_bytes(b"unexpected")

    result = _run(venv)
    markers = _markers(result)

    assert result.returncode == 0, result.stdout
    assert unexpected.exists()
    assert markers["NUMBA_LEGACY_CACHE_DETECTED"] == "0"
    assert markers["NUMBA_LEGACY_CACHE_REMOVED"] == "0"
    assert markers["NUMBA_LEGACY_CACHE_UNEXPECTED_PATHS"] == "1"
    assert markers["NUMBA_LEGACY_CACHE_CLEANUP_STATUS"] == "partial_unexpected"


def test_symlink_in_allowlist_blocks_all_removal(tmp_path: Path) -> None:
    venv = _venv(tmp_path / "runtime")
    core, _ = _allowlist_parents(venv)
    valid = core / "valid.nbc"
    valid.write_bytes(b"valid")
    (core / "linked.nbi").symlink_to(tmp_path / "outside")

    result = _run(venv)
    markers = _markers(result)

    assert result.returncode != 0
    assert valid.exists()
    assert markers["NUMBA_LEGACY_CACHE_REMOVED"] == "0"
    assert int(markers["NUMBA_LEGACY_CACHE_ANOMALIES"]) > 0
    assert markers["NUMBA_LEGACY_CACHE_CLEANUP_STATUS"] == "blocked_anomaly"


def test_parent_realpath_escape_blocks_all_removal(tmp_path: Path) -> None:
    venv = _venv(tmp_path / "runtime")
    site = venv / "lib/python3.12/site-packages/librosa"
    outside = tmp_path / "outside/core/__pycache__"
    outside.mkdir(parents=True)
    (outside / "escaped.nbc").write_bytes(b"escape")
    site.mkdir(parents=True)
    (site / "core").symlink_to(outside.parent)

    result = _run(venv)
    markers = _markers(result)

    assert result.returncode != 0
    assert (outside / "escaped.nbc").exists()
    assert markers["NUMBA_LEGACY_CACHE_REMOVED"] == "0"
    assert markers["NUMBA_LEGACY_CACHE_CLEANUP_STATUS"] == "blocked_anomaly"


@pytest.mark.parametrize("suffix", ["nbc", "nbi"])
def test_cache_named_directory_blocks_all_removal(tmp_path: Path, suffix: str) -> None:
    venv = _venv(tmp_path / "runtime")
    core, _ = _allowlist_parents(venv)
    valid = core / "valid.nbc"
    valid.write_bytes(b"valid")
    (core / f"directory.{suffix}").mkdir()

    result = _run(venv)
    markers = _markers(result)

    assert result.returncode != 0
    assert valid.exists()
    assert markers["NUMBA_LEGACY_CACHE_REMOVED"] == "0"
    assert markers["NUMBA_LEGACY_CACHE_CLEANUP_STATUS"] == "blocked_anomaly"


def test_cache_like_unexpected_extension_blocks_all_removal(tmp_path: Path) -> None:
    venv = _venv(tmp_path / "runtime")
    core, _ = _allowlist_parents(venv)
    valid = core / "valid.nbc"
    invalid = core / "unfinished.nbc.tmp"
    valid.write_bytes(b"valid")
    invalid.write_bytes(b"invalid")

    result = _run(venv)
    markers = _markers(result)

    assert result.returncode != 0
    assert valid.exists() and invalid.exists()
    assert markers["NUMBA_LEGACY_CACHE_REMOVED"] == "0"
    assert markers["NUMBA_LEGACY_CACHE_CLEANUP_STATUS"] == "blocked_anomaly"


def _fake_rm(tmp_path: Path, body: str) -> dict[str, str]:
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    script = fake_bin / "rm"
    script.write_text("#!/bin/sh\n" + body, encoding="utf-8")
    script.chmod(0o755)
    return {"PATH": f"{fake_bin}:{os.environ['PATH']}"}


def test_removal_failure_before_first_delete_is_hard_failure(tmp_path: Path) -> None:
    venv = _venv(tmp_path / "runtime")
    core, _ = _allowlist_parents(venv)
    cache = core / "cache.nbc"
    cache.write_bytes(b"cache")
    env = _fake_rm(tmp_path, "exit 1\n")

    result = _run(venv, env=env)
    markers = _markers(result)

    assert result.returncode != 0
    assert cache.exists()
    assert markers["NUMBA_LEGACY_CACHE_REMOVED"] == "0"
    assert markers["NUMBA_LEGACY_CACHE_CLEANUP_STATUS"] == "failed"


def test_partial_removal_reports_actual_removed_count(tmp_path: Path) -> None:
    venv = _venv(tmp_path / "runtime")
    core, _ = _allowlist_parents(venv)
    first, second = core / "a.nbc", core / "b.nbi"
    first.write_bytes(b"first")
    second.write_bytes(b"second")
    counter = tmp_path / "rm-count"
    env = _fake_rm(
        tmp_path,
        f'count=$(cat "{counter}" 2>/dev/null || echo 0)\n'
        f'count=$((count + 1)); echo "$count" > "{counter}"\n'
        'if [ "$count" -gt 1 ]; then exit 1; fi\n'
        'exec /bin/rm "$@"\n',
    )

    result = _run(venv, env=env)
    markers = _markers(result)

    assert result.returncode != 0
    assert sum(path.exists() for path in (first, second)) == 1
    assert markers["NUMBA_LEGACY_CACHE_REMOVED"] == "1"
    assert markers["NUMBA_LEGACY_CACHE_NOT_REMOVED"] == "1"
    assert markers["NUMBA_LEGACY_CACHE_POSTCHECK_REMAINING"] == "1"
    assert markers["NUMBA_LEGACY_CACHE_CLEANUP_STATUS"] == "failed"


def test_postcheck_failure_is_hard_failure(tmp_path: Path) -> None:
    venv = _venv(tmp_path / "runtime")
    core, _ = _allowlist_parents(venv)
    cache = core / "cache.nbc"
    cache.write_bytes(b"cache")
    env = _fake_rm(tmp_path, "exit 0\n")

    result = _run(venv, env=env)
    markers = _markers(result)

    assert result.returncode != 0
    assert cache.exists()
    assert markers["NUMBA_LEGACY_CACHE_REMOVED"] == "0"
    assert markers["NUMBA_LEGACY_CACHE_POSTCHECK_REMAINING"] == "1"
    assert markers["NUMBA_LEGACY_CACHE_CLEANUP_STATUS"] == "failed"


def test_controlled_runtime_cache_is_untouched_and_not_unexpected(tmp_path: Path) -> None:
    runtime = tmp_path / "runtime"
    venv = _venv(runtime)
    runtime_cache = runtime / "cache/numba/compiled"
    runtime_cache.mkdir(parents=True)
    cache = runtime_cache / "runtime.nbc"
    cache.write_bytes(b"runtime-cache")

    result = _run(venv)
    markers = _markers(result)

    assert result.returncode == 0, result.stdout
    assert cache.read_bytes() == b"runtime-cache"
    assert markers["NUMBA_LEGACY_CACHE_UNEXPECTED_PATHS"] == "0"
    assert markers["NUMBA_LEGACY_CACHE_RUNTIME_CACHE_TOUCHED"] == "no"


def test_missing_active_venv_is_safe_noop_and_not_created(tmp_path: Path) -> None:
    venv = tmp_path / "runtime/.venv"

    result = _run(venv)
    markers = _markers(result)

    assert result.returncode == 0, result.stdout
    assert not venv.exists()
    assert markers["NUMBA_LEGACY_CACHE_CLEANUP_STATUS"] == "not_required"


def test_sibling_venv_is_untouched(tmp_path: Path) -> None:
    runtime = tmp_path / "runtime"
    venv = _venv(runtime)
    sibling = runtime / ".venv-drumsep-rocm/lib/python3.12/site-packages/librosa/core/__pycache__"
    sibling.mkdir(parents=True)
    cache = sibling / "sibling.nbc"
    cache.write_bytes(b"sibling")

    result = _run(venv)

    assert result.returncode == 0, result.stdout
    assert cache.read_bytes() == b"sibling"


def test_non_numba_package_files_are_untouched(tmp_path: Path) -> None:
    venv = _venv(tmp_path / "runtime")
    core, _ = _allowlist_parents(venv)
    dist_info = venv / "lib/python3.12/site-packages/librosa-1.0.dist-info/METADATA"
    dist_info.parent.mkdir(parents=True)
    files = {
        core / "module.pyc": b"pyc",
        core.parent / "module.py": b"source",
        dist_info: b"metadata",
    }
    for path, content in files.items():
        path.write_bytes(content)

    result = _run(venv)

    assert result.returncode == 0, result.stdout
    assert all(path.read_bytes() == content for path, content in files.items())


def test_status_vocabulary_is_exact() -> None:
    helper = BOOTSTRAP.read_text(encoding="utf-8")

    assert "NUMBA_LEGACY_CACHE_CLEANUP_STATUS" in helper
    for value in STATUS_VALUES:
        assert value in helper
    assert "blocked_manifest_mismatch" not in helper


def test_product_policy_contains_no_manifest_hash_or_fixed_count() -> None:
    product = BOOTSTRAP.read_text(encoding="utf-8")

    assert "numba-legacy-cache-manifest" not in product
    assert "ALLOWLIST_EVIDENCE_FILE_COUNT" not in product
    assert "LOCAL_EVIDENCE_MANIFEST" not in product
    assert "sha256sum" not in product
    assert "/home/flark" not in product


def test_new_file_after_validation_is_not_silently_deleted(tmp_path: Path) -> None:
    venv = _venv(tmp_path / "runtime")
    core, _ = _allowlist_parents(venv)
    original = core / "original.nbc"
    appeared = core / "appeared.nbi"
    original.write_bytes(b"original")
    marker = tmp_path / "created"
    env = _fake_rm(
        tmp_path,
        f'if [ ! -e "{marker}" ]; then : > "{marker}"; printf new > "{appeared}"; fi\n'
        'exec /bin/rm "$@"\n',
    )

    result = _run(venv, env=env)
    markers = _markers(result)

    assert result.returncode != 0
    assert not original.exists()
    assert appeared.read_bytes() == b"new"
    assert markers["NUMBA_LEGACY_CACHE_REMOVED"] == "1"
    assert markers["NUMBA_LEGACY_CACHE_POSTCHECK_REMAINING"] == "1"
    assert markers["NUMBA_LEGACY_CACHE_CLEANUP_STATUS"] == "failed"


def test_bootstrap_runs_cleanup_only_for_repair_before_final_success() -> None:
    script = BOOTSTRAP.read_text(encoding="utf-8")
    call = 'if [ "${MODE}" = "repair" ] && [ -n "${VENV_PY}" ] && [ -x "${VENV_PY}" ]; then'

    assert call in script
    assert script.index(call) < script.index('log_step "Final verification"')
    assert script.index(call) < script.index('log "Bootstrap finished successfully"')
    assert "ready-to-go-verify" not in call


def test_ready_to_go_metadata_probe_exits_before_cleanup_path() -> None:
    script = BOOTSTRAP.read_text(encoding="utf-8")
    probe = 'if [ "${MODE}" = "ready-to-go-verify" ]; then'
    cleanup = 'if [ "${MODE}" = "repair" ] && [ -n "${VENV_PY}" ] && [ -x "${VENV_PY}" ]; then'

    assert script.index(probe) < script.index(cleanup)
    probe_body = script[script.index(probe) : script.index(cleanup)]
    assert "exit 0" in probe_body


def test_bootstrap_persists_cleanup_markers_in_state() -> None:
    script = BOOTSTRAP.read_text(encoding="utf-8")

    for marker in (
        "NUMBA_LEGACY_CACHE_DETECTED",
        "NUMBA_LEGACY_CACHE_REMOVED",
        "NUMBA_LEGACY_CACHE_UNEXPECTED_PATHS",
        "NUMBA_LEGACY_CACHE_ANOMALIES",
        "NUMBA_LEGACY_CACHE_POSTCHECK_REMAINING",
        "NUMBA_LEGACY_CACHE_NOT_REMOVED",
        "NUMBA_LEGACY_CACHE_RUNTIME_CACHE_TOUCHED",
        "NUMBA_LEGACY_CACHE_CLEANUP_STATUS",
    ):
        assert f'echo "{marker}=${{{marker}}}"' in script
