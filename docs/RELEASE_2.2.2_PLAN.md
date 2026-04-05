# STEMwerk 2.2.2 Implementation Contract

## Purpose

2.2.2 is a product polish release following the stabilization work in
2.2.1.

Goal: Make STEMwerk clear, predictable, and easy to use, without
introducing new complexity or risk.

## Scope (LOCKED)

2.2.2 focuses on: - Setup clarity - Runtime sanity check (read-only
diagnostics) - Passive path validation (no auto-fix) - Troubleshooting
affordances (logs + runtime folder) - Documentation improvements

Explicitly excluded: - ReaPack fixes - Automatic repair flows -
Installer redesign - Major UI redesign - Model / AI / processing changes

## Features

### Setup completion clarity

"Setup complete --- run STEMwerk.lua from the REAPER Action List"
Button: Open Action List

### Runtime sanity check

Checks: - Python path exists - FFmpeg path exists - Runtime folder
exists

States: - OK - Warning - Broken

(No automatic fixes)

### Passive path validation

Show warning if paths invalid: "Runtime appears broken. Run Setup to
repair."

### Troubleshooting

Buttons: - Open Logs - Open Runtime Folder

### Documentation

Add Troubleshooting + Known Issues to README

## Done Criteria

-   No new crashes
-   Setup flow stable
-   English-only UI
-   Works on Windows + Linux

## Guiding Principle

2.2.1 = make it work 2.2.2 = make it understandable
