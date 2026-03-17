-- STEMwerk: Set Python Path (ExtState)
-- Lets you point STEMwerk to a specific Python executable (e.g. a ROCm-enabled venv).
--
-- This sets REAPER ExtState section "STEMwerk" key "pythonPath".

local section = "STEMwerk"

local function getOS()
  local ros = reaper and reaper.GetOS and tostring(reaper.GetOS() or "") or ""
  if ros:match("Win") then return "Windows" end
  if ros:match("OSX") or ros:match("macOS") then return "macOS" end
  return "Linux"
end

local function getHome()
  local osName = getOS()
  if osName == "Windows" then
    return os.getenv("USERPROFILE") or "C:\\Users\\Default"
  end
  return os.getenv("HOME") or "/tmp"
end

local function getRuntimeBase()
  local osName = getOS()
  local override = reaper.GetExtState(section, "runtimeBase")
  if override ~= "" then return override end
  local home = getHome()
  if osName == "Windows" then
    local localAppData = os.getenv("LOCALAPPDATA") or ""
    if localAppData ~= "" then return localAppData .. "\\STEMwerk" end
    return home .. "\\Documents\\STEMwerk"
  elseif osName == "macOS" then
    return "/Users/Shared/STEMwerk"
  end
  local xdg = os.getenv("XDG_DATA_HOME") or ""
  if xdg ~= "" then return xdg .. "/STEMwerk" end
  return home .. "/.local/share/STEMwerk"
end

local current = reaper.GetExtState(section, "pythonPath")
if current == "" then
  local base = getRuntimeBase()
  if getOS() == "Windows" then
    current = base .. "\\.venv\\Scripts\\python.exe"
  else
    current = base .. "/.venv/bin/python"
  end
end

local ok, input = reaper.GetUserInputs("STEMwerk - Python Path", 1, "pythonPath:", current)
if not ok then return end

input = (input or ""):gsub("^%s+", ""):gsub("%s+$", "")
if input == "" then
  reaper.ShowMessageBox("No path entered; nothing changed.", "STEMwerk", 0)
  return
end

reaper.SetExtState(section, "pythonPath", input, true)
reaper.ShowMessageBox("Saved STEMwerk pythonPath:\n\n" .. input .. "\n\nRe-run STEMwerk.", "STEMwerk", 0)


