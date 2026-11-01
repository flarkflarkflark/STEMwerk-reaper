"""CLI stream JSON is ASCII-only, so it survives any console or pipe code page.

A Windows pipe uses the locale code page. PYTHONIOENCODING sets that code
page in the child on every OS, so each runner exercises the Windows case:
characters outside the code page must not end the process with exit 1, and
characters inside it must not reach a UTF-8 reader as legacy bytes.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import sys

import pytest

ROOT = Path(__file__).resolve().parents[1]
CORE_SRC = ROOT / "scripts/reaper/vendor/stemwerk-core/src"
sys.path.insert(0, str(CORE_SRC))

from tests.cli_harness import run_cli, single_json_line  # noqa: E402

pytestmark = pytest.mark.portable

# Composed and decomposed Latin, Cyrillic, CJK and a non-BMP character.
TEXT = "Testger\u00e4t be\u00f1at e\u0301 \u041f\u0440\u0438\u0432\u0435\u0442 \u6587\u5b57 \U0001F39B"
SURROGATE_PAIR = b"\\ud83c\\udf9b"
DESTINATION = os.path.join(os.sep, "Users", TEXT, "STEMwerk")
CODE_PAGES = ["cp1252", "cp850", "cp437"]
EXIT_CODES = {"success": 0, "handled": 2, "internal": 3}

ASSET_CHILD = """
import importlib
import sys

sys.path.insert(0, sys.argv[1])
module = importlib.import_module(sys.argv[2])
api, kind, text = sys.argv[3], sys.argv[4], sys.argv[5]


def handled_error():
    name = module.__name__.rsplit(".", 1)[1]
    if name == "asset_materialization":
        return module.MaterializationError("invalid_path", text, destination=text)
    if name == "asset_acquisition":
        return module.AcquisitionError("invalid_destination", text, destination=text)
    return module.PreparationError(
        "invalid_destination", text, phase="validation", source_mode=None,
        acquisition_completed=False, publication_state="not_started", destination=text,
    )


def replacement(*args, **kwargs):
    if kind == "success":
        return {"outcome": "success", "detail": text, "paths": [text]}
    if kind == "handled":
        raise handled_error()
    raise type(text, (RuntimeError,), {})("internal detail")


setattr(module, api, replacement)
raise SystemExit(module.main(sys.argv[6:]))
"""

MODULE_INSTALL_CHILD = """
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from stemwerk_core import module_install
from stemwerk_core import module_verify as mv

kind, text = sys.argv[2], sys.argv[3]
if kind == "success":
    mv.NoRegistryLookup.locate = lambda self, module_id, component_id: (
        mv.ComponentLocation(Path(text)) if component_id == "ffmpeg" else None
    )
elif kind == "internal":
    def fail(*args, **kwargs):
        raise type(text, (RuntimeError,), {})("internal detail")

    mv.verify_module = fail
raise SystemExit(module_install.main(sys.argv[4:]))
"""

ASSET_CLIS = {
    "materialization": (
        "stemwerk_core.asset_materialization",
        "materialize_drumsep_assets",
        ["--checkpoint-source", DESTINATION + ".ckpt", "--config-source",
         DESTINATION + ".yaml", "--destination", DESTINATION],
    ),
    "acquisition": (
        "stemwerk_core.asset_acquisition",
        "acquire_drumsep_sources",
        ["--destination", DESTINATION],
    ),
    "preparation": (
        "stemwerk_core.asset_preparation",
        "prepare_drumsep_assets",
        ["--destination", DESTINATION, "--acquire"],
    ),
}


def _strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield key
            yield from _strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from _strings(item)


def _check(result, kind):
    assert result.returncode == EXIT_CODES[kind], result.stderr
    written, other = (result.stdout, result.stderr) if kind == "success" else (result.stderr, result.stdout)
    assert other == b""
    assert written.isascii(), written
    assert SURROGATE_PAIR in written
    document = single_json_line(written)
    strings = set(_strings(document))
    if kind == "internal":
        assert f"unexpected internal error ({TEXT})" in strings
    else:
        assert TEXT in strings
    return document


@pytest.mark.native_publication
@pytest.mark.parametrize("code_page", CODE_PAGES)
@pytest.mark.parametrize("kind", sorted(EXIT_CODES))
@pytest.mark.parametrize("cli", sorted(ASSET_CLIS))
def test_asset_cli_json_is_ascii_on_any_code_page(cli, kind, code_page):
    module, api, arguments = ASSET_CLIS[cli]
    result = run_cli(
        ["-c", ASSET_CHILD, str(CORE_SRC), module, api, kind, TEXT, *arguments],
        extra_env={"PYTHONIOENCODING": code_page},
    )
    document = _check(result, kind)
    if kind == "internal":
        assert DESTINATION in set(_strings(document))


@pytest.mark.native_publication
@pytest.mark.parametrize("code_page", CODE_PAGES)
@pytest.mark.parametrize("kind", sorted(EXIT_CODES))
def test_module_install_json_is_ascii_on_any_code_page(kind, code_page):
    module_id = TEXT if kind == "handled" else "drum_kit"
    result = run_cli(
        ["-c", MODULE_INSTALL_CHILD, str(CORE_SRC), kind, TEXT, "verify", "--module", module_id],
        extra_env={"PYTHONIOENCODING": code_page},
    )
    document = _check(result, kind)
    if kind == "success":
        assert document["installation_state"] == "unknown"
        ffmpeg = next(c for c in document["components"] if c["component_id"] == "ffmpeg")
        assert ffmpeg["location"] == str(Path(TEXT))
    if kind == "handled":
        assert document["error"] == {
            "code": "unknown_module",
            "message": f"unknown module {TEXT!r}",
            "module": TEXT,
        }


@pytest.mark.native_publication
@pytest.mark.parametrize("code_page", CODE_PAGES)
def test_module_install_describe_is_ascii_on_any_code_page(code_page):
    result = run_cli(
        ["-m", "stemwerk_core.module_install", "--describe"],
        extra_env={"PYTHONIOENCODING": code_page},
    )
    assert result.returncode == 0
    assert result.stdout.isascii()
    assert single_json_line(result.stdout)["kind"] == "stemwerk_install_capabilities"


PREVIEW_CHILD = """
import sys

sys.path.insert(0, sys.argv[1])
from stemwerk_core import installation_plan

text = sys.argv[2]
installation_plan.preview_installation = lambda *args, **kwargs: {
    "outcome": "success", "detail": text, "paths": [text]
}
raise SystemExit(installation_plan.main(sys.argv[3:]))
"""


@pytest.mark.native_publication
@pytest.mark.parametrize("code_page", CODE_PAGES)
@pytest.mark.parametrize("pretty", [False, True])
def test_installation_preview_json_is_ascii_on_any_code_page(pretty, code_page):
    arguments = ["--module", "drum_kit", "--device", "cpu"] + (["--pretty"] if pretty else [])
    result = run_cli(
        ["-c", PREVIEW_CHILD, str(CORE_SRC), TEXT, *arguments],
        extra_env={"PYTHONIOENCODING": code_page},
    )
    assert result.returncode == 0, result.stderr
    assert result.stderr == b""
    assert result.stdout.isascii()
    assert SURROGATE_PAIR in result.stdout
    document = json.loads(result.stdout) if pretty else single_json_line(result.stdout)
    assert document == {"outcome": "success", "detail": TEXT, "paths": [TEXT]}


def test_ascii_escaping_restores_every_test_string_exactly():
    text = json.dumps({"t": TEXT}, ensure_ascii=True)
    assert text.isascii()
    assert json.loads(text)["t"] == TEXT
    assert "e\u0301" in json.loads(text)["t"]  # decomposed form kept
    assert "\\ud83c\\udf9b" in text  # non-BMP as a surrogate pair
