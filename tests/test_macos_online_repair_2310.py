"""2.3.1.0 (A): macOS online-Repair resolution + installer guard tests.

Network-dependent resolution proofs are opt-in via STEMWERK_NETWORK_TESTS=1
(they hit PyPI); everything else is hermetic.
"""

import hashlib
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "scripts/reaper/STEMwerk_Bootstrap_macOS.sh"
POSTINSTALL = ROOT / "installer/macos/scripts/postinstall"
WHEELS_ARM64 = ROOT / "scripts/reaper/vendor/wheels/darwin-arm64-cp312"
WHEELS_X64 = ROOT / "scripts/reaper/vendor/wheels/darwin-x86_64-cp312"

NETWORK = os.environ.get("STEMWERK_NETWORK_TESTS") == "1"
needs_network = pytest.mark.skipif(not NETWORK, reason="set STEMWERK_NETWORK_TESTS=1")


def test_managed_samplerate_wheels_are_platform_tagged_for_both_arches():
    """D7: the managed samplerate wheels carry explicit macosx platform tags, so pip's
    tag priority always beats the archless PyPI landmine (py2.py3-none-any with an
    x86_64-only dylib)."""
    arm = WHEELS_ARM64 / "samplerate-0.1.0-py3-none-macosx_11_0_arm64.whl"
    x86 = WHEELS_X64 / "samplerate-0.1.0-py3-none-macosx_11_0_x86_64.whl"
    assert arm.is_file(), f"missing {arm}"
    assert x86.is_file(), f"missing {x86}"
    for wheel, needle in ((arm, b"Tag: py3-none-macosx_11_0_arm64"), (x86, b"Tag: py3-none-macosx_11_0_x86_64")):
        with zipfile.ZipFile(wheel) as archive:
            wheel_meta = archive.read("samplerate-0.1.0.dist-info/WHEEL")
            assert needle in wheel_meta, f"{wheel.name} misses platform tag {needle!r}"
            dylib = archive.read("samplerate/_samplerate_data/libsamplerate.dylib")
            assert b" Mach-O" in dylib[:4096] or dylib[:4] == b"\xcf\xfa\xed\xfe", "dylib payload missing"


def test_diffq_wheels_contain_native_code_for_the_right_arch():
    import tempfile

    expected = {
        WHEELS_ARM64 / "diffq-0.2.4-cp312-cp312-macosx_11_0_arm64.whl": "arm64",
        WHEELS_X64 / "diffq-0.2.4-cp312-cp312-macosx_11_0_x86_64.whl": "x86_64",
    }
    for wheel, arch in expected.items():
        assert wheel.is_file(), f"missing {wheel}"
        with tempfile.TemporaryDirectory() as tmp:
            with zipfile.ZipFile(wheel) as archive:
                archive.extractall(tmp)
            so_files = list(Path(tmp).rglob("*.so"))
            assert so_files, f"no .so in {wheel.name}"
            out = subprocess.run(["file", str(so_files[0])], capture_output=True, text=True).stdout
            assert arch in out, f"{wheel.name}: expected {arch} in {out.strip()}"


def test_bootstrap_onnxruntime_pin_matrix_and_macos_floor():
    script = BOOTSTRAP.read_text(encoding="utf-8")
    assert 'PINNED_ONNXRUNTIME_VERSION="1.27.0"' in script  # arm64 macOS >= 14
    assert 'PINNED_ONNXRUNTIME_VERSION="1.23.2"' in script  # arm64 13 / Intel >= 13
    assert 'PINNED_ONNXRUNTIME_VERSION="1.17.3"' in script  # arm64 12 (11_0_universal2)
    assert 'PINNED_ONNXRUNTIME_VERSION="1.19.2"' in script  # Intel 11-12 (11_0_universal2)
    assert 'MACOS_MIN_SUPPORTED="12"' in script             # arm64 floor (scipy cp312 starts at 12_0)
    assert 'MACOS_MIN_SUPPORTED="11"' in script             # Intel floor
    assert "onnxruntime-silicon" not in script              # fork attempt removed
    assert 'MACOS_ONNXRUNTIME_PIN="${PINNED_ONNXRUNTIME_VERSION}"' in script


def test_bootstrap_verify_venv_arch_guard_contract():
    script = BOOTSTRAP.read_text(encoding="utf-8")
    assert "verify_venv_arch()" in script
    assert ".dist-info" in script and "WHEEL" in script
    assert 'set_status "deps_failed" "macos_arch_mismatch"' in script
    assert 'broken\\|*samplerate:import_error:*"incompatible architecture"*' in script
    assert 'MACOS_RUNTIME_POLICY_STATUS="arch_mismatch"' in script
    assert 'MACOS_ARCH_GUARD_DETAIL="${_runtime_policy_probe}"' in script
    onnx_install = script.index('if [ "${_onnx_observed}" != "${PINNED_ONNXRUNTIME_VERSION}" ]; then')
    guard_call = script.index("if ! verify_venv_arch; then")
    assert onnx_install < guard_call, "arch guard must run after the last pip install"


def test_b0_ready_fields_and_processing_no_download_contracts_are_declared():
    mac = BOOTSTRAP.read_text(encoding="utf-8")
    linux = (ROOT / "scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text(encoding="utf-8")
    windows = (ROOT / "scripts/reaper/STEMwerk_Bootstrap_Windows.ps1").read_text(encoding="utf-8")
    for text in (mac, linux, windows):
        assert "NORMAL_STEMS_MODEL_READY=" in text
        assert "QUALITY_READY=" in text
        assert "SIX_STEM_READY=" in text
        assert "DIRECT_KIT_READY=" in text
        assert "KIT_SPLIT_READY=" in text

    lua = (ROOT / "scripts/reaper/STEMwerk.lua").read_text(encoding="utf-8")
    workflow = (ROOT / "scripts/reaper/_internal/STEMwerk_Workflow.lua").read_text(encoding="utf-8")
    process = (ROOT / "scripts/reaper/audio_separator_process.py").read_text(encoding="utf-8")
    assert "The required model for this workflow is not installed. Open STEMwerk Setup and run Repair" in lua
    assert "worker_started=no download_started=no catalog_download_started=no" in lua
    assert "verifyDependenciesReadyForProcessing" in lua
    assert "STEMWERK_PROCESSING_MAY_DOWNLOAD=no" in lua
    assert "STEMWERK_PROCESSING_MAY_DOWNLOAD=no" in workflow
    assert "allow_downloads=False" in process


def _postinstall_env(tmp_path, src, home):
    env = dict(os.environ)
    env["STEMWERK_POSTINSTALL_SRC_OVERRIDE"] = str(src)
    env["STEMWERK_POSTINSTALL_HOME_OVERRIDE"] = str(home)
    return env


def _mk_tree(tmp_path):
    home = tmp_path / "home"
    target = home / "Library/Application Support/REAPER/Scripts/STEMwerk-reaper"
    target.mkdir(parents=True)
    return home, target


@pytest.mark.skipif(os.name == "nt", reason="POSIX/bash installer")
def test_postinstall_refuses_thin_over_bundled_and_preserves_payload(tmp_path):
    src = tmp_path / "src"
    (src / "scripts").mkdir(parents=True)
    (src / "scripts/a.lua").write_text("x\n", encoding="utf-8")
    home, target = _mk_tree(tmp_path)
    manifest = target / "_bundled/macos/apple-silicon/manifest.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text("{}\n", encoding="utf-8")

    result = subprocess.run(["bash", str(POSTINSTALL)], env=_postinstall_env(tmp_path, src, home),
                            capture_output=True, text=True)
    assert result.returncode == 1
    assert "has been stopped" in result.stdout
    assert "releases/latest" in result.stdout
    assert manifest.is_file(), "bundled payload must be preserved on refusal"


@pytest.mark.skipif(os.name == "nt", reason="POSIX/bash installer")
def test_postinstall_allows_bundled_over_bundled_and_thin_over_thin(tmp_path):
    src = tmp_path / "src"
    (src / "_bundled/macos/apple-silicon").mkdir(parents=True)
    (src / "_bundled/macos/apple-silicon/manifest.json").write_text("{}\n", encoding="utf-8")
    (src / "scripts").mkdir()
    (src / "scripts/a.lua").write_text("x\n", encoding="utf-8")

    home, target = _mk_tree(tmp_path)
    manifest = target / "_bundled/macos/apple-silicon/manifest.json"
    manifest.parent.mkdir(parents=True)
    manifest.write_text("{}\n", encoding="utf-8")
    result = subprocess.run(["bash", str(POSTINSTALL)], env=_postinstall_env(tmp_path, src, home),
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr

    thin = tmp_path / "thin"
    (thin / "scripts").mkdir(parents=True)
    (thin / "scripts/a.lua").write_text("x\n", encoding="utf-8")
    home2, _target2 = _mk_tree(tmp_path / "second")
    result = subprocess.run(["bash", str(POSTINSTALL)], env=_postinstall_env(tmp_path, thin, home2),
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr


@needs_network
@pytest.mark.parametrize(
    "platform_tag,constraints_name,expect",
    [
        ("macosx_14_0_arm64", "macos.txt", {"numpy==1.26.4", "torch==2.5.1", "onnxruntime==1.27.0"}),
        ("macosx_13_0_x86_64", "macos-intel.txt", {"numpy==1.26.4", "torch==2.2.2", "onnxruntime==1.23.2"}),
    ],
)
def test_online_resolution_is_sdist_free(tmp_path, platform_tag, constraints_name, expect):
    """Full 2.3.1.0 install plan resolves with --only-binary=:all: for both arches using
    the repo wheelhouse as find-links overlay (no sdist may be fetched or built)."""
    wheelhouse = WHEELS_ARM64 if "arm64" in platform_tag else WHEELS_X64
    requirements = tmp_path / "requirements.txt"
    torch_pin = "torch==2.5.1\ntorchvision==0.20.1\ntorchaudio==2.5.1" if "arm64" in platform_tag else \
        "torch==2.2.2\ntorchvision==0.17.2\ntorchaudio==2.2.2"
    onnx_pin = "onnxruntime==1.27.0" if "arm64" in platform_tag else "onnxruntime==1.23.2"
    requirements.write_text(
        "numpy==1.26.4\n" + torch_pin + "\nnumba==0.59.1\nllvmlite==0.42.0\nsamplerate==0.1.0\n"
        "audio-separator==0.23.0\n" + onnx_pin + "\nstemwerk-core==0.1.1\n",
        encoding="utf-8",
    )
    dest = tmp_path / "dl"
    dest.mkdir()
    result = subprocess.run(
        [
            sys.executable, "-m", "pip", "download",
            "-r", str(requirements),
            "-c", str(ROOT / "scripts/reaper/constraints" / constraints_name),
            "--only-binary=:all:", "--implementation", "cp", "--python-version", "3.12",
            "--abi", "cp312", "--platform", platform_tag,
            "--find-links", str(wheelhouse), "-d", str(dest), "-q",
        ],
        capture_output=True, text=True, timeout=900,
    )
    assert result.returncode == 0, result.stdout[-3000:] + result.stderr[-3000:]
    artifacts = [p.name for p in dest.iterdir()]
    assert not any(a.endswith((".tar.gz", ".zip")) for a in artifacts), f"sdist fetched: {artifacts}"
    assert "Building wheel for" not in result.stdout + result.stderr
    for pinned in expect:
        name, version = pinned.split("==")
        assert any(a.startswith(f"{name}-{version}") or a.startswith(f"{name.replace('-', '_')}-{version}")
                   for a in artifacts), f"{pinned} not resolved for {platform_tag}"
    samplerate_pick = next(a for a in artifacts if a.startswith("samplerate-0.1.0"))
    assert "macosx_11_0" in samplerate_pick, f"managed platform-tagged samplerate wheel must win: {samplerate_pick}"
