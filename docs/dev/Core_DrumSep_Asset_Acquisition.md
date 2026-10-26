# Core DrumSep asset acquisition (v1)

`stemwerk_core.asset_acquisition` is a bounded source-acquisition primitive for
Core's two pinned DrumSep files. It downloads both files into a new, explicitly
supplied local directory and returns their paths only after exact-size and
SHA-256 verification.

Acquisition is separate from installation and publication. It does not choose
an active model root, invoke `asset_materialization`, execute an installation
preview, install packages, provision a runtime, load a model or run inference.
Installation previews remain informational with `executable=false`.

## API and CLI

```python
from pathlib import Path
from stemwerk_core.asset_acquisition import (
    AcquisitionRequest,
    acquire_drumsep_sources,
)

result = acquire_drumsep_sources(
    AcquisitionRequest(destination=Path("/absolute/new/source-set"))
)
```

Production callers supply only the new destination. URLs, revisions, exact
sizes and retry/redirect policy are internal trusted metadata. Filenames and
SHA-256 values are imported from
`model_assets.DIRECT_DKS_MODEL_EXPECTED_SHA256`; the acquisition module does
not define another integrity catalog and accepts no caller-supplied hashes.

The equivalent CLI is:

```bash
python -I -B -m stemwerk_core.asset_acquisition \
  --destination /absolute/new/source-set \
  --pretty
```

Exit `0` returns a complete verified mapping in JSON. Exit `2` returns a
versioned JSON error on stderr, including a stable code and any operation-owned
paths that could not be cleaned. Normal argparse errors also exit `2`.

The returned `sources` mapping may be passed explicitly into
`asset_materialization.MaterializationRequest`. Acquisition never calls the
materializer, and its result never claims that installation publication took
place.

## Trusted sources and transport sizes

The checkpoint source order is:

1. Sucial/MSST-WebUI revision
   `90b617b15bd0dc0b784f3d361faca1b51173fe44`:
   `https://huggingface.co/Sucial/MSST-WebUI/resolve/90b617b15bd0dc0b784f3d361faca1b51173fe44/All_Models/multi_stem_models/aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt`;
2. KitsuneX07/Music_Source_Sepetration_Models revision
   `8309883c6b3fecc360fff24c932dcc588f8c23c2`:
   `https://huggingface.co/KitsuneX07/Music_Source_Sepetration_Models/resolve/8309883c6b3fecc360fff24c932dcc588f8c23c2/multi_stem_models/aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt?download=true`.

The YAML has one source: TRvlvr/application_data revision
`adea29c9fdbd2fa115a208965d00a6f03cdfde96`:
`https://raw.githubusercontent.com/TRvlvr/application_data/adea29c9fdbd2fa115a208965d00a6f03cdfde96/mdx_model_data/mdx_c_configs/aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml`.

The exact transport sizes are recorded separately from Core's integrity pins:

| File | Exact bytes |
|---|---:|
| `aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt` | 437,652,699 |
| `aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml` | 2,417 |

`Content-Length` is checked when present, but headers, host metadata and ETags
never replace final byte counting and SHA-256 verification. The stream reader
reads through response completion and rejects truncation and trailing data.

## Network bounds

Only HTTPS is accepted with the standard Python trust store, certificate
validation and hostname verification. Initial URLs and redirects are parsed;
hosts are matched on complete DNS-label boundaries. Checkpoint redirects may
remain on `huggingface.co`, `*.huggingface.co`, `hf.co`, `*.hf.co`,
`xethub.hf.co` or `*.xethub.hf.co`. YAML requests remain on
`raw.githubusercontent.com`. URL credentials, non-HTTPS URLs, non-default
ports, unapproved hosts and more than five redirects fail without retry or
fallback.

Requests send only `Accept`, `Accept-Encoding: identity`, `Connection: close`
and a fixed User-Agent. Credentials, cookies and proxy authorization are never
accepted from callers or forwarded across redirects. Query strings and
fragments are removed from all recorded and rendered URLs. Transport errors
are re-raised without their raw exception chain so temporary signed redirect
values cannot enter API errors, CLI output or tracebacks.

Each asset has at most three attempts across all sources. The checkpoint uses
the primary twice for retryable failures and the fallback for the third
attempt. A primary HTTP 404 or 410 advances immediately to the fallback. The
single-source YAML may use all three attempts against its pinned URL.

Only connection/read failures and HTTP 408, 429, 500, 502, 503 and 504 are
retryable. Delays are one and four seconds. A numeric `Retry-After` may increase
the delay, capped at 30 seconds. Wrong size/hash, TLS failure, rejected
redirects, other HTTP statuses and local validation/write failures are
terminal and never select the fallback.

DNS resolution runs in a daemon worker that receives only a hostname and port;
the acquisition thread stops waiting at the attempt deadline. A resolver call
that cannot be cancelled by the operating system may finish later, but it has
no destination or file handle and cannot write into cleaned paths. Resolved
addresses are passed to the connection so the HTTPS library does not perform a
second unbounded lookup.

TCP connection setup is bounded to 30 seconds or the remaining attempt time,
whichever is shorter. TLS negotiation, request transmission, response headers
and body reads share an attempt watchdog. The watchdog shuts down both the
connection socket and the response-owned socket; this matters when HTTP
connection-close framing transfers socket ownership to `HTTPResponse`. An
individual blocked body read is additionally bounded to 60 seconds. The
monotonic deadline is checked after every socket-delivered chunk, so a
trickling response cannot extend the attempt.

The checkpoint has a 1,800-second attempt bound and 3,600-second total asset
budget. The YAML has a 120-second attempt bound and 300-second total asset
budget. DNS, redirects, TCP/TLS, request and response work, fallback attempts
and retry waits consume the enclosing asset budget. The two sequential asset
budgets total 3,900 seconds. These are network-operation bounds, not a strict
end-to-end wall-clock guarantee: local file writes, `fsync`, hash verification,
cleanup and operating-system scheduling are synchronous and are not forcibly
cancelled by the network watchdog.

For a non-chunked response, the client reads past the declared
`Content-Length` until the requested connection close, preventing a matching
prefix followed by extra wire bytes from passing. Chunked response bodies are
decoded by the standard HTTP parser and remain subject to the same exact body
size and SHA-256 checks.

## Filesystem and failure behavior

The destination must be absolute, have an existing symlink-free parent, and be
absent. It is created exclusively with user-only permissions. A second thread
or process targeting the same destination fails rather than sharing or
replacing it. An exclusively created private staging directory and partial
files hold incoming bytes. There is no resume support or persistent cache.

Every descriptor-level open (partial-file creation, transfer writes,
verification reads and the final copy) requests `O_BINARY` where the platform
defines it, so Windows does not translate line endings or treat `0x1A` as end
of file; it is a no-op on Linux and macOS. A regression test records the flags
of each open with a sentinel bit. The binary-mode test and the
acquisition-to-materializer test are part of the `native_publication` CI
selection, so the macOS and Windows jobs will exercise them; until those jobs
have run, the Windows behavior is not natively qualified.

Acquisition's destination check rejects symbolic links only. Windows junctions
and other reparse points on the destination path are rejected by the
materializer but not by acquisition, and no acquisition test covers them.

Both downloaded files are re-opened and verified from storage. Final files are
created with exclusive no-replace opens and verified again before their paths
are returned. An error after one successful transfer cannot return a partial
mapping.

On failure or interruption, cleanup operates only on recorded filesystem
identities created by this operation. Substituted paths and unrelated content
are not followed or recursively removed; unresolved paths are reported. This
establishes collision safety for a new, cooperatively stable destination. It
does not claim atomic visibility of the complete two-file set, protection
against hostile ancestor replacement, network-filesystem semantics, crash
recovery, `SIGKILL` recovery or power-loss durability. The existing
materializer retains its separate platform-native, no-replace publication
contract. Portable acquisition tests run without active roots and do not by
themselves qualify publication on a host platform or filesystem.

## Provenance and licensing limits

The original `jarredou/models` release is unavailable. The two checkpoint
mirrors currently expose matching bytes, but their metadata disagrees:
Sucial labels its repository CC-BY-NC-SA-4.0 while Kitsune labels its license
unknown. Neither record establishes an original-author grant for the
aufr33/jarredou weights. The TRvlvr repository and YAML contain no identified
license grant.

Public availability, successful HTTPS transfer and a SHA-256 match establish
availability and content identity only. They do not establish authorship,
commercial permission, model-weight licensing or redistribution permission.
This primitive does not alter existing installer/payload behavior, disable
existing distribution, authorize release activation or resolve those policy
questions.
