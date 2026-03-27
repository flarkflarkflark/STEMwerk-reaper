from __future__ import annotations

from typing import Protocol


class ProgressCallback(Protocol):
    """Callback signature for progress updates."""

    def __call__(self, percent: float, message: str) -> None:
        ...
