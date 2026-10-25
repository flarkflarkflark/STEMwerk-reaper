#!/usr/bin/env python3
"""REAPER-side readiness adapter for STEMwerk Core.

The client-neutral readiness API (``stemwerk_core.readiness``) deliberately
never locates or imports ``audio_separator_process.py``: production DrumSep
runtime selection (``_select_drumsep_runtime`` and its verification chain)
stays behind this adapter boundary. This module is the one place that wires
the real selector into the Core API, for both the REAPER-bundled Python
usage and this repository's tooling.

What it provides
----------------
- ``build_drum_kit_collector``: calls the production selector at most once
  per evaluation and shapes its result into the Core collector protocol.
  Live fallback attribution (``selection_info`` with the selector's own
  ``selection_policy``/``fallback_reason``) comes only from this path --
  user-supplied JSON can never confer it. The downgrade/permission policy
  itself is still applied inside Core by the resolver
  (``device_policy.drum_kit_is_unexpected_cpu_downgrade``); this adapter
  supplies evidence, not decisions.
- ``build_drum_kit_model_asset_provider``: exposes the legacy-pinned
  ``DIRECT_DKS_MODEL_EXPECTED_SHA256`` asset map for Core's read-only
  integrity check. The pins stay authoritative in the legacy module; Core
  holds no copy.
- ``assess`` / ``main``: the same API and CLI semantics as
  ``stemwerk_core.readiness`` (same report shape, same exit codes), with the
  DrumSep collectors injected. Normal-Stems stages use Core's own read-only
  live collection unchanged.

The legacy module is imported lazily and only when DrumSep live collection
actually runs: fixture (simulated) evaluations and Normal-Stems-only
requests through this adapter never touch ``audio_separator_process.py``.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Callable, Dict, Mapping, Optional, Sequence

_INTERNAL = Path(__file__).resolve().parent
CORE_SRC = _INTERNAL.parents[0] / "vendor" / "stemwerk-core" / "src"
CANONICAL_CATALOG_DIR = _INTERNAL.parents[0] / "catalog"
for _path in (str(CORE_SRC), str(_INTERNAL)):
    if _path not in sys.path:
        sys.path.insert(0, _path)

from stemwerk_core import device_policy, managed_runtime, readiness, readiness_collect  # noqa: E402
from stemwerk_core.verdicts import FAIL, UNAVAILABLE  # noqa: E402

SELECTOR_PROVENANCE = "production_select_drumsep_runtime"


def _load_legacy_module():
    """Import the production processor via the existing seam (lazy)."""

    import stemwerk_runtime_seam

    return stemwerk_runtime_seam._load_legacy_module()


def build_drum_kit_collector(runtime_base: Optional[Path] = None) -> Callable[[str], Dict[str, Any]]:
    """Return the Core ``collectors["drum_kit"]`` callable backed by the
    production DrumSep selector.

    The collector runs ``legacy._select_drumsep_runtime`` exactly once per
    call (Core caches it once per evaluation) and, when a runtime was
    selected, probes that interpreter's required imports in a bounded
    subprocess via the shared ``readiness_collect`` helper. No selection
    rule is re-implemented here; the result is shaped into evidence only.
    """

    def collect(requested_device: str) -> Dict[str, Any]:
        legacy = _load_legacy_module()
        drumsep_python, runtime_kind, selection_info = legacy._select_drumsep_runtime(
            requested_device, runtime_base
        )
        info = dict(selection_info or {})
        resolved = (
            runtime_kind
            if (drumsep_python is not None and runtime_kind in device_policy.DRUMSEP_RUNTIME_KINDS)
            else "unavailable"
        )
        evidence = {
            "source": "collected",
            "evidence_kind": "production_selector_result",
            "runtime_source": "managed_drumsep",
            "selector_provenance": SELECTOR_PROVENANCE,
        }
        resolution = {
            "requested": str(requested_device or "auto"),
            "resolved_device_id": resolved,
            "resolved_device_name": resolved,
            "resolved_backend": resolved,
            "selection_info": info,
        }
        if resolved == "unavailable":
            detail = str(info.get("detail") or runtime_kind)
            reason_code = (
                readiness.REASON_RUNTIME_EVIDENCE_MISSING
                if runtime_kind == "missing"
                else readiness.REASON_RUNTIME_EVIDENCE_BROKEN
            )
            capability = {
                "verdict": FAIL,
                "reason_code": reason_code,
                "reason": f"production DrumSep runtime selection found no usable runtime: {detail}",
                "resolution": resolution,
                "evidence": evidence,
            }
            runtime = {
                "verdict": UNAVAILABLE,
                "reason_code": reason_code,
                "reason": f"no usable DrumSep interpreter ({runtime_kind})",
                "evidence": {
                    "source": "collected",
                    "evidence_kind": "required_imports",
                    "runtime_source": "managed_drumsep",
                    "runtime_profile": "drumsep",
                },
            }
        else:
            capability = {
                "verdict": "PASS",
                "resolution": resolution,
                "evidence": {**evidence, "python_executable": str(drumsep_python)},
            }
            runtime = readiness_collect.collect_runtime_imports(
                drumsep_python, source_label="managed_drumsep", runtime_profile="drumsep"
            )
        return {"capability": capability, "runtime": runtime}

    return collect


def build_drum_kit_model_asset_provider(
    model_cache_dir: Optional[Path] = None,
) -> Callable[[], Dict[str, Any]]:
    """Return the Core ``model_asset_providers["drumsep_mdx23c"]`` callable.

    Supplies the legacy-authoritative pinned hashes
    (``DIRECT_DKS_MODEL_EXPECTED_SHA256``) plus the managed model cache
    location; Core performs the read-only hash verification itself and never
    downloads, evicts, or repairs anything.
    """

    def provide() -> Dict[str, Any]:
        legacy = _load_legacy_module()
        base_dir = (
            Path(model_cache_dir).expanduser()
            if model_cache_dir is not None
            else managed_runtime.managed_model_cache_dir()
        )
        return {
            "base_dir": str(base_dir),
            "assets": [
                {"name": name, "sha256": expected}
                for name, expected in sorted(legacy.DIRECT_DKS_MODEL_EXPECTED_SHA256.items())
            ],
        }

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
