"""Portable installation previews: explicit evidence, no installed-state probes."""
from __future__ import annotations

import copy
import json
import os
from pathlib import Path
import socket
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / 'scripts/reaper/vendor/stemwerk-core/src'
sys.path.insert(0, str(CORE_SRC))
from stemwerk_core import installation_plan as plan, readiness, workflow_contracts

pytestmark = pytest.mark.portable


@pytest.fixture
def catalogs():
    return workflow_contracts.validate_catalogs(CORE_SRC / 'stemwerk_core/catalog')


def preview(catalogs, inventory=None, device='cpu'):
    return plan.preview_installation(plan.InstallationRequest(requested_device=device),
                                     inventory=inventory, catalogs=catalogs)


def test_unknown_is_not_missing_and_expands_both_split_stages(catalogs):
    result = preview(catalogs)
    assert result['kind'] == 'stemwerk_installation_preview'
    assert result['execution'] == {'classification': 'informational_preview', 'executable': False}
    stages = result['requirements']['workflows'][1]['stages']
    assert [s['model_id'] for s in stages] == ['htdemucs', 'drumsep_mdx23c']
    assert stages[1]['depends_on'] == ['separate_normal_for_kit']
    assert not result['missing_prerequisites']
    assert all(c['presence'] == 'unknown' for c in result['components'])
    assert not any(a['intent'] == 'acquire_missing' for a in result['actions'])
    drum = next(c for c in result['components'] if c['id'] == 'runtime:drumsep')
    assert len(drum['consumers']) == 2


def test_repeatable_without_io_or_host_discovery(catalogs, monkeypatch):
    def forbidden(*args, **kwargs):
        raise AssertionError('pure preview attempted I/O or discovery')
    monkeypatch.setattr(subprocess, 'run', forbidden)
    monkeypatch.setattr(socket, 'socket', forbidden)
    monkeypatch.setattr(Path, 'open', forbidden)
    monkeypatch.setattr(Path, 'home', forbidden)
    monkeypatch.setattr(readiness, '_utc_now', forbidden)
    monkeypatch.setattr(readiness, 'assess_readiness', forbidden)
    first = preview(catalogs)
    monkeypatch.setenv('STEMWERK_RUNTIME_BASE', '/different')
    assert plan.canonical_json(first) == plan.canonical_json(preview(catalogs))


def inventory(catalogs):
    reports = {}
    for workflow in plan.WORKFLOWS:
        _, infos = readiness._resolve_stage_infos(readiness.ReadinessRequest(workflow), catalogs)
        stages = []
        for info in infos:
            python = '/runtime/rocm/bin/python' if info['flavor'] == 'drumsep' else '/runtime/main/bin/python'
            stages.append({'stage_id': info['stage']['stage_id'], 'model_id': info['model_id'],
                           'capability_id': info['capability_id'], 'components': {
                'runtime': {'verdict': 'PASS', 'evidence': {'python_executable': python}},
                'capability': {'verdict': 'PASS', 'evidence': {'python_executable': python},
                    'resolution': {'requested': 'cpu', 'resolved_backend': 'cpu',
                        'resolved_device_id': 'cpu', 'resolved_device_name': 'cpu',
                        'available_devices': [{'id': 'cpu', 'name': 'CPU'}],
                        'selection_info': {'selection_policy': 'explicit_cpu_via_rocm_runtime',
                                           'runtime_source_family': 'rocm'} if info['flavor'] == 'drumsep' else {}}},
                'model': {'verdict': 'PASS', 'evidence': {'model_cache_dir': '/models',
                         'integrity': 'sha256_verified' if info['flavor'] == 'drumsep' else 'unverified',
                         'files_verified': sorted(plan.model_assets.DIRECT_DKS_MODEL_EXPECTED_SHA256) if info['flavor'] == 'drumsep' else [],
                         'files_present': ['htdemucs.yaml', 'controlled-weight.th'] if info['flavor'] == 'normal' else []}},
            }})
        reports[workflow] = {'kind': readiness.REPORT_KIND, 'schema_version': '1.0.0',
                            'request': {'workflow_id': workflow, 'requested_device': 'cpu',
                                        'model_ids': [info['model_id'] for info in infos]},
                            'stages': stages, 'components': {'ffmpeg': {'verdict': 'PASS', 'path': '/bin/ffmpeg'}}}
    return {'kind': plan.INVENTORY_KIND, 'schema_version': '1.0.0',
            'context': {'platform_system': 'linux', 'machine': 'x86_64'}, 'reports': reports}


def component(result, key):
    return next(c for c in result['components'] if c['id'] == key)


def drum_stages(inv):
    return [inv['reports']['drum_kit_direct']['stages'][0]['components'],
            inv['reports']['drum_kit_split']['stages'][1]['components']]


def test_satisfied_unknown_ownership_cpu_via_rocm(catalogs):
    result = preview(catalogs, inventory(catalogs))
    assert len(result['reusable_components']) == 5
    runtime = component(result, 'runtime:drumsep')
    assert runtime['target'] == '/runtime/rocm/bin/python'
    assert runtime['ownership'] == 'unknown'
    assert runtime['integrity'] == 'unknown'
    assert runtime['presence'] == 'present'
    assert len(runtime['evidence']) == 2
    assert not result['actions']
    assert component(result, 'model:htdemucs')['integrity'] == 'unverified'


def test_missing_and_partial_have_blocked_acquisition_and_transitive_verification(catalogs):
    inv = inventory(catalogs)
    for stage in drum_stages(inv):
        stage['runtime'] = {'verdict': 'UNAVAILABLE', 'presence': 'absent'}
        stage['capability'] = {'verdict': 'UNAVAILABLE'}
        stage['model'] = {'verdict': 'FAIL', 'reason_code': 'model_assets_missing',
                          'evidence': {'model_cache_dir': '/models', 'files_missing': [plan.model_assets.DIRECT_DKS_MODEL_YAML],
                                       'files_verified': [plan.model_assets.DIRECT_DKS_MODEL_FILENAME]}}
    result = preview(catalogs, inv)
    assert component(result, 'model:drumsep_mdx23c')['presence'] == 'partial'
    assert set(result['missing_prerequisites']) == {'runtime:drumsep', 'model:drumsep_mdx23c'}
    acquire = next(a for a in result['actions'] if a['id'] == 'acquire:runtime:drumsep')
    verify = next(a for a in result['actions'] if a['id'] == 'verify:runtime:drumsep')
    assert 'provisioning_recipe_unknown' in acquire['blockers']
    assert 'verification_policy_unknown' in verify['prerequisites']
    assert 'provisioning_recipe_unknown' in verify['blockers']
    assert verify['upstream_blockers'][0]['dependency'] == acquire['id']
    assert result['actions'][-1]['id'] == 'reassess:drum_kit'
    assert all(a['status'] == 'blocked' for a in result['actions'])


@pytest.mark.parametrize('field,value', [('python_executable', '/other/bin/python'),
                                        ('runtime_base', '/another-root')])
def test_conflicting_shared_runtime_roots_block_reuse(catalogs, field, value):
    inv = inventory(catalogs)
    first, second = drum_stages(inv)
    if field == 'runtime_base':
        first['runtime']['evidence'][field] = '/runtime'
    second['runtime']['evidence'][field] = value
    result = preview(catalogs, inv)
    assert not component(result, 'runtime:drumsep')['reusable']
    assert 'conflicting_evidence' in result['blockers']
    assert not any(a['intent'] == 'acquire_missing' for a in result['actions'])


def test_interpreter_and_device_contradictions(catalogs):
    inv = inventory(catalogs)
    drum_stages(inv)[0]['capability']['evidence']['python_executable'] = '/different/python'
    assert 'interpreter_identity_mismatch' in preview(catalogs, inv)['blockers']
    inv = inventory(catalogs)
    drum_stages(inv)[0]['capability']['resolution']['requested'] = 'cuda:0'
    assert 'request_identity_mismatch' in preview(catalogs, inv)['blockers']


@pytest.mark.parametrize('change', ['root', 'missing_and_verified', 'corrupt', 'pass_and_absent'])
def test_model_conflicts_or_corruption_never_suggest_replacement(catalogs, change):
    inv = inventory(catalogs)
    first, second = [s['model'] for s in drum_stages(inv)]
    if change == 'root':
        second['evidence']['model_cache_dir'] = '/other-models'
    elif change == 'missing_and_verified':
        first['evidence']['files_missing'] = [plan.model_assets.DIRECT_DKS_MODEL_FILENAME]
    elif change == 'corrupt':
        first.update(verdict='FAIL', reason_code='asset_integrity_mismatch')
        first['evidence']['files_mismatched'] = [plan.model_assets.DIRECT_DKS_MODEL_FILENAME]
    else:
        first['presence'] = 'absent'
    result = preview(catalogs, inv)
    assert not component(result, 'model:drumsep_mdx23c')['reusable']
    assert not any(a['intent'] == 'acquire_missing' for a in result['actions'])
    assert result['blockers']


@pytest.mark.parametrize('platform,device', [('freebsd', 'cpu'), ('linux', 'mps'), ('darwin', 'rocm'), ('linux', 'directml')])
def test_unsupported_platform_device_blocks(catalogs, platform, device):
    inv = inventory(catalogs)
    inv['context']['platform_system'] = platform
    result = preview(catalogs, inv, device)
    assert 'unsupported_platform_device' in result['blockers']
    assert not result['reusable_components']


def test_imported_claims_do_not_confer_authority(catalogs):
    inv = inventory(catalogs)
    inv['provenance'] = {'source': 'collected', 'locally_verified': True}
    for stage in drum_stages(inv):
        stage['runtime']['ownership'] = 'managed'
        stage['runtime']['evidence'].update(source='collected', selector_provenance='production_selector')
    result = preview(catalogs, inv)
    assert result['provenance']['source'] == 'caller_supplied'
    assert not result['provenance']['locally_verified']
    assert component(result, 'runtime:drumsep')['ownership'] == 'unknown'
    assert 'selector_provenance' not in plan.canonical_json(result)
    assert '"ownership":"managed"' not in plan.canonical_json(result)


@pytest.mark.parametrize('damage', ['empty', 'backend', 'dependency', 'duplicate', 'model', 'order'])
def test_invalid_catalogs_are_errors_not_installation_triggers(catalogs, damage):
    if damage == 'empty':
        catalogs['models'] = []
    elif damage == 'backend':
        catalogs['capabilities'][0]['permitted_backends'] = ['magic']
    elif damage == 'dependency':
        catalogs['workflows'][2]['ordered_stages'][1]['input_stage_id'] = 'drumsep_kit'
    elif damage == 'duplicate':
        catalogs['models'].append(catalogs['models'][0])
    elif damage == 'model':
        catalogs['models'][0]['capability_id'] = 'bogus'
    else:
        catalogs['workflows'][2]['ordered_stages'].reverse()
    with pytest.raises(plan.InstallationPlanError):
        preview(catalogs)


def test_canonical_catalog_sets_and_ordered_evidence(catalogs):
    inv = inventory(catalogs)
    original = copy.deepcopy(inv)
    first = preview(catalogs, inv)
    for entries in catalogs.values():
        entries.reverse()
    assert first == preview(catalogs, inv)
    assert inv == original
    inv['context']['candidate_roots'] = ['/a', '/b']
    a = preview(catalogs, inv)['input_fingerprints']['inventory']
    inv['context']['candidate_roots'].reverse()
    assert a != preview(catalogs, inv)['input_fingerprints']['inventory']


@pytest.mark.parametrize('dependencies', [['missing'], ['a'], ['b'], ['b', 'b']])
def test_malformed_action_dependencies_rejected(dependencies):
    with pytest.raises(plan.InstallationPlanError):
        plan._order_actions([{'id': 'a', 'depends_on': dependencies, 'prerequisites': []},
                             {'id': 'b', 'depends_on': ['a'], 'prerequisites': []}])


def test_collection_delegates_to_readiness_and_serialization_loses_live_provenance(catalogs, monkeypatch):
    inv = inventory(catalogs)
    calls = []
    def assess(request, **kwargs):
        calls.append((request, kwargs))
        return inv['reports'][request.workflow_id]
    monkeypatch.setattr(readiness, 'assess_readiness', assess)
    result = plan.collect_installation_inventory(plan.InstallationRequest(requested_device='cpu'),
                                                catalog_dir=CORE_SRC / 'stemwerk_core/catalog')
    assert [r.workflow_id for r, _ in calls] == list(plan.WORKFLOWS)
    assert all(r.evidence_mode == 'collect' for r, _ in calls)
    assert preview(catalogs, result)['provenance']['source'] == 'readiness_collection'
    assert preview(catalogs, json.loads(json.dumps(result)))['provenance']['source'] == 'caller_supplied'


def test_cli_api_agree_for_inventory_and_never_collect_by_default(catalogs, tmp_path, monkeypatch, capsys):
    inv = inventory(catalogs)
    path = tmp_path / 'inventory.json'
    path.write_text(json.dumps(inv))
    def forbidden(*args, **kwargs):
        raise AssertionError('unexpected collection')
    monkeypatch.setattr(plan, 'collect_installation_inventory', forbidden)
    args = ['--module', 'drum_kit', '--device', 'cpu', '--inventory', str(path), '--pretty']
    assert plan.main(args) == 0
    output = capsys.readouterr()
    assert not output.err
    with readiness._catalog_dir(None) as (root, source):
        explicit_catalogs = {'entries': catalogs, 'context': {'source': source, 'path': str(root)}}
    assert json.loads(output.out) == preview(explicit_catalogs, inv)
    assert plan.main(['--module', 'drum_kit', '--device', 'cpu']) == 0
    output = capsys.readouterr()
    result = json.loads(output.out)
    assert not result['reusable_components']
    assert result['provenance']['source'] == 'not_supplied'
    assert all(c['presence'] == 'unknown' for c in result['components'])


def test_cli_collect_is_explicit(catalogs, monkeypatch, capsys):
    called = []
    def collect(request, **kwargs):
        called.append(request)
        return inventory(catalogs)
    monkeypatch.setattr(plan, 'collect_installation_inventory', collect)
    assert plan.main(['--module', 'drum_kit', '--device', 'cpu', '--collect']) == 0
    assert len(called) == 1
    assert json.loads(capsys.readouterr().out)['execution']['executable'] is False


@pytest.mark.parametrize('text', ['{', '[]', '{"kind":"wrong"}', '{"x":1,"x":2}', '{"x":NaN}'])
def test_cli_invalid_input_exit_2(tmp_path, capsys, text):
    path = tmp_path / 'bad.json'
    path.write_text(text)
    assert plan.main(['--module', 'drum_kit', '--inventory', str(path)]) == 2
    output = capsys.readouterr()
    assert output.err
    assert not output.out


def test_python_module_cli_exits_and_import_boundary(tmp_path):
    env = {**os.environ, 'PYTHONPATH': str(CORE_SRC), 'PYTHONDONTWRITEBYTECODE': '1'}
    base = [sys.executable, '-m', 'stemwerk_core.installation_plan', '--module', 'drum_kit', '--device', 'cpu']
    for args, code in [([], 0), (['--collect', '--inventory', 'unused.json'], 2), (['--device', 'invalid'], 2)]:
        proc = subprocess.run(base + args, capture_output=True, text=True, env=env, cwd=tmp_path, timeout=20)
        assert proc.returncode == code, proc.stderr
        if code == 0:
            assert json.loads(proc.stdout)['execution']['executable'] is False
        else:
            assert not proc.stdout
            assert proc.stderr
    proc = subprocess.run([sys.executable, '-c',
        "from stemwerk_core import installation_plan; import sys; "
        "assert not {'torch','yaml','reaper','audio_separator','onnxruntime'} & set(sys.modules)"],
        capture_output=True, text=True, env=env, cwd=tmp_path, timeout=20)
    assert proc.returncode == 0, proc.stderr


def test_split_physical_devices_must_match(catalogs):
    inv = inventory(catalogs)
    for report in inv['reports'].values():
        report['request']['requested_device'] = 'cuda:0'
        for stage in report['stages']:
            cap = stage['components']['capability']
            cap['resolution'].update(requested='cuda:0', resolved_backend='cuda',
                resolved_device_id='cuda:0', resolved_device_name='GPU',
                resolved_device_identity={'uuid': stage['capability_id']},
                available_devices=[{'id': 'cuda:0', 'name': 'GPU'}])
    result = preview(catalogs, inv, 'cuda:0')
    assert 'device_identity_mismatch' in result['blockers']
    assert not component(result, 'runtime:drumsep')['reusable']


def test_failed_readiness_feasibility_never_becomes_reuse(catalogs):
    inv = inventory(catalogs)
    inv['reports']['drum_kit_split']['components']['feasibility'] = {
        'verdict': 'FAIL', 'reason_code': 'execution_contract_unsupported'}
    result = preview(catalogs, inv)
    assert 'execution_contract_unsupported' in result['blockers']
    assert not component(result, 'runtime:drumsep')['reusable']


def test_opposing_asset_observations_with_same_partial_presence_conflict(catalogs):
    inv = inventory(catalogs)
    for stage, missing, verified in zip(drum_stages(inv), ['a', 'b'], ['b', 'a']):
        stage['model'] = {'verdict': 'FAIL', 'reason_code': 'model_assets_missing',
                          'evidence': {'model_cache_dir': '/models', 'files_missing': [missing],
                                       'files_verified': [verified]}}
    result = preview(catalogs, inv)
    assert 'conflicting_evidence' in result['blockers']
    assert not any(a['intent'] == 'acquire_missing' for a in result['actions'])


@pytest.mark.parametrize('field', ['model_id', 'capability_id'])
def test_omitted_stage_identity_stays_unknown(catalogs, field):
    inv = inventory(catalogs)
    del inv['reports']['drum_kit_split']['stages'][0][field]
    assert not component(preview(catalogs, inv), 'model:htdemucs')['reusable']


def test_bare_model_pass_does_not_identify_reusable_assets(catalogs):
    inv = inventory(catalogs)
    for stage in drum_stages(inv):
        stage['model'] = {'verdict': 'PASS'}
    result = preview(catalogs, inv)
    assert not component(result, 'model:drumsep_mdx23c')['reusable']
    assert 'component_identity_unknown' in result['blockers']


def test_preserves_valid_linux_attributed_cuda_cpu_fallback(catalogs):
    inv = inventory(catalogs)
    for report in inv['reports'].values():
        report['request']['requested_device'] = 'cuda:0'
        for stage in report['stages']:
            resolution = stage['components']['capability']['resolution']
            resolution['requested'] = 'cuda:0'
            if stage['capability_id'] == 'drum_kit_6':
                resolution['selection_info'] = {'selection_policy': 'fallback_cpu', 'fallback_reason': 'cuda_skipped:missing'}
            else:
                resolution.update(resolved_backend='cuda', resolved_device_id='cuda:0', resolved_device_name='GPU',
                                  available_devices=[{'id': 'cuda:0', 'name': 'GPU'}],
                                  resolved_device_identity={'uuid': 'gpu0'})
    assert component(preview(catalogs, inv, 'cuda:0'), 'runtime:drumsep')['reusable']


def test_conflicting_root_conventions_are_not_merged(catalogs):
    inv = inventory(catalogs)
    for stage in drum_stages(inv):
        stage['runtime']['evidence'].update(runtime_root='/a', runtime_base='/b')
    result = preview(catalogs, inv)
    assert 'conflicting_evidence' in result['blockers']
    assert not component(result, 'runtime:drumsep')['reusable']


def test_drumsep_integrity_pins_are_core_owned(catalogs):
    result = preview(catalogs)
    assets = component(result, 'model:drumsep_mdx23c')['authoritative_assets']
    assert {a['name']: a['sha256'] for a in assets} == plan.model_assets.DIRECT_DKS_MODEL_EXPECTED_SHA256
    assert all('url' not in a for a in assets)


@pytest.mark.parametrize('change', ['verdict', 'reason', 'path', 'machine', 'resolution', 'stage', 'request'])
def test_malformed_inventory_rejected(catalogs, change):
    inv = inventory(catalogs)
    raw = drum_stages(inv)[0]
    if change == 'verdict':
        raw['runtime']['verdict'] = []
    elif change == 'reason':
        raw['runtime'].update(verdict='FAIL', reason_code=[])
    elif change == 'path':
        inv['reports']['drum_kit_direct']['components']['ffmpeg']['path'] = []
    elif change == 'machine':
        inv['context']['machine'] = []
    elif change == 'resolution':
        raw['capability']['resolution']['available_devices'] = [1]
    elif change == 'stage':
        inv['reports']['drum_kit_split']['stages'][0]['model_id'] = []
    else:
        inv['reports']['drum_kit_split']['request'] = []
    with pytest.raises(plan.InstallationPlanError):
        preview(catalogs, inv)


@pytest.mark.parametrize('change', ['integrity', 'absent_with_files', 'context_root', 'runtime_family'])
def test_contradictory_claims_block_reuse_and_acquisition(catalogs, change):
    inv = inventory(catalogs)
    for stage in drum_stages(inv):
        if change == 'integrity':
            stage['model']['evidence']['integrity'] = 'mismatch'
        elif change == 'absent_with_files':
            stage['model'].update(verdict='UNAVAILABLE', presence='absent')
        elif change == 'context_root':
            inv['context']['model_cache_dir'] = '/different'
        else:
            inv['context']['platform_system'] = 'win32'
    result = preview(catalogs, inv)
    key = 'runtime:drumsep' if change == 'runtime_family' else 'model:drumsep_mdx23c'
    assert not component(result, key)['reusable']
    assert not any(a['intent'] == 'acquire_missing' for a in result['actions'])
    if change == 'integrity':
        assert 'repair_decision_required' in result['blockers']


def test_omitted_runtime_evidence_is_not_absence(catalogs):
    inv = inventory(catalogs)
    for stage in drum_stages(inv):
        stage['runtime'] = {'verdict': 'UNAVAILABLE', 'reason_code': 'runtime_evidence_missing'}
        stage['capability'] = {'verdict': 'UNAVAILABLE'}
    result = preview(catalogs, inv)
    assert component(result, 'runtime:drumsep')['presence'] == 'unknown'
    assert 'runtime:drumsep' not in result['missing_prerequisites']
    assert not any(a['intent'] == 'acquire_missing' for a in result['actions'])


def test_action_order_and_prerequisites_are_stable(catalogs):
    inv = inventory(catalogs)
    for report in inv['reports'].values():
        report['components']['ffmpeg'] = {'verdict': 'UNAVAILABLE', 'presence': 'absent'}
    result = preview(catalogs, inv)
    assert result == preview(catalogs, inv)
    seen = set()
    for action in result['actions']:
        assert set(action['depends_on']) <= seen
        assert set(action['prerequisites']) <= set(action['blockers'])
        seen.add(action['id'])
    assert result['actions'][-1]['id'] == 'reassess:drum_kit'
    assert 'acquisition_source_unknown' in result['actions'][-1]['blockers']


def test_in_memory_catalog_validation_matches_existing_loader(catalogs, tmp_path):
    variants = [copy.deepcopy(catalogs) for _ in range(6)]
    variants[1]['workflows'][2]['deliverable_routes'] = []
    variants[2]['workflows'][2]['ordered_stages'][1]['input_port_id'] = 'invented'
    variants[3]['models'][0]['output_semantic_ids'].reverse()
    variants[4]['workflows'][0]['ordered_stages'][0]['order'] = True
    variants[5]['capabilities'][0]['permitted_backends'] = []
    for entries in variants:
        for name, values in entries.items():
            (tmp_path / f'{name}.v1.json').write_text(json.dumps({'schema_version': '1.0.0', name: values}))
        try:
            workflow_contracts.validate_catalogs(tmp_path)
        except workflow_contracts.ContractError:
            with pytest.raises(plan.InstallationPlanError):
                preview(entries)
        else:
            assert preview(entries)['requirements']


def test_pure_supplied_inventory_cannot_probe_or_mutate(catalogs, monkeypatch):
    import builtins
    inv = inventory(catalogs)
    before = plan.canonical_json(inv)
    def forbidden(*args, **kwargs):
        raise AssertionError('pure planner attempted a side effect')
    for target, name in [(builtins, 'open'), (Path, 'open'), (Path, 'write_text'),
                         (Path, 'mkdir'), (Path, 'unlink'), (Path, 'exists'),
                         (Path, 'home'), (subprocess, 'run'), (subprocess, 'Popen'),
                         (socket, 'socket'), (os, 'getenv'), (readiness, '_utc_now'),
                         (plan.platform, 'machine')]:
        monkeypatch.setattr(target, name, forbidden)
    assert len(preview(catalogs, inv)['reusable_components']) == 5
    assert plan.canonical_json(inv) == before


def test_duplicate_action_ids_rejected():
    with pytest.raises(plan.InstallationPlanError):
        plan._order_actions([{'id': 'same', 'depends_on': [], 'prerequisites': []}] * 2)


def test_collection_forwards_existing_readiness_injections(catalogs, monkeypatch):
    inv = inventory(catalogs)
    collectors, providers = {'drum_kit': object()}, {'htdemucs': object()}
    calls = []
    def assess(request, **kwargs):
        calls.append(kwargs)
        return inv['reports'][request.workflow_id]
    monkeypatch.setattr(readiness, 'assess_readiness', assess)
    monkeypatch.setattr(plan.platform, 'machine', lambda: 'x86_64')
    monkeypatch.setattr(plan.sys, 'platform', 'linux')
    result = plan.collect_installation_inventory(
        plan.InstallationRequest(requested_device='cpu'),
        catalog_dir=CORE_SRC / 'stemwerk_core/catalog', collectors=collectors,
        model_asset_providers=providers)
    assert all(c['collectors'] is collectors and c['model_asset_providers'] is providers for c in calls)
    assert result['context']['platform_system'] == 'linux'
    assert result['context']['machine'] == 'x86_64'
    assert preview(catalogs, result)['provenance']['locally_verified'] is True


def test_conflicting_runtime_and_capability_roots_are_preserved(catalogs):
    inv = inventory(catalogs)
    for stage in drum_stages(inv):
        stage['runtime']['evidence']['runtime_root'] = '/imports-root'
        stage['capability']['evidence']['runtime_root'] = '/selector-root'
    result = preview(catalogs, inv)
    assert 'conflicting_evidence' in result['blockers']
    assert not component(result, 'runtime:drumsep')['reusable']


def test_explicit_unknown_feasibility_does_not_become_ready(catalogs):
    inv = inventory(catalogs)
    inv['reports']['drum_kit_split']['components']['feasibility'] = {
        'verdict': 'UNAVAILABLE', 'reason_code': 'runtime_evidence_missing'}
    result = preview(catalogs, inv)
    assert 'runtime_evidence_missing' in result['blockers']
    assert not result['reusable_components']


@pytest.mark.parametrize('blocker', ['platform', 'catalog', 'device'])
def test_known_unsupported_or_mismatched_state_never_proposes_acquisition(catalogs, blocker):
    inv = inventory(catalogs)
    for report in inv['reports'].values():
        report['components']['ffmpeg'] = {'verdict': 'UNAVAILABLE', 'presence': 'absent'}
    if blocker == 'platform':
        inv['context']['platform_system'] = 'freebsd'
    elif blocker == 'catalog':
        inv['catalog_fingerprint'] = 'different-catalog'
    else:
        inv['reports']['drum_kit_split']['components']['feasibility'] = {
            'verdict': 'FAIL', 'reason_code': 'execution_contract_unsupported'}
    result = preview(catalogs, inv)
    assert result['blockers']
    assert not any(a['intent'] == 'acquire_missing' for a in result['actions'])


def test_explicit_presence_is_not_overwritten_by_conflicting_missing_claim(catalogs):
    inv = inventory(catalogs)
    for stage in drum_stages(inv):
        stage['model'] = {'verdict': 'UNAVAILABLE', 'presence': 'present',
                          'reason_code': 'model_assets_missing'}
    result = preview(catalogs, inv)
    model = component(result, 'model:drumsep_mdx23c')
    assert model['presence'] == 'unknown'
    assert 'conflicting_evidence' in model['blockers']
    assert not any(a['intent'] == 'acquire_missing' for a in result['actions'])


@pytest.mark.parametrize('filenames', [['unrelated.txt'], [], [plan.model_assets.DIRECT_DKS_MODEL_FILENAME]])
def test_drumsep_reuse_requires_evidence_for_known_assets(catalogs, filenames):
    inv = inventory(catalogs)
    for stage in drum_stages(inv):
        stage['model']['evidence']['files_verified'] = filenames
    result = preview(catalogs, inv)
    assert not component(result, 'model:drumsep_mdx23c')['reusable']
    assert not any(a['intent'] == 'acquire_missing' for a in result['actions'])


def test_demucs_descriptor_for_another_model_does_not_satisfy_default(catalogs):
    inv = inventory(catalogs)
    inv['reports']['drum_kit_split']['stages'][0]['components']['model']['evidence']['files_present'] = ['htdemucs_ft.yaml', 'controlled.th']
    result = preview(catalogs, inv)
    assert not component(result, 'model:htdemucs')['reusable']


def test_conflicting_runtime_source_families_block_shared_reuse(catalogs):
    inv = inventory(catalogs)
    drum_stages(inv)[1]['capability']['resolution']['selection_info']['runtime_source_family'] = 'cpu'
    result = preview(catalogs, inv)
    runtime = component(result, 'runtime:drumsep')
    assert not runtime['reusable']
    assert 'conflicting_evidence' in runtime['blockers']
    assert not any(a['intent'] == 'acquire_missing' for a in result['actions'])


@pytest.mark.parametrize('model_ids', [['htdemucs'], ['drumsep_mdx23c', 'htdemucs']])
def test_report_model_request_must_match_expanded_ordered_models(catalogs, model_ids):
    inv = inventory(catalogs)
    inv['reports']['drum_kit_direct']['request']['model_ids'] = model_ids
    result = preview(catalogs, inv)
    assert 'request_identity_mismatch' in result['blockers']
    assert not result['reusable_components']


@pytest.mark.parametrize('model_ids', ['drumsep_mdx23c', [None], {}])
def test_malformed_report_model_request_is_input_error(catalogs, model_ids):
    inv = inventory(catalogs)
    inv['reports']['drum_kit_direct']['request']['model_ids'] = model_ids
    with pytest.raises(plan.InstallationPlanError):
        preview(catalogs, inv)


def test_component_usability_is_independent_of_workflow_feasibility(catalogs):
    inv = inventory(catalogs)
    inv['reports']['drum_kit_split']['components']['feasibility'] = {
        'verdict': 'UNAVAILABLE', 'reason_code': 'runtime_evidence_missing'}
    result = preview(catalogs, inv)
    assert not result['reusable_components']
    assert component(result, 'ffmpeg')['usability'] == 'preflight_pass'
    assert component(result, 'runtime:normal')['usability'] == 'preflight_pass'


def test_observed_component_failure_is_not_unknown_usability(catalogs):
    inv = inventory(catalogs)
    for report in inv['reports'].values():
        report['components']['ffmpeg'] = {'verdict': 'FAIL', 'presence': 'present', 'path': '/broken/ffmpeg'}
    ffmpeg = component(preview(catalogs, inv), 'ffmpeg')
    assert ffmpeg['presence'] == 'present'
    assert ffmpeg['usability'] == 'preflight_fail'
    assert 'usability_unknown' not in ffmpeg['blockers']
    assert not ffmpeg['reusable']


def test_incompatible_catalog_defaults_are_planning_errors(catalogs):
    direct = next(w for w in catalogs['workflows'] if w['workflow_id'] == 'drum_kit_direct')
    normal = next(c for c in catalogs['capabilities'] if c['capability_id'] == 'normal_stems_4')
    direct['ordered_stages'][0]['capability_ids'] = ['normal_stems_4']
    direct['deliverable_routes'] = [{'capability_id': 'normal_stems_4', 'deliverable_ids': normal['output_semantic_ids']}]
    with pytest.raises(plan.InstallationPlanError):
        preview(catalogs)


@pytest.mark.parametrize('reason', ['execution_contract_unsupported', 'unrecognized_failure'])
def test_absence_does_not_discard_failure_reasons_before_acquisition(catalogs, reason):
    inv = inventory(catalogs)
    for report in inv['reports'].values():
        report['components']['ffmpeg'] = {'verdict': 'FAIL', 'presence': 'absent', 'reason_code': reason}
    result = preview(catalogs, inv)
    assert reason in component(result, 'ffmpeg')['blockers']
    assert not any(a['intent'] == 'acquire_missing' for a in result['actions'])
