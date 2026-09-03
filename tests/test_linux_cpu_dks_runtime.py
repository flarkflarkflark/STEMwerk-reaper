"""Regression contract for compiler-free Linux Direct Kit runtimes."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import sys


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


def test_clean_dks_catalog_materialization_keeps_audio_separator_schema(tmp_path):
    module = _load_audio_process()

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
