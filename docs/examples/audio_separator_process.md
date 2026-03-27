# Audio Separator Process Examples

Quick CLI examples for `scripts/reaper/audio_separator_process.py`.

1. List models:

```bash
python scripts/reaper/audio_separator_process.py --list-models
```

2. Check the local runtime:

```bash
python scripts/reaper/audio_separator_process.py --check
```

3. Run a local separation:

```bash
python scripts/reaper/audio_separator_process.py path/to/input.wav separated_out --model htdemucs --device auto
```

Use your own input file. CI only runs the lightweight `--list-models` check.
