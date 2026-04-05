#!/usr/bin/env python3
"""Build offline STEMwerk model packs as zip archives.

Expected staging layout:

    <staging-root>/
      fast/models/...      # warmed cache for htdemucs
      quality/models/...   # warmed cache for htdemucs_ft
      sixstem/models/...   # warmed cache for htdemucs_6s
      all/models/...       # optional; if missing it is synthesized from the 3 packs

Each generated zip contains:

    STEMwerk-Model-Pack-<Name>/
      models/...
      INSTALL.md
      PACK_INFO.json
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable
from zipfile import ZIP_DEFLATED, ZipFile


PACK_DEFS = {
    "fast": {
        "display": "Fast",
        "model": "htdemucs",
        "source_dir": "fast",
    },
    "quality": {
        "display": "Quality",
        "model": "htdemucs_ft",
        "source_dir": "quality",
    },
    "sixstem": {
        "display": "6-Stem",
        "model": "htdemucs_6s",
        "source_dir": "sixstem",
    },
    "all": {
        "display": "All",
        "model": "htdemucs + htdemucs_ft + htdemucs_6s",
        "source_dir": "all",
    },
}


@dataclass(frozen=True)
class PackMeta:
    key: str
    display: str
    model: str
    source_models_dir: Path

    @property
    def root_folder(self) -> str:
        return f"STEMwerk-Model-Pack-{self.display}"


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build offline STEMwerk model pack zip files")
    parser.add_argument(
        "--staging-root",
        required=True,
        help="Directory containing fast/quality/sixstem/(optional)all subfolders",
    )
    parser.add_argument(
        "--output-dir",
        required=True,
        help="Directory where zip packs will be written",
    )
    parser.add_argument(
        "--version",
        default="dev",
        help="Version label used in zip file names, e.g. 2.2.2",
    )
    parser.add_argument(
        "--require-all-source",
        action="store_true",
        help="Require staging/all/models to exist instead of synthesizing All from the other 3 packs",
    )
    return parser.parse_args()


def _collect_pack_meta(staging_root: Path) -> list[PackMeta]:
    packs: list[PackMeta] = []
    for key, cfg in PACK_DEFS.items():
        source_models_dir = staging_root / cfg["source_dir"] / "models"
        packs.append(
            PackMeta(
                key=key,
                display=cfg["display"],
                model=cfg["model"],
                source_models_dir=source_models_dir,
            )
        )
    return packs


def _assert_non_empty_models_dir(path: Path) -> None:
    if not path.exists() or not path.is_dir():
        raise FileNotFoundError(f"Missing models directory: {path}")
    if not any(path.iterdir()):
        raise FileNotFoundError(f"Models directory is empty: {path}")


def _copy_tree(src: Path, dst: Path) -> None:
    if dst.exists():
        shutil.rmtree(dst)
    shutil.copytree(src, dst)


def _merge_dirs(sources: Iterable[Path], destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for source in sources:
        for root, _, files in os.walk(source):
            rel_root = Path(root).relative_to(source)
            target_root = destination / rel_root
            target_root.mkdir(parents=True, exist_ok=True)
            for filename in files:
                src_file = Path(root) / filename
                dst_file = target_root / filename
                if dst_file.exists():
                    continue
                shutil.copy2(src_file, dst_file)


def _install_doc(pack_name: str, model_hint: str) -> str:
    return f"""# STEMwerk Model Pack: {pack_name}

Included model preset(s): {model_hint}

## Folder structure inside this pack

- models/

Copy the models folder contents into your local STEMwerk models cache.

## Destination paths per OS

- Windows: %LOCALAPPDATA%\\STEMwerk\\models
- macOS: ~/Library/Application Support/STEMwerk/models
- Linux: $XDG_DATA_HOME/STEMwerk/models (if XDG_DATA_HOME is set)
- Linux fallback: ~/.local/share/STEMwerk/models

## Install steps (offline machine)

1. Ensure STEMwerk is already installed on that machine.
2. Extract this zip file.
3. Copy everything from models/ into the OS-specific destination path above.
4. Start REAPER and launch STEMwerk.
5. Select the matching model preset and run a short test.

## Notes

- These packs contain model cache files only, not runtime/backend installers.
- Keep STEMwerk versions aligned between online prep machine and offline target machine.
- If you use a custom cache location, set AUDIO_SEPARATOR_MODEL_DIR to that path.
"""


def _zip_dir(src_dir: Path, zip_path: Path) -> None:
    with ZipFile(zip_path, "w", compression=ZIP_DEFLATED, compresslevel=9) as zf:
        for file_path in src_dir.rglob("*"):
            if file_path.is_file():
                arc_name = file_path.relative_to(src_dir)
                zf.write(file_path, arc_name.as_posix())


def _build_single_pack(output_dir: Path, version: str, pack: PackMeta, models_source: Path) -> Path:
    with tempfile.TemporaryDirectory(prefix=f"stemwerk-pack-{pack.key}-") as temp_dir:
        temp_root = Path(temp_dir)
        pack_root = temp_root / pack.root_folder
        pack_models = pack_root / "models"
        pack_root.mkdir(parents=True, exist_ok=True)

        _copy_tree(models_source, pack_models)

        install_text = _install_doc(pack.display, pack.model)
        (pack_root / "INSTALL.md").write_text(install_text, encoding="utf-8")

        manifest = {
            "pack": pack.display,
            "model_hint": pack.model,
            "version": version,
            "root_folder": pack.root_folder,
        }
        (pack_root / "PACK_INFO.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")

        zip_name = f"STEMwerk-Model-Pack-{pack.display}-v{version}.zip"
        zip_path = output_dir / zip_name
        _zip_dir(temp_root, zip_path)
        return zip_path


def main() -> int:
    args = _parse_args()

    staging_root = Path(args.staging_root).expanduser().resolve()
    output_dir = Path(args.output_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    packs = _collect_pack_meta(staging_root)

    for pack in packs:
        if pack.key == "all" and not args.require_all_source:
            continue
        _assert_non_empty_models_dir(pack.source_models_dir)

    all_meta = next(p for p in packs if p.key == "all")
    fast_meta = next(p for p in packs if p.key == "fast")
    quality_meta = next(p for p in packs if p.key == "quality")
    sixstem_meta = next(p for p in packs if p.key == "sixstem")

    fast_zip = _build_single_pack(output_dir, args.version, fast_meta, fast_meta.source_models_dir)
    quality_zip = _build_single_pack(output_dir, args.version, quality_meta, quality_meta.source_models_dir)
    sixstem_zip = _build_single_pack(output_dir, args.version, sixstem_meta, sixstem_meta.source_models_dir)

    if args.require_all_source:
        all_source = all_meta.source_models_dir
    else:
        with tempfile.TemporaryDirectory(prefix="stemwerk-pack-all-src-") as temp_dir:
            merged = Path(temp_dir) / "models"
            _merge_dirs(
                [fast_meta.source_models_dir, quality_meta.source_models_dir, sixstem_meta.source_models_dir],
                merged,
            )
            all_zip = _build_single_pack(output_dir, args.version, all_meta, merged)
        print(f"Created {fast_zip}")
        print(f"Created {quality_zip}")
        print(f"Created {sixstem_zip}")
        print(f"Created {all_zip}")
        return 0

    all_zip = _build_single_pack(output_dir, args.version, all_meta, all_source)
    print(f"Created {fast_zip}")
    print(f"Created {quality_zip}")
    print(f"Created {sixstem_zip}")
    print(f"Created {all_zip}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
