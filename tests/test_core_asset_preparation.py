"""Portable composition tests for DrumSep asset preparation."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import asset_acquisition as acquisition  # noqa: E402
from stemwerk_core import asset_materialization as materialization  # noqa: E402
from stemwerk_core import asset_preparation as preparation  # noqa: E402

pytestmark = pytest.mark.portable


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def controlled_sources(tmp_path: Path):
    contents = {
        "controlled.ckpt": b"controlled checkpoint\r\nbare-lf\n\x1a\x00tail\n",
        "controlled.yaml": b"controlled config\r\nbare-lf\n\x1a\x00tail\n",
    }
    source_dir = tmp_path / "sources"
    source_dir.mkdir(parents=True)
    sources = {}
    for name, content in contents.items():
        path = source_dir / name
        path.write_bytes(content)
        sources[name] = path
    policy = materialization._TrustedAssetPolicy(
        "tests.preparation",
        tuple((name, sha256(content)) for name, content in contents.items()),
    )
    return sources, contents, policy


def controlled_materializer(policy):
    def materialize(request):
        return materialization._materialize_asset_set(request, policy)

    return materialize


@pytest.mark.native_publication
@pytest.mark.skipif(
    not (sys.platform.startswith("linux") or sys.platform in {"darwin", "win32"}),
    reason="requires a supported native publisher",
)
def test_local_source_success_preserves_sources_and_skips_acquisition(
    tmp_path, monkeypatch
):
    sources, contents, policy = controlled_sources(tmp_path)
    original = {name: path.read_bytes() for name, path in sources.items()}

    def unexpected_acquisition(request):  # pragma: no cover - assertion path
        raise AssertionError("local mode must not contact acquisition")

    monkeypatch.setattr(
        acquisition, "acquire_drumsep_sources", unexpected_acquisition
    )
    result = preparation._prepare_asset_set(
        preparation.PreparationRequest(
            destination=tmp_path / "published", local_sources=sources
        ),
        materialize=controlled_materializer(policy),
    )

    assert result["outcome"] == "success"
    assert result["phase"] == "complete"
    assert result["source_mode"] == "local"
    assert result["acquisition"] == {
        "requested": False,
        "completed": False,
        "evidence": None,
    }
    assert result["publication"]["state"] == "published"
    assert result["publication"]["operation_id"]
    assert result["publication"]["receipt_path"].endswith(
        materialization.RECEIPT_FILENAME
    )
    assert result["temporary_sources"]["created"] is False
    for name, path in sources.items():
        assert path.read_bytes() == original[name] == contents[name]


def controlled_acquirer(contents, policy):
    acquisition_policy = acquisition._AcquisitionPolicy(
        "tests.preparation-acquisition",
        tuple(
            acquisition._AssetSpec(
                name=name,
                sha256=sha256(content),
                size=len(content),
                sources=(
                    acquisition._SourceSpec(
                        source_id=name,
                        url=f"https://controlled.example/{name}",
                        redirect_hosts=("controlled.example",),
                    ),
                ),
                attempt_timeout=2,
                total_timeout=3,
            )
            for name, content in contents.items()
        ),
    )

    class Transport:
        def download(self, source, asset, target, *, deadline, target_identity):
            target.write_bytes(contents[asset.name])
            return acquisition._TransferEvidence("controlled.example", asset.size)

    def acquire(request):
        return acquisition._acquire_asset_set(
            request, acquisition_policy, transport=Transport()
        )

    return acquire


@pytest.mark.native_publication
@pytest.mark.skipif(
    not (sys.platform.startswith("linux") or sys.platform in {"darwin", "win32"}),
    reason="requires a supported native publisher",
)
def test_controlled_acquisition_then_publication_cleans_temporary_sources(tmp_path):
    _, contents, policy = controlled_sources(tmp_path)
    result = preparation._prepare_asset_set(
        preparation.PreparationRequest(
            destination=tmp_path / "published", acquire=True
        ),
        acquire=controlled_acquirer(contents, policy),
        materialize=controlled_materializer(policy),
        workspace_factory=lambda: tmp_path / "temporary-acquisition",
    )

    assert result["outcome"] == "success"
    assert result["source_mode"] == "acquire"
    assert result["acquisition"]["completed"] is True
    assert result["acquisition"]["evidence"]["outcome"] == "success"
    assert result["publication"]["state"] == "published"
    assert result["temporary_sources"]["cleanup"] == {
        "complete": True,
        "remaining_paths": [],
    }
    assert not (tmp_path / "temporary-acquisition").exists()


@pytest.mark.parametrize("mode", ["invalid_destination", "unsupported_platform"])
def test_preflight_failure_does_not_acquire(tmp_path, monkeypatch, mode):
    calls = []
    destination = Path("relative") if mode == "invalid_destination" else tmp_path / "out"
    if mode == "unsupported_platform":
        monkeypatch.setattr(materialization.sys, "platform", "unsupported-os")

    with pytest.raises(preparation.PreparationError) as exc:
        preparation._prepare_asset_set(
            preparation.PreparationRequest(destination=destination, acquire=True),
            acquire=lambda request: calls.append(request),
        )

    assert exc.value.phase == "validation"
    assert calls == []
    expected = "invalid_path" if mode == "invalid_destination" else "publication_unsupported"
    assert exc.value.code == expected


def test_acquisition_failure_never_invokes_materialization(tmp_path):
    materialization_calls = []

    def fail_acquisition(request):
        raise acquisition.AcquisitionError(
            "source_unavailable",
            "controlled failure",
            cleanup_remaining=(str(request.destination),),
            destination=str(request.destination),
        )

    with pytest.raises(preparation.PreparationError) as exc:
        preparation._prepare_asset_set(
            preparation.PreparationRequest(
                destination=tmp_path / "published", acquire=True
            ),
            acquire=fail_acquisition,
            materialize=lambda request: materialization_calls.append(request),
            workspace_factory=lambda: tmp_path / "temporary-acquisition",
        )

    assert exc.value.phase == "acquisition"
    assert exc.value.acquisition_completed is False
    assert exc.value.publication_state == "not_started"
    assert materialization_calls == []
    assert exc.value.primitive_error["error"]["code"] == "source_unavailable"


def test_acquisition_cleanup_failure_preserves_primary_error_and_leftover(tmp_path):
    workspace = tmp_path / "temporary-acquisition"

    def fail_acquisition(request):
        raise acquisition.AcquisitionError("source_unavailable", "controlled failure")

    def fail_cleanup(paths):
        raise OSError("controlled cleanup failure")

    with pytest.raises(preparation.PreparationError) as exc:
        preparation._prepare_asset_set(
            preparation.PreparationRequest(
                destination=tmp_path / "published", acquire=True
            ),
            acquire=fail_acquisition,
            workspace_factory=lambda: workspace,
            cleanup_owned=fail_cleanup,
        )

    assert exc.value.code == "source_unavailable"
    assert exc.value.phase == "acquisition"
    assert exc.value.cleanup_remaining == (str(workspace),)
    assert exc.value.temporary_sources_retained is True
    assert workspace.is_dir()


def test_materialization_failure_retains_acquisition_and_publication_evidence(tmp_path):
    _, contents, policy = controlled_sources(tmp_path)
    receipt_path = tmp_path / "published" / materialization.RECEIPT_FILENAME

    def fail_materialization(request):
        raise materialization.MaterializationError(
            "publication_failed",
            "publication state could not be established",
            published=None,
            destination=str(request.destination),
            receipt_path=str(receipt_path),
            operation_id="controlled-operation",
            cleanup_remaining=(str(tmp_path / "materializer-stage"),),
        )

    workspace = tmp_path / "temporary-acquisition"
    with pytest.raises(preparation.PreparationError) as exc:
        preparation._prepare_asset_set(
            preparation.PreparationRequest(
                destination=tmp_path / "published", acquire=True
            ),
            acquire=controlled_acquirer(contents, policy),
            materialize=fail_materialization,
            workspace_factory=lambda: workspace,
        )

    assert exc.value.phase == "publication"
    assert exc.value.acquisition_completed is True
    assert exc.value.publication_state == "unknown"
    assert exc.value.operation_id == "controlled-operation"
    assert exc.value.receipt_path == str(receipt_path)
    assert exc.value.acquisition_evidence["outcome"] == "success"
    assert str(workspace) in exc.value.cleanup_remaining
    assert workspace.exists()


def test_unconfirmed_materializer_result_is_not_reported_as_success(tmp_path):
    sources, _, _ = controlled_sources(tmp_path)

    with pytest.raises(preparation.PreparationError) as exc:
        preparation._prepare_asset_set(
            preparation.PreparationRequest(
                destination=tmp_path / "published", local_sources=sources
            ),
            materialize=lambda request: {"outcome": "success"},
        )

    assert exc.value.code == "publication_evidence_invalid"
    assert exc.value.phase == "publication"
    assert exc.value.publication_state == "unknown"


def test_publication_interrupt_retains_temporary_sources_and_state(tmp_path):
    _, contents, policy = controlled_sources(tmp_path)
    workspace = tmp_path / "temporary-acquisition"

    def interrupt(request):
        error = KeyboardInterrupt("publication cancelled")
        error.published = None
        error.operation_id = "interrupted-operation"
        error.receipt_path = str(
            request.destination / materialization.RECEIPT_FILENAME
        )
        error.cleanup_remaining = (str(tmp_path / "materializer-stage"),)
        raise error

    with pytest.raises(KeyboardInterrupt) as exc:
        preparation._prepare_asset_set(
            preparation.PreparationRequest(
                destination=tmp_path / "published", acquire=True
            ),
            acquire=controlled_acquirer(contents, policy),
            materialize=interrupt,
            workspace_factory=lambda: workspace,
        )

    assert exc.value.phase == "publication"
    assert exc.value.acquisition_completed is True
    assert exc.value.publication_state == "unknown"
    assert exc.value.operation_id == "interrupted-operation"
    assert str(workspace) in exc.value.cleanup_remaining
    assert workspace.exists()


def test_acquisition_interrupt_preserves_type_and_reports_cleanup(tmp_path):
    workspace = tmp_path / "temporary-acquisition"

    def interrupt(request):
        error = KeyboardInterrupt("cancelled")
        error.cleanup_remaining = (str(request.destination),)
        error.destination = str(request.destination)
        raise error

    with pytest.raises(KeyboardInterrupt) as exc:
        preparation._prepare_asset_set(
            preparation.PreparationRequest(
                destination=tmp_path / "published", acquire=True
            ),
            acquire=interrupt,
            workspace_factory=lambda: workspace,
        )

    assert exc.value.phase == "acquisition"
    assert exc.value.acquisition_completed is False
    assert exc.value.publication_state == "not_started"
    assert str(workspace / "sources") in exc.value.cleanup_remaining


def test_cleanup_failure_after_publication_reports_published_result(tmp_path):
    _, contents, policy = controlled_sources(tmp_path)
    workspace = tmp_path / "temporary-acquisition"

    with pytest.raises(preparation.PreparationError) as exc:
        preparation._prepare_asset_set(
            preparation.PreparationRequest(
                destination=tmp_path / "published", acquire=True
            ),
            acquire=controlled_acquirer(contents, policy),
            materialize=controlled_materializer(policy),
            workspace_factory=lambda: workspace,
            cleanup_owned=lambda paths: [str(workspace)],
        )

    assert exc.value.phase == "cleanup"
    assert exc.value.publication_state == "published"
    assert exc.value.operation_id
    assert exc.value.receipt_path
    assert exc.value.cleanup_remaining == (str(workspace),)
    assert (tmp_path / "published").is_dir()


def test_existing_destination_is_unchanged_before_source_work(tmp_path):
    destination = tmp_path / "published"
    destination.mkdir()
    marker = destination / "keep"
    marker.write_text("preserve", encoding="utf-8")
    calls = []

    with pytest.raises(preparation.PreparationError) as exc:
        preparation._prepare_asset_set(
            preparation.PreparationRequest(destination=destination, acquire=True),
            acquire=lambda request: calls.append(request),
        )

    assert exc.value.code == "destination_exists"
    assert calls == []
    assert marker.read_text(encoding="utf-8") == "preserve"


@pytest.mark.parametrize(
    "preparation_request",
    [
        preparation.PreparationRequest(destination=Path("/tmp/output")),
        preparation.PreparationRequest(
            destination=Path("/tmp/output"), local_sources={}, acquire=True
        ),
    ],
)
def test_requires_exactly_one_source_mode(preparation_request):
    with pytest.raises(preparation.PreparationError) as exc:
        preparation._prepare_asset_set(preparation_request)
    assert exc.value.code == "invalid_source_mode"


@pytest.mark.parametrize("acquire", [None, 0, 1, "yes", []])
def test_rejects_non_boolean_acquisition_request_before_side_effects(
    tmp_path, acquire
):
    calls = []
    request = preparation.PreparationRequest(
        destination=tmp_path / "published", acquire=acquire  # type: ignore[arg-type]
    )

    with pytest.raises(preparation.PreparationError) as exc:
        preparation._prepare_asset_set(
            request,
            preflight=lambda destination: calls.append(("preflight", destination)),
            acquire=lambda acquisition_request: calls.append(
                ("acquire", acquisition_request)
            ),
        )

    assert exc.value.code == "invalid_request"
    assert exc.value.phase == "validation"
    assert calls == []


def test_cli_builds_explicit_local_and_acquisition_requests(monkeypatch, tmp_path, capsys):
    seen = []

    def prepare(request):
        seen.append(request)
        return {"outcome": "success", "destination": str(request.destination)}

    monkeypatch.setattr(preparation, "prepare_drumsep_assets", prepare)
    checkpoint = tmp_path / "model.ckpt"
    config = tmp_path / "model.yaml"
    destination = tmp_path / "published"

    assert preparation.main(
        [
            "--destination",
            str(destination),
            "--checkpoint-source",
            str(checkpoint),
            "--config-source",
            str(config),
        ]
    ) == 0
    assert seen[-1].acquire is False
    assert set(seen[-1].local_sources.values()) == {checkpoint, config}
    json.loads(capsys.readouterr().out)

    assert preparation.main(
        ["--destination", str(destination), "--acquire"]
    ) == 0
    assert seen[-1].acquire is True
    assert seen[-1].local_sources is None


def test_cli_rejects_mixed_modes_without_calling_api(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(
        preparation,
        "prepare_drumsep_assets",
        lambda request: pytest.fail("invalid CLI must not call API"),
    )

    status = preparation.main(
        [
            "--destination",
            str(tmp_path / "published"),
            "--acquire",
            "--checkpoint-source",
            str(tmp_path / "model.ckpt"),
            "--config-source",
            str(tmp_path / "model.yaml"),
        ]
    )

    error = json.loads(capsys.readouterr().err)
    assert status == 2
    assert error["error"]["code"] == "invalid_source_mode"


LEAKY_INTERNAL_MESSAGE = "boom https://user:secret@example.invalid/x?token=SECRET"


def _key_shape(document):
    if isinstance(document, dict):
        return {key: _key_shape(value) for key, value in document.items()}
    return None


@pytest.mark.parametrize("error_type", [RuntimeError, TypeError])
def test_cli_unexpected_exception_is_a_redacted_internal_error(
    monkeypatch, tmp_path, capsys, error_type
):
    def fail(request):
        error = error_type(LEAKY_INTERNAL_MESSAGE)
        if hasattr(error, "add_note"):
            error.add_note(LEAKY_INTERNAL_MESSAGE)
        raise error

    monkeypatch.setattr(preparation, "prepare_drumsep_assets", fail)
    destination = str(tmp_path / "published")

    status = preparation.main(["--destination", destination, "--acquire"])

    captured = capsys.readouterr()
    assert status == 3
    assert captured.out == ""
    document = json.loads(captured.err)
    handled = preparation._error_document(
        preparation.PreparationError(
            "code",
            "message",
            phase="validation",
            source_mode=None,
            acquisition_completed=False,
            publication_state="not_started",
            destination=None,
        )
    )
    assert _key_shape(document) == _key_shape(handled)
    assert document["kind"] == "stemwerk_asset_preparation_error"
    assert document["schema_version"] == preparation.SCHEMA_VERSION
    assert document["outcome"] == "error"
    assert document["phase"] is None
    assert document["source_mode"] is None
    assert document["destination"] == destination
    assert document["acquisition"] == {"completed": None, "evidence": None}
    assert document["publication"] == {
        "state": "unknown",
        "operation_id": None,
        "receipt_path": None,
    }
    assert document["temporary_sources"] == {"path": None, "retained": None}
    assert document["cleanup"] == {"complete": None, "remaining_paths": None}
    assert document["error"] == {
        "code": "internal_error",
        "message": f"unexpected internal error ({error_type.__name__})",
        "primitive": None,
    }
    for leaked in ("secret", "SECRET", "token", "example.invalid", "boom"):
        assert leaked not in captured.err


def test_cli_keyboard_interrupt_is_not_converted(monkeypatch, tmp_path, capsys):
    def interrupt(request):
        raise KeyboardInterrupt

    monkeypatch.setattr(preparation, "prepare_drumsep_assets", interrupt)

    with pytest.raises(KeyboardInterrupt):
        preparation.main(["--destination", str(tmp_path / "published"), "--acquire"])

    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err == ""
