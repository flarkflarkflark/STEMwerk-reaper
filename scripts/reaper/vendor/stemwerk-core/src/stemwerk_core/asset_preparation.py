"""Compose DrumSep source acquisition and verified asset publication.

This module prepares only Core's pinned DrumSep assets in a new explicit
destination. It does not provision a runtime, activate a module, infer work
from an installation preview, or establish workflow readiness.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
from pathlib import Path
import sys
import tempfile
from typing import Any, Callable, Mapping, Sequence

from . import asset_acquisition as acquisition
from . import asset_materialization as materialization
from . import model_assets


SCHEMA_VERSION = "1.0.0"


class PreparationError(Exception):
    """A validation, acquisition, publication, or cleanup failure."""

    def __init__(
        self,
        code: str,
        message: str,
        *,
        phase: str,
        source_mode: str | None,
        acquisition_completed: bool,
        publication_state: str,
        destination: str | None,
        operation_id: str | None = None,
        receipt_path: str | None = None,
        cleanup_remaining: Sequence[str] = (),
        acquisition_evidence: Mapping[str, Any] | None = None,
        primitive_error: Mapping[str, Any] | None = None,
        temporary_source_path: str | None = None,
        temporary_sources_retained: bool = False,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.phase = phase
        self.source_mode = source_mode
        self.acquisition_completed = acquisition_completed
        self.publication_state = publication_state
        self.destination = destination
        self.operation_id = operation_id
        self.receipt_path = receipt_path
        self.cleanup_remaining = tuple(cleanup_remaining)
        self.acquisition_evidence = acquisition_evidence
        self.primitive_error = primitive_error
        self.temporary_source_path = temporary_source_path
        self.temporary_sources_retained = temporary_sources_retained


@dataclass(frozen=True)
class PreparationRequest:
    """Prepare from explicit local sources or an explicitly requested download."""

    destination: Path
    local_sources: Mapping[str, os.PathLike[str] | str] | None = None
    acquire: bool = False


@dataclass(frozen=True)
class _ValidatedPreparation:
    destination: Path
    source_mode: str
    local_sources: Mapping[str, os.PathLike[str] | str] | None


@dataclass(frozen=True)
class _TemporarySources:
    workspace: Path
    acquisition_destination: Path
    owned_paths: tuple[acquisition._OwnedPath, ...]


def _deduplicate_paths(paths: Sequence[str]) -> tuple[str, ...]:
    return tuple(dict.fromkeys(path for path in paths if path))


def _publication_state(value: bool | None) -> str:
    if value is True:
        return "published"
    if value is False:
        return "not_published"
    return "unknown"


def _validate_request(request: PreparationRequest) -> _ValidatedPreparation:
    if not isinstance(request, PreparationRequest):
        raise PreparationError(
            "invalid_request",
            "request must be a PreparationRequest",
            phase="validation",
            source_mode=None,
            acquisition_completed=False,
            publication_state="not_started",
            destination=None,
        )
    if not isinstance(request.acquire, bool):
        raise PreparationError(
            "invalid_request",
            "acquire must be a boolean",
            phase="validation",
            source_mode=None,
            acquisition_completed=False,
            publication_state="not_started",
            destination=str(request.destination),
        )
    local_requested = request.local_sources is not None
    if local_requested == request.acquire:
        raise PreparationError(
            "invalid_source_mode",
            "exactly one source mode is required: local_sources or acquire",
            phase="validation",
            source_mode=None,
            acquisition_completed=False,
            publication_state="not_started",
            destination=str(request.destination),
        )
    if local_requested and not isinstance(request.local_sources, Mapping):
        raise PreparationError(
            "invalid_request",
            "local_sources must be a mapping",
            phase="validation",
            source_mode="local",
            acquisition_completed=False,
            publication_state="not_started",
            destination=str(request.destination),
        )
    return _ValidatedPreparation(
        destination=request.destination,
        source_mode="local" if local_requested else "acquire",
        local_sources=request.local_sources,
    )


def _preflight(validated: _ValidatedPreparation, preflight) -> None:
    try:
        preflight(validated.destination)
    except materialization.MaterializationError as exc:
        raise PreparationError(
            exc.code,
            str(exc),
            phase="validation",
            source_mode=validated.source_mode,
            acquisition_completed=False,
            publication_state="not_started",
            destination=exc.destination or str(validated.destination),
            cleanup_remaining=exc.cleanup_remaining,
            primitive_error=materialization._error_document(exc),
        ) from exc


def _workspace_path(
    workspace_factory: Callable[[], Path] | None, destination: Path
) -> Path:
    if workspace_factory is None:
        try:
            return Path(tempfile.mkdtemp(prefix="stemwerk-drumsep-acquisition-"))
        except OSError as exc:
            raise PreparationError(
                "temporary_workspace_failed",
                f"cannot create temporary acquisition workspace: {exc}",
                phase="acquisition",
                source_mode="acquire",
                acquisition_completed=False,
                publication_state="not_started",
                destination=str(destination),
            ) from exc
    try:
        path = Path(workspace_factory())
    except (TypeError, ValueError, OSError) as exc:
        raise PreparationError(
            "temporary_workspace_failed",
            "temporary acquisition workspace path is invalid",
            phase="acquisition",
            source_mode="acquire",
            acquisition_completed=False,
            publication_state="not_started",
            destination=str(destination),
        ) from exc
    if not path.is_absolute():
        raise PreparationError(
            "temporary_workspace_failed",
            "temporary acquisition workspace must be absolute",
            phase="acquisition",
            source_mode="acquire",
            acquisition_completed=False,
            publication_state="not_started",
            destination=str(destination),
        )
    try:
        os.mkdir(path, 0o700)
    except OSError as exc:
        raise PreparationError(
            "temporary_workspace_failed",
            f"cannot create temporary acquisition workspace: {exc}",
            phase="acquisition",
            source_mode="acquire",
            acquisition_completed=False,
            publication_state="not_started",
            destination=str(destination),
        ) from exc
    return path


def _record_temporary_sources(
    workspace: Path,
    workspace_owned: acquisition._OwnedPath,
    acquisition_destination: Path,
    publication_destination: Path,
    result: Mapping[str, Any],
) -> _TemporarySources:
    if not isinstance(result, Mapping):
        raise PreparationError(
            "acquisition_evidence_invalid",
            "acquisition did not return a result document",
            phase="acquisition",
            source_mode="acquire",
            acquisition_completed=True,
            publication_state="not_started",
            destination=str(publication_destination),
            cleanup_remaining=(str(workspace),),
            temporary_source_path=str(workspace),
            temporary_sources_retained=True,
        )
    if (
        result.get("outcome") != "success"
        or result.get("destination") != str(acquisition_destination)
    ):
        raise PreparationError(
            "acquisition_evidence_invalid",
            "acquisition result does not identify the owned temporary destination",
            phase="acquisition",
            source_mode="acquire",
            acquisition_completed=True,
            publication_state="not_started",
            destination=str(publication_destination),
            acquisition_evidence=result,
            cleanup_remaining=(str(workspace),),
            temporary_source_path=str(workspace),
            temporary_sources_retained=True,
        )
    sources = result.get("sources")
    if not isinstance(sources, Mapping) or not sources:
        raise PreparationError(
            "acquisition_evidence_invalid",
            "acquisition result omitted its verified source mapping",
            phase="acquisition",
            source_mode="acquire",
            acquisition_completed=True,
            publication_state="not_started",
            destination=str(publication_destination),
            acquisition_evidence=result,
            cleanup_remaining=(str(workspace),),
            temporary_source_path=str(workspace),
            temporary_sources_retained=True,
        )
    try:
        source_paths = tuple(Path(value) for value in sources.values())
    except (TypeError, ValueError, OSError) as exc:
        raise PreparationError(
            "acquisition_evidence_invalid",
            "acquisition result contains an invalid source path",
            phase="acquisition",
            source_mode="acquire",
            acquisition_completed=True,
            publication_state="not_started",
            destination=str(publication_destination),
            acquisition_evidence=result,
            cleanup_remaining=(str(workspace),),
            temporary_source_path=str(workspace),
            temporary_sources_retained=True,
        ) from exc
    if any(path.parent != acquisition_destination for path in source_paths):
        raise PreparationError(
            "acquisition_evidence_invalid",
            "acquisition result references content outside its temporary destination",
            phase="acquisition",
            source_mode="acquire",
            acquisition_completed=True,
            publication_state="not_started",
            destination=str(publication_destination),
            acquisition_evidence=result,
            cleanup_remaining=(str(workspace),),
            temporary_source_path=str(workspace),
            temporary_sources_retained=True,
        )
    try:
        owned_paths = (
            workspace_owned,
            acquisition._owned(acquisition_destination),
            *(acquisition._owned(path) for path in source_paths),
        )
    except OSError as exc:
        raise PreparationError(
            "acquisition_evidence_invalid",
            f"cannot record temporary acquisition ownership: {exc}",
            phase="acquisition",
            source_mode="acquire",
            acquisition_completed=True,
            publication_state="not_started",
            destination=str(publication_destination),
            acquisition_evidence=result,
            cleanup_remaining=(str(workspace),),
            temporary_source_path=str(workspace),
            temporary_sources_retained=True,
        ) from exc
    return _TemporarySources(workspace, acquisition_destination, owned_paths)


def _operation_identity(result: Mapping[str, Any]) -> tuple[str | None, str | None]:
    if not isinstance(result, Mapping):
        return None, None
    receipt = result.get("receipt")
    operation_id = None
    if isinstance(receipt, Mapping):
        operation = receipt.get("operation")
        if isinstance(operation, Mapping):
            value = operation.get("operation_id")
            if isinstance(value, str):
                operation_id = value
    receipt_path = result.get("receipt_path")
    return operation_id, receipt_path if isinstance(receipt_path, str) else None


def _attempt_cleanup(
    cleanup_owned: Callable[[Sequence[acquisition._OwnedPath]], list[str]],
    owned_paths: Sequence[acquisition._OwnedPath],
) -> tuple[str, ...]:
    """Keep a primary failure intact if best-effort cleanup itself fails."""

    try:
        return tuple(cleanup_owned(owned_paths))
    except BaseException:
        return tuple(str(owned.path) for owned in owned_paths)


def _attach_interruption(
    exc: BaseException,
    *,
    phase: str,
    source_mode: str,
    acquisition_completed: bool,
    publication_state: str,
    destination: Path,
    cleanup_remaining: Sequence[str],
    acquisition_evidence: Mapping[str, Any] | None,
    operation_id: str | None,
    receipt_path: str | None,
    temporary_source_path: str | None,
    temporary_sources_retained: bool,
) -> None:
    exc.phase = phase  # type: ignore[attr-defined]
    exc.source_mode = source_mode  # type: ignore[attr-defined]
    exc.acquisition_completed = acquisition_completed  # type: ignore[attr-defined]
    exc.publication_state = publication_state  # type: ignore[attr-defined]
    exc.destination = str(destination)  # type: ignore[attr-defined]
    exc.cleanup_remaining = _deduplicate_paths(cleanup_remaining)  # type: ignore[attr-defined]
    exc.acquisition_evidence = acquisition_evidence  # type: ignore[attr-defined]
    exc.operation_id = operation_id  # type: ignore[attr-defined]
    exc.receipt_path = receipt_path  # type: ignore[attr-defined]
    exc.temporary_source_path = temporary_source_path  # type: ignore[attr-defined]
    exc.temporary_sources_retained = temporary_sources_retained  # type: ignore[attr-defined]
    if hasattr(exc, "add_note"):
        exc.add_note(
            "STEMwerk asset preparation state: "
            f"phase={phase}, publication={publication_state}, "
            f"destination={destination}, operation_id={operation_id}, "
            f"receipt_path={receipt_path}, "
            f"cleanup_remaining={list(cleanup_remaining)}"
        )


def _prepare_asset_set(
    request: PreparationRequest,
    *,
    preflight: Callable[[Path], Mapping[str, Any]] | None = None,
    acquire: Callable[[acquisition.AcquisitionRequest], Mapping[str, Any]] | None = None,
    materialize: Callable[
        [materialization.MaterializationRequest], Mapping[str, Any]
    ]
    | None = None,
    workspace_factory: Callable[[], Path] | None = None,
    cleanup_owned: Callable[[Sequence[acquisition._OwnedPath]], list[str]] | None = None,
) -> dict[str, Any]:
    """Internal composition seam; production entry points bind Core policy."""

    validated = _validate_request(request)
    preflight = preflight or materialization.preflight_drumsep_materialization
    acquire = acquire or acquisition.acquire_drumsep_sources
    materialize = materialize or materialization.materialize_drumsep_assets
    cleanup_owned = cleanup_owned or acquisition._cleanup_owned
    _preflight(validated, preflight)

    acquisition_result: Mapping[str, Any] | None = None
    temporary: _TemporarySources | None = None
    sources: Mapping[str, os.PathLike[str] | str]
    if validated.source_mode == "local":
        assert validated.local_sources is not None
        sources = dict(validated.local_sources)
    else:
        workspace = _workspace_path(workspace_factory, validated.destination)
        try:
            workspace_owned = acquisition._owned(workspace)
        except OSError as exc:
            raise PreparationError(
                "temporary_workspace_failed",
                f"cannot record temporary workspace ownership: {exc}",
                phase="acquisition",
                source_mode="acquire",
                acquisition_completed=False,
                publication_state="not_started",
                destination=str(validated.destination),
                cleanup_remaining=(str(workspace),),
                temporary_source_path=str(workspace),
                temporary_sources_retained=True,
            ) from exc
        acquisition_destination = workspace / "sources"
        try:
            acquisition_result = acquire(
                acquisition.AcquisitionRequest(acquisition_destination)
            )
        except acquisition.AcquisitionError as exc:
            workspace_cleanup = _attempt_cleanup(cleanup_owned, (workspace_owned,))
            remaining = _deduplicate_paths(
                (*exc.cleanup_remaining, *workspace_cleanup)
            )
            raise PreparationError(
                exc.code,
                str(exc),
                phase="acquisition",
                source_mode="acquire",
                acquisition_completed=False,
                publication_state="not_started",
                destination=str(validated.destination),
                cleanup_remaining=remaining,
                primitive_error=acquisition._error_payload(exc),
                temporary_source_path=str(workspace),
                temporary_sources_retained=bool(remaining),
            ) from exc
        except Exception as exc:
            workspace_cleanup = _attempt_cleanup(cleanup_owned, (workspace_owned,))
            remaining = _deduplicate_paths(
                (*getattr(exc, "cleanup_remaining", ()), *workspace_cleanup)
            )
            raise PreparationError(
                "acquisition_failed",
                f"acquisition failed unexpectedly: {type(exc).__name__}",
                phase="acquisition",
                source_mode="acquire",
                acquisition_completed=False,
                publication_state="not_started",
                destination=str(validated.destination),
                cleanup_remaining=remaining,
                primitive_error={"exception_type": type(exc).__name__},
                temporary_source_path=str(workspace),
                temporary_sources_retained=bool(remaining),
            ) from exc
        except BaseException as exc:
            workspace_cleanup = _attempt_cleanup(cleanup_owned, (workspace_owned,))
            remaining = _deduplicate_paths(
                (*getattr(exc, "cleanup_remaining", ()), *workspace_cleanup)
            )
            _attach_interruption(
                exc,
                phase="acquisition",
                source_mode="acquire",
                acquisition_completed=False,
                publication_state="not_started",
                destination=validated.destination,
                cleanup_remaining=remaining,
                acquisition_evidence=None,
                operation_id=None,
                receipt_path=None,
                temporary_source_path=str(workspace),
                temporary_sources_retained=bool(remaining),
            )
            raise
        temporary = _record_temporary_sources(
            workspace,
            workspace_owned,
            acquisition_destination,
            validated.destination,
            acquisition_result,
        )
        sources = acquisition_result["sources"]

    materialization_request = materialization.MaterializationRequest(
        sources=dict(sources), destination=validated.destination
    )
    try:
        publication_result = materialize(materialization_request)
    except materialization.MaterializationError as exc:
        retained = (str(temporary.workspace),) if temporary is not None else ()
        remaining = _deduplicate_paths((*exc.cleanup_remaining, *retained))
        raise PreparationError(
            exc.code,
            str(exc),
            phase="publication",
            source_mode=validated.source_mode,
            acquisition_completed=acquisition_result is not None,
            publication_state=_publication_state(exc.published),
            destination=exc.destination or str(validated.destination),
            operation_id=exc.operation_id,
            receipt_path=exc.receipt_path,
            cleanup_remaining=remaining,
            acquisition_evidence=acquisition_result,
            primitive_error=materialization._error_document(exc),
            temporary_source_path=(
                str(temporary.workspace) if temporary is not None else None
            ),
            temporary_sources_retained=temporary is not None,
        ) from exc
    except Exception as exc:
        retained = (str(temporary.workspace),) if temporary is not None else ()
        remaining = _deduplicate_paths(
            (*getattr(exc, "cleanup_remaining", ()), *retained)
        )
        raise PreparationError(
            "materialization_failed",
            f"materialization failed unexpectedly: {type(exc).__name__}",
            phase="publication",
            source_mode=validated.source_mode,
            acquisition_completed=acquisition_result is not None,
            publication_state=_publication_state(getattr(exc, "published", None)),
            destination=str(validated.destination),
            operation_id=getattr(exc, "operation_id", None),
            receipt_path=getattr(exc, "receipt_path", None),
            cleanup_remaining=remaining,
            acquisition_evidence=acquisition_result,
            primitive_error={"exception_type": type(exc).__name__},
            temporary_source_path=(
                str(temporary.workspace) if temporary is not None else None
            ),
            temporary_sources_retained=temporary is not None,
        ) from exc
    except BaseException as exc:
        retained = (str(temporary.workspace),) if temporary is not None else ()
        remaining = _deduplicate_paths(
            (*getattr(exc, "cleanup_remaining", ()), *retained)
        )
        _attach_interruption(
            exc,
            phase="publication",
            source_mode=validated.source_mode,
            acquisition_completed=acquisition_result is not None,
            publication_state=_publication_state(getattr(exc, "published", None)),
            destination=validated.destination,
            cleanup_remaining=remaining,
            acquisition_evidence=acquisition_result,
            operation_id=getattr(exc, "operation_id", None),
            receipt_path=getattr(exc, "receipt_path", None),
            temporary_source_path=(
                str(temporary.workspace) if temporary is not None else None
            ),
            temporary_sources_retained=temporary is not None,
        )
        raise

    operation_id, receipt_path = _operation_identity(publication_result)
    if (
        not isinstance(publication_result, Mapping)
        or publication_result.get("outcome") != "success"
        or publication_result.get("destination") != str(validated.destination)
        or operation_id is None
        or receipt_path is None
    ):
        retained = (str(temporary.workspace),) if temporary is not None else ()
        raise PreparationError(
            "publication_evidence_invalid",
            "materializer returned without confirmed publication evidence",
            phase="publication",
            source_mode=validated.source_mode,
            acquisition_completed=acquisition_result is not None,
            publication_state="unknown",
            destination=str(validated.destination),
            cleanup_remaining=retained,
            acquisition_evidence=acquisition_result,
            primitive_error=(
                publication_result if isinstance(publication_result, Mapping) else None
            ),
            temporary_source_path=(
                str(temporary.workspace) if temporary is not None else None
            ),
            temporary_sources_retained=temporary is not None,
        )
    temporary_cleanup = {"complete": True, "remaining_paths": []}
    temporary_path = None
    if temporary is not None:
        temporary_path = str(temporary.workspace)
        try:
            remaining = cleanup_owned(temporary.owned_paths)
        except Exception as exc:
            potentially_remaining = tuple(
                str(owned.path) for owned in temporary.owned_paths
            )
            raise PreparationError(
                "temporary_cleanup_failed",
                f"temporary cleanup failed unexpectedly: {type(exc).__name__}",
                phase="cleanup",
                source_mode="acquire",
                acquisition_completed=True,
                publication_state="published",
                destination=str(validated.destination),
                operation_id=operation_id,
                receipt_path=receipt_path,
                cleanup_remaining=potentially_remaining,
                acquisition_evidence=acquisition_result,
                primitive_error={"exception_type": type(exc).__name__},
                temporary_source_path=str(temporary.workspace),
                temporary_sources_retained=True,
            ) from exc
        except BaseException as exc:
            potentially_remaining = tuple(
                str(owned.path) for owned in temporary.owned_paths
            )
            _attach_interruption(
                exc,
                phase="cleanup",
                source_mode="acquire",
                acquisition_completed=True,
                publication_state="published",
                destination=validated.destination,
                cleanup_remaining=potentially_remaining,
                acquisition_evidence=acquisition_result,
                operation_id=operation_id,
                receipt_path=receipt_path,
                temporary_source_path=str(temporary.workspace),
                temporary_sources_retained=True,
            )
            raise
        if remaining:
            raise PreparationError(
                "temporary_cleanup_failed",
                "publication succeeded but temporary acquisition sources remain",
                phase="cleanup",
                source_mode="acquire",
                acquisition_completed=True,
                publication_state="published",
                destination=str(validated.destination),
                operation_id=operation_id,
                receipt_path=receipt_path,
                cleanup_remaining=remaining,
                acquisition_evidence=acquisition_result,
                temporary_source_path=str(temporary.workspace),
                temporary_sources_retained=True,
            )

    return {
        "kind": "stemwerk_asset_preparation_result",
        "schema_version": SCHEMA_VERSION,
        "outcome": "success",
        "phase": "complete",
        "source_mode": validated.source_mode,
        "destination": str(validated.destination),
        "acquisition": {
            "requested": validated.source_mode == "acquire",
            "completed": acquisition_result is not None,
            "evidence": acquisition_result,
        },
        "publication": {
            "state": "published",
            "operation_id": operation_id,
            "receipt_path": receipt_path,
            "evidence": publication_result,
        },
        "temporary_sources": {
            "created": temporary is not None,
            "path": temporary_path,
            "retained": False,
            "cleanup": temporary_cleanup,
        },
        "limits": {
            "runtime_installed": False,
            "module_activated": False,
            "existing_installation_adopted": False,
            "workflow_readiness_established": False,
            "complete_drum_kit_installation": False,
        },
    }


def prepare_drumsep_assets(request: PreparationRequest) -> dict[str, Any]:
    """Prepare Core-pinned DrumSep assets from one explicit source mode."""

    return _prepare_asset_set(request)


def _error_document(exc: PreparationError) -> dict[str, Any]:
    return {
        "kind": "stemwerk_asset_preparation_error",
        "schema_version": SCHEMA_VERSION,
        "outcome": "error",
        "phase": exc.phase,
        "source_mode": exc.source_mode,
        "destination": exc.destination,
        "acquisition": {
            "completed": exc.acquisition_completed,
            "evidence": exc.acquisition_evidence,
        },
        "publication": {
            "state": exc.publication_state,
            "operation_id": exc.operation_id,
            "receipt_path": exc.receipt_path,
        },
        "temporary_sources": {
            "path": exc.temporary_source_path,
            "retained": exc.temporary_sources_retained,
        },
        "cleanup": {
            "complete": not exc.cleanup_remaining,
            "remaining_paths": list(exc.cleanup_remaining),
        },
        "error": {
            "code": exc.code,
            "message": str(exc),
            "primitive": exc.primitive_error,
        },
    }


def _internal_error_document(exc: Exception, destination: str) -> dict[str, Any]:
    # Only the exception type is reported: its message, arguments and notes may
    # carry unredacted URLs or paths. Facts the CLI cannot know are null, and
    # the publication state is the existing "unknown".
    return {
        "kind": "stemwerk_asset_preparation_error",
        "schema_version": SCHEMA_VERSION,
        "outcome": "error",
        "phase": None,
        "source_mode": None,
        "destination": destination,
        "acquisition": {"completed": None, "evidence": None},
        "publication": {
            "state": "unknown",
            "operation_id": None,
            "receipt_path": None,
        },
        "temporary_sources": {"path": None, "retained": None},
        "cleanup": {"complete": None, "remaining_paths": None},
        "error": {
            "code": "internal_error",
            "message": f"unexpected internal error ({type(exc).__name__})",
            "primitive": None,
        },
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", required=True)
    parser.add_argument("--acquire", action="store_true")
    parser.add_argument("--checkpoint-source")
    parser.add_argument("--config-source")
    parser.add_argument("--pretty", action="store_true")
    return parser


def _request_from_args(args: argparse.Namespace) -> PreparationRequest:
    supplied = (args.checkpoint_source is not None, args.config_source is not None)
    if args.acquire:
        if any(supplied):
            raise PreparationError(
                "invalid_source_mode",
                "--acquire cannot be combined with local source options",
                phase="validation",
                source_mode=None,
                acquisition_completed=False,
                publication_state="not_started",
                destination=args.destination,
            )
        return PreparationRequest(Path(args.destination), acquire=True)
    if supplied != (True, True):
        raise PreparationError(
            "invalid_source_mode",
            "local mode requires both --checkpoint-source and --config-source",
            phase="validation",
            source_mode=None,
            acquisition_completed=False,
            publication_state="not_started",
            destination=args.destination,
        )
    return PreparationRequest(
        destination=Path(args.destination),
        local_sources={
            model_assets.DIRECT_DKS_MODEL_FILENAME: Path(args.checkpoint_source),
            model_assets.DIRECT_DKS_MODEL_YAML: Path(args.config_source),
        },
    )


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        result = prepare_drumsep_assets(_request_from_args(args))
    except PreparationError as exc:
        print(
            json.dumps(
                _error_document(exc),
                indent=2 if args.pretty else None,
                sort_keys=True,
                ensure_ascii=False,
                allow_nan=False,
                separators=None if args.pretty else (",", ":"),
            ),
            file=sys.stderr,
        )
        return 2
    except Exception as exc:
        print(
            json.dumps(
                _internal_error_document(exc, args.destination),
                indent=2 if args.pretty else None,
                sort_keys=True,
                ensure_ascii=False,
                allow_nan=False,
                separators=None if args.pretty else (",", ":"),
            ),
            file=sys.stderr,
        )
        return 3
    print(
        json.dumps(
            result,
            indent=2 if args.pretty else None,
            sort_keys=True,
            ensure_ascii=False,
            allow_nan=False,
            separators=None if args.pretty else (",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
