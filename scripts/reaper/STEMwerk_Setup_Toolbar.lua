-- @description Stemwerk: Setup Toolbar
-- @author flarkAUDIO <flarkaudio@pm.me>
-- @version 2.2.2.2.1
-- @changelog
--   Adds/refreshes STEMwerk scripts in the Action List and guides toolbar setup.
--   Registers the dedicated "Stemwerk: Explode Takes (In Place)" quick action.
-- @link Repository https://github.com/flarkflarkflark/STEMwerk

local function msgBox(title, text, type)
    return reaper.ShowMessageBox(tostring(text), tostring(title), type or 0)
end

local function isDebugEnabled()
    if not (reaper and reaper.GetExtState) then return false end
    local a = tostring(reaper.GetExtState("STEMwerk", "debugMode") or "")
    local b = tostring(reaper.GetExtState("STEMwerk", "debug") or "")
    return a == "1" or b == "1"
end

local function debugConsole(text)
    if not (isDebugEnabled() and reaper and reaper.ShowConsoleMsg) then return end
    reaper.ShowConsoleMsg("[STEMwerk Toolbar Setup] " .. tostring(text or "") .. "\n")
end

local function hr()
    return "------------------------------------------------------------"
end

local function section(title, body)
    return "[" .. tostring(title or "") .. "]\n" .. tostring(body or "")
end

local function joinBlocks(...)
    local blocks = {...}
    local out = {}
    for i = 1, #blocks do
        local block = tostring(blocks[i] or "")
        if block ~= "" then
            out[#out + 1] = block
        end
    end
    return table.concat(out, "\n\n")
end

local function toolbarDialogTitle(suffix)
    return "STEMwerk Toolbar Setup" .. (suffix and (": " .. tostring(suffix)) or "")
end

local function getScriptDir()
    local info = debug.getinfo(1, "S")
    return (info and info.source and info.source:match("@?(.*[/\\])")) or ""
end

local function getPathSep()
    local osName = reaper and reaper.GetOS and tostring(reaper.GetOS() or "") or ""
    if osName:match("Win") then return "\\" end
    return "/"
end

local function joinPath(...)
    local sep = getPathSep()
    local parts = {...}
    for i = 1, #parts do
        local part = tostring(parts[i] or "")
        if i > 1 then
            part = part:gsub("^[/\\]+", "")
        end
        if i < #parts then
            part = part:gsub("[/\\]+$", "")
        end
        parts[i] = part
    end
    return table.concat(parts, sep)
end

local function fileExists(path)
    if not path or path == "" then return false end
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function copyFile(src, dst)
    local inFile = io.open(src, "rb")
    if not inFile then return false, "unable to open source: " .. tostring(src) end
    local data = inFile:read("*all")
    inFile:close()
    local outFile = io.open(dst, "wb")
    if not outFile then return false, "unable to open destination: " .. tostring(dst) end
    outFile:write(data)
    outFile:close()
    return true
end

local function ensureDir(path)
    if reaper and reaper.RecursiveCreateDirectory then
        reaper.RecursiveCreateDirectory(path, 0)
        return true
    end
    return false
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*all")
    f:close()
    return data
end

local function writeFile(path, data)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

local function splitLines(text)
    local lines = {}
    local normalized = tostring(text or ""):gsub("\r\n", "\n")
    if normalized == "" then return lines end
    if normalized:sub(-1) ~= "\n" then normalized = normalized .. "\n" end
    for line in normalized:gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

local function joinLines(lines)
    if #lines == 0 then return "" end
    return table.concat(lines, "\n") .. "\n"
end

local function trim(s)
    return tostring(s or ""):match("^%s*(.-)%s*$")
end

local function normalizeNamedCommandId(commandId)
    local value = trim(commandId)
    if value == "" then return "" end
    if value:sub(1, 1) ~= "_" then
        value = "_" .. value
    end
    return value
end

local function pad2(n)
    n = tonumber(n) or 0
    if n < 10 then return "0" .. tostring(n) end
    return tostring(n)
end

local function makeTimestamp()
    local now = os.date("*t")
    return string.format(
        "%04d%s%s-%s%s%s",
        tonumber(now.year) or 0,
        pad2(now.month),
        pad2(now.day),
        pad2(now.hour),
        pad2(now.min),
        pad2(now.sec)
    )
end

local scriptDir = getScriptDir()
local pathSep = getPathSep()
local toolbarAssetDir = joinPath(scriptDir, "assets", "toolbar_icons")

local scriptFiles = {
    "STEMwerk.lua",
    "STEMwerk-SETUP.lua",
    "STEMwerk_Save_Support_Bundle.lua",
    "STEMwerk_Explode_Takes.lua",
    "STEMwerk_Karaoke.lua",
    "STEMwerk_Vocals_Only.lua",
    "STEMwerk_Drums_Only.lua",
    "STEMwerk_Bass_Only.lua",
    "STEMwerk_All_Stems.lua",
}

local toolbarIcons = {
    {
        source1x = joinPath(toolbarAssetDir, "strips_90x30", "stemwerk_main_90x30.png"),
        source2x = joinPath(toolbarAssetDir, "strips_180x60", "stemwerk_main_180x60.png"),
        targets = {"stemwerk_main.png"},
    },
    {
        source1x = joinPath(toolbarAssetDir, "strips_90x30", "stemwerk_setup_90x30.png"),
        source2x = joinPath(toolbarAssetDir, "strips_180x60", "stemwerk_setup_180x60.png"),
        targets = {"stemwerk_setup.png"},
    },
    {
        source1x = joinPath(toolbarAssetDir, "strips_90x30", "stemwerk_karaoke_90x30.png"),
        source2x = joinPath(toolbarAssetDir, "strips_180x60", "stemwerk_karaoke_180x60.png"),
        targets = {"stemwerk_karaoke.png"},
    },
    {
        source1x = joinPath(toolbarAssetDir, "strips_90x30", "stemwerk_vocals_only_90x30.png"),
        source2x = joinPath(toolbarAssetDir, "strips_180x60", "stemwerk_vocals_only_180x60.png"),
        targets = {"stemwerk_vocals_only.png"},
    },
    {
        source1x = joinPath(toolbarAssetDir, "strips_90x30", "stemwerk_drums_only_90x30.png"),
        source2x = joinPath(toolbarAssetDir, "strips_180x60", "stemwerk_drums_only_180x60.png"),
        targets = {"stemwerk_drums_only.png"},
    },
    {
        source1x = joinPath(toolbarAssetDir, "strips_90x30", "stemwerk_bass_only_90x30.png"),
        source2x = joinPath(toolbarAssetDir, "strips_180x60", "stemwerk_bass_only_180x60.png"),
        targets = {"stemwerk_bass_only.png"},
    },
    {
        source1x = joinPath(toolbarAssetDir, "strips_90x30", "stemwerk_all_stems_90x30.png"),
        source2x = joinPath(toolbarAssetDir, "strips_180x60", "stemwerk_all_stems_180x60.png"),
        targets = {"stemwerk_all_stems.png", "toolbar_6stem.png"},
    },
    {
        source1x = joinPath(toolbarAssetDir, "strips_90x30", "stemwerk_explode_takes_90x30.png"),
        source2x = joinPath(toolbarAssetDir, "strips_180x60", "stemwerk_explode_takes_180x60.png"),
        targets = {"stemwerk_explode_takes.png"},
    },
}

local recommendedToolbarOrder = {
    "1. Setup -> STEMwerk-SETUP.lua -> stemwerk_setup.png",
    "2. STEMwerk -> STEMwerk.lua -> stemwerk_main.png",
    "3. separator",
    "4. All Stems -> STEMwerk_All_Stems.lua -> stemwerk_all_stems.png",
    "5. Vocals Only -> STEMwerk_Vocals_Only.lua -> stemwerk_vocals_only.png",
    "6. Drums Only -> STEMwerk_Drums_Only.lua -> stemwerk_drums_only.png",
    "7. Bass Only -> STEMwerk_Bass_Only.lua -> stemwerk_bass_only.png",
    "8. Karaoke -> STEMwerk_Karaoke.lua -> stemwerk_karaoke.png",
    "9. separator",
    "10. Explode Takes -> STEMwerk_Explode_Takes.lua -> stemwerk_explode_takes.png",
}

local toolbarEntries = {
    {script = "STEMwerk-SETUP.lua", label = "Setup", icon = "stemwerk_setup.png"},
    {script = "STEMwerk.lua", label = "STEMwerk", icon = "stemwerk_main.png"},
    {separator = true},
    {script = "STEMwerk_All_Stems.lua", label = "All Stems", icon = "stemwerk_all_stems.png"},
    {script = "STEMwerk_Vocals_Only.lua", label = "Vocals Only", icon = "stemwerk_vocals_only.png"},
    {script = "STEMwerk_Drums_Only.lua", label = "Drums Only", icon = "stemwerk_drums_only.png"},
    {script = "STEMwerk_Bass_Only.lua", label = "Bass Only", icon = "stemwerk_bass_only.png"},
    {script = "STEMwerk_Karaoke.lua", label = "Karaoke", icon = "stemwerk_karaoke.png"},
    {separator = true},
    {script = "STEMwerk_Explode_Takes.lua", label = "Explode Takes", icon = "stemwerk_explode_takes.png"},
}

local function registerScripts()
    local resolved = {}
    if not (reaper and reaper.AddRemoveReaScript) then
        return false, "AddRemoveReaScript API unavailable.", resolved
    end

    for index, name in ipairs(scriptFiles) do
        local path = scriptDir .. name
        local commandId = reaper.AddRemoveReaScript(true, 0, path, index == #scriptFiles)
        if not commandId or commandId <= 0 then
            return false, "Failed to register script: " .. tostring(name), resolved
        end

        local named = reaper.ReverseNamedCommandLookup and reaper.ReverseNamedCommandLookup(commandId) or ""
        named = normalizeNamedCommandId(named)
        if not named or named == "" then
            return false, "Failed to resolve named command ID for: " .. tostring(name), resolved
        end

        resolved[name] = {
            commandId = commandId,
            namedId = named,
        }
    end

    return true, nil, resolved
end

local function buildToolbarSectionLines(sectionName, actionMap)
    local lines = {sectionName}
    local itemIndex = 0
    for _, entry in ipairs(toolbarEntries) do
        if entry.separator then
            lines[#lines + 1] = "item_" .. tostring(itemIndex) .. "=-1"
        else
            local resolved = actionMap[entry.script]
            if not resolved or not resolved.namedId or resolved.namedId == "" then
                return nil, "Missing action ID for " .. tostring(entry.script)
            end
            lines[#lines + 1] = "icon_" .. tostring(itemIndex) .. "=" .. entry.icon
            lines[#lines + 1] = "item_" .. tostring(itemIndex) .. "=" .. resolved.namedId .. " STEMwerk: " .. entry.label
        end
        itemIndex = itemIndex + 1
    end
    lines[#lines + 1] = "title=STEMwerk"
    lines[#lines + 1] = ""
    return lines
end

local function parseIniSections(lines)
    local sections = {}
    local current
    for i, line in ipairs(lines) do
        if line:match("^%[.+%]$") then
            if current then
                current.last = i - 1
                sections[#sections + 1] = current
            end
            current = {
                name = line,
                first = i,
                last = #lines,
            }
        end
    end
    if current then
        current.last = #lines
        sections[#sections + 1] = current
    end
    return sections
end

local function findStemwerkToolbar(sections, lines)
    for _, section in ipairs(sections) do
        if section.name:match("^%[Floating toolbar %d+%]$") then
            for i = section.first + 1, section.last do
                if trim(lines[i]) == "title=STEMwerk" then
                    return section
                end
            end
        end
    end
    return nil
end

local function collectUsedToolbarSlots(sections)
    local used = {}
    for _, section in ipairs(sections) do
        local slot = section.name:match("^%[Floating toolbar (%d+)%]$")
        if slot then used[tonumber(slot)] = true end
    end
    return used
end

local function findFreeToolbarSlot(sections, maxSlot)
    local used = collectUsedToolbarSlots(sections)
    for slot = 1, maxSlot do
        if not used[slot] then return slot end
    end
    return nil
end

local function backupMenuFile(menuPath)
    local data = readFile(menuPath)
    if not data then
        return false, "Unable to read reaper-menu.ini for backup."
    end
    local backupPath = menuPath .. ".STEMwerk-backup-" .. makeTimestamp()
    if not writeFile(backupPath, data) then
        return false, "Unable to write backup: " .. tostring(backupPath)
    end
    return true, backupPath
end

local function replaceSection(lines, targetSection, replacementLines)
    local out = {}
    for i = 1, targetSection.first - 1 do
        out[#out + 1] = lines[i]
    end
    for _, line in ipairs(replacementLines) do
        out[#out + 1] = line
    end
    for i = targetSection.last + 1, #lines do
        out[#out + 1] = lines[i]
    end
    return out
end

local function appendSection(lines, replacementLines)
    local out = {}
    for i = 1, #lines do
        out[#out + 1] = lines[i]
    end
    if #out > 0 and trim(out[#out]) ~= "" then
        out[#out + 1] = ""
    end
    for _, line in ipairs(replacementLines) do
        out[#out + 1] = line
    end
    return out
end

local function buildToolbarWritePlan(actionMap)
    local resourcePath = reaper and reaper.GetResourcePath and reaper.GetResourcePath() or ""
    if resourcePath == "" then
        return false, "REAPER resource path is unavailable."
    end

    local menuPath = joinPath(resourcePath, "reaper-menu.ini")
    local menuData = readFile(menuPath)
    if not menuData then
        return false, "Unable to read reaper-menu.ini at:\n" .. tostring(menuPath)
    end

    local lines = splitLines(menuData)
    local sections = parseIniSections(lines)
    local existing = findStemwerkToolbar(sections, lines)
    local slot = existing and tonumber(existing.name:match("^%[Floating toolbar (%d+)%]$")) or findFreeToolbarSlot(sections, 16)
    if not slot then
        return false, "No free floating toolbar slot found in range 1-16."
    end

    local sectionName = "[Floating toolbar " .. tostring(slot) .. "]"
    local sectionLines, sectionErr = buildToolbarSectionLines(sectionName, actionMap)
    if not sectionLines then
        return false, sectionErr
    end

    return true, {
        menuPath = menuPath,
        lines = lines,
        sections = sections,
        existing = existing,
        slot = slot,
        sectionName = sectionName,
        sectionLines = sectionLines,
    }
end

local function writeStemwerkToolbar(actionMap)
    local planOk, plan = buildToolbarWritePlan(actionMap)
    if not planOk then return false, plan end

    local confirmText = joinBlocks(
        "STEMwerk Toolbar Setup\n" .. hr(),
        section("Ready to update toolbar", "A dedicated STEMwerk toolbar section will be created or updated in REAPER."),
        section("Details", "Toolbar slot: Floating toolbar " .. tostring(plan.slot) .. "\nTarget file: reaper-menu.ini"),
        section("Choose action", "Yes = create/update dedicated STEMwerk toolbar\nNo = close without changes\nCancel = close without changes")
    )
    local confirm = msgBox(toolbarDialogTitle("Create Toolbar"), confirmText, 3)
    if confirm ~= 6 then
        return false, "Toolbar creation skipped by user."
    end

    if plan.existing then
        local replace = msgBox(
            toolbarDialogTitle("Existing Toolbar"),
            "A dedicated STEMwerk toolbar already exists in slot " .. tostring(plan.slot) ..
            ".\n\nReplace only that STEMwerk toolbar section?\n\nYes = replace\nNo = leave unchanged",
            4
        )
        if replace ~= 6 then
            return false, "Existing STEMwerk toolbar left unchanged."
        end
    end

    debugConsole("Toolbar write plan: slot=" .. tostring(plan.slot) .. " existing=" .. tostring(plan.existing) .. " menuPath=" .. tostring(plan.menuPath))

    local backupOk, backupInfo = backupMenuFile(plan.menuPath)
    if not backupOk then
        return false, backupInfo
    end

    local outputLines
    if plan.existing then
        outputLines = replaceSection(plan.lines, plan.existing, plan.sectionLines)
    else
        outputLines = appendSection(plan.lines, plan.sectionLines)
    end

    if not writeFile(plan.menuPath, joinLines(outputLines)) then
        return false, "Failed to write toolbar section to:\n" .. tostring(plan.menuPath)
    end

    local result =
        "Backup created:\n" .. backupInfo ..
        "\n\nToolbar slot:\nFloating toolbar " .. tostring(plan.slot) ..
        "\n\nOpen in REAPER via:\nView -> Floating toolbar " .. tostring(plan.slot) ..
        "\n\nIf it does not appear immediately, restart REAPER."
    return true, result, plan.existing
end

local function installToolbarIcons()
    local resourcePath = reaper and reaper.GetResourcePath and reaper.GetResourcePath() or ""
    if resourcePath == "" then
        return false, "REAPER resource path is unavailable."
    end

    local toolbarRoot = joinPath(resourcePath, "Data", "toolbar_icons")
    local toolbar200 = joinPath(toolbarRoot, "200")
    ensureDir(toolbarRoot)
    ensureDir(toolbar200)

    local installed = {}
    local missing = {}

    for _, icon in ipairs(toolbarIcons) do
        local have1x = fileExists(icon.source1x)
        local have2x = fileExists(icon.source2x)
        if not have1x or not have2x then
            if not have1x then missing[#missing + 1] = icon.source1x end
            if not have2x then missing[#missing + 1] = icon.source2x end
        else
            for _, name in ipairs(icon.targets) do
                local okBase, errBase = copyFile(icon.source1x, joinPath(toolbarRoot, name))
                local ok200, err200 = copyFile(icon.source2x, joinPath(toolbar200, name))
                if okBase and ok200 then
                    installed[#installed + 1] = name
                else
                    return false, errBase or err200 or ("failed to install " .. tostring(name))
                end
            end
        end
    end

    if #missing > 0 then
        return false, "Missing toolbar icon strip(s):\n" .. table.concat(missing, "\n")
    end

    return true, toolbarRoot, installed
end

local scriptsOk, scriptsErr, actionMap = registerScripts()
if not scriptsOk then
    msgBox(
        toolbarDialogTitle(),
        joinBlocks(
            "STEMwerk Toolbar Setup\n" .. hr(),
            section("Setup failed", tostring(scriptsErr)),
            section("What you can do", "Open Actions -> ReaScript and reload the STEMwerk scripts, then run this setup again.")
        ),
        0
    )
    return
end

local installOk, installInfo = installToolbarIcons()
local installSummary
if installOk then
    installSummary =
        "Toolbar icon strips installed to:\n" .. installInfo ..
        "\n- 1x: stemwerk_*.png in toolbar_icons" ..
        "\n- 200%: matching names in 200/ (180x60 strips)" ..
        "\n- compatibility alias: toolbar_6stem.png"
else
    installSummary =
        "Toolbar icon install skipped:\n" .. tostring(installInfo) ..
        "\n\nYou can still use the shipped strip files manually from:\n" ..
        toolbarAssetDir .. pathSep .. "strips_90x30\n" ..
        toolbarAssetDir .. pathSep .. "strips_180x60\n\n" ..
        "Optional individual icons are also available under:\n" ..
        toolbarAssetDir .. pathSep .. "single"
end

local toolbarOrderSummary =
    "Recommended dedicated STEMwerk toolbar order:\n" ..
    table.concat(recommendedToolbarOrder, "\n") ..
    "\n\nManual add steps:\n" ..
    "1) Open Actions -> Show action list\n" ..
    "2) Filter for 'STEMwerk:'\n" ..
    "3) Add actions to a toolbar in the order above\n" ..
    "4) Assign the installed icon filenames in Customize Toolbar"

if not installOk then
    debugConsole("Icon install details: " .. tostring(installInfo))
    msgBox(
        toolbarDialogTitle(),
        joinBlocks(
            "STEMwerk Toolbar Setup\n" .. hr(),
            section("Status", installSummary),
            section("Result", "Dedicated toolbar creation was skipped because required icon strips were not installed.\nNo toolbar config was written."),
            section("Manual setup", toolbarOrderSummary)
        ),
        0
    )
    return
end

local flowText =
    joinBlocks(
        "STEMwerk Toolbar Setup\n" .. hr(),
        section("Status", "Scripts are registered and toolbar icon strips are ready.\n\n" .. installSummary),
        section("Choose setup mode", "Yes = create/update dedicated STEMwerk toolbar\nNo = show manual toolbar instructions\nCancel = close (icons are already installed; toolbar unchanged)")
    )

local flowChoice = msgBox(toolbarDialogTitle(), flowText, 3)

if flowChoice == 6 then
    local toolbarOk, toolbarInfo, updatedExisting = writeStemwerkToolbar(actionMap)
    if toolbarOk then
        local existingUpdateLine = updatedExisting and "\n\nExisting STEMwerk toolbar was updated." or ""
        msgBox(
            toolbarDialogTitle("Toolbar Created"),
            joinBlocks(
                "STEMwerk Toolbar Setup\n" .. hr(),
                section("Result", "Toolbar setup completed successfully.\n\nYour toolbar actions and icon-strip assignments are now ready."),
                section("Toolbar location", "Open in REAPER: View -> Floating toolbar"),
                section("Backup", "A backup of reaper-menu.ini was created before writing."),
                section("Recommended order", table.concat(recommendedToolbarOrder, "\n"))
            ) .. existingUpdateLine .. (isDebugEnabled() and "\n\nTechnical details were written to the REAPER console." or ""),
            0
        )
        debugConsole(toolbarInfo)
    else
        debugConsole("Toolbar write failed/skipped: " .. tostring(toolbarInfo))
        msgBox(
            toolbarDialogTitle("Toolbar Not Written"),
            joinBlocks(
                "STEMwerk Toolbar Setup\n" .. hr(),
                section("Result", tostring(toolbarInfo)),
                section("Safety", "No random toolbar sections were modified."),
                section("Manual setup", toolbarOrderSummary),
                section("What you can do", "Retry this setup, or configure toolbar actions manually from the Action List.")
            ),
            0
        )
    end
elseif flowChoice == 7 then
    msgBox(
        toolbarDialogTitle("Manual Toolbar Setup"),
        joinBlocks(
            "STEMwerk Toolbar Setup\n" .. hr(),
            section("Manual setup", "1) Open Action List\n2) Search for STEMwerk\n3) Add the actions to your toolbar\n4) Assign icons from REAPER Data/toolbar_icons (use 200/ for hiDPI/retina; single/ icons are optional for custom/manual use)."),
            section("Recommended order", table.concat(recommendedToolbarOrder, "\n")),
            section("Tip", "Run 'STEMwerk: Setup' if separation fails or components are missing.")
        ),
        0
    )
end
