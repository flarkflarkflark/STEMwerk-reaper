#!/usr/bin/env python3
"""REAPER-side readiness adapter for STEMwerk Core.

The client-neutral readiness API owns DrumSep runtime selection and never
locates or imports ``audio_separator_process.py``. This module only supplies
REAPER's catalog defaults and optional runtime/model-cache paths.

What it provides
----------------
- ``build_drum_kit_collector``: returns Core's production collector.
- ``build_drum_kit_model_asset_provider``: returns Core's pinned, read-only
  DrumSep model evidence.
- ``assess`` / ``main``: the same API and CLI semantics as
  ``stemwerk_core.readiness`` (same report shape, same exit codes), with the
  DrumSep collectors injected. Normal-Stems stages use Core's own read-only
  live collection unchanged.

No adapter path imports the legacy processor.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Callable, Dict, Optional, Sequence

_INTERNAL = Path(__file__).resolve().parent
CORE_SRC = _INTERNAL.parents[0] / "vendor" / "stemwerk-core" / "src"
CANONICAL_CATALOG_DIR = _INTERNAL.parents[0] / "catalog"
for _path in (str(CORE_SRC), str(_INTERNAL)):
    if _path not in sys.path:
        sys.path.insert(0, _path)

from stemwerk_core import model_assets, readiness, readiness_collect  # noqa: E402

SELECTOR_PROVENANCE = readiness_collect.SELECTOR_PROVENANCE


def build_drum_kit_collector(runtime_base: Optional[Path] = None) -> Callable[[str], Dict[str, Any]]:
    """Return Core's production DrumSep collector unchanged."""

    return readiness_collect.build_drum_kit_collector(runtime_base)


def build_drum_kit_model_asset_provider(
    model_cache_dir: Optional[Path] = None,
) -> Callable[[], Dict[str, Any]]:
    """Return Core-owned pinned DrumSep asset evidence."""

    def provide() -> Dict[str, Any]:
        return model_assets.drumsep_asset_evidence(model_cache_dir)

    return provide


def assess(
    request: Any,
    *,
    fixture: Any = None,
    catalog_dir: Optional[str | Path] = None,
    runtime_base: Optional[Path] = None,
    model_cache_dir: Optional[Path] = None,
) -> Dict[str, Any]:
    """Evaluate readiness through the Core API with the production DrumSep
    collectors injected. Same request/response semantics as
    ``stemwerk_core.readiness.assess_readiness``; a Standalone client calling
    Core directly gets the identical report for the same inputs."""

    return readiness.assess_readiness(
        request,
        fixture=fixture,
        catalog_dir=catalog_dir if catalog_dir is not None else CANONICAL_CATALOG_DIR,
        collectors={"drum_kit": build_drum_kit_collector(runtime_base)},
        model_asset_providers={"drumsep_mdx23c": build_drum_kit_model_asset_provider(model_cache_dir)},
    )


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = readiness.build_arg_parser()
    args = parser.parse_args(argv)

    deliverable_ids = None
    if args.deliverables:
        deliverable_ids = [item.strip() for item in args.deliverables.split(",") if item.strip()]

    fixture = None
    evidence_mode = "collect"
    if args.fixture:
        evidence_mode = "fixture"
        from stemwerk_core import workflow_contracts

        try:
            fixture = workflow_contracts.load_json(args.fixture)
        except workflow_contracts.ContractError as exc:
            document = readiness.error_document(readiness.REASON_FIXTURE_INVALID, str(exc))
            json.dump(document, sys.stdout, indent=2 if args.pretty else None)
            sys.stdout.write("\n")
            print(f"readiness: {readiness.REASON_FIXTURE_INVALID}: {exc}", file=sys.stderr)
            return readiness.EXIT_UNAVAILABLE_OR_ERROR

    request = readiness.ReadinessRequest(
        workflow_id=args.workflow,
        model_id=args.models,
        requested_device=args.device,
        deliverable_ids=deliverable_ids,
        evidence_mode=evidence_mode,
    )
    try:
        report = assess(request, fixture=fixture, catalog_dir=args.catalog_dir)
    except readiness.ReadinessError as exc:
        document = readiness.error_document(exc.code, exc.detail)
        json.dump(document, sys.stdout, indent=2 if args.pretty else None)
        sys.stdout.write("\n")
        print(f"readiness: {exc.code}: {exc.detail}", file=sys.stderr)
        return readiness.EXIT_UNAVAILABLE_OR_ERROR

    json.dump(report, sys.stdout, indent=2 if args.pretty else None)
    sys.stdout.write("\n")
    verdict = report["readiness"]["verdict"]
    scope = report["readiness"]["scope"]
    print(f"readiness: {verdict} ({scope})", file=sys.stderr)
    return readiness.exit_code_for_report(report)


if __name__ == "__main__":
    sys.exit(main())
