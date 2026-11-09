# Core installation preview (v1)

`stemwerk_core.installation_plan` explains whether existing components can
satisfy the optional **Drum Kit** module, and describes unresolved work. It
performs no installation. The only request is `module_id="drum_kit"`,
`operation="ensure_installed"`. Module IDs are outside the closed workflow,
model and capability catalogs.

Every result has `kind="stemwerk_installation_preview"`,
`schema_version="1.0.0"`, and:

```json
{"execution":{"classification":"informational_preview","executable":false}}
```

A usable, ownership-unknown runtime can be reusable for execution. This never
grants permission to overwrite, adopt, repair or remove it. All ownership
assessments in this slice remain `unknown`, including paths discovered under
managed directories and successful imports. Execution still requires the
existing production gates' revalidation.

## API and evidence boundary

```python
from stemwerk_core.installation_plan import (
    InstallationRequest, preview_installation, collect_installation_inventory,
)
from stemwerk_core.workflow_contracts import validate_catalogs

request = InstallationRequest(requested_device="cpu")
catalogs = validate_catalogs("scripts/reaper/vendor/stemwerk-core/src/stemwerk_core/catalog")
unknown = preview_installation(request, inventory=None, catalogs=catalogs)

# Explicit, potentially expensive host observation:
inventory = collect_installation_inventory(request)
preview = preview_installation(request, inventory=inventory, catalogs=catalogs)
```

`preview_installation(request, *, inventory, catalogs)` is pure. It never
reads the environment, discovers paths, loads catalog files, probes hardware,
imports ML packages, generates timestamps, accesses networks or writes files.
Callers pass parsed catalog entries, normally returned by the existing catalog
validator. A request mapping with the dataclass fields is also accepted.
Unknown request fields and unsupported requests fail.

Catalogs may alternatively be an envelope
`{"entries": catalogs, "context": {"source": "explicit", "path": "..."}}`.
This makes loader provenance explicit without discovery inside the planner.
The CLI supplies this envelope using readiness's existing catalog resolution
(explicit API path, environment, packaged resource); it does not introduce a
new source-precedence policy. Plain entry mappings have caller-supplied catalog
provenance. The envelope's context is descriptive, never provisioning authority.

`collect_installation_inventory` calls existing `assess_readiness` for Direct
Kit and default Kit Split. It accepts `catalog_dir`, `collectors` and
`model_asset_providers`, forwarding the existing readiness injection points.
It records `sys.platform`, machine architecture, catalog location/fingerprint
and readiness reports. It intentionally does no provisioning or repair.
Readiness probes use owned temporary directories, disable subprocess bytecode
writes and clean up afterward. Arbitrary third-party initialization may still
write caches/configuration or contact networks; collection makes no universal
side-effect guarantee. No inference is performed.

The returned in-process inventory retains collection provenance. Serializing
and reimporting it loses that provenance. Any ordinary mapping or JSON file is
**caller-supplied and locally unverified**, regardless of embedded claims about
collection, ownership, timestamps or production selectors. Nested ownership
and source labels are relabeled and selector-provenance claims are removed
from displayed evidence. Original input content still contributes to its
fingerprint. Imported observations support attributed informational assessments
only. Collection provenance also never confers mutation authority.

## Inventory v1

```json
{
  "kind": "stemwerk_installation_inventory",
  "schema_version": "1.0.0",
  "context": {"platform_system": "linux", "machine": "x86_64"},
  "reports": {
    "drum_kit_direct": {},
    "drum_kit_split": {}
  }
}
```

Replace the empty report placeholders with existing v1
`stemwerk_readiness_report` objects. Omit report keys for unknown workflows.
Each report carries its request, stage IDs, model/capability IDs, stage
`components.runtime`, `components.capability`, `components.model`, and shared
`components.ffmpeg`. Existing readiness `components.feasibility` failures are
preserved. Missing reports/components remain unknown; they are not installation
triggers. An empty inventory object is also an unknown snapshot.

The optional component field `presence` accepts `unknown`, `present`, `absent`
or `partial`. Explicit absence can describe a controlled observation when
readiness's unavailable result alone cannot establish physical absence.
A runtime selection failure can mean missing **or broken** runtimes, so it is
not automatically absence. Model `files_missing`/`model_assets_missing`
evidence establishes missing prerequisites; `files_present`/`files_verified`
distinguishes partial assets. Contradictory absence/PASS, roots, interpreters,
requested devices, GPU identities and per-file observations block reuse.
Corruption requires a separate repair decision, never silent replacement.

Paths are compared as explicit identities; the planner does not resolve
symlinks, case-fold paths using the host, or choose between conflicting roots.
Different runtime-root conventions remain separate evidence. Ambiguous or
contradictory snapshots require reconciliation rather than a precedence guess.
Bare PASS statements without component identity are insufficient for reuse.
Supplied report `request.model_ids` must match the expanded ordered model IDs;
malformed lists are input errors. Established runtime source families are part
of shared-runtime identity, including CPU execution through ROCm.

## Expanded requirements and output

Readiness's defaults and the existing catalogs expand to:

| Workflow stage | Runtime profile | Model |
| --- | --- | --- |
| Direct Kit: `drumsep_direct` | DrumSep | `drumsep_mdx23c` |
| Kit Split: `separate_normal_for_kit` | Normal Stems | `htdemucs` |
| Kit Split: `drumsep_kit` | DrumSep | `drumsep_mdx23c` |

FFmpeg is shared. The Split DrumSep stage consumes the first stage's `drums`
output. Requirements retain this dependency and catalog deliverable order.
Five component requirements are deduplicated, retaining all consumers and
observations. Conflicting evidence never produces a reusable merged component.
The selected runtime is reused as reported, including CPU execution through an
existing ROCm environment; no dedicated CPU runtime is proposed in that case.

The planner wraps supplied resolution evidence with readiness's existing probe
adapter and Core's existing in-memory stage resolver. It does not choose a
backend. Platform guards reject impossible combinations; catalog permission
alone does not establish platform installation support. Unknown platform or
architecture remains unknown. Model presence, preflight usability, integrity
and ownership remain separate. Demucs presence-only evidence retains
`integrity="unverified"`; it does not acquire fabricated hashes. Reuse requires
model-specific evidence: the Core-pinned YAML and checkpoint in DrumSep
`files_verified`, or the requested Demucs descriptor and observed weight files.
Unrelated or incomplete file lists cannot satisfy those requirements. These
checks compare supplied identities; they do not read or hash model files.

Component `usability` records its observed `preflight_pass`, `preflight_fail`, or
`unknown` result independently of module feasibility and ownership. Conflicting
component observations remain unknown. A module blocker can prevent reuse
without erasing a successful component observation.

The document contains:

- `request`, ordered `requirements.workflows`, explicit `context` and
  `catalog_context`, and evidence `provenance`.
- `components` with consumers, evidence snapshots, observed targets, source
  references, presence/usability/integrity/ownership and reuse assessments.
- `reusable_components`, `missing_prerequisites`, `blockers`, and field-specific
  `unknowns`. Unknown ownership/integrity need not prevent documented execution
  reuse, but never authorizes mutations.
- `actions` with stable IDs, intent, dependencies, targets and source references.
  These are descriptions, never shell commands. Each retains its own
  `prerequisites`, effective `blockers` and attributed `upstream_blockers`.
- SHA-256 `input_fingerprints` for request, inventory, catalog entries, catalog
  context and evidence origin. They identify inputs, not authenticity or trust.

`canonical_json` sorts object keys and preserves array order. Catalog entry
sets are normalized by ID; workflow stages, deliverables, candidate paths and
evidence arrays keep their semantic order. Given identical explicit inputs
(including evidence origin), output is identical. No generated time is added.
Action ordering uses a stable topological sort. Duplicate IDs, duplicate or
missing dependency references, and cycles are rejected. Invalid catalogs and
malformed inventories are errors, never acquisition triggers.

## CLI and exits

With the vendored Core source on `PYTHONPATH`:

```bash
export PYTHONPATH="$PWD/scripts/reaper/vendor/stemwerk-core/src"
python -m stemwerk_core.installation_plan --module drum_kit --device cpu --inventory inventory.json --pretty
python -m stemwerk_core.installation_plan --module drum_kit --device cpu --collect --pretty
python -m stemwerk_core.installation_plan --module drum_kit --device cpu --pretty
```

`--inventory` and `--collect` are mutually exclusive. The third invocation
reports unknown installed state and performs no live collection. JSON goes to
stdout; diagnostics go to stderr.

- **0:** a valid informational preview was generated, including blocked previews.
  It does **not** mean installed, ready or executable.
- **2:** invalid request/input/catalog or planning failure.

Existing readiness CLI exit meanings are unchanged.

## Provisioning gaps and maintenance

This slice has no provisioning recipes, package/version selection, download
sources, sizes, licenses, target allocation/overwrite policy, receipts or
ownership-adoption mechanism. It exposes Core's existing DrumSep filename and
SHA-256 pins with their source reference. Those integrity pins do not establish
an acquisition URL or permission to install.

Missing components can yield blocked `acquire_missing` intents, followed by
blocked verification and module reassessment. Missing target/source/recipe,
platform-installation, verification and ownership policies are explicit.
Verification keeps its own prerequisites **and** acquisition's blockers;
reassessment propagates them transitively. Existing conflicting or corrupt
components yield assessment/decision blockers instead of acquisition intents.
Unsupported platforms/devices, catalog/request mismatches and other established
failures also require assessment; only absence-related uncertainty can describe
an acquisition intent. Explicit presence contradicting missing evidence is
retained as a conflict instead of being converted to absence.
No action is executable, even when all existing components are reusable.

The current catalog validator and public resolver load filesystem paths. To
keep this slice pure and confined to its authorized files, it reuses Core's
private entry validators, closed-ID constants, readiness expansion/probe
helpers and in-memory stage resolver. The small catalog cross-reference
validation boundary must track the existing v1 validator until Core exposes a
public in-memory catalog API. Catalog parity and readiness/resolver contracts
are part of verification. No global loaders are patched at runtime.

## Verification

All installation-preview tests are marked `portable` and use controlled
snapshots or stubbed collectors. No hardware/model/runtime probes are needed.
The existing CI portable job explicitly includes
`tests/test_core_installation_plan.py`. Its exact selection is:

```bash
python -m pytest -q -m portable \
  tests/test_stemwerk_runtime_diagnostics_harness.py \
  tests/test_core_drumsep_runtime.py \
  tests/test_core_readiness.py \
  tests/test_core_readiness_hardening.py \
  tests/test_core_installation_plan.py \
  tests/test_core_catalog_sync.py \
  tests/test_dependency_constraints.py::test_audio_separator_process_consumes_shared_managed_ffmpeg_candidates
```

Also run the focused file, workflow/resolver contracts, catalog sync,
`tools/version_sync.py --check`, `tools/release_gate.py --check`, workflow YAML
validation, and whitespace checks. Inference smoke is outside this slice.
