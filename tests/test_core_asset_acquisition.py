"""Portable tests for bounded DrumSep source acquisition."""
from __future__ import annotations

from collections import deque
import hashlib
import http.client
import http.server
import inspect
import json
import os
from pathlib import Path
import socket
import ssl
import sys
import threading
import time
import traceback

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(CORE_SRC))

from stemwerk_core import asset_acquisition as acquisition  # noqa: E402
from stemwerk_core import asset_materialization as materialization  # noqa: E402
from stemwerk_core import model_assets  # noqa: E402

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
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler_type)
        server.daemon_threads = True
        server.socket = server_context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        servers.append((server, thread))

        def connection_factory(host, port, timeout, context):
            assert host == "localhost"
            assert port == 443
            return http.client.HTTPSConnection(
                "localhost",
                server.server_address[1],
                timeout=timeout,
                context=context,
            )

        return connection_factory, client_context, server.server_address[1]

    yield start

    for server, thread in servers:
        server.shutdown()
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


@pytest.mark.skipif(
    not sys.platform.startswith("linux"),
    reason="materializer publication requires Linux renameat2",
)
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


def test_cli_help_does_not_contact_network(capsys):
    with pytest.raises(SystemExit) as exc:
        acquisition.main(["--help"])

    assert exc.value.code == 0
    assert "--destination" in capsys.readouterr().out
