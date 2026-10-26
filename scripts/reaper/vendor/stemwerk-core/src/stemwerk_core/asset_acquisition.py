"""Bounded HTTPS acquisition of Core-pinned DrumSep source assets.

This module acquires verified local source files into a new, explicit
destination.  It does not select an installation root, materialize assets,
execute installation previews, or alter existing processing/bootstrap policy.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import http.client
import json
import os
from pathlib import Path
import socket
import ssl
import stat
import sys
import threading
import time
from typing import Any, Callable, Sequence
from urllib.parse import SplitResult, urljoin, urlsplit
import uuid

from . import model_assets


SCHEMA_VERSION = "1.0.0"
PRODUCTION_POLICY_ID = "stemwerk_core.drumsep_acquisition.v1"
CHECKPOINT_SIZE = 437_652_699
CONFIG_SIZE = 2_417
MAX_ATTEMPTS = 3
MAX_REDIRECTS = 5
CONNECT_TIMEOUT_SECONDS = 30.0
READ_TIMEOUT_SECONDS = 60.0
CHECKPOINT_ATTEMPT_TIMEOUT_SECONDS = 1_800.0
CHECKPOINT_TOTAL_TIMEOUT_SECONDS = 3_600.0
CONFIG_ATTEMPT_TIMEOUT_SECONDS = 120.0
CONFIG_TOTAL_TIMEOUT_SECONDS = 300.0
RETRY_DELAYS_SECONDS = (1.0, 4.0)
TRANSIENT_HTTP_STATUSES = frozenset({408, 429, 500, 502, 503, 504})
UNAVAILABLE_HTTP_STATUSES = frozenset({404, 410})

SUCIAL_CHECKPOINT_URL = (
    "https://huggingface.co/Sucial/MSST-WebUI/resolve/"
    "90b617b15bd0dc0b784f3d361faca1b51173fe44/All_Models/"
    "multi_stem_models/"
    "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt"
)
KITSUNE_CHECKPOINT_URL = (
    "https://huggingface.co/KitsuneX07/"
    "Music_Source_Sepetration_Models/resolve/"
    "8309883c6b3fecc360fff24c932dcc588f8c23c2/multi_stem_models/"
    "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt"
    "?download=true"
)
TRVLVR_CONFIG_URL = (
    "https://raw.githubusercontent.com/TRvlvr/application_data/"
    "adea29c9fdbd2fa115a208965d00a6f03cdfde96/mdx_model_data/"
    "mdx_c_configs/"
    "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
)


class AcquisitionError(Exception):
    """A bounded validation, transport, integrity, write, or cleanup failure."""

    def __init__(
        self,
        code: str,
        message: str,
        *,
        cleanup_remaining: Sequence[str] = (),
        destination: str | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.cleanup_remaining = tuple(cleanup_remaining)
        self.destination = destination


class _AttemptFailure(Exception):
    """Retry/fallback-eligible failure from one source attempt."""

    def __init__(
        self, kind: str, message: str, *, retry_after: float | None = None
    ) -> None:
        if kind not in {"transient", "unavailable"}:
            raise ValueError("attempt failure kind must be transient or unavailable")
        super().__init__(message)
        self.kind = kind
        self.retry_after = retry_after


@dataclass(frozen=True)
class AcquisitionRequest:
    """A new explicit directory in which verified local sources are created."""

    destination: Path


@dataclass(frozen=True)
class _SourceSpec:
    source_id: str
    url: str
    redirect_hosts: tuple[str, ...]
    revision: str = ""

    def __post_init__(self) -> None:
        if not self.source_id or not self.url or not self.redirect_hosts:
            raise ValueError("source specification is incomplete")
        _validated_https_url(self.url, self.redirect_hosts)


@dataclass(frozen=True)
class _AssetSpec:
    name: str
    sha256: str
    size: int
    sources: tuple[_SourceSpec, ...]
    attempt_timeout: float
    total_timeout: float

    def __post_init__(self) -> None:
        if (
            not self.name
            or Path(self.name).name != self.name
            or self.name in {".", ".."}
        ):
            raise ValueError("asset name must be a single safe filename")
        if (
            len(self.sha256) != 64
            or any(char not in "0123456789abcdefABCDEF" for char in self.sha256)
        ):
            raise ValueError("asset SHA-256 is invalid")
        if self.size <= 0 or not self.sources:
            raise ValueError("asset size and sources must be provided")
        if self.attempt_timeout <= 0 or self.total_timeout <= 0:
            raise ValueError("asset timeouts must be positive")


@dataclass(frozen=True)
class _AcquisitionPolicy:
    policy_id: str
    assets: tuple[_AssetSpec, ...]

    def __post_init__(self) -> None:
        if not self.policy_id or not self.assets:
            raise ValueError("acquisition policy is incomplete")
        names = [asset.name for asset in self.assets]
        if len(names) != len(set(names)):
            raise ValueError("acquisition policy contains duplicate asset names")


@dataclass(frozen=True)
class _TransferEvidence:
    final_host: str
    size: int


@dataclass
class _OwnedPath:
    path: Path
    device: int
    inode: int
    is_directory: bool


def _production_policy() -> _AcquisitionPolicy:
    checkpoint_name = model_assets.DIRECT_DKS_MODEL_FILENAME
    config_name = model_assets.DIRECT_DKS_MODEL_YAML
    return _AcquisitionPolicy(
        policy_id=PRODUCTION_POLICY_ID,
        assets=(
            _AssetSpec(
                name=checkpoint_name,
                sha256=model_assets.DIRECT_DKS_MODEL_EXPECTED_SHA256[
                    checkpoint_name
                ],
                size=CHECKPOINT_SIZE,
                sources=(
                    _SourceSpec(
                        source_id="sucial-msst-webui-90b617b",
                        url=SUCIAL_CHECKPOINT_URL,
                        redirect_hosts=(
                            "huggingface.co",
                            "hf.co",
                            "xethub.hf.co",
                        ),
                        revision="90b617b15bd0dc0b784f3d361faca1b51173fe44",
                    ),
                    _SourceSpec(
                        source_id="kitsunex07-models-8309883",
                        url=KITSUNE_CHECKPOINT_URL,
                        redirect_hosts=(
                            "huggingface.co",
                            "hf.co",
                            "xethub.hf.co",
                        ),
                        revision="8309883c6b3fecc360fff24c932dcc588f8c23c2",
                    ),
                ),
                attempt_timeout=CHECKPOINT_ATTEMPT_TIMEOUT_SECONDS,
                total_timeout=CHECKPOINT_TOTAL_TIMEOUT_SECONDS,
            ),
            _AssetSpec(
                name=config_name,
                sha256=model_assets.DIRECT_DKS_MODEL_EXPECTED_SHA256[config_name],
                size=CONFIG_SIZE,
                sources=(
                    _SourceSpec(
                        source_id="trvlvr-application-data-adea29c",
                        url=TRVLVR_CONFIG_URL,
                        redirect_hosts=("raw.githubusercontent.com",),
                        revision="adea29c9fdbd2fa115a208965d00a6f03cdfde96",
                    ),
                ),
                attempt_timeout=CONFIG_ATTEMPT_TIMEOUT_SECONDS,
                total_timeout=CONFIG_TOTAL_TIMEOUT_SECONDS,
            ),
        ),
    )


def _hostname_allowed(hostname: str, allowed: Sequence[str]) -> bool:
    host = hostname.rstrip(".").lower()
    for entry in allowed:
        suffix = entry.rstrip(".").lower()
        if host == suffix or host.endswith("." + suffix):
            return True
    return False


def _validated_https_url(url: str, allowed_hosts: Sequence[str]) -> SplitResult:
    try:
        parsed = urlsplit(url)
        port = parsed.port
    except (TypeError, ValueError):
        raise AcquisitionError("redirect_rejected", "source URL is invalid") from None
    hostname = parsed.hostname
    if (
        parsed.scheme.lower() != "https"
        or not hostname
        or parsed.username is not None
        or parsed.password is not None
        or port not in {None, 443}
        or not _hostname_allowed(hostname, allowed_hosts)
    ):
        raise AcquisitionError(
            "redirect_rejected",
            f"HTTPS source host is not allowed: {_redacted_url(url)}",
        )
    return parsed


def _redacted_url(url: str) -> str:
    try:
        parsed = urlsplit(url)
    except (TypeError, ValueError):
        return "<invalid-url>"
    hostname = parsed.hostname or "<invalid-host>"
    try:
        port = parsed.port
    except ValueError:
        port = None
    authority = hostname if port in {None, 443} else f"{hostname}:{port}"
    path = parsed.path or "/"
    suffix = "?<redacted>" if parsed.query else ""
    return f"{parsed.scheme or '<invalid-scheme>'}://{authority}{path}{suffix}"


def _binary_flag() -> int:
    """Windows opens descriptors in text mode unless O_BINARY is requested."""

    return getattr(os, "O_BINARY", 0)


def _remaining(deadline: float, clock: Callable[[], float]) -> float:
    value = deadline - clock()
    if value <= 0:
        raise AcquisitionError(
            "deadline_exceeded", "asset acquisition exceeded its total deadline"
        )
    return value


def _attempt_remaining(deadline: float, clock: Callable[[], float]) -> float:
    value = deadline - clock()
    if value <= 0:
        raise _AttemptFailure(
            "transient", "source attempt exceeded its bounded deadline"
        )
    return value


def _retry_after_seconds(response: Any) -> float | None:
    value = response.getheader("Retry-After")
    if value is None:
        return None
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    if parsed < 0:
        return None
    return min(parsed, 30.0)


class _ResolvedHTTPSConnection(http.client.HTTPSConnection):
    """HTTPS connection that uses addresses from a separately bounded lookup."""

    def __init__(
        self,
        host,
        port,
        timeout,
        context,
        addresses,
        connect_deadline,
        attempt_deadline,
        clock,
    ):
        super().__init__(host=host, port=port, timeout=timeout, context=context)
        self._resolved_addresses = addresses
        self._connect_deadline = connect_deadline
        self._attempt_deadline = attempt_deadline
        self._clock = clock
        # HTTPConnection stores socket.create_connection on the instance. Replace
        # it so connect/TLS still use the original hostname while DNS is not
        # repeated outside our deadline.
        self._create_connection = self._connect_resolved

    def _connect_resolved(self, address, timeout, source_address):
        del address
        last_error = None
        for family, socket_type, protocol, _, socket_address in self._resolved_addresses:
            remaining = self._connect_deadline - self._clock()
            if remaining <= 0:
                raise socket.timeout("TCP connection exceeded its shared deadline")
            candidate = None
            try:
                candidate = socket.socket(family, socket_type, protocol)
                candidate.settimeout(min(timeout, remaining))
                if source_address:
                    candidate.bind(source_address)
                candidate.connect(socket_address)
                return candidate
            except OSError as exc:
                last_error = exc
                if candidate is not None:
                    candidate.close()
            except BaseException:
                if candidate is not None:
                    candidate.close()
                raise
        if last_error is not None:
            raise last_error
        raise OSError("DNS resolution returned no usable addresses")

    def connect(self) -> None:
        """Attach the SSL socket before a deadline-bounded handshake."""

        http.client.HTTPConnection.connect(self)
        server_hostname = self._tunnel_host or self.host
        remaining = _attempt_remaining(self._attempt_deadline, self._clock)
        wrapped = self._context.wrap_socket(
            self.sock,
            server_hostname=server_hostname,
            do_handshake_on_connect=False,
        )
        self.sock = wrapped
        self.sock.settimeout(remaining)
        self.sock.do_handshake()


def _bounded_resolve(host, port, deadline, clock, resolver):
    """Resolve in a daemon worker; the worker never receives a filesystem path."""

    completed = threading.Event()
    outcome = {}

    def resolve() -> None:
        try:
            outcome["addresses"] = resolver(
                host, port, type=socket.SOCK_STREAM
            )
        except BaseException as exc:  # retained only until the bounded caller reads it
            outcome["error"] = exc
        finally:
            completed.set()

    worker = threading.Thread(
        target=resolve,
        name="stemwerk-acquisition-dns",
        daemon=True,
    )
    worker.start()
    if not completed.wait(_attempt_remaining(deadline, clock)):
        raise _AttemptFailure(
            "transient", f"DNS resolution exceeded its deadline for {host}"
        )
    _attempt_remaining(deadline, clock)
    error = outcome.get("error")
    if error is not None:
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise error
        raise _AttemptFailure(
            "transient", f"DNS resolution failed for {host}: {type(error).__name__}"
        ) from None
    addresses = outcome.get("addresses")
    if not addresses:
        raise _AttemptFailure(
            "transient", f"DNS resolution returned no addresses for {host}"
        )
    return addresses


def _shutdown_socket(sock: Any) -> None:
    if sock is None:
        return
    try:
        sock.shutdown(socket.SHUT_RDWR)
    except Exception:
        pass


def _response_socket(response: Any) -> Any:
    fp = getattr(response, "fp", None)
    raw = getattr(fp, "raw", None)
    return getattr(raw, "_sock", None)


class _DeadlineWatchdog:
    """Close both connection-owned and response-owned sockets at a deadline."""

    def __init__(self, connection: Any, seconds: float, timer_factory) -> None:
        self.reached = threading.Event()
        self._connection = connection
        self._response = None
        self._lock = threading.Lock()
        self._timer = timer_factory(seconds, self._abort)
        if hasattr(self._timer, "daemon"):
            self._timer.daemon = True

    def start(self) -> None:
        self._timer.start()

    def attach_response(self, response: Any) -> None:
        with self._lock:
            self._response = response
            reached = self.reached.is_set()
        if reached:
            self._abort_response(response)

    @staticmethod
    def _abort_response(response: Any) -> None:
        _shutdown_socket(_response_socket(response))
        try:
            response.close()
        except Exception:
            pass

    def _abort(self) -> None:
        self.reached.set()
        with self._lock:
            response = self._response
        if response is not None:
            self._abort_response(response)
        _shutdown_socket(getattr(self._connection, "sock", None))
        try:
            self._connection.close()
        except Exception:
            pass

    def finish(self) -> None:
        self._timer.cancel()
        try:
            self._timer.join(timeout=0.1)
        except (AttributeError, RuntimeError):
            pass
        with self._lock:
            response = self._response
        if response is not None:
            try:
                response.close()
            except Exception:
                pass
        try:
            self._connection.close()
        except Exception:
            pass


class _HttpsTransport:
    """Small streaming HTTPS client with explicit redirect and deadline policy."""

    def __init__(
        self,
        *,
        connection_factory: Callable[..., Any] | None = None,
        clock: Callable[[], float] = time.monotonic,
        chunk_size: int = 1024 * 1024,
        ssl_context: ssl.SSLContext | None = None,
        timer_factory: Callable[..., Any] = threading.Timer,
        resolver: Callable[..., Any] = socket.getaddrinfo,
    ) -> None:
        self._connection_factory = connection_factory
        self._clock = clock
        self._chunk_size = chunk_size
        self._ssl_context = ssl_context or ssl.create_default_context()
        self._timer_factory = timer_factory
        self._resolver = resolver

    def _connection(self, parsed: SplitResult, timeout: float, deadline: float):
        if self._connection_factory is not None:
            return self._connection_factory(
                parsed.hostname,
                parsed.port or 443,
                timeout,
                self._ssl_context,
            )
        addresses = _bounded_resolve(
            parsed.hostname,
            parsed.port or 443,
            deadline,
            self._clock,
            self._resolver,
        )
        connect_deadline = min(
            deadline, self._clock() + CONNECT_TIMEOUT_SECONDS
        )
        connect_timeout = _attempt_remaining(connect_deadline, self._clock)
        return _ResolvedHTTPSConnection(
            parsed.hostname,
            parsed.port or 443,
            connect_timeout,
            self._ssl_context,
            addresses,
            connect_deadline,
            deadline,
            self._clock,
        )

    def download(
        self,
        source: _SourceSpec,
        asset: _AssetSpec,
        target: Path,
        *,
        deadline: float,
        target_identity: _OwnedPath | None = None,
    ) -> _TransferEvidence:
        if target_identity is None:
            try:
                target_identity = _owned(target)
            except OSError as exc:
                raise AcquisitionError(
                    "write_failed", f"cannot inspect owned partial target: {exc}"
                ) from exc
        current_url = source.url
        redirects = 0
        while True:
            parsed = _validated_https_url(current_url, source.redirect_hosts)
            remaining = _attempt_remaining(deadline, self._clock)
            timeout = min(CONNECT_TIMEOUT_SECONDS, remaining)
            connection = None
            response = None
            watchdog = None
            try:
                connection = self._connection(parsed, timeout, deadline)
                watchdog = _DeadlineWatchdog(
                    connection,
                    _attempt_remaining(deadline, self._clock),
                    self._timer_factory,
                )
                watchdog.start()
                target_path = parsed.path or "/"
                if parsed.query:
                    target_path += "?" + parsed.query
                headers = {
                    "Accept": "application/octet-stream, text/plain;q=0.9",
                    "Accept-Encoding": "identity",
                    "Connection": "close",
                    "User-Agent": "stemwerk-core-asset-acquisition/1",
                }
                connection.request("GET", target_path, headers=headers)
                response = connection.getresponse()
                watchdog.attach_response(response)
                if watchdog.reached.is_set():
                    raise _AttemptFailure(
                        "transient", "source attempt exceeded its bounded deadline"
                    )
                if response.status in {301, 302, 303, 307, 308}:
                    location = response.getheader("Location")
                    if not location:
                        raise AcquisitionError(
                            "redirect_rejected", "redirect response omitted Location"
                        )
                    redirects += 1
                    if redirects > MAX_REDIRECTS:
                        raise AcquisitionError(
                            "redirect_rejected",
                            f"redirect limit exceeded at {_redacted_url(current_url)}",
                        )
                    try:
                        candidate = urljoin(current_url, location)
                    except (TypeError, ValueError):
                        raise AcquisitionError(
                            "redirect_rejected", "redirect Location is invalid"
                        ) from None
                    _validated_https_url(candidate, source.redirect_hosts)
                    current_url = candidate
                    continue

                if response.status in TRANSIENT_HTTP_STATUSES:
                    raise _AttemptFailure(
                        "transient",
                        f"source returned transient HTTP {response.status} at "
                        f"{_redacted_url(current_url)}",
                        retry_after=_retry_after_seconds(response),
                    )
                if response.status in UNAVAILABLE_HTTP_STATUSES:
                    raise _AttemptFailure(
                        "unavailable",
                        f"source returned HTTP {response.status} at "
                        f"{_redacted_url(current_url)}",
                    )
                if response.status != 200:
                    raise AcquisitionError(
                        "http_rejected",
                        f"source returned non-retryable HTTP {response.status} at "
                        f"{_redacted_url(current_url)}",
                    )

                content_length = response.getheader("Content-Length")
                if content_length is not None:
                    try:
                        declared_size = int(content_length)
                    except (TypeError, ValueError):
                        raise AcquisitionError(
                            "content_length_mismatch",
                            "source returned an invalid Content-Length",
                        ) from None
                    if declared_size != asset.size:
                        raise AcquisitionError(
                            "content_length_mismatch",
                            f"source declared {declared_size} bytes; expected {asset.size}",
                        )
                if getattr(response, "chunked", False) and content_length is not None:
                    raise AcquisitionError(
                        "http_rejected",
                        "source returned conflicting chunked and Content-Length framing",
                    )
                # http.client otherwise stops exactly at Content-Length and hides
                # excess wire bytes. The request requires connection-close, so
                # reading the non-chunked stream to EOF proves there is no suffix.
                if content_length is not None and not getattr(response, "chunked", False):
                    response.length = None

                return self._stream_response(
                    response,
                    connection,
                    current_url,
                    asset,
                    target,
                    deadline,
                    target_identity,
                    watchdog.reached,
                )
            except (_AttemptFailure, AcquisitionError):
                raise
            except (ssl.CertificateError, ssl.SSLError):
                raise AcquisitionError(
                    "tls_failed",
                    f"TLS validation failed for {_redacted_url(current_url)}",
                ) from None
            except http.client.HTTPException:
                raise AcquisitionError(
                    "http_rejected",
                    f"source returned malformed HTTP at {_redacted_url(current_url)}",
                ) from None
            except (socket.timeout, TimeoutError, ConnectionError, OSError) as exc:
                if watchdog is not None and watchdog.reached.is_set():
                    raise _AttemptFailure(
                        "transient", "source attempt exceeded its bounded deadline"
                    ) from None
                raise _AttemptFailure(
                    "transient",
                    f"transport failed for {_redacted_url(current_url)}: "
                    f"{type(exc).__name__}",
                ) from None
            finally:
                if watchdog is not None:
                    watchdog.finish()
                elif connection is not None:
                    try:
                        connection.close()
                    except OSError:
                        pass

    def _stream_response(
        self,
        response: Any,
        connection: Any,
        current_url: str,
        asset: _AssetSpec,
        target: Path,
        deadline: float,
        target_identity: _OwnedPath,
        deadline_reached: threading.Event,
    ) -> _TransferEvidence:
        digest = hashlib.sha256()
        received = 0
        flags = (
            os.O_WRONLY
            | _binary_flag()
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0)
        )
        handle = None
        try:
            try:
                handle = os.open(target, flags)
            except OSError as exc:
                raise AcquisitionError(
                    "write_failed", f"cannot open owned partial target: {exc}"
                ) from exc
            current = os.fstat(handle)
            if (
                not stat.S_ISREG(current.st_mode)
                or current.st_dev != target_identity.device
                or current.st_ino != target_identity.inode
            ):
                raise AcquisitionError(
                    "write_failed", "owned partial target changed before transfer"
                )
            try:
                os.ftruncate(handle, 0)
            except OSError as exc:
                raise AcquisitionError(
                    "write_failed", f"cannot reset owned partial target: {exc}"
                ) from exc
            while True:
                remaining = _attempt_remaining(deadline, self._clock)
                active_socket = getattr(connection, "sock", None)
                if active_socket is None:
                    active_socket = _response_socket(response)
                if active_socket is not None:
                    active_socket.settimeout(min(READ_TIMEOUT_SECONDS, remaining))
                amount = min(self._chunk_size, asset.size - received + 1)
                try:
                    reader = getattr(response, "read1", response.read)
                    chunk = reader(max(1, amount))
                except (ssl.CertificateError, ssl.SSLError):
                    raise AcquisitionError(
                        "tls_failed",
                        f"TLS validation failed while reading {_redacted_url(current_url)}",
                    ) from None
                except (
                    http.client.IncompleteRead,
                    socket.timeout,
                    TimeoutError,
                    ConnectionError,
                    OSError,
                ) as exc:
                    if deadline_reached.is_set():
                        raise _AttemptFailure(
                            "transient",
                            "source attempt exceeded its bounded deadline",
                        ) from None
                    raise _AttemptFailure(
                        "transient",
                        f"response read failed at {_redacted_url(current_url)}: "
                        f"{type(exc).__name__}",
                    ) from None
                if deadline_reached.is_set():
                    raise _AttemptFailure(
                        "transient", "source attempt exceeded its bounded deadline"
                    )
                _attempt_remaining(deadline, self._clock)
                if not chunk:
                    break
                received += len(chunk)
                if received > asset.size:
                    raise AcquisitionError(
                        "transfer_excess",
                        f"source exceeded the {asset.size}-byte transport limit",
                    )
                digest.update(chunk)
                view = memoryview(chunk)
                while view:
                    try:
                        written = os.write(handle, view)
                    except OSError as exc:
                        raise AcquisitionError(
                            "write_failed", f"cannot write acquired bytes: {exc}"
                        ) from exc
                    if written <= 0:
                        raise AcquisitionError(
                            "write_failed", "acquisition write made no progress"
                        )
                    view = view[written:]
            if received != asset.size:
                raise AcquisitionError(
                    "transfer_truncated",
                    f"source ended after {received} bytes; expected {asset.size}",
                )
            actual = digest.hexdigest()
            if actual.lower() != asset.sha256.lower():
                raise AcquisitionError(
                    "source_integrity_mismatch",
                    f"acquired bytes for {asset.name} do not match Core's pin",
                )
            try:
                os.fsync(handle)
            except OSError as exc:
                raise AcquisitionError(
                    "write_failed", f"cannot synchronize acquired bytes: {exc}"
                ) from exc
        finally:
            if handle is not None:
                os.close(handle)
        parsed = urlsplit(current_url)
        return _TransferEvidence(final_host=parsed.hostname or "", size=received)


def _absolute_destination(value: Any) -> Path:
    if not isinstance(value, (str, os.PathLike)) or not str(value):
        raise AcquisitionError("invalid_path", "destination must be a path")
    try:
        path = Path(value)
    except (TypeError, ValueError, OSError) as exc:
        raise AcquisitionError("invalid_path", "destination is invalid") from exc
    if "\x00" in str(path) or not path.is_absolute() or ".." in path.parts:
        raise AcquisitionError(
            "invalid_path", "destination must be absolute and contain no '..' segment"
        )
    return path


def _reject_symlink_components(path: Path) -> None:
    for component in reversed([path, *path.parents]):
        try:
            mode = os.lstat(component).st_mode
        except FileNotFoundError:
            continue
        except OSError as exc:
            raise AcquisitionError(
                "destination_ineligible", f"cannot inspect destination path: {exc}"
            ) from exc
        if stat.S_ISLNK(mode):
            raise AcquisitionError(
                "destination_ineligible", "destination path contains a symbolic link"
            )


def _validate_request(request: AcquisitionRequest) -> Path:
    if not isinstance(request, AcquisitionRequest):
        raise AcquisitionError(
            "invalid_request", "request must be an AcquisitionRequest"
        )
    destination = _absolute_destination(request.destination)
    _reject_symlink_components(destination.parent)
    try:
        parent = os.stat(destination.parent, follow_symlinks=False)
    except FileNotFoundError as exc:
        raise AcquisitionError(
            "destination_parent_missing", "destination parent does not exist"
        ) from exc
    except OSError as exc:
        raise AcquisitionError(
            "destination_ineligible", f"cannot inspect destination parent: {exc}"
        ) from exc
    if not stat.S_ISDIR(parent.st_mode):
        raise AcquisitionError(
            "destination_ineligible", "destination parent is not a directory"
        )
    try:
        os.lstat(destination)
    except FileNotFoundError:
        return destination
    except OSError as exc:
        raise AcquisitionError(
            "destination_ineligible", f"cannot inspect destination: {exc}"
        ) from exc
    raise AcquisitionError(
        "destination_exists", "destination already contains filesystem content"
    )


def _owned(path: Path) -> _OwnedPath:
    current = os.lstat(path)
    return _owned_from_stat(path, current)


def _owned_from_stat(path: Path, current: os.stat_result) -> _OwnedPath:
    return _OwnedPath(
        path=path,
        device=current.st_dev,
        inode=current.st_ino,
        is_directory=stat.S_ISDIR(current.st_mode),
    )


def _matches_owned(current: os.stat_result, owned: _OwnedPath) -> bool:
    return (
        current.st_dev == owned.device
        and current.st_ino == owned.inode
        and stat.S_ISDIR(current.st_mode) == owned.is_directory
        and stat.S_ISREG(current.st_mode) != owned.is_directory
    )


def _remove_owned(owned: _OwnedPath) -> None:
    try:
        current = os.lstat(owned.path)
    except OSError as exc:
        raise AcquisitionError(
            "cleanup_failed", f"cannot inspect owned path before removal: {owned.path}"
        ) from exc
    if not _matches_owned(current, owned):
        raise AcquisitionError(
            "path_substituted", f"owned path changed before removal: {owned.path}"
        )
    try:
        if owned.is_directory:
            owned.path.rmdir()
        else:
            owned.path.unlink()
    except OSError as exc:
        raise AcquisitionError(
            "cleanup_failed", f"cannot remove owned path: {owned.path}"
        ) from exc


def _cleanup_owned(paths: Sequence[_OwnedPath]) -> list[str]:
    remaining: list[str] = []
    for owned in reversed(paths):
        try:
            current = os.lstat(owned.path)
        except FileNotFoundError:
            continue
        except OSError:
            remaining.append(str(owned.path))
            continue
        if not _matches_owned(current, owned):
            remaining.append(str(owned.path))
            continue
        try:
            if owned.is_directory:
                owned.path.rmdir()
            else:
                owned.path.unlink()
        except OSError:
            remaining.append(str(owned.path))
    return remaining


def _verify_acquired_file(
    path: Path, asset: _AssetSpec, owned: _OwnedPath | None = None
) -> None:
    handle = None
    try:
        flags = (
            os.O_RDONLY
            | _binary_flag()
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_NONBLOCK", 0)
        )
        handle = os.open(path, flags)
        current = os.fstat(handle)
        if (
            not stat.S_ISREG(current.st_mode)
            or current.st_size != asset.size
            or (
                owned is not None
                and (
                    current.st_dev != owned.device
                    or current.st_ino != owned.inode
                )
            )
        ):
            raise AcquisitionError(
                "staged_verification_failed",
                f"acquired source {asset.name} has an invalid type or size",
            )
        digest = hashlib.sha256()
        while True:
            chunk = os.read(handle, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        actual = digest.hexdigest()
    except AcquisitionError:
        raise
    except OSError as exc:
        raise AcquisitionError(
            "staged_verification_failed",
            f"cannot verify acquired source {asset.name}: {exc}",
        ) from exc
    finally:
        if handle is not None:
            os.close(handle)
    if actual.lower() != asset.sha256.lower():
        raise AcquisitionError(
            "staged_verification_failed",
            f"acquired source {asset.name} failed final SHA-256 verification",
        )


def _copy_to_final(
    source_owned: _OwnedPath,
    target: Path,
    asset: _AssetSpec,
    owned_paths: list[_OwnedPath],
) -> _OwnedPath:
    source_handle = None
    target_handle = None
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | _binary_flag()
        | getattr(os, "O_CLOEXEC", 0)
    )
    try:
        try:
            source_handle = os.open(
                source_owned.path,
                os.O_RDONLY
                | _binary_flag()
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_NONBLOCK", 0),
            )
        except OSError as exc:
            raise AcquisitionError(
                "path_substituted", "cannot reopen the owned staged source"
            ) from exc
        source_current = os.fstat(source_handle)
        if not _matches_owned(source_current, source_owned):
            raise AcquisitionError(
                "path_substituted", "staged source changed before final copy"
            )
        target_handle = os.open(target, flags, 0o600)
        target_current = os.fstat(target_handle)
        if not stat.S_ISREG(target_current.st_mode):
            raise AcquisitionError(
                "write_failed", f"created destination is not a regular file: {asset.name}"
            )
        final_owned = _owned_from_stat(target, target_current)
        owned_paths.append(final_owned)
        while True:
            chunk = os.read(source_handle, 1024 * 1024)
            if not chunk:
                break
            view = memoryview(chunk)
            while view:
                written = os.write(target_handle, view)
                if written <= 0:
                    raise OSError("final copy made no progress")
                view = view[written:]
        os.fsync(target_handle)
    except FileExistsError as exc:
        raise AcquisitionError(
            "destination_collision", f"destination entry appeared for {asset.name}"
        ) from exc
    except OSError as exc:
        raise AcquisitionError(
            "write_failed", f"cannot publish acquired source {asset.name}: {exc}"
        ) from exc
    finally:
        if target_handle is not None:
            os.close(target_handle)
        if source_handle is not None:
            os.close(source_handle)
    _verify_acquired_file(target, asset, final_owned)
    return final_owned


def _set_failure_context(
    exc: BaseException, destination: Path, cleanup_remaining: Sequence[str]
) -> None:
    exc.destination = str(destination)  # type: ignore[attr-defined]
    exc.cleanup_remaining = tuple(cleanup_remaining)  # type: ignore[attr-defined]
    if hasattr(exc, "add_note"):
        exc.add_note(
            "STEMwerk acquisition cleanup: "
            f"destination={destination}, remaining={list(cleanup_remaining)}"
        )


def _acquire_one(
    asset: _AssetSpec,
    staging: Path,
    transport: Any,
    *,
    clock: Callable[[], float],
    sleeper: Callable[[float], None],
    owned_paths: list[_OwnedPath],
) -> tuple[_OwnedPath, dict[str, Any]]:
    partial = staging / (asset.name + ".part")
    try:
        handle = os.open(
            partial,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | _binary_flag()
            | getattr(os, "O_CLOEXEC", 0),
            0o600,
        )
        os.close(handle)
    except OSError as exc:
        raise AcquisitionError(
            "write_failed", f"cannot create owned partial file: {exc}"
        ) from exc
    partial_owned = _owned(partial)
    owned_paths.append(partial_owned)

    total_deadline = clock() + asset.total_timeout
    source_index = 0
    primary_attempts = 0
    last_failure = "source unavailable"
    for attempt in range(1, MAX_ATTEMPTS + 1):
        _remaining(total_deadline, clock)
        source = asset.sources[source_index]
        if source_index == 0:
            primary_attempts += 1
        attempt_deadline = min(total_deadline, clock() + asset.attempt_timeout)
        try:
            evidence = transport.download(
                source,
                asset,
                partial,
                deadline=attempt_deadline,
                target_identity=partial_owned,
            )
            _verify_acquired_file(partial, asset, partial_owned)
            return partial_owned, {
                "name": asset.name,
                "sha256": asset.sha256.lower(),
                "size": asset.size,
                "source_id": source.source_id,
                "revision": source.revision,
                "final_host": evidence.final_host,
                "attempts": attempt,
            }
        except _AttemptFailure as exc:
            last_failure = str(exc)
            if exc.kind == "unavailable":
                if source_index + 1 < len(asset.sources):
                    source_index += 1
                    continue
                else:
                    raise AcquisitionError(
                        "source_unavailable",
                        f"source is unavailable for {asset.name}: {last_failure}",
                    ) from exc
            elif (
                exc.kind == "transient"
                and source_index == 0
                and source_index + 1 < len(asset.sources)
                and primary_attempts >= 2
            ):
                source_index += 1
            if attempt >= MAX_ATTEMPTS:
                break
            delay = RETRY_DELAYS_SECONDS[attempt - 1]
            if exc.retry_after is not None:
                delay = max(delay, min(exc.retry_after, 30.0))
            if clock() + delay >= total_deadline:
                raise AcquisitionError(
                    "deadline_exceeded",
                    f"acquisition budget expired after {attempt} attempts for {asset.name}",
                ) from exc
            sleeper(delay)
        except AcquisitionError:
            raise
        except OSError as exc:
            raise AcquisitionError(
                "write_failed", f"cannot store acquired source {asset.name}: {exc}"
            ) from exc
    raise AcquisitionError(
        "source_unavailable",
        f"all {MAX_ATTEMPTS} acquisition attempts failed for {asset.name}: "
        f"{last_failure}",
    )


def _acquire_asset_set(
    request: AcquisitionRequest,
    policy: _AcquisitionPolicy,
    *,
    transport: Any | None = None,
    clock: Callable[[], float] = time.monotonic,
    sleeper: Callable[[float], None] = time.sleep,
) -> dict[str, Any]:
    destination = _validate_request(request)
    if transport is None:
        transport = _HttpsTransport(clock=clock)
    owned_paths: list[_OwnedPath] = []
    assets_evidence: list[dict[str, Any]] = []
    final_sources: dict[str, str] = {}
    final_owned_paths: dict[str, _OwnedPath] = {}
    try:
        try:
            os.mkdir(destination, 0o700)
        except FileExistsError as exc:
            raise AcquisitionError(
                "destination_exists", "destination was created by a competing operation"
            ) from exc
        except OSError as exc:
            raise AcquisitionError(
                "destination_ineligible", f"cannot create destination: {exc}"
            ) from exc
        destination_owned = _owned(destination)
        owned_paths.append(destination_owned)

        staging = destination / (".stemwerk-acquisition-stage-" + uuid.uuid4().hex)
        try:
            os.mkdir(staging, 0o700)
        except OSError as exc:
            raise AcquisitionError(
                "write_failed", f"cannot create acquisition staging directory: {exc}"
            ) from exc
        staging_owned = _owned(staging)
        owned_paths.append(staging_owned)

        staged_assets: list[tuple[_AssetSpec, _OwnedPath]] = []
        for asset in policy.assets:
            staged_owned, evidence = _acquire_one(
                asset,
                staging,
                transport,
                clock=clock,
                sleeper=sleeper,
                owned_paths=owned_paths,
            )
            staged_assets.append((asset, staged_owned))
            assets_evidence.append(evidence)

        for asset, staged_owned in staged_assets:
            final_path = destination / asset.name
            final_owned = _copy_to_final(
                staged_owned,
                final_path,
                asset,
                owned_paths,
            )
            final_sources[asset.name] = str(final_path)
            final_owned_paths[asset.name] = final_owned
            _remove_owned(staged_owned)
            owned_paths.remove(staged_owned)

        _remove_owned(staging_owned)
        owned_paths.remove(staging_owned)
        for asset in policy.assets:
            _verify_acquired_file(
                Path(final_sources[asset.name]),
                asset,
                final_owned_paths[asset.name],
            )

        # The destination and final files are the successful result, not cleanup
        # targets after this point.
        owned_paths.clear()
        return {
            "kind": "stemwerk_asset_acquisition_result",
            "schema_version": SCHEMA_VERSION,
            "outcome": "success",
            "destination": str(destination),
            "policy": {"policy_id": policy.policy_id},
            "sources": final_sources,
            "assets": assets_evidence,
            "cleanup": {"complete": True, "remaining_paths": []},
            "materialization": {"performed": False, "published": False},
        }
    except BaseException as exc:
        remaining = _cleanup_owned(owned_paths)
        _set_failure_context(exc, destination, remaining)
        raise


def acquire_drumsep_sources(request: AcquisitionRequest) -> dict[str, Any]:
    """Acquire Core's complete pinned DrumSep source set into a new directory."""

    return _acquire_asset_set(request, _production_policy())


def _error_payload(exc: AcquisitionError) -> dict[str, Any]:
    return {
        "kind": "stemwerk_asset_acquisition_error",
        "schema_version": SCHEMA_VERSION,
        "outcome": "error",
        "destination": exc.destination,
        "error": {"code": exc.code, "message": str(exc)},
        "cleanup": {
            "complete": not exc.cleanup_remaining,
            "remaining_paths": list(exc.cleanup_remaining),
        },
        "materialization": {"performed": False, "published": False},
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Acquire Core-pinned DrumSep source files into a new directory."
    )
    parser.add_argument("--destination", required=True)
    parser.add_argument("--pretty", action="store_true")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        result = acquire_drumsep_sources(
            AcquisitionRequest(destination=Path(args.destination))
        )
    except AcquisitionError as exc:
        print(
            json.dumps(
                _error_payload(exc),
                indent=2 if args.pretty else None,
                sort_keys=True,
            ),
            file=sys.stderr,
        )
        return 2
    print(json.dumps(result, indent=2 if args.pretty else None, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
