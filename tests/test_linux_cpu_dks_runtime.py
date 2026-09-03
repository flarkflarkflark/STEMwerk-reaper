"""Regression contract for compiler-free Linux Direct Kit runtimes."""

from __future__ import annotations

import importlib.util
import json
import shutil
from pathlib import Path
import sys

import pytest


BOOTSTRAP_PATH = Path("scripts/reaper/STEMwerk_Bootstrap_Linux.sh")
WHEELHOUSE_BUILDER_PATH = Path("tools/build_linux_wheelhouse.py")
AUDIO_PROCESS_PATH = Path("scripts/reaper/audio_separator_process.py")


def _load_wheelhouse_builder():
    spec = importlib.util.spec_from_file_location("stemwerk_linux_wheelhouse", WHEELHOUSE_BUILDER_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _load_audio_process():
    spec = importlib.util.spec_from_file_location("stemwerk_linux_cpu_dks_audio_process", AUDIO_PROCESS_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def _shell_function(script: str, name: str, next_name: str) -> str:
    return script.split(f"{name}() {{", 1)[1].split(f"{next_name}() {{", 1)[0]


def test_linux_cpu_drumsep_installs_cpu_torch_from_cpu_index():
    script = BOOTSTRAP_PATH.read_text(encoding="utf-8")
    install = _shell_function(script, "install_drumsep_runtime", "resolve_core_target")

    assert 'DRUMSEP_CPU_TORCH_INDEX_URL="https://download.pytorch.org/whl/cpu"' in script
    assert '"torch==${DRUMSEP_TORCH_VERSION}+cpu"' in install
    assert '"torchvision==${DRUMSEP_TORCHVISION_VERSION}+cpu"' in install
    assert '"${_drumsep_py}" -m pip install --no-cache-dir --index-url "${DRUMSEP_CPU_TORCH_INDEX_URL}"' in install


def test_linux_cpu_and_rocm_drumsep_use_compiler_free_mdxc_dependencies():
    script = BOOTSTRAP_PATH.read_text(encoding="utf-8")
    shared_install = _shell_function(
        script,
        "install_drumsep_mdxc_packages",
        "verify_drumsep_package_integrity",
    )
    cpu_install = _shell_function(script, "install_drumsep_runtime", "resolve_core_target")
    rocm_install = _shell_function(script, "install_drumsep_rocm_runtime", "install_drumsep_runtime")

    assert 'pip_install_with_scope drumsep "${_py}" --no-cache-dir --no-deps' in shared_install
    assert '"audio-separator==${DRUMSEP_AUDIO_SEPARATOR_VERSION}"' in shared_install
    assert '"diffq' not in shared_install
    assert 'install_drumsep_mdxc_packages "${_drumsep_py}"' in cpu_install
    assert 'install_drumsep_mdxc_packages "${_py}"' in rocm_install
    assert '"diffq==0.2.4"' not in rocm_install


def test_drumsep_integrity_check_allows_only_the_intentional_diffq_metadata_gap():
    script = BOOTSTRAP_PATH.read_text(encoding="utf-8")
    integrity = _shell_function(
        script,
        "verify_drumsep_package_integrity",
        "install_drumsep_rocm_runtime",
    )

    assert 'audio-separator ${DRUMSEP_AUDIO_SEPARATOR_VERSION} requires diffq, which is not installed.' in integrity
    assert "return 1" in integrity


def test_linux_drumsep_wheelhouses_exclude_unused_demucs_diffq_dependency():
    module = _load_wheelhouse_builder()

    for backend in ("cpu", "cuda", "rocm"):
        spec = module.SPECS[("drumsep", backend)]
        skipped = {module.canonicalize_name(name) for name in spec.skipped_dependency_names}
        assert "diffq" in skipped


def test_linux_rocm_torch_policy_remains_on_rocm_indexes():
    script = BOOTSTRAP_PATH.read_text(encoding="utf-8")
    rocm_install = _shell_function(script, "install_drumsep_rocm_runtime", "install_drumsep_runtime")

    assert '--index-url "${DRUMSEP_ACTIVE_ROCM_TORCH_INDEX_URL}"' in rocm_install
    assert '"torch==${DRUMSEP_ACTIVE_ROCM_TORCH_VERSION}"' in rocm_install
    assert '"torchvision==${DRUMSEP_ACTIVE_ROCM_TORCHVISION_VERSION}"' in rocm_install
    assert '"torchaudio==${DRUMSEP_ACTIVE_ROCM_TORCHAUDIO_VERSION}"' in rocm_install


def test_clean_dks_catalog_never_fabricates_empty_audio_separator_sections(tmp_path, monkeypatch):
    module = _load_audio_process()

    # A clean cache has no download_checks.json and no bundled/dev-repo
    # snapshot; the fix must obtain the real authoritative catalog (the same
    # way audio-separator's own list_supported_model_files() does) instead of
    # fabricating empty sections for it.
    real_demucs_entry = {"Demucs v4: htdemucs": {"htdemucs.th": "https://example.invalid/htdemucs.th"}}

    def fake_fetch(timeout: int = 120):
        return {
            "demucs_download_list": real_demucs_entry,
            "vr_download_list": {},
            "mdx_download_list": {},
            "mdx_download_vip_list": {},
            "mdx23c_download_list": {},
            "mdx23c_download_vip_list": {},
            "roformer_download_list": {},
        }

    monkeypatch.setattr(module, "_fetch_authoritative_audio_separator_catalog", fake_fetch)

    ok, _detail = module._ensure_runtime_download_checks_has_drumsep(
        tmp_path,
        module.DIRECT_DKS_MODEL_ENTRY_NAME,
        module._builtin_direct_dks_asset_map(),
        None,
    )

    assert ok
    checks = module._read_json_file(tmp_path / "download_checks.json")
    for key in (
        "demucs_download_list",
        "vr_download_list",
        "mdx_download_list",
        "mdx_download_vip_list",
        "mdx23c_download_list",
        "mdx23c_download_vip_list",
        "roformer_download_list",
        "other_network_list_new",
    ):
        assert isinstance(checks[key], dict)
    # The real (fetched) Normal Stems catalog content must survive untouched --
    # this is the exact section the old fix used to fabricate as {}.
    assert checks["demucs_download_list"] == real_demucs_entry


def test_ensure_runtime_download_checks_fails_closed_without_authoritative_catalog(tmp_path, monkeypatch):
    module = _load_audio_process()

    def fake_fetch_fails(timeout: int = 120):
        raise OSError("offline")

    monkeypatch.setattr(module, "_fetch_authoritative_audio_separator_catalog", fake_fetch_fails)

    ok, detail = module._ensure_runtime_download_checks_has_drumsep(
        tmp_path,
        module.DIRECT_DKS_MODEL_ENTRY_NAME,
        module._builtin_direct_dks_asset_map(),
        None,
    )

    assert ok is False
    assert "authoritative_catalog_fetch_failed" in detail
    # No synthetic/partial download_checks.json may be left behind on failure.
    assert not (tmp_path / "download_checks.json").exists()


def test_ensure_runtime_download_checks_preserves_existing_complete_catalog_byte_for_byte(tmp_path):
    module = _load_audio_process()

    checks_path = tmp_path / "download_checks.json"
    unrelated_demucs_entry = {"Demucs v4: htdemucs": {"htdemucs.th": "https://example.invalid/htdemucs.th"}}
    unrelated_vr_entry = {"VR Arch Single Model v5: 1_HP-UVR": "1_HP-UVR.pth"}
    existing = {
        "demucs_download_list": unrelated_demucs_entry,
        "vr_download_list": unrelated_vr_entry,
        "mdx_download_list": {},
        "mdx_download_vip_list": {},
        "mdx23c_download_list": {"Some Other MDX23C Model": {"other.ckpt": "other.yaml"}},
        "mdx23c_download_vip_list": {},
        "roformer_download_list": {},
        "other_network_list_new": {},
    }
    checks_path.write_text(json.dumps(existing), encoding="utf-8")

    ok, _detail = module._ensure_runtime_download_checks_has_drumsep(
        tmp_path,
        module.DIRECT_DKS_MODEL_ENTRY_NAME,
        module._builtin_direct_dks_asset_map(),
        None,
    )

    assert ok
    checks = module._read_json_file(checks_path)
    # Every pre-existing section/entry survives untouched -- only STEMwerk's
    # own managed DrumSep entries are merged in.
    assert checks["demucs_download_list"] == unrelated_demucs_entry
    assert checks["vr_download_list"] == unrelated_vr_entry
    assert checks["mdx23c_download_list"]["Some Other MDX23C Model"] == {"other.ckpt": "other.yaml"}
    assert module.DIRECT_DKS_MODEL_ENTRY_NAME in checks["mdx23c_download_list"]


def test_dks_first_writer_leaves_normal_stems_resolvable_via_real_audio_separator(tmp_path, monkeypatch):
    """
    End-to-end regression for the proven Apple Silicon clean-cache bug:
    DrumSep prefetch is the first thing to ever create download_checks.json,
    on a cache that already has a real Normal Stems (htdemucs) weight file on
    disk (as a bundled installer would pre-seed it). Both DrumSep's own model
    and the already-on-disk htdemucs weight must remain resolvable through
    the real (not reimplemented) audio-separator catalog lookup afterward.
    """
    pytest.importorskip("audio_separator")
    if shutil.which("ffmpeg") is None:
        pytest.skip("ffmpeg not available in this environment")
    from audio_separator.separator import Separator

    module = _load_audio_process()

    demucs_weight_name = "955717e8-8726e21a.th"
    demucs_weight_url = "https://dl.fbaipublicfiles.com/demucs/hybrid_transformer/" + demucs_weight_name
    demucs_yaml_url = "https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/htdemucs.yaml"
    (tmp_path / demucs_weight_name).write_bytes(b"fake-weight-bytes")
    (tmp_path / "htdemucs.yaml").write_text("placeholder", encoding="utf-8")

    def fake_fetch(timeout: int = 120):
        return {
            "demucs_download_list": {
                "Demucs v4: htdemucs": {
                    demucs_weight_name: demucs_weight_url,
                    "htdemucs.yaml": demucs_yaml_url,
                }
            },
            "vr_download_list": {},
            "mdx_download_list": {},
            "mdx_download_vip_list": {},
            "mdx23c_download_list": {},
            "mdx23c_download_vip_list": {},
            "roformer_download_list": {},
        }

    monkeypatch.setattr(module, "_fetch_authoritative_audio_separator_catalog", fake_fetch)

    ok, _detail = module._ensure_runtime_download_checks_has_drumsep(
        tmp_path,
        module.DIRECT_DKS_MODEL_ENTRY_NAME,
        module._builtin_direct_dks_asset_map(),
        None,
    )
    assert ok

    (tmp_path / module.DIRECT_DKS_MODEL_FILENAME).write_bytes(b"fake-drumsep-ckpt")
    (tmp_path / module.DIRECT_DKS_MODEL_YAML).write_text("placeholder", encoding="utf-8")

    sep = Separator(model_file_dir=str(tmp_path), output_dir=str(tmp_path / "out"), output_format="wav")

    drumsep_result = sep.download_model_files(module.DIRECT_DKS_MODEL_FILENAME)
    assert drumsep_result[0] == module.DIRECT_DKS_MODEL_FILENAME

    normal_stems_result = sep.download_model_files(demucs_weight_name)
    assert normal_stems_result[0] == demucs_weight_name
