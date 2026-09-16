# STEMwerk 2.3.1.2

## Scope

`2.3.1.2` is a Windows Blackwell hotfix release that also carries a set of
cross-platform DrumSep/Kit Split correctness fixes discovered and verified
during the same release-prep cycle. It descends linearly from `v2.3.1.1`
through seven commits; the initial Windows cu128 fix (`05e2c677`) is a
legitimate part of that chain, not contamination.

## Windows NVIDIA Blackwell (RTX 50-series) hotfix (issue #118)

- The Windows CUDA backend (Normal Stems and the separate Drum Kit Split CUDA
  runtime) now installs `torch==2.7.1+cu128` / `torchvision==0.22.1+cu128` /
  `torchaudio==2.7.1+cu128` (previously `2.4.1+cu121`), adding the compiled
  kernels Blackwell (sm_120) GPUs need. Windows CPU and DirectML keep their
  existing, independently-pinned torch stacks.
- Setup/Repair detects an existing `2.3.1.1`-era cu121 install and rebuilds it
  to the matched cu128 stack automatically; an already-correct cu128 runtime
  is verified and left alone instead of being reinstalled on every Repair.
- CUDA readiness verification launches a real kernel instead of only checking
  `torch.cuda.is_available()`, so a stale or broken CUDA runtime is caught and
  repaired before a separation run starts instead of failing partway through.
- A CUDA architecture/kernel failure is now classified and surfaced as such,
  instead of falling through as a generic error or being confused with a
  model-download/network failure.
- Fixed an offline Drum Kit Split NVIDIA payload defect where both
  `onnxruntime` and `onnxruntime-gpu` could be requested together, which could
  silently leave CUDA acceleration unavailable.
- Validated on real Blackwell hardware and on this line's regression machine
  (RTX 3060, sm_86).

## DrumSep / Kit Split correctness fixes (all platforms)

- **UVR-equivalent DrumSep MDXC reconstruction.** Forensic A/B testing against
  real UVR 5.6.0 output (byte-identical checkpoint, YAML config, source audio,
  and settings) found the DrumSep MDXC path (the Jarredou MDX23C model)
  diverged meaningfully only on the Snare stem, traced to a numerically
  consequential difference between audio-separator's chunk-accumulation
  strategy and UVR's own. Reproducing UVR's strategy closes the gap: Snare
  correlation against real UVR output moves from 0.68 to 0.9998.
- **Full-scale input preserved.** DrumSep no longer pre-attenuates
  already-near-full-scale source audio before separation
  (`normalization_threshold` is now explicitly `1.0` instead of inheriting
  audio-separator's default of `0.9`), matching UVR's own default of no
  output-level renormalization.
- **macOS DrumSep routing corrected.** macOS now always routes through the
  same UVR-equivalent MDXC reconstruction used on Windows/Linux, instead of a
  legacy direct-demix path that bypassed it.
- **Kit Split stem mapping corrected.** Drum Kit extraction now identifies
  each separator output by the generator's own stem token instead of
  substring-matching the output filename, so a source file whose name happens
  to contain a stem-like word can no longer be misclassified.
- **Amplification disabled, version-neutrally.** A stem-amplification default
  that silently drifted across audio-separator versions (`0.6` on macOS's
  bundled `0.23.0`, `0.0` on Windows/Linux's `0.34.1`) is now explicitly
  disabled everywhere, so naturally-quiet DrumSep stems (Toms/Ride/Crash) are
  no longer force-amplified on macOS while Windows/Linux left them untouched.
- Verified end-to-end on real hardware (RTX 3060 CUDA, plus source-level
  parity checks across the macOS audio-separator versions) through both the
  direct helper CLI and the production Direct Kit / Kit Split entrypoints.

## Explicit exclusions

- Issues #119 and #123 are not addressed by this release.
- No model-registry v2, device/backend-normalization architecture, or Linux
  ROCm unified runtime work.
- No new toolbar actions or icons.
- No 2.4 design or handoff work.
- Offline/allmodels products are not rebuilt or replaced.

## Release-prep corrections (this slice)

This slice implements release-preparation corrections only; it does not
change DSP/runtime behavior:

- ReaPack `index.xml` package payload sources are pinned to the immutable
  `v2.3.1.2` tag instead of the moving `main` branch.
- A fail-closed immutable-payload-ref release gate (`tools/release_gate.py`)
  rejects any payload source pinned to a floating ref.
- `.github/workflows/release-installers.yml` defaults publication off,
  verifies the checkout resolves to the exact release commit before building,
  pins third-party Actions to immutable commit SHAs, separates build from
  publish into distinct jobs, and builds only the five public artifacts
  (Windows standard/bundled, macOS standard/bundled Apple Silicon, Linux
  x86_64 AppImage) -- `.deb`/`.rpm`/Arch packages are not published.
- `installer/linux/build_appimage.sh` pins its `appimagetool` input to
  AppImageKit's last immutable tagged release (`13`) with a checksummed,
  fail-closed download instead of the floating `continuous` release.

No push, tag, installer build, or publication is part of release preparation.
