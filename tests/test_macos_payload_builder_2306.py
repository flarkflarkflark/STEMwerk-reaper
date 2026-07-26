import importlib.util
import subprocess
import zipfile
from pathlib import Path

import pytest


BUILDER_PATH = Path("tools/build_macos_apple_silicon_payload.py")


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
