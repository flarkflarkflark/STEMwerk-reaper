"""Check shipped managed-Python pins against the vendor's release each week.

The SHA256SUMS file is the checksum authority. Asset HEAD verifies that the
shipped URL remains reachable and that its byte length still matches.
"""

from __future__ import annotations

from pathlib import Path
import sys
from urllib.parse import unquote, urlsplit
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/reaper/vendor/stemwerk-core/src"))
from stemwerk_core import runtime_manifest  # noqa: E402


def _request(url: str, method: str = "GET"):
    try:
        with urlopen(Request(url, method=method, headers={"User-Agent": "STEMwerk-pin-check/1"}), timeout=45) as response:
            return response.read() if method == "GET" else (response.status, response.headers)
    except Exception:
        # A redirect may contain a short-lived signed query string. Keep it
        # out of CI tracebacks even when the upstream request fails.
        raise RuntimeError("vendor pin request failed") from None


def check_checksum(record: runtime_manifest.RuntimeRecord, checksums: dict[str, str]) -> None:
    filename = unquote(urlsplit(record.url).path.rsplit("/", 1)[-1])
    if checksums.get(filename) != record.sha256:
        raise ValueError(f"{record.platform}: vendor checksum differs from shipped pin")


def main() -> int:
    records = runtime_manifest.load_manifest()
    builds = {record.build for record in records}
    if len(builds) != 1:
        raise ValueError("managed Python records have different build dates")
    build = builds.pop()
    source = runtime_manifest.PBS_DOWNLOAD_BASE + build + "/SHA256SUMS"
    lines = _request(source).decode("ascii").splitlines()
    checksums = {filename: digest for digest, filename in (line.split("  ", 1) for line in lines)}
    for record in records:
        check_checksum(record, checksums)
        status, headers = _request(record.url, "HEAD")
        if status != 200 or int(headers.get("Content-Length", "-1")) != record.size:
            raise ValueError(f"{record.platform}: vendor asset URL or byte length differs from shipped pin")
        print(f"{record.platform}: URL, size and SHA-256 pin match")
    # Exercise the same comparison with a deliberately broken pin. This must
    # fail, or the scheduled gate's checksum comparison is ineffective.
    from dataclasses import replace

    broken = replace(records[0], sha256="0" * 64)
    try:
        check_checksum(broken, checksums)
    except ValueError:
        print("broken-pin self-test: rejected")
    else:
        raise ValueError("broken-pin self-test unexpectedly passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
