from __future__ import annotations

import re
import subprocess
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
MACOS_METADATA_PATTERN = re.compile(
    r"(^|/)\._[^/]*$|(^|/)\.DS_Store$|(^|/)__MACOSX(/|$)"
)


def test_repository_has_no_tracked_macos_metadata() -> None:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=REPOSITORY_ROOT,
        check=True,
        stdout=subprocess.PIPE,
    )
    tracked_paths = [
        path.decode("utf-8", errors="surrogateescape")
        for path in result.stdout.split(b"\0")
        if path
    ]
    violations = sorted(
        path for path in tracked_paths if MACOS_METADATA_PATTERN.search(path)
    )

    assert not violations, (
        "Tracked macOS metadata artifacts must be removed:\n"
        + "\n".join(violations)
    )
