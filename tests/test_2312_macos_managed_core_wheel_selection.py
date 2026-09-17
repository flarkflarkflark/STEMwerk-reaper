"""Regression tests for the macOS "fresh ReaPack install falls back to
bundled stemwerk-core SOURCE instead of the shipped managed wheel" bug.

Real-world symptom (Intel Mac, fresh ReaPack install, no bundled
Apple-Silicon payload):

    bootstrap chooses vendor/stemwerk-core (source) over the shipped
    scripts/reaper/vendor/wheels/darwin-x86_64-cp312/stemwerk_core-0.1.1-py3-none-any.whl
    -> install_stemwerk_core_target() runs pip with --no-build-isolation
    -> fresh venv has no guaranteed setuptools.build_meta
    -> pip._vendor.pyproject_hooks._impl.BackendUnavailable
    -> STATUS=deps_failed REASON=stemwerk_core_install_failed

Root cause: resolve_core_target() in STEMwerk_Bootstrap_macOS.sh never
looked at MANAGED_WHEELS_DIR (the small ReaPack-shipped wheelhouse) at
all, so a normal ReaPack install -- which has no bundled Apple-Silicon
payload and no STEMWERK_CORE_PATH override -- always fell through to the
bundled *source* tree.

Investigation performed here with the real shell functions extracted
verbatim from STEMwerk_Bootstrap_macOS.sh and executed under a real POSIX
`sh` (never a re-implementation), following the same pattern as
test_2310_macos_offline_first_run_bootstrap.py.
"""

from __future__ import annotations

import re
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "scripts" / "reaper" / "STEMwerk_Bootstrap_macOS.sh"

SH = "/bin/sh"

_HEREDOC_START_RE = re.compile(r"<<-?\s*'?\"?([A-Za-z_][A-Za-z0-9_]*)'?\"?")


def _bootstrap_text() -> str:
    return BOOTSTRAP.read_text(encoding="utf-8")


def _function_body(text: str, name: str) -> str:
    """Extract a `name() { ... }` block verbatim (heredoc-safe)."""
    start = text.index(f"\n{name}() {{\n") + 1
    lines = text[start:].splitlines(keepends=True)
    heredoc_delim = None
    consumed = []
    for line in lines:
        consumed.append(line)
        if heredoc_delim is not None:
            if line.rstrip("\n") == heredoc_delim:
                heredoc_delim = None
            continue
        m = _HEREDOC_START_RE.search(line)
        if m:
            heredoc_delim = m.group(1)
            continue
        if line == "}\n" or line == "}":
            return "".join(consumed)
    raise AssertionError(f"could not find end of function {name}")


_CORE_TARGET_FUNCTIONS = (
    "bundled_stemwerk_core_wheel",
    "managed_stemwerk_core_wheel",
    "is_core_source_bundle",
    "resolve_core_target",
    "install_stemwerk_core_target",
    "install_with_optional_bundled_wheels",
)


def _core_target_funcs_src() -> str:
    text = _bootstrap_text()
    return "\n".join(_function_body(text, name) for name in _CORE_TARGET_FUNCTIONS)


def _run_resolve(
    tmp_path: Path,
    *,
    bundled_wheels_dir: Path | None = None,
    managed_wheels_dir: Path | None = None,
    stemwerk_core_path: Path | None = None,
    bundled_core_dir: Path | None = None,
) -> dict[str, str]:
    """Execute the real resolve_core_target()/install_stemwerk_core_target()
    functions under /bin/sh and report what they decided, plus the exact
    argv pip would have been invoked with (a fake `python` records argv
    instead of actually installing anything)."""
    record = tmp_path / "pip_argv.txt"
    fake_python = tmp_path / "fake_python.sh"
    fake_python.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/sh
            printf '%s\\n' "$*" >> "{record}"
            exit 0
            """
        ),
        encoding="utf-8",
    )
    fake_python.chmod(0o755)

    env_lines = [
        f'BUNDLED_WHEELS_DIR="{bundled_wheels_dir or ""}"',
        f'MANAGED_WHEELS_DIR="{managed_wheels_dir or ""}"',
        f'STEMWERK_CORE_PATH="{stemwerk_core_path or ""}"',
        f'BUNDLED_CORE_DIR="{bundled_core_dir or (tmp_path / "no-such-bundled-core")}"',
        "STEMWERK_CORE_BUNDLE_DIR=",
    ]

    script = "\n".join(
        [
            "#!/bin/sh",
            "set -eu",
            *env_lines,
            'log() { :; }',
            _core_target_funcs_src(),
            "resolve_core_target || true",
            'printf "CORE_TARGET=%s\\n" "${CORE_TARGET:-}"',
            'printf "CORE_TARGET_DESC=%s\\n" "${CORE_TARGET_DESC:-}"',
            'if [ -n "${CORE_TARGET:-}" ]; then',
            f'  install_stemwerk_core_target "{fake_python}" "${{CORE_TARGET}}" "${{CORE_TARGET_DESC}}"',
            "fi",
        ]
    )
    script_path = tmp_path / "driver.sh"
    script_path.write_text(script, encoding="utf-8")
    script_path.chmod(0o755)

    proc = subprocess.run(
        [SH, str(script_path)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr

    result: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if "=" in line:
            key, _, value = line.partition("=")
            result[key] = value
    result["pip_argv"] = record.read_text(encoding="utf-8") if record.exists() else ""
    return result


def _make_wheel_dir(tmp_path: Path, name: str, wheel_filename: str) -> Path:
    d = tmp_path / name
    d.mkdir()
    (d / wheel_filename).write_bytes(b"fake wheel contents")
    return d


def _make_source_bundle(tmp_path: Path, name: str) -> Path:
    d = tmp_path / name
    (d / "src" / "stemwerk_core").mkdir(parents=True)
    (d / "pyproject.toml").write_text("[build-system]\n", encoding="utf-8")
    (d / "src" / "stemwerk_core" / "__init__.py").write_text("", encoding="utf-8")
    (d / "src" / "stemwerk_core" / "separator.py").write_text("", encoding="utf-8")
    return d


# ---------------------------------------------------------------------------
# 1 & 7. Intel ReaPack managed-wheel selection + x86_64 wheelhouse path
# ---------------------------------------------------------------------------
def test_intel_managed_wheel_selected_over_bundled_source(tmp_path: Path) -> None:
    managed = _make_wheel_dir(tmp_path, "darwin-x86_64-cp312", "stemwerk_core-0.1.1-py3-none-any.whl")
    result = _run_resolve(tmp_path, managed_wheels_dir=managed)

    assert result["CORE_TARGET_DESC"] == "managed wheel"
    assert result["CORE_TARGET"] == str(managed / "stemwerk_core-0.1.1-py3-none-any.whl")


# ---------------------------------------------------------------------------
# 2. Apple Silicon ReaPack managed-wheel selection
# ---------------------------------------------------------------------------
def test_arm64_managed_wheel_selected(tmp_path: Path) -> None:
    managed = _make_wheel_dir(tmp_path, "darwin-arm64-cp312", "stemwerk_core-0.1.1-py3-none-any.whl")
    result = _run_resolve(tmp_path, managed_wheels_dir=managed)

    assert result["CORE_TARGET_DESC"] == "managed wheel"
    assert result["CORE_TARGET"] == str(managed / "stemwerk_core-0.1.1-py3-none-any.whl")


# ---------------------------------------------------------------------------
# 3. Bundled Apple-Silicon payload wheel: existing behavior unchanged, and
#    it still beats the managed wheel (pre-existing precedence, preserved).
# ---------------------------------------------------------------------------
def test_bundled_payload_wheel_still_wins_over_managed_wheel(tmp_path: Path) -> None:
    bundled = _make_wheel_dir(tmp_path, "bundled-wheels", "stemwerk_core-0.1.1-py3-none-any.whl")
    managed = _make_wheel_dir(tmp_path, "darwin-arm64-cp312", "stemwerk_core-0.1.1-py3-none-any.whl")
    result = _run_resolve(tmp_path, bundled_wheels_dir=bundled, managed_wheels_dir=managed)

    assert result["CORE_TARGET_DESC"] == "bundled wheel"
    assert result["CORE_TARGET"] == str(bundled / "stemwerk_core-0.1.1-py3-none-any.whl")


# ---------------------------------------------------------------------------
# 4. Explicit STEMWERK_CORE_PATH override: preserved, and still beats the
#    managed wheel (pre-existing precedence: bundled wheel > dev override >
#    managed wheel > bundled source fallback).
# ---------------------------------------------------------------------------
def test_stemwerk_core_path_override_still_wins_over_managed_wheel(tmp_path: Path) -> None:
    override = _make_source_bundle(tmp_path, "dev-checkout")
    managed = _make_wheel_dir(tmp_path, "darwin-arm64-cp312", "stemwerk_core-0.1.1-py3-none-any.whl")
    result = _run_resolve(tmp_path, stemwerk_core_path=override, managed_wheels_dir=managed)

    assert result["CORE_TARGET_DESC"] == "STEMWERK_CORE_PATH source"
    assert result["CORE_TARGET"] == str(override)


# ---------------------------------------------------------------------------
# 5. No managed/bundled wheel: bundled-source fallback remains available.
# ---------------------------------------------------------------------------
def test_bundled_source_fallback_remains_available_with_no_wheels(tmp_path: Path) -> None:
    source = _make_source_bundle(tmp_path, "vendor-stemwerk-core")
    result = _run_resolve(tmp_path, bundled_core_dir=source)

    assert result["CORE_TARGET_DESC"] == "bundled source"
    assert result["CORE_TARGET"] == str(source)


# ---------------------------------------------------------------------------
# 6. Install flags: managed wheel takes the WHEEL path (no
#    --no-build-isolation); source fallback keeps its existing flags.
# ---------------------------------------------------------------------------
def test_managed_wheel_install_does_not_use_no_build_isolation(tmp_path: Path) -> None:
    managed = _make_wheel_dir(tmp_path, "darwin-x86_64-cp312", "stemwerk_core-0.1.1-py3-none-any.whl")
    result = _run_resolve(tmp_path, managed_wheels_dir=managed)

    argv = result["pip_argv"]
    assert "--no-build-isolation" not in argv
    assert "--no-deps" in argv
    assert "stemwerk_core-0.1.1-py3-none-any.whl" in argv


def test_bundled_source_install_keeps_no_build_isolation(tmp_path: Path) -> None:
    source = _make_source_bundle(tmp_path, "vendor-stemwerk-core")
    result = _run_resolve(tmp_path, bundled_core_dir=source)

    argv = result["pip_argv"]
    assert "--no-build-isolation" in argv
    assert "--no-deps" in argv


def test_bundled_wheel_install_does_not_use_no_build_isolation(tmp_path: Path) -> None:
    bundled = _make_wheel_dir(tmp_path, "bundled-wheels", "stemwerk_core-0.1.1-py3-none-any.whl")
    result = _run_resolve(tmp_path, bundled_wheels_dir=bundled)

    argv = result["pip_argv"]
    assert "--no-build-isolation" not in argv
    assert "--no-deps" in argv


# ---------------------------------------------------------------------------
# 7 (path resolution half). MANAGED_WHEELS_DIR construction from SCRIPT_DIR
#    for both architectures, as actually written in the bootstrap driver.
# ---------------------------------------------------------------------------
@pytest.mark.parametrize("mac_arch", ["arm64", "x86_64"])
def test_managed_wheels_dir_resolves_per_arch(mac_arch: str, tmp_path: Path) -> None:
    text = _bootstrap_text()
    assert (
        'if [ -d "${SCRIPT_DIR}/vendor/wheels/darwin-${MAC_ARCH}-cp312" ]; then\n'
        '  MANAGED_WHEELS_DIR="${SCRIPT_DIR}/vendor/wheels/darwin-${MAC_ARCH}-cp312"'
        in text
    )

    script_dir = tmp_path / "script_dir"
    (script_dir / f"vendor/wheels/darwin-{mac_arch}-cp312").mkdir(parents=True)
    script = "\n".join(
        [
            "#!/bin/sh",
            "set -eu",
            f'SCRIPT_DIR="{script_dir}"',
            f'MAC_ARCH="{mac_arch}"',
            'if [ -d "${SCRIPT_DIR}/vendor/wheels/darwin-${MAC_ARCH}-cp312" ]; then',
            '  MANAGED_WHEELS_DIR="${SCRIPT_DIR}/vendor/wheels/darwin-${MAC_ARCH}-cp312"',
            "fi",
            'printf "%s\\n" "${MANAGED_WHEELS_DIR:-}"',
        ]
    )
    proc = subprocess.run([SH, "-c", script], capture_output=True, text=True, check=False)
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.strip() == str(script_dir / f"vendor/wheels/darwin-{mac_arch}-cp312")


# ---------------------------------------------------------------------------
# 8. ReaPack/package contract: both managed stemwerk_core wheels are shipped
#    and distributed via index.xml (repo state, not just the new selector).
# ---------------------------------------------------------------------------
def test_both_managed_darwin_stemwerk_core_wheels_are_shipped() -> None:
    for arch in ("arm64", "x86_64"):
        wheel = ROOT / "scripts" / "reaper" / "vendor" / "wheels" / f"darwin-{arch}-cp312" / "stemwerk_core-0.1.1-py3-none-any.whl"
        assert wheel.is_file(), wheel


def test_index_xml_distributes_both_managed_darwin_stemwerk_core_wheels() -> None:
    index_xml = (ROOT / "index.xml").read_text(encoding="utf-8")
    for arch in ("arm64", "x86_64"):
        assert (
            f'<source file="../vendor/wheels/darwin-{arch}-cp312/stemwerk_core-0.1.1-py3-none-any.whl"'
            in index_xml
        )


# ---------------------------------------------------------------------------
# 9. No-setuptools proof: install the exact shipped wheel with an isolated
#    venv that never relies on setuptools, and import it. No network.
# ---------------------------------------------------------------------------
_CP312_CANDIDATES = (
    # Prefer an actual cp312 interpreter matching the wheel's target ABI
    # (the bug this test proves is cp312-specific: "managed Python 3.12.13
    # found/used" on the real Intel failure). Falls back to whatever
    # python3 is on PATH so this test still runs (skipped only if no
    # interpreter with a usable venv module exists at all).
    Path("/Users/flark/Library/Application Support/STEMwerk/python/bin/python3.12"),
)


def _venv_python(tmp_path: Path) -> Path:
    interpreter = next((p for p in _CP312_CANDIDATES if p.is_file()), Path(sys.executable))
    venv_dir = tmp_path / "no-setuptools-venv"
    subprocess.run(
        [str(interpreter), "-m", "venv", str(venv_dir)],
        capture_output=True,
        text=True,
        check=True,
    )
    venv_py = venv_dir / "bin" / "python3"
    if not venv_py.exists():
        venv_py = venv_dir / "Scripts" / "python.exe"
    return venv_py


def test_managed_wheel_installs_and_imports_without_setuptools(tmp_path: Path) -> None:
    wheel = ROOT / "scripts" / "reaper" / "vendor" / "wheels" / "darwin-arm64-cp312" / "stemwerk_core-0.1.1-py3-none-any.whl"
    if not wheel.is_file():
        pytest.skip("managed arm64 stemwerk_core wheel not present in this checkout")

    venv_py = _venv_python(tmp_path)

    # The whole point of this proof: install the WHEEL directly (no
    # build backend involved at all -- pip just unpacks it), same
    # invocation shape install_stemwerk_core_target() uses for a
    # "managed wheel"/"bundled wheel" target (--no-deps, no
    # --no-build-isolation, no network).
    install = subprocess.run(
        [str(venv_py), "-m", "pip", "install", "--no-index", "--no-deps", str(wheel)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert install.returncode == 0, install.stdout + install.stderr

    uninstall_setuptools = subprocess.run(
        [str(venv_py), "-m", "pip", "uninstall", "-y", "setuptools"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert uninstall_setuptools.returncode == 0, uninstall_setuptools.stdout + uninstall_setuptools.stderr

    # stemwerk_core.separator imports PyYAML at module load time, which is
    # a separate, undeclared runtime dependency satisfied in the real
    # bootstrap by other, unrelated install steps (audio-separator's own
    # dependency chain) -- out of scope for this core-target-selection
    # slice. Stub it out so this offline test isolates exactly what it's
    # here to prove: the wheel installs and imports with no setuptools and
    # no build backend involved, not stemwerk_core's full dependency
    # closure.
    site_packages = next(venv_py.parent.parent.glob("lib/python3.*/site-packages"))
    (site_packages / "yaml.py").write_text(
        "def safe_load(*_a, **_k):\n    raise NotImplementedError('stub')\n",
        encoding="utf-8",
    )

    check = subprocess.run(
        [str(venv_py), "-c", "import stemwerk_core; print('stemwerk_core import ok')"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert check.returncode == 0, check.stdout + check.stderr
    assert "stemwerk_core import ok" in check.stdout

    setuptools_check = subprocess.run(
        [str(venv_py), "-c", "import setuptools"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert setuptools_check.returncode != 0, "setuptools unexpectedly still importable"
