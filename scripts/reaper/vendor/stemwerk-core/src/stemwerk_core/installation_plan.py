"""Informational installation intent; no installation or mutation authority.

The pure planner accepts JSON catalog entries and readiness snapshots. Only
``collect_installation_inventory`` collects host evidence. See
``docs/dev/Core_Installation_Plan_Preview.md`` for the v1 input contract.
"""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
import platform
import re
import sys
from typing import Any, Sequence

from . import model_assets, readiness, runtime_resolution, workflow_contracts as contracts

SCHEMA_VERSION = '1.0.0'
INVENTORY_KIND = 'stemwerk_installation_inventory'
WORKFLOWS = ('drum_kit_direct', 'drum_kit_split')


class InstallationPlanError(ValueError):
    """Invalid input, catalog, or dependency structure (CLI exit 2)."""


@dataclass(frozen=True)
class InstallationRequest:
    module_id: str = 'drum_kit'
    operation: str = 'ensure_installed'
    requested_device: str = 'auto'


def canonical_json(value: Any) -> str:
    """Sort object keys, preserving every ordered array; reject non-JSON data."""
    try:
        return json.dumps(value, sort_keys=True, separators=(',', ':'),
                          ensure_ascii=False, allow_nan=False)
    except (TypeError, ValueError) as exc:
        raise InstallationPlanError(f'expected finite JSON data: {exc}') from exc


def _fingerprint(value: Any) -> str:
    return hashlib.sha256(canonical_json(value).encode('utf-8')).hexdigest()


def _request(value: Any) -> InstallationRequest:
    try:
        result = value if isinstance(value, InstallationRequest) else InstallationRequest(**value)
    except (TypeError, ValueError) as exc:
        raise InstallationPlanError('expected InstallationRequest or request object') from exc
    if result.module_id != 'drum_kit' or result.operation != 'ensure_installed':
        raise InstallationPlanError('only drum_kit / ensure_installed is supported')
    if not isinstance(result.requested_device, str) or not re.fullmatch(
        r'auto|cpu|cuda(?::\d+)?|rocm|mps|directml(?::\d+)?', result.requested_device
    ):
        raise InstallationPlanError('unsupported requested_device')
    return result


def _validate_catalogs(catalogs: Any) -> dict:
    """In-memory boundary using the existing v1 entry validators.

    The public catalog loader requires filesystem paths. Keep its closed IDs,
    entry rules and cross-reference invariants here without reading files or
    temporarily replacing global loaders. No provisioning fields are accepted.
    """
    if not isinstance(catalogs, dict) or set(catalogs) != {'workflows', 'models', 'capabilities'}:
        raise InstallationPlanError('catalogs must contain workflows, models and capabilities')
    try:
        indexes = {}
        for name, key, known in (
            ('workflows', 'workflow_id', contracts._KNOWN_WORKFLOW_IDS),
            ('models', 'model_id', contracts._KNOWN_MODEL_IDS),
            ('capabilities', 'capability_id', contracts._KNOWN_CAPABILITY_IDS),
        ):
            entries = contracts._list(catalogs[name], name)
            for entry in entries:
                contracts._mapping(entry, name)
                contracts._stable_id(entry.get(key), key)
            indexes[name] = contracts._unique(entries, key, name)
            if set(indexes[name]) != known:
                raise InstallationPlanError(f'incomplete or unknown {name} catalog')
        caps = indexes['capabilities']
        for key, cap in caps.items():
            contracts._validate_capability_entry(cap, key)
        for key, model in indexes['models'].items():
            contracts._validate_model_entry(model, key)
            if model['capability_id'] not in caps or model['output_semantic_ids'] != caps[model['capability_id']]['output_semantic_ids']:
                raise InstallationPlanError(f'invalid model capability: {key}')
        for key, workflow in indexes['workflows'].items():
            contracts._only_keys(workflow, {'workflow_id', 'label', 'ordered_stages', 'deliverable_routes'}, key)
            contracts._string(workflow.get('label'), key)
            stages = contracts._list(workflow.get('ordered_stages'), key)
            if not stages:
                raise InstallationPlanError(f'empty workflow: {key}')
            prior = {}
            for order, stage in enumerate(stages, 1):
                contracts._validate_workflow_stage_entry(stage, key)
                if stage['order'] != order or stage['stage_id'] in prior:
                    raise InstallationPlanError(f'invalid stage order: {key}')
                if any(cap not in caps for cap in stage['capability_ids']):
                    raise InstallationPlanError(f'unknown stage capability: {key}')
                if stage['input_kind'] == 'stage_output':
                    producer = prior.get(stage['input_stage_id'])
                    if producer is None or not any(stage['input_port_id'] in caps[c]['output_semantic_ids'] for c in producer['capability_ids']):
                        raise InstallationPlanError(f'invalid stage dependency: {key}')
                prior[stage['stage_id']] = stage
            routes = contracts._list(workflow.get('deliverable_routes'), key)
            route_caps = []
            for route in routes:
                contracts._mapping(route, key)
                contracts._only_keys(route, {'capability_id', 'deliverable_ids'}, key)
                cap = contracts._stable_id(route.get('capability_id'), key)
                if cap not in stages[-1]['capability_ids'] or route.get('deliverable_ids') != caps[cap]['output_semantic_ids']:
                    raise InstallationPlanError(f'invalid deliverable route: {key}')
                route_caps.append(cap)
            if sorted(route_caps) != sorted(stages[-1]['capability_ids']):
                raise InstallationPlanError(f'incomplete or duplicate routes: {key}')
        contracts._reject_reaper_pointers(catalogs)
    except (contracts.ContractError, KeyError, TypeError) as exc:
        raise InstallationPlanError(f'invalid catalog: {exc}') from exc
    # Catalog entry arrays are sets indexed by ID; stage/output arrays are ordered.
    return {name: sorted(entries, key=lambda e: e[{'workflows': 'workflow_id', 'models': 'model_id', 'capabilities': 'capability_id'}[name]])
            for name, entries in catalogs.items()}


def _expand(catalogs: dict) -> tuple[list, dict]:
    workflows, components = [], {}
    for workflow_id in WORKFLOWS:
        workflow, infos = readiness._resolve_stage_infos(readiness.ReadinessRequest(workflow_id), catalogs)
        stages = []
        for info in infos:
            stage = info['stage']
            consumer = {'workflow_id': workflow_id, 'stage_id': stage['stage_id']}
            ids = [f"runtime:{info['flavor']}", f"model:{info['model_id']}", 'ffmpeg']
            for component_id in ids:
                component = components.setdefault(component_id, {
                    'id': component_id, 'kind': component_id.split(':')[0], 'consumers': [],
                    'source_references': [],
                })
                component['consumers'].append(consumer)
                reference = f"catalog/workflows.v1.json#{workflow_id}/{stage['stage_id']}"
                component['source_references'].append(reference)
            if info['flavor'] == 'drumsep':
                model_component = components[f"model:{info['model_id']}"]
                model_component['authoritative_assets'] = [
                    {'name': name, 'sha256': digest}
                    for name, digest in sorted(model_assets.DIRECT_DKS_MODEL_EXPECTED_SHA256.items())]
                model_component['integrity_source'] = 'stemwerk_core.model_assets.DIRECT_DKS_MODEL_EXPECTED_SHA256'
            stages.append({'stage_id': stage['stage_id'], 'model_id': info['model_id'],
                           'capability_id': info['capability_id'], 'requirements': ids,
                           'depends_on': [stage['input_stage_id']] if stage['input_kind'] == 'stage_output' else [],
                           'input_port_id': stage.get('input_port_id')})
        workflows.append({'workflow_id': workflow_id, 'stages': stages,
                          'deliverable_ids': readiness._promised_deliverables(workflow, infos[-1]['capability_id'])})
    return workflows, components


def _order_actions(actions: list[dict]) -> list[dict]:
    """Stable topological order, preserving direct and upstream prerequisites."""
    by_id = {a['id']: a for a in actions}
    if len(by_id) != len(actions):
        raise InstallationPlanError('duplicate action ID')
    for action in actions:
        deps = action['depends_on']
        if not isinstance(deps, list) or any(not isinstance(d, str) for d in deps) or len(deps) != len(set(deps)) or any(d not in by_id for d in deps):
            raise InstallationPlanError('invalid action dependency')
    ordered, done = [], set()
    while len(done) < len(actions):
        candidates = sorted(key for key, a in by_id.items() if key not in done and set(a['depends_on']) <= done)
        if not candidates:
            raise InstallationPlanError('cyclic action dependencies')
        for key in candidates:
            action = by_id[key]
            inherited = [{'dependency': dep, 'reasons': by_id[dep]['blockers']}
                         for dep in action['depends_on'] if by_id[dep]['blockers']]
            action['upstream_blockers'] = inherited
            action['blockers'] = sorted(set(action['prerequisites']) | {
                reason for dep in action['depends_on'] for reason in by_id[dep]['blockers']})
            action['status'] = 'blocked' if action['blockers'] else 'informational'
            ordered.append(action)
            done.add(key)
    return ordered


class _CollectedInventory(dict):
    """In-process provenance token; serialized/reimported snapshots lose it."""


def _object(value: Any, where: str) -> dict:
    if not isinstance(value, dict):
        raise InstallationPlanError(f'{where} must be an object')
    return value


def _string_fields(value: dict, fields: Sequence[str]) -> None:
    for field in fields:
        if field in value and not isinstance(value[field], str):
            raise InstallationPlanError(f'{field} must be a string')


def _attributed(value: Any, source: str) -> Any:
    if isinstance(value, dict):
        return {key: ('unknown' if key == 'ownership' else
                      False if key in {'mutation_authority', 'locally_verified'} else
                      source if key == 'source' else
                      'inventory_snapshot' if key == 'evidence_kind' else
                      _attributed(nested, source))
                for key, nested in value.items() if 'selector_provenance' not in key.lower()}
    if isinstance(value, list):
        return [_attributed(item, source) for item in value]
    return value


def _inventory(value: Any) -> dict:
    value = _object(value, 'inventory')
    if not value:
        return {'context': {}, 'reports': {}}
    if value.get('kind') != INVENTORY_KIND or value.get('schema_version') != SCHEMA_VERSION:
        raise InstallationPlanError('unsupported inventory kind or schema_version')
    context = _object(value.get('context', {}), 'inventory.context')
    _string_fields(context, ('platform_system', 'machine', 'runtime_base', 'runtime_root', 'model_cache_dir'))
    reports = _object(value.get('reports', {}), 'inventory.reports')
    if set(reports) - set(WORKFLOWS):
        raise InstallationPlanError('inventory contains an unrelated workflow')
    for workflow_id, report in reports.items():
        _object(report, 'readiness report')
        if report.get('kind') != readiness.REPORT_KIND or report.get('schema_version') != readiness.SCHEMA_VERSION:
            raise InstallationPlanError('unsupported readiness report')
        report_request = _object(report.get('request', {}), 'report.request')
        _string_fields(report_request, ('workflow_id', 'requested_device'))
        if 'model_ids' in report_request:
            model_ids = report_request['model_ids']
            if not isinstance(model_ids, list) or any(not isinstance(model, str) for model in model_ids):
                raise InstallationPlanError('report.request.model_ids must be an array of strings')
        _object(report.get('components', {}), 'report.components')
        stages = report.get('stages', [])
        if not isinstance(stages, list):
            raise InstallationPlanError('report.stages must be an array')
        seen = set()
        for stage in stages:
            _object(stage, 'report stage')
            sid = stage.get('stage_id')
            if not isinstance(sid, str) or sid in seen:
                raise InstallationPlanError('invalid or duplicate inventory stage_id')
            seen.add(sid)
            _string_fields(stage, ('model_id', 'capability_id'))
            _object(stage.get('components', {}), 'stage.components')
        for components in [report.get('components', {})] + [s.get('components', {}) for s in stages]:
            for raw in components.values():
                _object(raw, 'readiness component')
                _string_fields(raw, ('verdict', 'reason_code', 'path', 'presence'))
                if raw.get('verdict') not in readiness._VERDICTS:
                    raise InstallationPlanError('invalid readiness verdict')
                evidence = _object(raw.get('evidence', {}), 'component.evidence')
                resolution = _object(raw.get('resolution', {}), 'component.resolution')
                _object(resolution.get('selection_info', {}), 'selection_info')
                _string_fields(resolution, ('requested', 'resolved_backend', 'resolved_device_id', 'resolved_device_name'))
                devices = resolution.get('available_devices', [])
                if not isinstance(devices, list) or any(not isinstance(d, dict) for d in devices):
                    raise InstallationPlanError('available_devices must be an array of objects')
                _object(resolution.get('resolved_device_identity', {}), 'resolved_device_identity')
                if raw.get('presence', 'unknown') not in {'unknown', 'present', 'absent', 'partial'}:
                    raise InstallationPlanError('invalid presence evidence')
                for field in ('files_present', 'files_verified', 'files_missing', 'files_mismatched'):
                    files = evidence.get(field, [])
                    if not isinstance(files, list) or any(not isinstance(f, str) for f in files):
                        raise InstallationPlanError(f'{field} must be an array of strings')
                _string_fields(evidence, ('integrity',))
                if evidence.get('integrity', 'unknown') not in {'unknown', 'unverified', 'sha256_verified', 'mismatch'}:
                    raise InstallationPlanError('invalid integrity state')
                for field in ('python_executable', 'runtime_base', 'runtime_root', 'model_cache_dir', 'integrity'):
                    if field in evidence and not isinstance(evidence[field], str):
                        raise InstallationPlanError(f'{field} must be a string')
    return value


def _platform_blockers(context: dict, device: str) -> list[str]:
    # Negative platform constraints, NOT an installation-support matrix.
    # Mirrors Core's sys.platform convention and DrumSep's Darwin ARM guard.
    platform = context.get('platform_system')
    if platform is None:
        return ['platform_unknown']
    if not isinstance(platform, str):
        raise InstallationPlanError('platform_system must be a string')
    linux, windows, mac = platform.startswith('linux'), platform.startswith('win'), platform == 'darwin'
    backend = device.split(':')[0]
    if (not any((linux, windows, mac)) or
        backend == 'mps' and not mac or
        backend == 'rocm' and not linux or
        backend == 'directml' and not windows or
        backend == 'cuda' and mac):
        return ['unsupported_platform_device']
    if backend not in {'auto', 'cpu', 'cuda', 'rocm', 'mps', 'directml'}:
        return ['unsupported_platform_device']
    if backend == 'mps':
        if not context.get('machine'):
            return ['architecture_unknown']
        if context['machine'].lower() not in {'arm64', 'aarch64'}:
            return ['unsupported_platform_device']
    return []


def _observations(component: dict, inventory: dict, workflows: list) -> list[dict]:
    observations = []
    reports = inventory.get('reports', {})
    for consumer in component['consumers']:
        report = reports.get(consumer['workflow_id'], {})
        stage = next((s for s in report.get('stages', []) if s['stage_id'] == consumer['stage_id']), {})
        expected = next(s for w in workflows if w['workflow_id'] == consumer['workflow_id']
                        for s in w['stages'] if s['stage_id'] == consumer['stage_id'])
        raw = (report.get('components', {}) if component['kind'] == 'ffmpeg'
               else stage.get('components', {})).get(component['kind'], {})
        observations.append({'consumer': consumer, 'component': raw,
                             'capability': stage.get('components', {}).get('capability', {}),
                             'stage': stage, 'expected': expected, 'report_request': report.get('request', {})})
    return observations


def _runtime_blockers(observation: dict, request: InstallationRequest, catalogs: dict, context: dict) -> list[str]:
    raw, capability = observation['component'], observation['capability']
    if capability.get('verdict') != 'PASS':
        return [capability.get('reason_code') or 'capability_evidence_unknown']
    resolution = capability.get('resolution', {})
    runtime_python = raw.get('evidence', {}).get('python_executable')
    selector_python = capability.get('evidence', {}).get('python_executable')
    blockers = []
    if not runtime_python or not selector_python:
        blockers.append('interpreter_identity_unknown')
    elif runtime_python != selector_python:
        blockers.append('interpreter_identity_mismatch')
    if resolution.get('requested') != request.requested_device:
        blockers.append('request_identity_mismatch')
    if not all(isinstance(resolution.get(k), str) and resolution[k]
               for k in ('resolved_backend', 'resolved_device_id', 'resolved_device_name')):
        return blockers + ['device_evidence_unknown']
    blockers.extend(_platform_blockers(context, resolution['resolved_backend']))
    family = resolution.get('selection_info', {}).get('runtime_source_family')
    if family is not None:
        if not isinstance(family, str) or family not in readiness.device_policy.DRUMSEP_RUNTIME_KINDS:
            raise InstallationPlanError('unknown runtime source family')
        blockers.extend(_platform_blockers(context, family))
    consumer, expected = observation['consumer'], observation['expected']
    _, infos = readiness._resolve_stage_infos(readiness.ReadinessRequest(consumer['workflow_id']), catalogs)
    info = next(i for i in infos if i['stage']['stage_id'] == expected['stage_id'])
    try:
        # Wrap the already selected result; never enumerate or select host devices.
        runtime_resolution._resolve_single_stage(
            catalogs, consumer['workflow_id'], info['stage'], info['model_id'],
            request.requested_device, readiness._probe_from_resolution(
                info['flavor'], resolution, platform_system=context.get('platform_system', 'unknown')))
    except runtime_resolution.ResolutionError as exc:
        blockers.append(exc.code)
    resolved_id = resolution['resolved_device_id']
    backend = resolution['resolved_backend']
    expected_prefix = 'cuda' if backend in {'cuda', 'rocm'} else backend
    if resolved_id.split(':')[0] != expected_prefix:
        blockers.append('device_identity_mismatch')
    if re.fullmatch(r'(cuda|directml):\d+', request.requested_device) and resolved_id != request.requested_device and resolved_id != 'cpu':
        blockers.append('device_identity_mismatch')
    if request.requested_device == 'cpu' and resolved_id != 'cpu':
        blockers.append('device_identity_mismatch')
    return blockers



def _model_asset_blockers(component_id: str, raw: dict) -> list[str]:
    """Compare snapshot identities to Core's existing model requirements."""
    evidence = raw.get('evidence', {})
    present = set(evidence.get('files_present', []) + evidence.get('files_verified', []))
    if component_id == 'model:drumsep_mdx23c':
        expected = set(model_assets.DIRECT_DKS_MODEL_EXPECTED_SHA256)
        observed = present | set(evidence.get('files_missing', [])) | set(evidence.get('files_mismatched', []))
        if observed - expected:
            return ['component_identity_mismatch']
        if raw.get('verdict') == 'PASS' and (
            not expected <= set(evidence.get('files_verified', []))
            or evidence.get('integrity') != 'sha256_verified'
        ):
            return ['asset_evidence_unknown']
    elif raw.get('verdict') == 'PASS':
        descriptor = readiness.DEMUCS_AUDIO_SEPARATOR_MODEL_IDS[component_id.removeprefix('model:')]
        if descriptor not in present:
            return ['component_identity_mismatch' if present else 'asset_evidence_unknown']
        if not any(name.endswith('.th') for name in present):
            return ['asset_evidence_unknown']
    return []


def _assess(component: dict, observations: list, request: InstallationRequest,
            catalogs: dict, context: dict, source: str, common_blockers: list) -> dict:
    blockers = list(common_blockers)
    presences, integrities, targets, signatures, evidence_items = [], [], [], [], []
    all_usable = True
    any_failed = False
    asset_states = {}
    for obs in observations:
        raw = obs['component']
        evidence = raw.get('evidence', {})
        verdict = raw.get('verdict')
        if verdict != 'PASS' and raw.get('reason_code'):
            blockers.append(raw['reason_code'])
        reported = obs['report_request']
        if not reported:
            blockers.append('request_identity_unknown')
        elif (reported.get('workflow_id') != obs['consumer']['workflow_id'] or
                         reported.get('requested_device') != request.requested_device):
            blockers.append('request_identity_mismatch')
        for field in ('model_id', 'capability_id'):
            if component['kind'] != 'ffmpeg' and field not in obs['stage']:
                blockers.append('component_identity_unknown')
            elif field in obs['stage'] and obs['stage'][field] != obs['expected'][field]:
                blockers.append('component_identity_mismatch')
        present = set(evidence.get('files_present', []) + evidence.get('files_verified', []))
        missing, corrupt = set(evidence.get('files_missing', [])), set(evidence.get('files_mismatched', []))
        for state, files in (('present', present), ('missing', missing), ('corrupt', corrupt)):
            for filename in files:
                asset_states.setdefault(filename, set()).add(state)
        declared_presence = raw.get('presence', 'unknown')
        presence = declared_presence
        if presence == 'absent' and (present or corrupt):
            blockers.append('conflicting_evidence')
        if verdict == 'PASS':
            if presence in {'absent', 'partial'} or missing or corrupt:
                blockers.append('conflicting_evidence')
            presence = 'present'
        elif missing or raw.get('reason_code') == readiness.REASON_MODEL_ASSETS_MISSING:
            presence = 'partial' if present else 'absent'
        elif present or corrupt:
            presence = 'present'
        if declared_presence != 'unknown' and presence != declared_presence:
            blockers.append('conflicting_evidence')
            presence = 'unknown'
        if present & missing or present & corrupt or missing & corrupt:
            blockers.append('conflicting_evidence')
        if corrupt or evidence.get('integrity') == 'mismatch' or raw.get('reason_code') == readiness.REASON_ASSET_INTEGRITY_MISMATCH:
            blockers.append('repair_decision_required')
            if verdict == 'PASS':
                blockers.append('conflicting_evidence')
        elif verdict == 'FAIL' and presence not in {'absent', 'partial'}:
            blockers.extend([raw.get('reason_code') or 'existing_component_unusable', 'repair_decision_required'])
        if presence == 'unknown':
            blockers.append('installed_state_unknown')
        elif presence in {'absent', 'partial'}:
            blockers.append('component_missing')
        elif verdict not in {'PASS', 'FAIL'}:
            blockers.append('usability_unknown')
        if component['kind'] == 'runtime':
            blockers.extend(_runtime_blockers(obs, request, catalogs, context))
        integrity = evidence.get('integrity', 'unknown')
        if corrupt or raw.get('reason_code') == readiness.REASON_ASSET_INTEGRITY_MISMATCH:
            integrity = 'mismatch'
        integrities.append(integrity)
        presences.append(presence)
        all_usable &= verdict == 'PASS'
        any_failed |= verdict == 'FAIL'
        target = (evidence.get('python_executable') if component['kind'] == 'runtime' else
                  evidence.get('model_cache_dir') if component['kind'] == 'model' else raw.get('path'))
        if target:
            targets.append(target)
        elif verdict == 'PASS':
            blockers.append('component_identity_unknown')
        if component['kind'] == 'model':
            blockers.extend(_model_asset_blockers(component['id'], raw))
        # Only compare established identities; omission stays unknown. Never
        # normalize paths using this host or merge contradictory root conventions.
        signature = {key: evidence[key] for key in ('runtime_base', 'runtime_root', 'model_cache_dir') if evidence.get(key)}
        if any(context.get(key) and context[key] != value for key, value in signature.items()):
            blockers.append('conflicting_evidence')
        if component['kind'] == 'runtime':
            selection_evidence = obs['capability'].get('evidence', {})
            selection_roots = {key: selection_evidence[key] for key in ('runtime_base', 'runtime_root') if selection_evidence.get(key)}
            signatures.append(selection_roots)
            roots = {value for source_roots in (signature, selection_roots, context)
                     for key, value in source_roots.items() if key in {'runtime_base', 'runtime_root'} and value}
            if len(roots) > 1:
                blockers.append('conflicting_evidence')
            resolution = obs['capability'].get('resolution', {})
            signature.update({key: resolution[key] for key in ('resolved_backend', 'resolved_device_id', 'resolved_device_identity') if resolution.get(key)})
            family = resolution.get('selection_info', {}).get('runtime_source_family')
            if family:
                signature['runtime_source_family'] = family
        if evidence.get('runtime_base') and evidence.get('runtime_root') and evidence['runtime_base'] != evidence['runtime_root']:
            blockers.append('conflicting_evidence')
        signatures.append(signature)
        evidence_items.append({'consumer': obs['consumer'], 'source': source,
                               'snapshot': _attributed(raw, source),
                               **({'selection': _attributed(obs['capability'], source)} if component['kind'] == 'runtime' else {})})
    if any(len(states) > 1 for states in asset_states.values()):
        blockers.append('conflicting_evidence')
    if len(set(targets)) > 1 or len(set(presences) - {'unknown'}) > 1:
        blockers.append('conflicting_evidence')
    for key in {key for signature in signatures for key in signature}:
        if len({canonical_json(sig[key]) for sig in signatures if key in sig}) > 1:
            blockers.append('conflicting_evidence')
    presence = presences[0] if len(set(presences)) == 1 else 'unknown'
    integrity = integrities[0] if len(set(integrities)) == 1 else 'unknown'
    if len(set(integrities) - {'unknown', 'unverified'}) > 1:
        blockers.append('conflicting_evidence')
    blockers = sorted(set(blockers))
    usability = 'preflight_fail' if any_failed else 'preflight_pass' if all_usable else 'unknown'
    if 'conflicting_evidence' in blockers:
        usability = 'unknown'
    return {**component, 'presence': presence, 'usability': usability,
            'integrity': integrity, 'ownership': 'unknown', 'reusable': all_usable and not blockers,
            'blockers': blockers, 'evidence': evidence_items, 'target': targets[0] if len(set(targets)) == 1 else None}


def _actions(components: list[dict], common_blockers: list[str]) -> list[dict]:
    actions = []
    for component in components:
        if component['reusable']:
            continue
        key = component['id']
        blockers = component['blockers']
        # Only absence-related uncertainty can describe acquisition. Unknown
        # failure codes stay assessment blockers, never provisioning triggers.
        absence_blockers = {
            'component_missing', 'platform_unknown', 'architecture_unknown',
            'capability_evidence_unknown', 'interpreter_identity_unknown',
            'device_evidence_unknown', readiness.REASON_RUNTIME_EVIDENCE_MISSING,
            readiness.REASON_MODEL_ASSETS_MISSING, readiness.REASON_FFMPEG_UNAVAILABLE,
        }
        can_describe_acquisition = (component['presence'] in {'absent', 'partial'}
                                   and set(blockers) <= absence_blockers)
        if can_describe_acquisition:
            prerequisites = [b for b in blockers if b != 'component_missing'] + list(common_blockers) + ['provisioning_recipe_unknown', 'acquisition_source_unknown',
                                                   'platform_installation_support_unknown', 'ownership_policy_unknown']
            if component['target'] is None:
                prerequisites.append('target_unknown')
            actions.append({'id': f'acquire:{key}', 'intent': 'acquire_missing', 'component_id': key,
                            'depends_on': [], 'prerequisites': sorted(set(prerequisites)),
                            'target': component['target'], 'source_references': component['source_references']})
            actions.append({'id': f'verify:{key}', 'intent': 'verify_acquired', 'component_id': key,
                            'depends_on': [f'acquire:{key}'], 'prerequisites': ['verification_policy_unknown'],
                            'target': component['target'], 'source_references': component['source_references']})
        else:
            actions.append({'id': f'assess:{key}', 'intent': 'assess_existing', 'component_id': key,
                            'depends_on': [], 'prerequisites': blockers,
                            'target': component['target'], 'source_references': component['source_references']})
    if actions:
        actions.append({'id': 'reassess:drum_kit', 'intent': 'reassess_readiness', 'component_id': 'drum_kit',
                        'depends_on': sorted(a['id'] for a in actions if a['intent'] != 'acquire_missing'),
                        'prerequisites': ['fresh_readiness_evidence_required'], 'target': None,
                        'source_references': ['stemwerk_core.readiness.assess_readiness']})
    return _order_actions(actions)


def preview_installation(request: Any, *, inventory: Any, catalogs: Any) -> dict:
    """Pure preview. Missing inventory means unknown, never absent or installed."""
    request = _request(request)
    catalog_input = json.loads(canonical_json(catalogs))
    catalog_context = {'source': 'caller_supplied'}
    if isinstance(catalog_input, dict) and set(catalog_input) == {'entries', 'context'}:
        catalog_context = _object(catalog_input['context'], 'catalog context')
        catalog_input = catalog_input['entries']
    catalogs = _validate_catalogs(catalog_input)
    collected = isinstance(inventory, _CollectedInventory)
    supplied = inventory is not None
    inventory = _inventory(json.loads(canonical_json(inventory)) if supplied else {})
    source = 'readiness_collection' if collected else 'caller_supplied' if supplied else 'not_supplied'
    try:
        workflows, required = _expand(catalogs)
    except readiness.ReadinessError as exc:
        raise InstallationPlanError(str(exc)) from exc
    context = inventory.get('context', {})
    common_blockers = _platform_blockers(context, request.requested_device)
    if inventory.get('catalog_fingerprint') not in (None, _fingerprint(catalogs)):
        common_blockers.append('catalog_evidence_mismatch')
    for workflow in workflows:
        report = inventory.get('reports', {}).get(workflow['workflow_id'], {})
        model_ids = report.get('request', {}).get('model_ids')
        if model_ids is not None and model_ids != [s['model_id'] for s in workflow['stages']]:
            common_blockers.append('request_identity_mismatch')
        if set(s['stage_id'] for s in report.get('stages', [])) - {s['stage_id'] for s in workflow['stages']}:
            raise InstallationPlanError('inventory contains an unknown workflow stage')
    common_blockers.extend(_workflow_blockers(inventory))
    components = [_assess(c, _observations(c, inventory, workflows), request, catalogs, context, source, common_blockers)
                  for c in required.values()]
    actions = _actions(components, common_blockers)
    return {'kind': 'stemwerk_installation_preview', 'schema_version': SCHEMA_VERSION,
            'request': asdict(request), 'requirements': {'workflows': workflows},
            'context': _attributed(context, source), 'catalog_context': catalog_context,
            'provenance': {'source': source, 'locally_verified': collected, 'mutation_authority': False,
                           'assessment_scope': 'readiness_preflight_snapshot',
                           'authoritative_gate': 'execution_time_recheck'},
            'components': components,
            'reusable_components': [c['id'] for c in components if c['reusable']],
            'missing_prerequisites': [c['id'] for c in components if c['presence'] in {'absent', 'partial'}],
            'actions': actions,
            'blockers': sorted({b for c in components for b in c['blockers']} | {b for a in actions for b in a['blockers']}),
            'unknowns': [{'component_id': c['id'], 'fields': [field for field in ('presence', 'usability', 'integrity', 'ownership') if c[field] in {'unknown', 'unverified'}]}
                         for c in components if any(c[field] in {'unknown', 'unverified'} for field in ('presence', 'usability', 'integrity', 'ownership'))],
            'input_fingerprints': {'request': _fingerprint(asdict(request)),
                                   'inventory': _fingerprint(inventory), 'catalogs': _fingerprint(catalogs),
                                   'catalog_context': _fingerprint(catalog_context),
                                   'evidence_origin': _fingerprint(source)},
            'execution': {'classification': 'informational_preview', 'executable': False}}


def _workflow_blockers(inventory: dict) -> list[str]:
    blockers = []
    for report in inventory.get('reports', {}).values():
        feasibility = report.get('components', {}).get('feasibility', {})
        if feasibility and feasibility.get('verdict') != 'PASS':
            blockers.append(feasibility.get('reason_code') or 'readiness_feasibility_unresolved')
        identities = []
        for stage in report.get('stages', []):
            resolution = stage.get('components', {}).get('capability', {}).get('resolution', {})
            if re.fullmatch(r'cuda:\d+', str(resolution.get('resolved_device_id', ''))):
                identities.append({key: str(value).strip().lower()
                                   for key, value in resolution.get('resolved_device_identity', {}).items()
                                   if key in {'uuid', 'pci_bus_id'} and value})
        if len(identities) > 1:
            reference = identities[0]
            for identity in identities[1:]:
                common = set(reference) & set(identity)
                if not common:
                    blockers.append('device_identity_unknown')
                elif any(reference[key] != identity[key] for key in common):
                    blockers.append('device_identity_mismatch')
    return blockers


def collect_installation_inventory(
    request: Any, *, catalog_dir: Any = None, collectors: Any = None,
    model_asset_providers: Any = None,
) -> dict:
    """Explicit readiness collection, with readiness's third-party probe limits.

    No intentional installation/download/repair. Readiness uses owned temporary
    directories; arbitrary third-party imports may still initialize caches or
    contact networks. The pure planner never calls this function.
    """
    request = _request(request)
    with readiness._catalog_dir(catalog_dir) as (root, source):
        catalogs = _validate_catalogs(readiness._load_catalogs(root))
        reports = {workflow: readiness.assess_readiness(
            readiness.ReadinessRequest(workflow, requested_device=request.requested_device),
            catalog_dir=root, collectors=collectors, model_asset_providers=model_asset_providers,
        ) for workflow in WORKFLOWS}
        return _CollectedInventory(
            kind=INVENTORY_KIND, schema_version=SCHEMA_VERSION,
            context={'platform_system': sys.platform, 'machine': platform.machine(),
                     'catalog': {'source': source, 'path': str(root)},
                     'collection_limits': ['no_inference_evidence', 'third_party_initialization_side_effects_possible']},
            catalog_fingerprint=_fingerprint(catalogs), reports=reports,
        )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--module', required=True, choices=['drum_kit'])
    parser.add_argument('--device', default='auto')
    evidence = parser.add_mutually_exclusive_group()
    evidence.add_argument('--inventory', help='caller-supplied JSON inventory; locally unverified')
    evidence.add_argument('--collect', action='store_true', help='explicitly collect readiness evidence')
    parser.add_argument('--pretty', action='store_true')
    args = parser.parse_args(argv)
    try:
        request = _request(InstallationRequest(module_id=args.module, requested_device=args.device))
        with readiness._catalog_dir(None) as (root, catalog_source):
            catalogs = {'entries': readiness._load_catalogs(root),
                        'context': {'source': catalog_source, 'path': str(root)}}
            inventory = (collect_installation_inventory(request, catalog_dir=root) if args.collect else
                         contracts.load_json(args.inventory) if args.inventory else None)
            result = preview_installation(request, inventory=inventory, catalogs=catalogs)
        print(json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False)
              if args.pretty else canonical_json(result))
        return 0
    except Exception as exc:
        print(f'installation preview failed: {exc}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
