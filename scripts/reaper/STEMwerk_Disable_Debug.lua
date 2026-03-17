-- STEMwerk: Disable Debug Logging

local section = "STEMwerk"
reaper.SetExtState(section, "debugMode", "0", true)
reaper.SetExtState(section, "debug", "0", true)
reaper.ShowMessageBox("STEMwerk debug disabled.", "STEMwerk", 0)


