STEMwerk Toolbar Icons
======================

This folder contains language-neutral toolbar icons for STEMwerk actions.

Recommended sets:
- strips_90x30: REAPER toolbar 1x (3 states in one file: normal/hover/active)
- strips_180x60: REAPER toolbar hiDPI/retina (same 3-state layout at 2x)
- single/*: single-square icons (24, 30, 36, 48, 64) for manual/custom use

Installation notes:
- `STEMwerk_Setup_Toolbar.lua` installs REAPER-ready strip files into `Data/toolbar_icons/`.
- Base icons are installed as `stemwerk_*.png`.
- hiDPI copies are installed with the same names under `Data/toolbar_icons/150/` and `Data/toolbar_icons/200/`.
- Legacy compatibility alias currently installed: `toolbar_6stem.png` for the All Stems action.

Action-to-icon mapping:
- STEMwerk: Main -> stemwerk_main
- STEMwerk: Setup -> stemwerk_setup
- STEMwerk: Karaoke -> stemwerk_karaoke
- STEMwerk: Vocals Only -> stemwerk_vocals_only
- STEMwerk: Drums Only -> stemwerk_drums_only
- STEMwerk: Bass Only -> stemwerk_bass_only
- STEMwerk: All Stems -> stemwerk_all_stems
- Stemwerk: Explode Takes (In Place) -> stemwerk_explode_takes

Notes:
- This pack does not modify reaper-menu.ini.
- Assign icons manually in REAPER toolbar customize dialogs.
