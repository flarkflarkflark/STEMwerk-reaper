"""Portable tests for bounded DrumSep source acquisition."""
from __future__ import annotations

from collections import deque
import errno
import hashlib
import http.client
import http.server
import inspect
import json
import os
from pathlib import Path
import socket
import socketserver
import ssl
import sys
import tempfile
import threading
import time
import traceback
import types
import warnings

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import asset_acquisition as acquisition  # noqa: E402
from stemwerk_core import asset_materialization as materialization  # noqa: E402
from stemwerk_core import model_assets  # noqa: E402
from tests.asset_link_helpers import (  # noqa: E402
    is_directory_link,
    make_directory_link,
)

pytestmark = pytest.mark.portable


LOCALHOST_CERTIFICATE = """-----BEGIN CERTIFICATE-----
MIIDKzCCAhOgAwIBAgIUPoWUqTGDZDb9fHMXfKElpOUkO2YwDQYJKoZIhvcNAQEL
BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MTAyNjE4MDY1NVoYDzIxMDgx
MjE1MTgwNjU1WjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3DQEB
AQUAA4IBDwAwggEKAoIBAQDC4lBozh2z1GR6oB+R7rmJL3tpxnkyRlDg7hjyr9Ru
Zw7O09OeXYDvEA3fqC67W6wyzt9KA6b/xuKhQHOx9pqxOa5XDo3Db8n53kFZyrvG
VHyfxvq1YFPrwSqPfojNkXionIp5dslU+cpxLGuEgvmrMqiFnSy+wsHhrZe9w8rd
30w2pT/jc/NfXmRr81SOxrXhHp+zDcLGKwcXMqxA5IQYhgmS8WV/PK0GMcoz3Rzu
SSbo78wPHlRvbJoqYpBXQ/5DrgAoAWtbGtvr98r6hGHQhiuteGQP0EYBntS8ai0y
PZQfM/KYnTD7pGY5K+Che+31Wm8K3pjcvDT8UE5LIx47AgMBAAGjczBxMBoGA1Ud
EQQTMBGCCWxvY2FsaG9zdIcEfwAAATAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB
/wQEAwICpDATBgNVHSUEDDAKBggrBgEFBQcDATAdBgNVHQ4EFgQUFdVzUayRN7jK
1LzwUKKsa8a8OVcwDQYJKoZIhvcNAQELBQADggEBAGKZbvAr5z/JHeqkuHU41bmE
ozMyNhOLbQ6JZ1MU1EjsJgylj0CI/gFdYgNLXF3YN/EtD2IzplrZUF0kenlMwykE
ptdZZto+A32ZIakjtmYAB5hqhgVIJ1LdJmZPcZy77sJtyIiKGidj54lnu7z616w5
qHNlKBN3WamK7F2y/D21v6tqebH6u3GUrGoqutQYidcSIyoaIzdRGS+WL6QaTn4T
NBsyNxy8H+CABhNulmQ7BxvepVt0oCfNuLDyO7vh4zUn7IC0fKDb3DkZI9yjV8Ei
cxJ1f5Pjc9yyAKBfbBDyKg/P8HelkYnx18SUYOVCm0j7hYX8LOL4D9OjR8D6foI=
-----END CERTIFICATE-----
"""

LOCALHOST_PRIVATE_KEY = """-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDC4lBozh2z1GR6
oB+R7rmJL3tpxnkyRlDg7hjyr9RuZw7O09OeXYDvEA3fqC67W6wyzt9KA6b/xuKh
QHOx9pqxOa5XDo3Db8n53kFZyrvGVHyfxvq1YFPrwSqPfojNkXionIp5dslU+cpx
LGuEgvmrMqiFnSy+wsHhrZe9w8rd30w2pT/jc/NfXmRr81SOxrXhHp+zDcLGKwcX
MqxA5IQYhgmS8WV/PK0GMcoz3RzuSSbo78wPHlRvbJoqYpBXQ/5DrgAoAWtbGtvr
98r6hGHQhiuteGQP0EYBntS8ai0yPZQfM/KYnTD7pGY5K+Che+31Wm8K3pjcvDT8
UE5LIx47AgMBAAECggEAUD2urfhv8mM5G+RiG0wXyIxsXBkEPdcF5hci3onXBb4Z
Mr+1GjeVptkNXVF6LFqKhED5Xxgx4o6ZMZvABz5qYx5E0kODyzx0BRWmArqepgKT
bZYYFCYdZ6yZQYvv9/Q1ofcSbQCj1QEkgYSwoFbtRbgN+zXD/qdh/PHk0JWVKdTV
0var+xKW5Ln8b4bBI0behtna6byRHDQ55otP9VxdFgk0UNjC/GDDDto+NEQ1BHIV
KgQpTWb4X/+viGXQYPlpymOZMulMxzV6S9Jj+xZdTgfK3agEhHrOja6ht6CaMw3p
gr0/VJnA3pW5y2ldkLerM5m1ieCDS8+jxwcQ5vSqgQKBgQD8fVaFTdDKocbEYjLj
9EM7pOYkWaY6axwsd/jB0R/aEWE9LVbIlHiwRHP+rLrffgLK/O78TIbAt5+mGxiY
619FSI0fYF93BTDQMzVp+tMOjaSiiAmsJOk0T0nqklNjosiKEe7+tG6pXtSZgSun
m9NXrqNUFJpZq06bn7ZXuyw+yQKBgQDFl/I4exZGpoLk8CTrw80n/BWNdFpMsYef
syM8oGCIdXAkRBXVQnd9Ghxj8V3OjA/GI3ifBP/N8MxtMLVt1P5Zd3jiY0X4beBR
FD8USoEz8zeEsUhyIDBH4d6sUzP9g9gKk7HE5MdVhHZQUCTfI/e10XvlHfqnW8At
wK6vAqri4wKBgDiKiNmJN3xpBe3sX6EUjgnJP5BcUxE58zEyHI6qmgtnYPMmOAzq
0qwGaENbwu1RdqamRY5SRMrbU/EKmFOGQett98xS9I3ep7O4A/obpS/ZIEkVVbUq
/t4r802IPwxM48OniHGZTj63cbx+ZJxAFO/Jt+GYS4hRCGVpOpgi3iGhAoGAbmWe
p3/dyktuBotFlZQoI5bsU8QWT5NAuzFTFqRkStmSdjC0Ihqot/TGt/A7AROwHHvl
ALPCWEWZccgtFdhS45mkqJfemBaLpcEyHRwjY+sXscN7PohNcVv5FT7HZXUsV3x9
bgyEcns3v1eHwkROOf94wWImkSrqDKYC8zUCVRECgYEArsV0ywAduFWCA/X4ws+s
Ue46BEJ01D1AxXEVkssoZty+dx06fYEMS3XIKXFX78ulTiAAB6HfOfYy98BcmhGn
QyMMHSGxmZa0m3xNCJFlEDE8RGXp3qdm9TlhYtH5qNlUgiORghO7pWPhe+4XtS2l
/U5vt2djN65qMJQ5Xsz/W1s=
-----END PRIVATE KEY-----
"""


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


DUAL_STACK_BIND_ATTEMPTS = 20
IPV6_UNAVAILABLE_ERRNOS = {errno.EADDRNOTAVAIL, errno.EAFNOSUPPORT}


class _ExclusiveBindMixin:
    """Make a bind on a port that is already in use fail instead of sharing it.

    ``http.server`` sets SO_REUSEADDR, which on Windows lets a second socket
    bind a port another socket holds, with indeterminate delivery afterwards.
    Where SO_EXCLUSIVEADDRUSE exists (Windows) it is set before the bind.
    """

    allow_reuse_address = False

    def _set_exclusive_bind(self):
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)


class _LoopbackV4Server(_ExclusiveBindMixin, http.server.ThreadingHTTPServer):
    """IPv4 loopback test server with an exclusive bind."""

    def server_bind(self):
        self._set_exclusive_bind()
        super().server_bind()


class _LoopbackV6Server(_ExclusiveBindMixin, http.server.ThreadingHTTPServer):
    """IPv6-only loopback twin of the IPv4 test server (same handler and port)."""

    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        self._set_exclusive_bind()
        socketserver.TCPServer.server_bind(self)
        host, port = self.server_address[:2]
        self.server_name = host
        self.server_port = port


def _bind_loopback_servers(handler_type):
    """Bind 127.0.0.1:P and [::1]:P for one port P, loopback addresses only.

    ``localhost`` resolves to ``::1`` before ``127.0.0.1`` on some hosts, and a
    refused ``::1`` connect can cost seconds there; listening on both families
    makes the first address answer immediately. Returns ``(servers,
    ipv6_available)``. When IPv6 loopback truly does not exist only the IPv4
    server is returned and the caller must report it.
    """

    for _ in range(DUAL_STACK_BIND_ATTEMPTS):
        v4 = _LoopbackV4Server(("127.0.0.1", 0), handler_type)
        if not socket.has_ipv6:
            return [v4], False
        try:
            v6 = _LoopbackV6Server(("::1", v4.server_address[1]), handler_type)
        except OSError as exc:
            if exc.errno in IPV6_UNAVAILABLE_ERRNOS:
                return [v4], False
            v4.server_close()
            if exc.errno == errno.EADDRINUSE:
                continue  # the port is taken on ::1; choose another port
            raise
        return [v4, v6], True
    raise RuntimeError(
        f"could not bind one port on both loopback families in {DUAL_STACK_BIND_ATTEMPTS} attempts"
    )


@pytest.fixture
def local_https_server(tmp_path):
    certificate = tmp_path / "localhost-cert.pem"
    private_key = tmp_path / "localhost-key.pem"
    certificate.write_text(LOCALHOST_CERTIFICATE, encoding="ascii")
    private_key.write_text(LOCALHOST_PRIVATE_KEY, encoding="ascii")
    server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_context.load_cert_chain(certificate, private_key)
    client_context = ssl.create_default_context(cafile=str(certificate))
    servers = []

    def start(handler_type):
        listeners, ipv6_available = _bind_loopback_servers(handler_type)
        start.ipv6_available = ipv6_available
        if not ipv6_available:
            warnings.warn(
                "IPv6 loopback is unavailable on this host; the local HTTPS test "
                "server listens on 127.0.0.1 only",
                RuntimeWarning,
                stacklevel=2,
            )
        for server in listeners:
            server.daemon_threads = True
            server.socket = server_context.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            servers.append((server, thread))
        port = listeners[0].server_address[1]

        def connection_factory(host, port_, timeout, context):
            assert host == "localhost"
            assert port_ == 443
            return http.client.HTTPSConnection(
                "localhost",
                port,
                timeout=timeout,
                context=context,
            )

        return connection_factory, client_context, port

    start.servers = servers
    start.ipv6_available = None

    yield start

    for server, thread in servers:
        server.shutdown()
    for server, thread in servers:
        server.server_close()
        thread.join(2)


class QuietHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        return None


class FakeClock:
    def __init__(self) -> None:
        self.value = 100.0
        self.sleeps: list[float] = []

    def __call__(self) -> float:
        return self.value

    def advance(self, seconds: float) -> None:
        self.value += seconds

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.advance(seconds)


class ScriptedTransport:
    def __init__(self, actions, clock: FakeClock | None = None) -> None:
        self.actions = deque(actions)
        self.clock = clock
        self.calls: list[str] = []

    def download(self, source, asset, target, *, deadline, target_identity):
        self.calls.append(source.source_id)
        action = self.actions.popleft()
        if callable(action):
            action(source, asset, target, deadline)
            return acquisition._TransferEvidence(
                final_host="controlled.example",
                size=target.stat().st_size,
            )
        if isinstance(action, BaseException):
            raise action
        target.write_bytes(action)
        return acquisition._TransferEvidence(
            final_host="controlled.example",
            size=len(action),
        )


def controlled_policy(*, total_timeout: float = 30.0):
    contents = {
        "controlled-model.ckpt": b"controlled checkpoint\r\nbare-lf\n\x1a\x00tail\n",
        "controlled-model.yaml": b"controlled config\r\nbare-lf\n\x1a\x00tail\n",
    }
    primary = acquisition._SourceSpec(
        source_id="primary",
        url="https://primary.example/assets/model",
        redirect_hosts=("primary.example", "cdn.example"),
    )
    fallback = acquisition._SourceSpec(
        source_id="fallback",
        url="https://fallback.example/assets/model",
        redirect_hosts=("fallback.example", "cdn.example"),
    )
    assets = (
        acquisition._AssetSpec(
            name="controlled-model.ckpt",
            sha256=sha256(contents["controlled-model.ckpt"]),
            size=len(contents["controlled-model.ckpt"]),
            sources=(primary, fallback),
            attempt_timeout=10.0,
            total_timeout=total_timeout,
        ),
        acquisition._AssetSpec(
            name="controlled-model.yaml",
            sha256=sha256(contents["controlled-model.yaml"]),
            size=len(contents["controlled-model.yaml"]),
            sources=(
                acquisition._SourceSpec(
                    source_id="yaml",
                    url="https://config.example/model.yaml",
                    redirect_hosts=("config.example",),
                ),
            ),
            attempt_timeout=5.0,
            total_timeout=total_timeout,
        ),
    )
    return acquisition._AcquisitionPolicy("tests.controlled", assets), contents


def acquire(tmp_path: Path, policy, transport, clock: FakeClock | None = None):
    clock = clock or FakeClock()
    return acquisition._acquire_asset_set(
        acquisition.AcquisitionRequest(tmp_path / "acquired"),
        policy,
        transport=transport,
        clock=clock,
        sleeper=clock.sleep,
    )


def test_production_policy_uses_core_pins_and_exact_investigated_sources():
    policy = acquisition._production_policy()

    assert [asset.name for asset in policy.assets] == [
        model_assets.DIRECT_DKS_MODEL_FILENAME,
        model_assets.DIRECT_DKS_MODEL_YAML,
    ]
    assert [asset.sha256 for asset in policy.assets] == [
        model_assets.DIRECT_DKS_MODEL_EXPECTED_SHA256[asset.name]
        for asset in policy.assets
    ]
    checkpoint, config = policy.assets
    assert checkpoint.size == 437_652_699
    assert checkpoint.sources[0].url == (
        "https://huggingface.co/Sucial/MSST-WebUI/resolve/"
        "90b617b15bd0dc0b784f3d361faca1b51173fe44/All_Models/"
        "multi_stem_models/"
        "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt"
    )
    assert checkpoint.sources[1].url == (
        "https://huggingface.co/KitsuneX07/"
        "Music_Source_Sepetration_Models/resolve/"
        "8309883c6b3fecc360fff24c932dcc588f8c23c2/multi_stem_models/"
        "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.ckpt"
        "?download=true"
    )
    assert config.size == 2_417
    assert config.sources[0].url == (
        "https://raw.githubusercontent.com/TRvlvr/application_data/"
        "adea29c9fdbd2fa115a208965d00a6f03cdfde96/mdx_model_data/"
        "mdx_c_configs/"
        "aufr33-jarredou_DrumSep_model_mdx23c_ep_141_sdr_10.8059.yaml"
    )
    assert tuple(inspect.signature(acquisition.AcquisitionRequest).parameters) == (
        "destination",
    )


def test_acquires_complete_verified_mapping_without_materializing(tmp_path):
    policy, contents = controlled_policy()
    transport = ScriptedTransport([contents[name] for name in contents])

    result = acquire(tmp_path, policy, transport)

    destination = tmp_path / "acquired"
    assert result["kind"] == "stemwerk_asset_acquisition_result"
    assert result["outcome"] == "success"
    assert result["destination"] == str(destination)
    assert result["cleanup"] == {"complete": True, "remaining_paths": []}
    assert result["materialization"] == {"performed": False, "published": False}
    assert set(result["sources"]) == set(contents)
    assert set(path.name for path in destination.iterdir()) == set(contents)
    for name, content in contents.items():
        path = Path(result["sources"][name])
        assert path.read_bytes() == content
        assert path.parent == destination


def test_primary_is_retried_then_fallback_used_with_three_total_attempts(tmp_path):
    policy, contents = controlled_policy()
    transport = ScriptedTransport(
        [
            acquisition._AttemptFailure("transient", "temporary one"),
            acquisition._AttemptFailure("transient", "temporary two"),
            contents["controlled-model.ckpt"],
            contents["controlled-model.yaml"],
        ]
    )

    result = acquire(tmp_path, policy, transport)

    assert transport.calls == ["primary", "primary", "fallback", "yaml"]
    assert result["assets"][0]["attempts"] == 3
    assert result["assets"][0]["source_id"] == "fallback"


def test_unavailable_primary_moves_immediately_to_fallback(tmp_path):
    policy, contents = controlled_policy()
    clock = FakeClock()
    transport = ScriptedTransport(
        [
            acquisition._AttemptFailure("unavailable", "not found"),
            acquisition._AttemptFailure("transient", "fallback temporary"),
            contents["controlled-model.ckpt"],
            contents["controlled-model.yaml"],
        ]
    )

    acquire(tmp_path, policy, transport, clock)

    assert transport.calls == ["primary", "fallback", "fallback", "yaml"]
    assert clock.sleeps == [4.0]


def test_unavailable_source_without_another_fallback_is_not_retried(tmp_path):
    policy, _ = controlled_policy()
    transport = ScriptedTransport(
        [
            acquisition._AttemptFailure("unavailable", "primary gone"),
            acquisition._AttemptFailure("unavailable", "fallback gone"),
        ]
    )

    with pytest.raises(acquisition.AcquisitionError) as exc:
        acquire(tmp_path, policy, transport)

    assert exc.value.code == "source_unavailable"
    assert transport.calls == ["primary", "fallback"]


@pytest.mark.parametrize(
    "failure",
    [
        acquisition.AcquisitionError("source_integrity_mismatch", "wrong bytes"),
        acquisition.AcquisitionError("tls_failed", "certificate rejected"),
        acquisition.AcquisitionError("redirect_rejected", "host rejected"),
    ],
)
def test_integrity_tls_and_redirect_failures_do_not_retry_or_fallback(
    tmp_path, failure
):
    policy, _ = controlled_policy()
    transport = ScriptedTransport([failure])

    with pytest.raises(acquisition.AcquisitionError) as exc:
        acquire(tmp_path, policy, transport)

    assert exc.value.code == failure.code
    assert transport.calls == ["primary"]
    assert not (tmp_path / "acquired").exists()


def test_three_attempt_limit_and_retry_waits_fit_global_deadline(tmp_path):
    policy, _ = controlled_policy(total_timeout=4.5)
    clock = FakeClock()
    transport = ScriptedTransport(
        [
            acquisition._AttemptFailure("transient", "one"),
            acquisition._AttemptFailure("transient", "two"),
            acquisition._AttemptFailure("transient", "three"),
        ],
        clock,
    )

    with pytest.raises(acquisition.AcquisitionError) as exc:
        acquire(tmp_path, policy, transport, clock)

    assert exc.value.code == "deadline_exceeded"
    assert transport.calls == ["primary", "primary"]
    assert clock.sleeps == [1.0]
    assert not (tmp_path / "acquired").exists()


def test_retry_exhaustion_is_bounded_to_three_attempts(tmp_path):
    policy, _ = controlled_policy()
    transport = ScriptedTransport(
        [acquisition._AttemptFailure("transient", str(index)) for index in range(3)]
    )

    with pytest.raises(acquisition.AcquisitionError) as exc:
        acquire(tmp_path, policy, transport)

    assert exc.value.code == "source_unavailable"
    assert transport.calls == ["primary", "primary", "fallback"]


def test_retry_after_is_capped_and_charged_to_total_budget(tmp_path):
    policy, contents = controlled_policy(total_timeout=40.0)
    clock = FakeClock()
    transport = ScriptedTransport(
        [
            acquisition._AttemptFailure(
                "transient", "rate limited", retry_after=300.0
            ),
            contents["controlled-model.ckpt"],
            contents["controlled-model.yaml"],
        ]
    )

    result = acquire(tmp_path, policy, transport, clock)

    assert result["outcome"] == "success"
    assert clock.sleeps == [30.0]


def test_url_policy_uses_dns_label_boundaries_and_rejects_credentials():
    allowed = ("hf.co", "huggingface.co")
    assert acquisition._validated_https_url(
        "https://us.aws.cdn.hf.co/object", allowed
    ).hostname == "us.aws.cdn.hf.co"
    assert acquisition._validated_https_url(
        "https://huggingface.co/object", allowed
    ).hostname == "huggingface.co"
    for url in (
        "http://huggingface.co/object",
        "https://huggingface.co.attacker.example/object",
        "https://notreallyhf.co/object",
        "https://user:secret@huggingface.co/object",
    ):
        with pytest.raises(acquisition.AcquisitionError) as exc:
            acquisition._validated_https_url(url, allowed)
        assert exc.value.code == "redirect_rejected"


def test_redacts_queries_and_fragments_from_error_text():
    secret = "temporary-signed-secret"
    url = f"https://cdn.example/object?Signature={secret}#fragment-secret"

    redacted = acquisition._redacted_url(url)
    error = acquisition.AcquisitionError(
        "redirect_rejected", f"redirect rejected: {redacted}"
    )

    assert redacted == "https://cdn.example/object?<redacted>"
    assert secret not in str(error)
    assert "fragment-secret" not in str(error)


class FakeSocket:
    def __init__(self) -> None:
        self.timeouts: list[float] = []

    def settimeout(self, timeout: float) -> None:
        self.timeouts.append(timeout)


class FakeResponse:
    def __init__(self, status=200, body=b"", headers=None, clock=None, tick=0.0):
        self.status = status
        self._body = body
        self._offset = 0
        self._headers = {key.lower(): value for key, value in (headers or {}).items()}
        self.clock = clock
        self.tick = tick

    def getheader(self, name, default=None):
        return self._headers.get(name.lower(), default)

    def read(self, amount=-1):
        if self.clock is not None:
            self.clock.advance(self.tick)
        if self._offset >= len(self._body):
            return b""
        if amount < 0:
            amount = len(self._body) - self._offset
        end = min(self._offset + amount, len(self._body))
        chunk = self._body[self._offset:end]
        self._offset = end
        return chunk

    def close(self):
        return None


class FakeConnection:
    def __init__(self, response):
        self.response = response
        self.sock = FakeSocket()
        self.requests = []

    def request(self, method, target, headers=None):
        self.requests.append((method, target, dict(headers or {})))

    def getresponse(self):
        return self.response

    def close(self):
        return None


class ConnectionFactory:
    def __init__(self, responses):
        self.responses = deque(responses)
        self.connections = []

    def __call__(self, host, port, timeout, context):
        connection = FakeConnection(self.responses.popleft())
        self.connections.append((host, port, timeout, context, connection))
        return connection


def transport_asset(content=b"verified"):
    source = acquisition._SourceSpec(
        source_id="controlled",
        url="https://primary.example/source?token=initial-secret",
        redirect_hosts=("primary.example", "cdn.example"),
    )
    asset = acquisition._AssetSpec(
        name="asset.bin",
        sha256=sha256(content),
        size=len(content),
        sources=(source,),
        attempt_timeout=10.0,
        total_timeout=20.0,
    )
    return source, asset


def test_https_transport_follows_only_allowed_redirects_and_sends_safe_headers(tmp_path):
    content = b"verified"
    responses = [
        FakeResponse(
            status=302,
            headers={"Location": "https://cdn.example/blob?Signature=redirect-secret"},
        ),
        FakeResponse(status=200, body=content, headers={"Content-Length": str(len(content))}),
    ]
    factory = ConnectionFactory(responses)
    clock = FakeClock()
    transport = acquisition._HttpsTransport(connection_factory=factory, clock=clock)
    source, asset = transport_asset(content)
    target = tmp_path / "asset.part"
    target.touch()

    evidence = transport.download(source, asset, target, deadline=clock() + 20)

    assert target.read_bytes() == content
    assert evidence.final_host == "cdn.example"
    assert [entry[0] for entry in factory.connections] == [
        "primary.example",
        "cdn.example",
    ]
    second_headers = factory.connections[1][4].requests[0][2]
    assert set(second_headers) == {
        "Accept",
        "Accept-Encoding",
        "Connection",
        "User-Agent",
    }
    assert not any(
        name.lower() in {"authorization", "proxy-authorization", "cookie"}
        for name in second_headers
    )


def test_redirect_rejection_redacts_signed_query(tmp_path):
    secret = "redirect-secret"
    factory = ConnectionFactory(
        [
            FakeResponse(
                status=302,
                headers={"Location": f"https://attacker.example/blob?Signature={secret}"},
            )
        ]
    )
    clock = FakeClock()
    transport = acquisition._HttpsTransport(connection_factory=factory, clock=clock)
    source, asset = transport_asset()
    target = tmp_path / "asset.part"
    target.touch()

    with pytest.raises(acquisition.AcquisitionError) as exc:
        transport.download(source, asset, target, deadline=clock() + 20)

    assert exc.value.code == "redirect_rejected"
    assert secret not in str(exc.value)


def test_redirect_count_is_bounded(tmp_path):
    responses = [
        FakeResponse(status=302, headers={"Location": f"/redirect-{index}"})
        for index in range(acquisition.MAX_REDIRECTS + 1)
    ]
    factory = ConnectionFactory(responses)
    clock = FakeClock()
    transport = acquisition._HttpsTransport(connection_factory=factory, clock=clock)
    source, asset = transport_asset()
    target = tmp_path / "asset.part"
    target.touch()

    with pytest.raises(acquisition.AcquisitionError) as exc:
        transport.download(source, asset, target, deadline=clock() + 20)

    assert exc.value.code == "redirect_rejected"
    assert len(factory.connections) == acquisition.MAX_REDIRECTS + 1


@pytest.mark.parametrize(
    ("status", "failure_type", "detail"),
    [
        (429, acquisition._AttemptFailure, "transient"),
        (503, acquisition._AttemptFailure, "transient"),
        (404, acquisition._AttemptFailure, "unavailable"),
        (403, acquisition.AcquisitionError, "http_rejected"),
    ],
)
def test_http_statuses_have_explicit_retry_classification(
    tmp_path, status, failure_type, detail
):
    headers = {"Retry-After": "300"} if status == 429 else {}
    factory = ConnectionFactory([FakeResponse(status=status, headers=headers)])
    clock = FakeClock()
    transport = acquisition._HttpsTransport(connection_factory=factory, clock=clock)
    source, asset = transport_asset()
    target = tmp_path / "asset.part"
    target.touch()

    with pytest.raises(failure_type) as exc:
        transport.download(source, asset, target, deadline=clock() + 20)

    if isinstance(exc.value, acquisition._AttemptFailure):
        assert exc.value.kind == detail
        if status == 429:
            assert exc.value.retry_after == 30.0
    else:
        assert exc.value.code == detail


def test_tls_failure_is_terminal_and_does_not_expose_query(tmp_path):
    def reject_tls(host, port, timeout, context):
        raise ssl.SSLCertVerificationError("certificate rejected")

    clock = FakeClock()
    transport = acquisition._HttpsTransport(
        connection_factory=reject_tls, clock=clock
    )
    source, asset = transport_asset()
    target = tmp_path / "asset.part"
    target.touch()

    with pytest.raises(acquisition.AcquisitionError) as exc:
        transport.download(source, asset, target, deadline=clock() + 20)

    assert exc.value.code == "tls_failed"
    assert "initial-secret" not in str(exc.value)


def test_malformed_http_response_is_terminal_and_redacted(tmp_path):
    secret = "initial-secret"

    def malformed(host, port, timeout, context):
        class Connection(FakeConnection):
            def getresponse(self):
                raise http.client.BadStatusLine(f"bad response ?signature={secret}")

        return Connection(FakeResponse())

    clock = FakeClock()
    transport = acquisition._HttpsTransport(connection_factory=malformed, clock=clock)
    source, asset = transport_asset()
    target = tmp_path / "asset.part"
    target.touch()

    with pytest.raises(acquisition.AcquisitionError) as exc:
        transport.download(source, asset, target, deadline=clock() + 20)

    assert exc.value.code == "http_rejected"
    rendered = "".join(
        traceback.format_exception(type(exc.value), exc.value, exc.value.__traceback__)
    )
    assert secret not in rendered


def test_invalid_content_length_redacts_nested_secret(tmp_path):
    secret = "CONTENT_LENGTH_SECRET"
    factory = ConnectionFactory(
        [
            FakeResponse(
                status=200,
                headers={"Content-Length": f"8?signature={secret}"},
            )
        ]
    )
    transport = acquisition._HttpsTransport(
        connection_factory=factory, clock=FakeClock()
    )
    source, asset = transport_asset()
    target = tmp_path / "asset.part"
    target.touch()

    with pytest.raises(acquisition.AcquisitionError) as exc:
        transport.download(source, asset, target, deadline=120)

    rendered = "".join(
        traceback.format_exception(type(exc.value), exc.value, exc.value.__traceback__)
    )
    assert exc.value.code == "content_length_mismatch"
    assert secret not in rendered


def test_invalid_url_port_redacts_nested_secret():
    secret = "INVALID_PORT_SECRET"
    url = f"https://localhost:not-a-port?signature={secret}"

    with pytest.raises(acquisition.AcquisitionError) as exc:
        acquisition._validated_https_url(url, ("localhost",))

    rendered = "".join(
        traceback.format_exception(type(exc.value), exc.value, exc.value.__traceback__)
    )
    assert exc.value.code == "redirect_rejected"
    assert secret not in rendered


def test_dns_resolution_is_bounded_without_a_filesystem_worker(tmp_path):
    def blocked_resolver(host, port, *, type):
        time.sleep(0.3)
        return []

    transport = acquisition._HttpsTransport(resolver=blocked_resolver)
    source, asset = transport_asset()
    target = tmp_path / "asset.part"
    target.write_bytes(b"preserve")
    started = time.monotonic()

    with pytest.raises(acquisition._AttemptFailure) as exc:
        transport.download(
            source,
            asset,
            target,
            deadline=time.monotonic() + 0.05,
        )

    assert time.monotonic() - started < 0.2
    assert exc.value.kind == "transient"
    assert target.read_bytes() == b"preserve"


def test_resolved_addresses_share_one_tcp_connection_deadline(monkeypatch):
    clock = FakeClock()
    attempted = []

    class BlackholedSocket:
        def settimeout(self, timeout):
            self.timeout = timeout

        def connect(self, address):
            attempted.append((address, self.timeout))
            clock.advance(self.timeout)
            raise socket.timeout("blackhole")

        def close(self):
            return None

    monkeypatch.setattr(acquisition.socket, "socket", lambda *args: BlackholedSocket())
    addresses = [
        (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("192.0.2.1", 443)),
        (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("192.0.2.2", 443)),
    ]
    connection = acquisition._ResolvedHTTPSConnection(
        "example.test",
        443,
        30,
        ssl.create_default_context(),
        addresses,
        clock() + 5,
        clock() + 10,
        clock,
    )

    with pytest.raises(socket.timeout):
        connection._connect_resolved(None, 30, None)

    assert attempted == [(('192.0.2.1', 443), 5.0)]


def test_production_tls_handshake_obeys_remaining_attempt_deadline(tmp_path):
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]
    accepted = threading.Event()

    def stall_handshake():
        connection, _ = listener.accept()
        accepted.set()
        time.sleep(0.6)
        connection.close()
        listener.close()

    server = threading.Thread(target=stall_handshake, daemon=True)
    server.start()

    def resolver(host, requested_port, *, type):
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", port))]

    transport = acquisition._HttpsTransport(resolver=resolver)
    source, asset = localhost_transport_asset()
    target = tmp_path / "asset.part"
    target.touch()
    started = time.monotonic()

    with pytest.raises(acquisition._AttemptFailure) as exc:
        transport.download(
            source, asset, target, deadline=time.monotonic() + 0.15
        )

    elapsed = time.monotonic() - started
    assert accepted.wait(1)
    assert exc.value.kind == "transient"
    assert elapsed < 0.45


def test_request_interrupt_closes_connection_and_cancels_watchdog(tmp_path):
    timers = []

    class TrackingTimer:
        def __init__(self, seconds, callback):
            self.cancelled = False
            self.daemon = False
            timers.append(self)

        def start(self):
            return None

        def cancel(self):
            self.cancelled = True

        def join(self, timeout=None):
            return None

    class InterruptedConnection(FakeConnection):
        def __init__(self):
            super().__init__(FakeResponse())
            self.closed = False

        def request(self, method, target, headers=None):
            raise KeyboardInterrupt("cancelled")

        def close(self):
            self.closed = True

    connection = InterruptedConnection()
    transport = acquisition._HttpsTransport(
        connection_factory=lambda *args: connection,
        timer_factory=TrackingTimer,
        clock=FakeClock(),
    )
    source, asset = transport_asset()
    target = tmp_path / "asset.part"
    target.touch()

    with pytest.raises(KeyboardInterrupt):
        transport.download(source, asset, target, deadline=120)

    assert connection.closed
    assert timers and timers[0].cancelled


def test_tls_error_during_body_read_is_terminal(tmp_path):
    class BadTlsResponse(FakeResponse):
        def read(self, amount=-1):
            raise ssl.SSLError("bad record")

    transport = acquisition._HttpsTransport(
        connection_factory=ConnectionFactory([BadTlsResponse(status=200)]),
        clock=FakeClock(),
    )
    source, asset = transport_asset()
    target = tmp_path / "asset.part"
    target.touch()

    with pytest.raises(acquisition.AcquisitionError) as exc:
        transport.download(source, asset, target, deadline=120)

    assert exc.value.code == "tls_failed"


def test_incomplete_read_exception_is_retryable(tmp_path):
    class IncompleteResponse(FakeResponse):
        def read(self, amount=-1):
            raise http.client.IncompleteRead(b"partial")

    factory = ConnectionFactory([IncompleteResponse(status=200)])
    clock = FakeClock()
    transport = acquisition._HttpsTransport(connection_factory=factory, clock=clock)
    source, asset = transport_asset()
    target = tmp_path / "asset.part"
    target.touch()

    with pytest.raises(acquisition._AttemptFailure) as exc:
        transport.download(source, asset, target, deadline=clock() + 20)

    assert exc.value.kind == "transient"


@pytest.mark.parametrize(
    ("body", "content_length", "code"),
    [
        (b"short", None, "transfer_truncated"),
        (b"verified-extra", None, "transfer_excess"),
        (b"verified", "7", "content_length_mismatch"),
        (b"verifiex", "8", "source_integrity_mismatch"),
    ],
)
def test_transport_rejects_truncated_excess_length_and_hash_failures(
    tmp_path, body, content_length, code
):
    headers = {} if content_length is None else {"Content-Length": content_length}
    factory = ConnectionFactory([FakeResponse(status=200, body=body, headers=headers)])
    clock = FakeClock()
    transport = acquisition._HttpsTransport(connection_factory=factory, clock=clock)
    source, asset = transport_asset()
    target = tmp_path / "asset.part"
    target.touch()

    with pytest.raises(acquisition.AcquisitionError) as exc:
        transport.download(source, asset, target, deadline=clock() + 20)

    assert exc.value.code == code


class _ManualTimer:
    """Watchdog timer that fires only when a test says the deadline was reached."""

    def __init__(self, callback):
        self.callback = callback
        self.daemon = False

    def start(self):
        return None

    def cancel(self):
        return None

    def join(self, timeout=None):
        return None

    def fire(self):
        self.callback()


class _ManualTimers:
    def __init__(self):
        self.timers = []

    def __call__(self, seconds, callback):
        timer = _ManualTimer(callback)
        self.timers.append(timer)
        return timer


class _FailingStatusConnection(FakeConnection):
    """Raises ``error`` while waiting for the status line."""

    def __init__(self, error, timers, deadline_reached):
        super().__init__(FakeResponse())
        self.error = error
        self.timers = timers
        self.deadline_reached = deadline_reached

    def getresponse(self):
        if self.deadline_reached:
            self.timers.timers[-1].fire()
        raise self.error


class _FailingBodyResponse(FakeResponse):
    """Raises ``error`` on the first body read."""

    def __init__(self, error, timers, deadline_reached, content):
        super().__init__(
            status=200, body=content, headers={"Content-Length": str(len(content))}
        )
        self.error = error
        self.timers = timers
        self.deadline_reached = deadline_reached

    def read(self, amount=-1):
        if self.deadline_reached:
            self.timers.timers[-1].fire()
        raise self.error


class _ScriptedConnectionFactory:
    """One item per connection: an exception to raise at getresponse or a response."""

    def __init__(self, items, timers):
        self.items = deque(items)
        self.timers = timers
        self.connections = 0

    def __call__(self, host, port, timeout, context):
        self.connections += 1
        item = self.items.popleft()
        if isinstance(item, BaseException):
            return _FailingStatusConnection(item, self.timers, False)
        return FakeConnection(item)


DEADLINE = "bounded deadline"
CLOSED = "closed the connection without a response"
STATUS_PHASE_CASES = [
    pytest.param(http.client.RemoteDisconnected("eof"), True, "deadline", id="remote-disconnected-reached"),
    pytest.param(http.client.RemoteDisconnected("eof"), False, "closed", id="remote-disconnected"),
    pytest.param(BrokenPipeError(32, "Broken pipe"), True, "deadline", id="broken-pipe-reached"),
    pytest.param(ssl.SSLEOFError(8, "EOF occurred"), True, "deadline", id="ssl-eof-reached"),
    pytest.param(ssl.SSLError("handshake"), True, "deadline", id="ssl-error-reached"),
    pytest.param(ssl.SSLError("handshake"), False, "tls_failed", id="ssl-error"),
    pytest.param(http.client.BadStatusLine("garbage"), False, "http_rejected", id="bad-status-line"),
    pytest.param(http.client.BadStatusLine("garbage"), True, "deadline", id="bad-status-line-reached"),
    pytest.param(http.client.LineTooLong("status line"), False, "http_rejected", id="line-too-long"),
    pytest.param(http.client.LineTooLong("status line"), True, "deadline", id="line-too-long-reached"),
    pytest.param(ConnectionResetError(104, "reset"), False, "transport", id="connection-reset"),
    pytest.param(ConnectionResetError(104, "reset"), True, "deadline", id="connection-reset-reached"),
]


@pytest.mark.parametrize(("error", "deadline_reached", "expected"), STATUS_PHASE_CASES)
def test_status_phase_failures_are_classified_by_deadline_then_type(
    tmp_path, error, deadline_reached, expected
):
    timers = _ManualTimers()
    connection = _FailingStatusConnection(error, timers, deadline_reached)
    clock = FakeClock()
    transport = acquisition._HttpsTransport(
        connection_factory=lambda *args: connection,
        timer_factory=timers,
        clock=clock,
    )
    source, asset = transport_asset()
    target = tmp_path / "asset.part"
    target.touch()

    with pytest.raises(
        (acquisition._AttemptFailure, acquisition.AcquisitionError)
    ) as exc:
        transport.download(source, asset, target, deadline=clock() + 20)

    outcome = exc.value
    assert "initial-secret" not in str(outcome)
    if expected in {"deadline", "closed", "transport"}:
        assert isinstance(outcome, acquisition._AttemptFailure)
        assert outcome.kind == "transient"
        assert {
            "deadline": DEADLINE,
            "closed": CLOSED,
            "transport": "transport failed",
        }[expected] in str(outcome)
    else:
        assert isinstance(outcome, acquisition.AcquisitionError)
        assert outcome.code == expected


@pytest.mark.parametrize("deadline_reached", [True, False])
def test_tls_failure_while_reading_body_follows_the_deadline(tmp_path, deadline_reached):
    content = b"verified"
    timers = _ManualTimers()
    response = _FailingBodyResponse(
        ssl.SSLEOFError(8, "EOF occurred"), timers, deadline_reached, content
    )
    clock = FakeClock()
    transport = acquisition._HttpsTransport(
        connection_factory=lambda *args: FakeConnection(response),
        timer_factory=timers,
        clock=clock,
    )
    source, asset = transport_asset(content)
    target = tmp_path / "asset.part"
    target.touch()

    with pytest.raises(
        (acquisition._AttemptFailure, acquisition.AcquisitionError)
    ) as exc:
        transport.download(source, asset, target, deadline=clock() + 20)

    if deadline_reached:
        assert isinstance(exc.value, acquisition._AttemptFailure)
        assert exc.value.kind == "transient"
        assert DEADLINE in str(exc.value)
    else:
        assert isinstance(exc.value, acquisition.AcquisitionError)
        assert exc.value.code == "tls_failed"


@pytest.mark.parametrize("phase", ["status", "body"])
@pytest.mark.parametrize("deadline_reached", [True, False])
def test_value_error_from_a_watchdog_closed_socket_follows_the_deadline(
    tmp_path, phase, deadline_reached
):
    content = b"verified"
    error = ValueError("Read on closed or unwrapped SSL socket.")
    timers = _ManualTimers()
    if phase == "status":
        connection = _FailingStatusConnection(error, timers, deadline_reached)
    else:
        connection = FakeConnection(
            _FailingBodyResponse(error, timers, deadline_reached, content)
        )
    clock = FakeClock()
    transport = acquisition._HttpsTransport(
        connection_factory=lambda *args: connection,
        timer_factory=timers,
        clock=clock,
    )
    source, asset = transport_asset(content)
    target = tmp_path / "asset.part"
    target.touch()

    if deadline_reached:
        with pytest.raises(acquisition._AttemptFailure) as exc:
            transport.download(source, asset, target, deadline=clock() + 20)
        assert exc.value.kind == "transient"
        assert DEADLINE in str(exc.value)
        return

    with pytest.raises(ValueError) as exc:
        transport.download(source, asset, target, deadline=clock() + 20)

    # Never wrapped or reclassified: the same object, with its original traceback.
    assert exc.value is error
    assert str(exc.value) == "Read on closed or unwrapped SSL socket."
    assert exc.value.__cause__ is None and not exc.value.__suppress_context__
    raise_site = "getresponse" if phase == "status" else "read"
    assert raise_site in [
        frame.name for frame in traceback.extract_tb(exc.value.__traceback__)
    ]


class _RecordingSocket(FakeSocket):
    """Records the thread and the watchdog state of every shutdown."""

    def __init__(self, log, label, reached):
        super().__init__()
        self.log = log
        self.label = label
        self.reached = reached

    def shutdown(self, how):
        self.log.append(
            (
                self.label + ".shutdown",
                threading.current_thread().name,
                self.reached(),
            )
        )


class _RecordingResponse(FakeResponse):
    """Owns a socket like a real response and records who closes it."""

    def __init__(self, log, socket_, body=b"", headers=None, on_read=None):
        super().__init__(status=200, body=body, headers=headers)
        self.log = log
        self.fp = types.SimpleNamespace(raw=types.SimpleNamespace(_sock=socket_))
        self.on_read = on_read

    def read(self, amount=-1):
        if self.on_read is not None:
            self.on_read()
        return super().read(amount)

    def close(self):
        self.log.append(("response.close", threading.current_thread().name, None))


class _RecordingConnection(FakeConnection):
    def __init__(self, log, response, socket_, on_getresponse=None):
        super().__init__(response)
        self.sock = socket_
        self.log = log
        self.on_getresponse = on_getresponse

    def getresponse(self):
        if self.on_getresponse is not None:
            self.on_getresponse()
        return self.response

    def close(self):
        self.log.append(("connection.close", threading.current_thread().name, None))


def _fire_on_watchdog_thread(timers):
    thread = threading.Thread(target=timers.timers[-1].fire, name="watchdog-thread")
    thread.start()
    thread.join(5)
    assert not thread.is_alive()


WATCHDOG_CASES = ["success", "ordinary-failure", "deadline-in-body", "deadline-in-status"]


@pytest.mark.parametrize("case", WATCHDOG_CASES)
def test_watchdog_thread_only_shuts_down_and_the_attempt_thread_closes_once(tmp_path, case):
    content = b"verified"
    log = []
    timers = _ManualTimers()

    def reached():
        return timers.timers[-1].callback.__self__.reached.is_set()

    connection_socket = _RecordingSocket(log, "connection.sock", reached)
    response_socket = _RecordingSocket(log, "response.sock", reached)
    if case == "ordinary-failure":
        # right size, wrong bytes: a terminal integrity failure
        body = b"corrupted"[: len(content)]
        on_read = None
    elif case == "deadline-in-body":
        body = content
        on_read = lambda: _fire_on_watchdog_thread(timers)  # noqa: E731
    else:
        body = content
        on_read = None
    response = _RecordingResponse(
        log,
        response_socket,
        body=body,
        headers={"Content-Length": str(len(content))},
        on_read=on_read,
    )

    def status_deadline():
        _fire_on_watchdog_thread(timers)
        raise ConnectionResetError(104, "reset")

    connection = _RecordingConnection(
        log,
        response,
        connection_socket,
        on_getresponse=status_deadline if case == "deadline-in-status" else None,
    )
    clock = FakeClock()
    transport = acquisition._HttpsTransport(
        connection_factory=lambda *args: connection,
        timer_factory=timers,
        clock=clock,
    )
    source, asset = transport_asset(content)
    target = tmp_path / "asset.part"
    target.touch()
    attempt_thread = threading.current_thread().name

    if case == "success":
        transport.download(source, asset, target, deadline=clock() + 20)
    elif case == "ordinary-failure":
        with pytest.raises(acquisition.AcquisitionError) as exc:
            transport.download(source, asset, target, deadline=clock() + 20)
        assert exc.value.code == "source_integrity_mismatch"
    else:
        with pytest.raises(acquisition._AttemptFailure) as exc:
            transport.download(source, asset, target, deadline=clock() + 20)
        assert DEADLINE in str(exc.value)

    closes = [entry for entry in log if entry[0].endswith(".close")]
    shutdowns = [entry for entry in log if entry[0].endswith(".shutdown")]
    # Closing is the attempt thread's job, on every path, exactly once.
    assert [name for name, _, _ in closes].count("connection.close") == 1
    expected_response_closes = 0 if case == "deadline-in-status" else 1
    assert [name for name, _, _ in closes].count("response.close") == expected_response_closes
    assert {thread for _, thread, _ in closes} == {attempt_thread}
    if case.startswith("deadline"):
        # The watchdog thread only woke the attempt: it set `reached` first and
        # then shut down what the attempt owns. Nothing else ran on it.
        assert {thread for _, thread, _ in log} == {attempt_thread, "watchdog-thread"}
        assert shutdowns
        assert {thread for _, thread, _ in shutdowns} == {"watchdog-thread"}
        assert all(flag is True for _, _, flag in shutdowns)
        assert {name for name, _, _ in shutdowns} >= {"connection.sock.shutdown"}
    else:
        assert not shutdowns


@pytest.mark.parametrize("owner", ["response-owned", "both-sockets"])
def test_watchdog_shuts_down_the_response_owned_socket_during_the_body_read(
    tmp_path, owner
):
    content = b"verified"
    log = []
    timers = _ManualTimers()

    def reached():
        return timers.timers[-1].callback.__self__.reached.is_set()

    connection_socket = _RecordingSocket(log, "connection.sock", reached)
    response_socket = _RecordingSocket(log, "response.sock", reached)
    response = _RecordingResponse(
        log,
        response_socket,
        body=content,
        headers={"Content-Length": str(len(content))},
        on_read=lambda: _fire_on_watchdog_thread(timers),
    )

    def hand_over_socket():
        if owner == "response-owned":
            # With `Connection: close` http.client hands the socket to the
            # response: the connection has none left during the body read.
            connection.sock = None

    connection = _RecordingConnection(
        log, response, connection_socket, on_getresponse=hand_over_socket
    )
    clock = FakeClock()
    transport = acquisition._HttpsTransport(
        connection_factory=lambda *args: connection,
        timer_factory=timers,
        clock=clock,
    )
    source, asset = transport_asset(content)
    target = tmp_path / "asset.part"
    target.touch()
    attempt_thread = threading.current_thread().name

    with pytest.raises(acquisition._AttemptFailure) as exc:
        transport.download(source, asset, target, deadline=clock() + 20)

    assert DEADLINE in str(exc.value)
    shutdowns = [entry for entry in log if entry[0].endswith(".shutdown")]
    expected = ["response.sock.shutdown"]
    if owner == "both-sockets":
        expected.append("connection.sock.shutdown")
    # Each owned socket is shut down exactly once, by the watchdog thread,
    # after `reached` was set.
    assert sorted(name for name, _, _ in shutdowns) == sorted(expected)
    assert {thread for _, thread, _ in shutdowns} == {"watchdog-thread"}
    assert all(flag is True for _, _, flag in shutdowns)
    assert [
        name for name, thread, _ in log
        if thread == "watchdog-thread" and not name.endswith(".shutdown")
    ] == []
    closes = [(name, thread) for name, thread, _ in log if name.endswith(".close")]
    assert sorted(closes) == [
        ("connection.close", attempt_thread),
        ("response.close", attempt_thread),
    ]


def _finished_download(tmp_path):
    """A successful download, then its watchdog and the recorded events."""

    content = b"verified"
    log = []
    timers = _ManualTimers()

    def reached():
        return timers.timers[-1].callback.__self__.reached.is_set()

    response = _RecordingResponse(
        log,
        _RecordingSocket(log, "response.sock", reached),
        body=content,
        headers={"Content-Length": str(len(content))},
    )
    connection = _RecordingConnection(
        log, response, _RecordingSocket(log, "connection.sock", reached)
    )
    clock = FakeClock()
    transport = acquisition._HttpsTransport(
        connection_factory=lambda *args: connection,
        timer_factory=timers,
        clock=clock,
    )
    source, asset = transport_asset(content)
    target = tmp_path / "asset.part"
    target.touch()
    transport.download(source, asset, target, deadline=clock() + 20)
    assert sorted(name for name, _, _ in log) == ["connection.close", "response.close"]
    return timers, log


def test_watchdog_firing_after_finish_touches_no_socket(tmp_path):
    timers, log = _finished_download(tmp_path)
    before = list(log)

    # A timer that fires late, after the attempt thread already closed.
    _fire_on_watchdog_thread(timers)

    assert timers.timers[-1].callback.__self__.reached.is_set()
    assert log == before


def test_watchdog_finish_closes_only_once(tmp_path):
    timers, log = _finished_download(tmp_path)
    before = list(log)

    timers.timers[-1].callback.__self__.finish()

    assert log == before


ESCAPE_ERRORS = [
    pytest.param(
        lambda: AttributeError("'NoneType' object has no attribute 'close'"),
        id="attribute-error",
    ),
    pytest.param(lambda: TypeError("argument of type 'NoneType' is not iterable"), id="type-error"),
]


def _escape_download(tmp_path, phase, make_error, deadline_reached):
    content = b"verified"
    error = make_error()
    timers = _ManualTimers()
    if phase == "status":
        connection = _FailingStatusConnection(error, timers, deadline_reached)
    else:
        connection = FakeConnection(
            _FailingBodyResponse(error, timers, deadline_reached, content)
        )
    clock = FakeClock()
    transport = acquisition._HttpsTransport(
        connection_factory=lambda *args: connection,
        timer_factory=timers,
        clock=clock,
    )
    source, asset = transport_asset(content)
    target = tmp_path / "asset.part"
    target.touch()
    return error, lambda: transport.download(source, asset, target, deadline=clock() + 20)


@pytest.mark.parametrize("phase", ["status", "body"])
@pytest.mark.parametrize("make_error", ESCAPE_ERRORS)
def test_unexpected_exception_after_the_deadline_is_the_deadline_outcome(
    tmp_path, phase, make_error
):
    secret_url = "https://leak.example/object?Signature=exception-secret"
    error, download = _escape_download(
        tmp_path,
        phase,
        lambda: type(make_error())(f"failed at {secret_url}"),
        True,
    )

    with pytest.raises(acquisition._AttemptFailure) as exc:
        download()

    outcome = exc.value
    assert outcome.kind == "transient"
    assert DEADLINE in str(outcome)
    assert f"after {type(error).__name__}" in str(outcome)
    rendered = "".join(traceback.format_exception(outcome))
    for text in (str(outcome), rendered):
        assert "exception-secret" not in text
        assert "leak.example" not in text
        assert "initial-secret" not in text
    # Neither chained nor embedded: only the type name is carried over.
    assert outcome.__cause__ is None
    assert outcome.__suppress_context__


@pytest.mark.parametrize("phase", ["status", "body"])
@pytest.mark.parametrize("make_error", ESCAPE_ERRORS)
def test_unexpected_exception_without_the_deadline_propagates_unchanged(
    tmp_path, phase, make_error
):
    error, download = _escape_download(tmp_path, phase, make_error, False)

    with pytest.raises(type(error)) as exc:
        download()

    assert exc.value is error
    assert exc.value.__cause__ is None and not exc.value.__suppress_context__
    raise_site = "getresponse" if phase == "status" else "read"
    assert raise_site in [
        frame.name for frame in traceback.extract_tb(exc.value.__traceback__)
    ]


@pytest.mark.parametrize("phase", ["status", "body"])
@pytest.mark.parametrize(
    "make_error",
    [
        pytest.param(lambda: KeyboardInterrupt("cancelled"), id="keyboard-interrupt"),
        pytest.param(lambda: SystemExit(3), id="system-exit"),
        pytest.param(GeneratorExit, id="generator-exit"),
    ],
)
def test_base_exceptions_after_the_deadline_are_never_caught(tmp_path, phase, make_error):
    error, download = _escape_download(tmp_path, phase, make_error, True)

    with pytest.raises(type(error)) as exc:
        download()

    assert exc.value is error


def test_closed_without_response_is_retried_and_the_bytes_are_verified(tmp_path):
    policy, contents = controlled_policy()
    timers = _ManualTimers()
    ckpt = contents["controlled-model.ckpt"]
    yaml_bytes = contents["controlled-model.yaml"]
    factory = _ScriptedConnectionFactory(
        [
            http.client.RemoteDisconnected("closed"),
            FakeResponse(status=200, body=ckpt, headers={"Content-Length": str(len(ckpt))}),
            FakeResponse(
                status=200,
                body=yaml_bytes,
                headers={"Content-Length": str(len(yaml_bytes))},
            ),
        ],
        timers,
    )
    clock = FakeClock()
    transport = acquisition._HttpsTransport(
        connection_factory=factory, timer_factory=timers, clock=clock
    )

    result = acquisition._acquire_asset_set(
        acquisition.AcquisitionRequest(tmp_path / "acquired"),
        policy,
        transport=transport,
        clock=clock,
        sleeper=clock.sleep,
    )

    assert result["outcome"] == "success"
    assert [asset["attempts"] for asset in result["assets"]] == [2, 1]
    assert factory.connections == 3
    assert clock.sleeps  # the retry waited before trying again
    for name, content in contents.items():
        assert Path(result["sources"][name]).read_bytes() == content


def test_repeated_closed_without_response_exhausts_into_source_unavailable(tmp_path):
    policy, _ = controlled_policy()
    timers = _ManualTimers()
    factory = _ScriptedConnectionFactory(
        [http.client.RemoteDisconnected("closed")] * 3, timers
    )
    clock = FakeClock()
    transport = acquisition._HttpsTransport(
        connection_factory=factory, timer_factory=timers, clock=clock
    )

    with pytest.raises(acquisition.AcquisitionError) as exc:
        acquisition._acquire_asset_set(
            acquisition.AcquisitionRequest(tmp_path / "acquired"),
            policy,
            transport=transport,
            clock=clock,
            sleeper=clock.sleep,
        )

    assert exc.value.code == "source_unavailable"
    assert CLOSED in str(exc.value)
    assert factory.connections == 3
    assert not (tmp_path / "acquired").exists()


def localhost_transport_asset(content=b"verified", path="/asset"):
    source = acquisition._SourceSpec(
        source_id="localhost",
        url=f"https://localhost{path}",
        redirect_hosts=("localhost",),
    )
    asset = acquisition._AssetSpec(
        name="asset.bin",
        sha256=sha256(content),
        size=len(content),
        sources=(source,),
        attempt_timeout=2.0,
        total_timeout=3.0,
    )
    return source, asset


def test_local_https_server_answers_on_both_loopback_families_on_one_port(
    local_https_server,
):
    class OkHandler(QuietHandler):
        def do_GET(self):
            body = b"same-response"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True

    _, context, port = local_https_server(OkHandler)

    # The fixture decides IPv6 availability once and never skips a test for it.
    assert local_https_server.ipv6_available in {True, False}
    families = [(socket.AF_INET, "127.0.0.1")]
    if local_https_server.ipv6_available:
        families.append((socket.AF_INET6, "::1"))
    bodies = []
    for family, address in families:
        with socket.socket(family, socket.SOCK_STREAM) as raw:
            raw.settimeout(5)
            raw.connect((address, port))
            with context.wrap_socket(raw, server_hostname="localhost") as tls:
                tls.sendall(
                    b"GET /x HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
                )
                data = b""
                while True:
                    chunk = tls.recv(4096)
                    if not chunk:
                        break
                    data += chunk
        assert data.startswith(b"HTTP/1.1 200")
        bodies.append(data.partition(b"\r\n\r\n")[2])

    assert bodies == [b"same-response"] * len(families)


def test_local_https_server_listens_on_loopback_addresses_only(local_https_server):
    _, _, port = local_https_server(QuietHandler)

    bound = sorted(
        server.socket.getsockname()[:2] for server, _ in local_https_server.servers
    )

    expected = ["127.0.0.1"] + (["::1"] if local_https_server.ipv6_available else [])
    assert sorted(host for host, _ in bound) == sorted(expected)
    assert {listening_port for _, listening_port in bound} == {port}
    for server, _ in local_https_server.servers:
        # Exclusive binding: no SO_REUSEADDR; SO_EXCLUSIVEADDRUSE where it exists.
        assert not server.socket.getsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR)
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            assert server.socket.getsockopt(
                socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE
            )


@pytest.mark.parametrize("family", ["ipv4", "ipv6"])
def test_local_https_server_bind_on_a_port_in_use_fails_loudly(family):
    address_family, address = (
        (socket.AF_INET, "127.0.0.1") if family == "ipv4" else (socket.AF_INET6, "::1")
    )
    server_class = _LoopbackV4Server if family == "ipv4" else _LoopbackV6Server
    try:
        holder = socket.socket(address_family, socket.SOCK_STREAM)
        holder.bind((address, 0))
    except OSError as exc:
        # A loopback family that does not exist cannot hold a port to collide on.
        assert family == "ipv6" and exc.errno in IPV6_UNAVAILABLE_ERRNOS
        return
    with holder:
        holder.listen(1)
        port = holder.getsockname()[1]

        with pytest.raises(OSError) as exc:
            server_class((address, port), QuietHandler)

        assert exc.value.errno == errno.EADDRINUSE


def test_real_https_transport_rejects_bytes_after_declared_body(
    tmp_path, local_https_server
):
    class ExcessHandler(QuietHandler):
        def do_GET(self):
            self.connection.sendall(
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Length: 8\r\n"
                b"Connection: close\r\n\r\n"
                b"verifiedEXTRA"
            )
            self.close_connection = True

    _, context, port = local_https_server(ExcessHandler)
    transport = acquisition._HttpsTransport(
        ssl_context=context,
        resolver=lambda host, requested_port, *, type: [
            (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("127.0.0.1", port))
        ],
    )
    source, asset = localhost_transport_asset()
    target = tmp_path / "asset.part"
    target.touch()

    with pytest.raises(acquisition.AcquisitionError) as exc:
        transport.download(
            source, asset, target, deadline=time.monotonic() + 2
        )

    assert exc.value.code == "transfer_excess"


@pytest.mark.native_publication
def test_real_https_response_owned_socket_obeys_idle_read_timeout(
    tmp_path, local_https_server, monkeypatch
):
    class StalledBodyHandler(QuietHandler):
        def do_GET(self):
            self.connection.sendall(
                b"HTTP/1.1 200 OK\r\n"
                b"Content-Length: 8\r\n"
                b"Connection: close\r\n\r\n"
                b"v"
            )
            time.sleep(0.6)
            try:
                self.connection.sendall(b"erified")
            except OSError:
                pass
            self.close_connection = True

    factory, context, _ = local_https_server(StalledBodyHandler)
    transport = acquisition._HttpsTransport(
        connection_factory=factory, ssl_context=context
    )
    monkeypatch.setattr(acquisition, "READ_TIMEOUT_SECONDS", 0.15)
    source, asset = localhost_transport_asset()
    target = tmp_path / "asset.part"
    target.touch()
    started = time.monotonic()

    with pytest.raises(acquisition._AttemptFailure) as exc:
        transport.download(
            source, asset, target, deadline=time.monotonic() + 2
        )

    elapsed = time.monotonic() - started
    size_at_return = target.stat().st_size
    time.sleep(0.65)
    assert exc.value.kind == "transient"
    assert elapsed < 0.45
    assert target.stat().st_size == size_at_return


@pytest.mark.native_publication
def test_real_https_header_stall_is_stopped_at_attempt_deadline(
    tmp_path, local_https_server
):
    class StalledHeaderHandler(QuietHandler):
        def do_GET(self):
            time.sleep(0.6)
            try:
                self.send_response(200)
                self.send_header("Content-Length", "8")
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(b"verified")
            except OSError:
                pass
            self.close_connection = True

    factory, context, _ = local_https_server(StalledHeaderHandler)
    transport = acquisition._HttpsTransport(
        connection_factory=factory, ssl_context=context
    )
    source, asset = localhost_transport_asset()
    target = tmp_path / "asset.part"
    target.touch()
    started = time.monotonic()

    with pytest.raises(acquisition._AttemptFailure) as exc:
        transport.download(
            source, asset, target, deadline=time.monotonic() + 0.15
        )

    assert exc.value.kind == "transient"
    assert time.monotonic() - started < 0.45


@pytest.mark.native_publication
def test_real_https_watchdog_alone_wakes_a_stalled_status_read(
    tmp_path, local_https_server
):
    class StalledHeaderHandler(QuietHandler):
        def do_GET(self):
            time.sleep(0.6)
            try:
                self.send_response(200)
                self.send_header("Content-Length", "8")
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(b"verified")
            except OSError:
                pass
            self.close_connection = True

    factory, context, _ = local_https_server(StalledHeaderHandler)

    def slow_socket_factory(host, port, timeout, ssl_context):
        # The socket would only time out long after the attempt deadline, so
        # the shutdown from the watchdog thread is the only thing that can
        # wake the read in time.
        return factory(host, port, 30.0, ssl_context)

    transport = acquisition._HttpsTransport(
        connection_factory=slow_socket_factory, ssl_context=context
    )
    source, asset = localhost_transport_asset()
    target = tmp_path / "asset.part"
    target.touch()
    started = time.monotonic()

    with pytest.raises(acquisition._AttemptFailure) as exc:
        transport.download(
            source, asset, target, deadline=time.monotonic() + 0.15
        )

    assert exc.value.kind == "transient"
    assert DEADLINE in str(exc.value)
    if sys.platform == "win32":
        # Winsock documents no wake-up of an idle select() by shutdown(); the
        # wait ends when the server's data arrives at ~0.6 s, because data
        # after shutdown(SD_RECEIVE) resets the connection (CI run
        # 40603074419). The bound still catches a hang.
        assert time.monotonic() - started < 2.0
    else:
        assert time.monotonic() - started < 0.45


@pytest.mark.native_publication
def test_real_https_watchdog_wakes_a_chunked_body_read_on_a_response_owned_socket(
    tmp_path, local_https_server
):
    # The chunk-size line is trickled one byte every 50 ms for 6 s. http.client
    # reads that line inside a single read1() call, so neither the per-chunk
    # deadline check nor the per-receive timeout (set to the remaining attempt
    # time, far above 50 ms) can end the read: only the watchdog's shutdown of
    # the response-owned socket (`Connection: close`) can.
    trickle_interval = 0.05
    trickle_steps = 120

    class TrickledChunkHeaderHandler(QuietHandler):
        def do_GET(self):
            try:
                self.connection.sendall(
                    b"HTTP/1.1 200 OK\r\n"
                    b"Transfer-Encoding: chunked\r\n"
                    b"Connection: close\r\n\r\n"
                )
                for _ in range(trickle_steps):
                    time.sleep(trickle_interval)
                    self.connection.sendall(b"0")
            except OSError:
                pass
            self.close_connection = True

    factory, context, _ = local_https_server(TrickledChunkHeaderHandler)

    def slow_socket_factory(host, port, timeout, ssl_context):
        return factory(host, port, 30.0, ssl_context)

    transport = acquisition._HttpsTransport(
        connection_factory=slow_socket_factory, ssl_context=context
    )
    source, asset = localhost_transport_asset()
    target = tmp_path / "asset.part"
    target.touch()
    started = time.monotonic()

    with pytest.raises(acquisition._AttemptFailure) as exc:
        transport.download(
            source, asset, target, deadline=time.monotonic() + 0.5
        )

    elapsed = time.monotonic() - started
    assert exc.value.kind == "transient"
    assert DEADLINE in str(exc.value)
    # Without the wake-up the read lasts as long as the trickle (6 s). The
    # bound leaves 2 s after the 0.5 s deadline for slow runners.
    assert elapsed < 2.5
    assert target.stat().st_size == 0


def test_real_https_rejects_untrusted_certificate(tmp_path, local_https_server):
    class ValidHandler(QuietHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Length", "8")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"verified")
            self.close_connection = True

    factory, _, _ = local_https_server(ValidHandler)
    transport = acquisition._HttpsTransport(connection_factory=factory)
    source, asset = localhost_transport_asset()
    target = tmp_path / "asset.part"
    target.touch()

    with pytest.raises(acquisition.AcquisitionError) as exc:
        transport.download(
            source, asset, target, deadline=time.monotonic() + 2
        )

    assert exc.value.code == "tls_failed"


def test_real_malformed_https_response_redacts_nested_secret(
    tmp_path, local_https_server
):
    secret = "SIGNED_QUERY_CANARY"

    class MalformedHandler(QuietHandler):
        def do_GET(self):
            self.connection.sendall(
                f"BAD ?signature={secret}\r\n\r\n".encode("ascii")
            )
            self.close_connection = True

    factory, context, _ = local_https_server(MalformedHandler)
    transport = acquisition._HttpsTransport(
        connection_factory=factory, ssl_context=context
    )
    source, asset = localhost_transport_asset(path=f"/asset?signature={secret}")
    target = tmp_path / "asset.part"
    target.touch()

    with pytest.raises(acquisition.AcquisitionError) as exc:
        transport.download(
            source, asset, target, deadline=time.monotonic() + 2
        )

    rendered = "".join(
        traceback.format_exception(type(exc.value), exc.value, exc.value.__traceback__)
    )
    assert exc.value.code == "http_rejected"
    assert secret not in rendered


def test_trickling_response_cannot_evade_total_deadline(tmp_path):
    clock = FakeClock()

    class OneReceiveAtATime(FakeResponse):
        def read(self, amount=-1):  # pragma: no cover - must use read1
            raise AssertionError("streaming transport must not use filling read()")

        def read1(self, amount=-1):
            return super().read(amount)

    response = OneReceiveAtATime(
        status=200, body=b"verified", clock=clock, tick=2.0
    )
    factory = ConnectionFactory([response])
    transport = acquisition._HttpsTransport(
        connection_factory=factory, clock=clock, chunk_size=1
    )
    source, asset = transport_asset()
    target = tmp_path / "asset.part"
    target.touch()

    with pytest.raises(acquisition._AttemptFailure) as exc:
        transport.download(source, asset, target, deadline=clock() + 3)

    assert exc.value.kind == "transient"


def test_deadline_watchdog_aborts_even_before_response_headers_complete(tmp_path):
    class ImmediateTimer:
        def __init__(self, seconds, callback):
            self.seconds = seconds
            self.callback = callback
            self.daemon = False

        def start(self):
            self.callback()

        def cancel(self):
            return None

        def join(self, timeout=None):
            return None

    clock = FakeClock()
    factory = ConnectionFactory([FakeResponse(status=200, body=b"verified")])
    transport = acquisition._HttpsTransport(
        connection_factory=factory,
        clock=clock,
        timer_factory=ImmediateTimer,
    )
    source, asset = transport_asset()
    target = tmp_path / "asset.part"
    target.touch()

    with pytest.raises(acquisition._AttemptFailure) as exc:
        transport.download(source, asset, target, deadline=clock() + 3)

    assert exc.value.kind == "transient"


def _can_create_file_symlink() -> bool:
    """Whether this process can create a file symlink without extra privilege.

    Windows refuses it without Developer Mode or administrator rights
    (ERROR_PRIVILEGE_NOT_HELD, 1314); elsewhere it normally succeeds.
    """

    with tempfile.TemporaryDirectory() as directory:
        target = Path(directory) / "target"
        target.touch()
        try:
            (Path(directory) / "link").symlink_to(target)
        except (OSError, NotImplementedError):
            return False
    return True


CAN_CREATE_FILE_SYMLINK = _can_create_file_symlink()


@pytest.mark.skipif(
    not CAN_CREATE_FILE_SYMLINK, reason="requires unprivileged symlink creation"
)
def test_transport_refuses_partial_path_substitution_without_touching_target(tmp_path):
    content = b"verified"
    factory = ConnectionFactory([FakeResponse(status=200, body=content)])
    clock = FakeClock()
    transport = acquisition._HttpsTransport(connection_factory=factory, clock=clock)
    source, asset = transport_asset(content)
    target = tmp_path / "asset.part"
    target.touch()
    owned = acquisition._owned(target)
    victim = tmp_path / "victim"
    victim.write_bytes(b"preserve")
    target.unlink()
    target.symlink_to(victim)

    with pytest.raises(acquisition.AcquisitionError) as exc:
        transport.download(
            source,
            asset,
            target,
            deadline=clock() + 20,
            target_identity=owned,
        )

    assert exc.value.code == "write_failed"
    assert victim.read_bytes() == b"preserve"


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="requires FIFO support")
def test_transport_refuses_fifo_substitution_without_blocking(tmp_path):
    content = b"verified"
    factory = ConnectionFactory([FakeResponse(status=200, body=content)])
    clock = FakeClock()
    transport = acquisition._HttpsTransport(connection_factory=factory, clock=clock)
    source, asset = transport_asset(content)
    target = tmp_path / "asset.part"
    target.touch()
    owned = acquisition._owned(target)
    target.unlink()
    os.mkfifo(target)

    with pytest.raises(acquisition.AcquisitionError) as exc:
        transport.download(
            source,
            asset,
            target,
            deadline=clock() + 20,
            target_identity=owned,
        )

    assert exc.value.code == "write_failed"


def test_destination_collision_fails_without_using_transport(tmp_path):
    policy, _ = controlled_policy()
    destination = tmp_path / "acquired"
    destination.mkdir()
    marker = destination / "unrelated"
    marker.write_text("preserve", encoding="utf-8")
    transport = ScriptedTransport([])

    with pytest.raises(acquisition.AcquisitionError) as exc:
        acquisition._acquire_asset_set(
            acquisition.AcquisitionRequest(destination),
            policy,
            transport=transport,
        )

    assert exc.value.code == "destination_exists"
    assert marker.read_text(encoding="utf-8") == "preserve"
    assert transport.calls == []


def _acquire_to(destination: Path, policy, transport):
    clock = FakeClock()
    return acquisition._acquire_asset_set(
        acquisition.AcquisitionRequest(destination),
        policy,
        transport=transport,
        clock=clock,
        sleeper=clock.sleep,
    )


@pytest.mark.native_publication
def test_rejects_destination_parent_directory_link(tmp_path):
    policy, _ = controlled_policy()
    real_parent = tmp_path / "real-parent"
    real_parent.mkdir()
    parent_link = tmp_path / "parent-link"
    make_directory_link(parent_link, real_parent)
    transport = ScriptedTransport([])

    with pytest.raises(acquisition.AcquisitionError) as exc:
        _acquire_to(parent_link / "acquired", policy, transport)

    assert exc.value.code == "destination_ineligible"
    assert transport.calls == []
    assert list(real_parent.iterdir()) == []
    assert is_directory_link(parent_link)


@pytest.mark.native_publication
def test_rejects_deeper_destination_ancestor_directory_link(tmp_path):
    policy, _ = controlled_policy()
    real_root = tmp_path / "real-root"
    (real_root / "child").mkdir(parents=True)
    root_link = tmp_path / "root-link"
    make_directory_link(root_link, real_root)
    transport = ScriptedTransport([])

    with pytest.raises(acquisition.AcquisitionError) as exc:
        _acquire_to(root_link / "child" / "acquired", policy, transport)

    assert exc.value.code == "destination_ineligible"
    assert transport.calls == []
    assert list((real_root / "child").iterdir()) == []
    assert is_directory_link(root_link)


@pytest.mark.native_publication
def test_rejects_destination_that_is_a_directory_link(tmp_path):
    policy, _ = controlled_policy()
    victim = tmp_path / "victim"
    victim.mkdir()
    (victim / "keep.txt").write_text("preserve", encoding="utf-8")
    destination = tmp_path / "acquired"
    make_directory_link(destination, victim)
    transport = ScriptedTransport([])

    with pytest.raises(acquisition.AcquisitionError) as exc:
        _acquire_to(destination, policy, transport)

    assert exc.value.code == "destination_exists"
    assert transport.calls == []
    assert [path.name for path in victim.iterdir()] == ["keep.txt"]
    assert (victim / "keep.txt").read_text(encoding="utf-8") == "preserve"
    assert is_directory_link(destination)


@pytest.mark.native_publication
def test_cleanup_does_not_follow_directory_link_at_owned_path(tmp_path):
    path = tmp_path / "owned-stage"
    path.mkdir()
    owned = acquisition._owned(path)
    path.rename(tmp_path / "original-stage")
    victim = tmp_path / "victim"
    victim.mkdir()
    (victim / "keep.txt").write_text("preserve", encoding="utf-8")
    make_directory_link(path, victim)

    assert acquisition._cleanup_owned([owned]) == [str(path)]
    with pytest.raises(acquisition.AcquisitionError) as exc:
        acquisition._remove_owned(owned)

    assert exc.value.code == "path_substituted"
    assert (victim / "keep.txt").read_text(encoding="utf-8") == "preserve"
    assert is_directory_link(path)


@pytest.mark.native_publication
def test_failed_acquisition_does_not_follow_directory_link_substituted_for_staging(
    tmp_path,
):
    policy, _ = controlled_policy()
    victim = tmp_path / "victim"
    victim.mkdir()
    (victim / "keep.txt").write_text("preserve", encoding="utf-8")
    (victim / "controlled-model.ckpt.part").write_text("preserve", encoding="utf-8")
    swapped = []

    def substitute_staging(source, asset, target, deadline):
        staging = target.parent
        staging.rename(staging.with_name(staging.name + "-moved"))
        make_directory_link(staging, victim)
        swapped.append(staging)
        raise OSError("interrupted after staging substitution")

    with pytest.raises(acquisition.AcquisitionError) as exc:
        _acquire_to(tmp_path / "acquired", policy, ScriptedTransport([substitute_staging]))

    assert exc.value.code == "write_failed"
    assert str(swapped[0]) in exc.value.cleanup_remaining
    assert sorted(path.name for path in victim.iterdir()) == [
        "controlled-model.ckpt.part",
        "keep.txt",
    ]
    assert (victim / "keep.txt").read_text(encoding="utf-8") == "preserve"
    assert (victim / "controlled-model.ckpt.part").read_text(encoding="utf-8") == (
        "preserve"
    )
    assert is_directory_link(swapped[0])


class _WindowsStyleStat:
    """lstat result for a Windows reparse point whose st_mode is not a link."""

    def __init__(self, real: os.stat_result, attributes: int) -> None:
        self.st_mode = real.st_mode
        self.st_dev = real.st_dev
        self.st_ino = real.st_ino
        self.st_file_attributes = attributes


REPARSE_POINT_ATTRIBUTE = 0x400
ARCHIVE_ATTRIBUTE = 0x20


def _lstat_with_fake(monkeypatch, fake_path: Path, attributes: int) -> None:
    real_lstat = os.lstat

    def lstat(candidate, *args, **kwargs):
        result = real_lstat(candidate, *args, **kwargs)
        if Path(candidate) == fake_path:
            return _WindowsStyleStat(result, attributes)
        return result

    monkeypatch.setattr(os, "lstat", lstat)


def test_link_detection_is_shared_with_the_materializer():
    assert acquisition._is_link_or_reparse is materialization._is_link_or_reparse


@pytest.mark.parametrize("position", ["parent", "ancestor"])
def test_windows_reparse_point_in_destination_path_is_rejected(
    tmp_path, monkeypatch, position
):
    policy, _ = controlled_policy()
    fake = tmp_path if position == "parent" else tmp_path.parent
    _lstat_with_fake(monkeypatch, fake, REPARSE_POINT_ATTRIBUTE)
    transport = ScriptedTransport([])

    with pytest.raises(acquisition.AcquisitionError) as exc:
        _acquire_to(tmp_path / "acquired", policy, transport)

    assert exc.value.code == "destination_ineligible"
    assert "reparse point" in str(exc.value)
    assert transport.calls == []
    assert not (tmp_path / "acquired").exists()


@pytest.mark.parametrize("position", ["parent", "ancestor"])
def test_windows_non_reparse_attributes_in_destination_path_are_accepted(
    tmp_path, monkeypatch, position
):
    policy, contents = controlled_policy()
    fake = tmp_path if position == "parent" else tmp_path.parent
    _lstat_with_fake(monkeypatch, fake, ARCHIVE_ATTRIBUTE)

    result = _acquire_to(
        tmp_path / "acquired",
        policy,
        ScriptedTransport([contents[name] for name in contents]),
    )

    assert result["outcome"] == "success"


def test_windows_reparse_point_at_owned_path_is_not_cleaned_up(tmp_path, monkeypatch):
    path = tmp_path / "owned-stage"
    path.mkdir()
    owned = acquisition._owned(path)
    _lstat_with_fake(monkeypatch, path, REPARSE_POINT_ATTRIBUTE)

    assert acquisition._matches_owned(os.lstat(path), owned) is False
    assert acquisition._cleanup_owned([owned]) == [str(path)]
    with pytest.raises(acquisition.AcquisitionError) as exc:
        acquisition._remove_owned(owned)

    assert exc.value.code == "path_substituted"
    monkeypatch.undo()
    assert path.is_dir()


def test_windows_non_reparse_attributes_at_owned_path_are_cleaned_up(
    tmp_path, monkeypatch
):
    path = tmp_path / "owned-stage"
    path.mkdir()
    owned = acquisition._owned(path)
    _lstat_with_fake(monkeypatch, path, ARCHIVE_ATTRIBUTE)

    assert acquisition._matches_owned(os.lstat(path), owned) is True
    assert acquisition._cleanup_owned([owned]) == []
    monkeypatch.undo()
    assert not path.exists()


def test_competing_operations_cannot_both_acquire(tmp_path):
    policy, contents = controlled_policy()
    entered = threading.Event()
    release = threading.Event()
    outcomes = []

    def blocking(source, asset, target, deadline):
        entered.set()
        assert release.wait(5)
        target.write_bytes(contents[asset.name])

    first_transport = ScriptedTransport(
        [blocking, contents["controlled-model.yaml"]]
    )

    def run_first():
        try:
            outcomes.append(acquire(tmp_path, policy, first_transport))
        except BaseException as exc:  # pragma: no cover - diagnostic capture
            outcomes.append(exc)

    thread = threading.Thread(target=run_first)
    thread.start()
    assert entered.wait(5)
    second_transport = ScriptedTransport([])
    with pytest.raises(acquisition.AcquisitionError) as exc:
        acquire(tmp_path, policy, second_transport)
    assert exc.value.code == "destination_exists"
    release.set()
    thread.join(5)

    assert len(outcomes) == 1
    assert isinstance(outcomes[0], dict)


def test_interrupt_cleans_owned_destination_and_preserves_original_exception(tmp_path):
    policy, _ = controlled_policy()
    transport = ScriptedTransport([KeyboardInterrupt("cancelled")])

    with pytest.raises(KeyboardInterrupt) as exc:
        acquire(tmp_path, policy, transport)

    assert not (tmp_path / "acquired").exists()
    assert exc.value.cleanup_remaining == ()
    assert exc.value.destination == str(tmp_path / "acquired")


def test_cleanup_preserves_untracked_content_and_reports_destination(tmp_path):
    policy, _ = controlled_policy()

    def inject_unrelated_content(source, asset, target, deadline):
        (target.parent.parent / "unrelated").write_text(
            "preserve", encoding="utf-8"
        )
        raise acquisition.AcquisitionError("source_integrity_mismatch", "stop")

    with pytest.raises(acquisition.AcquisitionError) as exc:
        acquire(tmp_path, policy, ScriptedTransport([inject_unrelated_content]))

    destination = tmp_path / "acquired"
    assert exc.value.cleanup_remaining == (str(destination),)
    assert (destination / "unrelated").read_text(encoding="utf-8") == "preserve"
    assert list(destination.iterdir()) == [destination / "unrelated"]


def test_disk_write_failure_reports_error_and_cleans(tmp_path, monkeypatch):
    policy, contents = controlled_policy()

    def fail_write(source, asset, target, deadline):
        raise OSError("disk full")

    transport = ScriptedTransport([fail_write])

    with pytest.raises(acquisition.AcquisitionError) as exc:
        acquire(tmp_path, policy, transport)

    assert exc.value.code == "write_failed"
    assert not (tmp_path / "acquired").exists()


def test_never_returns_mapping_after_second_asset_failure(tmp_path):
    policy, contents = controlled_policy()
    transport = ScriptedTransport(
        [
            contents["controlled-model.ckpt"],
            acquisition.AcquisitionError(
                "source_integrity_mismatch", "bad configuration"
            ),
        ]
    )

    with pytest.raises(acquisition.AcquisitionError):
        acquire(tmp_path, policy, transport)

    assert not (tmp_path / "acquired").exists()


@pytest.mark.skipif(
    not CAN_CREATE_FILE_SYMLINK, reason="requires unprivileged symlink creation"
)
def test_substituted_staged_source_is_preserved_and_not_followed(tmp_path):
    policy, contents = controlled_policy()
    victim = tmp_path / "external-matching-content"
    victim.write_bytes(contents["controlled-model.ckpt"])

    def substitute_first_asset(source, asset, target, deadline):
        first = target.parent / "controlled-model.ckpt.part"
        first.unlink()
        first.symlink_to(victim)
        target.write_bytes(contents[asset.name])

    transport = ScriptedTransport(
        [contents["controlled-model.ckpt"], substitute_first_asset]
    )

    with pytest.raises(acquisition.AcquisitionError) as exc:
        acquire(tmp_path, policy, transport)

    substituted = next((tmp_path / "acquired").glob(".stemwerk-acquisition-stage-*"))
    substituted /= "controlled-model.ckpt.part"
    assert exc.value.code == "path_substituted"
    assert substituted.is_symlink()
    assert victim.read_bytes() == contents["controlled-model.ckpt"]
    assert str(substituted) in exc.value.cleanup_remaining


def test_real_https_second_asset_integrity_failure_cleans_owned_destination(
    tmp_path, local_https_server
):
    policy, contents = controlled_policy()

    class AssetHandler(QuietHandler):
        def do_GET(self):
            if self.path == "/checkpoint":
                body = contents["controlled-model.ckpt"]
            elif self.path == "/yaml":
                body = b"X" * len(contents["controlled-model.yaml"])
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True

    factory, context, _ = local_https_server(AssetHandler)
    local_assets = tuple(
        acquisition._AssetSpec(
            name=asset.name,
            sha256=asset.sha256,
            size=asset.size,
            sources=(
                acquisition._SourceSpec(
                    source_id="local",
                    url=(
                        "https://localhost/checkpoint"
                        if asset.name.endswith(".ckpt")
                        else "https://localhost/yaml"
                    ),
                    redirect_hosts=("localhost",),
                ),
            ),
            attempt_timeout=2,
            total_timeout=3,
        )
        for asset in policy.assets
    )
    local_policy = acquisition._AcquisitionPolicy("tests.local", local_assets)
    destination = tmp_path / "acquired"

    with pytest.raises(acquisition.AcquisitionError) as exc:
        acquisition._acquire_asset_set(
            acquisition.AcquisitionRequest(destination),
            local_policy,
            transport=acquisition._HttpsTransport(
                connection_factory=factory, ssl_context=context
            ),
        )

    assert exc.value.code == "source_integrity_mismatch"
    assert not destination.exists()
    assert exc.value.cleanup_remaining == ()


def test_real_https_unavailable_primary_uses_one_shared_fallback_attempt(
    tmp_path, local_https_server
):
    content = b"controlled fallback body"
    requests = []

    class FallbackHandler(QuietHandler):
        def do_GET(self):
            requests.append(self.path)
            if self.path == "/primary":
                self.send_response(404)
                body = b""
            else:
                self.send_response(200)
                body = content
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True

    factory, context, _ = local_https_server(FallbackHandler)
    asset = acquisition._AssetSpec(
        name="asset.bin",
        sha256=sha256(content),
        size=len(content),
        sources=(
            acquisition._SourceSpec(
                "primary", "https://localhost/primary", ("localhost",)
            ),
            acquisition._SourceSpec(
                "fallback", "https://localhost/fallback", ("localhost",)
            ),
        ),
        attempt_timeout=2,
        total_timeout=3,
    )
    waits = []

    result = acquisition._acquire_asset_set(
        acquisition.AcquisitionRequest(tmp_path / "acquired"),
        acquisition._AcquisitionPolicy("tests.local-fallback", (asset,)),
        transport=acquisition._HttpsTransport(
            connection_factory=factory, ssl_context=context
        ),
        sleeper=waits.append,
    )

    assert requests == ["/primary", "/fallback"]
    assert waits == []
    assert result["assets"][0]["attempts"] == 2
    assert result["assets"][0]["source_id"] == "fallback"


@pytest.mark.native_publication
def test_every_descriptor_open_requests_binary_mode(
    tmp_path, local_https_server, monkeypatch
):
    policy, contents = controlled_policy()

    class AssetHandler(QuietHandler):
        def do_GET(self):
            body = contents.get(self.path.lstrip("/"))
            if body is None:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            self.close_connection = True

    factory, context, _ = local_https_server(AssetHandler)
    local_policy = acquisition._AcquisitionPolicy(
        "tests.local",
        tuple(
            acquisition._AssetSpec(
                name=asset.name,
                sha256=asset.sha256,
                size=asset.size,
                sources=(
                    acquisition._SourceSpec(
                        source_id="local",
                        url=f"https://localhost/{asset.name}",
                        redirect_hosts=("localhost",),
                    ),
                ),
                attempt_timeout=2,
                total_timeout=3,
            )
            for asset in policy.assets
        ),
    )
    sentinel = 1 << 30
    real_binary = getattr(os, "O_BINARY", 0)
    real_open = os.open
    recorded = []

    def recording_open(path, flags, *args, **kwargs):
        recorded.append((Path(path).name, flags))
        return real_open(path, (flags & ~sentinel) | real_binary, *args, **kwargs)

    monkeypatch.setattr(os, "O_BINARY", sentinel, raising=False)
    monkeypatch.setattr(os, "open", recording_open)

    result = acquisition._acquire_asset_set(
        acquisition.AcquisitionRequest(tmp_path / "acquired"),
        local_policy,
        transport=acquisition._HttpsTransport(
            connection_factory=factory, ssl_context=context
        ),
    )

    # Per asset: partial create, HTTPS body write, verify read, staged-source
    # read and final-target create all go through os.open.
    creates = [item for item in recorded if item[1] & os.O_CREAT]
    writes = [
        item
        for item in recorded
        if item[1] & os.O_WRONLY and not item[1] & os.O_CREAT
    ]
    reads = [item for item in recorded if not item[1] & os.O_WRONLY]
    assert len(creates) >= 4 and len(writes) >= 2 and len(reads) >= 4
    assert [name for name, flags in recorded if not flags & sentinel] == []
    for name, content in contents.items():
        assert Path(result["sources"][name]).read_bytes() == content


@pytest.mark.native_publication
def test_acquired_mapping_feeds_existing_materializer(tmp_path):
    policy, contents = controlled_policy()
    acquired = acquire(
        tmp_path,
        policy,
        ScriptedTransport([contents[name] for name in contents]),
    )
    materialization_policy = materialization._TrustedAssetPolicy(
        policy_id="tests.controlled",
        assets=tuple((asset.name, asset.sha256) for asset in policy.assets),
    )
    request = materialization.MaterializationRequest(
        sources=acquired["sources"],
        destination=tmp_path / "published",
    )

    result = materialization._materialize_asset_set(request, materialization_policy)

    assert result["outcome"] == "success"
    assert result["destination"] == str(tmp_path / "published")
    for name, content in contents.items():
        assert (tmp_path / "published" / name).read_bytes() == content


def test_cli_rejects_relative_destination_without_network(capsys):
    status = acquisition.main(["--destination", "relative/path"])

    captured = capsys.readouterr()
    assert status == 2
    error = json.loads(captured.err)
    assert error["kind"] == "stemwerk_asset_acquisition_error"
    assert error["error"]["code"] == "invalid_path"
    assert captured.out == ""


LEAKY_INTERNAL_MESSAGE = "boom https://user:secret@example.invalid/x?token=SECRET"


def _key_shape(document):
    if isinstance(document, dict):
        return {key: _key_shape(value) for key, value in document.items()}
    return None


@pytest.mark.parametrize("error_type", [RuntimeError, TypeError])
def test_cli_unexpected_exception_is_a_redacted_internal_error(
    monkeypatch, tmp_path, capsys, error_type
):
    def fail(request):
        error = error_type(LEAKY_INTERNAL_MESSAGE)
        if hasattr(error, "add_note"):
            error.add_note(LEAKY_INTERNAL_MESSAGE)
        raise error

    monkeypatch.setattr(acquisition, "acquire_drumsep_sources", fail)
    destination = str(tmp_path / "published")

    status = acquisition.main(["--destination", destination])

    captured = capsys.readouterr()
    assert status == 3
    assert captured.out == ""
    document = json.loads(captured.err)
    handled = acquisition._error_payload(acquisition.AcquisitionError("code", "message"))
    assert _key_shape(document) == _key_shape(handled)
    assert document["kind"] == "stemwerk_asset_acquisition_error"
    assert document["schema_version"] == acquisition.SCHEMA_VERSION
    assert document["outcome"] == "error"
    assert document["destination"] == destination
    assert document["error"] == {
        "code": "internal_error",
        "message": f"unexpected internal error ({error_type.__name__})",
    }
    assert document["cleanup"] == {"complete": None, "remaining_paths": None}
    assert document["materialization"] == {"performed": False, "published": False}
    for leaked in ("secret", "SECRET", "token", "example.invalid", "boom"):
        assert leaked not in captured.err


def test_cli_keyboard_interrupt_is_not_converted(monkeypatch, tmp_path, capsys):
    def interrupt(request):
        raise KeyboardInterrupt

    monkeypatch.setattr(acquisition, "acquire_drumsep_sources", interrupt)

    with pytest.raises(KeyboardInterrupt):
        acquisition.main(["--destination", str(tmp_path / "published")])

    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err == ""


def _internal_error_document(monkeypatch, tmp_path, capsys, error):
    def fail(request):
        raise error

    monkeypatch.setattr(acquisition, "acquire_drumsep_sources", fail)

    status = acquisition.main(["--destination", str(tmp_path / "published")])

    captured = capsys.readouterr()
    assert status == 3
    assert captured.out == ""
    for leaked in ("secret", "SECRET", "token", "example.invalid", "boom"):
        assert leaked not in captured.err
    return json.loads(captured.err)


def test_cli_internal_error_lists_the_recorded_remaining_paths(
    monkeypatch, tmp_path, capsys
):
    remaining = (str(tmp_path / "published" / "stage"), str(tmp_path / "published"))
    error = RuntimeError(LEAKY_INTERNAL_MESSAGE)
    error.cleanup_remaining = remaining
    if hasattr(error, "add_note"):
        error.add_note(LEAKY_INTERNAL_MESSAGE)

    document = _internal_error_document(monkeypatch, tmp_path, capsys, error)

    assert document["error"]["code"] == "internal_error"
    assert document["cleanup"] == {"complete": None, "remaining_paths": list(remaining)}


def test_cli_internal_error_reports_the_real_cleanup_result(monkeypatch, tmp_path, capsys):
    class FailingTransport:
        def __init__(self, **kwargs):
            pass

        def download(self, *args, **kwargs):
            raise RuntimeError(LEAKY_INTERNAL_MESSAGE)

    monkeypatch.setattr(acquisition, "_HttpsTransport", FailingTransport)
    destination = tmp_path / "published"

    status = acquisition.main(["--destination", str(destination)])

    captured = capsys.readouterr()
    assert status == 3
    assert captured.out == ""
    for leaked in ("secret", "SECRET", "token", "example.invalid", "boom"):
        assert leaked not in captured.err
    document = json.loads(captured.err)
    assert document["error"]["code"] == "internal_error"
    assert document["cleanup"] == {"complete": None, "remaining_paths": []}
    assert not destination.exists()


@pytest.mark.parametrize(
    "recorded",
    [
        pytest.param(["/a"], id="list"),
        pytest.param("/a", id="string"),
        pytest.param(("/a", 1), id="non-string-item"),
        pytest.param(None, id="none"),
    ],
)
def test_cli_internal_error_ignores_malformed_remaining_paths(
    monkeypatch, tmp_path, capsys, recorded
):
    error = RuntimeError(LEAKY_INTERNAL_MESSAGE)
    error.cleanup_remaining = recorded

    document = _internal_error_document(monkeypatch, tmp_path, capsys, error)

    assert document["cleanup"] == {"complete": None, "remaining_paths": None}


def test_cli_help_does_not_contact_network(capsys):
    with pytest.raises(SystemExit) as exc:
        acquisition.main(["--help"])

    assert exc.value.code == 0
    assert "--destination" in capsys.readouterr().out
