from __future__ import annotations

import hashlib
import xml.etree.ElementTree as ET
from pathlib import Path

from tools import release_gate


ROOT = Path(__file__).resolve().parents[1]
WHEEL_NAME = "diffq-0.2.4-cp312-cp312-linux_x86_64.whl"
REPOSITORY_SOURCE = f"scripts/reaper/vendor/wheels/linux-x86_64-cp312/{WHEEL_NAME}"
STAGED_TARGET = f"vendor/wheels/linux-x86_64-cp312/{WHEEL_NAME}"
WHEEL_SHA256 = "b829202cba2df9883815f95323f1d40294d657dd9c7a7d1c9706b57932d0a203"


def _matching_sources(index_path: Path) -> list[ET.Element]:
    return [
        source
        for source in ET.parse(index_path).findall(".//source")
        if source.get("file") == f"../{STAGED_TARGET}"
        and (source.text or "").strip().endswith(f"/{REPOSITORY_SOURCE}")
    ]


def test_linux_online_layout_distributes_exact_managed_diffq_wheel() -> None:
    source = ROOT / REPOSITORY_SOURCE
    assert source.is_file()
    assert hashlib.sha256(source.read_bytes()).hexdigest() == WHEEL_SHA256
    assert len(_matching_sources(ROOT / "index.xml")) == 1


def test_staged_target_matches_bootstrap_search_contract() -> None:
    bootstrap = (ROOT / "scripts/reaper/STEMwerk_Bootstrap_Linux.sh").read_text(encoding="utf-8")
    assert '"${SCRIPT_DIR}/vendor/wheels/linux-x86_64-cp312"' in bootstrap
    assert '"${wheel_dir}"/diffq-*.whl' in bootstrap
    assert STAGED_TARGET in bootstrap


def test_managed_diffq_filename_contract_accepts_only_linux_cp312_x86_64() -> None:
    assert release_gate.is_linux_managed_diffq_wheel_name(WHEEL_NAME)
    rejected = (
        "diffq-0.2.4-cp311-cp311-linux_x86_64.whl",
        "diffq-0.2.4-cp312-abi3-linux_x86_64.whl",
        "diffq-0.2.4-cp312-cp312-manylinux_2_17_x86_64.whl",
        "diffq-0.2.4-cp312-cp312-linux_aarch64.whl",
    )
    for filename in rejected:
        assert not release_gate.is_linux_managed_diffq_wheel_name(filename), filename


def test_release_gate_rejects_missing_duplicate_and_wrong_managed_wheel_sources(tmp_path: Path) -> None:
    wheel = tmp_path / REPOSITORY_SOURCE
    wheel.parent.mkdir(parents=True)
    wheel.write_bytes((ROOT / REPOSITORY_SOURCE).read_bytes())
    bootstrap = tmp_path / "scripts/reaper/STEMwerk_Bootstrap_Linux.sh"
    bootstrap.parent.mkdir(parents=True, exist_ok=True)
    bootstrap.write_text(
        'find_managed_diffq_wheel() {\n'
        'REQUIRED_REAPER_LAYOUT="vendor/wheels/linux-x86_64-cp312/' + WHEEL_NAME + '"\n'
        'wheel_dir="${SCRIPT_DIR}/vendor/wheels/linux-x86_64-cp312"\n'
        'for wheel in "${wheel_dir}"/diffq-*.whl; do :; done\n'
        '}\n',
        encoding="utf-8",
    )

    def write_index(entries: list[tuple[str, str]]) -> None:
        body = "\n".join(
            f'<source file="../{target}" type="file">https://raw.githubusercontent.com/x/y/main/{source}</source>'
            for target, source in entries
        )
        (tmp_path / "index.xml").write_text(f"<index><version>{body}</version></index>\n", encoding="utf-8")

    write_index([])
    assert release_gate.check_linux_managed_diffq_distribution(tmp_path).status == "FAIL"

    exact = (STAGED_TARGET, REPOSITORY_SOURCE)
    write_index([exact, exact])
    assert release_gate.check_linux_managed_diffq_distribution(tmp_path).status == "FAIL"

    wrong_target = STAGED_TARGET.replace("cp312-cp312", "cp311-cp311")
    write_index([(wrong_target, REPOSITORY_SOURCE)])
    assert release_gate.check_linux_managed_diffq_distribution(tmp_path).status == "FAIL"

    write_index([exact])
    assert release_gate.check_linux_managed_diffq_distribution(tmp_path).status == "PASS"
