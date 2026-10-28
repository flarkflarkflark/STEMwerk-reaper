# Core DrumSep asset preparation (v1)

`stemwerk_core.asset_preparation` is the client-neutral composition layer for
preparing Core's two pinned DrumSep assets in an explicit new destination. It
delegates source integrity and network policy to `asset_acquisition` and
delegates source validation, copying, receipt creation and atomic publication
to `asset_materialization`.

Preparation does not install or select a runtime, activate a module, adopt an
existing installation, execute an installation preview or establish Drum Kit
workflow readiness. Installation previews remain informational with
`executable=false` and are not accepted as preparation input.

## API

Exactly one source mode is required.

Local source mode:

```python
from pathlib import Path
from stemwerk_core.asset_preparation import (
    PreparationRequest,
    prepare_drumsep_assets,
)
from stemwerk_core import model_assets

result = prepare_drumsep_assets(
    PreparationRequest(
        destination=Path("/absolute/new/drumsep-assets"),
        local_sources={
            model_assets.DIRECT_DKS_MODEL_FILENAME: Path("/local/model.ckpt"),
            model_assets.DIRECT_DKS_MODEL_YAML: Path("/local/model.yaml"),
        },
    )
)
```

Explicit acquisition mode:

```python
result = prepare_drumsep_assets(
    PreparationRequest(
        destination=Path("/absolute/new/drumsep-assets"),
        acquire=True,
    )
)
```

`local_sources` and `acquire=True` are mutually exclusive. Omitting both is
also invalid. Local failure never falls back to network acquisition.
Production callers cannot replace acquisition URLs, revisions, sizes, hashes
or transport policy. A preview document is not an accepted request field.

## CLI

Local source mode:

```bash
python -I -B -m stemwerk_core.asset_preparation \
  --destination /absolute/new/drumsep-assets \
  --checkpoint-source /absolute/local/model.ckpt \
  --config-source /absolute/local/model.yaml \
  --pretty
```

Explicit acquisition mode:

```bash
python -I -B -m stemwerk_core.asset_preparation \
  --destination /absolute/new/drumsep-assets \
  --acquire \
  --pretty
```

Exit `0` is returned only after the materializer reports verified publication
and temporary acquisition cleanup succeeds; the success document is printed as
one JSON document on stdout. A handled validation, acquisition, publication or
cleanup failure (`PreparationError`) prints a versioned JSON error document on
stderr instead and exits `2`; callers must read stderr for the error document.
An invalid source-mode combination (`--acquire` with a local source option, or
only one of the two local source options) is such a validation failure, not an
argparse error. Other argument errors are printed by argparse in its own format
and also exit `2`.

## Preflight and publication

The orchestrator first validates that exactly one mode was selected. It then
calls the materializer's shared publication preflight before any acquisition.
Preflight rejects unsupported platforms, invalid or existing destinations and
ineligible parents. Publication uses the materializer's native no-replace API:
Linux `renameat2(RENAME_NOREPLACE)`, macOS `renamex_np(RENAME_EXCL)`, or Windows
`MoveFileExW` without replacement/copy flags.

Preflight does not reserve the destination. The materializer independently
revalidates source identities, destination eligibility and parent identity,
then performs its normal collision-safe publication. Filesystem support for a
particular no-replace rename is established by the actual publication call;
successful API preflight does not promise successful publication on every
filesystem. Preparation, including the CLI with the real pinned DrumSep files,
has run on Linux, macOS and Windows hosts, and its native publication tests run
in CI on all three; commits, environments and scope are in the platform status
of `Core_DrumSep_Asset_Materialization.md`.

## Evidence and phases

Successful output has `phase="complete"` and keeps primitive evidence in
separate `acquisition` and `publication` objects. It records whether
acquisition was requested and completed, publication state, materialization
operation ID and receipt path. Overall success requires a materializer success
document for the requested destination with both operation and receipt
identity.

Errors report the failed `phase`: `validation`, `acquisition`, `publication`
or `cleanup`. Publication state is `not_started`, `not_published`, `published`
or `unknown`. A materializer's `published=None` remains `unknown`; the
orchestrator does not infer absence or retry the whole operation. Primitive
error evidence, acquisition success evidence, receipt location and cleanup
leftovers remain separate fields.

Interrupts retain their original exception type. The exception receives the
same phase, publication, operation, receipt and cleanup facts that a structured
preparation failure would carry.

## Temporary and local source lifecycle

Acquisition mode creates a private workspace under the operating system's
temporary directory and asks the acquisition primitive to create its source
set inside it. After confirmed publication, the orchestrator removes only the
recorded workspace, acquisition directory and files through the acquisition
primitive's identity-checked cleanup rules.

If acquisition fails, the primitive first cleans its owned paths and the
orchestrator attempts to remove its outer workspace. If publication fails or
its state is unknown, the acquired workspace is retained and reported for
diagnosis; a potentially published destination is never removed. If
post-publication temporary cleanup fails, the result is a cleanup-phase error
with `publication.state="published"`, operation and receipt identity, and the
remaining paths. No whole-operation retry is performed.

If acquisition returns malformed success evidence, the workspace is retained
and reported because the orchestrator cannot safely reconstruct a complete
owned-path set from that result. A cleanup error while handling an acquisition
failure does not replace the primary failure; the outer workspace is reported
as remaining.

Caller-supplied local source files are read only by the materializer and are
never cleanup targets. Preparation does not merge, overwrite, repair or adopt
an existing destination.

## Limits and licensing

Preparation inherits the acquisition transport bounds and the materializer's
cooperative ancestor stability, platform/filesystem and crash-durability
limits. It adds no transaction database, lease, rollback, download cache or
receipt authority. The materialization receipt remains bounded evidence of
that copy-and-publication operation; it is not installation readiness,
licensing evidence or authority for future mutation.

The unresolved source and model-weight licensing evidence documented in
`Core_DrumSep_Asset_Acquisition.md` is unchanged. Preparation does not alter or
authorize existing product distribution policy.
