"""Check the shipped FFmpeg pin against the vendor's release each week.

Sister of ``check_managed_python_pins.py``; the workflow runs both. The vendor
publishes ``checksums.sha256`` with every release tag, so that file is the
checksum authority for the archive. Asset HEAD verifies that the shipped URL
remains reachable and that its byte length still matches.
"""

from __future__ import annotations

from dataclasses import replace
from pathlib import Path
import sys
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/reaper/vendor/stemwerk-core/src"))
from stemwerk_core import managed_ffmpeg  # noqa: E402


def _request(url: str, method: str = "GET"):
    try:
        with urlopen(Request(url, method=method, headers={"User-Agent": "STEMwerk-pin-check/1"}), timeout=45) as response:
            return response.read() if method == "GET" else (response.status, response.headers)
    except Exception:
        # A redirect may contain a short-lived signed query string. Keep it
        # out of CI tracebacks even when the upstream request fails.
        raise RuntimeError("vendor pin request failed") from None


def parse_checksums(text: str) -> dict[str, str]:
    """``digest  filename`` lines, as ``sha256sum`` writes them."""
    checksums: dict[str, str] = {}
    for line in text.splitlines():
        digest, separator, filename = line.partition("  ")
        if separator and digest and filename:
            checksums[filename.strip()] = digest.strip()
    return checksums


def check_checksum(pin: managed_ffmpeg.FFmpegPin, checksums: dict[str, str]) -> None:
    if checksums.get(pin.archive_name) != pin.archive_sha256:
        raise ValueError(f"{pin.platform}: vendor checksum differs from shipped pin")


def main() -> int:
    pin = managed_ffmpeg.load_pin("linux-x86_64")
    source = f"{managed_ffmpeg.DOWNLOAD_BASE}{pin.release_tag}/checksums.sha256"
    checksums = parse_checksums(_request(source).decode("ascii"))
    check_checksum(pin, checksums)
    status, headers = _request(pin.archive_url, "HEAD")
    if status != 200 or int(headers.get("Content-Length", "-1")) != pin.archive_size:
        raise ValueError(f"{pin.platform}: vendor asset URL or byte length differs from shipped pin")
    print(f"{pin.platform}: URL, size and SHA-256 pin match")
    # Exercise the same comparison with a deliberately broken pin. This must
    # fail, or the scheduled gate's checksum comparison is ineffective.
    broken = replace(pin, archive_sha256="0" * 64)
    try:
        check_checksum(broken, checksums)
    except ValueError:
        print("broken-pin self-test: rejected")
    else:
        raise ValueError("broken-pin self-test unexpectedly passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
