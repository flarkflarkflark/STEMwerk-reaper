Examples
========

Quick tests and examples for `scripts/reaper/audio_separator_process.py`.

1) List models (fast, safe for CI):

```bash
python scripts/reaper/audio_separator_process.py --list-models
```

2) Check installation (may require GPU and audio-separator):

```bash
python scripts/reaper/audio_separator_process.py --check
```

3) Run separation locally (example):

```bash
python scripts/reaper/audio_separator_process.py examples/input.wav separated_out --model htdemucs --device auto
```

Note: Provide your own `examples/input.wav` for testing. The CI workflow runs the quick `--list-models` check only.
