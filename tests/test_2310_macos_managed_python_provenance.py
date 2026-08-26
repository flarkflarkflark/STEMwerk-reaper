"""Release provenance gates for the bundled macOS managed-Python artifact."""

from __future__ import annotations

import io
import json
import tarfile
from pathlib import Path
from types import SimpleNamespace

import pytest

from installer.macos import audit_payload
from tools import build_macos_apple_silicon_payload as payload_builder
from tools import macos_managed_python


ROOT = Path(__file__).resolve().parents[1]
EXPECTED_RUNTIME = {
    "implementation": "CPython",
    "python_version": "3.12.13",
    "sys_platform": "darwin",
    "architecture": "arm64",
}


def _artifact_fixture(tmp_path: Path) -> Path:
    artifact = tmp_path / macos_managed_python.MANAGED_PYTHON_ARTIFACT_FILENAME
    with tarfile.open(artifact, "w:gz") as archive:
        directory = tarfile.TarInfo("python/bin")
        directory.type = tarfile.DIRTYPE
        directory.mode = 0o755
        archive.addfile(directory)
        data = b"#!/bin/sh\n"
        executable = tarfile.TarInfo("python/bin/python3.12")
        executable.mode = 0o755
        executable.size = len(data)
        archive.addfile(executable, io.BytesIO(data))
    return artifact


def _official_fixture(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> tuple[Path, dict[str, object], dict[str, object]]:
    artifact = _artifact_fixture(tmp_path)
    original_sha256_file = macos_managed_python.sha256_file

    def fixture_hash(path: Path) -> str:
        if path == artifact:
            return macos_managed_python.MANAGED_PYTHON_ARTIFACT_SHA256
        return original_sha256_file(path)

    monkeypatch.setattr(macos_managed_python, "sha256_file", fixture_hash)
    fixture_root = tmp_path / "fixture-tree"
    (fixture_root / "bin").mkdir(parents=True)
    (fixture_root / "bin/python3.12").write_bytes(b"#!/bin/sh\n")
    (fixture_root / "bin/python3.12").chmod(0o755)
    monkeypatch.setattr(
        macos_managed_python,
        "MANAGED_PYTHON_ARTIFACT_TREE_IDENTITY",
        macos_managed_python.payload_tree_identity(fixture_root),
    )
    monkeypatch.setattr(macos_managed_python, "MANAGED_PYTHON_EXCLUDED_NON_MACOS_PATHS", ())
    monkeypatch.setattr(
        macos_managed_python,
        "inspect_managed_python_runtime",
        lambda _root: dict(EXPECTED_RUNTIME),
    )
    destination = tmp_path / "payload/python"
    provenance = macos_managed_python.prepare_managed_python_payload(
        destination, artifact=artifact, release_mode=True
    )
    manifest: dict[str, object] = {"managed_python": provenance}
    return destination, provenance, manifest


def test_official_managed_python_artifact_is_verified_extracted_and_bound_to_payload(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    destination, provenance, manifest = _official_fixture(tmp_path, monkeypatch)

    assert provenance == manifest["managed_python"]
    assert provenance["managed_python_release"] == "20260408"
    assert provenance["managed_python_version"] == "3.12.13"
    assert provenance["managed_python_artifact_url"] == macos_managed_python.MANAGED_PYTHON_ARTIFACT_URL
    assert provenance["managed_python_artifact_sha256"] == macos_managed_python.MANAGED_PYTHON_ARTIFACT_SHA256
    assert provenance["managed_python_platform"] == "aarch64-apple-darwin"
    assert provenance["managed_python_architecture"] == "arm64"
    assert provenance["runtime_validation"] == EXPECTED_RUNTIME
    assert provenance["artifact_payload_tree"] == macos_managed_python.MANAGED_PYTHON_ARTIFACT_TREE_IDENTITY
    assert provenance["excluded_non_macos_paths"] == []
    assert provenance["payload_tree"] == macos_managed_python.payload_tree_identity(destination)
    assert provenance["release_eligible"] is True
    assert (destination / "bin/python3.12").is_file()
    macos_managed_python.validate_official_managed_python_provenance(destination, manifest)


@pytest.mark.parametrize(
    "field,mutation",
    [
        ("managed_python_artifact_url", "missing"),
        ("managed_python_artifact_url", "wrong"),
        ("managed_python_artifact_sha256", "missing"),
        ("managed_python_artifact_sha256", "wrong"),
        ("managed_python_release", "wrong"),
        ("managed_python_version", "wrong"),
        ("managed_python_platform", "wrong"),
        ("managed_python_architecture", "wrong"),
        ("artifact_payload_tree", "wrong"),
        ("excluded_non_macos_paths", "wrong"),
    ],
)
def test_official_managed_python_provenance_rejects_missing_or_tampered_identity(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, field: str, mutation: str
) -> None:
    destination, provenance, manifest = _official_fixture(tmp_path, monkeypatch)
    if mutation == "missing":
        del provenance[field]
    else:
        provenance[field] = "tampered"
    with pytest.raises(RuntimeError, match="managed-Python provenance field"):
        macos_managed_python.validate_official_managed_python_provenance(destination, manifest)


@pytest.mark.parametrize(
    "field,value",
    [
        ("python_version", "3.12.12"),
        ("sys_platform", "linux"),
        ("architecture", "x86_64"),
        ("implementation", "PyPy"),
    ],
)
def test_runtime_probe_rejects_wrong_version_platform_architecture_or_implementation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, field: str, value: str
) -> None:
    root = tmp_path / "python"
    executable = root / "bin/python3.12"
    executable.parent.mkdir(parents=True)
    executable.write_text("#!/bin/sh\n", encoding="utf-8")
    executable.chmod(0o755)
    identity = dict(EXPECTED_RUNTIME)
    identity[field] = value
    monkeypatch.setattr(
        macos_managed_python.subprocess,
        "run",
        lambda *_args, **_kwargs: SimpleNamespace(stdout=json.dumps(identity)),
    )
    with pytest.raises(RuntimeError, match="Unexpected managed-Python runtime identity"):
        macos_managed_python.inspect_managed_python_runtime(root)


def test_runtime_probe_uses_explicit_no_bytecode_flag_and_does_not_mutate_tree(
    tmp_path: Path,
) -> None:
    root = tmp_path / "python"
    executable = root / "bin/python3.12"
    executable.parent.mkdir(parents=True)
    executable.write_text(
        """#!/bin/sh
no_bytecode=false
for argument in "$@"; do
    if [ "$argument" = "-B" ]; then
        no_bytecode=true
    fi
done
if [ "$no_bytecode" != true ]; then
    touch "${0}.pyc"
fi
printf '%s\n' '{"architecture":"arm64","implementation":"CPython","python_version":"3.12.13","sys_platform":"darwin"}'
""",
        encoding="utf-8",
    )
    executable.chmod(0o755)
    before = macos_managed_python.payload_tree_identity(root)

    assert macos_managed_python.inspect_managed_python_runtime(root) == EXPECTED_RUNTIME
    assert macos_managed_python.payload_tree_identity(root) == before


def test_development_directory_override_is_release_ineligible_and_cannot_pass_release_mode(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = tmp_path / "development-python"
    (source / "bin").mkdir(parents=True)
    (source / "bin/python3.12").write_text("fixture", encoding="utf-8")
    monkeypatch.setattr(
        macos_managed_python,
        "inspect_managed_python_runtime",
        lambda _root: dict(EXPECTED_RUNTIME),
    )
    with pytest.raises(RuntimeError, match="requires the official pinned"):
        macos_managed_python.prepare_managed_python_payload(
            tmp_path / "release-denied", development_source=source, release_mode=True
        )
    provenance = macos_managed_python.prepare_managed_python_payload(
        tmp_path / "development-output", development_source=source
    )
    assert provenance["build_mode"] == "development-directory-override"
    assert provenance["official_artifact"] is False
    assert provenance["release_eligible"] is False
    assert provenance["managed_python_artifact_sha256"] is None
    with pytest.raises(RuntimeError, match="managed-Python provenance field"):
        macos_managed_python.validate_official_managed_python_provenance(
            tmp_path / "development-output", {"managed_python": provenance}
        )


def test_manifest_preserves_exact_managed_python_provenance(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    destination, provenance, _manifest = _official_fixture(tmp_path, monkeypatch)
    output = tmp_path / "manifest-output"
    output.mkdir()
    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    payload_builder.write_manifest(output, version, [], None, False, {}, provenance)
    manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["managed_python"] == provenance
    macos_managed_python.validate_official_managed_python_provenance(destination, manifest)


def test_payload_audit_rejects_missing_managed_python_provenance(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    bundled = tmp_path / "_bundled/macos/apple-silicon"
    (bundled / "ffmpeg").mkdir(parents=True)
    (bundled / "python").mkdir()
    (bundled / "manifest.json").write_text("{}\n", encoding="utf-8")
    monkeypatch.setattr(audit_payload, "validate_official_provenance", lambda *_a, **_k: None)
    with pytest.raises(RuntimeError, match="Missing managed-Python provenance"):
        audit_payload.audit_bundled_apple_silicon_payload(tmp_path)


def test_release_workflow_reads_managed_python_identity_from_single_authoritative_module() -> None:
    workflow = (ROOT / ".github/workflows/release-installers.yml").read_text(encoding="utf-8")
    assert "tools/macos_managed_python.py --print-artifact-field" in workflow
    assert "--managed-python-artifact" in workflow
    assert macos_managed_python.MANAGED_PYTHON_ARTIFACT_URL not in workflow
    assert macos_managed_python.MANAGED_PYTHON_ARTIFACT_SHA256 not in workflow
