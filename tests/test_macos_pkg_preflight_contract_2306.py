import hashlib
import os
import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "scripts/reaper/STEMwerk_Bootstrap_macOS.sh"
STAGE = ROOT / "installer/macos/build/bundled-apple-silicon/root"
STAGED = STAGE / "Users/Shared/STEMwerk-reaper/STEMwerk_Bootstrap_macOS.sh"
DEFAULT_PKG = ROOT / "installer/macos/dist/STEMwerk-2.3.0.6-bundled-apple-silicon.pkg"
MARKERS = (
    "MACOS_PAYLOAD_PREFLIGHT_STATUS",
    "MACOS_PAYLOAD_PREFLIGHT_REASON",
    "MACOS_PAYLOAD_PREFLIGHT_MUTATION_STARTED",
    "apple_silicon_requires_bundled_payload",
    "write_ready_to_go_state",
    "READY_TO_GO_STATUS",
    "MAIN_RUNTIME_STATUS",
    "MACOS_RUNTIME_POLICY_STATUS",
    "MACOS_RUNTIME_POLICY_REASON",
    "MACOS_RUNTIME_POLICY_MUTATION_STARTED",
    "runtime_policy_mismatch_requires_rebuild",
)


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _extract_pkg(pkg: Path, root: Path) -> Path:
    expanded = root / "expanded"
    payload_root = root / "payload"
    subprocess.run(["pkgutil", "--expand", str(pkg), str(expanded)], check=True)
    payload_root.mkdir()
    command = f'gzip -dc "{expanded / "Payload"}" | cpio -idm --quiet'
    subprocess.run(["/bin/sh", "-c", command], cwd=payload_root, check=True)
    return payload_root / "Users/Shared/STEMwerk-reaper/STEMwerk_Bootstrap_macOS.sh"


@pytest.mark.skipif(shutil.which("pkgutil") is None, reason="macOS package tools required")
def test_built_pkg_contains_current_preflight_bootstrap(tmp_path):
    pkg = Path(os.environ.get("STEMWERK_2306_TEST_PKG", DEFAULT_PKG))
    if not pkg.is_file():
        pytest.skip(f"package not built: {pkg}")
    packaged = _extract_pkg(pkg, tmp_path)
    hashes = {_sha256(path) for path in (SOURCE, STAGED, packaged)}
    assert len(hashes) == 1
    text = packaged.read_text(encoding="utf-8")
    for marker in MARKERS:
        assert marker in text


def test_pkg_builder_recreates_stage_before_copying_current_source():
    script = (ROOT / "installer/macos/build_pkg.sh").read_text(encoding="utf-8")
    reset = script.index('rm -rf "$STAGE"')
    recreate = script.index('mkdir -p "$OUT_DIR" "$STAGE/Users/Shared/STEMwerk-reaper"')
    copy = script.index('rsync -a --delete', recreate)
    package = script.index("pkgbuild \\", copy)
    assert reset < recreate < copy < package
