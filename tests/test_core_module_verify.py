"""Tests for the module descriptor and the read-only module verification."""
from __future__ import annotations

import builtins
import dataclasses
import hashlib
import io
import itertools
import json
import os
from pathlib import Path
import sys
import time
import uuid

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import asset_acquisition  # noqa: E402
from stemwerk_core import asset_materialization as materialization  # noqa: E402
from stemwerk_core import install_lock, process_identity  # noqa: E402
from stemwerk_core import managed_runtime, model_assets  # noqa: E402
from stemwerk_core import module_descriptors as descriptors  # noqa: E402
from stemwerk_core import module_verify as verify  # noqa: E402
from tests.asset_link_helpers import (  # noqa: E402
    is_directory_link,
    make_directory_link,
)

pytestmark = pytest.mark.portable


@pytest.fixture(autouse=True)
def isolated_runtime_root(tmp_path, monkeypatch):
    """verify reads the install lock under <root>: never the real user's root."""

    root = tmp_path / "isolated-runtime-root"
    monkeypatch.setenv("STEMWERK_RUNTIME_ROOT", str(root))
    return root

CHECKPOINT = descriptors.DIRECT_KIT.components[3].assets[0].name
CONFIG = descriptors.DIRECT_KIT.components[3].assets[1].name
CONTENTS = {
    CHECKPOINT: b"controlled checkpoint\r\nbare-lf\n\x1a\x00tail\n",
    CONFIG: b"controlled config\n",
}
NON_ASSET_COMPONENTS = ("managed_python", "module_venv", "ffmpeg", "reaper_activation")
ALL_COMPONENTS = NON_ASSET_COMPONENTS[:3] + ("drumsep_assets",) + NON_ASSET_COMPONENTS[3:]


def _pin(name: str, content: bytes) -> descriptors.AssetPin:
    return descriptors.AssetPin(
        name=name, size=len(content), sha256=hashlib.sha256(content).hexdigest()
    )


def fixture_descriptor() -> descriptors.ModuleDescriptor:
    """DIRECT_KIT with the asset pins replaced by small controlled files."""

    pins = tuple(_pin(name, CONTENTS[name]) for name in (CHECKPOINT, CONFIG))
    components = tuple(
        dataclasses.replace(component, assets=pins)
        if component.kind == descriptors.KIND_ASSET
        else component
        for component in descriptors.DIRECT_KIT.components
    )
    return dataclasses.replace(descriptors.DIRECT_KIT, components=components)


def make_asset_set(parent: Path, name: str = "asset-set") -> Path:
    directory = parent / name
    directory.mkdir(parents=True)
    for filename, content in CONTENTS.items():
        (directory / filename).write_bytes(content)
    (directory / "stemwerk-materialization-receipt.v1.json").write_text("{}")
    return directory


class FixtureLookup:
    lookup_id = "fixture"

    def __init__(self, locations=None):
        self.locations = dict(locations or {})
        self.calls = []

    def locate(self, module_id, component_id):
        self.calls.append((module_id, component_id))
        value = self.locations.get(component_id)
        if isinstance(value, Exception):
            raise value
        if value is None:
            return None
        return verify.ComponentLocation(Path(value))


def stub(component_class=verify.PRESENT_PASSING, reason="stub_verified"):
    def verifier(component, location):
        return verify.ComponentVerdict(component_class, reason)

    return verifier


STUB_VERIFIERS = {
    descriptors.KIND_RUNTIME: stub(),
    descriptors.KIND_FFMPEG: stub(),
    descriptors.KIND_ACTIVATION: stub(),
}


def run(locations, *, verifiers=None):
    return verify.verify_descriptor(
        fixture_descriptor(), lookup=FixtureLookup(locations), verifiers=verifiers
    )


def component(document, component_id):
    return next(c for c in document["components"] if c["component_id"] == component_id)


def classes(document):
    return {c["component_id"]: c["class"] for c in document["components"]}


# --- precedence (design section 2.1) -------------------------------------

A, F, P, U = verify.ABSENT, verify.PRESENT_FAILING, verify.PRESENT_PASSING, verify.UNVERIFIABLE

PRECEDENCE_TABLE = [
    # rule 1: any present-failing wins, including over missing and unverifiable
    ([F], verify.REPAIR_REQUIRED, 1),
    ([F, A], verify.REPAIR_REQUIRED, 1),
    ([A, A, F], verify.REPAIR_REQUIRED, 1),
    ([F, U], verify.REPAIR_REQUIRED, 1),
    ([U, F, A, P], verify.REPAIR_REQUIRED, 1),
    ([P, F], verify.REPAIR_REQUIRED, 1),
    # rule 2: any unverifiable, before all-absent and partial
    ([U], verify.UNKNOWN, 2),
    ([U, A], verify.UNKNOWN, 2),
    ([A, A, A, A, U], verify.UNKNOWN, 2),
    ([U, P], verify.UNKNOWN, 2),
    ([P, A, U], verify.UNKNOWN, 2),
    # rule 3: all absent
    ([A], verify.NOT_INSTALLED, 3),
    ([A] * 5, verify.NOT_INSTALLED, 3),
    # rule 4: any absent (activation missing with intact files is partial)
    ([A, P], verify.PARTIAL, 4),
    ([P, P, P, P, A], verify.PARTIAL, 4),
    ([P, A, P], verify.PARTIAL, 4),
    # rule 5: otherwise
    ([P], verify.INSTALLED, 5),
    ([P] * 5, verify.INSTALLED, 5),
]


@pytest.mark.parametrize(("observed", "state", "rule"), PRECEDENCE_TABLE)
def test_precedence_table(observed, state, rule):
    assert verify.installation_state(observed) == (state, rule)


@pytest.mark.parametrize("size", [1, 2, 3, 4])
def test_precedence_is_order_independent_and_matches_definitions(size):
    for combination in itertools.product(verify.COMPONENT_CLASSES, repeat=size):
        state, rule = verify.installation_state(combination)
        for permutation in itertools.permutations(combination):
            assert verify.installation_state(permutation) == (state, rule)
        present = set(combination)
        assert (state == verify.REPAIR_REQUIRED) == (F in present)
        assert (state == verify.UNKNOWN) == (F not in present and U in present)
        assert (state == verify.INSTALLED) == (present == {P})
        assert (state == verify.NOT_INSTALLED) == (present == {A})
        assert (state == verify.PARTIAL) == (present == {A, P})


@pytest.mark.parametrize("observed", [[], ["installed"], [A, "passing"]])
def test_precedence_rejects_empty_or_unknown_classes(observed):
    with pytest.raises(ValueError):
        verify.installation_state(observed)


# --- descriptor ------------------------------------------------------------


def test_direct_kit_descriptor_names_and_components():
    kit = descriptors.get_module_descriptor("drum_kit")
    assert kit is descriptors.DIRECT_KIT
    assert (kit.module_id, kit.workflow_id, kit.engine_id, kit.display_name) == (
        "drum_kit",
        "drum_kit_direct",
        "drumsep_mdx23c",
        "STEMwerk DKS",
    )
    assert [(c.component_id, c.kind) for c in kit.components] == [
        ("managed_python", "runtime"),
        ("module_venv", "runtime"),
        ("ffmpeg", "ffmpeg"),
        ("drumsep_assets", "asset"),
        ("reaper_activation", "activation"),
    ]


def test_direct_kit_asset_pins_come_from_existing_core_pins():
    pins = {pin.name: pin for pin in descriptors.DIRECT_KIT.components[3].assets}
    assert {name: pin.sha256 for name, pin in pins.items()} == dict(
        model_assets.DIRECT_DKS_MODEL_EXPECTED_SHA256
    )
    assert pins[model_assets.DIRECT_DKS_MODEL_FILENAME].size == asset_acquisition.CHECKPOINT_SIZE
    assert pins[model_assets.DIRECT_DKS_MODEL_YAML].size == asset_acquisition.CONFIG_SIZE
    policy = asset_acquisition._production_policy()
    assert {(a.name, a.size, a.sha256) for a in policy.assets} == {
        (p.name, p.size, p.sha256) for p in pins.values()
    }


def test_unknown_module_is_rejected():
    with pytest.raises(ValueError, match="unknown module"):
        descriptors.get_module_descriptor("vocals_hq")
    with pytest.raises(ValueError, match="unknown module"):
        verify.verify_module("vocals_hq")


@pytest.mark.parametrize(
    "build",
    [
        lambda: descriptors.AssetPin("../x", 1, "0" * 64),
        lambda: descriptors.AssetPin("a\\b", 1, "0" * 64),
        lambda: descriptors.AssetPin("x", 0, "0" * 64),
        lambda: descriptors.AssetPin("x", 1, "A" * 64),
        lambda: descriptors.ComponentDescriptor("c", "plugin", "d"),
        lambda: descriptors.ComponentDescriptor("c", "asset", "d"),
        lambda: descriptors.ComponentDescriptor(
            "c", "runtime", "d", (descriptors.AssetPin("x", 1, "0" * 64),)
        ),
        lambda: descriptors.ModuleDescriptor("m", "w", "e", "n", ()),
        lambda: descriptors.ModuleDescriptor(
            "m",
            "w",
            "e",
            "n",
            (
                descriptors.ComponentDescriptor("c", "runtime", "d"),
                descriptors.ComponentDescriptor("c", "ffmpeg", "d"),
            ),
        ),
    ],
)
def test_descriptor_validation(build):
    with pytest.raises(ValueError):
        build()


# --- default lookup ----------------------------------------------------------


def test_no_registry_lookup_finds_nothing():
    lookup = verify.NoRegistryLookup()
    for component_id in ALL_COMPONENTS:
        assert lookup.locate("drum_kit", component_id) is None


def test_default_lookup_is_not_installed_and_reads_no_legacy_layout(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    for variable in ("HOME", "USERPROFILE"):
        monkeypatch.setenv(variable, str(home))
    monkeypatch.setenv("LOCALAPPDATA", str(home / "AppData" / "Local"))
    monkeypatch.setenv("XDG_DATA_HOME", str(home / ".local" / "share"))
    monkeypatch.delenv("AUDIO_SEPARATOR_MODEL_DIR", raising=False)
    monkeypatch.delenv("STEMWERK_RUNTIME_ROOT", raising=False)
    legacy_models = managed_runtime.managed_model_cache_dir()
    assert home in legacy_models.parents
    # The only paths verify may read: the install lock (design section 2.1).
    runtime_root = managed_runtime.managed_runtime_root()
    lock_directory = runtime_root / "state" / "locks"
    lock_paths = {runtime_root / "state", lock_directory}
    legacy_models.mkdir(parents=True)
    for name, content in CONTENTS.items():
        (legacy_models / name).write_bytes(content)
    (legacy_models.parent / ".venv-drumsep").mkdir()

    accessed = []

    def forbidden(module, name):
        original = getattr(module, name)

        def guard(*args, **kwargs):
            path = Path(args[0]) if args and isinstance(args[0], (str, os.PathLike)) else None
            if path is not None and (path in lock_paths or path.parent == lock_directory):
                return original(*args, **kwargs)
            accessed.append((name, args[:1]))
            raise AssertionError(f"verify touched the file system via {name}")

        return guard

    for module, name in [
        (os, "stat"),
        (os, "lstat"),
        (os, "open"),
        (os, "scandir"),
        (os, "listdir"),
        (builtins, "open"),
        (io, "open"),
    ]:
        monkeypatch.setattr(module, name, forbidden(module, name))
    try:
        document = verify.verify_module("drum_kit")
        document_for_fixture_pins = verify.verify_descriptor(fixture_descriptor())
    finally:
        monkeypatch.undo()

    assert accessed == []
    for result in (document, document_for_fixture_pins):
        assert result["lookup"] == "no_registry"
        assert result["installation_state"] == verify.NOT_INSTALLED
        assert result["decided_by_rule"] == 3
        assert set(classes(result).values()) == {verify.ABSENT}
        assert all(c["location"] is None for c in result["components"])


def test_lookup_without_any_location_is_not_installed():
    lookup = FixtureLookup()
    document = verify.verify_descriptor(fixture_descriptor(), lookup=lookup)
    assert document["installation_state"] == verify.NOT_INSTALLED
    assert lookup.calls == [("drum_kit", component_id) for component_id in ALL_COMPONENTS]


def test_lookup_failure_is_unverifiable_and_unknown():
    document = run({"drumsep_assets": verify.ComponentLookupError("registry unreadable")})
    entry = component(document, "drumsep_assets")
    assert (entry["class"], entry["reason_code"]) == (verify.UNVERIFIABLE, "lookup_failed")
    assert document["installation_state"] == verify.UNKNOWN


def test_unexpected_lookup_errors_propagate():
    with pytest.raises(RuntimeError):
        run({"ffmpeg": RuntimeError("bug")})


def test_lookup_and_verifier_must_return_contract_types(tmp_path):
    class BadLookup(FixtureLookup):
        def locate(self, module_id, component_id):
            return str(tmp_path)

    with pytest.raises(TypeError):
        verify.verify_descriptor(fixture_descriptor(), lookup=BadLookup())
    with pytest.raises(TypeError):
        run({"ffmpeg": tmp_path}, verifiers={"ffmpeg": lambda c, l: "present_passing"})
    with pytest.raises(ValueError):
        verify.ComponentVerdict(verify.ABSENT, "not_found")


# --- verify on fixture trees -------------------------------------------------


@pytest.mark.native_publication
def test_installed_only_with_stubbed_verifiers(tmp_path):
    locations = {component_id: tmp_path / component_id for component_id in NON_ASSET_COMPONENTS}
    locations["drumsep_assets"] = make_asset_set(tmp_path)
    document = run(locations, verifiers=STUB_VERIFIERS)
    assert document["installation_state"] == verify.INSTALLED
    assert document["decided_by_rule"] == 5
    assets = component(document, "drumsep_assets")
    assert (assets["class"], assets["reason_code"]) == (verify.PRESENT_PASSING, "verified")
    assert [f["result"] for f in assets["files"]] == ["verified", "verified"]


@pytest.mark.native_publication
def test_verified_assets_with_other_components_absent_is_partial(tmp_path):
    document = run({"drumsep_assets": make_asset_set(tmp_path)})
    assert document["installation_state"] == verify.PARTIAL
    assert document["decided_by_rule"] == 4
    assert classes(document) == {
        "managed_python": verify.ABSENT,
        "module_venv": verify.ABSENT,
        "ffmpeg": verify.ABSENT,
        "drumsep_assets": verify.PRESENT_PASSING,
        "reaper_activation": verify.ABSENT,
    }


@pytest.mark.native_publication
def test_missing_activation_with_intact_files_is_partial(tmp_path):
    locations = {component_id: tmp_path / component_id for component_id in NON_ASSET_COMPONENTS}
    locations["drumsep_assets"] = make_asset_set(tmp_path)
    locations["reaper_activation"] = None
    document = run(locations, verifiers=STUB_VERIFIERS)
    assert document["installation_state"] == verify.PARTIAL
    assert component(document, "reaper_activation")["class"] == verify.ABSENT


@pytest.mark.native_publication
@pytest.mark.parametrize("component_id", NON_ASSET_COMPONENTS)
def test_found_component_without_verifier_is_unverifiable_and_unknown(tmp_path, component_id):
    located = tmp_path / component_id
    located.mkdir()
    document = run({"drumsep_assets": make_asset_set(tmp_path), component_id: located})
    entry = component(document, component_id)
    assert (entry["class"], entry["reason_code"]) == (verify.UNVERIFIABLE, "verifier_unavailable")
    assert entry["location"] == str(located)
    assert document["installation_state"] == verify.UNKNOWN
    assert document["decided_by_rule"] == 2


def test_without_stubs_the_real_route_can_never_be_installed(tmp_path):
    locations = {component_id: tmp_path / component_id for component_id in NON_ASSET_COMPONENTS}
    locations["drumsep_assets"] = make_asset_set(tmp_path)
    document = run(locations)
    assert document["installation_state"] == verify.UNKNOWN
    assert {
        c["component_id"] for c in document["components"] if c["class"] == verify.UNVERIFIABLE
    } == set(NON_ASSET_COMPONENTS)


def _expect_failing(document, reason):
    entry = component(document, "drumsep_assets")
    assert (entry["class"], entry["reason_code"]) == (verify.PRESENT_FAILING, reason)
    assert document["installation_state"] == verify.REPAIR_REQUIRED
    assert document["decided_by_rule"] == 1
    return entry


@pytest.mark.native_publication
def test_hash_mismatch_is_repair_required(tmp_path):
    directory = make_asset_set(tmp_path)
    original = CONTENTS[CONFIG]
    (directory / CONFIG).write_bytes(bytes([original[0] ^ 0xFF]) + original[1:])
    entry = _expect_failing(run({"drumsep_assets": directory}), "asset_integrity_mismatch")
    results = {f["name"]: f["result"] for f in entry["files"]}
    assert results == {CHECKPOINT: "verified", CONFIG: "asset_integrity_mismatch"}


@pytest.mark.native_publication
def test_size_mismatch_is_repair_required_and_reports_sizes(tmp_path):
    directory = make_asset_set(tmp_path)
    (directory / CHECKPOINT).write_bytes(CONTENTS[CHECKPOINT] + b"x")
    entry = _expect_failing(run({"drumsep_assets": directory}), "asset_size_mismatch")
    checkpoint = entry["files"][0]
    assert checkpoint["expected_size"] == len(CONTENTS[CHECKPOINT])
    assert checkpoint["observed_size"] == len(CONTENTS[CHECKPOINT]) + 1


def test_wrong_size_file_is_not_hashed(tmp_path, monkeypatch):
    directory = make_asset_set(tmp_path)
    (directory / CHECKPOINT).write_bytes(b"short")
    hashed = []
    original = materialization._validate_source

    def recording(name, value, expected):
        hashed.append(name)
        return original(name, value, expected)

    monkeypatch.setattr(materialization, "_validate_source", recording)
    _expect_failing(run({"drumsep_assets": directory}), "asset_size_mismatch")
    assert hashed == [CONFIG]


@pytest.mark.native_publication
def test_missing_file_is_repair_required(tmp_path):
    directory = make_asset_set(tmp_path)
    (directory / CHECKPOINT).unlink()
    entry = _expect_failing(run({"drumsep_assets": directory}), "asset_file_missing")
    assert entry["files"][1]["result"] == "verified"


@pytest.mark.native_publication
def test_missing_file_is_never_hidden_by_absent_components(tmp_path):
    # Tie-break of rule 1: one corrupt component and four missing ones.
    directory = make_asset_set(tmp_path)
    (directory / CONFIG).unlink()
    document = run({"drumsep_assets": directory})
    _expect_failing(document, "asset_file_missing")
    assert list(classes(document).values()).count(verify.ABSENT) == 4


@pytest.mark.native_publication
def test_failing_component_wins_over_unverifiable_component(tmp_path):
    directory = make_asset_set(tmp_path)
    (directory / CONFIG).write_bytes(b"x" * len(CONTENTS[CONFIG]))
    located = tmp_path / "ffmpeg"
    document = run({"drumsep_assets": directory, "ffmpeg": located})
    _expect_failing(document, "asset_integrity_mismatch")
    assert component(document, "ffmpeg")["class"] == verify.UNVERIFIABLE


@pytest.mark.native_publication
def test_located_but_missing_directory_is_repair_required(tmp_path):
    _expect_failing(run({"drumsep_assets": tmp_path / "gone"}), "location_missing")


@pytest.mark.native_publication
def test_location_that_is_a_file_is_repair_required(tmp_path):
    target = tmp_path / "not-a-directory"
    target.write_bytes(b"x")
    _expect_failing(run({"drumsep_assets": target}), "location_not_directory")


@pytest.mark.native_publication
def test_asset_name_that_is_a_directory_is_repair_required(tmp_path):
    directory = make_asset_set(tmp_path)
    (directory / CONFIG).unlink()
    (directory / CONFIG).mkdir()
    _expect_failing(run({"drumsep_assets": directory}), "asset_not_regular_file")


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="requires FIFO support")
def test_fifo_asset_is_repair_required_without_blocking(tmp_path):
    directory = make_asset_set(tmp_path)
    (directory / CONFIG).unlink()
    os.mkfifo(directory / CONFIG)
    _expect_failing(run({"drumsep_assets": directory}), "asset_not_regular_file")


@pytest.mark.skipif(
    os.name == "nt" or (hasattr(os, "geteuid") and os.geteuid() == 0),
    reason="requires POSIX permissions and an unprivileged user",
)
def test_unreadable_asset_is_unverifiable_and_unknown(tmp_path):
    directory = make_asset_set(tmp_path)
    target = directory / CONFIG
    target.chmod(0)
    try:
        document = run({"drumsep_assets": directory})
    finally:
        target.chmod(0o600)
    entry = component(document, "drumsep_assets")
    assert (entry["class"], entry["reason_code"]) == (verify.UNVERIFIABLE, "asset_unreadable")
    assert document["installation_state"] == verify.UNKNOWN


def test_relative_location_is_unverifiable():
    document = run({"drumsep_assets": Path("relative") / "asset-set"})
    entry = component(document, "drumsep_assets")
    assert (entry["class"], entry["reason_code"]) == (verify.UNVERIFIABLE, "location_invalid")
    assert document["installation_state"] == verify.UNKNOWN


@pytest.mark.skipif(os.name == "nt", reason="requires unprivileged symlink creation")
def test_symlinked_asset_file_is_repair_required(tmp_path):
    directory = make_asset_set(tmp_path)
    elsewhere = tmp_path / "elsewhere.yaml"
    elsewhere.write_bytes(CONTENTS[CONFIG])
    (directory / CONFIG).unlink()
    (directory / CONFIG).symlink_to(elsewhere)
    _expect_failing(run({"drumsep_assets": directory}), "symlink_not_allowed")


@pytest.mark.native_publication
def test_linked_asset_directory_is_repair_required(tmp_path):
    real = make_asset_set(tmp_path, "real-set")
    link = tmp_path / "linked-set"
    make_directory_link(link, real)
    _expect_failing(run({"drumsep_assets": link}), "symlink_not_allowed")
    assert is_directory_link(link)
    assert {p.name for p in real.iterdir()} == set(CONTENTS) | {
        "stemwerk-materialization-receipt.v1.json"
    }


@pytest.mark.native_publication
def test_linked_ancestor_of_asset_directory_is_repair_required(tmp_path):
    real_root = tmp_path / "real-root"
    make_asset_set(real_root)
    root_link = tmp_path / "root-link"
    make_directory_link(root_link, real_root)
    _expect_failing(run({"drumsep_assets": root_link / "asset-set"}), "symlink_not_allowed")
    assert is_directory_link(root_link)


# --- verify writes nothing ---------------------------------------------------


def _snapshot(root: Path):
    entries = {}
    for current, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            path = Path(current) / name
            info = os.lstat(path)
            entry = (oct(info.st_mode), info.st_size, info.st_mtime_ns)
            if path.is_file() and not path.is_symlink():
                entry += (hashlib.sha256(path.read_bytes()).hexdigest(),)
            entries[str(path.relative_to(root))] = entry
    return entries


@pytest.mark.native_publication
def test_verify_writes_nothing(tmp_path, monkeypatch):
    good = make_asset_set(tmp_path, "good-set")
    bad = make_asset_set(tmp_path, "bad-set")
    (bad / CHECKPOINT).write_bytes(b"x" * len(CONTENTS[CHECKPOINT]))
    (bad / CONFIG).unlink()
    before = _snapshot(tmp_path)

    blocked = []

    def refuse(name):
        def guard(*args, **kwargs):
            blocked.append(name)
            raise AssertionError(f"verify attempted {name}")

        return guard

    for name in ("mkdir", "makedirs", "rename", "replace", "remove", "unlink", "rmdir",
                 "utime", "chmod", "link", "symlink", "truncate"):
        if hasattr(os, name):
            monkeypatch.setattr(os, name, refuse(f"os.{name}"))
    real_open = os.open
    write_flags = os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND

    def read_only_open(path, flags, *args, **kwargs):
        if flags & write_flags:
            blocked.append(f"os.open({path!r}, {flags:#x})")
            raise AssertionError("verify opened a file for writing")
        return real_open(path, flags, *args, **kwargs)

    monkeypatch.setattr(os, "open", read_only_open)
    try:
        documents = [
            run({"drumsep_assets": good}, verifiers=STUB_VERIFIERS),
            run({"drumsep_assets": bad}),
            run({"drumsep_assets": good, "ffmpeg": tmp_path / "ffmpeg"}),
            run({"drumsep_assets": tmp_path / "absent-set"}),
        ]
    finally:
        monkeypatch.undo()

    assert blocked == []
    assert [d["installation_state"] for d in documents] == [
        verify.PARTIAL,
        verify.REPAIR_REQUIRED,
        verify.UNKNOWN,
        verify.REPAIR_REQUIRED,
    ]
    assert _snapshot(tmp_path) == before


# --- document schema ---------------------------------------------------------

TOP_LEVEL_KEYS = [
    "kind",
    "schema_version",
    "descriptor_version",
    "module_id",
    "workflow_id",
    "engine_id",
    "display_name",
    "lookup",
    "installation_state",
    "decided_by_rule",
    "operation_in_progress",
    "operation_id",
    "lock_status",
    "components",
]
COMPONENT_KEYS = ["component_id", "kind", "class", "reason_code", "location"]
FILE_KEYS = ["name", "result", "expected_size", "observed_size", "expected_sha256"]


def test_document_schema_and_identity():
    document = verify.verify_module("drum_kit")
    assert list(document) == TOP_LEVEL_KEYS
    assert document["kind"] == "stemwerk_module_verification"
    assert document["schema_version"] == verify.SCHEMA_VERSION == "1.1.0"
    assert (document["operation_in_progress"], document["operation_id"],
            document["lock_status"]) == (False, None, "free")
    assert document["descriptor_version"] == descriptors.DESCRIPTOR_VERSION == "1.0.0"
    assert (document["module_id"], document["workflow_id"], document["engine_id"]) == (
        "drum_kit",
        "drum_kit_direct",
        "drumsep_mdx23c",
    )
    assert document["display_name"] == "STEMwerk DKS"
    assert [c["component_id"] for c in document["components"]] == list(ALL_COMPONENTS)
    for entry in document["components"]:
        assert list(entry) == COMPONENT_KEYS
        assert entry["class"] in verify.COMPONENT_CLASSES


def test_document_is_deterministic_json(tmp_path):
    directory = make_asset_set(tmp_path)
    locations = {"drumsep_assets": directory, "ffmpeg": tmp_path / "ffmpeg"}
    first = run(locations)
    second = run(locations)
    assert first == second
    text = json.dumps(first, ensure_ascii=False)
    assert json.loads(text) == first
    assert text == json.dumps(second, ensure_ascii=False)
    assets = component(first, "drumsep_assets")
    assert list(assets) == COMPONENT_KEYS + ["files"]
    assert [list(f) for f in assets["files"]] == [FILE_KEYS, FILE_KEYS]
    assert [f["name"] for f in assets["files"]] == [CHECKPOINT, CONFIG]


# --- running operation (install lock) -----------------------------------------


def write_lock(root, *, pid, start_token, host=None, age=3600.0):
    lock_paths = install_lock.LockPaths.for_root(root)
    lock_paths.directory.mkdir(parents=True, exist_ok=True)
    metadata = {
        "protocol": install_lock.LOCK_PROTOCOL,
        "operation_id": "6f1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
        "pid": pid,
        "start_token": start_token,
        "host": process_identity.host_name() if host is None else host,
        "created": install_lock._timestamp(time.time() - age),
    }
    lock_paths.lock.write_bytes(install_lock._encode(metadata))
    return metadata["operation_id"]


def own_lock(root, **kwargs):
    return write_lock(root, pid=os.getpid(),
                      start_token=process_identity.current_start_token(), **kwargs)


def tree_snapshot(root):
    return sorted((str(p), p.read_bytes() if p.is_file() else None) for p in root.rglob("*"))


def torn_lock(root, monkeypatch):
    lock = install_lock.LockPaths.for_root(root).lock
    lock.parent.mkdir(parents=True)
    lock.write_bytes(b"{torn")


def unprobeable_owner(root, monkeypatch):
    monkeypatch.setattr(process_identity, "probe_process",
                        lambda pid: process_identity.ProcessProbe(None, None))
    return write_lock(root, pid=os.getpid(), start_token="x")


# status: (prepare(root, monkeypatch), operation_in_progress, operation_id reported)
LOCK_CASES = {
    "free": (lambda root, monkeypatch: None, False, False),
    "held": (lambda root, monkeypatch: own_lock(root), True, True),
    "stale": (lambda root, monkeypatch: write_lock(root, pid=os.getpid(), start_token="reused"),
              False, True),
    "unreadable": (torn_lock, None, False),
    "unsupported": (unprobeable_owner, None, True),
    "foreign_host": (lambda root, monkeypatch: own_lock(root, host="another-host.example"),
                     None, True),
}


@pytest.mark.native_publication
@pytest.mark.parametrize("status", sorted(LOCK_CASES))
def test_verify_reports_the_lock_without_taking_it(isolated_runtime_root, monkeypatch, status):
    prepare, in_progress, has_id = LOCK_CASES[status]
    root = isolated_runtime_root
    root.mkdir()
    written = prepare(root, monkeypatch)
    before = tree_snapshot(root)

    def refuse(*args):
        raise AssertionError("verify must never take the install lock")

    monkeypatch.setattr(install_lock, "_os_lock", refuse)
    monkeypatch.setattr(install_lock, "_os_unlock", refuse)
    document = verify.verify_module("drum_kit")
    assert tree_snapshot(root) == before
    assert document["lock_status"] == status
    assert document["operation_in_progress"] is in_progress
    assert document["operation_id"] == (written if has_id else None)
    assert document["installation_state"] == verify.NOT_INSTALLED


@pytest.mark.native_publication
@pytest.mark.parametrize("held", [False, True])
def test_a_held_lock_never_changes_the_installation_state(tmp_path, held):
    directory = make_asset_set(tmp_path)
    locations = {component: tmp_path / "x" for component in NON_ASSET_COMPONENTS}
    locations["drumsep_assets"] = directory
    root = tmp_path / "root"
    lock = install_lock.acquire(root, str(uuid.uuid4())) if held else None
    try:
        documents = [
            verify.verify_descriptor(fixture_descriptor(), lookup=FixtureLookup(locations),
                                     verifiers=STUB_VERIFIERS, root=root),
            verify.verify_descriptor(fixture_descriptor(), lookup=FixtureLookup({}), root=root),
            verify.verify_descriptor(fixture_descriptor(), lookup=FixtureLookup(
                {"drumsep_assets": directory, "ffmpeg": tmp_path / "ffmpeg"}), root=root),
        ]
    finally:
        if lock is not None:
            lock.release()
    assert [d["installation_state"] for d in documents] == [
        verify.INSTALLED, verify.NOT_INSTALLED, verify.UNKNOWN]
    for document in documents:
        assert document["operation_in_progress"] is held
        assert document["lock_status"] == ("held" if held else "free")
        assert document["operation_id"] == (lock.operation_id if held else None)


@pytest.mark.native_publication
def test_cli_verify_in_another_process_sees_the_held_lock(isolated_runtime_root):
    from tests.cli_harness import run_cli, single_json_line

    with install_lock.acquire(isolated_runtime_root, str(uuid.uuid4())) as lock:
        result = run_cli(["-m", "stemwerk_core.module_install", "verify", "--module", "drum_kit"])
        assert install_lock.os_lock_is_free(lock.paths.lock) is False
    assert result.returncode == 0, result.stderr
    document = single_json_line(result.stdout)
    assert (document["operation_in_progress"], document["operation_id"],
            document["lock_status"]) == (True, lock.operation_id, "held")
    assert document["installation_state"] == "not_installed"
    assert document["schema_version"] == "1.1.0"


@pytest.mark.native_publication
@pytest.mark.parametrize("name", ["Testgerät", "beñat"])
def test_verify_lock_report_in_non_ascii_roots(tmp_path, name):
    root = tmp_path / name / "STEMwerk"
    root.parent.mkdir()
    with install_lock.acquire(root, str(uuid.uuid4())) as lock:
        document = verify.verify_module("drum_kit", root=root)
    assert (document["operation_in_progress"], document["operation_id"]) == (True, lock.operation_id)
    assert verify.verify_module("drum_kit", root=root)["lock_status"] == "free"
