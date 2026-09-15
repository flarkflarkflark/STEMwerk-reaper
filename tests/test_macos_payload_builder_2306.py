import importlib.util
import os
import shutil
import subprocess
import zipfile
from pathlib import Path

import pytest


BUILDER_PATH = Path("tools/build_macos_apple_silicon_payload.py")
NETWORK = os.environ.get("STEMWERK_NETWORK_TESTS") == "1"
needs_network = pytest.mark.skipif(not NETWORK, reason="set STEMWERK_NETWORK_TESTS=1")


def _load_builder():
    spec = importlib.util.spec_from_file_location("stemwerk_payload_builder_2306", BUILDER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def _fake_wheel(path: Path, name: str, version: str) -> None:
    dist_info = f"{name.replace('-', '_')}-{version}.dist-info"
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(f"{dist_info}/METADATA", f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n")
        archive.writestr(f"{dist_info}/WHEEL", "Wheel-Version: 1.0\nTag: py3-none-any\n")


def test_compatibility_config_is_required_and_hash_verified(tmp_path):
    builder = _load_builder()
    model_cache = tmp_path / "models"
    model_cache.mkdir()
    for filename in builder.DRUMSEP_FILES:
        (model_cache / filename).write_bytes(b"fixture")

    with pytest.raises(FileNotFoundError, match="compatibility config"):
        builder.copy_drumsep_assets(model_cache, tmp_path / "missing.yaml", tmp_path / "payload")


def test_duplicate_normalized_wheel_distribution_is_rejected(tmp_path):
    builder = _load_builder()
    _fake_wheel(tmp_path / "first.whl", "audio-separator", "0.23.0")
    _fake_wheel(tmp_path / "second.whl", "audio_separator", "0.23.0")

    with pytest.raises(RuntimeError, match="Duplicate wheel distribution audio-separator"):
        builder.resolved_wheel_inventory(tmp_path)


def test_offline_dependency_closure_uses_no_index_and_fails_closed(tmp_path, monkeypatch):
    builder = _load_builder()
    calls = []

    def fail_resolution(command, **kwargs):
        calls.append((command, kwargs))
        raise subprocess.CalledProcessError(1, command, stderr="ResolutionImpossible")

    monkeypatch.setattr(builder.subprocess, "run", fail_resolution)
    with pytest.raises(subprocess.CalledProcessError):
        builder.verify_offline_resolution(tmp_path, "/managed/python3.12")

    command = calls[0][0]
    assert "--dry-run" in command
    assert "--no-index" in command
    assert "--find-links" in command
    assert "audio-separator==0.23.0" in command
    assert "samplerate==0.1.0" in command


def test_conflicting_samplerate_audio_separator_policy_is_rejected():
    builder = _load_builder()
    conflicting = tuple(
        "samplerate==0.2.4" if requirement.startswith("samplerate==") else requirement
        for requirement in builder.RUNTIME_REQUIREMENTS
    )

    with pytest.raises(RuntimeError, match="audio-separator 0.23.0 requires samplerate 0.1.0"):
        builder.validate_declared_policy(conflicting)


def test_native_extension_must_be_arm64_only(tmp_path, monkeypatch):
    builder = _load_builder()
    native = tmp_path / "samplerate.cpython-312-darwin.so"
    native.write_bytes(b"fixture")

    monkeypatch.setattr(builder, "macho_architectures", lambda _path: ("x86_64", "arm64"))
    with pytest.raises(RuntimeError, match="Non-arm64-only Mach-O"):
        builder.assert_arm64_macho(native)

    monkeypatch.setattr(builder, "macho_architectures", lambda _path: ("arm64",))
    builder.assert_arm64_macho(native)


def test_macho_probe_uses_magic_before_lipo(tmp_path, monkeypatch):
    builder = _load_builder()
    candidate = tmp_path / "native.bin"
    candidate.write_bytes(b"\xcf\xfa\xed\xfe" + b"fixture")

    monkeypatch.setattr(
        builder.subprocess,
        "run",
        lambda *_args, **_kwargs: subprocess.CompletedProcess([], 0, stdout="arm64\n"),
    )
    assert builder.macho_architectures(candidate) == ("arm64",)


def test_wheel_metadata_ignores_vendored_dist_info(tmp_path):
    builder = _load_builder()
    wheel = tmp_path / "setuptools.whl"
    with zipfile.ZipFile(wheel, "w") as archive:
        archive.writestr(
            "setuptools-83.0.0.dist-info/METADATA",
            "Metadata-Version: 2.1\nName: setuptools\nVersion: 83.0.0\n",
        )
        archive.writestr(
            "setuptools/_vendor/packaging-26.0.dist-info/METADATA",
            "Metadata-Version: 2.1\nName: packaging\nVersion: 26.0\n",
        )

    assert builder.wheel_metadata(wheel) == ("setuptools", "83.0.0")


def test_thinned_arm64_wheel_uses_valid_macos_deployment_target(tmp_path):
    builder = _load_builder()
    original = tmp_path / "protobuf-7.35.1-cp310-abi3-macosx_10_9_universal2.whl"
    root = tmp_path / "wheel"
    dist_info = root / "protobuf-7.35.1.dist-info"
    dist_info.mkdir(parents=True)
    (dist_info / "WHEEL").write_text(
        "Wheel-Version: 1.0\nRoot-Is-Purelib: false\nTag: cp310-abi3-macosx_10_9_universal2\n",
        encoding="utf-8",
    )
    (dist_info / "METADATA").write_text(
        "Metadata-Version: 2.1\nName: protobuf\nVersion: 7.35.1\n",
        encoding="utf-8",
    )
    (dist_info / "RECORD").write_text("", encoding="utf-8")

    target = builder._retag_wheel_file(original, root)

    assert target.name.endswith("macosx_11_0_arm64.whl")
    with zipfile.ZipFile(target) as archive:
        wheel_text = archive.read("protobuf-7.35.1.dist-info/WHEEL").decode("utf-8")
    assert "Tag: cp310-abi3-macosx_11_0_arm64" in wheel_text


def test_selected_2304_generation_is_exact_and_coherent():
    builder = _load_builder()
    builder.validate_declared_policy(builder.RUNTIME_REQUIREMENTS)
    assert "numpy==1.26.4" in builder.RUNTIME_REQUIREMENTS
    assert "audio-separator==0.23.0" in builder.RUNTIME_REQUIREMENTS
    assert "samplerate==0.1.0" in builder.RUNTIME_REQUIREMENTS
    assert "numba==0.59.1" in builder.RUNTIME_REQUIREMENTS
    assert "llvmlite==0.42.0" in builder.RUNTIME_REQUIREMENTS
    assert not any("0.44.3" in requirement for requirement in builder.RUNTIME_REQUIREMENTS)


# --- payload_python(): invoking interpreter takes priority ------------------
#
# GitHub Actions run 34915567815 failed because payload_python() picked
# /usr/local/bin/python3.12 (a candidate fixed path) instead of sys.executable
# (the interpreter actions/setup-python actually provisioned for this job),
# and that fixed-path interpreter didn't have setuptools importable. These
# tests prove sys.executable now wins whenever it's itself a suitable native
# Python 3.12, and that the existing fallbacks still work when it isn't.


def _patch_candidate_paths_exist(monkeypatch, existing_paths: set[str]) -> None:
    real_is_file = Path.is_file

    def fake_is_file(self):
        if str(self) in existing_paths:
            return True
        return real_is_file(self)

    monkeypatch.setattr(Path, "is_file", fake_is_file)


def test_payload_python_prefers_suitable_invoking_interpreter(tmp_path, monkeypatch):
    builder = _load_builder()
    invoking = tmp_path / "invoking-python3.12"

    monkeypatch.setattr(builder.sys, "executable", str(invoking))
    _patch_candidate_paths_exist(
        monkeypatch,
        {str(invoking), "/opt/homebrew/bin/python3.12", "/usr/local/bin/python3.12"},
    )
    # Every candidate reports a suitable version -- proves sys.executable wins
    # on ordering, not because it was the only valid candidate.
    monkeypatch.setattr(builder, "python_version", lambda _path: (3, 12))

    assert builder.payload_python() == str(invoking)


def test_payload_python_falls_back_when_invoking_interpreter_is_unsuitable(tmp_path, monkeypatch):
    builder = _load_builder()
    invoking = tmp_path / "invoking-python3.11"
    homebrew = "/opt/homebrew/bin/python3.12"

    monkeypatch.setattr(builder.sys, "executable", str(invoking))
    _patch_candidate_paths_exist(monkeypatch, {str(invoking), homebrew})

    def fake_python_version(path):
        return (3, 11) if path == str(invoking) else (3, 12)

    monkeypatch.setattr(builder, "python_version", fake_python_version)

    assert builder.payload_python() == homebrew


def test_payload_python_rejects_when_nothing_is_python_312(tmp_path, monkeypatch):
    builder = _load_builder()
    invoking = tmp_path / "invoking-python2.7"

    monkeypatch.setattr(builder.sys, "executable", str(invoking))
    _patch_candidate_paths_exist(
        monkeypatch,
        {str(invoking), "/opt/homebrew/bin/python3.12", "/usr/local/bin/python3.12"},
    )
    monkeypatch.setattr(builder, "python_version", lambda _path: (2, 7))

    with pytest.raises(RuntimeError, match="Missing native Python 3.12 interpreter"):
        builder.payload_python()


# --- build_stemwerk_core_wheel(): self-contained PEP-517 build --------------


def test_core_wheel_build_command_uses_isolated_no_index_wheelhouse(tmp_path, monkeypatch):
    """Command-contract proof: the invoked pip command never disables build
    isolation and is restricted to the closed wheelhouse -- no implicit
    network dependency resolution for the setuptools/wheel build backend."""
    builder = _load_builder()
    wheels_dir = tmp_path / "wheels"
    wheels_dir.mkdir()
    (wheels_dir / "setuptools-83.0.0-py3-none-any.whl").write_bytes(b"fixture")
    (wheels_dir / "wheel-0.47.0-py3-none-any.whl").write_bytes(b"fixture")

    calls = []
    monkeypatch.setattr(
        builder.subprocess,
        "run",
        lambda command, **kwargs: calls.append(command) or subprocess.CompletedProcess(command, 0),
    )

    builder.build_stemwerk_core_wheel(tmp_path, wheels_dir, "/fake/python3.12")

    assert len(calls) == 1
    command = calls[0]
    assert "--no-build-isolation" not in command
    assert "--no-index" in command
    assert command[command.index("--find-links") + 1] == str(wheels_dir)
    assert command[command.index("--wheel-dir") + 1] == str(wheels_dir)


def test_core_wheel_build_fails_closed_with_specific_diagnostic_when_bootstrap_wheels_missing(tmp_path, monkeypatch):
    """A missing pinned setuptools/wheel wheel in the closed wheelhouse must
    raise a specific builder diagnostic identifying the exact missing
    requirement, before ever invoking pip -- not an opaque two-layers-deep
    pip subprocess traceback."""
    builder = _load_builder()
    wheels_dir = tmp_path / "wheels"
    wheels_dir.mkdir()
    # setuptools present, wheel missing.
    (wheels_dir / "setuptools-83.0.0-py3-none-any.whl").write_bytes(b"fixture")

    def fail_if_called(*_args, **_kwargs):
        raise AssertionError("pip must not be invoked when the wheelhouse is incomplete")

    monkeypatch.setattr(builder.subprocess, "run", fail_if_called)

    with pytest.raises(RuntimeError, match=r"missing the pinned PEP-517 build-backend wheel.*wheel==0\.47\.0"):
        builder.build_stemwerk_core_wheel(tmp_path, wheels_dir, "/fake/python3.12")


def test_core_wheel_build_fails_closed_when_setuptools_wheel_missing(tmp_path, monkeypatch):
    builder = _load_builder()
    wheels_dir = tmp_path / "wheels"
    wheels_dir.mkdir()
    (wheels_dir / "wheel-0.47.0-py3-none-any.whl").write_bytes(b"fixture")

    monkeypatch.setattr(
        builder.subprocess,
        "run",
        lambda *_a, **_k: (_ for _ in ()).throw(AssertionError("pip must not be invoked")),
    )

    with pytest.raises(RuntimeError, match=r"missing the pinned PEP-517 build-backend wheel.*setuptools==83\.0\.0"):
        builder.build_stemwerk_core_wheel(tmp_path, wheels_dir, "/fake/python3.12")


# --- real isolated build proof (network-gated: populates the test's own ----
# --- local wheelhouse fixture once; the actual build itself is offline) ----


@needs_network
def test_core_wheel_builds_offline_from_closed_wheelhouse_with_real_pip(tmp_path):
    """End-to-end proof that stemwerk-core builds via normal PEP-517
    isolation restricted to --no-index --find-links <wheelhouse>, using a
    real Python 3.12 interpreter and real pip -- without ever assuming
    setuptools.build_meta is importable in that interpreter's own site-
    packages (the exact failure mode from GitHub Actions run 34915567815).

    Network is used only to populate this test's own throwaway wheelhouse
    fixture with the pinned setuptools/wheel/packaging wheels (packaging is
    wheel 0.47.0's own declared dependency) -- ordinary CI without
    STEMWERK_NETWORK_TESTS=1 skips this and relies on the command-contract
    and fail-closed tests above instead. A real macOS GitHub Actions run of
    the actual release workflow is what proves this on the target platform;
    this test proves the underlying pip/PEP-517 mechanism is sound using
    whatever Python 3.12 this host has, regardless of OS.
    """
    python312 = shutil.which("python3.12")
    if not python312:
        pytest.skip("no python3.12 interpreter available on this host")

    builder = _load_builder()
    repo_root = Path.cwd()
    wheels_dir = tmp_path / "wheels"
    wheels_dir.mkdir()
    subprocess.run(
        [
            python312, "-m", "pip", "download",
            "--dest", str(wheels_dir),
            "--only-binary=:all:",
            "setuptools==83.0.0", "wheel==0.47.0",
        ],
        check=True,
    )
    assert any(wheels_dir.glob("setuptools-83.0.0-*.whl"))
    assert any(wheels_dir.glob("wheel-0.47.0-*.whl"))

    builder.build_stemwerk_core_wheel(repo_root, wheels_dir, python312)

    built = list(wheels_dir.glob("stemwerk_core-0.1.1-*.whl"))
    assert len(built) == 1, f"expected exactly one stemwerk-core wheel, found {built}"
    name, version = builder.wheel_metadata(built[0])
    assert name == "stemwerk-core"
    assert version == "0.1.1"
    # Pure-Python wheel: no compiled extension, so no platform-specific tag.
    assert built[0].name.endswith("-py3-none-any.whl"), built[0].name
