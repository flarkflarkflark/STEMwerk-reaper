#!/usr/bin/env python3
"""Simple wrapper to call the Demucs CLI for STEMwerk.

This script finds the `demucs` CLI on PATH and invokes it with sensible defaults.
Edit or call with `--model` and `--out` as needed.
"""
from __future__ import annotations
import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def build_cmd(demucs_exe: str, model: str, out: str, input_path: str) -> list[str]:
    return [demucs_exe, "-n", model, "-o", out, input_path]


def main() -> int:
    p = argparse.ArgumentParser(description="Run Demucs separation (wrapper)")
    p.add_argument("input", help="Input audio file (wav, mp3, etc.)")
    p.add_argument("-o", "--out", default="separated", help="Output directory")
    p.add_argument("-m", "--model", default="htdemucs", help="Demucs model name (htdemucs, demucs, etc.)")
    args = p.parse_args()

    demucs_exe = shutil.which("demucs")
    if not demucs_exe:
        print("demucs CLI not found on PATH. Install with: python -m pip install demucs", file=sys.stderr)
        return 2

    inp = str(Path(args.input))
    out = str(Path(args.out))
    cmd = build_cmd(demucs_exe, args.model, out, inp)

    print("Running:", " ".join(cmd))
    try:
        rc = subprocess.call(cmd)
    except OSError as e:
        print("Failed to run demucs:", e, file=sys.stderr)
        return 3
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
