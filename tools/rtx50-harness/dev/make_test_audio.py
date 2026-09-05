"""Generates a short synthetic stereo WAV file for a real separation smoke
test. Content doesn't need to sound like real music - htdemucs runs the
same CUDA kernels regardless of input; this just needs to be a valid
stereo audio file long enough to exercise real model inference.
"""
import sys
import numpy as np
import soundfile as sf

out_path = sys.argv[1] if len(sys.argv) > 1 else "test_input.wav"
sr = 44100
duration_s = 6.0
t = np.linspace(0, duration_s, int(sr * duration_s), endpoint=False)

# A few overlapping tones plus light noise, roughly emulating "bass + lead +
# percussion" spectral content so the separator has more than pure silence
# to work with.
bass = 0.25 * np.sin(2 * np.pi * 110 * t)
lead = 0.2 * np.sin(2 * np.pi * 440 * t) * (0.5 + 0.5 * np.sin(2 * np.pi * 2 * t))
click_times = (np.arange(0, duration_s, 0.5) * sr).astype(int)
perc = np.zeros_like(t)
for idx in click_times:
    end = min(idx + 200, len(perc))
    perc[idx:end] += np.hanning(end - idx) * 0.6
noise = 0.02 * np.random.RandomState(42).randn(len(t))

mono = bass + lead + perc + noise
left = mono * 0.9
right = mono * 0.85 + 0.05 * np.sin(2 * np.pi * 220 * t)

stereo = np.stack([left, right], axis=1).astype(np.float32)
stereo = np.clip(stereo, -1.0, 1.0)

sf.write(out_path, stereo, sr, subtype="PCM_16")
print(f"wrote {out_path}: {duration_s}s stereo @ {sr}Hz")
