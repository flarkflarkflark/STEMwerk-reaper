"""Shared verdict vocabulary for STEMwerk diagnostics and readiness.

The five states are the exact vocabulary established by
``tools/stemwerk_runtime_diagnostics.py`` (which now imports them from
here). Do not rename or extend them accidentally.
"""

from __future__ import annotations

PASS = "PASS"
FAIL = "FAIL"
SKIPPED = "SKIPPED"
UNAVAILABLE = "UNAVAILABLE"
NOT_APPLICABLE = "NOT_APPLICABLE"


def combine_probe_statuses(*statuses: str) -> str:
    if FAIL in statuses:
        return FAIL
    if not statuses or UNAVAILABLE in statuses:
        return UNAVAILABLE
    if SKIPPED in statuses:
        return SKIPPED
    return PASS if all(status == PASS for status in statuses) else UNAVAILABLE
