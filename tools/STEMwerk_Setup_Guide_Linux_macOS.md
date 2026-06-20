# STEMwerk Setup Wizard (Linux/macOS)

This is the new cross-platform STEMwerk installer for Linux and macOS. It provides the same fully-automatic, stepwise setup experience as the Windows installer, with a modern GUI and live progress/logging.

## Features
- One-click, fully automatic setup (no manual steps required)
- Stepwise progress bar (Runtime, Python + venv, FFmpeg, Core packages, REAPER integration)
- Live log output for troubleshooting
- Downloads a pinned STEMwerk-managed Python runtime on supported Linux/macOS platforms, then creates the venv, dependencies, and GPU backend (ROCm/NVIDIA/MPS/CPU)
- Copies all STEMwerk scripts to the correct REAPER Scripts folder
- No changes to existing STEMwerk files or legacy installers

## Usage
1. Run the installer:
   ```
   python3 tools/stemwerk_setup_gui.py
   ```
2. Wait for all steps to complete (progress and log are shown in the window)
3. When finished, open REAPER and run STEMwerk.lua — everything is ready!

## Requirements
- Internet access for first-time managed Python/runtime setup
- PySimpleGUI (will be installed automatically in the venv)
- ffmpeg (recommended, for full functionality)

Supported managed Python downloads currently cover Linux x86_64 glibc, macOS x86_64, and macOS arm64. Linux/macOS package and setup flows in the 2.3 release line are script/setup delivery paths, not full offline runtime/model bundles. Other Linux/macOS platforms need a supported Python 3.10-3.12 runtime installed manually.

## Troubleshooting
- All output is shown live in the log window
- If a step fails, check the log for details
- For advanced/manual repair, you can still use the legacy STEMwerk_First_Run_Setup.lua script

## Note
This installer is a new, standalone tool. It does not modify or replace any existing STEMwerk files or legacy installers.

---

(c) STEMwerk/flarkAUDIO — v2.2.2-dev and later
