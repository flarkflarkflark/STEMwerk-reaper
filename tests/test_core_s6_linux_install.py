"""Tests for the S6 Linux Direct Kit CPU installation slice."""

from __future__ import annotations

import base64
from contextlib import contextmanager
import dataclasses
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import uuid
import zipfile

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import (  # noqa: E402
    asset_materialization,
    asset_preparation,
    drumsep_runtime,
    install_preflight,
    managed_python,
    managed_runtime,
    model_assets,
    module_descriptors,
    module_installer,
    module_registry,
    module_verify,
    install_events,
    install_journal,
    install_lock,
    runtime_manifest,
    subprocess_policy,
    wheel_lock,
)

pytestmark = pytest.mark.portable
POSIX_ONLY = pytest.mark.skipif(os.name == "nt", reason="POSIX mode bits and symlinks")


def _private_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    if os.name != "nt":
        for p in [path, *path.parents]:
            try:
                st = p.stat()
                if st.st_uid == os.geteuid() and (st.st_mode & 0o022) and not (st.st_mode & 0o1000):
                    p.chmod(st.st_mode & ~0o022)
            except OSError:
                break
        path.chmod(0o700)
    return path


def _make_fake_managed_python(root: Path, platform_id: str = "linux-x86_64") -> Path:
    rec = runtime_manifest.python_record(platform_id)
    py_dir = runtime_manifest.published_directory(root, rec)
    (py_dir / "lib" / "python3.12").mkdir(parents=True, exist_ok=True)
    (py_dir / "lib" / "python3.12" / "os.py").write_text("# stdlib\n", encoding="utf-8")
    interp = managed_python.interpreter_path(py_dir, platform_id)
    interp.parent.mkdir(parents=True, exist_ok=True)
    interp.write_bytes(b"#!/bin/sh\nexit 0\n")
    if os.name != "nt":
        interp.chmod(0o755)
        for p in [py_dir, *py_dir.rglob("*")]:
            if not p.is_symlink():
                p.chmod(p.stat().st_mode & ~0o022)
    return py_dir


def _make_fake_module_venv(root: Path) -> tuple[Path, str, wheel_lock.WheelLockManifest]:
    venv_dir, pin_id, lock_manifest = module_registry.expected_module_venv_dir(
        root, "drum_kit", "linux-x86_64", "cpu"
    )
    site_dir = venv_dir / "lib" / "python3.12" / "site-packages"
    site_dir.mkdir(parents=True, exist_ok=True)
    (site_dir / "audio_separator.py").write_text("VERSION = '0.34.1'\n", encoding="utf-8")
    (venv_dir / "pyvenv.cfg").write_text("home = /managed\nversion = 3.12.16\n", encoding="utf-8")
    interp = venv_dir / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    interp.parent.mkdir(parents=True, exist_ok=True)
    interp.write_bytes(b"#!/bin/sh\nexit 0\n")
    if os.name != "nt":
        interp.chmod(0o755)
        for p in [venv_dir, *venv_dir.rglob("*")]:
            if not p.is_symlink():
                p.chmod(p.stat().st_mode & ~0o022)
    return venv_dir, pin_id, lock_manifest


def _make_valid_assets_dir(root: Path) -> tuple[Path, dict[str, dict[str, object]], bytes, bytes]:
    asset_dir = module_registry.expected_drumsep_assets_dir(root)
    asset_dir.mkdir(parents=True, exist_ok=True)
    ckpt = asset_dir / model_assets.DIRECT_DKS_MODEL_FILENAME
    yaml_file = asset_dir / model_assets.DIRECT_DKS_MODEL_YAML
    ckpt_bytes = b"drumsep-ckpt-test-payload"
    yaml_bytes = b"audio:\n  chunk_size: 1\nmodel:\n  name: test\ntraining:\n  instruments:\n  - kick\n"
    ckpt.write_bytes(ckpt_bytes)
    yaml_file.write_bytes(yaml_bytes)
    if os.name != "nt":
        asset_dir.parent.chmod(0o700)
        asset_dir.chmod(0o700)
        ckpt.chmod(0o644)
        yaml_file.chmod(0o644)
    artifacts = {
        model_assets.DIRECT_DKS_MODEL_FILENAME: {
            "sha256": hashlib.sha256(ckpt_bytes).hexdigest(),
            "size_bytes": len(ckpt_bytes),
            "source_url": "https://huggingface.co/test/ckpt",
        },
        model_assets.DIRECT_DKS_MODEL_YAML: {
            "sha256": hashlib.sha256(yaml_bytes).hexdigest(),
            "size_bytes": len(yaml_bytes),
            "source_url": "https://huggingface.co/test/yaml",
        },
    }
    return asset_dir, artifacts, ckpt_bytes, yaml_bytes


# --- 1. Subprocess and bytecode policy -----------------------------------------


def test_subprocess_policy_enforces_bytecode_suppression_and_clean_env():
    dirty = {
        "PATH": "/usr/bin",
        "PYTHONPATH": "/contaminate",
        "PYTHONHOME": "/contaminate_home",
        "PYTHONSTARTUP": "/startup.py",
        "PYTHONINSPECT": "1",
        "PYTHONPYCACHEPREFIX": "/tmp/pycache",
        "CUDA_VISIBLE_DEVICES": "0",
        "ROCR_VISIBLE_DEVICES": "0",
        "HIP_VISIBLE_DEVICES": "0",
        "HSA_OVERRIDE_GFX_VERSION": "11.0.0",
    }
    cleaned = subprocess_policy.clean_python_env(
        dirty,
        extra_strip=("CUDA_VISIBLE_DEVICES", "ROCR_VISIBLE_DEVICES", "HIP_VISIBLE_DEVICES", "HSA_OVERRIDE_GFX_VERSION"),
    )
    assert cleaned["PYTHONDONTWRITEBYTECODE"] == "1"
    assert cleaned["PATH"] == "/usr/bin"
    for removed in (
        "PYTHONPATH",
        "PYTHONHOME",
        "PYTHONSTARTUP",
        "PYTHONINSPECT",
        "PYTHONPYCACHEPREFIX",
        "CUDA_VISIBLE_DEVICES",
        "ROCR_VISIBLE_DEVICES",
        "HIP_VISIBLE_DEVICES",
        "HSA_OVERRIDE_GFX_VERSION",
    ):
        assert removed not in cleaned

    assert subprocess_policy.isolated_python_cmd("/bin/python3.12", "-m", "venv", "/stage") == [
        "/bin/python3.12",
        "-I",
        "-B",
        "-m",
        "venv",
        "/stage",
    ]
    assert subprocess_policy.bytecode_disabled_python_cmd("/venv/bin/python", "helper.py") == [
        "/venv/bin/python",
        "-B",
        "helper.py",
    ]
    pip_env = subprocess_policy.clean_pip_env({
        "PIP_TARGET": "/outside", "PIP_CONFIG_FILE": "/outside/pip.conf",
        "PIP_USER": "1", "pip_index_url": "https://outside", "VIRTUAL_ENV": "/other",
        "PYTHONUSERBASE": "/outside", "PATH": "/usr/bin",
    })
    assert pip_env == {"PATH": "/usr/bin", "PYTHONDONTWRITEBYTECODE": "1", "PIP_CONFIG_FILE": os.devnull}
    assert "NUMBA_CACHE_DIR" not in subprocess_policy.clean_python_env({"NUMBA_CACHE_DIR": "/venv/x"})


@pytest.mark.skipif(not sys.platform.startswith("linux"), reason="XDG_CONFIG_DIRS is the Linux global pip config path")
def test_clean_pip_env_skips_global_configuration_that_isolated_mode_still_loads(tmp_path):
    pytest.importorskip("pip")
    config = tmp_path / "pip" / "pip.conf"
    config.parent.mkdir()
    config.write_text("[install]\ntarget = /outside\n", encoding="utf-8")
    base = {k: v for k, v in os.environ.items() if not k.upper().startswith("PIP_")}
    base["XDG_CONFIG_DIRS"] = str(tmp_path)

    def listed(env):
        return subprocess.run(
            [sys.executable, "-I", "-m", "pip", "--isolated", "config", "list"],
            env=env, capture_output=True, text=True, check=True,
        ).stdout

    # The control proves the file is honored by --isolated without the policy.
    assert "install.target" in listed(base)
    assert "install.target" not in listed(subprocess_policy.clean_pip_env(base))


def test_outer_linux_entry_hands_off_operation_and_child_bytecode_policy():
    shell = (ROOT / "scripts/reaper/_internal/STEMwerk_Managed_Python_Linux.sh").read_text(encoding="utf-8")
    assert "STEMWERK_OPERATION_ID=$op\n" in shell
    assert "PYTHONDONTWRITEBYTECODE=1\n" in shell
    assert "export STEMWERK_RUNTIME_ROOT STEMWERK_OPERATION_ID PYTHONDONTWRITEBYTECODE" in shell
    assert 'exec "$root/runtimes/python/$name/bin/python3.12" -I -B "$src" "$@"' in shell


def test_strip_pycache_tree_removes_bytecode_files_and_dirs(tmp_path):
    pkg = tmp_path / "pkg"
    pycache = pkg / "__pycache__"
    pycache.mkdir(parents=True)
    (pkg / "mod.py").write_text("x = 1\n", encoding="utf-8")
    (pycache / "mod.cpython-312.pyc").write_bytes(b"bytecode")
    (pkg / "stray.pyo").write_bytes(b"bytecode2")

    removed = subprocess_policy.strip_pycache_tree(tmp_path)
    assert removed >= 2
    assert not pycache.exists()
    assert not list(tmp_path.rglob("*.pyc"))
    assert not list(tmp_path.rglob("*.pyo"))
    assert (pkg / "mod.py").is_file()


def _record_hash(data: bytes) -> str:
    return "sha256=" + base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=").decode("ascii")


@POSIX_ONLY
def test_staged_console_paths_and_their_record_rows_are_rewritten(tmp_path):
    stage = tmp_path / "tmp" / "op" / "venv-stage"
    published = tmp_path / "runtimes" / "drum_kit" / "pin"
    (stage / "bin").mkdir(parents=True)
    site = stage / "lib" / "python3.12" / "site-packages"
    (site / "x-1.dist-info").mkdir(parents=True)
    direct = f"#!{stage}/bin/python\nimport x\n"
    # pip's form for a path too long or spaced for a shebang line.
    quotes = "'" * 3
    trampoline = f"#!/bin/sh\n{quotes}exec' {stage}/bin/python3.12 \"$0\" \"$@\"\n' {quotes}\nimport x\n"
    spaced = f"#!/bin/sh\n{quotes}exec' '{stage}/bin/python' \"$0\" \"$@\"\n' {quotes}\nimport x\n"
    for name, text in (("pip", direct), ("audio-separator", trampoline), ("numba", spaced), ("activate", f"VIRTUAL_ENV={stage}\nPS1='(venv-stage) '\n")):
        (stage / "bin" / name).write_text(text, encoding="utf-8")
    (stage / "bin" / "python").symlink_to("/managed/bin/python3.12")
    (stage / "pyvenv.cfg").write_text(f"command = {stage}/bin/python\n", encoding="utf-8")
    untouched_row = "x/__init__.py,sha256=keep,3"
    record = site / "x-1.dist-info" / "RECORD"
    record.write_text(f"../../../bin/pip,sha256=old,1\n{untouched_row}\nx-1.dist-info/INSTALLER,,\n", encoding="utf-8")

    module_installer._rewrite_staged_venv_paths(stage, published)

    for path in [stage / "pyvenv.cfg", stage / "bin" / "pip", stage / "bin" / "audio-separator", stage / "bin" / "activate"]:
        text = path.read_text(encoding="utf-8")
        assert str(stage) not in text and str(published) in text
    # Whoever starts a console script, it must not write bytecode into the runtimes.
    assert (stage / "bin" / "pip").read_text(encoding="utf-8").startswith(f"#!{published}/bin/python -B\n")
    assert f'exec\' {published}/bin/python3.12 -B "$0" "$@"\n' in (stage / "bin" / "audio-separator").read_text(encoding="utf-8")
    assert f'exec\' \'{published}/bin/python\' -B "$0" "$@"\n' in (stage / "bin" / "numba").read_text(encoding="utf-8")
    assert "(venv-stage)" not in (stage / "bin" / "activate").read_text(encoding="utf-8")
    assert f"({published.name}) " in (stage / "bin" / "activate").read_text(encoding="utf-8")
    pip_bytes = (stage / "bin" / "pip").read_bytes()
    rows = record.read_text(encoding="utf-8").splitlines()
    assert rows[0] == f"../../../bin/pip,{_record_hash(pip_bytes)},{len(pip_bytes)}"
    assert rows[1] == untouched_row and rows[2] == "x-1.dist-info/INSTALLER,,"
    assert os.readlink(stage / "bin" / "python") == "/managed/bin/python3.12"


@POSIX_ONLY
def test_published_entry_point_probe_requires_each_script_to_run(tmp_path):
    venv = tmp_path / "venv"
    (venv / "bin").mkdir(parents=True)
    for name in ("pip", "audio-separator"):
        script = venv / "bin" / name
        script.write_text('#!/bin/sh\n[ -n "$NUMBA_CACHE_DIR" ] || exit 9\nexit 0\n', encoding="utf-8")
        script.chmod(0o755)
    module_installer._probe_published_entry_points(venv)
    (venv / "bin" / "audio-separator").write_text("#!/bin/sh\nexit 3\n", encoding="utf-8")
    with pytest.raises(module_installer.S6InstallError) as failed:
        module_installer._probe_published_entry_points(venv)
    assert failed.value.code == "entry_point_failed"
    (venv / "bin" / "pip").unlink()
    with pytest.raises(module_installer.S6InstallError) as missing:
        module_installer._probe_published_entry_points(venv)
    assert missing.value.code == "entry_point_missing"


def _dead_s6_operation(root: Path) -> str:
    op = str(uuid.uuid4())
    install_journal.open_journal(root, op).close()
    return op


@POSIX_ONLY
def test_asset_recovery_removes_only_a_dead_operations_lock_and_stage(tmp_path):
    root = _private_dir(tmp_path / "root")
    dest = module_registry.expected_drumsep_assets_dir(root)
    dest.parent.mkdir(parents=True)
    lock = dest.parent / f".{dest.name}.stemwerk-materialize.lock"
    recover = lambda: module_installer._recover_s6_asset_materializations(root, str(uuid.uuid4()))

    # A dead operation's lock and stage go; its journal stays for journal recovery.
    op = _dead_s6_operation(root)
    stage = dest.parent / f".{dest.name}.stemwerk-stage-{op}"
    stage.mkdir()
    (stage / model_assets.DIRECT_DKS_MODEL_YAML).write_bytes(b"partial")
    lock.write_text(op + "\n", encoding="ascii")
    recover()
    assert not stage.exists() and not lock.exists()
    assert (root / "tmp" / op / install_journal.JOURNAL_FILENAME).is_file()

    # A kill after the rename leaves only the lock.
    lock.write_text(op + "\n", encoding="ascii")
    recover()
    assert not lock.exists()

    # Data the materializer never writes is refused and kept, with the lock.
    stage.mkdir()
    (stage / "user-data").write_bytes(b"preserve")
    lock.write_text(op + "\n", encoding="ascii")
    with pytest.raises(install_lock.LockError) as refused:
        recover()
    assert refused.value.code == "recovery_incomplete"
    assert (stage / "user-data").read_bytes() == b"preserve" and lock.exists()
    (stage / "user-data").unlink()
    stage.rmdir()

    # A lock naming a live or unknown materializer, or unreadable as an owner, stays.
    for content in (f"{uuid.uuid4()}\n".encode("ascii"), b"", b"\xff\xfe"):
        lock.write_bytes(content)
        recover()
        assert lock.read_bytes() == content
    lock.unlink()

    # Without a journal nothing proves the directory is an S6 operation's.
    orphan = str(uuid.uuid4())
    (root / "tmp" / orphan).mkdir()
    orphan_stage = dest.parent / f".{dest.name}.stemwerk-stage-{orphan}"
    orphan_stage.mkdir()
    lock.write_text(orphan + "\n", encoding="ascii")
    recover()
    assert orphan_stage.is_dir() and lock.exists()


def test_registered_assets_do_not_fall_back_when_registration_is_unverifiable_or_missing(tmp_path, monkeypatch):
    root = _private_dir(tmp_path / "root")
    registered = module_registry.expected_drumsep_assets_dir(root)
    monkeypatch.setattr(managed_runtime, "managed_runtime_root", lambda: root)
    monkeypatch.setattr(
        module_registry,
        "read_and_validate_module_record",
        lambda _root, _module: (
            "valid", {"components": {"drumsep_assets": {"path": str(registered)}}}, None
        ),
    )
    assert model_assets.drumsep_asset_evidence()["base_dir"] == str(registered)

    monkeypatch.setattr(
        module_registry,
        "read_and_validate_module_record",
        lambda _root, _module: ("unverifiable", None, "registry_corrupt"),
    )
    assert model_assets.drumsep_asset_evidence()["base_dir"] == str(registered)


def test_s6_runtime_guard_rejects_other_pin_after_verifying_registered_runtime(tmp_path, monkeypatch):
    root = _private_dir(tmp_path / "root")
    registered = root / "runtimes" / "drum_kit" / "registered-pin"
    other_python = root / "runtimes" / "drum_kit" / "other-pin" / "bin" / "python"
    monkeypatch.setattr(
        module_verify,
        "verify_module",
        lambda _module, *, root: {
            "installation_state": "partial",
            "components": [{
                "component_id": "module_venv",
                "class": module_verify.PRESENT_PASSING,
                "location": str(registered),
            }],
        },
    )
    assert module_verify.verify_s6_runtime_interpreter(other_python)[0] is False
    other_binary = registered / "bin" / "python-unregistered"
    assert module_verify.verify_s6_runtime_interpreter(other_binary)[0] is False


def _load_worker(tmp_path, monkeypatch):
    script = ROOT / "scripts/reaper/audio_separator_process.py"
    spec = importlib.util.spec_from_file_location("stemwerk_s6_worker_guard_test", script)
    assert spec and spec.loader
    worker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(worker)
    helper = tmp_path / "helper.py"
    helper.write_text("# test helper\n", encoding="utf-8")
    monkeypatch.setattr(worker, "_drumsep_helper_path", lambda: helper)
    (tmp_path / "output").mkdir()
    return worker


def _run_worker_helper(worker, tmp_path, python):
    return worker._run_direct_dks_drumsep_helper(
        tmp_path / "input.wav", tmp_path / "output", tmp_path / "models", python,
        "model", "model", device="cpu",
    )


def test_worker_guard_refuses_unverifiable_runtime_before_spawn(tmp_path, monkeypatch):
    worker = _load_worker(tmp_path, monkeypatch)
    def unreadable(_python):
        raise PermissionError("unreadable runtime file")
    monkeypatch.setattr(module_verify, "verify_s6_runtime_interpreter", unreadable)
    monkeypatch.setattr(worker.subprocess, "Popen", lambda *_a, **_kw: pytest.fail("worker spawned after failed guard"))
    python = tmp_path / "runtimes" / "drum_kit" / "pin" / "bin" / "python"
    ok, _stems, code, detail = _run_worker_helper(worker, tmp_path, python)
    assert not ok and code == "drumsep_helper_failed" and "verification_unavailable" in detail

    monkeypatch.setattr(module_verify, "verify_s6_runtime_interpreter", lambda _p: (False, "s6_runtime_refused:x"))
    ok, _stems, code, detail = _run_worker_helper(worker, tmp_path, python)
    assert not ok and code == "drumsep_helper_failed" and "s6_runtime_refused:x" in detail


def test_worker_routes_numba_cache_outside_a_verified_runtime_only(tmp_path, monkeypatch):
    worker = _load_worker(tmp_path, monkeypatch)
    venv = tmp_path / "root" / "runtimes" / "drum_kit" / "pin"
    python = venv / "bin" / "python"
    python.parent.mkdir(parents=True)
    scratch = tmp_path / "scratch"
    scratch.mkdir()
    monkeypatch.setattr(worker.tempfile, "tempdir", str(scratch))
    inherited = str(venv / "inherited-cache")
    monkeypatch.setenv("NUMBA_CACHE_DIR", inherited)

    class Spawned(Exception):
        def __init__(self, cmd, env):
            self.cmd, self.env = cmd, env

    def fake_popen(cmd, **kwargs):
        raise Spawned(cmd, kwargs["env"])

    monkeypatch.setattr(worker.subprocess, "Popen", fake_popen)
    monkeypatch.setattr(module_verify, "verify_s6_runtime_interpreter", lambda _p: (True, "verified"))
    with pytest.raises(Spawned) as spawned:
        _run_worker_helper(worker, tmp_path, python)
    cache = Path(spawned.value.env["NUMBA_CACHE_DIR"])
    assert cache.is_dir() and scratch in cache.parents and venv not in cache.parents
    assert not (venv / "inherited-cache").exists()
    assert spawned.value.cmd[1] == "-B"
    assert spawned.value.env["PYTHONDONTWRITEBYTECODE"] == "1"

    # A scratch directory inside the runtime would itself change it.
    monkeypatch.setattr(worker.tempfile, "tempdir", str(venv))
    monkeypatch.setattr(worker.subprocess, "Popen", lambda *_a, **_kw: pytest.fail("spawned without a safe cache"))
    ok, _stems, code, detail = _run_worker_helper(worker, tmp_path, python)
    assert not ok and code == "drumsep_helper_failed" and "inside the verified runtime" in detail
    assert [p.name for p in venv.iterdir()] == ["bin"]

    # A runtime that is not S6-managed keeps its caller's setting.
    monkeypatch.setattr(worker.tempfile, "tempdir", str(scratch))
    monkeypatch.setattr(worker.subprocess, "Popen", fake_popen)
    monkeypatch.setattr(module_verify, "verify_s6_runtime_interpreter", lambda _p: (True, "not_s6_managed"))
    with pytest.raises(Spawned) as legacy:
        _run_worker_helper(worker, tmp_path, python)
    assert legacy.value.env["NUMBA_CACHE_DIR"] == inherited


# --- 2. Wheel lock and deterministic wheel builder -----------------------------


def test_linux_cpu_wheel_lock_is_complete_binary_only_and_cpu_only():
    manifest = wheel_lock.load_wheel_lock("drum_kit", "linux-x86_64", "cpu")
    assert manifest.schema_version == 1
    assert manifest.platform_key == "linux-x86_64"
    assert manifest.abi_tag == "cp312"
    assert manifest.wheel_count == 61
    assert len(manifest.wheels) == 61
    assert manifest.total_wheel_bytes == 396_290_399
    assert len(manifest.manifest_sha256) == 64

    names = [pkg.name for pkg in manifest.wheels]
    # onnx-weekly must precede onnx so onnx==1.21.0 owns final entry points.
    assert names.index("onnx-weekly") < names.index("onnx")
    for pkg in manifest.wheels:
        assert pkg.filename.endswith(".whl")
        assert pkg.size > 0
        assert len(pkg.sha256) == 64
        lower = pkg.name.lower()
        assert "cuda" not in lower
        assert "nvidia" not in lower
        assert "rocm" not in lower
        assert "directml" not in lower
        if pkg.name in {"torch", "torchvision", "torchaudio"}:
            assert "+cpu" in pkg.version


@pytest.mark.native_publication
def test_build_stemwerk_core_wheel_is_deterministic_and_contains_manifests(tmp_path):
    out1 = tmp_path / "one"
    out2 = tmp_path / "two"
    w1 = wheel_lock.build_stemwerk_core_wheel(out1)
    w2 = wheel_lock.build_stemwerk_core_wheel(out2)
    assert w1.filename == "stemwerk_core-0.1.1-py3-none-any.whl"
    assert w1.sha256 == w2.sha256
    assert w1.size == w2.size
    with zipfile.ZipFile(out1 / w1.filename, "r") as zf:
        members = set(zf.namelist())
    assert "stemwerk_core/runtime-manifest.v1.tsv" in members
    assert "stemwerk_core/wheel-lock-linux-x86_64-cpu.v1.json" in members
    assert "stemwerk_core/module_installer.py" in members


@pytest.mark.native_publication
def test_verify_wheel_file_checks_size_and_sha256(tmp_path):
    payload = b"wheel-binary-bytes"
    whl = tmp_path / "pkg-1.0-py3-none-any.whl"
    whl.write_bytes(payload)
    digest = hashlib.sha256(payload).hexdigest()
    good_rec = wheel_lock.WheelRecord(
        name="pkg",
        version="1.0",
        filename=whl.name,
        sha256=digest,
        size=len(payload),
        source_kind="pypi",
        url="https://files.pythonhosted.org/pkg-1.0-py3-none-any.whl",
        host="files.pythonhosted.org",
        tags=("py3-none-any",),
        requires_python=">=3.10",
        requires_dist=(),
        license="MIT",
        license_classifiers=(),
        license_files=(),
    )
    wheel_lock.verify_wheel_file(whl, good_rec)

    bad_size_rec = wheel_lock.WheelRecord(**{**good_rec.__dict__, "size": len(payload) + 1})
    with pytest.raises(wheel_lock.WheelLockError) as size_err:
        wheel_lock.verify_wheel_file(whl, bad_size_rec)
    assert size_err.value.code == "wheel_size_mismatch"

    bad_hash_rec = wheel_lock.WheelRecord(**{**good_rec.__dict__, "sha256": "0" * 64})
    with pytest.raises(wheel_lock.WheelLockError) as hash_err:
        wheel_lock.verify_wheel_file(whl, bad_hash_rec)
    assert hash_err.value.code == "wheel_hash_mismatch"


# --- 3. Module registry, receipts, and tree identity ---------------------------


@pytest.mark.native_publication
def test_tree_identity_and_receipt_registry_consistency(tmp_path):
    root = _private_dir(tmp_path / "root")
    py_dir = _make_fake_managed_python(root)
    py_rec = runtime_manifest.python_record("linux-x86_64")
    venv_dir, venv_pin, lock = _make_fake_module_venv(root)
    asset_dir, artifacts, _, _ = _make_valid_assets_dir(root)

    py_id = module_registry.compute_tree_identity(py_dir)
    venv_id = module_registry.compute_tree_identity(venv_dir)
    assert py_id.pyc_count == 0
    assert venv_id.pyc_count == 0
    assert len(py_id.s5b_tree_sha256) == 64

    receipt = module_registry.build_s6_receipt(
        root,
        module_id="drum_kit",
        operation_id="12345678-1234-4234-8234-1234567890ab",
        plan_fingerprint="a" * 64,
        platform_key="linux-x86_64",
        backend="cpu",
        managed_python_dir=py_dir,
        managed_python_pin_id=py_rec.name,
        managed_python_archive_sha256=py_rec.sha256,
        managed_python_identity=py_id,
        managed_python_s5b_tree_sha256=py_id.s5b_tree_sha256,
        managed_python_ownership="core_managed",
        module_venv_dir=venv_dir,
        module_venv_pin_id=venv_pin,
        wheel_lock_id=lock.lock_id,
        wheel_lock_sha256=lock.manifest_sha256,
        module_venv_identity=venv_id,
        installed_packages={w.name: w.version for w in lock.wheels},
        drumsep_assets_dir=asset_dir,
        drumsep_bundle_id=module_registry.DRUMSEP_ASSET_SET_ID,
        drumsep_artifacts=artifacts,
        drumsep_assets_ownership="core_managed",
    )
    _, rec_sha = module_registry.write_receipt(root, "drum_kit", receipt)
    module_registry.write_registry_from_receipt(root, "drum_kit", receipt, rec_sha)

    status, validated, reason = module_registry.read_and_validate_module_record(root, "drum_kit")
    assert status == "valid", reason
    assert validated is not None
    assert validated["components"]["module_venv"]["ownership"] == "core_managed"

    # Mutating registry alone without updating receipt must fail validation.
    reg_path = module_registry.registry_path(root)
    reg_doc = json.loads(reg_path.read_text(encoding="utf-8"))
    reg_doc["modules"]["drum_kit"]["receipt_sha256"] = "f" * 64
    reg_path.write_text(json.dumps(reg_doc), encoding="utf-8")
    status2, _, reason2 = module_registry.read_and_validate_module_record(root, "drum_kit")
    assert status2 == "unverifiable"
    assert reason2 == "registry_receipt_sha256_mismatch"


# --- 4. Module verification with S6 runtime verifiers --------------------------


@contextmanager
def _unreadable(path: Path, monkeypatch):
    """Make ``path`` really unreadable. Root ignores mode bits, so there the same
    ``PermissionError`` is injected instead of letting the check pass vacuously."""
    if os.geteuid() == 0:
        def denied(*_args, **_kwargs):
            raise PermissionError(13, "Permission denied", str(path))
        with monkeypatch.context() as patch:
            patch.setattr(module_registry, "compute_tree_identity", denied)
            yield
        return
    mode = stat.S_IMODE(path.stat().st_mode)
    path.chmod(0)
    try:
        with pytest.raises(PermissionError):
            list(path.iterdir()) if path.is_dir() else path.read_bytes()
        yield
    finally:
        path.chmod(mode)


@pytest.mark.native_publication
def test_module_verify_reports_partial_and_detects_post_publish_mutations(tmp_path, monkeypatch):
    root = _private_dir(tmp_path / "root")
    py_dir = _make_fake_managed_python(root)
    py_rec = runtime_manifest.python_record("linux-x86_64")
    venv_dir, venv_pin, lock = _make_fake_module_venv(root)
    asset_dir, artifacts, ckpt_bytes, yaml_bytes = _make_valid_assets_dir(root)

    patched_assets = (
        module_descriptors.AssetPin(
            model_assets.DIRECT_DKS_MODEL_FILENAME,
            len(ckpt_bytes),
            hashlib.sha256(ckpt_bytes).hexdigest(),
        ),
        module_descriptors.AssetPin(
            model_assets.DIRECT_DKS_MODEL_YAML,
            len(yaml_bytes),
            hashlib.sha256(yaml_bytes).hexdigest(),
        ),
    )
    patched_components = tuple(
        module_descriptors.ComponentDescriptor(
            c.component_id,
            c.kind,
            c.description,
            patched_assets if c.component_id == "drumsep_assets" else c.assets,
        )
        for c in module_descriptors.DIRECT_KIT.components
    )
    patched_descriptor = module_descriptors.ModuleDescriptor(
        module_id="drum_kit",
        workflow_id=module_descriptors.DIRECT_KIT.workflow_id,
        engine_id=module_descriptors.DIRECT_KIT.engine_id,
        display_name=module_descriptors.DIRECT_KIT.display_name,
        components=patched_components,
    )
    monkeypatch.setattr(
        module_descriptors,
        "get_module_descriptor",
        lambda mid: patched_descriptor if mid == "drum_kit" else module_descriptors.MODULE_DESCRIPTORS[mid],
    )
    monkeypatch.setattr(
        managed_python,
        "verify_managed_python",
        lambda r, rec, **kw: {"status": managed_python.VERIFIED, "reasons": []},
    )
    monkeypatch.setattr(
        module_verify,
        "_probe_module_venv_interpreter",
        lambda p, pkgs: (True, "verified", {}),
    )

    py_id = module_registry.compute_tree_identity(py_dir)
    venv_id = module_registry.compute_tree_identity(venv_dir)
    receipt = module_registry.build_s6_receipt(
        root,
        module_id="drum_kit",
        operation_id="12345678-1234-4234-8234-1234567890ab",
        plan_fingerprint="a" * 64,
        platform_key="linux-x86_64",
        backend="cpu",
        managed_python_dir=py_dir,
        managed_python_pin_id=py_rec.name,
        managed_python_archive_sha256=py_rec.sha256,
        managed_python_identity=py_id,
        managed_python_s5b_tree_sha256=py_id.s5b_tree_sha256,
        managed_python_ownership="core_managed",
        module_venv_dir=venv_dir,
        module_venv_pin_id=venv_pin,
        wheel_lock_id=lock.lock_id,
        wheel_lock_sha256=lock.manifest_sha256,
        module_venv_identity=venv_id,
        installed_packages={w.name: w.version for w in lock.wheels},
        drumsep_assets_dir=asset_dir,
        drumsep_bundle_id=module_registry.DRUMSEP_ASSET_SET_ID,
        drumsep_artifacts=artifacts,
        drumsep_assets_ownership="core_managed",
    )
    _, rec_sha = module_registry.write_receipt(root, "drum_kit", receipt)
    module_registry.write_registry_from_receipt(root, "drum_kit", receipt, rec_sha)

    doc = module_verify.verify_module("drum_kit", root=root)
    assert doc["lookup"] == "module_registry"
    assert doc["installation_state"] == "partial"
    by_id = {c["component_id"]: c for c in doc["components"]}
    assert by_id["managed_python"]["class"] == "present_passing"
    assert by_id["module_venv"]["class"] == "present_passing"
    assert by_id["drumsep_assets"]["class"] == "present_passing"
    assert by_id["ffmpeg"]["class"] == "absent"
    assert by_id["reaper_activation"]["class"] == "absent"

    venv_interp = venv_dir / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    assert module_verify.verify_s6_runtime_interpreter(venv_interp) == (True, "verified")

    # A failing import probe is a failing runtime, even with an unchanged tree.
    monkeypatch.setattr(module_verify, "_probe_module_venv_interpreter", lambda p, pkgs: (False, "venv_probe_failed", {}))
    probe_doc = module_verify.verify_module("drum_kit", root=root)
    assert probe_doc["installation_state"] == "repair_required"
    assert {c["component_id"]: c for c in probe_doc["components"]}["module_venv"]["reason_code"] == "venv_probe_failed"
    monkeypatch.setattr(module_verify, "_probe_module_venv_interpreter", lambda p, pkgs: (True, "verified", {}))

    # Mutate 1 byte in module_venv -> repair_required and execution refusal
    mod_file = venv_dir / "lib" / "python3.12" / "site-packages" / "audio_separator.py"
    orig_bytes = mod_file.read_bytes()
    mod_file.write_bytes(orig_bytes.replace(b"0.34.1", b"0.34.2"))
    tampered_doc = module_verify.verify_module("drum_kit", root=root)
    assert tampered_doc["installation_state"] == "repair_required"
    assert {c["component_id"]: c for c in tampered_doc["components"]}["module_venv"]["reason_code"] == "module_venv_tree_modified"
    ok, reason = module_verify.verify_s6_runtime_interpreter(venv_interp)
    assert not ok and "module_venv_tree_modified" in reason
    ok_rt, reason_rt, _ = drumsep_runtime._verify_drumsep_runtime(venv_interp)
    assert not ok_rt and "module_venv_tree_modified" in reason_rt
    mod_file.write_bytes(orig_bytes)

    if os.name != "nt":
        # Mutate 1 file mode in module_venv -> repair_required
        mod_file.chmod(0o600)
        mode_doc = module_verify.verify_module("drum_kit", root=root)
        assert mode_doc["installation_state"] == "repair_required"
        mod_file.chmod(0o644)
        # With its operation log present, only the validity check keeps a committed
        # registration from being treated as an interrupted one.
        op_log = root / "logs" / receipt["operation_id"]
        op_log.mkdir(parents=True)
        (op_log / install_events.EVENTS_FILENAME).write_bytes(b"")
        for unreadable_path in (mod_file, mod_file.parent):
            with _unreadable(unreadable_path, monkeypatch):
                unreadable = module_verify.verify_module("drum_kit", root=root)
                assert unreadable["installation_state"] == "unknown"
                venv_verdict = {c["component_id"]: c for c in unreadable["components"]}["module_venv"]
                assert (venv_verdict["class"], venv_verdict["reason_code"]) == ("unverifiable", "tree_unreadable")
                allowed, why = module_verify.verify_s6_runtime_interpreter(venv_interp)
                assert not allowed and "tree_unreadable" in why
                assert drumsep_runtime._verify_drumsep_runtime(venv_interp)[0] is False
                # Unverifiable content is never adopted as an interrupted registration.
                assert not install_preflight._has_recoverable_receipt_journal(root, "drum_kit")
        assert module_verify.verify_module("drum_kit", root=root)["installation_state"] == "partial"

    # Mutate 1 byte in asset file -> repair_required
    ckpt_path = asset_dir / model_assets.DIRECT_DKS_MODEL_FILENAME
    ckpt_path.write_bytes(ckpt_bytes[:-1] + b"X")
    asset_tampered = module_verify.verify_module("drum_kit", root=root)
    assert asset_tampered["installation_state"] == "repair_required"
    assert {c["component_id"]: c for c in asset_tampered["components"]}["drumsep_assets"]["reason_code"] == "asset_integrity_mismatch"
    ckpt_path.write_bytes(ckpt_bytes)

    # Corrupt receipt alone -> unknown
    rec_path = module_registry.receipt_path(root, "drum_kit")
    orig_rec = rec_path.read_text(encoding="utf-8")
    rec_path.write_text("{corrupt", encoding="utf-8")
    unknown_doc = module_verify.verify_module("drum_kit", root=root)
    assert unknown_doc["installation_state"] == "unknown"
    rec_path.write_text(orig_rec, encoding="utf-8")


# --- 5. S6 CPU preflight scope and conflict refusal ---------------------------


@POSIX_ONLY
def test_s6_cpu_preflight_scope_and_existing_runtime_conflict(tmp_path):
    root = _private_dir(tmp_path / "root")
    facts = install_preflight.HostFacts(
        platform_id="linux-x86_64",
        os_version="6.6.0",
        glibc_version="2.39",
        vcpp_runtime_present=None,
        vcpp_evidence="not_applicable",
        free_bytes=20 * install_preflight.GIB,
    )
    plan_doc = install_preflight.plan("drum_kit", root=root, facts=facts, scope="s6_cpu")
    assert plan_doc["scope"] == "s6_cpu"
    assert plan_doc["preflight_result"] == "no_blocker_found"
    assert plan_doc["actions"]["wheel_lock"]["wheel_count"] == 61
    assert plan_doc["space"]["known_minimum_bytes"] > 0
    assert plan_doc["actions"]["operation"] == "install"
    s4_fp = install_preflight.plan("drum_kit", root=root, facts=facts, scope="s4_assessment")["fingerprint"]
    assert s4_fp != plan_doc["fingerprint"]
    with pytest.raises(install_preflight.PreflightError) as refused:
        install_preflight.require_current_plan(s4_fp, "drum_kit", root, facts, scope="s6_cpu")
    assert refused.value.code == "plan_changed"

    # The enforced budget covers the sampled peak, not only the retained bytes.
    storage = install_preflight.OBSERVED_S6_LINUX_CPU_STORAGE
    budget = plan_doc["space"]["known_minimum_bytes"]
    assert budget == storage["s6_enforced_root_budget_bytes"]
    assert budget == storage["s6_sampled_allocated_peak_root_bytes"] + storage["s6_root_budget_headroom_bytes"]
    assert storage["s6_sampled_allocated_peak_root_bytes"] > storage["s6_sampled_logical_peak_root_bytes"]
    assert storage["s6_sampled_allocated_peak_root_bytes"] > storage["s6_measured_tmpfs_physical_peak_root_bytes"]
    def plan_with_free(free, **kwargs):
        low = install_preflight.HostFacts("linux-x86_64", "6.6.0", "2.39", free, None)
        return install_preflight.plan_s6_cpu("drum_kit", root=root, facts=low, **kwargs)
    assert "insufficient_known_space" in plan_with_free(budget - 1)["blockers"]
    assert "insufficient_known_space" not in plan_with_free(budget)["blockers"]

    # Stale staging is reclaimed only under the lock, so a retry near the limit
    # must reach recovery; the replan under lock then enforces the budget.
    op = _dead_s6_operation(root)
    deferred = plan_with_free(budget - 1)
    assert "insufficient_known_space" not in deferred["blockers"]
    assert "space_recheck_after_recovery" in deferred["warnings"]
    assert deferred["fingerprint"] == plan_doc["fingerprint"]
    under_lock = plan_with_free(budget - 1, ignore_self_lock_operation_id=str(uuid.uuid4()))
    assert "insufficient_known_space" in under_lock["blockers"]
    (root / "tmp" / op / install_journal.JOURNAL_FILENAME).unlink()

    # Create an unverified conflicting directory at the module_venv destination
    venv_dest = Path(plan_doc["actions"]["destinations"]["module_venv"])
    venv_dest.mkdir(parents=True)
    (venv_dest / "unrelated.txt").write_text("keep", encoding="utf-8")
    conflict_doc = install_preflight.plan("drum_kit", root=root, facts=facts, scope="s6_cpu")
    assert conflict_doc["preflight_result"] == "blocked"
    assert "runtime_conflict" in conflict_doc["blockers"]
    assert (venv_dest / "unrelated.txt").read_text(encoding="utf-8") == "keep"

    # A publication record allows resuming only the exact sealed bytes.
    pin = plan_doc["actions"]["module_venv_pin_id"]
    module_registry.write_publication_record(
        root, "drum_kit", operation_id=str(uuid.uuid4()), module_venv_dir=venv_dest,
        module_venv_pin_id=pin, identity=module_registry.compute_tree_identity(venv_dest),
    )
    resumable = install_preflight.plan("drum_kit", root=root, facts=facts, scope="s6_cpu")
    assert resumable["preflight_result"] == "no_blocker_found"
    assert "recoverable_venv_publication" in resumable["warnings"]
    assert "insufficient_known_space" not in plan_with_free(64 * install_preflight.MIB)["blockers"]
    (venv_dest / "unrelated.txt").write_text("changed", encoding="utf-8")
    tampered = install_preflight.plan("drum_kit", root=root, facts=facts, scope="s6_cpu")
    assert "runtime_conflict" in tampered["blockers"]
    assert not module_registry.matches_publication_record(root, "drum_kit", venv_dest.parent / "other-pin")
    record_path = module_registry.publication_record_path(root, "drum_kit")
    record_path.write_text("{corrupt", encoding="utf-8")
    assert module_registry.read_publication_record(root, "drum_kit", venv_dest) is None


# --- 6. Orchestrator fault recovery and idempotency ---------------------------


def _prepare_fake_install(tmp_path, monkeypatch):
    """Real lock, journal, publication and tree hashing with injected Linux host
    facts; venv, pip, wheel staging and asset preparation are fakes. The native
    jobs therefore exercise those primitives on each OS. They do not qualify the
    S6 route there, which is Linux-only until its port (s6_platform_port_pending).
    """
    facts = install_preflight.HostFacts("linux-x86_64", "6.6.0", "2.39", 20 * install_preflight.GIB, None)
    root = _private_dir(tmp_path / "root")
    unrelated = root / "user-preserved-notes.txt"
    unrelated.write_text("do not delete", encoding="utf-8")
    _make_fake_managed_python(root)

    ckpt_bytes = b"ckpt-verified-bytes"
    yaml_bytes = b"audio:\n  chunk_size: 1\nmodel:\n  name: test\ntraining:\n  instruments:\n  - kick\n"
    patched_assets = (
        module_descriptors.AssetPin(
            model_assets.DIRECT_DKS_MODEL_FILENAME,
            len(ckpt_bytes),
            hashlib.sha256(ckpt_bytes).hexdigest(),
        ),
        module_descriptors.AssetPin(
            model_assets.DIRECT_DKS_MODEL_YAML,
            len(yaml_bytes),
            hashlib.sha256(yaml_bytes).hexdigest(),
        ),
    )
    patched_components = tuple(
        module_descriptors.ComponentDescriptor(
            c.component_id,
            c.kind,
            c.description,
            patched_assets if c.component_id == "drumsep_assets" else c.assets,
        )
        for c in module_descriptors.DIRECT_KIT.components
    )
    patched_descriptor = module_descriptors.ModuleDescriptor(
        module_id="drum_kit",
        workflow_id=module_descriptors.DIRECT_KIT.workflow_id,
        engine_id=module_descriptors.DIRECT_KIT.engine_id,
        display_name=module_descriptors.DIRECT_KIT.display_name,
        components=patched_components,
    )
    monkeypatch.setattr(
        module_descriptors,
        "get_module_descriptor",
        lambda mid: patched_descriptor if mid == "drum_kit" else module_descriptors.MODULE_DESCRIPTORS[mid],
    )
    monkeypatch.setattr(
        managed_python,
        "verify_managed_python",
        lambda r, rec, **kw: {"status": managed_python.VERIFIED, "reasons": []},
    )
    monkeypatch.setattr(
        module_verify,
        "_probe_module_venv_interpreter",
        lambda p, pkgs: (True, "verified", {}),
    )

    def fake_subprocess_run(cmd, *args, **kwargs):
        seen_commands.append((list(cmd), kwargs.get("env")))
        # Handle `-m venv <stage>` by populating a fake clean venv in <stage>.
        if "-m" in cmd and "venv" in cmd:
            stage = Path(cmd[-1])
            site_dir = stage / "lib" / "python3.12" / "site-packages"
            site_dir.mkdir(parents=True, exist_ok=True)
            (site_dir / "audio_separator.py").write_text("VERSION = '0.34.1'\n", encoding="utf-8")
            pycache = site_dir / "__pycache__"
            pycache.mkdir()
            (pycache / "audio_separator.cpython-312.pyc").write_bytes(b"staged bytecode")
            (stage / "pyvenv.cfg").write_text(f"home = /managed\ncommand = {stage}\nversion = 3.12.16\n", encoding="utf-8")
            interp = stage / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
            interp.parent.mkdir(parents=True, exist_ok=True)
            interp.write_bytes(b"#!/bin/sh\nexit 0\n")
            (interp.parent / "pip").write_text(f"#!{stage}/bin/python\n", encoding="utf-8")
            if os.name != "nt":
                interp.chmod(0o755)
                # pip and venv honor the umask; publication must not.
                (interp.parent / "pip").chmod(0o775)
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    def fake_stage_wheelhouse(manifest, wheelhouse_dir, **kwargs):
        wheelhouse_dir.mkdir(parents=True, exist_ok=True)
        req_path = wheelhouse_dir / "requirements-locked.txt"
        req_path.write_text("# locked\n", encoding="utf-8")
        core_rec = wheel_lock.WheelRecord(
            name="stemwerk-core",
            version="0.1.1",
            filename="stemwerk_core-0.1.1-py3-none-any.whl",
            sha256="b" * 64,
            size=100,
            source_kind="in_tree_source",
            url="scripts/reaper/vendor/stemwerk-core/src/stemwerk_core",
            host="local_vendor",
            tags=("py3-none-any",),
            requires_python=">=3.10,<3.13",
            requires_dist=("soundfile",),
            license="Proprietary",
            license_classifiers=(),
            license_files=(),
        )
        return (*manifest.wheels, core_rec), req_path

    def fake_acquire_sources(sources_dir, **kwargs):
        sources_dir.mkdir(parents=True, exist_ok=True)
        c_path = sources_dir / model_assets.DIRECT_DKS_MODEL_FILENAME
        y_path = sources_dir / model_assets.DIRECT_DKS_MODEL_YAML
        c_path.write_bytes(ckpt_bytes)
        y_path.write_bytes(yaml_bytes)
        return {
            model_assets.DIRECT_DKS_MODEL_FILENAME: c_path,
            model_assets.DIRECT_DKS_MODEL_YAML: y_path,
        }

    def fake_prepare_assets(request, **kwargs):
        dest = Path(request.destination)
        dest.mkdir(parents=True, exist_ok=True)
        for name, src in (request.local_sources or {}).items():
            (dest / name).write_bytes(Path(src).read_bytes())
            (dest / name).chmod(0o644)
        dest.chmod(0o700)
        return {"outcome": "success", "destination": str(dest)}

    seen_commands = []
    monkeypatch.setattr(module_installer.subprocess, "run", fake_subprocess_run)
    monkeypatch.setattr(wheel_lock, "stage_and_verify_wheelhouse", fake_stage_wheelhouse)
    monkeypatch.setattr(module_installer, "_acquire_drumsep_sources_into", fake_acquire_sources)
    monkeypatch.setattr(asset_preparation, "prepare_drumsep_assets", fake_prepare_assets)

    monkeypatch.setattr(module_installer, "_probe_published_entry_points", lambda _venv: None)
    return facts, root, unrelated, seen_commands


@pytest.mark.native_publication
def test_s6_installer_fault_recovery_and_idempotency(tmp_path, monkeypatch):
    facts, root, unrelated, seen_commands = _prepare_fake_install(tmp_path, monkeypatch)
    entry_probes = []
    def record_entry_probe(venv):
        entry_probes.append((venv, module_registry.receipt_path(root, "drum_kit").exists()))
    monkeypatch.setattr(module_installer, "_probe_published_entry_points", record_entry_probe)
    monkeypatch.setenv("PIP_TARGET", str(tmp_path / "outside-target"))
    monkeypatch.setenv("PIP_CONFIG_FILE", str(tmp_path / "bad-pip.conf"))
    plan_doc = install_preflight.plan("drum_kit", root=root, facts=facts, scope="s6_cpu")
    assert plan_doc["preflight_result"] == "no_blocker_found"
    fp = plan_doc["fingerprint"]
    published_venv = Path(plan_doc["actions"]["destinations"]["module_venv"])
    publication_record = module_registry.publication_record_path(root, "drum_kit")

    def current_plan():
        return install_preflight.plan("drum_kit", root=root, facts=facts, scope="s6_cpu")

    def install_with_fault(fault):
        monkeypatch.setenv("STEMWERK_TEST_S6_FAULT_PHASE", fault)
        result = module_installer.install_module("drum_kit", current_plan()["fingerprint"], root=root, facts=facts)
        monkeypatch.delenv("STEMWERK_TEST_S6_FAULT_PHASE")
        return result

    # Wrong fingerprint is refused before mutation
    code, err_doc = module_installer.install_module("drum_kit", "0" * 64, root=root, facts=facts)
    assert code == 2
    assert err_doc["error"]["code"] == "plan_changed"

    # The read-only S4 assessment is not consent to install, and changes nothing.
    s4_fp = install_preflight.plan("drum_kit", root=root, facts=facts, scope="s4_assessment")["fingerprint"]
    code, err_doc = module_installer.install_module("drum_kit", s4_fp, root=root, facts=facts)
    assert code == 2 and err_doc["error"]["code"] == "plan_changed"
    assert not list(root.glob("tmp/*/journal.ndjson"))

    # A journal that cannot be recovered refuses; one that never started does not.
    stuck = root / "tmp" / str(uuid.uuid4())
    stuck.mkdir(parents=True)
    (stuck / install_journal.JOURNAL_FILENAME).write_bytes(b"not a journal\n")
    code, err_doc = module_installer.install_module("drum_kit", fp, root=root, facts=facts)
    assert code == 2 and err_doc["error"]["code"] == "recovery_incomplete"
    (stuck / install_journal.JOURNAL_FILENAME).write_bytes(b"")

    original_require = install_preflight.require_current_plan
    replans = []
    def recorded_require(*args, **kwargs):
        replans.append(kwargs.get("ignore_self_lock_operation_id"))
        return original_require(*args, **kwargs)
    monkeypatch.setattr(install_preflight, "require_current_plan", recorded_require)

    # A failed staged probe must prevent publication and any trusted registration.
    monkeypatch.setattr(module_verify, "_probe_module_venv_interpreter", lambda _p, _pkgs: (False, "probe_failed", {}))
    code, failed_probe = module_installer.install_module("drum_kit", fp, root=root, facts=facts)
    assert code == 2 and failed_probe["error"]["code"] == "staged_venv_probe_failed"
    assert not published_venv.exists() and not publication_record.exists()
    assert not module_registry.receipt_path(root, "drum_kit").exists()
    assert not module_registry.registry_path(root).exists()
    monkeypatch.setattr(module_verify, "_probe_module_venv_interpreter", lambda _p, _pkgs: (True, "verified", {}))

    # Fault 1: after_venv_staging
    replans.clear()
    seen_commands.clear()
    monkeypatch.setenv("STEMWERK_TEST_S6_FAULT_PHASE", "after_venv_staging")
    code, err_doc = module_installer.install_module("drum_kit", fp, root=root, facts=facts)
    monkeypatch.delenv("STEMWERK_TEST_S6_FAULT_PHASE")
    assert code == 2
    assert err_doc["error"]["code"] == "fault_injected_after_venv_staging"
    # One plan before the lock, one under it that names this operation.
    assert len(replans) == 2 and replans[0] is None and replans[1] == err_doc["operation_id"]
    pip_commands = [(cmd, env) for cmd, env in seen_commands if "pip" in cmd]
    assert len(pip_commands) == 3
    for cmd, env in pip_commands:
        assert cmd[1:3] == ["-I", "-B"] and "--isolated" in cmd
        assert "PIP_TARGET" not in env and env["PIP_CONFIG_FILE"] == os.devnull
    dry_run, final_install, pip_check = (cmd for cmd, _ in pip_commands)
    offline = {"--no-index", "--only-binary=:all:", "--require-hashes"}
    assert "--dry-run" in dry_run and offline.issubset(dry_run)
    assert "--no-deps" not in dry_run  # the dry run proves the locked closure resolves
    assert "--dry-run" not in final_install and offline.issubset(final_install)
    assert {"--no-deps", "--no-compile", "--no-cache-dir"}.issubset(final_install)
    assert "check" in pip_check
    assert unrelated.read_text(encoding="utf-8") == "do not delete"

    # Fault 2: after_asset_publish
    code, err_doc = install_with_fault("after_asset_publish")
    assert code == 2
    assert err_doc["error"]["code"] == "fault_injected_after_asset_publish"

    # Interrupted after publication: the sealed bytes stay resumable.
    code, err_doc = install_with_fault("after_venv_publish")
    assert code == 2 and err_doc["error"]["code"] == "fault_injected_after_venv_publish"
    assert published_venv.is_dir() and publication_record.is_file()
    assert not list(published_venv.rglob("*.pyc"))
    scripts = published_venv / ("Scripts" if os.name == "nt" else "bin")
    for generated in (scripts / "pip", published_venv / "pyvenv.cfg"):
        text = generated.read_text(encoding="utf-8")
        assert "venv-stage" not in text and str(published_venv) in text
    if os.name != "nt":
        assert stat.S_IMODE((scripts / "pip").stat().st_mode) == 0o755
    assert not module_registry.receipt_path(root, "drum_kit").exists()
    resume_plan = current_plan()
    assert resume_plan["preflight_result"] == "no_blocker_found"
    assert "recoverable_venv_publication" in resume_plan["warnings"]
    assert resume_plan["fingerprint"] == fp

    # Changed bytes in that window are refused and preserved, then resumable when restored.
    changed = published_venv / "lib" / "python3.12" / "site-packages" / "audio_separator.py"
    original = changed.read_bytes()
    changed.write_bytes(original + b"# tampered\n")
    assert "runtime_conflict" in current_plan()["blockers"]
    code, refused = module_installer.install_module("drum_kit", fp, root=root, facts=facts)
    assert code == 2 and refused["error"]["code"] == "runtime_conflict"
    assert b"tampered" in changed.read_bytes()
    assert not module_registry.receipt_path(root, "drum_kit").exists()
    changed.write_bytes(original)

    # A second interruption, after recovery already removed the first journal,
    # must not lose the right to resume. The directory is adopted, not rebuilt.
    venv_inode = published_venv.stat().st_ino
    code, err_doc = install_with_fault("before_receipt")
    assert code == 2 and err_doc["error"]["code"] == "fault_injected_before_receipt"
    assert "recoverable_venv_publication" in current_plan()["warnings"]
    assert published_venv.stat().st_ino == venv_inode

    # Fault 3: between_receipt_and_registry
    entry_probes.clear()
    code, err_doc = install_with_fault("between_receipt_and_registry")
    assert code == 2
    assert err_doc["error"]["code"] == "fault_injected_between_receipt_and_registry"
    assert entry_probes == [(published_venv, False)]  # entry points run before any receipt
    # Before recovery, registry does not exist yet while receipt does -> verify reports unknown
    assert module_verify.verify_module("drum_kit", root=root)["installation_state"] == "unknown"
    receipt_path = module_registry.receipt_path(root, "drum_kit")
    pending_receipt = json.loads(receipt_path.read_text())
    assert pending_receipt["components"]["drumsep_assets"]["ownership"] == "unknown"
    assert pending_receipt["components"]["module_venv"]["tree_sha256"] == json.loads(publication_record.read_text())["tree_sha256"]
    for state_file in (receipt_path, publication_record):
        assert json.dumps(str(root / "tmp"))[1:-1] not in state_file.read_text(encoding="utf-8")

    # The receipt window must refuse changed bytes instead of re-receipting them.
    receipt_bytes = receipt_path.read_bytes()
    changed.write_bytes(original + b"# tampered\n")
    fp_tamper = current_plan()["fingerprint"]
    code, refused = module_installer.install_module("drum_kit", fp_tamper, root=root, facts=facts)
    assert code == 2 and refused["error"]["code"] == "runtime_conflict"
    assert b"tampered" in changed.read_bytes()
    assert receipt_path.read_bytes() == receipt_bytes
    assert not module_registry.registry_path(root).exists()
    assert module_verify.verify_module("drum_kit", root=root)["installation_state"] == "unknown"
    changed.write_bytes(original)

    # Clean retry reconciles receipt to registry and reaches partial state
    code, ok_doc = module_installer.install_module("drum_kit", current_plan()["fingerprint"], root=root, facts=facts)
    assert code == 0, ok_doc
    assert ok_doc["kind"] == "stemwerk_module_install_result"
    assert ok_doc["outcome"] == "reused_after_recovery"
    assert ok_doc["installation_state"] == "partial"
    assert ok_doc["readiness"] == "not_ready"
    assert next(c for c in ok_doc["verification"]["components"] if c["component_id"] == "drumsep_assets")["ownership"] == "unknown"
    assert receipt_path.read_bytes() == receipt_bytes
    assert not publication_record.exists()
    assert unrelated.read_text(encoding="utf-8") == "do not delete"

    # Repeated request with fresh consent is a verified no-op (reused)
    code2, reused_doc = module_installer.install_module("drum_kit", current_plan()["fingerprint"], root=root, facts=facts)
    assert code2 == 0, reused_doc
    assert reused_doc["outcome"] == "reused"
    assert reused_doc["installation_state"] == "partial"
    # The managed Python identity gate must catch a change during reuse.
    changed_python = root / "runtimes" / "python" / runtime_manifest.python_record("linux-x86_64").name / "changed.txt"
    def mutate_managed_python(point):
        if point == "before_noop_integrity_check":
            changed_python.write_text("changed", encoding="utf-8")
    code, refused = module_installer.install_module(
        "drum_kit", current_plan()["fingerprint"], root=root, facts=facts, fault_hook=mutate_managed_python
    )
    assert code == 2 and refused["error"]["code"] == "managed_python_mutated"
    changed_python.unlink()


@pytest.mark.native_publication
def test_s6_fresh_install_gates_managed_python_and_rejects_a_changed_publication(tmp_path, monkeypatch):
    facts, root, unrelated, _commands = _prepare_fake_install(tmp_path, monkeypatch)
    plan_doc = install_preflight.plan("drum_kit", root=root, facts=facts, scope="s6_cpu")
    fp = plan_doc["fingerprint"]
    published_venv = Path(plan_doc["actions"]["destinations"]["module_venv"])
    changed_python = root / "runtimes" / "python" / runtime_manifest.python_record("linux-x86_64").name / "changed.txt"
    publication_record = module_registry.publication_record_path(root, "drum_kit")

    # What a kill during materialization leaves is cleared under the install lock.
    assets_dir = module_registry.expected_drumsep_assets_dir(root)
    _private_dir(assets_dir.parent)
    dead_op = _dead_s6_operation(root)
    asset_lock = assets_dir.parent / f".{assets_dir.name}.stemwerk-materialize.lock"
    asset_lock.write_text(dead_op + "\n", encoding="ascii")
    asset_stage = assets_dir.parent / f".{assets_dir.name}.stemwerk-stage-{dead_op}"
    asset_stage.mkdir()

    # A change to the published tree between the rename and the receipt is refused.
    def tamper_publication(point):
        if point == "before_receipt":
            (published_venv / "added.txt").write_text("changed", encoding="utf-8")
    code, refused = module_installer.install_module("drum_kit", fp, root=root, facts=facts, fault_hook=tamper_publication)
    assert code == 2 and refused["error"]["code"] == "runtime_conflict"
    assert not asset_lock.exists() and not asset_stage.exists()
    assert publication_record.is_file()
    assert not module_registry.receipt_path(root, "drum_kit").exists()
    (published_venv / "added.txt").unlink()

    def mutate_managed_python(point):
        if point == "before_final_integrity_check":
            changed_python.write_text("changed", encoding="utf-8")
    code, refused = module_installer.install_module("drum_kit", fp, root=root, facts=facts, fault_hook=mutate_managed_python)
    assert code == 2 and refused["error"]["code"] == "managed_python_mutated"
    # This hook runs after the registry commit, which ends the record's use.
    assert module_registry.registry_path(root).is_file() and not publication_record.exists()
    assert unrelated.read_text(encoding="utf-8") == "do not delete"


# --- 7. Seal ordering around publication ---------------------------------------


class _KilledAtPublication(BaseException):
    """Ends an install at an exact point, past Core's ``except Exception`` handlers."""


def _kill_at_venv_publication(monkeypatch, published_venv, *, after_rename):
    """Stop the install at the venv's no-replace rename, as a kill would.

    Core has no fault point between the seal and the rename, so this wraps the
    journal's rename. A real kill closes the journal descriptor, so this does too.
    Unlike a real kill, Core's ``finally`` still releases the install lock.
    """
    real_rename = install_journal.Journal.rename

    def rename(journal, source, destination, *args, **kwargs):
        if Path(destination) != published_venv:
            return real_rename(journal, source, destination, *args, **kwargs)
        if after_rename:
            real_rename(journal, source, destination, *args, **kwargs)
        journal.close()
        raise _KilledAtPublication()

    monkeypatch.setattr(install_journal.Journal, "rename", rename)


@pytest.mark.native_publication
def test_s6_kill_right_after_the_venv_rename_finds_its_seal_on_disk(tmp_path, monkeypatch):
    facts, root, unrelated, _commands = _prepare_fake_install(tmp_path, monkeypatch)
    plan_doc = install_preflight.plan("drum_kit", root=root, facts=facts, scope="s6_cpu")
    fp = plan_doc["fingerprint"]
    published_venv = Path(plan_doc["actions"]["destinations"]["module_venv"])
    publication_record = module_registry.publication_record_path(root, "drum_kit")

    with monkeypatch.context() as kill:
        _kill_at_venv_publication(kill, published_venv, after_rename=True)
        with pytest.raises(_KilledAtPublication):
            module_installer.install_module("drum_kit", fp, root=root, facts=facts)

    # Without the seal, this directory could only ever be a runtime_conflict.
    assert published_venv.is_dir()
    assert publication_record.is_file()
    assert module_registry.matches_publication_record(root, "drum_kit", published_venv)
    assert not module_registry.receipt_path(root, "drum_kit").exists()
    resume_plan = install_preflight.plan("drum_kit", root=root, facts=facts, scope="s6_cpu")
    assert resume_plan["preflight_result"] == "no_blocker_found"
    assert "recoverable_venv_publication" in resume_plan["warnings"]
    assert resume_plan["fingerprint"] == fp

    # The retry adopts the sealed directory instead of rebuilding it.
    venv_inode = published_venv.stat().st_ino
    code, doc = module_installer.install_module("drum_kit", fp, root=root, facts=facts)
    assert code == 0, doc
    assert doc["installation_state"] == "partial"
    assert published_venv.stat().st_ino == venv_inode
    assert not publication_record.exists()
    assert unrelated.read_text(encoding="utf-8") == "do not delete"


@pytest.mark.native_publication
def test_s6_seal_names_the_staged_tree_and_a_kill_before_the_rename_can_retry(tmp_path, monkeypatch):
    facts, root, unrelated, _commands = _prepare_fake_install(tmp_path, monkeypatch)
    plan_doc = install_preflight.plan("drum_kit", root=root, facts=facts, scope="s6_cpu")
    fp = plan_doc["fingerprint"]
    published_venv = Path(plan_doc["actions"]["destinations"]["module_venv"])
    publication_record = module_registry.publication_record_path(root, "drum_kit")

    with monkeypatch.context() as kill:
        _kill_at_venv_publication(kill, published_venv, after_rename=False)
        with pytest.raises(_KilledAtPublication):
            module_installer.install_module("drum_kit", fp, root=root, facts=facts)

    # The seal is durable while nothing is published yet, and names the staged bytes.
    assert not published_venv.exists()
    assert publication_record.is_file()
    stages = list(root.glob("tmp/*/core/venv-stage"))
    assert len(stages) == 1
    sealed = module_registry.read_publication_record(root, "drum_kit", published_venv)
    assert sealed["tree_sha256"] == module_registry.compute_tree_identity(stages[0]).tree_sha256

    # A seal without its directory does not block a retry, which seals its own stage.
    retry_plan = install_preflight.plan("drum_kit", root=root, facts=facts, scope="s6_cpu")
    assert retry_plan["preflight_result"] == "no_blocker_found"
    assert "recoverable_venv_publication" not in retry_plan["warnings"]
    code, doc = module_installer.install_module("drum_kit", fp, root=root, facts=facts)
    assert code == 0, doc
    assert doc["outcome"] == "installed_s6_partial"
    assert published_venv.is_dir() and not publication_record.exists()
    assert not list(root.glob("tmp/*/core/venv-stage"))
    assert unrelated.read_text(encoding="utf-8") == "do not delete"


@pytest.mark.native_publication
def test_s6_stage_changed_after_its_seal_gets_no_receipt(tmp_path, monkeypatch):
    facts, root, _unrelated, _commands = _prepare_fake_install(tmp_path, monkeypatch)
    plan_doc = install_preflight.plan("drum_kit", root=root, facts=facts, scope="s6_cpu")
    published_venv = Path(plan_doc["actions"]["destinations"]["module_venv"])
    real_rename = install_journal.Journal.rename

    def change_stage_then_rename(journal, source, destination, *args, **kwargs):
        if Path(destination) == published_venv:
            (Path(source) / "added.txt").write_text("changed", encoding="utf-8")
        return real_rename(journal, source, destination, *args, **kwargs)

    monkeypatch.setattr(install_journal.Journal, "rename", change_stage_then_rename)

    # The compare runs after the rename and before any trust is recorded.
    code, refused = module_installer.install_module("drum_kit", plan_doc["fingerprint"], root=root, facts=facts)
    assert code == 2 and refused["error"]["code"] == "runtime_conflict"
    assert not module_registry.receipt_path(root, "drum_kit").exists()
    assert not module_registry.registry_path(root).exists()


# --- 8. Consent binds the wheel lock -------------------------------------------


def test_s6_consent_fingerprint_binds_each_wheel_lock_field(tmp_path, monkeypatch):
    facts, root, _unrelated, _commands = _prepare_fake_install(tmp_path, monkeypatch)

    def current_plan():
        return install_preflight.plan("drum_kit", root=root, facts=facts, scope="s6_cpu")

    consent = current_plan()
    fp = consent["fingerprint"]
    pin = consent["actions"]["module_venv_pin_id"]
    real_load = wheel_lock.load_wheel_lock
    lock = real_load("drum_kit", "linux-x86_64", "cpu")
    assert consent["actions"]["wheel_lock"] == {
        "lock_id": lock.lock_id,
        "sha256": lock.manifest_sha256,
        "wheel_count": lock.wheel_count,
        "total_wheel_bytes": lock.total_wheel_bytes,
    }

    # module_venv_pin_id derives from the lock's SHA-256 and is fingerprinted too.
    # Holding it still leaves only the wheel_lock section to carry each change.
    monkeypatch.setattr(module_registry, "compute_venv_pin_id", lambda *_args: pin)
    for field, value in (
        ("lock_id", "another-lock"),
        ("manifest_sha256", "f" * 64),
        ("wheel_count", lock.wheel_count + 1),
        ("total_wheel_bytes", lock.total_wheel_bytes + 1),
    ):
        changed = dataclasses.replace(lock, **{field: value})
        monkeypatch.setattr(wheel_lock, "load_wheel_lock", lambda *_args, **_kwargs: changed)
        replanned = current_plan()
        assert replanned["actions"]["module_venv_pin_id"] == pin
        assert replanned["fingerprint"] != fp, field
        code, refused = module_installer.install_module("drum_kit", fp, root=root, facts=facts)
        assert code == 2 and refused["error"]["code"] == "plan_changed", field

    # With the lock restored the same consent is current, so the lock alone refused it.
    monkeypatch.setattr(wheel_lock, "load_wheel_lock", real_load)
    assert current_plan()["fingerprint"] == fp
    assert fp == install_preflight.fingerprint(consent["actions"])
    assert not list(root.glob("tmp/*/journal.ndjson"))
    assert not Path(consent["actions"]["destinations"]["module_venv"]).exists()
    assert not module_registry.receipt_path(root, "drum_kit").exists()


def test_s6_consent_is_refused_after_the_wheel_lock_file_changes(tmp_path, monkeypatch):
    facts, root, _unrelated, _commands = _prepare_fake_install(tmp_path, monkeypatch)
    consent = install_preflight.plan("drum_kit", root=root, facts=facts, scope="s6_cpu")

    lock_doc = json.loads(wheel_lock.default_wheel_lock_path().read_text(encoding="utf-8"))
    lock_doc["lock_id"] = "another-lock"
    changed_lock = tmp_path / "wheel-lock.json"
    changed_lock.write_text(json.dumps(lock_doc), encoding="utf-8")
    monkeypatch.setattr(wheel_lock, "default_wheel_lock_path", lambda: changed_lock)

    replanned = install_preflight.plan("drum_kit", root=root, facts=facts, scope="s6_cpu")
    assert replanned["actions"]["wheel_lock"]["lock_id"] == "another-lock"
    assert replanned["actions"]["wheel_lock"]["sha256"] != consent["actions"]["wheel_lock"]["sha256"]
    assert replanned["fingerprint"] != consent["fingerprint"]

    code, refused = module_installer.install_module("drum_kit", consent["fingerprint"], root=root, facts=facts)
    assert code == 2 and refused["error"]["code"] == "plan_changed"
    assert not list(root.glob("tmp/*/journal.ndjson"))
    assert not list((root / "runtimes" / "drum_kit").glob("*"))
    assert not module_registry.receipt_path(root, "drum_kit").exists()
