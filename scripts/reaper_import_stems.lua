-- scripts/reaper_import_stems.lua
-- Auto-detect WAV files in a folder and import each into its own Reaper track.
local retval, folder = reaper.GetUserInputs("Import stems folder", 1, "Folder path:", "C:\\temp")
if not retval then return end

local function ensure_trailing_sep(p)
  if string.sub(p, -1) ~= "\\" and string.sub(p, -1) ~= "/" then
    return p .. "\\"
  end
  return p
end

local function list_wavs(path)
  local files = {}
  local cmd = 'cmd /c dir /b /a:-d "' .. path .. '*.wav" 2>nul'
  local f = io.popen(cmd)
  if not f then return files end
  for name in f:lines() do
    table.insert(files, name)
  end
  f:close()
  return files
end

local function basename_no_ext(name)
  return name:match("(.+)%.[^%.]+$") or name
end

local function detect_stem_name(filename)
  local s = filename:lower()
  if s:find("vocal") then return "Vocals" end
  if s:find("bass") then return "Bass" end
  if s:find("drum") or s:find("drums") then return "Drums" end
  if s:find("other") or s:find("inst") or s:find("instrument") or s:find("accomp") then return "Other" end
  -- fallback: use cleaned filename
  local base = basename_no_ext(filename)
  return base:gsub("[_%(%)%-]+"," "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function deselect_all_tracks()
  local n = reaper.CountTracks(0)
  for i = 0, n-1 do
    local t = reaper.GetTrack(0, i)
    reaper.SetMediaTrackInfo_Value(t, "I_SELECTED", 0)
  end
end

folder = ensure_trailing_sep(folder)
local wavs = list_wavs(folder)

reaper.Undo_BeginBlock()
reaper.PreventUIRefresh(1)
reaper.SetEditCurPos(0, true, false)

local imported = {}
for _, fname in ipairs(wavs) do
  local full = folder .. fname
  local track_name = detect_stem_name(fname)
  local idx = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  local track = reaper.GetTrack(0, idx)
  reaper.GetSetMediaTrackInfo_String(track, "P_NAME", track_name, true)
  deselect_all_tracks()
  reaper.SetMediaTrackInfo_Value(track, "I_SELECTED", 1)
  reaper.InsertMedia(full, 0)
  table.insert(imported, {track_name, full})
end

reaper.UpdateArrange()
reaper.PreventUIRefresh(-1)
reaper.Undo_EndBlock("Import separated stems (auto-detect)", -1)

if #imported == 0 then
  reaper.ShowMessageBox("No WAV files found in:\n" .. folder, "Import stems", 0)
else
  local msg = "Imported stems:\n"
  for _, v in ipairs(imported) do msg = msg .. v[1] .. " -> " .. v[2] .. "\n" end
  reaper.ShowMessageBox(msg, "Import stems", 0)
end