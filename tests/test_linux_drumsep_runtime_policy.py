from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BOOTSTRAP = ROOT / "scripts/reaper/STEMwerk_Bootstrap_Linux.sh"


def _script() -> str:
    return BOOTSTRAP.read_text(encoding="utf-8")


def _function(script: str, name: str) -> str:
    start = script.index(f"{name}() {{")
    depth = 0
    for index in range(start, len(script)):
        if script[index] == "{":
            depth += 1
        elif script[index] == "}":
            depth -= 1
            if depth == 0:
                return script[start : index + 1]
    raise AssertionError(f"unterminated shell function: {name}")


def _run_policy_harness(tmp_path: Path, body: str) -> subprocess.CompletedProcess[str]:
    tmp_path.mkdir(parents=True, exist_ok=True)
    script = _script()
    names = (
        "atomic_write_state_file",
        "classify_drumsep_assets_result",
        "drumsep_state_file",
        "drumsep_rocm_state_file",
        "drumsep_sibling_runtime_dir",
        "drumsep_sibling_state_file",
        "inspect_drumsep_sibling",
        "begin_drumsep_install_txn",
        "fail_drumsep_install_txn",
        "commit_drumsep_install_txn",
        "run_drumsep_install_transaction",
        "apply_drumsep_sibling_policy",
        "resolve_main_drumsep_runtime_policy",
    )
    functions = "\n\n".join(_function(script, name) for name in names)
    harness = tmp_path / "policy-harness.sh"
    harness.write_text(
        "#!/bin/sh\nset -u\n"
        f'RUNTIME_BASE="{tmp_path / "runtime"}"\n'
        f'LOG_FILE="{tmp_path / "policy.log"}"\n'
        'STATUS="ok"\nSTATUS_REASON=""\nMODE="repair"\n'
        "log() { printf '%s\\n' \"$*\" >> \"${LOG_FILE}\"; }\n"
        "log_step() { log \" - $*\"; }\n"
        "set_status() { STATUS=\"$1\"; STATUS_REASON=\"$2\"; log \"STATUS=${STATUS} REASON=${STATUS_REASON}\"; }\n"
        "write_main_unified_rocm_state() { log 'main_unified_state=written'; }\n"
        "write_main_unified_cpu_state() { log 'main_unified_cpu_state=written'; }\n"
        "install_drumsep_rocm_runtime() { log 'INSTALL_ROCM_CALLED'; return 0; }\n"
        "install_drumsep_runtime() { log 'INSTALL_CPU_CALLED'; return 0; }\n"
        f"{functions}\n"
        "write_drumsep_rocm_state() { { echo STATUS=ok; echo STATUS_REASON=verified_ready; echo DRUMSEP_ROCM_INSTALL_TXN=\"$8\"; echo DRUMSEP_ROCM_MUTATION_REASON=\"$9\"; } | atomic_write_state_file \"$(drumsep_rocm_state_file)\"; }\n"
        "write_drumsep_state() { { echo STATUS=ok; echo STATUS_REASON=verified_ready; echo DRUMSEP_CPU_INSTALL_TXN=\"$6\"; echo DRUMSEP_CPU_MUTATION_REASON=\"$7\"; } | atomic_write_state_file \"$(drumsep_state_file)\"; }\n"
        f"{body}\n",
        encoding="utf-8",
    )
    return subprocess.run(
        ["/bin/sh", str(harness)],
        text=True,
        capture_output=True,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        timeout=20,
    )


def test_structured_result_contract_and_internal_callsites_are_explicit() -> None:
    script = _script()
    assets = _function(script, "ensure_drumsep_assets")
    rocm_probe = _function(script, "probe_main_rocm_dks_ready")
    assert "return 20" in assets
    assert 'raise SystemExit(21)' in assets
    assert 'raise SystemExit(22)' in assets
    assert '0|20|21|22' in assets
    assert "return 30" in rocm_probe and "return 31" in rocm_probe
    assert script.count("classify_drumsep_assets_result") >= 3


def test_ensure_drumsep_assets_emits_all_structured_failure_classes(tmp_path: Path) -> None:
    python = shutil.which("python3")
    assert python
    script = _script()
    functions = "\n\n".join(
        _function(script, name) for name in ("copy_bundled_models_to_cache", "ensure_drumsep_assets")
    )

    def run_with(source: str | None) -> int:
        layout = tmp_path / ("missing" if source is None else str(abs(hash(source))))
        layout.mkdir()
        if source is not None:
            (layout / "audio_separator_process.py").write_text(source, encoding="utf-8")
        harness = layout / "assets.sh"
        harness.write_text(
            "#!/bin/sh\nset -u\n"
            f'SCRIPT_DIR="{layout}"\nBUNDLED_PAYLOAD_DIR="{layout / "bundled"}"\n'
            f'LOG_FILE="{layout / "assets.log"}"\n'
            f"{functions}\n"
            f'ensure_drumsep_assets "{python}" "{layout / "models"}"\n'
            "exit $?\n",
            encoding="utf-8",
        )
        return subprocess.run(["/bin/sh", str(harness)], timeout=20).returncode

    assert run_with(None) == 20
    assert run_with(
        'DIRECT_DKS_MODEL_ALIAS="alias"\n'
        "def _direct_dks_preflight_check(alias, model_dir):\n"
        '    return False, alias, alias, "model_missing"\n'
    ) == 21
    assert run_with(
        'DIRECT_DKS_MODEL_ALIAS="alias"\n'
        "def _direct_dks_preflight_check(alias, model_dir):\n"
        '    raise RuntimeError("unexpected")\n'
    ) == 22


def test_tooling_and_model_failures_never_reach_sibling_policy(tmp_path: Path) -> None:
    for result, reason in (
        (20, "drumsep_assets_tooling_failed"),
        (21, "drumsep_assets_model_failed"),
        (22, "drumsep_assets_internal_failed"),
    ):
        run = _run_policy_harness(
            tmp_path / str(result),
            f"""
mkdir -p "${{RUNTIME_BASE}}/state"
probe_main_rocm_dks_ready() {{ return 0; }}
ensure_drumsep_assets() {{ return {result}; }}
inspect_drumsep_sibling() {{ log INSPECT_CALLED; return 99; }}
resolve_main_drumsep_runtime_policy rocm
rc=$?
printf 'rc=%s status=%s reason=%s\n' "$rc" "$STATUS" "$STATUS_REASON"
""",
        )
        log = (tmp_path / str(result) / "policy.log").read_text(encoding="utf-8")
        assert run.returncode == 0
        assert f"reason={reason}" in run.stdout
        assert "INSPECT_CALLED" not in log
        assert "INSTALL_" not in log


def test_runtime_probe_error_is_not_runtime_not_ready(tmp_path: Path) -> None:
    run = _run_policy_harness(
        tmp_path,
        """
mkdir -p "${RUNTIME_BASE}/state"
probe_main_rocm_dks_ready() { return 31; }
ensure_drumsep_assets() { log ASSETS_CALLED; return 0; }
inspect_drumsep_sibling() { log INSPECT_CALLED; return 99; }
resolve_main_drumsep_runtime_policy rocm
printf 'status=%s reason=%s\n' "$STATUS" "$STATUS_REASON"
""",
    )
    log = (tmp_path / "policy.log").read_text(encoding="utf-8")
    assert "status=deps_failed reason=drumsep_probe_error" in run.stdout
    assert "ASSETS_CALLED" not in log
    assert "INSPECT_CALLED" not in log
    assert "INSTALL_" not in log


def test_main_unified_ready_assets_failure_never_inspects_sibling(tmp_path: Path) -> None:
    sibling = tmp_path / "runtime" / "sibling-fixture"
    sibling.mkdir(parents=True)
    marker = sibling / "unchanged"
    marker.write_bytes(b"unchanged\n")
    before = marker.read_bytes()
    run = _run_policy_harness(
        tmp_path,
        """
probe_main_rocm_dks_ready() { return 0; }
ensure_drumsep_assets() { return 21; }
inspect_drumsep_sibling() { exit 97; }
resolve_main_drumsep_runtime_policy rocm
printf 'status=%s reason=%s\n' "$STATUS" "$STATUS_REASON"
""",
    )
    assert run.returncode == 0
    assert "reason=drumsep_assets_model_failed" in run.stdout
    assert marker.read_bytes() == before


def test_repair_preserves_present_or_absent_sibling(tmp_path: Path) -> None:
    runtime = tmp_path / "runtime"
    state = runtime / "state"
    state.mkdir(parents=True)
    sibling = runtime / ".venv-drumsep-rocm"
    sibling.mkdir()
    marker = sibling / "unchanged"
    marker.write_bytes(b"present\n")
    (state / "drumsep_runtime_rocm.env").write_text(
        "STATUS=ok\nDRUMSEP_ROCM_RUNTIME_STATUS=ok\n", encoding="utf-8"
    )
    present = _run_policy_harness(
        tmp_path,
        """
probe_main_rocm_dks_ready() { return 30; }
resolve_main_drumsep_runtime_policy rocm
printf 'status=%s reason=%s sibling=%s txn=%s\n' "$STATUS" "$STATUS_REASON" "$DRUMSEP_SIBLING_STATE" "${DRUMSEP_INSTALL_TXN:-none}"
""",
    )
    assert "reason=drumsep_sibling_rebuild_required" in present.stdout
    assert "sibling=present_untouched" in present.stdout
    assert marker.read_bytes() == b"present\n"
    assert "INSTALL_" not in (tmp_path / "policy.log").read_text(encoding="utf-8")

    marker.unlink()
    sibling.rmdir()
    (state / "drumsep_runtime_rocm.env").unlink()
    absent = _run_policy_harness(
        tmp_path,
        """
probe_main_rocm_dks_ready() { return 30; }
resolve_main_drumsep_runtime_policy rocm
printf 'status=%s reason=%s\n' "$STATUS" "$STATUS_REASON"
""",
    )
    assert "reason=drumsep_sibling_missing" in absent.stdout
    assert not sibling.exists()


def test_presence_mismatches_fail_closed_for_setup_and_repair(tmp_path: Path) -> None:
    runtime = tmp_path / "runtime"
    state = runtime / "state"
    state.mkdir(parents=True)
    sibling = runtime / ".venv-drumsep"
    sibling.mkdir()
    (state / "drumsep_runtime.env").write_text("STATUS=missing\n", encoding="utf-8")
    present_missing = _run_policy_harness(
        tmp_path,
        """
MODE=drumsep-runtime
apply_drumsep_sibling_policy cpu
printf 'status=%s reason=%s\n' "$STATUS" "$STATUS_REASON"
""",
    )
    assert "reason=drumsep_sibling_state_inconsistent" in present_missing.stdout
    assert "INSTALL_" not in (tmp_path / "policy.log").read_text(encoding="utf-8")

    sibling.rmdir()
    (state / "drumsep_runtime.env").write_text(
        "STATUS=ok\nDRUMSEP_RUNTIME_STATUS=ok\n", encoding="utf-8"
    )
    absent_ready = _run_policy_harness(
        tmp_path,
        """
MODE=repair
apply_drumsep_sibling_policy cpu
printf 'status=%s reason=%s\n' "$STATUS" "$STATUS_REASON"
""",
    )
    assert "reason=drumsep_sibling_state_inconsistent" in absent_ready.stdout
    assert not sibling.exists()


def test_explicit_setup_transaction_orders_begin_mutation_commit(tmp_path: Path) -> None:
    run = _run_policy_harness(
        tmp_path,
        """
mkdir -p "${RUNTIME_BASE}/state"
transaction_body() { log SIBLING_MUTATION; return 0; }
run_drumsep_install_transaction rocm create_absent transaction_body
cat "$(drumsep_rocm_state_file)"
""",
    )
    assert run.returncode == 0
    state = run.stdout
    assert "DRUMSEP_ROCM_INSTALL_TXN=commit" in state
    assert "STATUS=ok" in state
    assert "DRUMSEP_ROCM_MUTATION_REASON=create_absent" in state
    log = (tmp_path / "policy.log").read_text(encoding="utf-8")
    assert log.index("DRUMSEP_INSTALL_TXN=begin") < log.index("SIBLING_MUTATION")
    assert log.index("SIBLING_MUTATION") < log.index("DRUMSEP_INSTALL_TXN=commit")


def test_interrupted_transaction_overrides_stale_ok(tmp_path: Path) -> None:
    state_dir = tmp_path / "runtime" / "state"
    state_dir.mkdir(parents=True)
    state_file = state_dir / "drumsep_runtime_rocm.env"
    state_file.write_text("STATUS=ok\nDRUMSEP_ROCM_RUNTIME_STATUS=ok\n", encoding="utf-8")
    run = _run_policy_harness(
        tmp_path,
        """
interrupt_body() { log SIBLING_MUTATION; kill -TERM $$; }
run_drumsep_install_transaction rocm rebuild_explicit interrupt_body
""",
    )
    assert run.returncode != 0
    state = state_file.read_text(encoding="utf-8")
    assert "DRUMSEP_ROCM_INSTALL_TXN=begin" in state
    assert "STATUS=incomplete" in state
    assert "STATUS=ok" not in state


def test_commit_write_failure_cannot_report_ok(tmp_path: Path) -> None:
    run = _run_policy_harness(
        tmp_path,
        """
mkdir -p "${RUNTIME_BASE}/state"
transaction_body() { log SIBLING_MUTATION; return 0; }
write_drumsep_rocm_state() { return 1; }
run_drumsep_install_transaction rocm create_absent transaction_body
rc=$?
printf 'rc=%s status=%s reason=%s\n' "$rc" "$STATUS" "$STATUS_REASON"
""",
    )
    assert "status=failed reason=drumsep_state_commit_failed" in run.stdout
    state = (tmp_path / "runtime" / "state" / "drumsep_runtime_rocm.env").read_text(
        encoding="utf-8"
    )
    assert "DRUMSEP_ROCM_INSTALL_TXN=begin" in state
    assert "STATUS=ok" not in state


def test_cpu_policy_is_symmetric_for_absent_present_and_create(tmp_path: Path) -> None:
    script = _script()
    policy = _function(script, "apply_drumsep_sibling_policy")
    assert '${1:-cpu}' in policy and 'rocm)' in policy
    assert "drumsep_sibling_missing" in policy
    assert "drumsep_sibling_rebuild_required" in policy
    assert "create_absent" in policy
    assert "rebuild_explicit" in policy

    runtime = tmp_path / "runtime"
    state = runtime / "state"
    state.mkdir(parents=True)
    absent_repair = _run_policy_harness(
        tmp_path / "absent-repair",
        """
mkdir -p "${RUNTIME_BASE}/state"
MODE=repair
apply_drumsep_sibling_policy cpu
printf 'reason=%s state=%s\n' "$STATUS_REASON" "$DRUMSEP_SIBLING_STATE"
""",
    )
    assert "reason=drumsep_sibling_missing state=absent_untouched" in absent_repair.stdout

    explicit_root = tmp_path / "explicit-cpu"
    explicit = _run_policy_harness(
        explicit_root,
        """
mkdir -p "${RUNTIME_BASE}/state"
MODE=drumsep-runtime
install_drumsep_runtime() { transaction_body() { log SIBLING_MUTATION; }; run_drumsep_install_transaction cpu "$DRUMSEP_MUTATION_REASON" transaction_body; }
apply_drumsep_sibling_policy cpu
cat "$(drumsep_state_file)"
""",
    )
    assert explicit.returncode == 0
    assert "DRUMSEP_CPU_INSTALL_TXN=commit" in explicit.stdout
    assert "DRUMSEP_CPU_MUTATION_REASON=create_absent" in explicit.stdout


def test_explicit_rebuild_requires_present_consistent_state(tmp_path: Path) -> None:
    runtime = tmp_path / "runtime"
    state = runtime / "state"
    sibling = runtime / ".venv-drumsep-rocm"
    state.mkdir(parents=True)
    sibling.mkdir()
    marker = sibling / "unchanged-before-action"
    marker.write_text("same\n", encoding="utf-8")
    (state / "drumsep_runtime_rocm.env").write_text(
        "STATUS=ok\nDRUMSEP_ROCM_RUNTIME_STATUS=ok\n", encoding="utf-8"
    )
    run = _run_policy_harness(
        tmp_path,
        """
MODE=drumsep-rocm-runtime
apply_drumsep_sibling_policy rocm
printf 'reason=%s\n' "$DRUMSEP_MUTATION_REASON"
""",
    )
    assert run.returncode == 0
    assert "reason=rebuild_explicit" in run.stdout
    assert "INSTALL_ROCM_CALLED" in (tmp_path / "policy.log").read_text(encoding="utf-8")
    assert marker.read_text(encoding="utf-8") == "same\n"


def test_presence_contract_uses_one_non_recursive_directory_check() -> None:
    inspect = _function(_script(), "inspect_drumsep_sibling")
    assert inspect.count('[ -d "${_inspect_dir}" ]') == 1
    for forbidden in ("find ", "rglob", '[ -x ', '"${_inspect_dir}"/', "pip ", "python "):
        assert forbidden not in inspect


def test_verify_only_and_ready_state_treat_open_transaction_as_incomplete() -> None:
    script = _script()
    loader = _function(script, "load_ready_runtime_state")
    ready_writer = _function(script, "write_ready_to_go_state")
    verify_only = _function(script, "run_ready_to_go_verify_only")
    assert "INSTALL_TXN" in loader
    assert "INSTALL_TXN" in ready_writer
    assert "incomplete" in ready_writer
    assert "verify_existing_ready_runtime" in verify_only


def test_open_transaction_cannot_emit_ready_to_go_ok(tmp_path: Path) -> None:
    script = _script()
    functions = "\n\n".join(
        _function(script, name)
        for name in (
            "atomic_write_state_file",
            "drumsep_state_file",
            "drumsep_rocm_state_file",
            "load_ready_runtime_state",
            "write_ready_to_go_state",
        )
    )
    runtime = tmp_path / "runtime"
    state_dir = runtime / "state"
    state_dir.mkdir(parents=True)
    (state_dir / "drumsep_runtime_rocm.env").write_text(
        "DRUMSEP_ROCM_INSTALL_TXN=begin\n"
        "STATUS=ok\n"
        "DRUMSEP_ROCM_RUNTIME_STATUS=ok\n"
        "DRUMSEP_ROCM_MODEL_STATUS=ok\n",
        encoding="utf-8",
    )
    harness = tmp_path / "ready-open-txn.sh"
    harness.write_text(
        "#!/bin/sh\nset -u\n"
        f'RUNTIME_BASE="{runtime}"\nLOG_FILE="{tmp_path / "ready.log"}"\n'
        "CORE_MODEL_PREFETCH_STATUS=ok\nCORE_MODEL_PREFETCH_DETAIL=\n"
        "log() { :; }\nlog_step() { :; }\n"
        f"{functions}\n"
        f'ready_to_go_output_file() {{ printf "%s\\n" "{state_dir / "ready_to_go.env"}"; }}\n'
        "verify_core_model_cache() { printf 'model_dir=/fixture\\nfast=ok\\nquality=ok\\nsixstem=ok\\n'; }\n"
        "load_ready_runtime_state rocm\n"
        'write_ready_to_go_state "$READY_RUNTIME_KIND" "$READY_RUNTIME_STATUS" "$READY_DRUMSEP_MODEL_STATUS" "$READY_DETAIL" ok\n'
        f'cat "{state_dir / "ready_to_go.env"}"\n',
        encoding="utf-8",
    )
    run = subprocess.run(["/bin/sh", str(harness)], text=True, capture_output=True, timeout=20)
    assert run.returncode == 0
    assert "READY_TO_GO_STATUS=ok" not in run.stdout
    assert "DRUMSEP_READY_RUNTIME_STATUS=incomplete" in run.stdout
    assert "READY_TO_GO_DETAIL=drumsep_install_in_progress" in run.stdout


def test_transactional_status_has_one_commitpoint_and_no_open_txn_ok_path() -> None:
    script = _script()
    runner = _function(script, "run_drumsep_install_transaction")
    commit = _function(script, "commit_drumsep_install_txn")
    begin = _function(script, "begin_drumsep_install_txn")
    assert runner.count("commit_drumsep_install_txn") == 1
    assert "STATUS=incomplete" in begin
    assert "STATUS=ok" not in begin
    assert "INSTALL_TXN=commit" in commit
    assert script.count("commit_drumsep_install_txn() {") == 1
    writer = _function(script, "write_state")
    assert "DRUMSEP_ROCM_INSTALL_TXN=begin" in writer
    assert "DRUMSEP_CPU_INSTALL_TXN=begin" in writer
    assert '| atomic_write_state_file "${STATE_FILE}"' in writer


def test_normal_repair_no_longer_auto_installs_optional_siblings() -> None:
    script = _script()
    automatic = script[script.index('READY_RUNTIME_KIND="cpu"') :]
    assert "resolve_main_drumsep_runtime_policy" in automatic
    assert 'if ! install_drumsep_rocm_runtime; then' not in automatic
    assert 'if ! install_drumsep_runtime; then' not in automatic


def test_release_note_marks_intentional_repair_behavior_change() -> None:
    note = (ROOT / "docs/release/STEMwerk_2.4.0_RUNTIME_PAYLOAD_HANDOFF.md").read_text(
        encoding="utf-8"
    )
    assert "DRUMSEP_OPTIONAL_RUNTIME_REPAIR_POLICY=preserve_only" in note
