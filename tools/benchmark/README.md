# STEMwerk portable benchmark runner

Development and research tool for collecting comparable STEMwerk workflow
timings without using the REAPER GUI. This directory is not part of the public
release, installer, or ReaPack payload.

## Portable layout

Copy `tools/benchmark` into a portable folder and arrange it as:

```text
STEMwerk-Benchmark/
|-- audio/
|   |-- stemwerk-benchmark-30s.wav
|   |-- stemwerk-benchmark-2min.wav
|   `-- stemwerk-benchmark-4min.wav
|-- presets/
|-- runner/
|   `-- stemwerk_benchmark.py
|-- scripts/
`-- results/
```

No audio is included in the repository. Supply PCM WAV files with the exact
filenames above. For meaningful cross-system comparisons, use identical audio
content, sample rate, channel count, STEMwerk version, model cache, preset, and
device request on every machine.

## Usage

From the repository:

```bash
python tools/benchmark/stemwerk_benchmark.py \
  --input-dir /path/to/STEMwerk-Benchmark/audio \
  --preset tools/benchmark/presets/smoke.json \
  --output-dir /path/to/STEMwerk-Benchmark/results \
  --device auto
```

Plan commands without processing:

```bash
python tools/benchmark/stemwerk_benchmark.py \
  --input-dir /path/to/audio \
  --preset tools/benchmark/presets/full.json \
  --output-dir /path/to/results \
  --runs cold,warm \
  --workflow normal,dks_direct,dks_extract \
  --dry-run
```

The platform scripts accept additional runner arguments. Set
`STEMWERK_BENCHMARK_ROOT` to the portable folder and optionally set
`STEMWERK_BENCHMARK_PRESET` to `smoke`, `standard`, or `full`.

## Runtime use

The runner never installs or repairs STEMwerk. It detects these existing roots:

- Linux: `~/.local/share/STEMwerk`
- macOS: `~/Library/Application Support/STEMwerk`, then `/Users/Shared/STEMwerk`
- Windows: `%LOCALAPPDATA%\STEMwerk`

It uses the managed normal `.venv` Python and finds
`audio_separator_process.py` in this repository or the installed REAPER script
folder. Runtime state `.env` files and the model cache location are recorded in
`system_info.txt` and JSON output. GPU diagnostics are best-effort and never a
hard prerequisite.

## Workflows

- `normal`: headless Demucs through `audio_separator_process.py`.
- `dks_direct`: headless DrumSep MDX23C producing six drum outputs.
- `dks_extract`: headless two-stage Demucs drums extraction followed by
  DrumSep, producing six drum outputs.

Kit Split modes map to stage-one models:

- `Fast` -> `htdemucs`
- `Quality` -> `htdemucs_ft`
- `Expanded` -> `htdemucs_6s`

All processing writes below the timestamped result folder. A successful normal
run must report four outputs, or six for `htdemucs_6s`; DKS workflows must
report six. Output-count mismatch makes the benchmark row fail.

## Cold and warm

`cold` and `warm` are ordered run labels in v1. The runner does not flush OS
filesystem caches, GPU driver caches, or Python package caches. The first
process for a job is labeled cold and the following process warm so results
remain non-destructive and portable. Treat them as process-level first/repeat
measurements, not controlled hardware cold-cache measurements.

## Results

Each invocation creates:

```text
results/<hostname>-<timestamp>/
|-- benchmark_results.json
|-- benchmark_summary.csv
|-- benchmark_summary.md
|-- system_info.txt
|-- logs/
`-- outputs/
```

`--json-out`, `--csv-out`, and `--markdown-out` accept optional custom paths.
Per-run stdout and stderr are retained under `logs/`. The primary speed metric
is `x_realtime = duration_sec / wall_sec`.

## Limitations

- Benchmark v1 accepts WAV only.
- Results from different audio, models, runtime versions, caps, and device
  requests are not directly comparable.
- `--device gpu` depends on the installed runtime's normal device resolver.
- GPU detection text is diagnostic and may include integrated and discrete
  adapters.
- The runner does not currently sample power, temperature, VRAM, or startup
  sub-phases itself, although runtime logs may contain additional markers.
