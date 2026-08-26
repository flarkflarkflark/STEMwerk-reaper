"""Regression tests for the 2.3.1.0 diagnostics/state-contract fixes A/B/C.

These cover three defects found during the 2.3.1.0 Windows AMD (DirectML)
installer smokes. All three are diagnostics/state-contract defects: none of
them changed which device was selected or what was produced, and these tests
deliberately assert nothing about model selection, routing or output
generation.

A -- Check-only must be non-mutating.
    performPostBootstrap(publish=false) still wrote the pythonPath and
    ffmpegPath ExtState values (two ungated setExt calls, plus a
    verifyRuntimePaths() call that defaulted to publishing), so running
    "Check only" rewrote runtime-path state it was only supposed to read.

B -- a successful DirectML run must not leave a CPU claim as final truth.
    audio-separator can log "No hardware acceleration could be configured,
    running in CPU mode" at construction and then be moved onto DirectML by
    STEMwerk afterwards. That line is an intermediate library state; the tests
    below pin the authoritative structured evidence that supersedes it, and
    equally pin that a genuine CPU route and a genuinely failed accelerator
    are still reported as CPU/fallback.

C -- Normal Stems emitted no runtime_selected/backend_runtime.
    Direct Kit and Kit Split already emit them, so support bundles reported
    those two fields as "unknown" for an otherwise fully-proven DirectML run.

The Lua half of fix A is asserted structurally (every persisting call inside
performPostBootstrap is inside an `if publish then` gate) rather than by
matching one literal line, so the invariant survives refactors of the
surrounding code. This mirrors the approach already used for the same
contract in tests/test_macos_verify_only_read_only_2306.py.
"""

from __future__ import annotations

import io
import re
import sys
from contextlib import redirect_stderr
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]
SETUP = ROOT / "scripts" / "reaper" / "_internal" / "STEMwerk_Setup_Internal.lua"
BOOTSTRAP_WIN = ROOT / "scripts" / "reaper" / "STEMwerk_Bootstrap_Windows.ps1"
WORKER = ROOT / "scripts" / "reaper" / "audio_separator_process.py"
CORE_SRC = ROOT / "scripts" / "reaper" / "vendor" / "stemwerk-core" / "src"

if str(CORE_SRC) not in sys.path:
    sys.path.insert(0, str(CORE_SRC))

from stemwerk_core.devices import runtime_kind_for_device  # noqa: E402
from stemwerk_core.separator import StemSeparator  # noqa: E402


# --------------------------------------------------------------------------
# A -- Check-only must not persist runtime state
# --------------------------------------------------------------------------


def _perform_post_bootstrap_body() -> str:
    source = SETUP.read_text(encoding="utf-8")
    start = source.index("local function performPostBootstrap(")
    end = source.index("\nsafePerformPostBootstrap = function(", start)
    return source[start:end]


def _publish_gated_regions(body: str) -> list[tuple[int, int]]:
    """Character ranges of the `if publish then ... end` blocks in `body`.

    The gates in this function are not nested inside one another, so tracking
    `if`/`end` depth from each gate's start is enough to find its close.
    """
    regions: list[tuple[int, int]] = []
    for match in re.finditer(r"\bif publish then\b", body):
        depth = 0
        for token in re.finditer(r"\b(if|for|while|function|do|end)\b", body[match.start():]):
            word = token.group(1)
            if word in ("if", "for", "while", "function"):
                depth += 1
            elif word == "end":
                depth -= 1
                if depth == 0:
                    regions.append((match.start(), match.start() + token.end()))
                    break
    return regions


@pytest.mark.parametrize(
    "call",
    ["setExt(", "updateBootstrapEnv(", "writeCapabilities(", "ensureDir("],
)
def test_check_only_persistence_calls_are_all_publish_gated(call):
    """No persisting call may run when performPostBootstrap has publish=false."""
    body = _perform_post_bootstrap_body()
    regions = _publish_gated_regions(body)
    assert regions, "expected at least one `if publish then` gate"

    ungated = [
        match.start()
        for match in re.finditer(re.escape(call), body)
        if not any(start <= match.start() < end for start, end in regions)
    ]
    assert ungated == [], (
        f"{call} is reachable with publish=false at offsets {ungated}; "
        "Check-only must not create, replace, normalize or clear this state"
    )


def test_check_only_does_not_publish_via_verify_runtime_paths():
    """The nested verify must inherit publish, not default to publishing."""
    body = _perform_post_bootstrap_body()
    assert "verifyRuntimePaths(state, publish)" in body
    assert "verifyRuntimePaths(state)" not in body


def test_verify_runtime_paths_still_gates_its_own_extstate_writes():
    """The pre-existing gate this fix relies on must stay intact."""
    source = SETUP.read_text(encoding="utf-8")
    probe = source[
        source.index("local function verifyRuntimePaths") : source.index(
            "local function performPostBootstrap"
        )
    ]
    assert "if publishExtState == nil then publishExtState = true end" in probe
    assert 'if publishExtState then setExt("pythonPath", resolved.pythonPath) end' in probe
    assert 'if publishExtState then setExt("ffmpegPath", resolved.ffmpegPath) end' in probe


def test_setup_publish_path_still_writes_runtime_paths():
    """publish=true (Setup/install) must keep publishing both paths."""
    body = _perform_post_bootstrap_body()
    gated = "".join(body[start:end] for start, end in _publish_gated_regions(body))
    assert 'setExt("pythonPath", state.PYTHON_PATH)' in gated
    assert 'setExt("pythonPath", state.VENV_PYTHON)' in gated
    assert 'setExt("ffmpegPath", state.FFMPEG_PATH)' in gated
    assert "writeCapabilities(" in gated
    assert "updateBootstrapEnv(stateFile, syncKv)" in gated
    # The state directory is created as part of publication, not verification.
    assert "ensureDir(runtime.runtimeState)" in gated


def test_capabilities_path_stays_readable_for_the_check_only_report():
    """Gating the mkdir must not hide the capabilities path from the report.

    capPath is still referenced outside the publish block (the final message
    shows it), so only the directory creation may move inside the gate.
    """
    body = _perform_post_bootstrap_body()
    regions = _publish_gated_regions(body)
    decl = body.index('local capPath = runtime.runtimeState .. PATH_SEP .. "capabilities.env"')
    assert not any(start <= decl < end for start, end in regions)
    assert 'finalMessage[#finalMessage + 1] = "Capabilities: " .. tostring(capPath)' in body


def test_check_only_does_not_claim_it_normalized_stored_state():
    """The status line must not describe a write that publish=false skipped."""
    body = _perform_post_bootstrap_body()
    assert "local normalizationNote = publish" in body
    assert "check-only, stored state left unchanged" in body


def test_windows_check_only_entry_point_requests_non_publishing_run():
    """The Windows Check-only tick must keep passing publish=false."""
    source = SETUP.read_text(encoding="utf-8")
    assert (
        "safePerformPostBootstrap(runtime, stateFile, logFile, true, state, "
        "WINDOWS_VERIFY.separatorScript, false)" in source
    )


# --------------------------------------------------------------------------
# B/C -- runtime classification and final runtime evidence
# --------------------------------------------------------------------------


@pytest.mark.parametrize(
    "device_id,expected",
    [
        ("cpu", "cpu"),
        ("CPU", "cpu"),
        ("mps", "mps"),
        ("directml", "directml"),
        ("directml:0", "directml"),
        ("directml:1", "directml"),
        ("privateuseone:0", "directml"),
        ("rocm", "rocm"),
        ("rocm:0", "rocm"),
        ("", "unknown"),
        (None, "unknown"),
        ("something-else", "unknown"),
    ],
)
def test_runtime_kind_classification(device_id, expected):
    assert runtime_kind_for_device(device_id) == expected


def test_cuda_namespace_resolves_to_cuda_or_rocm_only():
    """ROCm torch exposes AMD GPUs as cuda:N, so both answers are legitimate.

    The invariant is that a cuda-style id never degrades to unknown/cpu.
    """
    assert runtime_kind_for_device("cuda:0") in {"cuda", "rocm"}
    assert runtime_kind_for_device("cuda") in {"cuda", "rocm"}


class _FakeSeparator:
    def __init__(self, torch_device="cpu", providers=None):
        self.torch_device = torch_device
        if providers is not None:
            self.onnx_execution_provider = providers


def _evidence(**kwargs):
    base = dict(
        requested_device="auto",
        effective_device_id="directml:0",
        effective_device_name="Some GPU",
        separator=_FakeSeparator(),
        use_directml=True,
        directml_mode="native",
        directml_bound=True,
    )
    base.update(kwargs)
    return StemSeparator._build_runtime_evidence(**base)


def test_native_directml_reports_directml_not_cpu():
    evidence = _evidence(
        separator=_FakeSeparator("privateuseone:0", ["DmlExecutionProvider"]),
    )
    assert evidence["runtime_selected"] == "directml"
    assert evidence["backend_runtime"] == "directml"
    assert evidence["selected_device"] == "directml:0"
    assert evidence["selected_device_name"] == "Some GPU"
    assert evidence["directml_init_mode"] == "native"
    assert evidence["separator_onnx_provider"] == "DmlExecutionProvider"


def test_successful_legacy_directml_override_reports_directml_not_cpu():
    """The exact Normal Stems / Kit Split stage-1 case behind bug B."""
    evidence = _evidence(
        directml_mode="legacy",
        directml_bound=True,
        separator=_FakeSeparator("privateuseone:0", ["DmlExecutionProvider"]),
    )
    assert evidence["runtime_selected"] == "directml"
    assert evidence["backend_runtime"] == "directml"
    assert evidence["directml_init_mode"] == "legacy"
    # Marks that audio-separator's earlier CPU line is superseded.
    assert evidence["accelerator_status_supersedes_library_log"] == "1"


def test_genuine_cpu_route_is_still_reported_as_cpu():
    evidence = _evidence(
        effective_device_id="cpu",
        effective_device_name="CPU",
        use_directml=False,
        directml_mode="",
        directml_bound=False,
        separator=_FakeSeparator("cpu"),
    )
    assert evidence["runtime_selected"] == "cpu"
    assert evidence["backend_runtime"] == "cpu"
    assert "accelerator_status_supersedes_library_log" not in evidence


def test_mps_route_is_reported_as_mps():
    evidence = _evidence(
        effective_device_id="mps",
        effective_device_name="Apple MPS",
        use_directml=False,
        directml_mode="",
        directml_bound=False,
        separator=_FakeSeparator("mps"),
    )
    assert evidence["runtime_selected"] == "mps"
    assert evidence["backend_runtime"] == "mps"


def test_unresolved_device_stays_unknown_and_is_not_guessed():
    evidence = _evidence(
        effective_device_id="",
        effective_device_name="",
        use_directml=False,
        directml_mode="",
        directml_bound=False,
        separator=_FakeSeparator(""),
    )
    assert evidence["runtime_selected"] == "unknown"
    assert evidence["backend_runtime"] == "unknown"
    assert evidence["selected_device"] == "unknown"


def _executable_source(path: Path) -> str:
    """Source with comments and docstrings removed.

    Prose may legitimately name a vendor while explaining detection (e.g. that
    ROCm exposes AMD GPUs through cuda:N ids); what must not happen is a vendor
    or adapter name appearing in executable logic.
    """
    import io as _io
    import tokenize

    kept: list[str] = []
    previous_type = tokenize.INDENT
    with open(path, "rb") as handle:
        for token in tokenize.tokenize(handle.readline):
            if token.type == tokenize.COMMENT:
                continue
            if token.type == tokenize.STRING and previous_type in (
                tokenize.INDENT,
                tokenize.DEDENT,
                tokenize.NEWLINE,
                tokenize.NL,
                tokenize.ENCODING,
            ):
                # Bare string expression == docstring.
                continue
            kept.append(token.string)
            if token.type not in (tokenize.NL, tokenize.COMMENT):
                previous_type = token.type
    return "\n".join(kept)


def test_evidence_never_hardcodes_a_vendor_or_adapter():
    """Adapter identity must come from detection, never from a literal."""
    evidence = _evidence(effective_device_name="Totally Fictional Adapter 123")
    assert evidence["selected_device_name"] == "Totally Fictional Adapter 123"
    for module in ("separator.py", "devices.py"):
        logic = _executable_source(CORE_SRC / "stemwerk_core" / module)
        for banned in ("RX 9070", "Radeon", "AMD", "NVIDIA", "GeForce"):
            assert banned not in logic, f"{module} hardcodes vendor/adapter '{banned}'"


def test_failed_legacy_directml_binding_falls_back_truthfully(monkeypatch):
    """A legacy override that fails leaves the run on CPU -- say so.

    Without this the run would keep claiming DirectML while audio-separator
    was still on the CPU device it configured at construction, which is the
    false-positive mirror image of bug B.
    """
    separator = _FakeSeparator("cpu")
    monkeypatch.setattr(
        StemSeparator, "_directml_mode", staticmethod(lambda sep: "legacy")
    )
    evidence = StemSeparator._build_runtime_evidence(
        requested_device="auto",
        effective_device_id="cpu",
        effective_device_name="CPU",
        separator=separator,
        use_directml=True,
        directml_mode="legacy",
        directml_bound=False,
    )
    assert evidence["runtime_selected"] == "cpu"
    assert evidence["backend_runtime"] == "cpu"
    assert "accelerator_status_supersedes_library_log" not in evidence


def test_separate_downgrades_to_cpu_when_legacy_binding_fails():
    """The downgrade decision itself must live in separate(), not only here."""
    source = (CORE_SRC / "stemwerk_core" / "separator.py").read_text(encoding="utf-8")
    assert 'if use_directml and not directml_bound and directml_mode != "native":' in source
    assert 'effective_device_id = "cpu"' in source


# --------------------------------------------------------------------------
# B -- legacy DirectML construction-time context marker
# --------------------------------------------------------------------------

# The exact third-party line the marker contextualizes. Reproduced here only
# as a test fixture so ordering can be asserted; STEMwerk itself must never
# reference or filter it (see test_cpu_mode_library_message_is_never_suppressed).
_LIBRARY_CPU_LINE = "No hardware acceleration could be configured, running in CPU mode"

_PENDING_MARKER = "directml_init_mode=legacy_pending_override"


def _run_get_separator(monkeypatch, *, supports_flag: bool, device: str, use_directml: bool):
    """Drive the real _get_separator against a stubbed audio-separator build.

    The stub logs the library's genuine construction-time CPU line so marker
    ordering can be asserted against it.
    """
    import types

    import stemwerk_core.separator as sep_mod

    if supports_flag:
        class _Separator:  # noqa: D401 - stub
            def __init__(self, output_dir=".", output_format="WAV", normalization_threshold=0.9,
                         log_level=10, mdx_params=None, model_file_dir=None, use_soundfile=None,
                         use_directml=False, demucs_params=None):
                print(_LIBRARY_CPU_LINE, file=sys.stderr, flush=True)
    else:
        class _Separator:  # noqa: D401 - stub (pre-use_directml build)
            def __init__(self, output_dir=".", output_format="WAV", normalization_threshold=0.9,
                         log_level=10, mdx_params=None, model_file_dir=None, use_soundfile=None,
                         demucs_params=None):
                print(_LIBRARY_CPU_LINE, file=sys.stderr, flush=True)

    pkg = types.ModuleType("audio_separator")
    sub = types.ModuleType("audio_separator.separator")
    sub.Separator = _Separator
    pkg.separator = sub
    monkeypatch.setitem(sys.modules, "audio_separator", pkg)
    monkeypatch.setitem(sys.modules, "audio_separator.separator", sub)

    monkeypatch.setattr(sep_mod, "_has_torch_directml", lambda: True)
    monkeypatch.setattr(sep_mod, "_has_onnxruntime_directml_provider", lambda: True)
    monkeypatch.setattr(sep_mod, "_processing_downloads_disabled", lambda: False)
    sep_mod._SEPARATOR_CACHE.clear()

    instance = StemSeparator(model="htdemucs", device="auto")
    buffer = io.StringIO()
    with redirect_stderr(buffer):
        separator, created, resolved_device, resolved_flag = instance._get_separator(
            "htdemucs", device, use_directml
        )
    sep_mod._SEPARATOR_CACHE.clear()
    return buffer.getvalue(), separator, resolved_device, resolved_flag


def test_legacy_directml_emits_pending_marker_immediately_after_construction(monkeypatch):
    emitted, separator, _device, flag = _run_get_separator(
        monkeypatch, supports_flag=False, device="privateuseone:0", use_directml=True
    )
    assert flag is True
    assert StemSeparator._directml_mode(separator) == "legacy"

    lines = [line for line in emitted.splitlines() if line.strip()]
    cpu_idx = next(i for i, l in enumerate(lines) if _LIBRARY_CPU_LINE in l)
    marker_idx = next(i for i, l in enumerate(lines) if _PENDING_MARKER in l)
    # Immediately after: nothing is allowed to separate the false claim from
    # its correction, which is the whole point of the fix.
    assert marker_idx == cpu_idx + 1
    # The library line itself is still present, verbatim and unmodified.
    assert _LIBRARY_CPU_LINE in emitted


def test_pending_marker_states_an_attempt_not_an_outcome(monkeypatch):
    emitted, _sep, _device, _flag = _run_get_separator(
        monkeypatch, supports_flag=False, device="privateuseone:0", use_directml=True
    )
    lowered = emitted.lower()
    assert "preliminary" in lowered
    assert "will now attempt" in lowered
    assert "authoritative" in lowered
    # Must not claim success before binding has happened.
    for forbidden in (
        "directml active",
        "gpu active",
        "acceleration active",
        "directml succeeded",
        "running on directml",
        "using directml",
    ):
        assert forbidden not in lowered, f"marker prematurely claims success: {forbidden!r}"


def test_no_pending_marker_for_genuine_cpu_route(monkeypatch):
    emitted, separator, _device, flag = _run_get_separator(
        monkeypatch, supports_flag=False, device="cpu", use_directml=False
    )
    assert flag is False
    assert StemSeparator._directml_mode(separator) == ""
    assert _PENDING_MARKER not in emitted
    # A genuine CPU route keeps the library's own CPU status fully visible.
    assert _LIBRARY_CPU_LINE in emitted


def test_no_pending_marker_for_native_directml(monkeypatch):
    emitted, separator, _device, flag = _run_get_separator(
        monkeypatch, supports_flag=True, device="privateuseone:0", use_directml=True
    )
    assert flag is True
    assert StemSeparator._directml_mode(separator) == "native"
    assert _PENDING_MARKER not in emitted


def test_marker_is_additive_only_and_filters_nothing(monkeypatch):
    """Every stub-emitted library line must survive verbatim."""
    emitted, _sep, _device, _flag = _run_get_separator(
        monkeypatch, supports_flag=False, device="privateuseone:0", use_directml=True
    )
    assert emitted.count(_LIBRARY_CPU_LINE) == 1


# --------------------------------------------------------------------------
# C -- Normal Stems emission wiring
# --------------------------------------------------------------------------


def _load_worker_symbol(name):
    """Import one symbol from the worker without importing its heavy deps."""
    import importlib.util

    spec = importlib.util.spec_from_file_location("_stemwerk_worker_probe", WORKER)
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as exc:  # pragma: no cover - depends on optional deps
        pytest.skip(f"worker module not importable in this environment: {exc}")
    return getattr(module, name)


def test_normal_stems_emits_runtime_fields_for_directml():
    emit = _load_worker_symbol("_emit_normal_runtime_evidence")

    class _Sep:
        runtime_evidence = {
            "runtime_selected": "directml",
            "backend_runtime": "directml",
            "selected_device": "directml:0",
            "selected_device_name": "Some GPU",
        }

    buffer = io.StringIO()
    with redirect_stderr(buffer):
        emit(_Sep())
    emitted = buffer.getvalue()

    assert "runtime_selected=directml" in emitted
    assert "backend_runtime=directml" in emitted
    assert "selected_device=directml:0" in emitted
    assert "selected_device_name=Some GPU" in emitted
    # device_name is the key the support bundle already consumes.
    assert "device_name=Some GPU" in emitted


def test_normal_stems_emits_cpu_fields_for_cpu_runs():
    emit = _load_worker_symbol("_emit_normal_runtime_evidence")

    class _Sep:
        runtime_evidence = {
            "runtime_selected": "cpu",
            "backend_runtime": "cpu",
            "selected_device": "cpu",
            "selected_device_name": "CPU",
        }

    buffer = io.StringIO()
    with redirect_stderr(buffer):
        emit(_Sep())
    emitted = buffer.getvalue()

    assert "runtime_selected=cpu" in emitted
    assert "backend_runtime=cpu" in emitted


def test_normal_stems_reports_not_proven_instead_of_guessing():
    emit = _load_worker_symbol("_emit_normal_runtime_evidence")

    class _Sep:
        runtime_evidence: dict = {}

    buffer = io.StringIO()
    with redirect_stderr(buffer):
        emit(_Sep())
    emitted = buffer.getvalue()

    assert "not_proven" in emitted
    assert "runtime_selected=" not in emitted
    assert "backend_runtime=" not in emitted


def test_normal_stems_evidence_is_emitted_even_if_separation_fails():
    source = WORKER.read_text(encoding="utf-8")
    assert "finally:" in source
    assert "_emit_normal_runtime_evidence(sep)" in source


def test_support_bundle_consumes_the_emitted_keys():
    """The bundle parser must already map these keys onto its run entries."""
    bundle = (
        ROOT / "scripts" / "reaper" / "STEMwerk_Save_Support_Bundle.lua"
    ).read_text(encoding="utf-8")
    assert 'elseif key == "backend_runtime" then' in bundle
    assert 'key == "drumsep_runtime_selected" or key == "runtime_selected"' in bundle
    assert 'elseif key == "device_name" or key == "gpu_name" then' in bundle


def test_cpu_fallback_summary_still_keys_off_these_fields():
    """Emitting truthful cpu values must keep CPU-fallback reporting working."""
    bundle = (
        ROOT / "scripts" / "reaper" / "STEMwerk_Save_Support_Bundle.lua"
    ).read_text(encoding="utf-8")
    assert (
        'and (runtimeSelected == "cpu" or backendRuntime == "cpu" '
        'or effectiveDevice == "cpu") then' in bundle
    )


# --------------------------------------------------------------------------
# B -- DrumSep DirectML bootstrap verification probe
# --------------------------------------------------------------------------


def test_drumsep_verify_configures_directml_at_construction_when_supported():
    source = BOOTSTRAP_WIN.read_text(encoding="utf-8")
    assert '"use_directml" in inspect.signature(Separator.__init__).parameters' in source
    assert 'sep_kwargs["use_directml"] = True' in source
    assert "import inspect" in source
    assert "DRUMSEP_DIRECTML_VERIFY directml_init_mode=" in source


def test_drumsep_verify_keeps_its_authoritative_final_evidence_line():
    source = BOOTSTRAP_WIN.read_text(encoding="utf-8")
    assert (
        'print("DRUMSEP_DIRECTML_VERIFY ok device=" + str(device) '
        '+ " provider=DmlExecutionProvider")' in source
    )


# --------------------------------------------------------------------------
# Safety rule: the CPU-mode message must remain diagnosable
# --------------------------------------------------------------------------


def test_cpu_mode_library_message_is_never_suppressed_or_stripped():
    """A genuine CPU route / accelerator failure must stay visible.

    The fix works by adding authoritative structured evidence, never by
    filtering third-party log text -- so STEMwerk must not contain any
    suppression of that message anywhere.
    """
    for path in (WORKER, SETUP, BOOTSTRAP_WIN, CORE_SRC / "stemwerk_core" / "separator.py"):
        text = path.read_text(encoding="utf-8")
        assert "No hardware acceleration" not in text, (
            f"{path.name} references the library CPU-mode line; suppressing or "
            "special-casing that text would hide genuine CPU/accelerator failures"
        )


def test_third_party_audio_separator_package_is_not_patched():
    """The fix must live in STEMwerk's integration layer only."""
    vendor_root = ROOT / "scripts" / "reaper" / "vendor"
    assert not list(vendor_root.glob("**/audio_separator/**/*.py")), (
        "audio-separator must not be vendored/forked into the repo"
    )
