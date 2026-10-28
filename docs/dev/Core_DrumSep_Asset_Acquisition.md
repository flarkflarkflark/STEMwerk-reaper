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

A transport failure is classified in one place, in this order. If the attempt
watchdog has fired, the failure is the transient "bounded deadline" outcome,
whatever exception type surfaced: the exception raised when the watchdog shuts
a socket down depends on the TLS library (`RemoteDisconnected` with OpenSSL
3.0.x, `BrokenPipeError` with OpenSSL 3.5.x, or an SSL EOF error), so the type
is never used to decide whether a deadline was reached. Otherwise a TLS failure
is terminal (`tls_failed`); a connection closed without any response
(`RemoteDisconnected`) is transient and retryable; any other malformed HTTP
(an invalid status line, an over-long line, other `http.client` protocol
errors) is terminal (`http_rejected`); and socket and timeout errors are
transient. The same deadline precedence applies to TLS errors while the body is
read. A `ValueError` raised by a TLS socket that the watchdog has just closed
(`ssl.SSLSocket.read` raises it when the watchdog's `shutdown` clears the TLS
object between `recv_into`'s check and the read) is classified as the deadline
outcome in both phases; without a fired watchdog a `ValueError` is never
reclassified and propagates unchanged. As the last rule, any other `Exception`
raised after the watchdog has fired (an `AttributeError` or `TypeError` from
`http.client` on a response or connection that was torn down underneath it, for
example) is also the deadline outcome, and its message names only the original
exception type ("... bounded deadline (after AttributeError)"), because the
original message may carry an unredacted URL. The original exception is not
used as the cause and its display is suppressed (`from None`); it remains
reachable as `__context__`, but no consumer in the codebase emits it. This
never applies to `BaseException`
(`KeyboardInterrupt`, `SystemExit`, `GeneratorExit` always propagate), and
without a fired watchdog such an exception propagates as the same object. A
transient failure is retried within the three-attempt budget and, once
the attempts are exhausted, ends as `source_unavailable` (or
`deadline_exceeded` when the retry wait would pass the asset budget). Tests
inject the exact exception at the status-line and body phases with a controlled
watchdog, so the rules are verified independently of the TLS library version.

DNS resolution runs in a daemon worker that receives only a hostname and port;
the acquisition thread stops waiting at the attempt deadline. A resolver call
that cannot be cancelled by the operating system may finish later, but it has
no destination or file handle and cannot write into cleaned paths. Resolved
addresses are passed to the connection so the HTTPS library does not perform a
second unbounded lookup.

TCP connection setup is bounded to 30 seconds or the remaining attempt time,
whichever is shorter. TLS negotiation, request transmission, response headers
and body reads share an attempt watchdog. At the deadline the watchdog first
sets its `reached` flag and then only shuts down the connection socket and the
response-owned socket (this matters when HTTP connection-close framing
transfers socket ownership to `HTTPResponse`). On Linux and macOS that
shutdown wakes a blocked read; on Windows it does not wake an idle wait (see
below). It never closes the response or the connection: the attempt thread does that once,
in its `finally`, on every path (success, failure and deadline). Closing from
the timer thread raced the woken reader inside `http.client` and could escape
as an `AttributeError`. The watchdog also takes no action once the attempt has
started closing, so its shutdown never overlaps the close performed in
`finish()`. `http.client`'s own internal closes on the attempt thread (on EOF
of the response, or the connection close inside `getresponse` that hands the
socket to the response) are not serialized with it; that leaves a narrow
window, which also existed before.

Wake-up by shutdown differs per operating system:

- Linux and macOS: the shutdown wakes a blocked read at the deadline. The
  `native_publication` jobs prove it on 5d57bf6 with a header stall whose
  socket timeout is far beyond the attempt deadline and a chunked body whose
  chunk-size line is trickled on a response-owned socket; only the watchdog
  can end either read in time.
- Windows: Winsock does not document that a shutdown wakes an idle `select()`,
  and CI run 40603074419 shows that it does not. A waiting read ends when data
  arrives (data after `shutdown(SD_RECEIVE)` resets the connection, as
  documented) or at its socket timeout, which is set from the remaining
  attempt time. In the status phase that timeout is set when the TLS handshake
  starts, so a stalled response ends at most about the handshake plus request
  time after the deadline. The header-stall test therefore expects the wait to
  end when the server's data arrives (bound 2 s on Windows), and the chunked
  test proves boundedness on Windows, not idle wake-up.

Every body read gets a socket timeout of 60 seconds or the remaining attempt
time, whichever is shorter, so an idle body read ends at the deadline on every
OS. The monotonic deadline is also checked after every socket-delivered chunk.
A response trickled inside a single read (for example a chunk-size line sent
one byte at a time) is ended at the deadline by the shutdown on Linux and
macOS; on Windows it ends at the next byte after the deadline (the reset) or
at the socket timeout, whichever comes first.

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

The destination must be absolute, have an existing parent free of symbolic
links and other reparse points, and be absent. It is created exclusively with user-only permissions. A second thread
or process targeting the same destination fails rather than sharing or
replacing it. An exclusively created private staging directory and partial
files hold incoming bytes. There is no resume support or persistent cache.

Every descriptor-level open (partial-file creation, transfer writes,
verification reads and the final copy) requests `O_BINARY` where the platform
defines it, so Windows does not translate line endings or treat `0x1A` as end
of file; it is a no-op on Linux and macOS. A regression test records the flags
of each open with a sentinel bit. The binary-mode test and the
acquisition-to-materializer test are part of the `native_publication` CI
selection, which runs on Linux, macOS and Windows; commits, environments and
scope are in the platform status of `Core_DrumSep_Asset_Materialization.md`.

Acquisition rejects every link on the destination path, with parity to the
materializer: symbolic links and, on Windows, all other reparse points
(junctions, cloud placeholders, deduplicated files). Detection is shared, not
copied: acquisition imports the materializer's `_is_link_or_reparse`, and a test
asserts both modules use the same function. The checks apply to the destination
parent and every ancestor (`destination_ineligible`, the code already used for a
symbolic link), to the destination itself when it exists as a link
(`destination_exists`, as for any existing object), and to owned paths before
cleanup or removal, where a link or reparse point is never removed or followed
(`path_substituted`, or reported in `cleanup_remaining`). Real-link tests use a
directory junction on Windows and a directory symlink elsewhere; mocked tests
inject Windows-style reparse attributes for the destination parent, an
ancestor and the owned path so that branch runs on Linux. The `fstat` of the
staged source in `_copy_to_final` is also covered by the reparse check but is
not exercised by a mocked test. The Windows junction branch runs natively in
the Windows `native_publication` job and on the Windows 11 host. The two
file-symlink substitution tests (partial file and staged source) skip with
"requires unprivileged symlink creation" when a file symlink cannot be created
without privilege, as on Windows without Developer Mode or administrator
rights. Acquisition has no publication step, so it has no equivalent of the
materializer's pre-publication parent re-check; ancestor swaps after validation
fall under the same cooperative ancestor-stability assumption.

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
