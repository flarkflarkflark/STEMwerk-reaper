#!/usr/bin/env python3
"""Matcher and twenty regression guards for macOS nm -u evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path


EXPECTED_SYMBOLS = {"arm64": "_statfs", "x86_64": "_statfs$INODE64"}
SYMBOL_TOKEN = re.compile(r"[A-Za-z_.$][A-Za-z0-9_.$]*\Z")


class SymbolEvidenceError(RuntimeError):
    pass


def normalize_undefined_symbols(raw: str) -> list[str]:
    symbols: list[str] = []
    for line_number, raw_line in enumerate(raw.splitlines(), start=1):
        stripped = raw_line.strip()
        if not stripped:
            continue
        tokens = stripped.split()
        if len(tokens) == 1 and tokens[0] != "U":
            symbol = tokens[0]
        elif len(tokens) == 2 and tokens[0] == "U":
            symbol = tokens[1]
        else:
            raise SymbolEvidenceError(f"unknown nm -u layout at line {line_number}")
        if not SYMBOL_TOKEN.fullmatch(symbol):
            raise SymbolEvidenceError(f"invalid symbol token at line {line_number}")
        symbols.append(symbol)
    if not symbols:
        raise SymbolEvidenceError("nm -u output contains no symbol records")
    return symbols


def match_undefined_symbol(raw: str, architecture: str) -> dict[str, object]:
    try:
        expected = EXPECTED_SYMBOLS[architecture]
    except KeyError as error:
        raise SymbolEvidenceError(f"unsupported architecture: {architecture}") from error
    symbols = normalize_undefined_symbols(raw)
    match_count = sum(symbol == expected for symbol in symbols)
    if match_count == 0:
        raise SymbolEvidenceError(f"expected undefined symbol absent: {expected}")
    if match_count != 1:
        raise SymbolEvidenceError(f"ambiguous undefined symbol evidence: {expected}")
    return {
        "schema_version": 1,
        "architecture": architecture,
        "expected_symbol": expected,
        "normalized_undefined_symbols": symbols,
        "exact_match_count": match_count,
        "result": "PASS",
    }


def match_file(raw_path: Path, architecture: str, normalized_path: Path, summary_path: Path) -> dict[str, object]:
    raw_bytes = raw_path.read_bytes()
    raw = raw_bytes.decode("utf-8")
    result = match_undefined_symbol(raw, architecture)
    normalized_path.write_text("".join(f"{symbol}\n" for symbol in result["normalized_undefined_symbols"]))
    result["raw_sha256"] = hashlib.sha256(raw_bytes).hexdigest()
    summary_path.write_text(json.dumps(result, sort_keys=True, indent=2) + "\n")
    return result


class MacOSNmSymbolMatcherTests(unittest.TestCase):
    def accepted(self, raw: str, architecture: str, expected: str) -> None:
        result = match_undefined_symbol(raw, architecture)
        self.assertEqual(result["expected_symbol"], expected)
        self.assertEqual(result["result"], "PASS")

    def rejected(self, raw: str, architecture: str) -> None:
        with self.assertRaises(SymbolEvidenceError):
            match_undefined_symbol(raw, architecture)

    def test_01_arm64_bare_symbol(self):
        self.accepted("_statfs\n", "arm64", "_statfs")

    def test_02_arm64_u_prefix(self):
        self.accepted("U _statfs\n", "arm64", "_statfs")

    def test_03_arm64_padded_u_prefix(self):
        self.accepted("         U _statfs\n", "arm64", "_statfs")

    def test_04_arm64_tab_separator(self):
        self.accepted("U\t_statfs\n", "arm64", "_statfs")

    def test_05_x86_bare_symbol(self):
        self.accepted("_statfs$INODE64\n", "x86_64", "_statfs$INODE64")

    def test_06_x86_u_prefix(self):
        self.accepted("U _statfs$INODE64\n", "x86_64", "_statfs$INODE64")

    def test_07_arm64_rejects_inode64(self):
        self.rejected("_statfs$INODE64\n", "arm64")

    def test_08_x86_rejects_bare(self):
        self.rejected("_statfs\n", "x86_64")

    def test_09_rejects_lookalike_suffix(self):
        self.rejected("_statfs_extra\n", "arm64")

    def test_10_rejects_lookalike_prefix(self):
        self.rejected("foo_statfs\n", "arm64")

    def test_11_rejects_inode32(self):
        self.rejected("_statfs$INODE32\n", "x86_64")

    def test_12_rejects_inode64_suffix(self):
        self.rejected("_statfs$INODE64_extra\n", "x86_64")

    def test_13_rejects_empty_output(self):
        self.rejected(" \n\t\n", "arm64")

    def test_14_rejects_unknown_token_layout(self):
        self.rejected("T _statfs\n", "arm64")

    def test_15_rejects_ambiguous_matches(self):
        self.rejected("_statfs\nU _statfs\n", "arm64")

    def test_16_preserves_raw_output(self):
        with tempfile.TemporaryDirectory() as directory:
            raw = Path(directory) / "raw.txt"
            normalized = Path(directory) / "normalized.txt"
            summary = Path(directory) / "summary.json"
            original = "  U _statfs  \n"
            raw.write_text(original)
            match_file(raw, "arm64", normalized, summary)
            self.assertEqual(raw.read_text(), original)

    def test_17_trailing_whitespace(self):
        self.accepted("_statfs   \n", "arm64", "_statfs")

    def test_18_crlf_input(self):
        self.accepted("_statfs\r\n", "arm64", "_statfs")

    def test_19_lf_input(self):
        self.accepted("_statfs\n", "arm64", "_statfs")

    def test_20_previous_arm64_failure_fixture(self):
        self.accepted("_statfs\n", "arm64", "_statfs")


def main() -> int:
    if "--match" not in sys.argv:
        unittest.main(verbosity=2)
        return 0
    parser = argparse.ArgumentParser()
    parser.add_argument("--match", action="store_true")
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--arch", choices=tuple(EXPECTED_SYMBOLS), required=True)
    parser.add_argument("--normalized-output", type=Path, required=True)
    parser.add_argument("--summary-output", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        match_file(
            arguments.input,
            arguments.arch,
            arguments.normalized_output,
            arguments.summary_output,
        )
        return 0
    except (OSError, UnicodeError, SymbolEvidenceError) as error:
        print(f"NM_SYMBOL_MATCH=FAIL {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
