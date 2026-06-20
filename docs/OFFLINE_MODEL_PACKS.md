# Offline Model Packs (Fast, Quality, 6-Stem, All)

This guide defines a repeatable release flow for four offline model packs:

- Fast (`htdemucs`)
- Quality (`htdemucs_ft`)
- 6-Stem (`htdemucs_6s`)
- All (combined)

These packs are Demucs/core stem model cache files only. They are not installers, not bundled installers, and not complete offline/full installers. They do not include DrumSep/Drum Kit models, DrumSep CKPT/YAML assets, or backend runtime/bootstrap dependencies.

## 1) Target zip naming

- `STEMwerk-Model-Pack-Fast-v<version>.zip`
- `STEMwerk-Model-Pack-Quality-v<version>.zip`
- `STEMwerk-Model-Pack-6-Stem-v<version>.zip`
- `STEMwerk-Model-Pack-All-v<version>.zip`

Each zip contains one top-level folder:

- `STEMwerk-Model-Pack-<Name>/models/...`
- `STEMwerk-Model-Pack-<Name>/INSTALL.md`
- `STEMwerk-Model-Pack-<Name>/PACK_INFO.json`

## 2) Cache destination paths (offline machine)

Copy pack contents to the STEMwerk model cache path:

- Windows: `%LOCALAPPDATA%\\STEMwerk\\models`
- macOS: `~/Library/Application Support/STEMwerk/models`
- Linux (preferred): `$XDG_DATA_HOME/STEMwerk/models`
- Linux fallback: `~/.local/share/STEMwerk/models`

If a custom path is used, set environment variable `AUDIO_SEPARATOR_MODEL_DIR`.

## 3) Prepare staging folders on an online prep machine

Create this staging structure:

```text
staging/
  fast/models/
  quality/models/
  sixstem/models/
  all/models/   (optional)
```

Recommended workflow:

1. Set `AUDIO_SEPARATOR_MODEL_DIR` to one pack-specific `models` folder.
2. Run one short separation with that model to force download into that folder.
3. Repeat for Fast, Quality, and 6-Stem.
4. Optional: build `all/models` explicitly by warming all three models into one folder.

Tip: if you skip `all/models`, the builder script can synthesize All by merging the other three packs.

## 4) Build all four zip files

Run:

```bash
python tools/build_model_packs.py \
  --staging-root /path/to/staging \
  --output-dir /path/to/release/model-packs \
  --version 2.2.2
```

If you want to require a manually prepared `staging/all/models`:

```bash
python tools/build_model_packs.py \
  --staging-root /path/to/staging \
  --output-dir /path/to/release/model-packs \
  --version 2.2.2 \
  --require-all-source
```

## 5) Offline install instructions to publish with packs

Use this short text for users:

1. Install STEMwerk first.
2. Download the matching model pack zip.
3. Extract the zip.
4. Copy files from `models/` to your OS-specific STEMwerk model cache path.
5. Open REAPER and run STEMwerk using that model.

## 6) QA checklist before release

1. Test each zip on Windows, macOS, Linux.
2. Verify model loads without internet.
3. Confirm first separation succeeds for each pack.
4. Confirm `All` includes files needed by Fast, Quality, and 6-Stem.
5. Publish SHA256 checksums next to zip downloads.
