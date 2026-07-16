import importlib.util
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest
import yaml


BUILDER_PATH = Path("tools/build_macos_apple_silicon_payload.py")
BOOTSTRAP_PATH = Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh")
SAMPLERATE_GUARD_PATH = Path("scripts/reaper/_internal/stemwerk_samplerate_guard.py")
PAYLOAD_CONTRACT_PATH = Path("scripts/reaper/_internal/stemwerk_macos_payload_contract.py")
DRUMSEP_HELPER_PATH = Path("scripts/reaper/_internal/stemwerk_drumsep_process.py")

CORE_BUNDLE = (
    "audio-separator==0.44.3",
    "numpy==2.4.4",
    "scipy==1.18.0",
    "numba==0.66.0",
    "llvmlite==0.48.0",
    "torch==2.5.1",
    "torchaudio==2.5.1",
    "torchvision==0.20.1",
    "samplerate==0.2.4",
    "onnxruntime==1.27.0",
)
FAKE_FLATBUFFERS_VERSION = "25.9.23"


def shell_function(script: str, name: str) -> str:
    match = re.search(rf"^{name}\(\) \{{\n(?P<body>.*?)^\}}$", script, re.MULTILINE | re.DOTALL)
    assert match, f"missing shell function {name}"
    return match.group("body")


def load_builder():
    spec = importlib.util.spec_from_file_location("macos_payload_builder_safety", BUILDER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def load_samplerate_guard():
    spec = importlib.util.spec_from_file_location("macos_samplerate_guard_safety", SAMPLERATE_GUARD_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def load_payload_contract():
    spec = importlib.util.spec_from_file_location("macos_payload_contract_safety", PAYLOAD_CONTRACT_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def load_drumsep_helper():
    spec = importlib.util.spec_from_file_location("macos_drumsep_helper_safety", DRUMSEP_HELPER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


def resolve_posix_shell() -> Path | None:
    if os.name != "nt":
        shell = shutil.which("sh") or "/bin/sh"
        path = Path(shell)
        return path if path.is_file() else None
    candidates = (
        Path(r"C:\Program Files\Git\bin\bash.exe"),
        Path(r"C:\Program Files\Git\bin\sh.exe"),
    )
    return next((path for path in candidates if path.is_file()), None)


def posix_shell_path(shell: Path, path: Path) -> str:
    resolved = path.resolve()
    if os.name != "nt":
        return str(resolved)
    return subprocess.run(
        [str(shell), "-lc", 'cygpath -u "$1"', "stemwerk-cygpath", str(resolved)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def run_drumsep_materialization_harness(
    tmp_path: Path, source_dir: Path, cache_dir: Path, *, extra_shell: str = ""
):
    shell = resolve_posix_shell()
    if shell is None:
        if os.name == "nt":
            pytest.skip("native Git Bash is required for the POSIX shell migration fixture on Windows")
        pytest.fail("native /bin/sh is required for the DrumSep migration fixture")
    script = BOOTSTRAP_PATH.read_text(encoding="utf-8")
    builder = load_builder()

    harness = tmp_path / "materialize-drumsep-compat.sh"
    harness.write_text(
        "#!/bin/sh\nset -u\n"
        + shell_function(script, "drumsep_file_sha256").join(("drumsep_file_sha256() {\n", "\n}\n"))
        + shell_function(script, "drumsep_file_size").join(("drumsep_file_size() {\n", "\n}\n"))
        + shell_function(script, "materialize_drumsep_compat_yaml").join(
            ("materialize_drumsep_compat_yaml() {\n", "\n}\n")
        )
        + f'LOG_FILE="{posix_shell_path(shell, tmp_path / "materialize.log")}"\n'
        + 'log() { printf "%s\\n" "$*" >> "$LOG_FILE"; }\n'
        + 'curl() { printf curl > "${LOG_FILE}.network"; return 97; }\n'
        + 'wget() { printf wget > "${LOG_FILE}.network"; return 98; }\n'
        + 'DRUMSEP_COMPAT_YAML="config_drumsep_mdx23c.yaml"\n'
        + f'DRUMSEP_COMPAT_YAML_EXPECTED_SHA256="{builder.DRUMSEP_COMPAT_CANONICAL_SHA256}"\n'
        + f'DRUMSEP_COMPAT_YAML_EXPECTED_SIZE="{builder.DRUMSEP_COMPAT_CANONICAL_SIZE}"\n'
        + f'DRUMSEP_COMPAT_YAML_LEGACY_CRLF_SHA256="{builder.DRUMSEP_COMPAT_SOURCE_PROVENANCE["sha256"]}"\n'
        + f'DRUMSEP_COMPAT_YAML_LEGACY_CRLF_SIZE="{builder.DRUMSEP_COMPAT_SOURCE_PROVENANCE["size"]}"\n'
        + f'SRC="{posix_shell_path(shell, source_dir)}"\n'
        + f'DEST="{posix_shell_path(shell, cache_dir)}"\n'
        + f'PY="{posix_shell_path(shell, Path(sys.executable))}"\n'
        + extra_shell
        + '\nmaterialize_drumsep_compat_yaml "$SRC" "$DEST" "$PY"\nrc=$?\n'
        + 'printf "result=%s:%s:%s:%s\\n" "$DRUMSEP_COMPAT_YAML_STATUS" "$DRUMSEP_COMPAT_YAML_REASON" '
        + '"$DRUMSEP_COMPAT_YAML_PREVIOUS_SHA256" "$DRUMSEP_COMPAT_YAML_SHA256"\nexit "$rc"\n',
        encoding="utf-8",
    )
    return subprocess.run(
        [str(shell), posix_shell_path(shell, harness)], capture_output=True, text=True
    )


def run_arm64_payload_gate_fixture(tmp_path: Path, payload_state: str):
    bash = Path(r"C:\Program Files\Git\bin\bash.exe")
    if not bash.is_file():
        pytest.skip("native Git Bash not available")
    script_dir = tmp_path / "reaper"
    internal = script_dir / "_internal"
    internal.mkdir(parents=True)
    bootstrap = script_dir / "STEMwerk_Bootstrap_macOS.sh"
    shutil.copy2(BOOTSTRAP_PATH, bootstrap)
    shutil.copy2(Path("scripts/reaper/audio_separator_process.py"), script_dir / "audio_separator_process.py")
    shutil.copy2(SAMPLERATE_GUARD_PATH, internal / "stemwerk_samplerate_guard.py")
    shutil.copy2(PAYLOAD_CONTRACT_PATH, internal / "stemwerk_macos_payload_contract.py")
    payload = script_dir / "_bundled" / "macos" / "apple-silicon"
    if payload_state == "damaged":
        payload.mkdir(parents=True)
        (payload / "manifest.json").write_text("{}\n", encoding="utf-8")

    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    (fake_bin / "uname").write_text("#!/bin/sh\nprintf 'arm64\\n'\n", encoding="utf-8")
    invoked = tmp_path / "python-invoked"
    (fake_bin / "python3.12").write_text(
        f"#!/bin/sh\nprintf invoked > '{invoked.as_posix()}'\nexit 99\n", encoding="utf-8"
    )
    runtime = tmp_path / "runtime"
    sentinel = runtime / ".venv" / "sentinel"
    sentinel.parent.mkdir(parents=True)
    sentinel.write_text("preserved\n", encoding="utf-8")

    def posix(path: Path) -> str:
        result = subprocess.run(
            [str(bash), "-lc", f"cygpath -u '{path.as_posix()}'"], check=True, capture_output=True, text=True
        )
        return result.stdout.strip()

    state = tmp_path / "state.env"
    log = tmp_path / "bootstrap.log"
    command = (
        f"PATH='{posix(fake_bin)}':$PATH '{posix(bootstrap)}' "
        f"--runtime-base '{posix(runtime)}' --state-file '{posix(state)}' "
        f"--log-file '{posix(log)}' --mode repair"
    )
    result = subprocess.run([str(bash), "-lc", command], capture_output=True, text=True)
    return result, state.read_text(encoding="utf-8"), sentinel, invoked


def wheel_name(requirement: str) -> str:
    name, version = requirement.split("==", 1)
    normalized = name.replace("-", "_")
    if name == "audio-separator":
        return f"{normalized}-{version}-py3-none-any.whl"
    if name == "samplerate":
        return f"{normalized}-{version}-cp312-cp312-macosx_10_13_universal2.whl"
    return f"{normalized}-{version}-cp312-cp312-macosx_12_0_arm64.whl"


def write_fake_wheel(path: Path, requires_dist=()) -> None:
    distribution, version = path.name.split("-", 2)[:2]
    metadata = ["Metadata-Version: 2.1", f"Name: {distribution.replace('_', '-')}", f"Version: {version}"]
    metadata += [f"Requires-Dist: {requirement}" for requirement in requires_dist]
    dist_info = f"{distribution}-{version}.dist-info"
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr(f"{dist_info}/METADATA", "\n".join(metadata) + "\n")
        archive.writestr(f"{dist_info}/WHEEL", "Wheel-Version: 1.0\nTag: py3-none-any\n")


def complete_fake_wheelhouse(tmp_path: Path, builder) -> Path:
    wheels = tmp_path / "wheels"
    wheels.mkdir()
    for requirement in builder.MAIN_REQUIREMENTS:
        if "==" in requirement:
            requires = ()
            if requirement == "onnxruntime==1.27.0":
                requires = ("flatbuffers>=23.5.26",)
            elif requirement == "torch==2.5.1":
                requires = ('setuptools; python_version >= "3.12"',)
            elif requirement == "audio-separator==0.44.3":
                requires = ("samplerate==0.1.0", "diffq==1.0")
            write_fake_wheel(wheels / wheel_name(requirement), requires)
    for requirement in builder.PINNED_BOOTSTRAP_REQUIREMENTS:
        name, version = requirement.split("==", 1)
        write_fake_wheel(wheels / f"{name}-{version}-py3-none-any.whl")
    for prefix in builder.REQUIRED_WHEEL_PREFIXES:
        if not any(wheels.glob(f"{prefix}*.whl")):
            write_fake_wheel(wheels / f"{prefix}1.0-py3-none-any.whl")
    write_fake_wheel(wheels / "sympy-1.13.1-py3-none-any.whl")
    write_fake_wheel(wheels / f"flatbuffers-{FAKE_FLATBUFFERS_VERSION}-py2.py3-none-any.whl")
    drumsep = tmp_path / "drumsep"
    drumsep.mkdir()
    (drumsep / builder.DRUMSEP_FILES[0]).write_bytes(b"fake canonical checkpoint")
    (drumsep / builder.DRUMSEP_FILES[1]).write_text("training:\n  instruments: [Kick]\n", encoding="utf-8")
    shutil.copy2(builder.DRUMSEP_COMPAT_ASSET, drumsep / builder.DRUMSEP_FILES[2])
    return wheels


@pytest.mark.parametrize("missing", ["numpy==2.4.4", "llvmlite==0.48.0"])
def test_exact_core_wheel_missing_fails_payload_audit(tmp_path, missing):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    (wheels / wheel_name(missing)).unlink()

    with pytest.raises(RuntimeError, match="payload_core_version_exclusivity"):
        builder.ensure_wheelhouse_complete(wheels)


def test_wrong_python_or_architecture_wheel_fails_payload_audit(tmp_path):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    wanted = wheels / wheel_name("numba==0.66.0")
    wanted.unlink()
    (wheels / "numba-0.66.0-cp311-cp311-macosx_12_0_x86_64.whl").touch()

    with pytest.raises(RuntimeError, match="wrong_platform"):
        builder.ensure_wheelhouse_complete(wheels)


def test_complete_exact_cp312_arm64_wheelhouse_passes_and_manifest_is_fingerprinted(tmp_path):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)

    builder.ensure_wheelhouse_complete(wheels)
    builder.write_manifest(tmp_path, "2.3.0.5")

    manifest = json.loads((tmp_path / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["python_tag"] == "cp312"
    assert manifest["architecture"] == "arm64"
    assert manifest["runtime_requirements"] == list(builder.MAIN_REQUIREMENTS)
    assert manifest["target_core_requirements"] == list(builder.MAIN_REQUIREMENTS)
    assert manifest["dependency_overrides"] == list(builder.DEPENDENCY_OVERRIDE_POLICY)
    assert manifest["forbidden_requirements"] == ["samplerate==0.1.0", "sympy==1.14.0"]
    assert manifest["dependency_closure_requirements"] == [
        "diffq==1.0", f"flatbuffers=={FAKE_FLATBUFFERS_VERSION}", "sympy==1.13.1"
    ]
    assert manifest["bootstrap_requirements"] == ["pip", "setuptools", "wheel"]
    assert "onnxruntime==1.27.0" in manifest["runtime_requirements"]
    assert {entry["filename"] for entry in manifest["wheel_inventory"]} == {
        path.name for path in wheels.glob("*.whl")
    }
    assert all(len(entry["sha256"]) == 64 for entry in manifest["wheel_inventory"])
    assert all(entry["size"] > 0 for entry in manifest["wheel_inventory"])
    builder.audit_existing_manifest(tmp_path)
    print("MACOS_PAYLOAD_CLOSED_WORLD_POSITIVE_TEST=PASS")


def test_drumsep_compat_yaml_payload_inventory_and_audit_are_closed(tmp_path):
    builder = load_builder()
    complete_fake_wheelhouse(tmp_path, builder)
    builder.write_manifest(tmp_path, "2.3.0.5")
    manifest = json.loads((tmp_path / "manifest.json").read_text(encoding="utf-8"))
    inventory = {item["filename"]: item for item in manifest["drumsep_file_inventory"]}
    compat = inventory["config_drumsep_mdx23c.yaml"]
    assert (tmp_path / "drumsep" / compat["filename"]).read_bytes() == builder.DRUMSEP_COMPAT_ASSET.read_bytes()
    assert compat == {
        "filename": "config_drumsep_mdx23c.yaml",
        "role": "compatibility_config",
        "sha256": builder.DRUMSEP_COMPAT_CANONICAL_SHA256,
        "size": builder.DRUMSEP_COMPAT_CANONICAL_SIZE,
        "canonical_payload_newlines": "LF",
        "instruments": list(builder.DRUMSEP_COMPAT_INSTRUMENTS),
        "source_provenance": builder.DRUMSEP_COMPAT_SOURCE_PROVENANCE,
    }
    assert {item["role"] for item in inventory.values()} == {
        "canonical_model", "canonical_config", "compatibility_config"
    }
    builder.audit_existing_manifest(tmp_path)
    manifest_path = tmp_path / "manifest.json"
    tampered_manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    next(
        item for item in tampered_manifest["drumsep_file_inventory"]
        if item["filename"] == builder.DRUMSEP_COMPAT_ASSET.name
    )["canonical_payload_newlines"] = "CRLF"
    manifest_path.write_text(json.dumps(tampered_manifest), encoding="utf-8")
    with pytest.raises(RuntimeError, match="payload_drumsep_inventory_policy_mismatch"):
        builder.audit_existing_manifest(tmp_path)
    builder.write_manifest(tmp_path, "2.3.0.5")

    compat_path = tmp_path / "drumsep" / "config_drumsep_mdx23c.yaml"
    original = compat_path.read_bytes()
    compat_path.write_bytes(b"checksum drift")
    with pytest.raises(RuntimeError, match="payload_drumsep_checksum_mismatch"):
        builder.audit_existing_manifest(tmp_path)
    compat_path.write_bytes(original)
    compat_path.unlink()
    with pytest.raises(RuntimeError, match="payload_drumsep_files_mismatch"):
        builder.audit_existing_manifest(tmp_path)
    compat_path.write_bytes(original)
    (tmp_path / "drumsep" / "unexpected.yaml").write_text("unexpected\n", encoding="utf-8")
    with pytest.raises(RuntimeError, match="payload_drumsep_files_mismatch"):
        builder.audit_existing_manifest(tmp_path)
    print("MACOS_DRUMSEP_COMPAT_YAML_PAYLOAD_TEST=PASS")


def test_drumsep_compat_yaml_canonical_bytes_survive_checkout_policy(tmp_path):
    builder = load_builder()
    asset = builder.DRUMSEP_COMPAT_ASSET
    canonical = asset.read_bytes()
    blob = subprocess.run(
        ["git", "cat-file", "blob", f"HEAD:{asset.as_posix()}"],
        check=True,
        capture_output=True,
    ).stdout
    assert canonical == blob
    assert len(canonical) == builder.DRUMSEP_COMPAT_CANONICAL_SIZE == 2331
    assert hashlib.sha256(canonical).hexdigest() == builder.DRUMSEP_COMPAT_CANONICAL_SHA256
    assert canonical.count(b"\n") == 86
    assert canonical.count(b"\r") == canonical.count(b"\r\n") == 0
    document = yaml.load(canonical.decode("utf-8"), Loader=yaml.FullLoader)
    assert tuple(document["training"]["instruments"]) == builder.DRUMSEP_COMPAT_INSTRUMENTS

    source = canonical.replace(b"\n", b"\r\n")
    assert len(source) == builder.DRUMSEP_COMPAT_SOURCE_PROVENANCE["size"] == 2417
    assert hashlib.sha256(source).hexdigest() == builder.DRUMSEP_COMPAT_SOURCE_PROVENANCE["sha256"]
    assert source.count(b"\r\n") == 86

    attributes = Path(".gitattributes").read_text(encoding="utf-8")
    expected_attribute = f"{asset.as_posix()} text eol=lf whitespace=-blank-at-eol"
    assert expected_attribute in attributes
    assert f"{asset.as_posix()} -whitespace" not in attributes

    source_repo = tmp_path / "source"
    source_repo.mkdir()
    shutil.copy2(Path(".gitattributes"), source_repo / ".gitattributes")
    target = source_repo / asset
    target.parent.mkdir(parents=True)
    target.write_bytes(canonical)
    subprocess.run(["git", "init", "-q"], cwd=source_repo, check=True)
    subprocess.run(["git", "add", ".gitattributes", asset.as_posix()], cwd=source_repo, check=True)
    subprocess.run(
        ["git", "-c", "user.name=STEMwerk Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "fixture"],
        cwd=source_repo,
        check=True,
    )
    for autocrlf in ("false", "true"):
        checkout = tmp_path / f"checkout-{autocrlf}"
        subprocess.run(
            ["git", "-c", f"core.autocrlf={autocrlf}", "clone", "-q", str(source_repo), str(checkout)],
            check=True,
        )
        checked_out = (checkout / asset).read_bytes()
        assert checked_out == canonical
        assert hashlib.sha256(checked_out).hexdigest() == builder.DRUMSEP_COMPAT_CANONICAL_SHA256

    fake_payload = tmp_path / "crlf-payload" / "drumsep"
    fake_payload.mkdir(parents=True)
    (fake_payload / builder.DRUMSEP_FILES[0]).write_bytes(b"checkpoint")
    (fake_payload / builder.DRUMSEP_FILES[1]).write_text("training: {}\n", encoding="utf-8")
    (fake_payload / builder.DRUMSEP_FILES[2]).write_bytes(source)
    with pytest.raises(RuntimeError, match="payload_drumsep_checksum_mismatch"):
        builder.validate_drumsep_files(fake_payload)
    print("MACOS_DRUMSEP_COMPAT_YAML_CANONICAL_BYTES_TEST=PASS")


def test_bootstrap_materializes_and_migrates_drumsep_compat_yaml_atomically(
    tmp_path, monkeypatch
):
    builder = load_builder()
    helper = load_drumsep_helper()
    source_dir = tmp_path / "payload" / "drumsep"
    cache_dir = tmp_path / "models"
    source_dir.mkdir(parents=True)
    canonical = builder.DRUMSEP_COMPAT_ASSET.read_bytes()
    legacy = canonical.replace(b"\n", b"\r\n")
    source = source_dir / builder.DRUMSEP_COMPAT_ASSET.name
    destination = cache_dir / builder.DRUMSEP_COMPAT_ASSET.name
    source.write_bytes(canonical)
    assert len(legacy) == builder.DRUMSEP_COMPAT_SOURCE_PROVENANCE["size"]
    assert hashlib.sha256(legacy).hexdigest() == builder.DRUMSEP_COMPAT_SOURCE_PROVENANCE["sha256"]

    created = run_drumsep_materialization_harness(tmp_path, source_dir, cache_dir)
    assert created.returncode == 0, created.stderr
    assert "result=created:materialized_from_payload::b7165bb7" in created.stdout
    assert destination.read_bytes() == canonical
    created_mtime = destination.stat().st_mtime_ns

    exists = run_drumsep_materialization_harness(tmp_path, source_dir, cache_dir)
    assert exists.returncode == 0, exists.stderr
    assert "result=exists_valid:already_materialized:b7165bb7" in exists.stdout
    assert destination.stat().st_mtime_ns == created_mtime

    canonical_checkpoint = cache_dir / helper.DRUMSEP_MODEL_FILENAME
    checkpoint_alias = cache_dir / helper.ASEP_0443_DRUMSEP_MODEL_FILENAME
    canonical_checkpoint.write_bytes(b"managed-checkpoint")
    checkpoint_alias.write_bytes(canonical_checkpoint.read_bytes())
    checkpoint_before = helper._sha256_file(checkpoint_alias)
    destination.write_bytes(legacy)
    migrated = run_drumsep_materialization_harness(tmp_path, source_dir, cache_dir)
    assert migrated.returncode == 0, migrated.stderr
    assert "result=migrated_legacy_crlf:migrated_known_legacy_crlf:17d1649a" in migrated.stdout
    assert migrated.stdout.rstrip().endswith(builder.DRUMSEP_COMPAT_CANONICAL_SHA256)
    assert destination.read_bytes() == canonical
    assert checkpoint_before == helper._sha256_file(checkpoint_alias)
    migrated_mtime = destination.stat().st_mtime_ns

    network_calls = []
    monkeypatch.setattr(
        "urllib.request.urlopen",
        lambda *args, **kwargs: network_calls.append((args, kwargs))
        or (_ for _ in ()).throw(AssertionError("network forbidden")),
    )
    resolution = helper._resolve_drumsep_catalog_cache_for_runtime(cache_dir, helper.DRUMSEP_MODEL_ALIAS)
    assert resolution.action == "mixed_cache_use_new"
    assert network_calls == []

    after_migration = run_drumsep_materialization_harness(tmp_path, source_dir, cache_dir)
    assert after_migration.returncode == 0
    assert "result=exists_valid:already_materialized:b7165bb7" in after_migration.stdout
    assert destination.stat().st_mtime_ns == migrated_mtime

    destination.write_bytes(b"unknown unmanaged bytes")
    unknown = destination.read_bytes()
    rejected = run_drumsep_materialization_harness(tmp_path, source_dir, cache_dir)
    assert rejected.returncode != 0
    assert "result=failed:existing_checksum_mismatch:" in rejected.stdout
    assert destination.read_bytes() == unknown

    destination.write_bytes(legacy)
    source.write_bytes(b"damaged payload")
    damaged_source = run_drumsep_materialization_harness(tmp_path, source_dir, cache_dir)
    assert damaged_source.returncode != 0
    assert "result=failed:payload_source_integrity_mismatch:" in damaged_source.stdout
    assert destination.read_bytes() == legacy
    source.write_bytes(canonical)

    atomic_failure = run_drumsep_materialization_harness(
        tmp_path, source_dir, cache_dir, extra_shell="mv() { return 1; }\n"
    )
    assert atomic_failure.returncode != 0
    assert "result=failed:atomic_replace_failed:17d1649a" in atomic_failure.stdout
    assert destination.read_bytes() == legacy

    temporary_mismatch = run_drumsep_materialization_harness(
        tmp_path,
        source_dir,
        cache_dir,
        extra_shell='cp() { command cp "$1" "$2" && printf drift >> "$2"; }\n',
    )
    assert temporary_mismatch.returncode != 0
    assert "result=failed:temporary_copy_integrity_mismatch:17d1649a" in temporary_mismatch.stdout
    assert destination.read_bytes() == legacy
    assert not list(cache_dir.glob("*.tmp.*"))
    assert not (tmp_path / "materialize.log.network").exists()
    script = BOOTSTRAP_PATH.read_text(encoding="utf-8")
    bootstrap_section = script.index('materialize_drumsep_compat_yaml "${_bundled_drumsep_dir}"')
    assert bootstrap_section < script.index('ensure_drumsep_assets "${VENV_PY}"')
    print("MACOS_DRUMSEP_COMPAT_YAML_LEGACY_MIGRATION_TEST=PASS")
    print("DRUMSEP_COMPAT_YAML_LEGACY_RUNTIME_GUARD_TEST=PASS")
    print("MACOS_DRUMSEP_COMPAT_YAML_REPAIR_CONVERGENCE_TEST=PASS")


def test_managed_model_legacy_replacement_policy_is_closed():
    builder = load_builder()
    legacy_sha = builder.DRUMSEP_COMPAT_SOURCE_PROVENANCE["sha256"]
    canonical_sha = builder.DRUMSEP_COMPAT_CANONICAL_SHA256
    filename = builder.DRUMSEP_COMPAT_ASSET.name
    alias = "MDX23C-DrumSep-aufr33-jarredou.ckpt"
    canonical_model = builder.DRUMSEP_FILES[0]
    checkpoint_sha = "checkpoint-sha"

    def classify(before, after):
        removed = set(before) - set(after)
        additions = set(after) - set(before)
        changes = {name: (before[name], after[name]) for name in set(before) & set(after) if before[name] != after[name]}
        if removed:
            return "UNMANAGED"
        if additions - {alias, filename}:
            return "UNMANAGED"
        if alias in additions and after[alias] != before.get(canonical_model):
            return "UNMANAGED"
        if filename in additions and after[filename] != canonical_sha:
            return "UNMANAGED"
        if changes and changes != {filename: (legacy_sha, canonical_sha)}:
            return "UNMANAGED"
        return "KNOWN_MANAGED_MIGRATION" if changes else "KNOWN_MANAGED_ADDITIONS"

    before = {canonical_model: checkpoint_sha, filename: legacy_sha}
    after = {canonical_model: checkpoint_sha, filename: canonical_sha, alias: checkpoint_sha}
    assert classify(before, after) == "KNOWN_MANAGED_MIGRATION"
    assert classify(before, {**after, filename: "unknown"}) == "UNMANAGED"
    assert classify(before, {canonical_model: checkpoint_sha}) == "UNMANAGED"
    assert classify(before, {**after, "unexpected.bin": "hash"}) == "UNMANAGED"
    assert classify({canonical_model: checkpoint_sha}, after) == "KNOWN_MANAGED_ADDITIONS"
    print("MACOS_MANAGED_MODEL_LEGACY_REPLACEMENT_TEST=PASS")


def test_native_samplerate_override_contract_passes_with_complete_closure(tmp_path):
    builder = load_builder()
    contract = load_payload_contract()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    builder.write_manifest(tmp_path, "2.3.0.5")
    core, closure = contract.validate_contract(tmp_path / "manifest.json", wheels, list(builder.MAIN_REQUIREMENTS))
    assert core == list(builder.MAIN_REQUIREMENTS)
    assert closure == ["diffq==1.0", f"flatbuffers=={FAKE_FLATBUFFERS_VERSION}", "sympy==1.13.1"]
    print("MACOS_SAMPLERATE_OVERRIDE_PREFLIGHT_POSITIVE_TEST=PASS")


def test_samplerate_override_contract_rejects_missing_override_forbidden_and_missing_closure(tmp_path):
    builder = load_builder()
    contract = load_payload_contract()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    builder.write_manifest(tmp_path, "2.3.0.5")

    samplerate = wheels / wheel_name("samplerate==0.2.4")
    samplerate.unlink()
    with pytest.raises(RuntimeError, match="samplerate_override_missing"):
        contract.validate_contract(tmp_path / "manifest.json", wheels, list(builder.MAIN_REQUIREMENTS))
    samplerate.touch()

    forbidden = wheels / "samplerate-0.1.0-py2.py3-none-any.whl"
    forbidden.touch()
    with pytest.raises(RuntimeError, match="forbidden_samplerate_0_1_0_present"):
        contract.validate_contract(tmp_path / "manifest.json", wheels, list(builder.MAIN_REQUIREMENTS))
    forbidden.unlink()

    closure_wheel = next(wheels.glob("diffq-*.whl"))
    closure_wheel.unlink()
    with pytest.raises(RuntimeError, match="dependency_closure_missing"):
        contract.validate_contract(tmp_path / "manifest.json", wheels, list(builder.MAIN_REQUIREMENTS))
    print("MACOS_SAMPLERATE_OVERRIDE_PREFLIGHT_NEGATIVE_TEST=PASS")


def test_torch_sympy_closure_accepts_1131_and_rejects_native_1140_fixture(tmp_path):
    builder = load_builder()
    contract = load_payload_contract()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    builder.write_manifest(tmp_path, "2.3.0.5")
    contract.validate_contract(tmp_path / "manifest.json", wheels, list(builder.MAIN_REQUIREMENTS))
    assert len(list(wheels.glob("sympy-1.13.1-*.whl"))) == 1
    print("MACOS_TORCH_SYMPY_CLOSURE_POSITIVE_TEST=PASS")

    good = wheels / "sympy-1.13.1-py3-none-any.whl"
    bad = wheels / "sympy-1.14.0-py3-none-any.whl"
    bad.touch()
    with pytest.raises(RuntimeError, match="dependency_closure_core_conflict"):
        builder.validate_closed_world_wheelhouse(wheels)
    bad.unlink()
    good.unlink()
    bad.touch()
    manifest = json.loads((tmp_path / "manifest.json").read_text(encoding="utf-8"))
    manifest["dependency_closure_requirements"] = [
        "diffq==1.0", f"flatbuffers=={FAKE_FLATBUFFERS_VERSION}", "sympy==1.14.0"
    ]
    manifest["wheel_inventory"] = [
        entry for entry in manifest["wheel_inventory"] if not entry["filename"].startswith("sympy-")
    ] + [{"filename": bad.name, "sha256": builder.sha256_file(bad), "size": bad.stat().st_size}]
    (tmp_path / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    with pytest.raises(RuntimeError, match="dependency_closure_core_conflict"):
        contract.validate_contract(tmp_path / "manifest.json", wheels, list(builder.MAIN_REQUIREMENTS))
    print("MACOS_TORCH_SYMPY_CLOSURE_NEGATIVE_TEST=PASS")


def test_core_constrained_resolver_plan_pins_torch_sympy_and_rewrites_only_samplerate(tmp_path):
    builder = load_builder()
    constraints = tmp_path / "resolver-constraints.txt"
    builder.write_core_constrained_resolver_file(constraints)
    lines = constraints.read_text(encoding="utf-8").splitlines()
    assert "torch==2.5.1" in lines
    assert "sympy==1.13.1" in lines
    assert not any(line.startswith("sympy==1.14") for line in lines)
    assert not any(line.startswith("samplerate==") for line in lines)
    assert set(builder.MAIN_REQUIREMENTS) - {"samplerate==0.2.4"} <= set(lines)
    assert set(builder.PINNED_BOOTSTRAP_REQUIREMENTS) <= set(lines)


def test_full_core_closure_resolver_uses_one_exact_core_plan(tmp_path, monkeypatch):
    builder = load_builder()
    calls = []
    monkeypatch.setattr(builder.subprocess, "run", lambda cmd, **kwargs: calls.append(cmd) or subprocess.CompletedProcess(cmd, 0))
    constraints = tmp_path / "constraints.txt"
    constraints.touch()
    builder.run_pip_download_plan(builder.FULL_CORE_RESOLVER_REQUIREMENTS, tmp_path / "resolved", constraints, "python3.12")
    assert len(calls) == 1
    assert "onnxruntime==1.27.0" in calls[0]
    assert "torch==2.5.1" in calls[0]
    assert "audio-separator==0.44.3" in calls[0]
    assert "samplerate==0.2.4" not in calls[0]
    assert set(builder.MAIN_REQUIREMENTS) - {"samplerate==0.2.4"} <= set(calls[0])
    print("MACOS_FULL_CORE_CLOSURE_RESOLVER_TEST=PASS")


def test_onnxruntime_flatbuffers_is_required_in_closed_manifest_and_semantic_gate(tmp_path):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    builder.write_manifest(tmp_path, "2.3.0.5")
    builder.audit_existing_manifest(tmp_path)
    manifest_path = tmp_path / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["dependency_closure_requirements"] = [
        requirement for requirement in manifest["dependency_closure_requirements"]
        if not requirement.startswith("flatbuffers==")
    ]
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    with pytest.raises(RuntimeError, match="payload_dependency_closure_mismatch"):
        builder.audit_existing_manifest(tmp_path)
    builder.write_manifest(tmp_path, "2.3.0.5")
    flatbuffers = next(wheels.glob("flatbuffers-*.whl"))
    flatbuffers.unlink()
    with pytest.raises(RuntimeError, match="dependency_closure_core_conflict"):
        builder.validate_closed_world_wheelhouse(wheels)
    with pytest.raises(RuntimeError, match="payload_core_dependency_unsatisfied.*flatbuffers"):
        builder.validate_core_requires_dist(wheels)
    write_fake_wheel(wheels / "flatbuffers-24.3.25-py2.py3-none-any.whl")
    write_fake_wheel(wheels / "flatbuffers-25.2.10-py2.py3-none-any.whl")
    with pytest.raises(RuntimeError, match="dependency_closure_core_conflict"):
        builder.validate_closed_world_wheelhouse(wheels)
    print("MACOS_ONNXRUNTIME_FLATBUFFERS_CLOSURE_TEST=PASS")


def test_core_requires_dist_gate_handles_bootstrap_override_markers_and_bad_metadata(tmp_path, monkeypatch):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    builder.validate_core_requires_dist(wheels)
    monkeypatch.setattr(builder, "BOOTSTRAP_ALLOWLIST", {"pip", "wheel"})
    with pytest.raises(RuntimeError, match="payload_core_dependency_unsatisfied.*setuptools"):
        builder.validate_core_requires_dist(wheels)
    monkeypatch.setattr(builder, "BOOTSTRAP_ALLOWLIST", {"pip", "setuptools", "wheel"})

    torch = wheels / wheel_name("torch==2.5.1")
    write_fake_wheel(torch, ('missing-inactive; python_version < "3.12"', 'setuptools; python_version >= "3.12"'))
    builder.validate_core_requires_dist(wheels)
    write_fake_wheel(torch, ("malformed requirement @@@",))
    with pytest.raises(RuntimeError, match="payload_core_metadata_invalid"):
        builder.validate_core_requires_dist(wheels)
    with zipfile.ZipFile(torch, "w") as archive:
        archive.writestr("torch-2.5.1.dist-info/WHEEL", "Wheel-Version: 1.0\n")
    with pytest.raises(RuntimeError, match="payload_core_metadata_missing"):
        builder.validate_core_requires_dist(wheels)
    torch.write_bytes(b"not-a-wheel")
    with pytest.raises(RuntimeError, match="payload_core_metadata_invalid"):
        builder.validate_core_requires_dist(wheels)
    print("MACOS_CORE_REQUIRES_DIST_GATE_TEST=PASS")


def test_py312_bootstrap_tools_are_installed_offline_before_core_bundle():
    script = BOOTSTRAP_PATH.read_text(encoding="utf-8")
    tools_command = 'install_with_optional_bundled_wheels "${VENV_PY}" --upgrade pip setuptools wheel'
    assert tools_command in script
    assert script.index(tools_command) < script.index('if ! install_apple_silicon_core_bundle; then')
    assert 'MACOS_BOOTSTRAP_TOOLS_INSTALL_REASON="bootstrap_tools_install_failed"' in script
    assert 'MACOS_BOOTSTRAP_TOOLS_INSTALL_REASON="installed_from_bundled_payload"' in script
    builder = load_builder()
    assert set(builder.BOOTSTRAP_REQUIREMENTS) == {"pip", "setuptools", "wheel"}
    assert set(builder.BOOTSTRAP_REQUIREMENTS) <= builder.BOOTSTRAP_ALLOWLIST
    print("MACOS_PY312_BOOTSTRAP_TOOLS_TEST=PASS")


def test_historical_repair_and_fresh_py312_scenarios_converge_by_policy():
    script = BOOTSTRAP_PATH.read_text(encoding="utf-8")
    body = shell_function(script, "install_apple_silicon_core_bundle")
    tools_command = 'install_with_optional_bundled_wheels "${VENV_PY}" --upgrade pip setuptools wheel'
    cleanup = '"${VENV_PY}" -m pip uninstall -y onnxruntime-silicon samplerate onnx onnx2torch'
    closure = '${MACOS_PAYLOAD_CLOSURE_REQUIREMENTS}'
    core = '"onnxruntime==${PINNED_ONNXRUNTIME_VERSION}"'
    assert script.index(tools_command) < script.index('if ! install_apple_silicon_core_bundle; then')
    assert body.index(cleanup) < body.index(closure) < body.index(core)
    builder = load_builder()
    assert "flatbuffers" in builder.REQUIRED_CLOSURE_PACKAGES
    assert "setuptools" in builder.BOOTSTRAP_ALLOWLIST and "wheel" in builder.BOOTSTRAP_ALLOWLIST


def fake_isolated_core_build_run(builder, calls, failure_stage=None, output_count=1):
    def fake_run(command, **kwargs):
        calls.append(command)
        if command[1:3] == ["-m", "venv"]:
            if failure_stage == "create":
                raise subprocess.CalledProcessError(1, command)
            environment = Path(command[-1])
            build_python = builder.isolated_environment_python(environment)
            build_python.parent.mkdir(parents=True)
            build_python.touch()
        elif "install" in command:
            if failure_stage == "install":
                raise subprocess.CalledProcessError(1, command)
        elif command[1:2] == ["-c"]:
            if failure_stage == "backend":
                raise subprocess.CalledProcessError(1, command)
            return subprocess.CompletedProcess(
                command, 0, stdout="pip=26.1.2 setuptools=83.0.0 wheel=0.45.1\n"
            )
        elif "wheel" in command:
            if failure_stage == "build":
                raise subprocess.CalledProcessError(1, command)
            output = Path(command[command.index("--wheel-dir") + 1])
            for index in range(output_count):
                suffix = "" if index == 0 else f"-{index}"
                (output / f"stemwerk_core-0.1.1{suffix}-py3-none-any.whl").touch()
        return subprocess.CompletedProcess(command, 0)

    return fake_run


def test_payload_builder_isolates_core_build_tools_from_invoking_python(tmp_path, monkeypatch):
    builder = load_builder()
    wheels = tmp_path / "payload" / "wheels"
    wheels.mkdir(parents=True)
    invoking_python = tmp_path / "production-like" / "python"
    invoking_python.parent.mkdir()
    invoking_python.write_bytes(b"python-with-pip-only")
    original = invoking_python.read_bytes()
    calls = []
    monkeypatch.setattr(builder.subprocess, "run", fake_isolated_core_build_run(builder, calls))

    produced = builder.build_stemwerk_core_wheel(Path.cwd(), wheels, str(invoking_python))

    assert produced.name == "stemwerk_core-0.1.1-py3-none-any.whl"
    assert invoking_python.read_bytes() == original
    assert not list((tmp_path / "payload").glob(".stemwerk-core-build-*"))
    invoking_calls = [command for command in calls if command[0] == str(invoking_python)]
    assert len(invoking_calls) == 1 and invoking_calls[0][1:3] == ["-m", "venv"]
    install = next(command for command in calls if "install" in command)
    assert install[0] != str(invoking_python)
    assert "--no-index" in install and "--find-links" in install
    assert tuple(install[-3:]) == builder.PINNED_BOOTSTRAP_REQUIREMENTS
    assert builder.BOOTSTRAP_VERSION_POLICY == {
        "pip": "26.1.2", "setuptools": "83.0.0", "wheel": "0.45.1"
    }
    print("MACOS_PAYLOAD_BUILDER_ISOLATED_CORE_BUILD_TEST=PASS")


def test_payload_builder_core_backend_guards_and_cleanup(tmp_path, monkeypatch):
    builder = load_builder()
    invoking_python = str(tmp_path / "production-like-python")
    cases = (
        ("create", 1, "core_build_environment_create_failed"),
        ("install", 1, "core_build_tools_install_failed"),
        ("backend", 1, "core_build_backend_unavailable"),
        ("build", 1, "core_wheel_build_failed"),
        (None, 0, "core_wheel_missing"),
        (None, 2, "core_wheel_ambiguous"),
    )
    for index, (failure_stage, output_count, reason) in enumerate(cases):
        case_root = tmp_path / f"case-{index}"
        wheels = case_root / "wheels"
        wheels.mkdir(parents=True)
        calls = []
        monkeypatch.setattr(
            builder.subprocess, "run",
            fake_isolated_core_build_run(builder, calls, failure_stage, output_count),
        )
        with pytest.raises(RuntimeError, match=reason):
            builder.build_stemwerk_core_wheel(Path.cwd(), wheels, invoking_python)
        assert not list(case_root.glob(".stemwerk-core-build-*"))
        assert not any(command[0] == invoking_python and "install" in command for command in calls)

    monkeypatch.setattr(
        builder.tempfile, "TemporaryDirectory",
        lambda **kwargs: (_ for _ in ()).throw(OSError("denied")),
    )
    with pytest.raises(RuntimeError, match="core_build_environment_create_failed"):
        builder.build_stemwerk_core_wheel(tmp_path, tmp_path / "temp-failure" / "wheels", invoking_python)
    source = BUILDER_PATH.read_text(encoding="utf-8")
    assert "pip install setuptools wheel" not in source
    assert "manually" not in source.lower()
    print("MACOS_PAYLOAD_BUILDER_CORE_BACKEND_GUARD_TEST=PASS")


def test_override_aware_shell_preflight_harness_exits_zero_before_mutation(tmp_path):
    bash = Path(r"C:\Program Files\Git\bin\bash.exe")
    if not bash.is_file():
        pytest.skip("native Git Bash not available")
    builder = load_builder()
    payload_root = tmp_path / "payload"
    payload_root.mkdir()
    wheels = complete_fake_wheelhouse(payload_root, builder)
    builder.write_manifest(wheels.parent, "2.3.0.5")
    helper = tmp_path / "stemwerk_macos_payload_contract.py"
    shutil.copy2(PAYLOAD_CONTRACT_PATH, helper)

    def git_bash_path(path: Path) -> str:
        result = subprocess.run(
            [str(bash), "-lc", f"cygpath -u '{path.as_posix()}'"],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()

    fake_python = tmp_path / "payload-python"
    host_python = git_bash_path(Path(sys.executable))
    fake_python.write_text(
        "#!/bin/sh\n"
        'if [ "${1:-}" = "-m" ]; then exit 0; fi\n'
        f"exec '{host_python}' \"$@\"\n",
        encoding="utf-8",
    )
    fake_python.chmod(0o755)
    harness = tmp_path / "preflight-harness.sh"
    pins = {
        "AUDIO_SEPARATOR": "0.44.3", "NUMPY": "2.4.4", "SCIPY": "1.18.0",
        "NUMBA": "0.66.0", "LLVM": "0.48.0", "TORCH": "2.5.1",
        "TORCHAUDIO": "2.5.1", "TORCHVISION": "0.20.1", "SAMPLERATE": "0.2.4",
        "ONNXRUNTIME": "1.27.0",
    }
    assignments = "\n".join(f'PINNED_{name}_VERSION="{version}"' for name, version in pins.items())
    harness.write_text(
        "#!/bin/sh\nset -u\n"
        + shell_function(BOOTSTRAP_PATH.read_text(encoding="utf-8"), "preflight_bundled_apple_silicon_payload").join(
            ("preflight_bundled_apple_silicon_payload() {\n", "\n}\n")
        )
        + assignments + "\n"
        + f"RUNTIME_BASE='{git_bash_path(tmp_path / 'runtime')}'\n"
        + f"LOG_FILE='{git_bash_path(tmp_path / 'bootstrap.log')}'\n"
        + f"BUNDLED_PAYLOAD_DIR='{git_bash_path(wheels.parent)}'\n"
        + f"MACOS_PAYLOAD_CONTRACT_HELPER='{git_bash_path(helper)}'\n"
        + 'MACOS_PAYLOAD_PREFLIGHT_STATUS="failed"\n'
        + 'MACOS_PAYLOAD_PREFLIGHT_REASON="not_run"\n'
        + 'MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED="false"\n'
        + f"preflight_bundled_apple_silicon_payload '{git_bash_path(fake_python)}' '{git_bash_path(wheels)}'\n"
        + 'printf "status=%s\\nreason=%s\\nmutation=%s\\n" "$MACOS_PAYLOAD_PREFLIGHT_STATUS" "$MACOS_PAYLOAD_PREFLIGHT_REASON" "$MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED"\n',
        encoding="utf-8",
    )
    result = subprocess.run([str(bash), git_bash_path(harness)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert "status=ok" in result.stdout
    assert "reason=resolved_with_native_override" in result.stdout
    assert "mutation=false" in result.stdout


def test_manifest_audit_rejects_missing_wheel_and_checksum_drift(tmp_path):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    builder.write_manifest(tmp_path, "2.3.0.5")
    victim = wheels / wheel_name("numpy==2.4.4")
    victim.write_bytes(b"changed")

    with pytest.raises(RuntimeError, match="payload_checksum_mismatch"):
        builder.audit_existing_manifest(tmp_path)

    assert victim.is_file()


def test_resolver_audit_is_non_mutating_and_uses_only_wheelhouse(tmp_path, monkeypatch):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    sentinel = tmp_path / "existing-torch-stack.sentinel"
    sentinel.write_text("torch=2.5.1\n", encoding="utf-8")
    calls = []

    def fake_run(cmd, **kwargs):
        calls.append(cmd)
        raise builder.subprocess.CalledProcessError(1, cmd, "missing llvmlite")

    monkeypatch.setattr(builder.subprocess, "run", fake_run)
    with pytest.raises(builder.subprocess.CalledProcessError):
        builder.audit_wheelhouse_resolution(wheels, "python3.12")

    command = calls[0]
    assert "--dry-run" in command
    assert "--ignore-installed" in command
    assert "--no-index" in command
    assert "--find-links" in command
    assert "uninstall" not in command
    assert sentinel.read_text(encoding="utf-8") == "torch=2.5.1\n"


def test_complete_wheelhouse_resolver_preflight_allows_install_path_to_start(tmp_path, monkeypatch):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    calls = []

    def fake_run(cmd, **kwargs):
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(builder.subprocess, "run", fake_run)
    builder.audit_wheelhouse_resolution(wheels, "python3.12")

    assert calls
    assert "--no-deps" in calls[0]
    assert set(builder.MAIN_REQUIREMENTS) <= set(calls[0])
    assert "sympy==1.13.1" in calls[0]


@pytest.mark.parametrize(
    "filename",
    [
        "samplerate-0.1.0-py2.py3-none-any.whl",
        "numpy-2.4.6-cp312-cp312-macosx_12_0_arm64.whl",
        "torch-2.13.0-cp312-cp312-macosx_12_0_arm64.whl",
        "torchvision-0.28.0-cp312-cp312-macosx_12_0_arm64.whl",
    ],
)
def test_closed_world_rejects_alternative_core_versions(tmp_path, filename):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    (wheels / filename).touch()
    reason = "payload_forbidden_samplerate_0_1_0" if filename.startswith("samplerate-") else "payload_core_version_exclusivity"
    with pytest.raises(RuntimeError, match=reason):
        builder.validate_closed_world_wheelhouse(wheels)


def test_proven_native_extra_wheel_fixture_fails_even_when_resolver_passes(tmp_path, monkeypatch):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    for filename in (
        "samplerate-0.1.0-py2.py3-none-any.whl",
        "numpy-2.4.6-cp312-cp312-macosx_12_0_arm64.whl",
        "torch-2.13.0-cp312-cp312-macosx_12_0_arm64.whl",
        "torchvision-0.28.0-cp312-cp312-macosx_12_0_arm64.whl",
    ):
        (wheels / filename).touch()
    monkeypatch.setattr(builder.subprocess, "run", lambda cmd, **kwargs: subprocess.CompletedProcess(cmd, 0))
    builder.audit_wheelhouse_resolution(wheels, "python3.12")
    with pytest.raises(RuntimeError, match="payload_forbidden_samplerate_0_1_0"):
        builder.validate_closed_world_wheelhouse(wheels)
    print("MACOS_PAYLOAD_CLOSED_WORLD_NEGATIVE_TEST=PASS")


def test_manifest_closed_world_rejects_extra_and_missing_non_core_wheels(tmp_path):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    builder.write_manifest(tmp_path, "2.3.0.5")
    extra = wheels / "extra_dependency-1.0-py3-none-any.whl"
    extra.touch()
    with pytest.raises(RuntimeError, match="payload_extra_wheels"):
        builder.audit_existing_manifest(tmp_path)
    extra.unlink()
    victim = next(wheels.glob("stemwerk_core-*.whl"))
    victim.unlink()
    with pytest.raises(RuntimeError, match="payload_missing_wheels"):
        builder.audit_existing_manifest(tmp_path)


def test_manifest_rejects_duplicate_entry_and_unexpected_archive(tmp_path):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    builder.write_manifest(tmp_path, "2.3.0.5")
    manifest_path = tmp_path / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["wheel_inventory"].append(dict(manifest["wheel_inventory"][0]))
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    with pytest.raises(RuntimeError, match="payload_manifest_duplicate"):
        builder.audit_existing_manifest(tmp_path)
    manifest["wheel_inventory"].pop()
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    (wheels / "unexpected.tar.gz").touch()
    with pytest.raises(RuntimeError, match="payload_unexpected_artifacts"):
        builder.audit_existing_manifest(tmp_path)


def test_manifest_rejects_case_collision(tmp_path):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    builder.write_manifest(tmp_path, "2.3.0.5")
    manifest_path = tmp_path / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    collision = dict(manifest["wheel_inventory"][0])
    collision["filename"] = collision["filename"].upper()
    manifest["wheel_inventory"].append(collision)
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    with pytest.raises(RuntimeError, match="payload_manifest_duplicate"):
        builder.audit_existing_manifest(tmp_path)


def test_duplicate_allowed_core_version_with_different_tag_is_rejected(tmp_path):
    builder = load_builder()
    wheels = complete_fake_wheelhouse(tmp_path, builder)
    (wheels / "numpy-2.4.4-cp312-cp312-macosx_11_0_universal2.whl").touch()
    with pytest.raises(RuntimeError, match="payload_core_version_exclusivity"):
        builder.validate_closed_world_wheelhouse(wheels)


def test_reset_dir_removes_only_selected_payload_root(tmp_path):
    builder = load_builder()
    output = tmp_path / "payload"
    outside = tmp_path / "keep.txt"
    output.mkdir()
    (output / "stale.whl").touch()
    outside.write_text("keep", encoding="utf-8")
    builder.reset_dir(output)
    assert output.is_dir() and not any(output.iterdir())
    assert outside.read_text(encoding="utf-8") == "keep"


def test_non_empty_output_requires_explicit_clean_and_fresh_output_passes(tmp_path):
    builder = load_builder()
    output = tmp_path / "payload"
    output.mkdir()
    (output / "stale.whl").touch()
    with pytest.raises(RuntimeError, match="existing_payload_requires_clean_output"):
        builder.prepare_output_dir(output, clean_output=False)
    assert (output / "stale.whl").is_file()
    builder.prepare_output_dir(output, clean_output=True)
    assert output.is_dir() and not any(output.iterdir())
    fresh = tmp_path / "fresh"
    builder.prepare_output_dir(fresh, clean_output=False)
    assert fresh.is_dir() and not any(fresh.iterdir())


def test_resolver_projection_discards_alternative_core_candidates(tmp_path):
    builder = load_builder()
    resolved = tmp_path / "resolved"
    selected = tmp_path / "selected"
    resolved.mkdir()
    for filename in (
        "samplerate-0.1.0-py2.py3-none-any.whl",
        wheel_name("samplerate==0.2.4"),
        "numpy-2.4.6-cp312-cp312-macosx_12_0_arm64.whl",
        wheel_name("numpy==2.4.4"),
        "some_dependency-1.0-py3-none-any.whl",
    ):
        (resolved / filename).touch()
    builder.project_resolved_wheels(resolved, selected)
    assert {path.name for path in selected.glob("*.whl")} == {
        wheel_name("samplerate==0.2.4"),
        wheel_name("numpy==2.4.4"),
        "some_dependency-1.0-py3-none-any.whl",
    }


def test_apple_silicon_repair_uses_one_complete_exact_offline_core_transaction():
    script = BOOTSTRAP_PATH.read_text(encoding="utf-8")
    body = shell_function(script, "install_apple_silicon_core_bundle")

    assert body.count('"${VENV_PY}" -m pip install') == 2
    assert '--upgrade --no-cache-dir --no-index --find-links "${BUNDLED_WHEELS_DIR}" --only-binary=:all: --no-deps' in body
    assert body.count('"audio-separator==${PINNED_AUDIO_SEPARATOR_VERSION}"') == 1
    assert "${MACOS_PAYLOAD_CLOSURE_REQUIREMENTS}" in body
    assert 'if [ "${MAC_ARCH}" = "arm64" ] && [ "${MACOS_PAYLOAD_PREFLIGHT_STATUS}" = "ok" ]; then' in script
    for requirement in CORE_BUNDLE:
        name, version = requirement.split("==")
        variable = {
            "audio-separator": "AUDIO_SEPARATOR",
            "llvmlite": "LLVM",
        }.get(name, name.replace("-", "_").upper())
        token = f'"{name}==${{PINNED_{variable}_VERSION}}"'
        assert token in body

    assert "https://" not in body
    assert '"${VENV_PY}" -m pip show onnxruntime-silicon samplerate onnx onnx2torch' in body
    assert '"${VENV_PY}" -m pip uninstall -y onnxruntime-silicon samplerate onnx onnx2torch' in body


def test_arm64_requires_bundled_payload_before_mutation(tmp_path):
    result, state, sentinel, invoked = run_arm64_payload_gate_fixture(tmp_path, "missing")
    assert result.returncode != 0
    assert "STATUS_REASON=apple_silicon_requires_bundled_payload" in state
    assert "MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED=false" in state
    assert sentinel.read_text(encoding="utf-8") == "preserved\n"
    assert not (sentinel.parents[1] / "bin").exists()
    assert not (sentinel.parents[1] / "python").exists()
    assert not invoked.exists()
    print("MACOS_APPLE_SILICON_BUNDLED_PAYLOAD_REQUIRED_TEST=PASS")


def test_damaged_arm64_payload_without_wheelhouse_fails_before_mutation(tmp_path):
    result, state, sentinel, invoked = run_arm64_payload_gate_fixture(tmp_path, "damaged")
    assert result.returncode != 0
    assert "STATUS_REASON=payload_preflight_failed" in state
    assert "MACOS_PAYLOAD_PREFLIGHT_REASON=wheelhouse_missing" in state
    assert "MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED=false" in state
    assert sentinel.read_text(encoding="utf-8") == "preserved\n"
    assert not (sentinel.parents[1] / "bin").exists()
    assert not (sentinel.parents[1] / "python").exists()
    assert not invoked.exists()
    print("MACOS_DAMAGED_PAYLOAD_WHEELHOUSE_GUARD_TEST=PASS")


def test_bounded_stale_package_cleanup_is_exact_and_before_closure_install():
    script = BOOTSTRAP_PATH.read_text(encoding="utf-8")
    body = shell_function(script, "install_apple_silicon_core_bundle")
    cleanup = '"${VENV_PY}" -m pip uninstall -y onnxruntime-silicon samplerate onnx onnx2torch'
    closure = 'Installing manifest-defined audio-separator dependency closure'
    assert cleanup in body
    assert body.index(cleanup) < body.index(closure)
    assert "pip freeze" not in body and "pip list --format" not in body
    assert 'MACOS_STALE_PACKAGE_CLEANUP_REASON="removed_or_absent"' in body
    assert 'MACOS_STALE_PACKAGE_CLEANUP_REASON="bounded_uninstall_failed"' in body
    cleanup_failure = body[body.index(f"if ! {cleanup}") : body.index("  fi", body.index(f"if ! {cleanup}"))]
    assert 'MACOS_CORE_BUNDLE_INSTALL_REASON="bounded_stale_package_cleanup_failed"' in cleanup_failure
    assert "return 1" in cleanup_failure
    call = 'if ! install_apple_silicon_core_bundle; then'
    assert script.rfind('MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED="true"', 0, script.index(call)) != -1
    assert 'if [ "${MAC_ARCH}" = "arm64" ] && [ "${MACOS_PAYLOAD_PREFLIGHT_STATUS}" = "ok" ]; then' in script
    print("MACOS_BOUNDED_STALE_PACKAGE_CLEANUP_TEST=PASS")
    print("MACOS_EXPANDED_BOUNDED_CLEANUP_TEST=PASS")


@pytest.mark.parametrize(
    ("installed", "target"),
    [("0.23.0", "0.44.3"), ("1.17.1", "1.18.0"), ("0.1.0", "0.2.4")],
)
def test_importable_old_package_is_still_offered_to_exact_bundle_transaction(installed, target):
    # Installed/importable state is deliberately irrelevant: repair always submits all exact pins to pip.
    submitted = {item.split("==", 1)[0]: item.split("==", 1)[1] for item in CORE_BUNDLE}
    package = {"0.23.0": "audio-separator", "1.17.1": "scipy", "0.1.0": "samplerate"}[installed]
    assert submitted[package] == target


def test_old_2304_fingerprint_executes_single_full_bundle_command():
    old = {
        "audio-separator": "0.23.0", "numpy": "1.26.4", "scipy": "1.17.1",
        "numba": "0.59.1", "llvmlite": "0.42.0", "torch": "2.5.1",
        "torchaudio": "2.5.1", "torchvision": "0.20.1", "samplerate": "0.2.4",
    }
    calls = []

    def fake_pip_install(requirements):
        calls.append(tuple(requirements))

    # The coherent repair path does not branch on imports or the old fingerprint.
    assert old["audio-separator"] and old["scipy"] and old["samplerate"]
    fake_pip_install(CORE_BUNDLE)
    assert calls == [CORE_BUNDLE]


def test_final_bundle_fingerprint_and_failure_reason_are_general_not_torch_only():
    script = BOOTSTRAP_PATH.read_text(encoding="utf-8")
    assertion = shell_function(script, "assert_pinned_torch_stack")
    for name, version in (item.split("==", 1) for item in CORE_BUNDLE):
        if name in {"scipy", "samplerate", "onnxruntime"}:
            assert f'expected_{name} = "${{PINNED_{name.upper()}_VERSION}}"' in assertion
            assert f'add_failure("{name}", expected_{name}' in assertion
    assert 'set_status "deps_failed" "core_bundle_pin_assert_failed"' in script


def test_bootstrap_incomplete_payload_fails_before_existing_runtime_mutation(tmp_path):
    bash = Path(r"C:\Program Files\Git\bin\bash.exe")
    if not bash.is_file():
        pytest.skip("native Git Bash not available")

    script_dir = tmp_path / "reaper"
    script_dir.mkdir()
    bootstrap = script_dir / "STEMwerk_Bootstrap_macOS.sh"
    shutil.copy2(Path("scripts/reaper/STEMwerk_Bootstrap_macOS.sh"), bootstrap)
    shutil.copy2(Path("scripts/reaper/audio_separator_process.py"), script_dir / "audio_separator_process.py")
    internal = script_dir / "_internal"
    internal.mkdir()
    shutil.copy2(Path("scripts/reaper/_internal/stemwerk_samplerate_guard.py"), internal / "stemwerk_samplerate_guard.py")
    shutil.copy2(PAYLOAD_CONTRACT_PATH, internal / "stemwerk_macos_payload_contract.py")
    wheelhouse = script_dir / "_bundled" / "macos" / "apple-silicon" / "wheels"
    wheelhouse.mkdir(parents=True)
    (wheelhouse / "torch-2.5.1-cp312-none-macosx_11_0_arm64.whl").touch()

    runtime = tmp_path / "runtime"
    fake_python = runtime / ".venv" / "bin" / "python"
    fake_python.parent.mkdir(parents=True)
    sentinel = runtime / ".venv" / "existing-torch-stack.sentinel"
    sentinel.write_text("torch=2.5.1\n", encoding="utf-8")
    pip_log = tmp_path / "fake-pip.log"
    fake_python.write_text(
        "#!/bin/sh\n"
        'printf "%s\\n" "$*" >> "$FAKE_PIP_LOG"\n'
        "exit 23\n",
        encoding="utf-8",
    )

    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    fake_uname = fake_bin / "uname"
    fake_uname.write_text("#!/bin/sh\nprintf 'arm64\\n'\n", encoding="utf-8")

    def git_bash_path(path: Path) -> str:
        result = subprocess.run(
            [str(bash), "-lc", f"cygpath -u '{path.as_posix()}'"],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()

    state = tmp_path / "state.env"
    log = tmp_path / "bootstrap.log"
    command = (
        f"PATH='{git_bash_path(fake_bin)}':$PATH "
        f"FAKE_PIP_LOG='{git_bash_path(pip_log)}' "
        f"'{git_bash_path(bootstrap)}' "
        f"--runtime-base '{git_bash_path(runtime)}' "
        f"--state-file '{git_bash_path(state)}' "
        f"--log-file '{git_bash_path(log)}' --mode repair"
    )
    result = subprocess.run([str(bash), "-lc", command], capture_output=True, text=True)

    assert result.returncode != 0
    assert sentinel.read_text(encoding="utf-8") == "torch=2.5.1\n"
    assert fake_python.is_file()
    pip_command = pip_log.read_text(encoding="utf-8")
    assert "stemwerk_macos_payload_contract.py" in pip_command
    assert "pip uninstall" not in pip_command
    state_text = state.read_text(encoding="utf-8")
    assert "STATUS=deps_failed" in state_text
    assert "STATUS_REASON=payload_preflight_failed" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_STATUS=failed" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_REASON=override_contract_invalid" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED=false" in state_text


def test_staged_layout_resolves_prefetch_script_independent_of_cwd(tmp_path):
    script_dir = tmp_path / "repair-stage" / "reaper"
    wheels = script_dir / "_bundled" / "macos" / "apple-silicon" / "wheels"
    wheels.mkdir(parents=True)
    for relative in (
        "STEMwerk_Bootstrap_macOS.sh",
        "audio_separator_process.py",
        "_internal/stemwerk_samplerate_guard.py",
        "_internal/stemwerk_macos_payload_contract.py",
    ):
        target = script_dir / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.touch()
    (wheels.parent / "manifest.json").write_text("{}\n", encoding="utf-8")

    canonical = script_dir.resolve()
    assert (canonical / "audio_separator_process.py").is_file()
    assert (canonical / "_internal" / "stemwerk_samplerate_guard.py").is_file()
    assert (canonical / "_internal" / "stemwerk_macos_payload_contract.py").is_file()
    assert (canonical / "_bundled" / "macos" / "apple-silicon" / "manifest.json").is_file()
    assert wheels.is_dir()
    assert canonical != tmp_path.resolve()


def test_missing_prefetch_sibling_fails_layout_preflight_before_python():
    script = BOOTSTRAP_PATH.read_text(encoding="utf-8")
    layout = shell_function(script, "validate_required_reaper_layout")
    prefetch = shell_function(script, "ensure_drumsep_assets")

    assert 'DRUMSEP_PREFETCH_SCRIPT_PATH="${SCRIPT_DIR}/audio_separator_process.py"' in layout
    assert 'REQUIRED_SCRIPT_STATUS="missing"' in layout
    assert 'DRUMSEP_PREFETCH_DETAIL="drumsep_prefetch_script_missing"' in prefetch
    assert script.index("validate_required_reaper_layout") < script.index('MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED="true"')
    assert prefetch.index('[ ! -f "${DRUMSEP_PREFETCH_SCRIPT_PATH}" ]') < prefetch.index('"${_py}" - <<PY')


def test_missing_prefetch_sibling_actual_bootstrap_stops_before_python(tmp_path):
    bash = Path(r"C:\Program Files\Git\bin\bash.exe")
    if not bash.is_file():
        pytest.skip("native Git Bash not available")
    script_dir = tmp_path / "repair-stage" / "reaper"
    script_dir.mkdir(parents=True)
    bootstrap = script_dir / "STEMwerk_Bootstrap_macOS.sh"
    shutil.copy2(BOOTSTRAP_PATH, bootstrap)
    runtime = tmp_path / "runtime"
    python = runtime / ".venv" / "bin" / "python"
    python.parent.mkdir(parents=True)
    invoked = tmp_path / "python-invoked"
    python.write_text(f"#!/bin/sh\ntouch '{invoked.as_posix()}'\nexit 0\n", encoding="utf-8")
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "uname").write_text("#!/bin/sh\nprintf 'arm64\\n'\n", encoding="utf-8")

    def posix(path: Path) -> str:
        return subprocess.run(
            [str(bash), "-lc", f"cygpath -u '{path.as_posix()}'"],
            check=True, capture_output=True, text=True,
        ).stdout.strip()

    state = tmp_path / "state.env"
    log = tmp_path / "bootstrap.log"
    command = (
        f"PATH='{posix(fake_bin)}':$PATH '{posix(bootstrap)}' "
        f"--runtime-base '{posix(runtime)}' --state-file '{posix(state)}' "
        f"--log-file '{posix(log)}' --mode repair"
    )
    result = subprocess.run([str(bash), "-lc", command], capture_output=True, text=True)
    assert result.returncode != 0
    assert not invoked.exists()
    state_text = state.read_text(encoding="utf-8")
    assert "STATUS_REASON=required_script_missing" in state_text
    assert "DRUMSEP_PREFETCH_SCRIPT_STATUS=missing" in state_text
    assert "MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED=false" in state_text


def test_prefetch_import_uses_validated_absolute_script_path():
    script = BOOTSTRAP_PATH.read_text(encoding="utf-8")
    prefetch = shell_function(script, "ensure_drumsep_assets")
    assert 'script_path = Path(r"${DRUMSEP_PREFETCH_SCRIPT_PATH}")' in prefetch
    assert 'Path(r"${SCRIPT_DIR}") / "audio_separator_process.py"' not in prefetch


def test_samplerate_native_override_keeps_strict_pip_check_for_other_conflicts():
    check = shell_function(BOOTSTRAP_PATH.read_text(encoding="utf-8"), "check_runtime_dependencies")
    assert '"${VENV_PY}" -m pip check' in check
    assert "apple_silicon_samplerate_native_override" in check
    assert 'PIP_CHECK_STATUS="failed"' in check
    assert 'PIP_CHECK_REASON="dependency_conflict"' in check


def test_pip_check_parser_accepts_only_single_samplerate_override(tmp_path):
    bash = Path(r"C:\Program Files\Git\bin\bash.exe")
    if not bash.is_file():
        pytest.skip("native Git Bash not available")

    def posix(path: Path) -> str:
        result = subprocess.run(
            [str(bash), "-lc", f"cygpath -u '{path.as_posix()}'"], check=True, capture_output=True, text=True
        )
        return result.stdout.strip()

    fake_python = tmp_path / "fake-python"
    fake_python.write_text('#!/bin/sh\ncat "$FAKE_PIP_CHECK_FILE"\nexit 1\n', encoding="utf-8")
    fake_python.chmod(0o755)
    harness = tmp_path / "pip-check-harness.sh"
    body = shell_function(BOOTSTRAP_PATH.read_text(encoding="utf-8"), "check_runtime_dependencies")
    harness.write_text(
        "#!/bin/sh\nset -u\ncheck_runtime_dependencies() {\n"
        + body
        + "\n}\nlog() { :; }\n"
        + f"RUNTIME_BASE='{posix(tmp_path / 'runtime')}'\nmkdir -p \"$RUNTIME_BASE/logs\"\n"
        + f"VENV_PY='{posix(fake_python)}'\nMAC_ARCH=arm64\nFAKE_PIP_CHECK_FILE=\"$1\"\nexport FAKE_PIP_CHECK_FILE\n"
        + 'check_runtime_dependencies\nrc=$?\nprintf "rc=%s\\nstatus=%s\\nreason=%s\\n" "$rc" "$PIP_CHECK_STATUS" "$PIP_CHECK_REASON"\n',
        encoding="utf-8",
    )
    override = tmp_path / "override.txt"
    override.write_text(
        "audio-separator 0.44.3 has requirement samplerate==0.1.0, but you have samplerate 0.2.4.\n",
        encoding="utf-8",
    )
    conflict = tmp_path / "conflict.txt"
    conflict.write_text(
        override.read_text(encoding="utf-8")
        + "torch 2.5.1 has requirement sympy==1.13.1, but you have sympy 1.14.0.\n",
        encoding="utf-8",
    )
    accepted = subprocess.run([str(bash), posix(harness), posix(override)], capture_output=True, text=True)
    rejected = subprocess.run([str(bash), posix(harness), posix(conflict)], capture_output=True, text=True)
    assert "rc=0" in accepted.stdout
    assert "reason=apple_silicon_samplerate_native_override" in accepted.stdout
    assert "rc=1" in rejected.stdout
    assert "reason=dependency_conflict" in rejected.stdout
    print("MACOS_PIP_CHECK_SINGLE_OVERRIDE_TEST=PASS")


def test_samplerate_guard_is_validate_only_before_ready_state():
    script = BOOTSTRAP_PATH.read_text(encoding="utf-8")
    guard = Path("scripts/reaper/_internal/stemwerk_samplerate_guard.py").read_text(encoding="utf-8")
    assert "--validate-only" in script
    assert 'parser.add_argument("--validate-only", action="store_true")' in guard
    assert '"samplerate_import_failed"' in guard
    assert 'samplerate.resample(np.zeros(32, dtype=np.float32), 1.0, "sinc_best")' in guard
    assert '"samplerate_native_probe_failed"' in guard
    assert script.index('repair_samplerate_if_arch_mismatch "pre_final_dependency_verification"') < script.index(
        'write_ready_to_go_state "${READY_RUNTIME_KIND}"'
    )


def test_validate_only_samplerate_guard_rejects_x86_only_native_payload(monkeypatch, capsys):
    guard = load_samplerate_guard()
    probe = {
        "samplerate_import": "ok",
        "samplerate_function_probe": "ok",
        "samplerate_dylib_x86_only_count": "1",
        "samplerate_dylib_arm_or_universal_count": "0",
        "samplerate_dylib_candidate_count": "1",
    }
    monkeypatch.setattr(guard.sys, "platform", "darwin")
    monkeypatch.setattr(guard.platform, "machine", lambda: "arm64")
    monkeypatch.setattr(guard, "_probe_samplerate", lambda: probe)
    monkeypatch.setattr(guard, "_check_audio_separator_import", lambda: (True, ""))
    monkeypatch.setattr(guard.sys, "argv", [str(SAMPLERATE_GUARD_PATH), "--validate-only"])

    assert guard.main() == 22
    output = capsys.readouterr().out
    assert "error=samplerate_arch_mismatch_requires_runtime_rebuild" in output
    assert "repair_attempted=no" in output


def test_validate_only_samplerate_guard_accepts_arm_native_function_probe(monkeypatch, capsys):
    guard = load_samplerate_guard()
    probe = {
        "samplerate_import": "ok",
        "samplerate_function_probe": "ok",
        "samplerate_dylib_x86_only_count": "0",
        "samplerate_dylib_arm_or_universal_count": "1",
        "samplerate_dylib_candidate_count": "1",
    }
    monkeypatch.setattr(guard.sys, "platform", "darwin")
    monkeypatch.setattr(guard.platform, "machine", lambda: "arm64")
    monkeypatch.setattr(guard, "_probe_samplerate", lambda: probe)
    monkeypatch.setattr(guard, "_check_audio_separator_import", lambda: (True, ""))
    monkeypatch.setattr(guard.sys, "argv", [str(SAMPLERATE_GUARD_PATH), "--validate-only"])

    assert guard.main() == 0
    output = capsys.readouterr().out
    assert "arch_match=yes" in output
    assert "repair_attempted=no" in output
