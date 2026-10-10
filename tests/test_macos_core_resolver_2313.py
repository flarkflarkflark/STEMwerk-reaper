"""Behavioral regression tests for the macOS managed stemwerk-core wheel route."""

from __future__ import annotations

import os
import shlex
import subprocess
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "scripts" / "reaper" / "STEMwerk_Bootstrap_macOS.sh"
REAPER_DIR = ROOT / "scripts" / "reaper"
SH = "/bin/sh"


def _function_body(text: str, name: str) -> str:
    start = text.index(f"\n{name}() {{\n") + 1
    lines = text[start:].splitlines(keepends=True)
    body: list[str] = []
    for line in lines:
        body.append(line)
        if line in {"}\n", "}"}:
            return "".join(body)
    raise AssertionError(f"could not find end of shell function {name}")


RESOLVER_FUNCTIONS = (
    "log",
    "bundled_stemwerk_core_wheel",
    "managed_stemwerk_core_wheel",
    "is_core_source_bundle",
    "resolve_core_target",
)


def _valid_source(path: Path) -> Path:
    (path / "src" / "stemwerk_core").mkdir(parents=True)
    (path / "pyproject.toml").write_text("[build-system]\n", encoding="utf-8")
    for name in ("__init__.py", "separator.py"):
        (path / "src" / "stemwerk_core" / name).write_text("", encoding="utf-8")
    return path


def _resolver_result(
    tmp_path: Path,
    *,
    arch: str,
    bundled_wheels: Path,
    managed_wheels: Path,
    default_source: Path,
    core_path: Path | None = None,
    core_bundle_dir: Path | None = None,
) -> tuple[dict[str, str], str]:
    text = BOOTSTRAP.read_text(encoding="utf-8")
    functions = "\n".join(_function_body(text, name) for name in RESOLVER_FUNCTIONS)
    log_file = tmp_path / "resolver.log"
    harness = tmp_path / "resolver.sh"

    override_lines = ["unset STEMWERK_CORE_PATH STEMWERK_CORE_BUNDLE_DIR"]
    if core_path is not None:
        override_lines.append(f"STEMWERK_CORE_PATH={shlex.quote(str(core_path))}")
    if core_bundle_dir is not None:
        override_lines.append(f"STEMWERK_CORE_BUNDLE_DIR={shlex.quote(str(core_bundle_dir))}")

    harness.write_text(
        "\n".join(
            (
                "#!/bin/sh",
                "set -u",
                f"LOG_FILE={shlex.quote(str(log_file))}",
                f"SCRIPT_DIR={shlex.quote(str(REAPER_DIR))}",
                f"MAC_ARCH={shlex.quote(arch)}",
                f"BUNDLED_WHEELS_DIR={shlex.quote(str(bundled_wheels))}",
                f"MANAGED_WHEELS_DIR={shlex.quote(str(managed_wheels))}",
                f"BUNDLED_CORE_DIR={shlex.quote(str(default_source))}",
                *override_lines,
                functions,
                "resolve_core_target",
                "resolver_rc=$?",
                "printf 'RC=%s\\n' \"${resolver_rc}\"",
                "printf 'TARGET=%s\\n' \"${CORE_TARGET}\"",
                "printf 'DESC=%s\\n' \"${CORE_TARGET_DESC}\"",
                "printf 'EXTRAS=%s\\n' \"${CORE_SUPPORTS_EXTRAS}\"",
                "",
            )
        ),
        encoding="utf-8",
    )
    harness.chmod(0o755)
    completed = subprocess.run([SH, str(harness)], text=True, capture_output=True, timeout=10)
    assert completed.returncode == 0, completed.stdout + completed.stderr
    parsed = dict(line.split("=", 1) for line in completed.stdout.splitlines() if "=" in line)
    log = log_file.read_text(encoding="utf-8") if log_file.exists() else ""
    return parsed, log


@pytest.mark.parametrize("arch", ["x86_64", "arm64"])
def test_online_resolver_selects_per_arch_managed_core_wheel(tmp_path: Path, arch: str):
    bundled = tmp_path / "no-bundled-wheelhouse"
    managed = REAPER_DIR / "vendor" / "wheels" / f"darwin-{arch}-cp312"
    result, _ = _resolver_result(
        tmp_path,
        arch=arch,
        bundled_wheels=bundled,
        managed_wheels=managed,
        default_source=REAPER_DIR / "vendor" / "stemwerk-core",
    )

    expected = managed / "stemwerk_core-0.1.1-py3-none-any.whl"
    assert result == {
        "RC": "0",
        "TARGET": str(expected),
        "DESC": "managed wheel",
        "EXTRAS": "0",
    }


def test_bundled_wheel_precedes_managed_wheel(tmp_path: Path):
    bundled = tmp_path / "bundled"
    bundled.mkdir()
    bundled_wheel = bundled / "stemwerk_core-0.1.1-py3-none-any.whl"
    bundled_wheel.touch()
    managed = REAPER_DIR / "vendor" / "wheels" / "darwin-arm64-cp312"

    result, _ = _resolver_result(
        tmp_path,
        arch="arm64",
        bundled_wheels=bundled,
        managed_wheels=managed,
        default_source=REAPER_DIR / "vendor" / "stemwerk-core",
    )

    assert result["RC"] == "0"
    assert result["TARGET"] == str(bundled_wheel)
    assert result["DESC"] == "bundled wheel"
    assert result["EXTRAS"] == "0"


def test_explicit_core_path_precedes_managed_wheel(tmp_path: Path):
    explicit = _valid_source(tmp_path / "explicit-path")
    managed = REAPER_DIR / "vendor" / "wheels" / "darwin-arm64-cp312"
    result, _ = _resolver_result(
        tmp_path,
        arch="arm64",
        bundled_wheels=tmp_path / "no-bundled-wheelhouse",
        managed_wheels=managed,
        default_source=REAPER_DIR / "vendor" / "stemwerk-core",
        core_path=explicit,
    )

    assert result["RC"] == "0"
    assert result["TARGET"] == str(explicit)
    assert result["DESC"] == "STEMWERK_CORE_PATH source"
    assert result["EXTRAS"] == "1"


def test_explicit_core_bundle_dir_precedes_managed_wheel(tmp_path: Path):
    explicit = _valid_source(tmp_path / "explicit-bundle")
    managed = REAPER_DIR / "vendor" / "wheels" / "darwin-arm64-cp312"
    result, _ = _resolver_result(
        tmp_path,
        arch="arm64",
        bundled_wheels=tmp_path / "no-bundled-wheelhouse",
        managed_wheels=managed,
        default_source=REAPER_DIR / "vendor" / "stemwerk-core",
        core_bundle_dir=explicit,
    )

    assert result["RC"] == "0"
    assert result["TARGET"] == str(explicit)
    assert result["DESC"] == "STEMWERK_CORE_BUNDLE_DIR source"
    assert result["EXTRAS"] == "1"


def test_default_vendored_source_is_final_fallback(tmp_path: Path):
    default_source = _valid_source(tmp_path / "default-source")
    managed = tmp_path / "managed-without-core"
    managed.mkdir()
    result, _ = _resolver_result(
        tmp_path,
        arch="x86_64",
        bundled_wheels=tmp_path / "no-bundled-wheelhouse",
        managed_wheels=managed,
        default_source=default_source,
    )

    assert result["RC"] == "0"
    assert result["TARGET"] == str(default_source)
    assert result["DESC"] == "vendored source"
    assert result["EXTRAS"] == "1"


def test_resolver_fails_when_all_targets_are_missing(tmp_path: Path):
    managed = tmp_path / "managed-without-core"
    managed.mkdir()
    result, _ = _resolver_result(
        tmp_path,
        arch="x86_64",
        bundled_wheels=tmp_path / "no-bundled-wheelhouse",
        managed_wheels=managed,
        default_source=tmp_path / "missing-source",
    )

    assert result == {"RC": "1", "TARGET": "", "DESC": "", "EXTRAS": "0"}


def test_ambiguous_managed_core_wheels_fail_closed(tmp_path: Path):
    managed = tmp_path / "ambiguous-managed"
    managed.mkdir()
    (managed / "stemwerk_core-0.1.1-py3-none-any.whl").touch()
    (managed / "stemwerk_core-9.9.9-py3-none-any.whl").touch()
    result, log = _resolver_result(
        tmp_path,
        arch="arm64",
        bundled_wheels=tmp_path / "no-bundled-wheelhouse",
        managed_wheels=managed,
        default_source=REAPER_DIR / "vendor" / "stemwerk-core",
    )

    assert result == {"RC": "1", "TARGET": "", "DESC": "", "EXTRAS": "0"}
    assert "Managed stemwerk-core wheel selection is ambiguous" in log


def test_fresh_venv_without_build_backend_installs_selected_managed_wheel(tmp_path: Path):
    if sys.version_info[:2] != (3, 12):
        pytest.skip("the release contract is specifically managed Python 3.12")

    managed = REAPER_DIR / "vendor" / "wheels" / "darwin-arm64-cp312"
    resolver_dir = tmp_path / "resolver"
    resolver_dir.mkdir()
    result, _ = _resolver_result(
        resolver_dir,
        arch="arm64",
        bundled_wheels=tmp_path / "no-bundled-wheelhouse",
        managed_wheels=managed,
        default_source=REAPER_DIR / "vendor" / "stemwerk-core",
    )
    assert result["DESC"] == "managed wheel"

    venv = tmp_path / "fresh-venv"
    subprocess.run([sys.executable, "-m", "venv", str(venv)], check=True, timeout=60)
    python = venv / "bin" / "python"
    contract = subprocess.run(
        [
            str(python),
            "-c",
            (
                "import importlib.util; "
                "assert importlib.util.find_spec('pip') is not None; "
                "assert importlib.util.find_spec('setuptools') is None; "
                "assert importlib.util.find_spec('wheel') is None"
            ),
        ],
        text=True,
        capture_output=True,
        timeout=30,
    )
    assert contract.returncode == 0, contract.stdout + contract.stderr

    install = subprocess.run(
        [str(python), "-m", "pip", "install", "--no-index", "--no-deps", result["TARGET"]],
        text=True,
        capture_output=True,
        timeout=60,
    )
    assert install.returncode == 0, install.stdout + install.stderr
    assert "BackendUnavailable" not in install.stdout + install.stderr
    assert "setuptools.build_meta" not in install.stdout + install.stderr

    # stemwerk_core imports yaml at module load time. Runtime dependency repair
    # occurs later in the real bootstrap, so provide only a no-op import stub;
    # do not add packaging/build tools to this deliberately pristine venv.
    import_stubs = tmp_path / "import-stubs"
    import_stubs.mkdir()
    (import_stubs / "yaml.py").write_text("", encoding="utf-8")
    env = dict(os.environ)
    env["PYTHONPATH"] = str(import_stubs)
    imported = subprocess.run(
        [
            str(python),
            "-c",
            (
                "import importlib.util; "
                "from importlib.metadata import version; "
                "assert importlib.util.find_spec('setuptools') is None; "
                "assert importlib.util.find_spec('wheel') is None; "
                "import stemwerk_core; "
                "assert version('stemwerk-core') == '0.1.1'; "
                "assert stemwerk_core.__file__"
            ),
        ],
        env=env,
        text=True,
        capture_output=True,
        timeout=30,
    )
    assert imported.returncode == 0, imported.stdout + imported.stderr
