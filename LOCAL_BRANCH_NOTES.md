# Local Branch Notes

- 2026-04-16: In the `2.2.1.9R` Windows test set, startup flicker is now strongly reduced (startup and pre-Complete flicker improvements are both in place). Next focus is NVIDIA/macOS validation, not further UI polishing right now.

- 2026-04-16: Cross-platform validation matrix for `stabilize/2.2.1.9R`:

| Platform | Result | Notes |
| --- | --- | --- |
| AMD Windows | PASS | AMD GPU path works, processing completed, approx. 2.42x realtime |
| AMD Linux | PASS |  |
| NVIDIA Windows | PASS | NVIDIA GPU path works, processing completed, approx. 2.40x realtime |
| NVIDIA Arch/Linux | PASS | approx. 4.65x realtime |
| macOS Intel | PASS | CPU/sequential only, approx. 0.07x realtime on late-2013 MacBook Pro; expected for old CPU-only hardware |

Additional notes:
- The script package is now identifiable as `2.2.1.9R`.
- Separate REAPER script folders are used for main/refactor testing.
- Install/distribution model remains unchanged and frozen.
- No processing regressions were observed in these validation runs.
