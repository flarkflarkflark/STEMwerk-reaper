"""Portable tests for bounded, offline DrumSep asset materialization."""
from __future__ import annotations

import errno
import hashlib
import json
import multiprocessing
import os
from pathlib import Path
import shutil
import sys
import threading
import uuid

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import asset_materialization as materialization  # noqa: E402

pytestmark = pytest.mark.portable
NATIVE_PUBLICATION = (
    sys.platform.startswith("linux") or sys.platform in {"darwin", "win32"}
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def controlled_request(tmp_path: Path):
    names = ("controlled-model.ckpt", "controlled-model.yaml")
    contents = {
        names[0]: b"controlled checkpoint\r\nbare-lf\n\x1a\x00tail\n",
        names[1]: b"controlled config\r\nbare-lf\n\x1a\x00tail\n",
    }
    source_dir = tmp_path / "sources"
    source_dir.mkdir(parents=True)
    sources = {}
    for name, content in contents.items():
        path = source_dir / name
        path.write_bytes(content)
        sources[name] = path
    policy = materialization._TrustedAssetPolicy(
        policy_id="tests.controlled-assets",
        assets=tuple((name, sha256(contents[name])) for name in names),
    )
    request = materialization.MaterializationRequest(
        sources=sources,
        destination=tmp_path / "published-assets",
    )
    return policy, request, contents


@pytest.mark.native_publication
@pytest.mark.skipif(not NATIVE_PUBLICATION, reason="requires a supported native publisher")
def test_every_descriptor_open_requests_binary_mode(tmp_path, monkeypatch):
    sentinel = 1 << 30
    real_binary = getattr(os, "O_BINARY", 0)
    real_open = os.open
    recorded = []

    def recording_open(path, flags, *args, **kwargs):
        recorded.append((Path(path).name, flags))
        return real_open(path, (flags & ~sentinel) | real_binary, *args, **kwargs)

    policy, request, contents = controlled_request(tmp_path)
    monkeypatch.setattr(os, "O_BINARY", sentinel, raising=False)
    monkeypatch.setattr(os, "open", recording_open)

    result = materialization._materialize_asset_set(request, policy)

    # validation (2) + lock (1) + copy source/target (4) + receipt (1)
    assert len(recorded) >= 8
    missing = [name for name, flags in recorded if not flags & sentinel]
    assert missing == []
    for name, expected in contents.items():
        assert (Path(result["destination"]) / name).read_bytes() == expected


@pytest.mark.native_publication
@pytest.mark.skipif(not NATIVE_PUBLICATION, reason="requires a supported native publisher")
def test_materializes_complete_verified_set_and_consistent_receipt(tmp_path):
    policy, request, contents = controlled_request(tmp_path)

    result = materialization._materialize_asset_set(request, policy)

    destination = Path(result["destination"])
    assert result["kind"] == "stemwerk_asset_materialization_result"
    assert result["outcome"] == "success"
    assert result["cleanup"] == {"complete": True, "remaining_paths": []}
    assert destination == request.destination
    assert sorted(path.name for path in destination.iterdir()) == [
        "controlled-model.ckpt",
        "controlled-model.yaml",
        materialization.RECEIPT_FILENAME,
    ]
    for name, expected in contents.items():
        target = destination / name
        assert target.read_bytes() == expected
        assert target.stat().st_ino != Path(request.sources[name]).stat().st_ino

    receipt = json.loads((destination / materialization.RECEIPT_FILENAME).read_text())
    assert receipt == result["receipt"]
    assert receipt["kind"] == "stemwerk_asset_materialization_receipt"
    assert receipt["schema_version"] == "1.0.0"
    uuid.UUID(receipt["operation"]["operation_id"])
    assert receipt["operation"]["destination"] == str(destination)
    assert receipt["policy"]["policy_id"] == policy.policy_id
    assert receipt["policy"]["policy_sha256"] == policy.fingerprint
    assert receipt["artifacts"] == [
        {"name": name, "sha256": expected_hash}
        for name, expected_hash in policy.assets
    ]
    assert receipt["created"] == [
        *(name for name, _ in policy.assets),
        materialization.RECEIPT_FILENAME,
    ]
    assert receipt["verification"] == {
        "outcome": "sha256_verified",
        "verified_artifacts": [name for name, _ in policy.assets],
    }
    assert receipt["limits"]["runtime_readiness_established"] is False
    assert receipt["limits"]["complete_module_installation"] is False


def test_validation_is_separate_and_does_not_mutate(tmp_path):
    policy, request, _ = controlled_request(tmp_path)

    validation = materialization._validate_asset_set(request, policy)

    assert validation.destination == request.destination
    assert not request.destination.exists()
    assert list(tmp_path.glob(".*.stemwerk-*")) == []


def test_rejects_incomplete_source_mapping_before_mutation(tmp_path):
    policy, request, _ = controlled_request(tmp_path)
    request = materialization.MaterializationRequest(
        sources={next(iter(request.sources.items()))[0]: next(iter(request.sources.items()))[1]},
        destination=request.destination,
    )

    with pytest.raises(materialization.MaterializationError, match="complete trusted asset set") as exc:
        materialization._materialize_asset_set(request, policy)

    assert exc.value.code == "incomplete_asset_set"
    assert not request.destination.exists()


def test_rejects_missing_or_corrupt_sources_before_mutation(tmp_path):
    policy, request, _ = controlled_request(tmp_path)
    missing_name = policy.assets[0][0]
    Path(request.sources[missing_name]).unlink()
    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._materialize_asset_set(request, policy)
    assert exc.value.code == "source_missing"
    assert not request.destination.exists()

    policy, request, _ = controlled_request(tmp_path / "second")
    corrupt_name = policy.assets[0][0]
    Path(request.sources[corrupt_name]).write_bytes(b"wrong")
    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._materialize_asset_set(request, policy)
    assert exc.value.code == "source_integrity_mismatch"
    assert not request.destination.exists()


@pytest.mark.skipif(
    os.name == "nt" or (hasattr(os, "geteuid") and os.geteuid() == 0),
    reason="requires POSIX permissions and an unprivileged user",
)
def test_rejects_unreadable_source_before_mutation(tmp_path):
    policy, request, _ = controlled_request(tmp_path)
    name = policy.assets[0][0]
    source = Path(request.sources[name])
    source.chmod(0)
    try:
        with pytest.raises(materialization.MaterializationError) as exc:
            materialization._materialize_asset_set(request, policy)
        assert exc.value.code == "source_unreadable"
        assert not request.destination.exists()
    finally:
        source.chmod(0o600)


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="requires FIFO support")
def test_rejects_fifo_source_without_blocking(tmp_path):
    policy, request, _ = controlled_request(tmp_path)
    name = policy.assets[0][0]
    source = Path(request.sources[name])
    source.unlink()
    os.mkfifo(source)

    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._materialize_asset_set(request, policy)

    assert exc.value.code == "source_not_regular"
    assert not request.destination.exists()


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="requires FIFO support")
def test_rejects_fifo_substitution_before_copy_without_blocking(tmp_path):
    policy, request, _ = controlled_request(tmp_path)
    validated = materialization._validate_asset_set(request, policy)
    source = validated.sources[0]
    source.path.unlink()
    os.mkfifo(source.path)

    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._copy_validated_source(source, tmp_path / "copy")

    assert exc.value.code == "source_changed"
    assert not (tmp_path / "copy").exists()


def _create_destination_object(destination: Path, kind: str) -> Path:
    if kind == "file":
        destination.write_text("existing")
        return destination
    target = destination
    if kind == "link":
        target = destination.parent / f"{destination.name}-link-target"
    target.mkdir()
    marker = target / "keep.txt"
    marker.write_text("existing")
    if kind == "link":
        try:
            destination.symlink_to(target, target_is_directory=True)
        except OSError as exc:
            pytest.skip(f"directory symlink creation unavailable: {exc}")
    return marker


@pytest.mark.native_publication
@pytest.mark.skipif(not NATIVE_PUBLICATION, reason="requires a supported native publisher")
@pytest.mark.parametrize("kind", ["file", "directory", "link"])
def test_existing_destination_is_preserved(tmp_path, kind):
    policy, request, _ = controlled_request(tmp_path)
    sentinel = _create_destination_object(request.destination, kind)

    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._materialize_asset_set(request, policy)

    assert exc.value.code == "destination_exists"
    assert sentinel.read_text() == "existing"


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("source", Path("relative/source.ckpt")),
        ("destination", Path("relative/destination")),
        ("destination", Path("/tmp/parent/../destination")),
    ],
)
def test_rejects_relative_or_traversing_paths(tmp_path, field, value):
    policy, request, _ = controlled_request(tmp_path)
    sources = dict(request.sources)
    destination = request.destination
    if field == "source":
        sources[policy.assets[0][0]] = value
    else:
        destination = value

    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._materialize_asset_set(
            materialization.MaterializationRequest(sources, destination), policy
        )

    assert exc.value.code == "invalid_path"
    assert not request.destination.exists()


@pytest.mark.skipif(os.name == "nt", reason="requires unprivileged symlink creation")
def test_rejects_source_and_destination_symlink_redirection(tmp_path):
    policy, request, _ = controlled_request(tmp_path)
    name = policy.assets[0][0]
    source_link = tmp_path / "source-link"
    source_link.symlink_to(request.sources[name])
    sources = {**request.sources, name: source_link}
    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._materialize_asset_set(
            materialization.MaterializationRequest(sources, request.destination), policy
        )
    assert exc.value.code == "symlink_not_allowed"

    real_parent = tmp_path / "real-parent"
    real_parent.mkdir()
    parent_link = tmp_path / "parent-link"
    parent_link.symlink_to(real_parent, target_is_directory=True)
    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._materialize_asset_set(
            materialization.MaterializationRequest(
                request.sources, parent_link / "destination"
            ),
            policy,
        )
    assert exc.value.code == "symlink_not_allowed"


def test_rejects_source_destination_alias_and_duplicate_source_inode(tmp_path):
    policy, request, _ = controlled_request(tmp_path)
    source = Path(request.sources[policy.assets[0][0]])
    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._materialize_asset_set(
            materialization.MaterializationRequest(request.sources, source), policy
        )
    assert exc.value.code == "source_destination_alias"
    assert source.is_file()

    duplicate_policy = materialization._TrustedAssetPolicy(
        "tests.same-content",
        (("first.bin", sha256(b"same")), ("second.bin", sha256(b"same"))),
    )
    first = tmp_path / "first.bin"
    second = tmp_path / "second.bin"
    first.write_bytes(b"same")
    os.link(first, second)
    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._materialize_asset_set(
            materialization.MaterializationRequest(
                {"first.bin": first, "second.bin": second}, tmp_path / "duplicate"
            ),
            duplicate_policy,
        )
    assert exc.value.code == "source_conflict"


def test_interrupted_copy_cleans_only_owned_temporary_material(tmp_path):
    policy, request, _ = controlled_request(tmp_path)

    def interrupted(source, target):
        target.write_bytes(b"partial")
        raise OSError("simulated interruption")

    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._materialize_asset_set(
            request, policy, copy_file=interrupted
        )

    assert exc.value.code == "materialization_failed"
    assert exc.value.cleanup_remaining == ()
    assert not request.destination.exists()
    assert sorted(path.name for path in tmp_path.iterdir()) == ["sources"]


def test_keyboard_interrupt_cleans_only_owned_temporary_material(tmp_path):
    policy, request, _ = controlled_request(tmp_path)

    def interrupted(source, target):
        target.write_bytes(b"partial")
        raise KeyboardInterrupt

    with pytest.raises(KeyboardInterrupt):
        materialization._materialize_asset_set(
            request, policy, copy_file=interrupted
        )

    assert not request.destination.exists()
    assert sorted(path.name for path in tmp_path.iterdir()) == ["sources"]


def test_keyboard_interrupt_during_lock_write_does_not_leak_lock(
    tmp_path, monkeypatch
):
    policy, request, _ = controlled_request(tmp_path)

    def interrupt_write(handle, payload):
        raise KeyboardInterrupt

    monkeypatch.setattr(materialization.os, "write", interrupt_write)
    with pytest.raises(KeyboardInterrupt) as exc:
        materialization._materialize_asset_set(request, policy)

    assert exc.value.published is False
    assert exc.value.cleanup_remaining == ()
    assert exc.value.destination == str(request.destination)
    assert exc.value.receipt_path is None
    assert exc.value.operation_id
    assert sorted(path.name for path in tmp_path.iterdir()) == ["sources"]


def test_lock_write_error_reports_incomplete_local_cleanup(tmp_path, monkeypatch):
    policy, request, _ = controlled_request(tmp_path)
    real_cleanup = materialization._cleanup_owned

    def fail_write(handle, payload):
        raise OSError("simulated lock write failure")

    def fail_lock_cleanup(owned):
        if owned is not None and not owned.is_directory:
            return [str(owned.path)]
        return real_cleanup(owned)

    monkeypatch.setattr(materialization.os, "write", fail_write)
    monkeypatch.setattr(materialization, "_cleanup_owned", fail_lock_cleanup)
    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._materialize_asset_set(request, policy)

    lock_path = request.destination.parent / (
        f".{request.destination.name}.stemwerk-materialize.lock"
    )
    assert exc.value.code == "materialization_failed"
    assert exc.value.cleanup_remaining == (str(lock_path),)
    assert lock_path.is_file()
    lock_path.unlink()


def test_incomplete_copy_cannot_publish_or_report_success(tmp_path):
    policy, request, _ = controlled_request(tmp_path)

    def incomplete_copy(source, target):
        target.write_bytes(b"partial")

    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._materialize_asset_set(
            request, policy, copy_file=incomplete_copy
        )

    assert exc.value.code == "staged_integrity_mismatch"
    assert not request.destination.exists()
    assert sorted(path.name for path in tmp_path.iterdir()) == ["sources"]


def test_publication_failure_preserves_destination_absence_and_cleans(tmp_path):
    policy, request, _ = controlled_request(tmp_path)

    def fail_publication(staging, destination):
        raise materialization.MaterializationError(
            "publication_failed", "simulated publication failure"
        )

    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._materialize_asset_set(
            request, policy, publish=fail_publication
        )

    assert exc.value.code == "publication_failed"
    assert not request.destination.exists()
    assert sorted(path.name for path in tmp_path.iterdir()) == ["sources"]


@pytest.mark.native_publication
@pytest.mark.skipif(not NATIVE_PUBLICATION, reason="requires a supported native publisher")
def test_failure_after_publication_reports_destination_and_receipt(tmp_path):
    policy, request, _ = controlled_request(tmp_path)

    def publish_then_fail(staging, destination):
        materialization._publish_noreplace(staging, destination)
        raise OSError("simulated failure after publication")

    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._materialize_asset_set(
            request, policy, publish=publish_then_fail
        )

    receipt = request.destination / materialization.RECEIPT_FILENAME
    assert exc.value.code == "materialization_failed"
    assert exc.value.published is True
    assert exc.value.destination == str(request.destination)
    assert exc.value.receipt_path == str(receipt)
    receipt_operation_id = json.loads(receipt.read_text())["operation"]["operation_id"]
    assert exc.value.operation_id == receipt_operation_id
    error = materialization._error_document(exc.value)["error"]
    assert error["published"] is True
    assert error["destination"] == str(request.destination)
    assert error["receipt_path"] == str(receipt)
    with pytest.raises(materialization.MaterializationError) as retry:
        materialization._materialize_asset_set(request, policy)
    assert retry.value.code == "destination_exists"


@pytest.mark.native_publication
@pytest.mark.skipif(not NATIVE_PUBLICATION, reason="requires a supported native publisher")
def test_interrupt_after_publication_preserves_original_with_context(tmp_path):
    policy, request, _ = controlled_request(tmp_path)

    def publish_then_interrupt(staging, destination):
        materialization._publish_noreplace(staging, destination)
        raise KeyboardInterrupt

    with pytest.raises(KeyboardInterrupt) as exc:
        materialization._materialize_asset_set(
            request, policy, publish=publish_then_interrupt
        )

    receipt = request.destination / materialization.RECEIPT_FILENAME
    assert exc.value.published is True
    assert exc.value.cleanup_remaining == ()
    assert exc.value.destination == str(request.destination)
    assert exc.value.receipt_path == str(receipt)
    assert exc.value.operation_id == json.loads(receipt.read_text())["operation"][
        "operation_id"
    ]
    assert receipt.is_file()


@pytest.mark.native_publication
@pytest.mark.skipif(not NATIVE_PUBLICATION, reason="requires a supported native publisher")
def test_publication_identity_survives_receipt_read_failure(tmp_path, monkeypatch):
    policy, request, _ = controlled_request(tmp_path)
    receipt = request.destination / materialization.RECEIPT_FILENAME
    real_read_text = Path.read_text

    def publish_then_fail(staging, destination):
        materialization._publish_noreplace(staging, destination)

        def fail_published_receipt(path, *args, **kwargs):
            if path == receipt:
                raise PermissionError("simulated receipt read failure")
            return real_read_text(path, *args, **kwargs)

        monkeypatch.setattr(Path, "read_text", fail_published_receipt)
        raise OSError("simulated failure after publication")

    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._materialize_asset_set(
            request, policy, publish=publish_then_fail
        )

    assert exc.value.published is True
    assert exc.value.destination == str(request.destination)
    assert exc.value.receipt_path == str(receipt)
    assert receipt.is_file()


@pytest.mark.native_publication
@pytest.mark.skipif(not NATIVE_PUBLICATION, reason="requires a supported native publisher")
def test_unknown_publication_state_is_not_reported_as_absent(tmp_path, monkeypatch):
    policy, request, _ = controlled_request(tmp_path)
    real_lstat = os.lstat

    def publish_then_hide_destination(staging, destination):
        materialization._publish_noreplace(staging, destination)

        def fail_destination_inspection(path):
            if Path(path) == destination:
                raise PermissionError("simulated destination inspection failure")
            return real_lstat(path)

        monkeypatch.setattr(materialization.os, "lstat", fail_destination_inspection)
        raise OSError("simulated failure after publication")

    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._materialize_asset_set(
            request, policy, publish=publish_then_hide_destination
        )

    assert exc.value.published is None
    assert exc.value.destination == str(request.destination)
    assert exc.value.receipt_path == str(
        request.destination / materialization.RECEIPT_FILENAME
    )
    assert request.destination.is_dir()


def test_unsupported_platform_fails_without_publication_fallback(
    tmp_path, monkeypatch
):
    staging = tmp_path / "staging"
    staging.mkdir()
    destination = tmp_path / "destination"
    monkeypatch.setattr(materialization.sys, "platform", "unsupported-os")

    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._publish_noreplace(staging, destination)

    assert exc.value.code == "publication_unsupported"
    assert staging.is_dir()
    assert not destination.exists()


@pytest.mark.simulated_publication_adapter
@pytest.mark.parametrize(
    ("error", "expected_code"),
    [
        (errno.EEXIST, "publication_conflict"),
        (errno.ENOTEMPTY, "publication_conflict"),
        (errno.EINVAL, "publication_unsupported"),
        (errno.EXDEV, "publication_unsupported"),
        (errno.EPERM, "publication_failed"),
    ],
)
def test_simulated_linux_adapter_reports_operation_errno_and_paths(
    tmp_path, error, expected_code
):
    calls = []

    def renameat2(source_dirfd, source, destination_dirfd, destination, flags):
        calls.append((source_dirfd, source, destination_dirfd, destination, flags))
        return -1

    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._publish_linux_noreplace(
            tmp_path / "staging",
            tmp_path / "destination",
            renameat2=renameat2,
            get_errno=lambda: error,
        )

    assert exc.value.code == expected_code
    message = str(exc.value)
    assert "renameat2(RENAME_NOREPLACE)" in message
    assert f"{errno.errorcode[error]} ({error}:" in message
    assert f"staging={tmp_path / 'staging'}" in message
    assert f"destination={tmp_path / 'destination'}" in message
    assert len(calls) == 1 and calls[0][4] == 1


@pytest.mark.simulated_publication_adapter
@pytest.mark.parametrize(
    ("error", "expected_code"),
    [
        (errno.EEXIST, "publication_conflict"),
        (errno.EXDEV, "publication_unsupported"),
        (errno.EACCES, "publication_failed"),
    ],
)
def test_simulated_macos_adapter_maps_errors_without_fallback(
    tmp_path, error, expected_code
):
    calls = []

    def renamex_np(source, destination, flags):
        calls.append((source, destination, flags))
        return -1

    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._publish_macos_noreplace(
            tmp_path / "staging-ë",
            tmp_path / "destination-ë",
            renamex_np=renamex_np,
            get_errno=lambda: error,
        )

    assert exc.value.code == expected_code
    message = str(exc.value)
    assert "renamex_np(RENAME_EXCL)" in message
    assert f"{errno.errorcode[error]} ({error}:" in message
    assert f"staging={tmp_path / 'staging-ë'}" in message
    assert f"destination={tmp_path / 'destination-ë'}" in message
    assert calls == [
        (
            os.fsencode(tmp_path / "staging-ë"),
            os.fsencode(tmp_path / "destination-ë"),
            0x00000004,
        )
    ]


@pytest.mark.simulated_publication_adapter
@pytest.mark.parametrize(
    ("error", "expected_code"),
    [
        (80, "publication_conflict"),
        (183, "publication_conflict"),
        (17, "publication_unsupported"),
        (50, "publication_unsupported"),
        (32, "publication_failed"),
    ],
)
def test_simulated_windows_adapter_uses_unicode_and_maps_errors(
    tmp_path, error, expected_code
):
    calls = []

    def move_file_ex(source, destination, flags):
        calls.append((source, destination, flags))
        return 0

    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._publish_windows_noreplace(
            tmp_path / "staging-ë",
            tmp_path / "destination-ë",
            move_file_ex=move_file_ex,
            get_last_error=lambda: error,
        )

    assert exc.value.code == expected_code
    message = str(exc.value)
    assert "MoveFileExW(flags=0)" in message
    assert f"GetLastError={error}" in message
    assert f"staging={tmp_path / 'staging-ë'}" in message
    assert f"destination={tmp_path / 'destination-ë'}" in message
    if error == 32:
        assert "ERROR_SHARING_VIOLATION" in message
    assert calls == [
        (str(tmp_path / "staging-ë"), str(tmp_path / "destination-ë"), 0)
    ]


@pytest.mark.simulated_publication_adapter
def test_simulated_windows_existing_directory_maps_access_denied_to_conflict(
    tmp_path,
):
    destination = tmp_path / "destination"
    destination.mkdir()
    sentinel = destination / "keep"
    sentinel.write_text("existing")

    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._publish_windows_noreplace(
            tmp_path / "staging",
            destination,
            move_file_ex=lambda source, target, flags: 0,
            get_last_error=lambda: 5,
        )

    assert exc.value.code == "publication_conflict"
    assert sentinel.read_text() == "existing"


@pytest.mark.simulated_publication_adapter
def test_simulated_platform_adapters_return_only_after_native_success(tmp_path):
    mac_calls = []
    windows_calls = []

    materialization._publish_macos_noreplace(
        tmp_path / "mac-stage",
        tmp_path / "mac-destination",
        renamex_np=lambda source, destination, flags: mac_calls.append(
            (source, destination, flags)
        )
        or 0,
    )
    materialization._publish_windows_noreplace(
        tmp_path / "windows-stage",
        tmp_path / "windows-destination",
        move_file_ex=lambda source, destination, flags: windows_calls.append(
            (source, destination, flags)
        )
        or 1,
    )

    assert mac_calls[0][2] == 0x00000004
    assert windows_calls[0][2] == 0


@pytest.mark.simulated_publication_adapter
@pytest.mark.parametrize(
    ("platform", "loader_name", "platform_id"),
    [
        ("linux", "_linux_renameat2", "linux_renameat2_noreplace"),
        ("darwin", "_macos_renamex_np", "macos_renamex_np_exclusive"),
        ("win32", "_windows_move_file_ex", "windows_movefileexw_noreplace"),
    ],
)
def test_preflight_reports_api_support_without_publication(
    tmp_path, monkeypatch, platform, loader_name, platform_id
):
    calls = []
    monkeypatch.setattr(materialization.sys, "platform", platform)
    monkeypatch.setattr(materialization, loader_name, lambda: calls.append(loader_name))

    result = materialization.preflight_drumsep_materialization(tmp_path / "new")

    assert result["outcome"] == "validated"
    assert result["publication_platform"] == platform_id
    assert calls == [loader_name]
    assert not (tmp_path / "new").exists()


def test_materialization_cleans_when_platform_is_unsupported(tmp_path, monkeypatch):
    policy, request, _ = controlled_request(tmp_path)
    monkeypatch.setattr(materialization.sys, "platform", "unsupported-os")

    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._materialize_asset_set(request, policy)

    assert exc.value.code == "publication_unsupported"
    assert exc.value.published is False
    assert exc.value.destination == str(request.destination)
    assert exc.value.receipt_path is None
    assert not request.destination.exists()
    assert sorted(path.name for path in tmp_path.iterdir()) == ["sources"]


@pytest.mark.native_publication
@pytest.mark.skipif(not NATIVE_PUBLICATION, reason="requires a supported native publisher")
@pytest.mark.parametrize("kind", ["file", "directory", "link"])
def test_destination_appearing_at_publication_is_not_replaced(tmp_path, kind):
    policy, request, _ = controlled_request(tmp_path)

    def competing_publication(staging, destination):
        _create_destination_object(destination, kind)
        materialization._publish_noreplace(staging, destination)

    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._materialize_asset_set(
            request, policy, publish=competing_publication
        )

    assert exc.value.code == "publication_conflict"
    sentinel = (
        request.destination
        if kind == "file"
        else (
            request.destination.parent / f"{request.destination.name}-link-target"
            if kind == "link"
            else request.destination
        )
        / "keep.txt"
    )
    assert sentinel.read_text() == "existing"
    assert not list(tmp_path.glob(".*.stemwerk-*"))


@pytest.mark.native_publication
@pytest.mark.skipif(not NATIVE_PUBLICATION, reason="requires a supported native publisher")
def test_competing_attempt_fails_while_first_owns_lock(tmp_path):
    policy, request, _ = controlled_request(tmp_path)
    copying = threading.Event()
    release = threading.Event()
    result = {}

    def blocking_copy(source, target):
        if not copying.is_set():
            copying.set()
            assert release.wait(5)
        materialization._copy_validated_source(source, target)

    def first_attempt():
        result["value"] = materialization._materialize_asset_set(
            request, policy, copy_file=blocking_copy
        )

    thread = threading.Thread(target=first_attempt)
    thread.start()
    assert copying.wait(5)
    try:
        with pytest.raises(materialization.MaterializationError) as exc:
            materialization._materialize_asset_set(request, policy)
        assert exc.value.code == "publication_conflict"
    finally:
        release.set()
        thread.join(10)
    assert not thread.is_alive()
    assert result["value"]["outcome"] == "success"


def _materialize_in_process(policy, request, output, copying=None, release=None):
    def controlled_copy(source, target):
        if copying is not None and not copying.is_set():
            copying.set()
            if not release.wait(10):
                raise RuntimeError("timed out waiting to release first process")
        materialization._copy_validated_source(source, target)

    try:
        result = materialization._materialize_asset_set(
            request,
            policy,
            copy_file=controlled_copy if copying is not None else None,
        )
    except materialization.MaterializationError as exc:
        output.put(("error", exc.code, exc.published))
    else:
        output.put(("success", result["destination"], True))


@pytest.mark.native_publication
@pytest.mark.skipif(not NATIVE_PUBLICATION, reason="requires a supported native publisher")
def test_competing_processes_cannot_both_publish(tmp_path):
    policy, request, _ = controlled_request(tmp_path)
    context = multiprocessing.get_context(
        "spawn" if sys.platform in {"darwin", "win32"} else "fork"
    )
    copying = context.Event()
    release = context.Event()
    output = context.Queue()
    first = context.Process(
        target=_materialize_in_process,
        args=(policy, request, output, copying, release),
    )
    second = context.Process(
        target=_materialize_in_process,
        args=(policy, request, output),
    )

    first.start()
    assert copying.wait(10)
    second.start()
    second.join(10)
    release.set()
    first.join(10)

    assert not first.is_alive()
    assert not second.is_alive()
    assert first.exitcode == second.exitcode == 0
    outcomes = sorted(output.get(timeout=2) for _ in range(2))
    assert outcomes == [
        ("error", "publication_conflict", False),
        ("success", str(request.destination), True),
    ]
    assert sorted(path.name for path in request.destination.iterdir()) == [
        "controlled-model.ckpt",
        "controlled-model.yaml",
        materialization.RECEIPT_FILENAME,
    ]


def test_incomplete_cleanup_is_explicit_on_failure(tmp_path, monkeypatch):
    policy, request, _ = controlled_request(tmp_path)
    real_rmtree = shutil.rmtree

    def interrupted(source, target):
        target.write_bytes(b"partial")
        raise OSError("simulated interruption")

    def fail_cleanup(path):
        raise OSError("simulated cleanup failure")

    monkeypatch.setattr(materialization.shutil, "rmtree", fail_cleanup)
    with pytest.raises(materialization.MaterializationError) as exc:
        materialization._materialize_asset_set(
            request, policy, copy_file=interrupted
        )
    assert exc.value.cleanup_remaining
    assert all(Path(path).exists() for path in exc.value.cleanup_remaining)
    for path in exc.value.cleanup_remaining:
        if Path(path).is_dir():
            real_rmtree(path)


def test_cleanup_inspection_error_is_reported_without_removing_path(
    tmp_path, monkeypatch
):
    path = tmp_path / "owned-lock"
    path.write_text("owned")
    path_stat = path.stat()
    owned = materialization._OwnedPath(
        path, path_stat.st_dev, path_stat.st_ino, is_directory=False
    )

    def fail_inspection(candidate):
        raise PermissionError("simulated inspection failure")

    monkeypatch.setattr(materialization.os, "lstat", fail_inspection)
    assert materialization._cleanup_owned(owned) == [str(path)]
    assert path.read_text() == "owned"


@pytest.mark.simulated_publication_adapter
def test_cleanup_refuses_reparse_point_even_if_identity_matches(tmp_path, monkeypatch):
    path = tmp_path / "owned-stage"
    path.mkdir()
    path_stat = path.stat()
    owned = materialization._OwnedPath(
        path, path_stat.st_dev, path_stat.st_ino, is_directory=True
    )

    class ReparseStat:
        st_dev = path_stat.st_dev
        st_ino = path_stat.st_ino
        st_mode = path_stat.st_mode
        st_file_attributes = 0x400

    monkeypatch.setattr(materialization.os, "lstat", lambda candidate: ReparseStat())
    monkeypatch.setattr(
        materialization.shutil,
        "rmtree",
        lambda candidate: pytest.fail("reparse point must not be a cleanup target"),
    )

    assert materialization._cleanup_owned(owned) == [str(path)]
    assert path.is_dir()


@pytest.mark.native_publication
@pytest.mark.skipif(not NATIVE_PUBLICATION, reason="requires a supported native publisher")
def test_cleanup_preserves_content_substituted_at_owned_path(tmp_path):
    path = tmp_path / "owned-stage"
    path.mkdir()
    path_stat = path.stat()
    owned = materialization._OwnedPath(
        path, path_stat.st_dev, path_stat.st_ino, is_directory=True
    )
    original = tmp_path / "original-stage"
    path.rename(original)
    path.mkdir()
    sentinel = path / "unrelated"
    sentinel.write_text("preserve")

    assert materialization._cleanup_owned(owned) == [str(path)]
    assert sentinel.read_text() == "preserve"
    assert original.is_dir()


@pytest.mark.native_publication
@pytest.mark.skipif(not NATIVE_PUBLICATION, reason="requires a supported native publisher")
def test_post_publication_cleanup_failure_remains_success_with_receipt(
    tmp_path, monkeypatch
):
    policy, request, _ = controlled_request(tmp_path)
    real_cleanup = materialization._cleanup_owned

    def fail_lock_cleanup(owned):
        if owned is not None and not owned.is_directory:
            return [str(owned.path)]
        return real_cleanup(owned)

    monkeypatch.setattr(materialization, "_cleanup_owned", fail_lock_cleanup)
    result = materialization._materialize_asset_set(request, policy)

    assert result["outcome"] == "success"
    assert result["destination"] == str(request.destination)
    assert result["receipt_path"] == str(
        request.destination / materialization.RECEIPT_FILENAME
    )
    assert result["cleanup"]["complete"] is False
    assert result["cleanup"]["remaining_paths"]
    assert request.destination.is_dir()


def test_production_policy_is_bound_to_core_pins():
    policy = materialization._production_policy()
    assert dict(policy.assets) == materialization.model_assets.DIRECT_DKS_MODEL_EXPECTED_SHA256
    assert policy.policy_id == materialization.PRODUCTION_POLICY_ID


def test_cli_maps_explicit_flags_to_production_asset_names(tmp_path, monkeypatch, capsys):
    checkpoint = tmp_path / "input.ckpt"
    config = tmp_path / "input.yaml"
    destination = tmp_path / "destination"
    captured = {}

    def materialize(request):
        captured["request"] = request
        return {"kind": "result", "outcome": "success"}

    monkeypatch.setattr(materialization, "materialize_drumsep_assets", materialize)
    status = materialization.main(
        [
            "--checkpoint-source",
            str(checkpoint),
            "--config-source",
            str(config),
            "--destination",
            str(destination),
        ]
    )

    assert status == 0
    assert captured["request"] == materialization.MaterializationRequest(
        sources={
            materialization.model_assets.DIRECT_DKS_MODEL_FILENAME: checkpoint,
            materialization.model_assets.DIRECT_DKS_MODEL_YAML: config,
        },
        destination=destination,
    )
    output = capsys.readouterr()
    assert json.loads(output.out) == {"kind": "result", "outcome": "success"}
    assert output.err == ""


def test_cli_reports_structured_failure_and_incomplete_cleanup(
    tmp_path, monkeypatch, capsys
):
    remaining = tmp_path / "owned-stage"

    def fail(request):
        raise materialization.MaterializationError(
            "copy_failed",
            "controlled failure",
            cleanup_remaining=[str(remaining)],
        )

    monkeypatch.setattr(materialization, "materialize_drumsep_assets", fail)
    status = materialization.main(
        [
            "--checkpoint-source",
            str(tmp_path / "input.ckpt"),
            "--config-source",
            str(tmp_path / "input.yaml"),
            "--destination",
            str(tmp_path / "destination"),
        ]
    )

    assert status == 2
    output = capsys.readouterr()
    assert output.out == ""
    error = json.loads(output.err)
    assert error["error"] == {
        "code": "copy_failed",
        "message": "controlled failure",
        "published": False,
        "destination": None,
        "receipt_path": None,
        "cleanup_remaining": [str(remaining)],
    }
