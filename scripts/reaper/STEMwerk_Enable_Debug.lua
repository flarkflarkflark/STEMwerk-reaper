-- STEMwerk: Enable Debug Logging
-- Sets REAPER ExtState so STEMwerk.lua writes /tmp/STEMwerk_debug.log (Linux/macOS) or %TEMP%\STEMwerk_debug.log (Windows).

local section = "STEMwerk"
reaper.SetExtState(section, "debugMode", "1", true)
reaper.SetExtState(section, "debug", "1", true)
reaper.ShowMessageBox("STEMwerk debug enabled.\n\nRe-run STEMwerk and then check:\n/tmp/STEMwerk_debug.log\n\n(To disable: run STEMwerk_Disable_Debug.lua)", "STEMwerk", 0)


