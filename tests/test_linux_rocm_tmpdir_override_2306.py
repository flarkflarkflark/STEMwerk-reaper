from __future__ import annotations

import hashlib
import os
from pathlib import Path
import subprocess
import textwrap
from types import SimpleNamespace


ROOT = Path(__file__).resolve().parents[1]
LINUX_BOOTSTRAP = ROOT / "scripts/reaper/STEMwerk_Bootstrap_Linux.sh"


def _bootstrap_text() -> str:
    return LINUX_BOOTSTRAP.read_text(encoding="utf-8")


def _preflight_functions(script: str) -> str:
    start = script.index("free_kb_for_path() {")
    end = script.index("verify_drumsep_rocm_runtime() {", start)
    return script[start:end]


def _run_preflight_harness(
    tmp_path: Path,
    *,
    explicit: str | None,
) -> SimpleNamespace:
    script = _bootstrap_text()
    functions = _preflight_functions(script).replace(
        '"/mnt/PRODUCTION/TMP/stemwerk-rocm-tmp"',
        '"${TEST_DEFAULT_TMPDIR}"',
    )
    runtime = tmp_path / "runtime"
    runtime.mkdir()
    default_tmp = tmp_path / "automatic-default"
    env = os.environ.copy()
    env.update(
        {
            "RUNTIME_BASE": str(runtime),
            "SCRIPT_DIR": str(tmp_path / "packaged-source"),
            "XDG_DATA_HOME": str(tmp_path / "xdg"),
            "TEST_DEFAULT_TMPDIR": str(default_tmp),
            "DRUMSEP_ROCM_MIN_FREE_GB": "0",
        }
    )
    if explicit is None:
        env.pop("DRUMSEP_ROCM_TMPDIR", None)
    else:
        env["DRUMSEP_ROCM_TMPDIR"] = explicit

    harness = textwrap.dedent(
        f"""
        set -u
        log_step() {{ printf 'LOG:%s\\n' "$*"; }}
        model_cache_dir() {{ printf '%s/STEMwerk/models\\n' "${{XDG_DATA_HOME}}"; }}
        {functions}
        if drumsep_rocm_disk_preflight; then
          printf 'RESULT=ok\\n'
          printf 'SOURCE=%s\\n' "${{DRUMSEP_ROCM_TMPDIR_SOURCE:-}}"
          printf 'RESOLVED=%s\\n' "${{DRUMSEP_ROCM_TMPDIR:-}}"
          exit 0
        fi
        printf 'RESULT=fail\\n'
        printf 'SOURCE=%s\\n' "${{DRUMSEP_ROCM_TMPDIR_SOURCE:-}}"
        printf 'DETAIL=%s\\n' "${{DRUMSEP_ROCM_PREFLIGHT_DETAIL:-}}"
        exit 7
        """
    )
    process = subprocess.Popen(
        ["sh", "-c", harness],
        cwd=tmp_path,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout, stderr = process.communicate()
    return SimpleNamespace(returncode=process.returncode, stdout=stdout, stderr=stderr)


def test_explicit_absolute_override_is_preserved_and_normalized(tmp_path: Path) -> None:
    explicit = tmp_path / "isolated" / "nested" / ".." / "rocm-tmp"
    result = _run_preflight_harness(tmp_path, explicit=str(explicit))

    assert result.returncode == 0, result.stderr + result.stdout
    assert "SOURCE=explicit" in result.stdout
    assert f"RESOLVED={tmp_path / 'isolated' / 'rocm-tmp'}" in result.stdout
    assert "DRUMSEP_ROCM_TMPDIR_SOURCE=explicit" in result.stdout


def test_valid_explicit_override_does_not_call_or_touch_default_resolver_path(
    tmp_path: Path,
) -> None:
    explicit = tmp_path / "isolated-rocm-tmp"
    result = _run_preflight_harness(tmp_path, explicit=str(explicit))

    assert result.returncode == 0, result.stderr + result.stdout
    assert explicit.is_dir()
    assert not (tmp_path / "automatic-default").exists()


def test_unset_override_retains_existing_first_candidate_default(tmp_path: Path) -> None:
    result = _run_preflight_harness(tmp_path, explicit=None)

    assert result.returncode == 0, result.stderr + result.stdout
    assert "SOURCE=auto" in result.stdout
    assert f"RESOLVED={tmp_path / 'automatic-default'}" in result.stdout
    assert (tmp_path / "automatic-default").is_dir()


def test_empty_override_behaves_as_unset(tmp_path: Path) -> None:
    result = _run_preflight_harness(tmp_path, explicit="")

    assert result.returncode == 0, result.stderr + result.stdout
    assert "SOURCE=auto" in result.stdout
    assert f"RESOLVED={tmp_path / 'automatic-default'}" in result.stdout


def test_relative_explicit_override_fails_closed_without_default_fallback(
    tmp_path: Path,
) -> None:
    result = _run_preflight_harness(tmp_path, explicit="relative/rocm-tmp")

    assert result.returncode == 7
    assert "RESULT=fail" in result.stdout
    assert "SOURCE=explicit" in result.stdout
    assert "DETAIL=explicit_temp_dir_relative_path" in result.stdout
    assert not (tmp_path / "automatic-default").exists()
    assert not (tmp_path / "relative").exists()


def test_invalid_explicit_override_fails_closed_without_default_fallback(
    tmp_path: Path,
) -> None:
    blocking_file = tmp_path / "not-a-directory"
    blocking_file.write_text("block", encoding="utf-8")
    result = _run_preflight_harness(
        tmp_path,
        explicit=str(blocking_file / "rocm-tmp"),
    )

    assert result.returncode == 7
    assert "RESULT=fail" in result.stdout
    assert "SOURCE=explicit" in result.stdout
    assert "DETAIL=explicit_temp_dir_create_failed" in result.stdout
    assert not (tmp_path / "automatic-default").exists()


def test_root_explicit_override_fails_closed(tmp_path: Path) -> None:
    result = _run_preflight_harness(tmp_path, explicit="/")

    assert result.returncode == 7
    assert "DETAIL=explicit_temp_dir_root_path" in result.stdout
    assert not (tmp_path / "automatic-default").exists()


def test_rocm_install_exports_only_the_preflight_selected_tmpdir() -> None:
    script = _bootstrap_text()
    preflight_call = script.index("if ! drumsep_rocm_disk_preflight; then")
    export = script.index('export TMPDIR="${DRUMSEP_ROCM_TMPDIR}"', preflight_call)
    next_function = script.index("install_drumsep_runtime() {", export)

    assert "resolve_drumsep_rocm_tmpdir" not in script[preflight_call:next_function]
    assert script.count('export TMPDIR="${DRUMSEP_ROCM_TMPDIR}"') == 1


def test_runtime_xdg_and_rocm_dependency_contracts_remain_unchanged() -> None:
    script = _bootstrap_text()

    assert 'printf "%s/STEMwerk/models\\n" "${XDG_DATA_HOME}"' in script
    assert 'mkdir -p "${RUNTIME_BASE}/state" "${RUNTIME_BASE}/logs"' in script
    assert (
        'pip_install_with_scope drumsep "${_py}" --no-cache-dir --index-url '
        '"${DRUMSEP_ACTIVE_ROCM_TORCH_INDEX_URL}"'
    ) in script
    assert 'DRUMSEP_ROCM7_GFX1201_TORCH_VERSION="2.10.0+rocm7.0"' in script


def test_macos_and_windows_bootstraps_remain_release_baseline_bytes() -> None:
    expected = {
        # 2.3.1.0: macOS online Repair (managed wheelhouse, deep preflight,
        # arch guard, per-arch onnxruntime pins) — hash updated from 2.3.0.7.
        "scripts/reaper/STEMwerk_Bootstrap_macOS.sh": (
            "bb08afa3326df4f8948078d2b9eeb10eb5982825db06ee158090400924774ef3"
        ),
        "scripts/reaper/STEMwerk_Bootstrap_Windows.ps1": (
            "facfd0090c87d9ef0ebadbe6d9d79c68e27307b39695cd7c75e75d63cf436679"
        ),
    }
    for relative, wanted in expected.items():
        actual = hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()
        assert actual == wanted
