"""Minimal Julius compatibility module for offline STEMwerk installs.

Only the API required by Demucs in audio-separator is implemented.
"""

from __future__ import annotations

import math

import torch
import torch.nn.functional as F


def resample_frac(x: torch.Tensor, old_sr: int, new_sr: int) -> torch.Tensor:
    """Resample along the last axis using a fractional sample-rate ratio.

    This compatibility implementation uses linear interpolation and supports
    tensors with arbitrary leading dimensions.
    """
    if old_sr <= 0 or new_sr <= 0:
        raise ValueError("old_sr and new_sr must be positive")
    if old_sr == new_sr:
        return x

    if not isinstance(x, torch.Tensor):
        raise TypeError("x must be a torch.Tensor")

    src_len = int(x.shape[-1])
    if src_len <= 0:
        return x

    dst_len = max(1, int(math.ceil(src_len * float(new_sr) / float(old_sr))))
    lead_shape = x.shape[:-1]

    y = x
    original_dtype = y.dtype
    if not torch.is_floating_point(y):
        y = y.float()

    y = y.reshape(1, -1, src_len)
    y = F.interpolate(y, size=dst_len, mode="linear", align_corners=False)
    y = y.reshape(*lead_shape, dst_len)

    if torch.is_floating_point(torch.empty((), dtype=original_dtype)):
        y = y.to(original_dtype)
    return y
