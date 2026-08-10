; Explicit Windows installer payload contract for normal online and bundled builds.
; Keep every source file explicit so new cross-platform files cannot enter by recursion.

; Public REAPER actions shared by Windows.
Source: "..\..\scripts\reaper\STEMwerk-SETUP.lua"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\reaper\STEMwerk.lua"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\reaper\STEMwerk_AI_Separate.lua"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\reaper\STEMwerk_All_Stems.lua"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\reaper\STEMwerk_Bass_Only.lua"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\reaper\STEMwerk_Benchmark_Flashy_Idle.lua"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\reaper\STEMwerk_Benchmark_REAPER_Native_Idle.lua"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\reaper\STEMwerk_Dev_Prepare_Benchmark_State.lua"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\reaper\STEMwerk_Dev_Project_State_Snapshot.lua"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\reaper\STEMwerk_Drum_Kit_Split.lua"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\reaper\STEMwerk_Drums_Only.lua"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\reaper\STEMwerk_Explode_Takes.lua"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\reaper\STEMwerk_Karaoke.lua"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\reaper\STEMwerk_REAPER_Native.lua"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\reaper\STEMwerk_Save_Support_Bundle.lua"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\reaper\STEMwerk_Setup_Toolbar.lua"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\reaper\STEMwerk_Vocals_Only.lua"; DestDir: "{app}"; Flags: ignoreversion

; Windows setup and shared processing entrypoints.
Source: "..\..\scripts\reaper\STEMwerk_Bootstrap_Windows.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\scripts\reaper\audio_separator_process.py"; DestDir: "{app}"; Flags: ignoreversion

; Shared REAPER internals used on Windows.
Source: "..\..\scripts\reaper\_internal\STEMwerk_Devices.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_DKS_Import.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_DrumKit_Workflow.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_ExtState.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_Glue_Helpers.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_Helpers.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_I18N.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_Log.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_Managed_Python.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_Messages.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_Path_Helper.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_Platform.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_Progress_Render.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_Runtime_Setup.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_Settings.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_Setup_Internal.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_System.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_Timing.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_UI.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_UI_Backgrounds.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_UI_Controls.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_UI_Draw.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_UI_HelpLayout.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_UI_PathInput.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_UI_Tokens.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_UI_Window.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_Window.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\STEMwerk_Workflow.lua"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\stemwerk_drumsep_process.py"; DestDir: "{app}\_internal"; Flags: ignoreversion
Source: "..\..\scripts\reaper\_internal\stemwerk_samplerate_guard.py"; DestDir: "{app}\_internal"; Flags: ignoreversion

; Windows dependency constraints.
Source: "..\..\scripts\reaper\constraints\base.txt"; DestDir: "{app}\constraints"; Flags: ignoreversion
Source: "..\..\scripts\reaper\constraints\cuda.txt"; DestDir: "{app}\constraints"; Flags: ignoreversion
Source: "..\..\scripts\reaper\constraints\directml.txt"; DestDir: "{app}\constraints"; Flags: ignoreversion

; Shared vendored Python sources required by the processing entrypoint.
Source: "..\..\scripts\reaper\vendor\julius\pyproject.toml"; DestDir: "{app}\vendor\julius"; Flags: ignoreversion
Source: "..\..\scripts\reaper\vendor\julius\src\julius.py"; DestDir: "{app}\vendor\julius\src"; Flags: ignoreversion
Source: "..\..\scripts\reaper\vendor\stemwerk-core\README.txt"; DestDir: "{app}\vendor\stemwerk-core"; Flags: ignoreversion
Source: "..\..\scripts\reaper\vendor\stemwerk-core\pyproject.toml"; DestDir: "{app}\vendor\stemwerk-core"; Flags: ignoreversion
Source: "..\..\scripts\reaper\vendor\stemwerk-core\src\stemwerk_core\__init__.py"; DestDir: "{app}\vendor\stemwerk-core\src\stemwerk_core"; Flags: ignoreversion
Source: "..\..\scripts\reaper\vendor\stemwerk-core\src\stemwerk_core\devices.py"; DestDir: "{app}\vendor\stemwerk-core\src\stemwerk_core"; Flags: ignoreversion
Source: "..\..\scripts\reaper\vendor\stemwerk-core\src\stemwerk_core\models.py"; DestDir: "{app}\vendor\stemwerk-core\src\stemwerk_core"; Flags: ignoreversion
Source: "..\..\scripts\reaper\vendor\stemwerk-core\src\stemwerk_core\progress.py"; DestDir: "{app}\vendor\stemwerk-core\src\stemwerk_core"; Flags: ignoreversion
Source: "..\..\scripts\reaper\vendor\stemwerk-core\src\stemwerk_core\separator.py"; DestDir: "{app}\vendor\stemwerk-core\src\stemwerk_core"; Flags: ignoreversion

; Canonical shared language data, mapped exactly once.
Source: "..\..\i18n\languages.lua"; DestDir: "{app}\i18n"; Flags: ignoreversion
Source: "..\..\i18n\language_checks.py"; DestDir: "{app}\i18n"; Flags: ignoreversion
Source: "..\..\i18n\stemwerk_language_wrapper.lua"; DestDir: "{app}\i18n"; Flags: ignoreversion
Source: "..\..\i18n\__init__.py"; DestDir: "{app}\i18n"; Flags: ignoreversion

; Shared toolbar resource descriptor used by setup.
Source: "..\..\scripts\reaper\assets\toolbar_icons\README.txt"; DestDir: "{app}\assets\toolbar_icons"; Flags: ignoreversion
