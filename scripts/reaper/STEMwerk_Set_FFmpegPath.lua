-- STEMwerk: Set FFmpeg Path (cross-platform)
-- Automatically finds FFmpeg or guides the user through setup.

local section = "STEMwerk"

local function getOS()
    local ros = ""
    if reaper and reaper.GetOS then
        ros = tostring(reaper.GetOS() or "")
    end
    if ros:match("Win") then return "Windows" end
    if ros:match("OSX") or ros:match("macOS") then return "macOS" end
    return "Linux"
end

local OS = getOS()
local PATH_SEP = OS == "Windows" and "\\" or "/"

local function fileExists(path)
    if not path or path == "" then return false end
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function getHome()
    if OS == "Windows" then
        return os.getenv("USERPROFILE") or "C:\\Users\\Default"
    end
    return os.getenv("HOME") or "/tmp"
end

local function getRuntimeBase()
    local override = reaper and reaper.GetExtState and reaper.GetExtState(section, "runtimeBase") or ""
    if override ~= "" then
        return override
    end
    local home = getHome()
    if OS == "Windows" then
        local localAppData = os.getenv("LOCALAPPDATA") or ""
        if localAppData ~= "" then return localAppData .. "\\STEMwerk" end
        return home .. "\\STEMwerk"
    elseif OS == "macOS" then
        return home .. "/Library/Application Support/STEMwerk"
    else
        local xdg = os.getenv("XDG_DATA_HOME") or ""
        if xdg ~= "" then return xdg .. "/STEMwerk" end
        return home .. "/.local/share/STEMwerk"
    end
end

local function isWindowsFfmpegShimPath(path)
    if OS ~= "Windows" then return false end
    if not path or path == "" then return false end
    local p = tostring(path):lower()
    return p:find("\\microsoft\\winget\\links\\ffmpeg.exe", 1, true)
        or p:find("\\windowsapps\\ffmpeg", 1, true)
        or p:find("/microsoft/winget/links/ffmpeg.exe", 1, true)
        or p:find("/windowsapps/ffmpeg", 1, true)
end

local function findFfmpeg()
    local runtimeBase = getRuntimeBase()
    local runtimeCandidates = {}
    if OS == "Windows" then
        table.insert(runtimeCandidates, runtimeBase .. "\\bin\\ffmpeg.exe")
        table.insert(runtimeCandidates, runtimeBase .. "\\ffmpeg\\bin\\ffmpeg.exe")
    else
        table.insert(runtimeCandidates, runtimeBase .. "/bin/ffmpeg")
        table.insert(runtimeCandidates, runtimeBase .. "/ffmpeg/bin/ffmpeg")
    end

    local candidates = {}
    for _, p in ipairs(runtimeCandidates) do
        table.insert(candidates, p)
    end

    if OS == "Windows" then
        local programFiles = os.getenv("ProgramFiles") or "C:\\Program Files"
        table.insert(candidates, programFiles .. "\\ffmpeg\\bin\\ffmpeg.exe")
        table.insert(candidates, "C:\\ffmpeg\\bin\\ffmpeg.exe")
        table.insert(candidates, "C:\\ProgramData\\chocolatey\\bin\\ffmpeg.exe")
    elseif OS == "macOS" then
        table.insert(candidates, "/opt/homebrew/bin/ffmpeg")
        table.insert(candidates, "/usr/local/bin/ffmpeg")
        table.insert(candidates, "/opt/homebrew/opt/ffmpeg/bin/ffmpeg")
        table.insert(candidates, "/usr/local/opt/ffmpeg/bin/ffmpeg")
        table.insert(candidates, "/usr/bin/ffmpeg")
    else
        table.insert(candidates, "/usr/local/bin/ffmpeg")
        table.insert(candidates, "/usr/bin/ffmpeg")
        table.insert(candidates, "/snap/bin/ffmpeg")
    end

    for _, p in ipairs(candidates) do
        if fileExists(p) and not isWindowsFfmpegShimPath(p) then return p end
    end

    if OS == "Windows" then
        local f = io.popen("where ffmpeg 2>nul")
        if f then
            local res = f:read("*l")
            f:close()
            if res and fileExists(res) and not isWindowsFfmpegShimPath(res) then return res end
        end
    else
        local f = io.popen("command -v ffmpeg 2>/dev/null")
        if f then
            local res = f:read("*l")
            f:close()
            if res and fileExists(res) then return res end
        end
    end
    return nil
end

local function openDownloadPage()
    local url = (OS == "Windows")
        and "https://www.gyan.dev/ffmpeg/builds/"
        or "https://ffmpeg.org/download.html"
    if OS == "Windows" then
        os.execute('start "" "' .. url .. '"')
    elseif OS == "macOS" then
        os.execute('open "' .. url .. '"')
    else
        os.execute('xdg-open "' .. url .. '"')
    end
end

local function main()
    local found = findFfmpeg()
    local exeLabel = (OS == "Windows") and "ffmpeg.exe" or "ffmpeg"

    if found then
        local msg = "FFmpeg was found at:\n\n" .. found .. "\n\nUse this path for STEMwerk?"
        local res = reaper.ShowMessageBox(msg, "FFmpeg Found", 4)
        if res == 6 then
            reaper.SetExtState(section, "ffmpegPath", found, true)
            reaper.ShowMessageBox("Success! FFmpeg is now configured.", "STEMwerk", 0)
            return
        end
    end

    local msg = "FFmpeg could not be found automatically.\n\n"
        .. "What would you like to do?\n\n"
        .. "YES: Enter the path to " .. exeLabel .. " manually\n"
        .. "NO: Open the download page\n"
        .. "CANCEL: Do nothing"

    local choice = reaper.ShowMessageBox(msg, "STEMwerk - FFmpeg Setup", 3)
    if choice == 6 then
        local current = reaper.GetExtState(section, "ffmpegPath")
        if current == "" then
            current = (OS == "Windows") and "C:\\Program Files\\ffmpeg\\bin\\ffmpeg.exe" or "/usr/local/bin/ffmpeg"
        end
        local ok, input = reaper.GetUserInputs("Path to " .. exeLabel, 1, "File path:,extrawidth=200", current)
        if ok and input ~= "" then
            input = input:gsub('"', "")
            if fileExists(input) then
                reaper.SetExtState(section, "ffmpegPath", input, true)
                reaper.ShowMessageBox("Success! Path saved:\n" .. input, "STEMwerk", 0)
            else
                reaper.ShowMessageBox("ERROR: The file does not exist at the specified location.", "Error", 0)
                main()
            end
        end
    elseif choice == 7 then
        openDownloadPage()
        reaper.ShowMessageBox("The download page was opened in your browser.", "STEMwerk", 0)
    end
end

main()
