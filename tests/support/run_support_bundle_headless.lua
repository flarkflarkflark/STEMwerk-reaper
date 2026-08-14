local SEP = package.config:sub(1, 1)
local IS_WINDOWS = SEP == "\\"

local function detectUnixName()
    if IS_WINDOWS then
        return "Windows"
    end
    local handle = io.popen("uname -s 2>/dev/null", "r")
    if not handle then
        return "Linux"
    end
    local out = handle:read("*a") or ""
    handle:close()
    out = (out:gsub("%s+$", ""))
    if out == "Darwin" then
        return "macOS"
    end
    return "Linux"
end

local PLATFORM_NAME = detectUnixName()
local REAL_IO_POPEN = io.popen
local REAL_OS_GETENV = os.getenv
local ENV_OVERRIDES = nil
local COMMAND_INTERCEPTOR = nil

local function trim(value)
    local text = tostring(value or "")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function joinPath(...)
    local parts = { ... }
    local out = ""
    for i = 1, #parts do
        local part = tostring(parts[i] or "")
        if part ~= "" then
            part = part:gsub("[/\\]+", SEP)
            if out == "" then
                out = part:gsub("[/\\]+$", "")
            else
                part = part:gsub("^[/\\]+", ""):gsub("[/\\]+$", "")
                out = out .. SEP .. part
            end
        end
    end
    return out
end

local function normalizePath(path)
    local text = tostring(path or "")
    if IS_WINDOWS then
        return text:gsub("/", "\\"):lower()
    end
    return text:gsub("\\", "/")
end

local function assertf(condition, message)
    if not condition then
        error(message, 2)
    end
end

local function shellQuote(path)
    local text = tostring(path or "")
    if IS_WINDOWS then
        return '"' .. text:gsub('"', '""') .. '"'
    end
    if text == "" then
        return "''"
    end
    return "'" .. text:gsub("'", "'\\''") .. "'"
end

local function fileExists(path)
    local f = io.open(path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then
        return nil
    end
    local data = f:read("*a")
    f:close()
    return data
end

local function writeFile(path, data)
    local f = io.open(path, "wb")
    assertf(f ~= nil, "Could not open for writing: " .. tostring(path))
    f:write(data or "")
    f:close()
end

local function pathExists(path)
    if not path or path == "" then
        return false
    end
    local ok, _, code = os.rename(path, path)
    if ok then
        return true
    end
    return tonumber(code) == 13
end

local function mkdirP(path)
    if not path or path == "" then
        return
    end
    if pathExists(path) then
        return
    end
    if IS_WINDOWS then
        os.execute('mkdir "' .. tostring(path):gsub('"', '""') .. '" >nul 2>nul')
    else
        os.execute("mkdir -p " .. shellQuote(path) .. " >/dev/null 2>&1")
    end
    assertf(pathExists(path), "Failed to create directory: " .. tostring(path))
end

local function removeTree(path)
    if not path or path == "" or not pathExists(path) then
        return
    end
    if IS_WINDOWS then
        os.execute('rmdir /S /Q "' .. tostring(path):gsub('"', '""') .. '" >nul 2>nul')
    else
        os.execute("rm -rf " .. shellQuote(path) .. " >/dev/null 2>&1")
    end
end

local function parentDir(path)
    return tostring(path or ""):match("^(.*)[/\\][^/\\]+$") or ""
end

local function listChildren(path, wantDirs)
    if not pathExists(path) then
        return {}
    end
    local cmd
    if IS_WINDOWS then
        cmd = string.format(
            'cmd.exe /d /c dir /B %s %s 2>nul',
            wantDirs and "/AD" or "/A-D",
            shellQuote(path)
        )
    else
        cmd = string.format(
            'find %s -mindepth 1 -maxdepth 1 -type %s -exec basename {} \\; 2>/dev/null',
            shellQuote(path),
            wantDirs and "d" or "f"
        )
    end
    local handle = REAL_IO_POPEN(cmd, "r")
    if not handle then
        return {}
    end
    local out = handle:read("*a") or ""
    handle:close()
    local items = {}
    for line in out:gmatch("[^\r\n]+") do
        items[#items + 1] = trim(line)
    end
    table.sort(items)
    return items
end

local function walkFiles(root)
    local files = {}
    local function walk(path)
        for _, fileName in ipairs(listChildren(path, false)) do
            files[#files + 1] = joinPath(path, fileName)
        end
        for _, dirName in ipairs(listChildren(path, true)) do
            walk(joinPath(path, dirName))
        end
    end
    if pathExists(root) then
        walk(root)
    end
    table.sort(files)
    return files
end

local function makeFakeHandle(output, exitCode)
    local data = output or ""
    local code = tonumber(exitCode) or 0
    return {
        read = function()
            return data
        end,
        close = function()
            if code == 0 then
                return true
            end
            return nil, "exit", code
        end,
    }
end

os.getenv = function(key)
    if ENV_OVERRIDES and ENV_OVERRIDES[key] ~= nil then
        return ENV_OVERRIDES[key]
    end
    return REAL_OS_GETENV(key)
end

io.popen = function(cmd, mode)
    if COMMAND_INTERCEPTOR then
        local handled, handle = COMMAND_INTERCEPTOR(cmd, mode)
        if handled then
            return handle
        end
    end
    return REAL_IO_POPEN(cmd, mode)
end

local function scriptDir()
    local info = debug.getinfo(1, "S")
    return (info and info.source and info.source:match("@?(.*[/\\])")) or "."
end

local function getCwd()
    local cmd = IS_WINDOWS and "cd" or "pwd"
    local handle = REAL_IO_POPEN(cmd, "r")
    if not handle then
        return "."
    end
    local out = trim(handle:read("*a") or "")
    handle:close()
    return out ~= "" and out or "."
end

local TEST_DIR = scriptDir()
if not TEST_DIR:match("^%a:[/\\]") and TEST_DIR:sub(1, 1) ~= "/" then
    TEST_DIR = joinPath(getCwd(), TEST_DIR)
end
local REPO_ROOT = TEST_DIR:gsub("[/\\]tests[/\\]support[/\\]?$", "")
local ACTION_SCRIPT = joinPath(REPO_ROOT, "scripts", "reaper", "STEMwerk_Save_Support_Bundle.lua")
-- Loaded once so end-to-end fixtures can call the REAL SW_LOG.persistRunDiagnostics
-- production copy path (not manual fixture injection into the persisted
-- location) -- see the Direct Kit persisted-helper-conflict/match fixtures
-- below.
dofile(joinPath(REPO_ROOT, "scripts", "reaper", "_internal", "STEMwerk_Log.lua"))

local function currentTempBase()
    if IS_WINDOWS then
        return os.getenv("TEMP") or os.getenv("TMP") or joinPath(os.getenv("USERPROFILE") or "C:\\", "Temp")
    end
    return os.getenv("TMPDIR") or "/tmp"
end

local function writePlaceholder(path)
    mkdirP(parentDir(path))
    writeFile(path, "placeholder\n")
end

local function waitNextSecond()
    local start = os.time()
    repeat until os.time() > start
end

local function containsNormalized(haystack, needle)
    return normalizePath(haystack):find(normalizePath(needle), 1, true) ~= nil
end

local function mockPowerShellZip(cmd)
    if not IS_WINDOWS then
        return false
    end
    local lower = cmd:lower()
    if not lower:find("powershell.exe", 1, true) or not lower:find("compress%-archive") then
        return false
    end

    local dst = cmd:match("%$dst%s*=%s*'(.-)'%s*;")
    if not dst or dst == "" then
        return true, makeFakeHandle("mock PowerShell zip command missing destination\n", 1)
    end
    writePlaceholder(dst:gsub("''", "'"))
    return true, makeFakeHandle("", 0)
end

local function isWhichCommand(cmd, name)
    local lower = cmd:lower()
    if IS_WINDOWS then
        return lower:find("where.exe", 1, true) and lower:find(name:lower(), 1, true)
    end
    return lower:match("^%s*which%s+") and lower:find(name, 1, true)
end

local function makeCommandInterceptor(context)
    return function(cmd)
        local lower = cmd:lower()
        local handled, handle = mockPowerShellZip(cmd)
        if handled then
            return true, handle
        end

        if context.disableCommandResolution then
            if isWhichCommand(cmd, "python3") or isWhichCommand(cmd, "python")
                or isWhichCommand(cmd, "ffmpeg") then
                return true, makeFakeHandle("", 1)
            end
        end

        if context.fakePythonPath and containsNormalized(cmd, context.fakePythonPath) then
            if lower:find("--version", 1, true) or lower:find(" -v", 1, true) then
                return true, makeFakeHandle("Python 3.11.9\n", 0)
            end
            return true, makeFakeHandle(table.concat({
                "python_executable=" .. context.fakePythonPath,
                "python_version=3.11.9",
                "numpy=2.1.1",
                "numba=0.60.0",
                "llvmlite=0.43.0",
                "torch=2.5.1",
                "torchvision=0.20.1",
                "torchaudio=2.5.1",
                "audio_separator=0.30.1",
                "audio_separator_dist=0.30.1",
                "onnxruntime=1.19.2",
                "stemwerk_core=0.0.0-test",
                "torch_directml=missing (PackageNotFoundError)",
                "torch_cuda_available=false",
                "torch_cuda_device_count=0",
                "torch_cuda_version=",
                "torch_hip_version=6.2.0",
                "torch_mps_built=false",
                "torch_mps_available=false",
                "onnxruntime_providers=CPUExecutionProvider, ROCMExecutionProvider",
                "directml_device_count=0",
                "",
            }, "\n"), 0)
        end

        if context.fakeFfmpegPath and containsNormalized(cmd, context.fakeFfmpegPath) then
            return true, makeFakeHandle("ffmpeg version 7.0-fake\n", 0)
        end

        return false
    end
end

local function makeReaperMock(resourcePath, extState)
    local boxes = {}
    local function enumerate(path, idx, wantDirs)
        local items = listChildren(path, wantDirs)
        return items[(tonumber(idx) or 0) + 1]
    end

    local function showMessageBox(text, title, boxType)
        boxes[#boxes + 1] = {
            text = tostring(text or ""),
            title = tostring(title or ""),
            boxType = tonumber(boxType) or 0,
        }
        if tonumber(boxType) == 4 then
            return 7
        end
        return 1
    end

    return {
        _boxes = boxes,
        GetResourcePath = function()
            return resourcePath
        end,
        GetAppVersion = function()
            return "7.50/headless"
        end,
        GetOS = function()
            if IS_WINDOWS then return "Win64" end
            if PLATFORM_NAME == "macOS" then return "OSX64" end
            return "Linux"
        end,
        ShowMessageBox = showMessageBox,
        MB = showMessageBox,
        CF_ShellExecute = function()
            return true
        end,
        RecursiveCreateDirectory = function(path)
            mkdirP(path)
        end,
        EnumerateFiles = function(path, idx)
            return enumerate(path, idx, false)
        end,
        EnumerateSubdirectories = function(path, idx)
            return enumerate(path, idx, true)
        end,
        GetExtState = function(section, key)
            if tostring(section) ~= "STEMwerk" then
                return ""
            end
            return extState[key] or ""
        end,
        ReaPack_GetVersion = function()
            return "1.2.4-headless"
        end,
    }
end

local function makeCommonEnv(baseRoot, tempRoot)
    local env = {
        HOME = joinPath(baseRoot, "home"),
        XDG_DATA_HOME = joinPath(baseRoot, "xdg-data"),
        TMPDIR = tempRoot,
        TMP = tempRoot,
        TEMP = tempRoot,
    }
    if IS_WINDOWS then
        env.USERPROFILE = joinPath(baseRoot, "home")
        env.LOCALAPPDATA = joinPath(baseRoot, "local-app-data")
        env.APPDATA = joinPath(baseRoot, "app-data")
    end
    for _, value in pairs(env) do
        mkdirP(value)
    end
    return env
end

local function createPresentScenario(baseRoot)
    local resourcePath = joinPath(baseRoot, "resource-present")
    local tempRoot = joinPath(baseRoot, "tmp-present")
    local env = makeCommonEnv(baseRoot, tempRoot)
    local runtimeBase = joinPath(baseRoot, "runtime-present")
    local runtimeStateDir = joinPath(runtimeBase, "state")
    local runtimeLogsDir = joinPath(runtimeBase, "logs")
    local fakePythonPath = joinPath(baseRoot, "bin", IS_WINDOWS and "fake-python.cmd" or "fake-python")
    local fakeFfmpegPath = joinPath(baseRoot, "bin", IS_WINDOWS and "fake-ffmpeg.cmd" or "fake-ffmpeg")
    local tempDir = joinPath(tempRoot, "STEMwerk_fake_present")
    local mediaBase = IS_WINDOWS and "C:\\Users\\Headless\\Music\\private_song.wav" or "/home/headless/Music/private_song.wav"
    local projectPath = IS_WINDOWS and "C:\\Users\\Headless\\Projects\\private_project.rpp" or "/home/headless/Projects/private_project.rpp"

    mkdirP(resourcePath)
    mkdirP(joinPath(resourcePath, "UserPlugins"))
    mkdirP(runtimeStateDir)
    mkdirP(runtimeLogsDir)
    mkdirP(tempDir)
    mkdirP(joinPath(tempDir, "peaks"))
    mkdirP(joinPath(tempDir, "nested"))
    writePlaceholder(fakePythonPath)
    writePlaceholder(fakeFfmpegPath)

    writeFile(joinPath(resourcePath, "reapack.ini"), "Version=1.2.4-headless\n")
    writeFile(joinPath(runtimeStateDir, "bootstrap.env"), table.concat({
        "PYTHON_PATH=" .. fakePythonPath,
        "FFMPEG_PATH=" .. fakeFfmpegPath,
        "STATUS=ok",
        "BACKEND=rocm",
        "BOOTSTRAP_STATUS=ok",
        "VENV_PYTHON=" .. fakePythonPath,
        "RUNTIME_VERIFY_DETAIL=ok",
        "",
    }, "\n"))
    writeFile(joinPath(runtimeStateDir, "capabilities.env"), table.concat({
        "PROFILE=linux-rocm",
        "BACKEND=rocm",
        "VERIFICATION=ok",
        "PYTHON_PATH=" .. fakePythonPath,
        "FFMPEG_PATH=" .. fakeFfmpegPath,
        "BOOTSTRAP_STATUS=ok",
        "",
    }, "\n"))
    writeFile(joinPath(runtimeStateDir, "bootstrap.pid"), "12345\n")
    writeFile(joinPath(runtimeStateDir, "bootstrap.guard"), "STATUS=ok\nREASON=completed\n")
    writeFile(joinPath(runtimeLogsDir, "bootstrap.log"), table.concat({
        "bootstrap ok",
        "ERROR: Could not find a version that satisfies the requirement onnxruntime-silicon",
        "ERROR: No matching distribution found for onnxruntime-silicon",
        "WARN: onnxruntime-silicon install failed; falling back to onnxruntime",
        "Successfully installed flatbuffers-25.12.19 onnxruntime-1.27.0",
        "Runtime verification passed.",
        "input=" .. joinPath(tempDir, "input.wav"),
        "source=" .. mediaBase,
        "project=" .. projectPath,
        "",
    }, "\n"))
    writeFile(joinPath(runtimeLogsDir, "historical-repair.log"), "ERROR: historical retained failure\n")
    writeFile(joinPath(tempDir, "separation_log.txt"), table.concat({
        "separation started",
        joinPath(tempDir, "input.wav"),
        joinPath(tempDir, "bass.wav"),
        joinPath(tempDir, "drums.wav"),
        joinPath(tempDir, "vocals.wav"),
        joinPath(tempDir, "other.wav"),
        projectPath,
        mediaBase,
        "",
    }, "\n"))
    writeFile(joinPath(tempDir, "stdout.txt"), "stdout path " .. joinPath(tempDir, "bass.wav") .. "\n")
    writeFile(joinPath(tempDir, "stderr.txt"), "stderr path " .. mediaBase .. "\n")
    writeFile(joinPath(tempDir, "nested", "debug.log"), "nested log " .. projectPath .. "\n")
    writeFile(joinPath(tempRoot, "STEMwerk_debug.log"), "debug " .. joinPath(tempDir, "other.wav") .. "\n")

    local intelJob = joinPath(env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_intel_six", "single")
    mkdirP(intelJob)
    writeFile(joinPath(intelJob, "phase_events.jsonl"),
        '{"time":1,"model":"htdemucs_6s","device":"cpu","result":"success","output_count":6,"output_names":"bass,drums,guitar,other,piano,vocals","output_validation_reason":"ok"}\n')
    writeFile(joinPath(intelJob, "timing_events.jsonl"), '{"time":2,"result":"success"}\n')
    writeFile(joinPath(intelJob, "done.txt"), "done\n")
    writeFile(joinPath(intelJob, "exit_code.txt"), "0\n")

    local evidenceRoot = joinPath(runtimeBase, "evidence", "current-session")
    local sessionId = "native-apple-silicon-2306-final"
    mkdirP(evidenceRoot)
    writeFile(joinPath(evidenceRoot, "session.env"), table.concat({
        "EVIDENCE_SCHEMA=1",
        "SESSION_ID=" .. sessionId,
        "SESSION_STARTED_UTC=2026-07-24T13:00:00Z",
        "",
    }, "\n"))
    local phases = {
        { "verify", "online", "ok", "mps", "not_applicable" },
        { "online_normal", "online", "ok", "mps", "ok" },
        { "online_drum", "online", "ok", "mps", "ok" },
        { "bundled_recovery", "bundled", "ok", "mps", "not_applicable" },
        { "post_bundled_normal", "bundled", "ok", "mps", "ok" },
        { "post_bundled_drum", "bundled", "ok", "mps", "ok" },
    }
    for _, phase in ipairs(phases) do
        local phaseDir = joinPath(evidenceRoot, phase[1])
        mkdirP(phaseDir)
        writeFile(joinPath(phaseDir, "evidence.env"), table.concat({
            "EVIDENCE_SCHEMA=1",
            "SESSION_ID=" .. sessionId,
            "PHASE=" .. phase[1],
            "DISTRIBUTION=" .. phase[2],
            "STATUS=" .. phase[3],
            "TIMESTAMP_UTC=2026-07-24T13:10:00Z",
            "BACKEND=metal",
            "DEVICE=" .. phase[4],
            "RUNTIME_ARCH=arm64",
            "OUTPUT_VALIDATION_REASON=" .. phase[5],
            "CURRENT_FATAL_ERROR_COUNT=0",
            "",
        }, "\n"))
        writeFile(joinPath(phaseDir, "phase_events.jsonl"), '{"phase":"' .. phase[1] .. '","status":"ok"}\n')
        writeFile(joinPath(phaseDir, "timing_events.jsonl"), '{"phase":"' .. phase[1] .. '","seconds":1.0}\n')
        writeFile(joinPath(phaseDir, "output_validation.txt"), "output_validation_reason=" .. phase[5] .. "\nbackend=metal\ndevice=" .. phase[4] .. "\nruntime_arch=arm64\n")
    end

    writeFile(joinPath(tempDir, "input.wav"), string.rep("a", 128))
    writeFile(joinPath(tempDir, "bass.wav"), string.rep("b", 64))
    writeFile(joinPath(tempDir, "drums.wav"), string.rep("c", 64))
    writeFile(joinPath(tempDir, "vocals.wav"), string.rep("d", 64))
    writeFile(joinPath(tempDir, "other.wav"), string.rep("e", 64))
    writeFile(joinPath(tempDir, "model.onnx"), string.rep("m", 256))
    writeFile(joinPath(tempDir, "weights.pt"), string.rep("p", 256))
    writeFile(joinPath(tempDir, "peaks", "input.wav.reapeaks"), "peaks\n")

    return {
        name = "present-runtime",
        resourcePath = resourcePath,
        env = env,
        extState = {
            runtimeBase = runtimeBase,
            pythonPath = fakePythonPath,
            ffmpegPath = fakeFfmpegPath,
            device = "auto",
            model = "htdemucs_ft",
            createNewTracks = "1",
            createFolder = "1",
            stemFileDestination = "custom",
            customStemDir = mediaBase,
            postProcessTakes = "glue",
            language = "en",
            parallelProcessing = "1",
            keepTempFiles = "0",
            colorMode = "both",
            themePreset = "classic",
            visualFX = "1",
            tooltips = "1",
            muteOriginal = "0",
            muteSelection = "0",
            deleteOriginal = "0",
            deleteSelection = "0",
            deleteOriginalTrack = "0",
            muteOriginalTrack = "0",
            debugMode = "1",
        },
        fakePythonPath = fakePythonPath,
        fakeFfmpegPath = fakeFfmpegPath,
        disableCommandResolution = false,
        expectedRawPaths = {
            joinPath(tempDir, "input.wav"),
            joinPath(tempDir, "bass.wav"),
            joinPath(tempDir, "drums.wav"),
            joinPath(tempDir, "vocals.wav"),
            joinPath(tempDir, "other.wav"),
            mediaBase,
            projectPath,
            tempDir,
        },
    }
end

local function createMissingScenario(baseRoot)
    local resourcePath = joinPath(baseRoot, "resource-missing")
    local tempRoot = joinPath(baseRoot, "tmp-missing")
    local env = makeCommonEnv(baseRoot, tempRoot)
    local runtimeBase = joinPath(baseRoot, "runtime-missing")
    mkdirP(resourcePath)
    mkdirP(joinPath(resourcePath, "UserPlugins"))
    writeFile(joinPath(resourcePath, "reapack.ini"), "Version=1.2.4-headless\n")

    return {
        name = "missing-runtime",
        resourcePath = resourcePath,
        env = env,
        extState = {
            runtimeBase = runtimeBase,
            pythonPath = "",
            ffmpegPath = "",
            device = "auto",
            model = "htdemucs",
            customStemDir = "",
        },
        disableCommandResolution = true,
        expectedRawPaths = {},
    }
end

local function latestBundleDir(resourcePath)
    local bundlesRoot = joinPath(resourcePath, "STEMwerk-support-bundles")
    local dirs = listChildren(bundlesRoot, true)
    table.sort(dirs)
    local latest = dirs[#dirs]
    if not latest then
        return nil
    end
    return joinPath(bundlesRoot, latest)
end

local function readBundleText(bundleDir)
    local chunks = {}
    for _, path in ipairs(walkFiles(bundleDir)) do
        local lower = path:lower()
        if lower:match("%.txt$") or lower:match("%.log$") or lower:match("%.env$") or lower:match("%.pid$")
            or lower:match("diagnostics") or lower:match("readme") then
            local data = readFile(path)
            if data then
                chunks[#chunks + 1] = data
            end
        end
    end
    return table.concat(chunks, "\n")
end

local FORBIDDEN_EXTENSIONS = {
    ".wav", ".flac", ".mp3", ".aiff", ".aif", ".m4a", ".ogg", ".opus", ".mp4", ".mov",
    ".onnx", ".pth", ".pt", ".ckpt",
}

local function assertNoForbiddenFiles(bundleDir)
    for _, path in ipairs(walkFiles(bundleDir)) do
        local lower = path:lower()
        for i = 1, #FORBIDDEN_EXTENSIONS do
            if lower:sub(-#FORBIDDEN_EXTENSIONS[i]) == FORBIDDEN_EXTENSIONS[i] then
                error("Forbidden payload copied into bundle: " .. path, 2)
            end
        end
    end
end

local function assertMaxFileSize(bundleDir, maxBytes)
    for _, path in ipairs(walkFiles(bundleDir)) do
        local data = readFile(path) or ""
        assertf(#data <= maxBytes, "Bundle file too large for headless fixture: " .. path)
    end
end

local function assertPresentScenario(bundleDir, context)
    assertf(fileExists(joinPath(bundleDir, "README.txt")), "README.txt missing")
    assertf(fileExists(joinPath(bundleDir, "diagnostics.txt")), "diagnostics.txt missing")
    assertf(fileExists(joinPath(bundleDir, "platform_details.txt")), "platform_details.txt missing")
    assertf(fileExists(joinPath(bundleDir, "python_diagnostics.txt")), "python_diagnostics.txt missing")
    assertf(fileExists(joinPath(bundleDir, "drumsep_runtime_status.txt")), "drumsep_runtime_status.txt missing")
    assertf(fileExists(joinPath(bundleDir, "temp_inventory.txt")), "temp_inventory.txt missing")
    assertf(fileExists(joinPath(bundleDir, "runtime_state", "bootstrap.env")), "bootstrap.env not copied")
    assertf(fileExists(joinPath(bundleDir, "runtime_state", "capabilities.env")), "capabilities.env not copied")
    assertf(fileExists(joinPath(bundleDir, "runtime_logs", "bootstrap.log")), "bootstrap.log not copied")
    assertf(fileExists(joinPath(bundleDir, "support_evidence_manifest.txt")), "support evidence manifest missing")
    assertf(fileExists(joinPath(bundleDir, "temp_logs", "STEMwerk_fake_present", "separation_log.txt")), "temp separation log not copied")
    assertf(fileExists(joinPath(bundleDir, "temp_logs", "STEMwerk_fake_present", "stdout.txt")), "temp stdout log not copied")

    local diagnostics = readFile(joinPath(bundleDir, "diagnostics.txt")) or ""
    local pythonDiagnostics = readFile(joinPath(bundleDir, "python_diagnostics.txt")) or ""
    local drumsepDiagnostics = readFile(joinPath(bundleDir, "drumsep_runtime_status.txt")) or ""
    local tempInventory = readFile(joinPath(bundleDir, "temp_inventory.txt")) or ""
    local allText = readBundleText(bundleDir)
    local evidenceManifest = readFile(joinPath(bundleDir, "support_evidence_manifest.txt")) or ""
    local processingSummary = readFile(joinPath(bundleDir, "processing_summary.txt")) or ""

    assertf(diagnostics:find("STEMwerk package version", 1, true) ~= nil, "diagnostics missing version block")
    if IS_WINDOWS then
        assertf(diagnostics:find("Python version", 1, true) ~= nil and diagnostics:find("skipped for speed", 1, true) ~= nil,
            "diagnostics missing Windows Python skip marker")
        assertf(diagnostics:find("FFmpeg version", 1, true) ~= nil and diagnostics:find("skipped for speed", 1, true) ~= nil,
            "diagnostics missing Windows FFmpeg skip marker")
    else
        assertf(diagnostics:find("Python version", 1, true) ~= nil and diagnostics:find("3.11.9", 1, true) ~= nil, "diagnostics missing Python version")
        assertf(diagnostics:find("FFmpeg version", 1, true) ~= nil and diagnostics:find("ffmpeg version 7.0-fake", 1, true) ~= nil, "diagnostics missing FFmpeg version")
    end
    assertf(trim(pythonDiagnostics) ~= "", "python_diagnostics.txt is empty")
    assertf(drumsepDiagnostics:find("DrumSep Runtime Diagnostics", 1, true) ~= nil, "drumsep runtime diagnostics missing header")
    assertf(drumsepDiagnostics:find("[CPU fallback runtime]", 1, true) ~= nil, "drumsep runtime diagnostics missing CPU section")
    assertf(drumsepDiagnostics:find("[ROCm runtime]", 1, true) ~= nil, "drumsep runtime diagnostics missing ROCm section")
    if IS_WINDOWS then
        assertf(pythonDiagnostics:find("Python diagnostics skipped for speed.", 1, true) ~= nil,
            "Windows python diagnostics missing skip payload")
    else
        assertf(pythonDiagnostics:find("python_version=3.11.9", 1, true) ~= nil, "python diagnostics missing version payload")
    end
    assertf(allText:find("[TEMP_AUDIO_FILE]", 1, true) ~= nil, "sanitization placeholder not present")
    assertf(allText:find("[STEMWERK_TEMP_DIR]", 1, true) ~= nil, "temp directory placeholder not present")
    assertf(tempInventory:find("| file |", 1, true) ~= nil, "temp inventory missing file metadata")
    assertf(tempInventory:find("stemwerk%-support%-bundle%-headless%-", 1) == nil, "headless support-bundle fixture leaked into temp inventory")
    assertf(evidenceManifest:find("manifest_status:%s+complete") ~= nil, "current-session evidence manifest is not complete")
    assertf(evidenceManifest:find("phases_included:%s+6") ~= nil, "not all current-session phases were included")
    assertf(evidenceManifest:find("handled_recovery_event:%s+yes") ~= nil, "handled ONNX fallback not classified")
    assertf(evidenceManifest:find("local_onnxruntime_version:%s+1%.27%.0") ~= nil, "local ONNX fallback version missing")
    assertf(evidenceManifest:find("current_fatal_errors:%s+none") ~= nil, "recovered ONNX fallback classified as fatal")
    assertf(evidenceManifest:find("historical_errors_scope:%s+runtime_logs_except_current_bootstrap_and_current_session_evidence") ~= nil,
        "historical error scope not separated")
    assertf(fileExists(joinPath(bundleDir, "runtime_logs", "historical-repair.log")), "historical error log was not preserved")
    assertf(processingSummary:find("found_stems: bass,drums,guitar,other,piano,vocals", 1, true) ~= nil,
        "six-stem output names were not parsed from actual phase evidence")
    assertf(processingSummary:find("output_validation_reason: ok", 1, true) ~= nil,
        "actual output validation reason was not preserved")
    -- The model (htdemucs_6s) is only known from this job's own late
    -- phase_events.jsonl evidence, not from anything decided up-front; the
    -- expected/found stem counts must be recomputed AFTER that resolution,
    -- not frozen before it. Six raw outputs must report as 6/6, not 4/4.
    assertf(processingSummary:find("outputs 6/6", 1, true) ~= nil,
        "late-resolved 6-Stem model did not report 6/6 outputs:\n" .. processingSummary)
    assertf(processingSummary:find("outputs 4/4", 1, true) == nil,
        "6-Stem run was frozen to a stale 4/4 expectation")
    -- Copy-Summary-equivalent provenance: the resolved runtime health,
    -- resolved backend, and probe/state provenance the verdict is based on
    -- must all be visible in the collected evidence, not hidden behind a
    -- bare pass/fail.
    assertf(evidenceManifest:find("final_runtime_health:%s+ok") ~= nil,
        "resolved runtime health missing from evidence manifest")
    assertf(evidenceManifest:find("acceptance_phases_status:%s+complete") ~= nil,
        "acceptance phase provenance missing from evidence manifest")
    -- Test-audit correction (fifth diagnostics fix): this fixture's
    -- final_runtime_health=ok is proven by its six healthy ACCEPTANCE
    -- PHASES only. Its persisted run (STEMwerk_intel_six) deliberately
    -- lacks current run identity, so it must NOT count as current worker
    -- evidence -- earlier reporting credited this fixture as
    -- worker-health coverage ("cached bootstrap + current success"), which
    -- was wrong. Worker-only proof with ZERO acceptance phases is covered
    -- by the dedicated *-no-phases fixtures below instead.
    assertf(evidenceManifest:find("current_worker_health:%s+not_proven") ~= nil,
        "present-runtime's non-current-identity run must not prove worker health:\n" .. evidenceManifest)
    assertf(evidenceManifest:find("final_runtime_health_source:%s+current_phase_evidence") ~= nil,
        "present-runtime's health must be attributed to acceptance-phase evidence, not workers:\n" .. evidenceManifest)
    assertf(evidenceManifest:find("handled_recovery_event:%s+yes") ~= nil,
        "recovery/provenance reasoning missing from evidence manifest")
    for _, phase in ipairs({ "verify", "online_normal", "online_drum", "bundled_recovery", "post_bundled_normal", "post_bundled_drum" }) do
        assertf(fileExists(joinPath(bundleDir, "current_session_evidence", phase, "evidence.env")), "phase evidence missing: " .. phase)
        assertf(fileExists(joinPath(bundleDir, "current_session_evidence", phase, "phase_events.jsonl")), "phase events missing: " .. phase)
        assertf(fileExists(joinPath(bundleDir, "current_session_evidence", phase, "timing_events.jsonl")), "timing events missing: " .. phase)
    end

    for _, rawPath in ipairs(context.expectedRawPaths) do
        assertf(allText:find(rawPath, 1, true) == nil, "Raw path leaked into bundle text: " .. rawPath)
    end

    assertNoForbiddenFiles(bundleDir)
    assertMaxFileSize(bundleDir, 1024 * 1024)
end

local function assertMissingScenario(bundleDir)
    assertf(fileExists(joinPath(bundleDir, "README.txt")), "README.txt missing")
    assertf(fileExists(joinPath(bundleDir, "diagnostics.txt")), "diagnostics.txt missing")
    assertf(fileExists(joinPath(bundleDir, "platform_details.txt")), "platform_details.txt missing")
    assertf(fileExists(joinPath(bundleDir, "python_diagnostics.txt")), "python_diagnostics.txt missing")
    assertf(fileExists(joinPath(bundleDir, "drumsep_runtime_status.txt")), "drumsep_runtime_status.txt missing")
    assertf(fileExists(joinPath(bundleDir, "temp_inventory.txt")), "temp_inventory.txt missing")

    local diagnostics = readFile(joinPath(bundleDir, "diagnostics.txt")) or ""
    local pythonDiagnostics = readFile(joinPath(bundleDir, "python_diagnostics.txt")) or ""
    local drumsepDiagnostics = readFile(joinPath(bundleDir, "drumsep_runtime_status.txt")) or ""

    assertf(diagnostics:find("Python path", 1, true) ~= nil and diagnostics:find("missing", 1, true) ~= nil, "missing scenario did not report missing Python path")
    assertf(diagnostics:find("FFmpeg path", 1, true) ~= nil and diagnostics:find("missing", 1, true) ~= nil, "missing scenario did not report missing FFmpeg path")
    assertf(diagnostics:find("bootstrap.env", 1, true) ~= nil and diagnostics:find("missing", 1, true) ~= nil, "missing runtime files not reported")
    assertf(trim(pythonDiagnostics) ~= "", "missing scenario python_diagnostics.txt is empty")
    if IS_WINDOWS then
        assertf(pythonDiagnostics:find("Python diagnostics skipped for speed.", 1, true) ~= nil,
            "missing scenario Windows python diagnostics missing skip payload")
    else
        assertf(pythonDiagnostics:find("no Python path detected", 1, true) ~= nil or pythonDiagnostics:find("missing", 1, true) ~= nil,
            "missing scenario python diagnostics did not explain the failure")
    end
    assertf(drumsepDiagnostics:find("DrumSep Runtime Diagnostics", 1, true) ~= nil, "missing scenario drumsep diagnostics missing header")

    assertNoForbiddenFiles(bundleDir)
    assertMaxFileSize(bundleDir, 1024 * 1024)
end

local function createFailedFallbackScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "failed-onnx-fallback"
    local runtimeBase = context.extState.runtimeBase
    writeFile(joinPath(runtimeBase, "logs", "bootstrap.log"), table.concat({
        "ERROR: Could not find a version that satisfies the requirement onnxruntime-silicon",
        "ERROR: No matching distribution found for onnxruntime-silicon",
        "WARN: onnxruntime-silicon install failed; falling back to onnxruntime",
        "ERROR: No matching distribution found for onnxruntime",
        "Runtime verification failed.",
        "",
    }, "\n"))
    -- This scenario represents a bootstrap run that genuinely, currently
    -- failed: bootstrap.env's structured status must agree with the log
    -- text (a real failed run would not leave STATUS=ok behind), and there
    -- must be no other current-session evidence proving health. Without
    -- this, the fixture would contradict itself -- claiming the runtime is
    -- both currently broken (via the log) and currently healthy (via
    -- structured state / acceptance-phase evidence inherited unchanged from
    -- the present-runtime scenario) at the same time.
    writeFile(joinPath(runtimeBase, "state", "bootstrap.env"), table.concat({
        "PYTHON_PATH=" .. context.fakePythonPath,
        "FFMPEG_PATH=" .. context.fakeFfmpegPath,
        "STATUS=failed",
        "STATUS_REASON=runtime_verification_failed",
        "BACKEND=rocm",
        "BOOTSTRAP_STATUS=failed",
        "VENV_PYTHON=" .. context.fakePythonPath,
        "RUNTIME_VERIFY_DETAIL=failed",
        "",
    }, "\n"))
    removeTree(joinPath(runtimeBase, "evidence"))
    return context
end

local function assertFailedFallbackScenario(bundleDir)
    local manifest = readFile(joinPath(bundleDir, "support_evidence_manifest.txt")) or ""
    assertf(manifest:find("onnxruntime_silicon_lookup_failed:%s+yes") ~= nil, "failed lookup not recorded")
    assertf(manifest:find("handled_recovery_event:%s+no") ~= nil, "failed fallback incorrectly handled")
    assertf(manifest:find("local_onnxruntime_version:%s+none") ~= nil, "failed fallback invented a version")
    assertf(manifest:find("current_fatal_error_count:%s+1") ~= nil, "failed fallback not counted as fatal")
end

-- ---------------------------------------------------------------------
-- Diagnostics-truthfulness regression fixtures (release/2.3.1.0-final-prep).
-- Each of these clones the known-good "present" scenario and mutates only
-- what the fixture needs, so the rest of the runtime/state stays realistic.
-- ---------------------------------------------------------------------

local function readProcessingSummary(bundleDir)
    return readFile(joinPath(bundleDir, "processing_summary.txt")) or ""
end

local function readManifest(bundleDir)
    return readFile(joinPath(bundleDir, "support_evidence_manifest.txt")) or ""
end

-- Removes the single job the present-runtime fixture wrote under
-- runtime_runs, so a scenario can lay down its own run/job structure
-- instead.
local function clearRuns(context)
    local cacheRunsRoot = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs")
    removeTree(cacheRunsRoot)
end

local function createAmdRocmScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "amd-rocm-device-classification"
    clearRuns(context)
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_amd_rocm", "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "stdout.txt"), table.concat({
        "model: htdemucs",
        "device: cuda:0",
        "backend_runtime: rocm",
        "device_name: AMD Radeon RX 9070",
        "result: success",
        "done",
        "",
    }, "\n"))
    writeFile(joinPath(jobDir, "done.txt"), "done\n")
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    return context
end

local function assertAmdRocmScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    assertf(summary:find("friendly_device: AMD ROCm", 1, true) ~= nil,
        "cuda:0 with current-run HIP/ROCm+AMD evidence was not classified as AMD ROCm:\n" .. summary)
    assertf(summary:find("friendly_device: NVIDIA CUDA", 1, true) == nil,
        "cuda:0 with AMD ROCm evidence was misclassified as NVIDIA CUDA")
end

local function createNvidiaCudaScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "nvidia-cuda-device-classification"
    clearRuns(context)
    local runtimeBase = context.extState.runtimeBase
    -- The present-runtime fixture's bootstrap/capabilities record an AMD
    -- ROCm profile; this scenario is genuinely NVIDIA, so that stale
    -- inherited BACKEND must not leak in and falsely trip ROCm evidence.
    writeFile(joinPath(runtimeBase, "state", "bootstrap.env"), table.concat({
        "PYTHON_PATH=" .. context.fakePythonPath,
        "FFMPEG_PATH=" .. context.fakeFfmpegPath,
        "STATUS=ok",
        "BACKEND=cuda",
        "BOOTSTRAP_STATUS=ok",
        "VENV_PYTHON=" .. context.fakePythonPath,
        "RUNTIME_VERIFY_DETAIL=ok",
        "",
    }, "\n"))
    writeFile(joinPath(runtimeBase, "state", "capabilities.env"), table.concat({
        "PROFILE=linux-cuda",
        "BACKEND=cuda",
        "VERIFICATION=ok",
        "PYTHON_PATH=" .. context.fakePythonPath,
        "FFMPEG_PATH=" .. context.fakeFfmpegPath,
        "BOOTSTRAP_STATUS=ok",
        "",
    }, "\n"))
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_nvidia_cuda", "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "stdout.txt"), table.concat({
        "model: htdemucs",
        "device: cuda:0",
        "device_name: NVIDIA GeForce RTX 4090",
        "result: success",
        "done",
        "",
    }, "\n"))
    writeFile(joinPath(jobDir, "done.txt"), "done\n")
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    return context
end

local function assertNvidiaCudaScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    assertf(summary:find("friendly_device: NVIDIA CUDA", 1, true) ~= nil,
        "cuda:0 with no HIP/ROCm evidence and an NVIDIA device name was not classified as NVIDIA CUDA:\n" .. summary)
    assertf(summary:find("friendly_device: AMD ROCm", 1, true) == nil,
        "genuine NVIDIA cuda:0 run was misclassified as AMD ROCm")
end

-- Two runs, each identified only by a run-ID token embedded in
-- run_stemwerk.log, deliberately written so the log's line order is the
-- reverse of the directory-name sort order buildProcessingSummary uses.
-- Correct behavior requires exact run-ID (key-based) association; pairing
-- by array position would cross-attach one run's model to the other.
local function createShuffledRunAssociationScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "shuffled-run-id-association"
    clearRuns(context)
    local runsRoot = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs")

    -- "STEMwerk_run_zzz_last" sorts after "STEMwerk_run_alpha", so
    -- directory-descending order is [zzz_last, alpha] -- the reverse of the
    -- order the two runs appear in run_stemwerk.log below.
    for _, runName in ipairs({ "STEMwerk_run_alpha", "STEMwerk_run_zzz_last" }) do
        local jobDir = joinPath(runsRoot, runName, "job0")
        mkdirP(jobDir)
        -- Deliberately no model/device text in the job's own evidence: the
        -- model must come from the run-ID-keyed match in run_stemwerk.log,
        -- not from job-local parsing, so this fixture actually exercises
        -- the association path under test.
        writeFile(joinPath(jobDir, "timing_events.jsonl"), '{"time":1,"result":"success"}\n')
        writeFile(joinPath(jobDir, "done.txt"), "done\n")
        writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    end

    local runtimeLogsDir = joinPath(context.extState.runtimeBase, "logs")
    writeFile(joinPath(runtimeLogsDir, "run_stemwerk.log"), table.concat({
        "[2026-07-01 10:00:00] CMD: LAUNCH: STEMwerk_run_alpha --model htdemucs --device cpu",
        "RC: 0",
        "[2026-07-01 10:05:00] CMD: LAUNCH: STEMwerk_run_zzz_last --model htdemucs_6s --device cpu",
        "RC: 0",
        "",
    }, "\n"))
    return context
end

local function assertShuffledRunAssociationScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    local alphaBlock = summary:match("run: STEMwerk_run_alpha.-\n\n") or summary:match("run: STEMwerk_run_alpha.*")
    local lastBlock = summary:match("run: STEMwerk_run_zzz_last.-\n\n") or summary:match("run: STEMwerk_run_zzz_last.*")
    assertf(alphaBlock ~= nil, "STEMwerk_run_alpha run block missing from processing summary:\n" .. summary)
    assertf(lastBlock ~= nil, "STEMwerk_run_zzz_last run block missing from processing summary:\n" .. summary)
    assertf(alphaBlock:find("model: htdemucs\n", 1, true) ~= nil,
        "STEMwerk_run_alpha did not get its own key-matched model (htdemucs):\n" .. alphaBlock)
    assertf(alphaBlock:find("htdemucs_6s", 1, true) == nil,
        "STEMwerk_run_alpha was cross-contaminated with STEMwerk_run_zzz_last's model")
    assertf(lastBlock:find("model: htdemucs_6s", 1, true) ~= nil,
        "STEMwerk_run_zzz_last did not get its own key-matched model (htdemucs_6s):\n" .. lastBlock)
end

local function createParallelAggregationScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "parallel-output-aggregation"
    clearRuns(context)
    local runDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_parallel_three")
    for i = 1, 3 do
        local jobDir = joinPath(runDir, "job" .. tostring(i))
        mkdirP(jobDir)
        writeFile(joinPath(jobDir, "phase_events.jsonl"),
            '{"time":' .. tostring(i) .. ',"model":"htdemucs","device":"cpu","result":"success",'
            .. '"output_count":4,"output_validation_reason":"ok"}\n')
        writeFile(joinPath(jobDir, "done.txt"), "done\n")
        writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    end
    return context
end

local function assertParallelAggregationScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    assertf(summary:find("jobs: 3", 1, true) ~= nil, "parallel run did not record 3 jobs:\n" .. summary)
    assertf(summary:find("outputs 12/12", 1, true) ~= nil,
        "3 successful parallel jobs (4 outputs each) did not aggregate to 12/12 outputs:\n" .. summary)
    assertf(summary:find("output_validation_reason: ok", 1, true) ~= nil,
        "3 successful parallel jobs did not aggregate to a known (ok) validation reason:\n" .. summary)
    assertf(summary:find("outputs unknown", 1, true) == nil, "parallel aggregation left outputs unknown")
    assertf(summary:find("validation unknown", 1, true) == nil, "parallel aggregation left validation unknown")
end

local function createDirectKitScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "direct-kit-semantic-model"
    clearRuns(context)
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_direct_kit", "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "stdout.txt"), table.concat({
        "workflow_source: dks_direct",
        "workflow_mode: drumkit",
        -- Decoy: an unrelated Demucs model name appears in a path, purely
        -- to prove the flow-aware semantic model never surfaces it for a
        -- DrumSep-only Direct Kit run.
        "model_cache_dir: /models/htdemucs_backup",
        "model_id=MDX23C-DrumSep-aufr33-jarredou.ckpt",
        "result: success",
        "done",
        "",
    }, "\n"))
    writeFile(joinPath(jobDir, "done.txt"), "done\n")
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    return context
end

local function assertDirectKitScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    assertf(summary:find("Direct Kit", 1, true) ~= nil, "Direct Kit workflow label missing:\n" .. summary)
    assertf(summary:find("semantic_model: MDX23C%-DrumSep%-aufr33%-jarredou%.ckpt") ~= nil,
        "Direct Kit did not report its DrumSep model as the semantic model:\n" .. summary)
    assertf(summary:find("semantic_model: htdemucs", 1, true) == nil,
        "Direct Kit incorrectly attached an unrelated Demucs model as its semantic model")
end

local function createKitSplitScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "kit-split-two-stage-model"
    clearRuns(context)
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_kit_split", "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "stdout.txt"), table.concat({
        "workflow_source: dks_extract",
        "model: htdemucs_6s",
        "dks_extract_stage1_runtime=cuda",
        "dks_extract_stage1_device=cuda:0",
        "dks_extract_stage2_runtime=cpu",
        "dks_extract_stage2_device=cpu",
        "model_id=MDX23C-DrumSep-aufr33-jarredou.ckpt",
        "result: success",
        "done",
        "",
    }, "\n"))
    writeFile(joinPath(jobDir, "done.txt"), "done\n")
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    return context
end

local function assertKitSplitScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    assertf(summary:find("Kit Split", 1, true) ~= nil, "Kit Split workflow label missing:\n" .. summary)
    assertf(summary:find("stage1_model: htdemucs_6s", 1, true) ~= nil,
        "Kit Split stage1 (Demucs) model missing:\n" .. summary)
    assertf(summary:find("stage2_model: MDX23C%-DrumSep%-aufr33%-jarredou%.ckpt") ~= nil,
        "Kit Split stage2 (DrumSep) model missing:\n" .. summary)
    assertf(summary:find("stage2_device: CPU", 1, true) ~= nil, "Kit Split stage2 device missing:\n" .. summary)
    assertf(summary:find("semantic_model: stage1:htdemucs_6s %-> stage2:MDX23C%-DrumSep%-aufr33%-jarredou%.ckpt") ~= nil,
        "Kit Split collapsed its two stages into a single/wrong model:\n" .. summary)
end

local function createHealthyNoAcceptancePhasesScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "healthy-runtime-no-acceptance-phases"
    -- Bootstrap/capabilities are untouched (still cached-healthy:
    -- STATUS=ok, RUNTIME_VERIFY_DETAIL=ok), but the optional fixed
    -- six-phase acceptance-evidence tree was never collected for this
    -- session, so there is no CURRENT evidence at all.
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    return context
end

-- Section 4 (2.3.1.0 final-prep follow-up): bootstrap.env has no
-- freshness/session identity of its own -- a cached STATUS=ok there must
-- not, by itself, prove CURRENT runtime health when no acceptance-phase
-- fixtures were collected for this session. It is exposed as
-- bootstrap_readiness=cached_healthy (provenance), not final_runtime_health.
local function assertHealthyNoAcceptancePhasesScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertf(manifest:find("bootstrap_readiness:%s+cached_healthy") ~= nil,
        "cached bootstrap-healthy provenance was not exposed:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+not_proven") ~= nil,
        "a cached bootstrap-healthy claim with no current session evidence at all proved final_runtime_health=ok on its own:\n" .. manifest)
    assertf(manifest:find("acceptance_phases_status:%s+not_collected") ~= nil,
        "0/6 acceptance phases was not labeled not_collected:\n" .. manifest)
    assertf(manifest:find("phases_included:%s+0") ~= nil, "expected 0 phases included:\n" .. manifest)
end

local function createHistoricalRecoveredFatalScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "historical-onnx-failure-recovered"
    -- Bootstrap/capabilities and the current-session acceptance-phase
    -- evidence stay healthy (proving current, live workers), but
    -- bootstrap.log itself records an old/unresolved onnxruntime-silicon
    -- lookup failure with no successful local fallback recorded.
    local runtimeBase = context.extState.runtimeBase
    writeFile(joinPath(runtimeBase, "logs", "bootstrap.log"), table.concat({
        "ERROR: Could not find a version that satisfies the requirement onnxruntime-silicon",
        "ERROR: No matching distribution found for onnxruntime-silicon",
        "WARN: onnxruntime-silicon install failed; falling back to onnxruntime",
        "ERROR: No matching distribution found for onnxruntime",
        "",
    }, "\n"))
    return context
end

local function assertHistoricalRecoveredFatalScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertf(manifest:find("onnxruntime_silicon_lookup_failed:%s+yes") ~= nil,
        "historical lookup failure was not recorded at all:\n" .. manifest)
    assertf(manifest:find("current_fatal_error_count:%s+0") ~= nil,
        "old/historical ONNX failure was counted as a CURRENT fatal error despite proven-healthy current workers:\n" .. manifest)
    assertf(manifest:find("historical_onnxruntime_silicon_issue:%s+recovered_or_superseded_by_current_health") ~= nil,
        "historical issue was not separately labeled once superseded by current health:\n" .. manifest)
end

-- Section 3 (2.3.1.0 follow-up): a single persisted run plus a single
-- reconstructed run_stemwerk.log "session" (which carries no run-ID of its
-- own -- it is purely positional launch-order reconstruction) must NOT be
-- paired by array position, even when there is exactly one of each. The
-- session has no usable identity, so it must never fill in the run's model.
local function createSingleRunUnrelatedSessionScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "single-run-unrelated-session"
    clearRuns(context)
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_solo_run", "single")
    mkdirP(jobDir)
    -- Deliberately no model/device evidence of its own and no run-ID token
    -- shared with run_stemwerk.log below, so any model shown for this run
    -- can only have come from the (identity-less) positional session.
    writeFile(joinPath(jobDir, "done.txt"), "done\n")
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")

    local runtimeLogsDir = joinPath(context.extState.runtimeBase, "logs")
    writeFile(joinPath(runtimeLogsDir, "run_stemwerk.log"), table.concat({
        "[2026-07-01 10:00:00] CMD: LAUNCH: --model htdemucs_ft --device cuda:0",
        "[2026-07-01 10:00:05] CMD: timing:workers_launched count=1 mode=stems",
        "RC: 0",
        "",
    }, "\n"))
    return context
end

local function assertSingleRunUnrelatedSessionScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    assertf(summary:find("model: htdemucs_ft", 1, true) == nil,
        "an identity-less positional session filled in a model for an unrelated run:\n" .. summary)
end

-- One run whose own evidence has no usable run-ID token, and a
-- run_stemwerk.log session with a mismatched/missing token: association
-- must be marked unavailable rather than guessed from position.
local function createMissingTokenSessionScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "missing-token-session"
    clearRuns(context)
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_no_token", "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "done.txt"), "done\n")
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")

    local runtimeLogsDir = joinPath(context.extState.runtimeBase, "logs")
    -- No "STEMwerk_..." run-ID token anywhere in this log, so it can never
    -- be key-matched to any persisted run.
    writeFile(joinPath(runtimeLogsDir, "run_stemwerk.log"), table.concat({
        "[2026-07-01 09:00:00] CMD: LAUNCH: --model htdemucs --device cpu",
        "RC: 0",
        "",
    }, "\n"))
    return context
end

local function assertMissingTokenSessionScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    assertf(summary:find("model: htdemucs\n", 1, true) == nil,
        "a run-ID-less log session was guessed onto a run it cannot be identified with:\n" .. summary)
end

-- Replayed/duplicate run ID: the same run-ID token appears twice in
-- run_stemwerk.log with genuinely different (conflicting) model/device
-- evidence. Silently keeping the first block's data hides the fact that the
-- association is ambiguous; it must be surfaced instead of guessed.
local function createReplayedRunIdScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "replayed-duplicate-run-id"
    clearRuns(context)
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_dup_run", "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "done.txt"), "done\n")
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")

    local runtimeLogsDir = joinPath(context.extState.runtimeBase, "logs")
    writeFile(joinPath(runtimeLogsDir, "run_stemwerk.log"), table.concat({
        "[2026-07-01 10:00:00] CMD: LAUNCH: STEMwerk_dup_run --model htdemucs --device cpu",
        "RC: 0",
        "[2026-07-01 11:00:00] CMD: LAUNCH: STEMwerk_dup_run --model htdemucs_ft --device cuda:0",
        "RC: 0",
        "",
    }, "\n"))
    return context
end

local function assertReplayedRunIdScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    local block = summary:match("run: STEMwerk_dup_run.*")
    assertf(block ~= nil, "STEMwerk_dup_run run block missing:\n" .. summary)
    assertf(block:find("model: htdemucs\n", 1, true) == nil,
        "replayed run ID silently picked the first conflicting model instead of surfacing ambiguity:\n" .. block)
    assertf(block:find("model: htdemucs_ft", 1, true) == nil,
        "replayed run ID silently picked a conflicting model instead of surfacing ambiguity:\n" .. block)
    assertf(block:find("model: ambiguous", 1, true) ~= nil,
        "replayed run ID with conflicting model evidence was not surfaced as ambiguous:\n" .. block)
end

-- Section 8 (2.3.1.0 follow-up): a genuinely current NVIDIA run must not be
-- reclassified by stale/global ROCm state inherited from an unrelated prior
-- install (the present-runtime fixture's runtime is provisioned as ROCm).
local function createCurrentNvidiaVsStaleAmdScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "current-nvidia-vs-stale-amd-global-state"
    clearRuns(context)
    -- Leave bootstrap.env/capabilities.env exactly as the present-runtime
    -- fixture wrote them: BACKEND=rocm, a stale global ROCm profile. This
    -- run's own evidence is unambiguously NVIDIA and must win.
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_current_nvidia", "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "stdout.txt"), table.concat({
        "model: htdemucs",
        "device: cuda:0",
        "device_name: NVIDIA RTX 3060",
        "result: success",
        "done",
        "",
    }, "\n"))
    writeFile(joinPath(jobDir, "done.txt"), "done\n")
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    return context
end

local function assertCurrentNvidiaVsStaleAmdScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    assertf(summary:find("friendly_device: NVIDIA CUDA", 1, true) ~= nil,
        "current NVIDIA run was reclassified by stale global ROCm state:\n" .. summary)
    assertf(summary:find("friendly_device: AMD ROCm", 1, true) == nil,
        "current NVIDIA run was misclassified as AMD ROCm from stale global state")
end

-- A bare "cuda:0" device string with no vendor/HIP/runtime evidence at all
-- must not be guessed as NVIDIA CUDA.
local function createAmbiguousCudaDeviceScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "ambiguous-cuda-device-no-vendor-evidence"
    clearRuns(context)
    local runtimeBase = context.extState.runtimeBase
    -- Neutralize the fixture's stale ROCm global state so it cannot
    -- accidentally supply vendor evidence either way.
    writeFile(joinPath(runtimeBase, "state", "bootstrap.env"), table.concat({
        "PYTHON_PATH=" .. context.fakePythonPath,
        "FFMPEG_PATH=" .. context.fakeFfmpegPath,
        "STATUS=ok",
        "BOOTSTRAP_STATUS=ok",
        "VENV_PYTHON=" .. context.fakePythonPath,
        "RUNTIME_VERIFY_DETAIL=ok",
        "",
    }, "\n"))
    writeFile(joinPath(runtimeBase, "state", "capabilities.env"), table.concat({
        "PROFILE=linux-cpu",
        "VERIFICATION=ok",
        "PYTHON_PATH=" .. context.fakePythonPath,
        "FFMPEG_PATH=" .. context.fakeFfmpegPath,
        "BOOTSTRAP_STATUS=ok",
        "",
    }, "\n"))
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_ambiguous_cuda", "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "stdout.txt"), table.concat({
        "model: htdemucs",
        "device: cuda:0",
        "result: success",
        "done",
        "",
    }, "\n"))
    writeFile(joinPath(jobDir, "done.txt"), "done\n")
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    return context
end

local function assertAmbiguousCudaDeviceScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    assertf(summary:find("friendly_device: NVIDIA CUDA", 1, true) == nil,
        "bare cuda:0 with no vendor evidence was guessed as NVIDIA CUDA:\n" .. summary)
    assertf(summary:find("friendly_device: AMD ROCm", 1, true) == nil,
        "bare cuda:0 with no vendor evidence was guessed as AMD ROCm:\n" .. summary)
end

-- A literal "unknown" placeholder in one evidence field must not suppress a
-- real value present in a different, later field in an `or` fallback chain
-- (runtime_selected defaults to the literal string "unknown", which is
-- truthy in Lua).
local function createUnknownTruthinessScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "unknown-truthiness-does-not-suppress-real-evidence"
    clearRuns(context)
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_unknown_truthiness", "single")
    mkdirP(jobDir)
    -- Only backend_runtime carries real ROCm evidence; runtime_selected is
    -- never mentioned, so it stays at its literal "unknown" default.
    writeFile(joinPath(jobDir, "stdout.txt"), table.concat({
        "model: htdemucs",
        "device: cuda:0",
        "backend_runtime: rocm",
        "device_name: AMD Radeon RX 9070",
        "result: success",
        "done",
        "",
    }, "\n"))
    writeFile(joinPath(jobDir, "done.txt"), "done\n")
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    return context
end

local function assertUnknownTruthinessScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    assertf(summary:find("friendly_device: AMD ROCm", 1, true) ~= nil,
        "literal 'unknown' in runtime_selected suppressed real backend_runtime=rocm evidence:\n" .. summary)
end

-- Section 4 (2.3.1.0 follow-up), fixture A: one successful job in a run
-- must not clear a genuine failure recorded by a different job in the same
-- run.
local function createMixedSuccessParallelScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "mixed-success-parallel-jobs"
    clearRuns(context)
    local runDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_mixed_result")
    local job1 = joinPath(runDir, "job1")
    mkdirP(job1)
    writeFile(joinPath(job1, "phase_events.jsonl"),
        '{"time":1,"model":"htdemucs","device":"cpu","result":"success","output_count":4,"output_validation_reason":"ok"}\n')
    writeFile(joinPath(job1, "done.txt"), "done\n")
    writeFile(joinPath(job1, "exit_code.txt"), "0\n")

    local job2 = joinPath(runDir, "job2")
    mkdirP(job2)
    writeFile(joinPath(job2, "exit_code.txt"), "1\n")
    return context
end

local function assertMixedSuccessParallelScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    assertf(summary:find("result: fail", 1, true) ~= nil,
        "job2's exit=1 failure was cleared by job1's success (run must FAIL):\n" .. summary)
    assertf(summary:find("result: success", 1, true) == nil,
        "run was reported success despite one required job failing:\n" .. summary)
end

-- Fixture B: one job's explicit validation=ok must not be reported as the
-- run's aggregate validation when another job never confirmed validation.
local function createPartialValidationScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "partial-validation-not-ok"
    clearRuns(context)
    local runDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_partial_validation")
    local job1 = joinPath(runDir, "job1")
    mkdirP(job1)
    writeFile(joinPath(job1, "phase_events.jsonl"),
        '{"time":1,"model":"htdemucs","device":"cpu","result":"success","output_count":4,"output_validation_reason":"ok"}\n')
    writeFile(joinPath(job1, "done.txt"), "done\n")
    writeFile(joinPath(job1, "exit_code.txt"), "0\n")

    -- job2 completes but never reports a validation reason of its own.
    local job2 = joinPath(runDir, "job2")
    mkdirP(job2)
    writeFile(joinPath(job2, "done.txt"), "done\n")
    writeFile(joinPath(job2, "exit_code.txt"), "0\n")
    return context
end

local function assertPartialValidationScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    assertf(summary:find("output_validation_reason: ok", 1, true) == nil,
        "job1's validation=ok leaked into the run aggregate even though job2 never confirmed validation:\n" .. summary)
end

-- Fixture C: unequal per-job output counts must be reported truthfully,
-- including the incompleteness, rather than silently presented as a clean
-- total.
local function createUnequalOutputCountsScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "unequal-output-counts"
    clearRuns(context)
    local runDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_unequal_outputs")
    local job1 = joinPath(runDir, "job1")
    mkdirP(job1)
    writeFile(joinPath(job1, "phase_events.jsonl"),
        '{"time":1,"model":"htdemucs","device":"cpu","result":"success","output_count":4,"output_validation_reason":"ok"}\n')
    writeFile(joinPath(job1, "done.txt"), "done\n")
    writeFile(joinPath(job1, "exit_code.txt"), "0\n")

    -- job2 finished but has no output evidence of its own at all.
    local job2 = joinPath(runDir, "job2")
    mkdirP(job2)
    writeFile(joinPath(job2, "done.txt"), "done\n")
    writeFile(joinPath(job2, "exit_code.txt"), "0\n")
    return context
end

local function assertUnequalOutputCountsScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    assertf(summary:find("found_stems: 4 (partial: 1/2 jobs reported)", 1, true) ~= nil,
        "unequal per-job output counts were not truthfully reported as incomplete:\n" .. summary)
end

-- Section 5 (2.3.1.0 follow-up), confirming fixture: 2 parallel jobs whose
-- model is unknown until a later job's own evidence resolves it must use
-- the resolved model for expected-output-count math (6 stems x 2 jobs =
-- 12/12), not a stale/default model's count.
local function createLateModelResolutionScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "late-model-resolution-6stem-parallel"
    clearRuns(context)
    local runDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_late_model")
    -- job1 has output evidence but no model field of its own.
    local job1 = joinPath(runDir, "job1")
    mkdirP(job1)
    writeFile(joinPath(job1, "phase_events.jsonl"),
        '{"time":1,"device":"cpu","result":"success","output_count":6,"output_validation_reason":"ok"}\n')
    writeFile(joinPath(job1, "done.txt"), "done\n")
    writeFile(joinPath(job1, "exit_code.txt"), "0\n")
    -- job2 is the only job that names the model.
    local job2 = joinPath(runDir, "job2")
    mkdirP(job2)
    writeFile(joinPath(job2, "phase_events.jsonl"),
        '{"time":2,"model":"htdemucs_6s","device":"cpu","result":"success","output_count":6,"output_validation_reason":"ok"}\n')
    writeFile(joinPath(job2, "done.txt"), "done\n")
    writeFile(joinPath(job2, "exit_code.txt"), "0\n")
    return context
end

local function assertLateModelResolutionScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    assertf(summary:find("outputs 12/12", 1, true) ~= nil,
        "late-resolved htdemucs_6s (6 stems x 2 jobs) did not aggregate to 12/12:\n" .. summary)
    assertf(summary:find("outputs 8/8", 1, true) == nil,
        "expected-output count used a stale/default model instead of the late-resolved one")
end

-- Section 7 (2.3.1.0 follow-up): two independent Kit Split runs, each with
-- its own stage1/stage2 model+device, must never cross-contaminate each
-- other's per-stage fields.
local function createCrossRunKitSplitScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "cross-run-kit-split-no-leakage"
    clearRuns(context)
    local runsRoot = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs")

    local jobA = joinPath(runsRoot, "STEMwerk_kitsplit_run_a", "single")
    mkdirP(jobA)
    writeFile(joinPath(jobA, "stdout.txt"), table.concat({
        "workflow_source: dks_extract",
        "model: htdemucs_6s",
        "dks_extract_stage1_runtime=mps",
        "dks_extract_stage1_device=mps",
        "dks_extract_stage2_runtime=mps",
        "dks_extract_stage2_device=mps",
        "model_id=DrumSep-model-A",
        "result: success",
        "done",
        "",
    }, "\n"))
    writeFile(joinPath(jobA, "done.txt"), "done\n")
    writeFile(joinPath(jobA, "exit_code.txt"), "0\n")

    local jobB = joinPath(runsRoot, "STEMwerk_kitsplit_run_b", "single")
    mkdirP(jobB)
    writeFile(joinPath(jobB, "stdout.txt"), table.concat({
        "workflow_source: dks_extract",
        "model: htdemucs_ft",
        "dks_extract_stage1_runtime=cpu",
        "dks_extract_stage1_device=cpu",
        "dks_extract_stage2_runtime=cpu",
        "dks_extract_stage2_device=cpu",
        "model_id=DrumSep-model-B",
        "result: success",
        "done",
        "",
    }, "\n"))
    writeFile(joinPath(jobB, "done.txt"), "done\n")
    writeFile(joinPath(jobB, "exit_code.txt"), "0\n")
    return context
end

local function assertCrossRunKitSplitScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    local blockA = summary:match("run: STEMwerk_kitsplit_run_a.-\n\n") or summary:match("run: STEMwerk_kitsplit_run_a.*")
    local blockB = summary:match("run: STEMwerk_kitsplit_run_b.-\n\n") or summary:match("run: STEMwerk_kitsplit_run_b.*")
    assertf(blockA ~= nil, "kit split run A block missing:\n" .. summary)
    assertf(blockB ~= nil, "kit split run B block missing:\n" .. summary)
    assertf(blockA:find("stage1_model: htdemucs_6s", 1, true) ~= nil, "run A stage1 model missing:\n" .. blockA)
    assertf(blockA:find("stage2_model: DrumSep%-model%-A") ~= nil, "run A stage2 model missing:\n" .. blockA)
    assertf(blockA:find("htdemucs_ft", 1, true) == nil, "run B's stage1 model leaked into run A:\n" .. blockA)
    assertf(blockA:find("DrumSep%-model%-B") == nil, "run B's stage2 model leaked into run A:\n" .. blockA)
    assertf(blockB:find("stage1_model: htdemucs_ft", 1, true) ~= nil, "run B stage1 model missing:\n" .. blockB)
    assertf(blockB:find("stage2_model: DrumSep%-model%-B") ~= nil, "run B stage2 model missing:\n" .. blockB)
    assertf(blockB:find("htdemucs_6s", 1, true) == nil, "run A's stage1 model leaked into run B:\n" .. blockB)
    assertf(blockB:find("DrumSep%-model%-A") == nil, "run A's stage2 model leaked into run B:\n" .. blockB)
end

-- Section 9/10 (2.3.1.0 follow-up): an old "Runtime verification passed."
-- sentence anywhere in the cumulative bootstrap.log, combined with a
-- genuinely CURRENT bootstrap failure, must not be read as proof of current
-- health, and the current ONNX failure alongside it must count as fatal.
local function createCurrentFailureDespiteHistoricalSuccessScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "current-failure-despite-historical-success"
    local runtimeBase = context.extState.runtimeBase
    writeFile(joinPath(runtimeBase, "logs", "bootstrap.log"), table.concat({
        "Runtime verification passed.",
        "--- later run ---",
        "ERROR: Could not find a version that satisfies the requirement onnxruntime-silicon",
        "ERROR: No matching distribution found for onnxruntime-silicon",
        "WARN: onnxruntime-silicon install failed; falling back to onnxruntime",
        "ERROR: No matching distribution found for onnxruntime",
        "",
    }, "\n"))
    writeFile(joinPath(runtimeBase, "state", "bootstrap.env"), table.concat({
        "PYTHON_PATH=" .. context.fakePythonPath,
        "FFMPEG_PATH=" .. context.fakeFfmpegPath,
        "STATUS=failed",
        "STATUS_REASON=runtime_verification_failed",
        "BACKEND=rocm",
        "BOOTSTRAP_STATUS=failed",
        "VENV_PYTHON=" .. context.fakePythonPath,
        "RUNTIME_VERIFY_DETAIL=failed",
        "",
    }, "\n"))
    removeTree(joinPath(runtimeBase, "evidence"))
    return context
end

local function assertCurrentFailureDespiteHistoricalSuccessScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertf(manifest:find("final_runtime_health:%s+not_proven") ~= nil,
        "a stale historical 'Runtime verification passed.' sentence masked a genuinely current failure:\n" .. manifest)
    assertf(manifest:find("current_fatal_error_count:%s+0") == nil,
        "current ONNX failure was not counted as fatal despite historical success text:\n" .. manifest)
end

-- Section 12 (2.3.1.0 follow-up): old residue temp folders (unrelated to
-- the current run) must not be able to trigger "Recent"/current-looking
-- diagnostics fields.
local function createTempResidueIsolationScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "temp-residue-isolation"
    local tempRoot = joinPath(baseRoot, "tmp-present")
    local currentJobDir = joinPath(tempRoot, "STEMwerk_fake_present")
    local oldReview = joinPath(tempRoot, "stemwerk-review")
    local oldBuild = joinPath(tempRoot, "stemwerk-build")
    mkdirP(oldReview)
    mkdirP(oldBuild)
    -- The genuinely current temp dir (STEMwerk_fake_present, written by
    -- createPresentScenario) has its own stdout.txt/separation_log.txt but
    -- deliberately NOT stderr.txt here, so "Recent stderr.txt" can only
    -- legitimately be triggered by this run's own evidence -- never by old
    -- residue -- proving the isolation this fixture targets.
    os.remove(joinPath(currentJobDir, "stderr.txt"))
    writeFile(joinPath(oldReview, "stdout.txt"), "old stdout\n")
    writeFile(joinPath(oldReview, "stderr.txt"), "old stderr\n")
    writeFile(joinPath(oldBuild, "separation_log.txt"), "old separation log\n")
    -- Backdate the old residue so it is unambiguously OLDER than the
    -- current run's own temp dir (both are written within the same test
    -- second otherwise, which would not exercise recency at all).
    if not IS_WINDOWS then
        os.execute("touch -d '2000-01-01T00:00:00' " .. shellQuote(oldReview) .. " " .. shellQuote(oldBuild)
            .. " " .. shellQuote(joinPath(oldReview, "stdout.txt")) .. " " .. shellQuote(joinPath(oldReview, "stderr.txt"))
            .. " " .. shellQuote(joinPath(oldBuild, "separation_log.txt")) .. " >/dev/null 2>&1")
    end
    return context
end

local function assertTempResidueIsolationScenario(bundleDir)
    local inventory = readFile(joinPath(bundleDir, "temp_inventory.txt")) or ""
    -- Old residue may still be inventoried/listed (historical context is
    -- fine) ...
    assertf(inventory:find("stemwerk-review", 1, true) ~= nil or inventory:find("stemwerk-build", 1, true) ~= nil,
        "old residue folders were not inventoried at all (unexpected):\n" .. inventory)
    -- ... but must never be able to make an unrelated old stderr.txt look
    -- like current/recent evidence: the current run's own temp dir has no
    -- stderr.txt of its own in this fixture, so "Recent stderr.txt" must
    -- read "missing", not "present".
    local diagnostics = readFile(joinPath(bundleDir, "diagnostics.txt")) or ""
    assertf(diagnostics:find("Recent stderr%.txt:%s+missing") ~= nil,
        "old residue's stderr.txt was treated as 'Recent' current-run evidence:\n" .. diagnostics)
end

-- Section 7 (2.3.1.0 follow-up): additional evidence markers the task spec
-- explicitly calls out (model_name=, drumsep_helper_model=) must actually be
-- parsed and attributed, not silently ignored.
local function createAdditionalModelMarkersScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "additional-model-markers-parsed"
    clearRuns(context)
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_extra_markers", "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "stdout.txt"), table.concat({
        "workflow_source: dks_direct",
        "workflow_mode: drumkit",
        "model_name: htdemucs_ft",
        "drumsep_helper_model=DrumSep-helper-model-X",
        "result: success",
        "done",
        "",
    }, "\n"))
    writeFile(joinPath(jobDir, "done.txt"), "done\n")
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    return context
end

local function assertAdditionalModelMarkersScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    -- Direct Kit: semantic model must be the DrumSep helper model marker,
    -- not the generic model_name= marker (same flow-aware rule as
    -- semanticModelLabel already enforces for model_id=/requested_model=).
    assertf(summary:find("semantic_model: DrumSep%-helper%-model%-X") ~= nil,
        "drumsep_helper_model= marker was not parsed/attributed:\n" .. summary)
end

-- ---------------------------------------------------------------------
-- Third follow-up (release/2.3.1.0-final-prep) fixtures: strict run-ID
-- association, per-job diagnostic isolation, run-level aggregation of
-- heterogeneous per-job evidence, Direct Kit generic-model leakage,
-- effective (not merely requested) backend/device, and current-health
-- identity/freshness. Each clones the known-good "present" scenario and
-- mutates only what the fixture needs.
-- ---------------------------------------------------------------------

-- Section 1: a new tokenless launch block must never inherit the previous
-- run's identity just because that run's token was the last one seen.
local function createTokenlessLaunchAfterValidRunScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "tokenless-launch-after-valid-run"
    clearRuns(context)
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_run_a", "single")
    mkdirP(jobDir)
    -- No model/device evidence of its own, so any model shown for this run
    -- can only have come from run_stemwerk.log association.
    writeFile(joinPath(jobDir, "done.txt"), "done\n")
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")

    local runtimeLogsDir = joinPath(context.extState.runtimeBase, "logs")
    writeFile(joinPath(runtimeLogsDir, "run_stemwerk.log"), table.concat({
        "[2026-07-01 10:00:00] CMD: LAUNCH: STEMwerk_run_a",
        "RC: 0",
        -- A brand-new launch begins here with NO run-ID token of its own.
        -- This starts a new logical launch boundary; its evidence must
        -- never be attributed to the PRIOR run just because that run's
        -- token was the last one seen.
        "[2026-07-01 10:05:00] CMD: LAUNCH: --model htdemucs_ft --device cuda:0",
        "RC: 0",
        "",
    }, "\n"))
    return context
end

local function assertTokenlessLaunchAfterValidRunScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    local block = summary:match("run: STEMwerk_run_a.*")
    assertf(block ~= nil, "STEMwerk_run_a run block missing:\n" .. summary)
    assertf(block:find("model: htdemucs_ft", 1, true) == nil,
        "a tokenless launch block starting AFTER STEMwerk_run_a's block leaked its model onto STEMwerk_run_a:\n" .. block)
    assertf(block:find("device: cuda:0", 1, true) == nil,
        "a tokenless launch block starting AFTER STEMwerk_run_a's block leaked its device onto STEMwerk_run_a:\n" .. block)
end

-- Section 2/3: within ONE run, jobs with genuinely different model/backend/
-- device evidence must never be blended into a fabricated combination; the
-- run summary must report "mixed" (never first-wins/last-wins).
local function createHeterogeneousJobsSameRunScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "heterogeneous-jobs-same-run-no-fabricated-combo"
    clearRuns(context)
    local runDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_hetero_run")
    local jobA = joinPath(runDir, "jobA")
    mkdirP(jobA)
    writeFile(joinPath(jobA, "stdout.txt"), table.concat({
        "model: X-model",
        "backend_runtime: rocm",
        "device: cuda:0",
        "result: success",
        "done",
        "",
    }, "\n"))
    writeFile(joinPath(jobA, "done.txt"), "done\n")
    writeFile(joinPath(jobA, "exit_code.txt"), "0\n")

    local jobB = joinPath(runDir, "jobB")
    mkdirP(jobB)
    writeFile(joinPath(jobB, "stdout.txt"), table.concat({
        "model: Y-model",
        "backend_runtime: cpu",
        "device: cpu",
        "result: success",
        "done",
        "",
    }, "\n"))
    writeFile(joinPath(jobB, "done.txt"), "done\n")
    writeFile(joinPath(jobB, "exit_code.txt"), "0\n")
    return context
end

local function assertHeterogeneousJobsSameRunScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    local block = summary:match("run: STEMwerk_hetero_run.*")
    assertf(block ~= nil, "STEMwerk_hetero_run block missing:\n" .. summary)
    assertf(block:find("model: mixed", 1, true) ~= nil, "heterogeneous per-job models were not reported as mixed:\n" .. block)
    assertf(block:find("backend_runtime: mixed", 1, true) ~= nil, "heterogeneous per-job backend_runtime was not reported as mixed:\n" .. block)
    assertf(block:find("device: mixed", 1, true) ~= nil, "heterogeneous per-job device was not reported as mixed:\n" .. block)
    assertf(block:find("model: X-model", 1, true) == nil, "run block shows one job's model instead of the truthful aggregate:\n" .. block)
    assertf(block:find("model: Y-model", 1, true) == nil, "run block shows one job's model instead of the truthful aggregate:\n" .. block)
end

-- Section 2/3 confirming fixture: same-run heterogeneous DrumSep fields
-- (Direct Kit) must also aggregate truthfully rather than picking one job's
-- value.
local function createHeterogeneousDrumsepSameRunScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "heterogeneous-drumsep-fields-same-run"
    clearRuns(context)
    local runDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_hetero_drumsep")
    local jobA = joinPath(runDir, "jobA")
    mkdirP(jobA)
    writeFile(joinPath(jobA, "stdout.txt"), table.concat({
        "workflow_source: dks_direct",
        "workflow_mode: drumkit",
        "model_id=DrumSep-model-A",
        "result: success",
        "done",
        "",
    }, "\n"))
    writeFile(joinPath(jobA, "done.txt"), "done\n")
    writeFile(joinPath(jobA, "exit_code.txt"), "0\n")

    local jobB = joinPath(runDir, "jobB")
    mkdirP(jobB)
    writeFile(joinPath(jobB, "stdout.txt"), table.concat({
        "workflow_source: dks_direct",
        "workflow_mode: drumkit",
        "model_id=DrumSep-model-B",
        "result: success",
        "done",
        "",
    }, "\n"))
    writeFile(joinPath(jobB, "done.txt"), "done\n")
    writeFile(joinPath(jobB, "exit_code.txt"), "0\n")
    return context
end

local function assertHeterogeneousDrumsepSameRunScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    local block = summary:match("run: STEMwerk_hetero_drumsep.*")
    assertf(block ~= nil, "STEMwerk_hetero_drumsep block missing:\n" .. summary)
    assertf(block:find("model: mixed", 1, true) ~= nil, "heterogeneous per-job DrumSep model_id was not reported as mixed:\n" .. block)
    assertf(block:find("semantic_model: mixed", 1, true) ~= nil, "heterogeneous DrumSep semantic model was not reported as mixed:\n" .. block)
    assertf(block:find("DrumSep-model-A", 1, true) == nil, "run block shows one job's DrumSep model instead of the truthful aggregate:\n" .. block)
    assertf(block:find("DrumSep-model-B", 1, true) == nil, "run block shows one job's DrumSep model instead of the truthful aggregate:\n" .. block)
end

-- Section 5: same-run heterogeneous Kit Split stages (two jobs in the SAME
-- run, not two different runs) must never cross-contaminate.
local function createHeterogeneousKitSplitSameRunScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "heterogeneous-kit-split-stages-same-run"
    clearRuns(context)
    local runDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_hetero_kitsplit")
    local jobA = joinPath(runDir, "jobA")
    mkdirP(jobA)
    writeFile(joinPath(jobA, "stdout.txt"), table.concat({
        "workflow_source: dks_extract",
        "model: htdemucs_6s",
        "dks_extract_stage1_runtime=mps",
        "dks_extract_stage1_device=mps",
        "dks_extract_stage2_runtime=mps",
        "dks_extract_stage2_device=mps",
        "model_id=DrumSep-model-A",
        "result: success",
        "done",
        "",
    }, "\n"))
    writeFile(joinPath(jobA, "done.txt"), "done\n")
    writeFile(joinPath(jobA, "exit_code.txt"), "0\n")

    local jobB = joinPath(runDir, "jobB")
    mkdirP(jobB)
    writeFile(joinPath(jobB, "stdout.txt"), table.concat({
        "workflow_source: dks_extract",
        "model: htdemucs_ft",
        "dks_extract_stage1_runtime=cpu",
        "dks_extract_stage1_device=cpu",
        "dks_extract_stage2_runtime=cpu",
        "dks_extract_stage2_device=cpu",
        "model_id=DrumSep-model-B",
        "result: success",
        "done",
        "",
    }, "\n"))
    writeFile(joinPath(jobB, "done.txt"), "done\n")
    writeFile(joinPath(jobB, "exit_code.txt"), "0\n")
    return context
end

local function assertHeterogeneousKitSplitSameRunScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    local block = summary:match("run: STEMwerk_hetero_kitsplit.*")
    assertf(block ~= nil, "STEMwerk_hetero_kitsplit block missing:\n" .. summary)
    assertf(block:find("stage1_model: mixed", 1, true) ~= nil, "heterogeneous same-run stage1 model was not reported as mixed:\n" .. block)
    assertf(block:find("stage1_runtime: mixed", 1, true) ~= nil, "heterogeneous same-run stage1 runtime was not reported as mixed:\n" .. block)
    assertf(block:find("stage1_device: mixed", 1, true) ~= nil, "heterogeneous same-run stage1 device was not reported as mixed:\n" .. block)
    assertf(block:find("stage2_model: mixed", 1, true) ~= nil, "heterogeneous same-run stage2 (DrumSep) model was not reported as mixed:\n" .. block)
    assertf(block:find("stage2_runtime: mixed", 1, true) ~= nil, "heterogeneous same-run stage2 runtime was not reported as mixed:\n" .. block)
    assertf(block:find("stage2_device: mixed", 1, true) ~= nil, "heterogeneous same-run stage2 device was not reported as mixed:\n" .. block)
    assertf(block:find("htdemucs_6s", 1, true) == nil, "run block leaked one job's stage1 model instead of the truthful aggregate:\n" .. block)
    assertf(block:find("htdemucs_ft", 1, true) == nil, "run block leaked one job's stage1 model instead of the truthful aggregate:\n" .. block)
end

-- Section 4: a real (non-obfuscated) decoy Demucs "model:" line alongside a
-- DrumSep model_id must never surface as the Direct Kit generic model.
local function createDirectKitGenericModelLeakageScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "direct-kit-generic-model-leakage"
    clearRuns(context)
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_direct_kit_leak", "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "stdout.txt"), table.concat({
        "workflow_source: dks_direct",
        "workflow_mode: drumkit",
        -- A real Demucs model marker (not an obfuscated decoy): this is
        -- exactly the generic "model:" text the shared per-run parsing
        -- would otherwise surface verbatim as the visible model field.
        "model: htdemucs",
        "model_id=MDX23C-DrumSep-aufr33-jarredou.ckpt",
        "result: success",
        "done",
        "",
    }, "\n"))
    writeFile(joinPath(jobDir, "done.txt"), "done\n")
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    return context
end

local function assertDirectKitGenericModelLeakageScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    local block = summary:match("run: STEMwerk_direct_kit_leak.*")
    assertf(block ~= nil, "STEMwerk_direct_kit_leak block missing:\n" .. summary)
    assertf(block:find("model: MDX23C-DrumSep-aufr33-jarredou.ckpt", 1, true) ~= nil,
        "Direct Kit generic 'model:' field did not show the DrumSep semantic model:\n" .. block)
    assertf(block:find("model: htdemucs\n", 1, true) == nil,
        "Direct Kit generic 'model:' field leaked the unrelated Demucs model:\n" .. block)
    assertf(block:find("raw_demucs_model_field", 1, true) ~= nil,
        "the raw Demucs field was dropped instead of kept as labeled historical provenance:\n" .. block)
end

-- Section 6: the active backend/device shown must be the EFFECTIVE worker
-- execution (runtime_selected=cpu fallback), never the merely requested/
-- earlier-probed capability (mps).
local function createMpsRequestedCpuEffectiveScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "mps-requested-cpu-effective-fallback"
    clearRuns(context)
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_mps_cpu_fallback", "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "stdout.txt"), table.concat({
        "model: htdemucs",
        "requested_device=mps",
        "device: mps",
        "runtime_selected: cpu",
        "result: success",
        "done",
        "",
    }, "\n"))
    writeFile(joinPath(jobDir, "done.txt"), "done\n")
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    return context
end

local function assertMpsRequestedCpuEffectiveScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    local block = summary:match("run: STEMwerk_mps_cpu_fallback.*")
    assertf(block ~= nil, "STEMwerk_mps_cpu_fallback block missing:\n" .. summary)
    assertf(block:find("friendly_device: CPU", 1, true) ~= nil,
        "requested=mps + earlier probe device=mps + runtime_selected=cpu must show CPU as the ACTIVE device:\n" .. block)
    assertf(block:find("friendly_device: Apple MPS", 1, true) == nil,
        "an MPS request that actually fell back to CPU execution was shown as the active device:\n" .. block)
    assertf(block:find("requested_device: mps", 1, true) ~= nil,
        "the requested (not active) MPS capability must still be visible as requested_device:\n" .. block)
end

-- Section 7/9: a stale/generic "healthy" bootstrap claim (no freshness
-- identity of its own) must not mask a genuinely current failed acceptance
-- phase -- current failure always outranks older healthy state.
local function createStaleBootstrapCurrentFailedPhaseScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "stale-healthy-bootstrap-current-failed-phase"
    -- bootstrap.env/capabilities.env stay untouched (STATUS=ok,
    -- RUNTIME_VERIFY_DETAIL=ok). One current-session acceptance phase
    -- (identity/timestamp already verified fresh) now fails.
    local evidenceRoot = joinPath(context.extState.runtimeBase, "evidence", "current-session")
    local sessionId = "native-apple-silicon-2306-final"
    local phaseDir = joinPath(evidenceRoot, "online_normal")
    writeFile(joinPath(phaseDir, "evidence.env"), table.concat({
        "EVIDENCE_SCHEMA=1",
        "SESSION_ID=" .. sessionId,
        "PHASE=online_normal",
        "DISTRIBUTION=online",
        "STATUS=fail",
        "TIMESTAMP_UTC=2026-07-24T13:10:00Z",
        "BACKEND=metal",
        "DEVICE=mps",
        "RUNTIME_ARCH=arm64",
        "OUTPUT_VALIDATION_REASON=failed",
        "CURRENT_FATAL_ERROR_COUNT=1",
        "",
    }, "\n"))
    return context
end

local function assertStaleBootstrapCurrentFailedPhaseScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertf(manifest:find("final_runtime_health:%s+not_proven") ~= nil,
        "a stale/generic 'healthy' bootstrap claim masked a genuinely current failed acceptance phase:\n" .. manifest)
    assertf(manifest:find("current_fatal_errors:%s+none") == nil,
        "current failed acceptance phase was not counted as a current fatal error:\n" .. manifest)
end

-- Section 8: a phase whose SESSION_ID matches but whose own generation
-- timestamp predates the current session start is stale (e.g. left behind
-- by session-ID reuse) and must not be able to prove current health.
local function createStaleTimestampedPhaseScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "stale-timestamped-phase-cannot-prove-health"
    local runtimeBase = context.extState.runtimeBase
    -- Bootstrap itself is not proven healthy, so the ONLY thing that could
    -- prove current health is the acceptance-phase evidence below.
    writeFile(joinPath(runtimeBase, "state", "bootstrap.env"), table.concat({
        "PYTHON_PATH=" .. context.fakePythonPath,
        "FFMPEG_PATH=" .. context.fakeFfmpegPath,
        "STATUS=failed",
        "STATUS_REASON=runtime_verification_failed",
        "BACKEND=rocm",
        "BOOTSTRAP_STATUS=failed",
        "VENV_PYTHON=" .. context.fakePythonPath,
        "RUNTIME_VERIFY_DETAIL=failed",
        "",
    }, "\n"))
    local evidenceRoot = joinPath(runtimeBase, "evidence", "current-session")
    local sessionId = "native-apple-silicon-2306-final"
    local phaseDir = joinPath(evidenceRoot, "online_normal")
    -- Correct session ID (identity alone would appear to match), but a
    -- TIMESTAMP_UTC well before the session started.
    writeFile(joinPath(phaseDir, "evidence.env"), table.concat({
        "EVIDENCE_SCHEMA=1",
        "SESSION_ID=" .. sessionId,
        "PHASE=online_normal",
        "DISTRIBUTION=online",
        "STATUS=ok",
        "TIMESTAMP_UTC=2020-01-01T00:00:00Z",
        "BACKEND=metal",
        "DEVICE=mps",
        "RUNTIME_ARCH=arm64",
        "OUTPUT_VALIDATION_REASON=ok",
        "CURRENT_FATAL_ERROR_COUNT=0",
        "",
    }, "\n"))
    -- Remove the other 5 fixed phases so this fixture isolates exactly the
    -- one stale-timestamped phase.
    for _, phase in ipairs({ "verify", "online_drum", "bundled_recovery", "post_bundled_normal", "post_bundled_drum" }) do
        removeTree(joinPath(evidenceRoot, phase))
    end
    return context
end

local function assertStaleTimestampedPhaseScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertf(manifest:find("final_runtime_health:%s+not_proven") ~= nil,
        "a stale-timestamped phase (older than the current session start) was accepted as current proof of health:\n" .. manifest)
    assertf(manifest:find("phases_included:%s+0") ~= nil,
        "the stale-timestamped phase was counted as 'included' current evidence:\n" .. manifest)
end

-- Section 10: a newer folder that merely shares the "stemwerk" name prefix
-- (not STEMwerk's own generated run/job naming identity) must never be able
-- to pass itself off as current run evidence merely by being newest.
local function createNewerUnrelatedTempResidueScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "newer-unrelated-temp-residue-lacks-identity"
    local tempRoot = joinPath(baseRoot, "tmp-present")
    local currentJobDir = joinPath(tempRoot, "STEMwerk_fake_present")
    -- The genuinely-current run's own folder has no stderr.txt of its own
    -- here, so "Recent stderr.txt" can only legitimately come from THIS
    -- run's own evidence -- never from the newer unrelated folder below.
    os.remove(joinPath(currentJobDir, "stderr.txt"))
    waitNextSecond()
    -- Created AFTER (mtime-newer than) the current run's own folder;
    -- matches the loose "stemwerk"-prefix but NOT STEMwerk's own generated
    -- run/job naming convention (STEMwerk_<token>).
    local newerUnrelated = joinPath(tempRoot, "stemwerk-review")
    mkdirP(newerUnrelated)
    writeFile(joinPath(newerUnrelated, "stderr.txt"), "unrelated newer stderr\n")
    return context
end

local function assertNewerUnrelatedTempResidueScenario(bundleDir)
    local inventory = readFile(joinPath(bundleDir, "temp_inventory.txt")) or ""
    assertf(inventory:find("stemwerk-review", 1, true) ~= nil,
        "the newer unrelated folder was not inventoried at all (unexpected):\n" .. inventory)
    local diagnostics = readFile(joinPath(bundleDir, "diagnostics.txt")) or ""
    assertf(diagnostics:find("Recent stderr%.txt:%s+missing") ~= nil,
        "a newer unrelated folder with no STEMwerk run/job identity became 'current' evidence merely by being the newest stemwerk-prefixed folder:\n" .. diagnostics)
end

-- Section 11 (2.3.1.0 final-prep follow-up): the literal
-- drumsep_helper_device_arg field (the argument passed TO the drumsep
-- helper subprocess) is a request, not evidence of what actually executed.
-- It must never surface as the ACTIVE device once backend_runtime/
-- runtime_selected explicitly recorded CPU execution.
local function createDrumsepHelperArgCpuEffectiveScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "drumsep-helper-arg-mps-cpu-effective"
    clearRuns(context)
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", "STEMwerk_drumsep_arg_cpu", "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "stdout.txt"), table.concat({
        "model: htdemucs",
        "requested_device=mps",
        "drumsep_helper_device_arg=mps",
        "backend_runtime=cpu",
        "runtime_selected=cpu",
        "result: success",
        "done",
        "",
    }, "\n"))
    writeFile(joinPath(jobDir, "done.txt"), "done\n")
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    return context
end

local function assertDrumsepHelperArgCpuEffectiveScenario(bundleDir)
    local summary = readProcessingSummary(bundleDir)
    local block = summary:match("run: STEMwerk_drumsep_arg_cpu.*")
    assertf(block ~= nil, "STEMwerk_drumsep_arg_cpu block missing:\n" .. summary)
    assertf(block:find("friendly_device: CPU", 1, true) ~= nil,
        "drumsep_helper_device_arg=mps + backend_runtime=cpu + runtime_selected=cpu must show CPU as the ACTIVE device:\n" .. block)
    assertf(block:find("friendly_device: Apple MPS", 1, true) == nil,
        "a helper-argument-only MPS request was shown as the active device despite CPU backend_runtime/runtime_selected:\n" .. block)
    assertf(block:find("requested_device: mps", 1, true) ~= nil,
        "requested (provenance-only) MPS must still be visible as requested_device:\n" .. block)
end

-- Section 12: matching session ID, but the acceptance-phase evidence file's
-- own TIMESTAMP_UTC is entirely missing. A missing timestamp is not
-- "fresh by default" -- it is unverifiable and must not be able to prove
-- current health, just like a provably-stale one.
local function createPhaseMissingTimestampScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "phase-missing-timestamp-cannot-prove-health"
    local runtimeBase = context.extState.runtimeBase
    -- Bootstrap itself is not proven healthy, so the ONLY thing that could
    -- prove current health is the acceptance-phase evidence below.
    writeFile(joinPath(runtimeBase, "state", "bootstrap.env"), table.concat({
        "PYTHON_PATH=" .. context.fakePythonPath,
        "FFMPEG_PATH=" .. context.fakeFfmpegPath,
        "STATUS=failed",
        "STATUS_REASON=runtime_verification_failed",
        "BACKEND=rocm",
        "BOOTSTRAP_STATUS=failed",
        "VENV_PYTHON=" .. context.fakePythonPath,
        "RUNTIME_VERIFY_DETAIL=failed",
        "",
    }, "\n"))
    local evidenceRoot = joinPath(runtimeBase, "evidence", "current-session")
    local sessionId = "native-apple-silicon-2306-final"
    local phaseDir = joinPath(evidenceRoot, "online_normal")
    -- Correct session ID and status=ok, but no TIMESTAMP_UTC line at all.
    writeFile(joinPath(phaseDir, "evidence.env"), table.concat({
        "EVIDENCE_SCHEMA=1",
        "SESSION_ID=" .. sessionId,
        "PHASE=online_normal",
        "DISTRIBUTION=online",
        "STATUS=ok",
        "BACKEND=metal",
        "DEVICE=mps",
        "RUNTIME_ARCH=arm64",
        "OUTPUT_VALIDATION_REASON=ok",
        "CURRENT_FATAL_ERROR_COUNT=0",
        "",
    }, "\n"))
    for _, phase in ipairs({ "verify", "online_drum", "bundled_recovery", "post_bundled_normal", "post_bundled_drum" }) do
        removeTree(joinPath(evidenceRoot, phase))
    end
    return context
end

local function assertPhaseMissingTimestampScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertf(manifest:find("final_runtime_health:%s+not_proven") ~= nil,
        "a phase with no TIMESTAMP_UTC at all was accepted as current proof of health:\n" .. manifest)
    assertf(manifest:find("phases_included:%s+0") ~= nil,
        "the missing-timestamp phase was counted as 'included' current evidence:\n" .. manifest)
    assertf(manifest:find("warning:%s+missing_timestamp") ~= nil,
        "the missing-timestamp phase was not distinctly labeled missing_timestamp:\n" .. manifest)
end

-- Section 13: matching session ID, but TIMESTAMP_UTC is not a parseable
-- timestamp at all. A naive string compare against the session start could
-- accidentally evaluate as "fresh" depending on the malformed text's
-- leading characters -- it must be rejected outright, not compared.
local function createPhaseMalformedTimestampScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "phase-malformed-timestamp-cannot-prove-health"
    local runtimeBase = context.extState.runtimeBase
    writeFile(joinPath(runtimeBase, "state", "bootstrap.env"), table.concat({
        "PYTHON_PATH=" .. context.fakePythonPath,
        "FFMPEG_PATH=" .. context.fakeFfmpegPath,
        "STATUS=failed",
        "STATUS_REASON=runtime_verification_failed",
        "BACKEND=rocm",
        "BOOTSTRAP_STATUS=failed",
        "VENV_PYTHON=" .. context.fakePythonPath,
        "RUNTIME_VERIFY_DETAIL=failed",
        "",
    }, "\n"))
    local evidenceRoot = joinPath(runtimeBase, "evidence", "current-session")
    local sessionId = "native-apple-silicon-2306-final"
    local phaseDir = joinPath(evidenceRoot, "online_normal")
    writeFile(joinPath(phaseDir, "evidence.env"), table.concat({
        "EVIDENCE_SCHEMA=1",
        "SESSION_ID=" .. sessionId,
        "PHASE=online_normal",
        "DISTRIBUTION=online",
        "STATUS=ok",
        -- Lexicographically greater than a well-formed "2026-..." timestamp
        -- (leading "z" sorts after digits), which would incorrectly read
        -- as "fresh" under a naive string compare with no format check.
        "TIMESTAMP_UTC=zz-not-a-real-timestamp",
        "BACKEND=metal",
        "DEVICE=mps",
        "RUNTIME_ARCH=arm64",
        "OUTPUT_VALIDATION_REASON=ok",
        "CURRENT_FATAL_ERROR_COUNT=0",
        "",
    }, "\n"))
    for _, phase in ipairs({ "verify", "online_drum", "bundled_recovery", "post_bundled_normal", "post_bundled_drum" }) do
        removeTree(joinPath(evidenceRoot, phase))
    end
    return context
end

local function assertPhaseMalformedTimestampScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertf(manifest:find("final_runtime_health:%s+not_proven") ~= nil,
        "a phase with a malformed TIMESTAMP_UTC was accepted as current proof of health:\n" .. manifest)
    assertf(manifest:find("phases_included:%s+0") ~= nil,
        "the malformed-timestamp phase was counted as 'included' current evidence:\n" .. manifest)
    assertf(manifest:find("warning:%s+malformed_timestamp") ~= nil,
        "the malformed-timestamp phase was not distinctly labeled malformed_timestamp:\n" .. manifest)
end

-- Section 14: a newer folder that matches STEMwerk's own exact
-- "STEMwerk_<token>" run/job naming convention -- not merely a loose
-- "stemwerk"-prefixed name -- must still not be able to pass itself off as
-- current run evidence unless its own content actually references it. A
-- human-made "STEMwerk_review"/"STEMwerk_build" folder can use the exact
-- same naming shape as a real run folder while carrying no real run
-- evidence at all.
local function createTempNameMatchesButNoRunIdentityScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "temp-name-pattern-without-run-identity"
    local tempRoot = joinPath(baseRoot, "tmp-present")
    local currentJobDir = joinPath(tempRoot, "STEMwerk_fake_present")
    -- The genuinely-current run's own folder has no stderr.txt of its own
    -- here, so "Recent stderr.txt" can only legitimately come from THIS
    -- run's own evidence -- never from either decoy below.
    os.remove(joinPath(currentJobDir, "stderr.txt"))
    waitNextSecond()
    -- Exactly matches STEMwerk's own naming convention (unlike the
    -- existing lowercase/hyphenated "stemwerk-review" fixture), but its
    -- content never references this folder -- a human review folder that
    -- happens to reuse STEMwerk's own naming shape.
    local reviewDecoy = joinPath(tempRoot, "STEMwerk_review")
    mkdirP(reviewDecoy)
    writeFile(joinPath(reviewDecoy, "stderr.txt"), "notes from manual review, unrelated to any run\n")
    waitNextSecond()
    -- Also matches the naming convention and even carries a run-id-shaped
    -- token of its own, but not one tied to the genuinely current run --
    -- an unrelated run's leftover residue must not become "current" either.
    -- (Deliberately does not mention its own folder name anywhere in its
    -- content, unlike a real run's own logged output paths.)
    local buildDecoy = joinPath(tempRoot, "STEMwerk_build")
    mkdirP(buildDecoy)
    writeFile(joinPath(buildDecoy, "stdout.txt"), "build log for an unrelated job token XYZ99, nothing to do with any current run\n")
    -- Both decoys carry a stderr.txt of their own (unrelated content, no
    -- self-reference) so this check catches the regression regardless of
    -- which decoy sorts as "newest" -- the real folder above has none.
    writeFile(joinPath(buildDecoy, "stderr.txt"), "build stderr for an unrelated job\n")
    return context
end

local function assertTempNameMatchesButNoRunIdentityScenario(bundleDir)
    local inventory = readFile(joinPath(bundleDir, "temp_inventory.txt")) or ""
    assertf(inventory:find("STEMwerk_review", 1, true) ~= nil and inventory:find("STEMwerk_build", 1, true) ~= nil,
        "the decoy folders were not inventoried at all (unexpected):\n" .. inventory)
    local diagnostics = readFile(joinPath(bundleDir, "diagnostics.txt")) or ""
    assertf(diagnostics:find("Recent stderr%.txt:%s+missing") ~= nil,
        "a newer folder that only shares STEMwerk's exact naming pattern (with no real run identity in its content) became 'current' evidence merely by being newest:\n" .. diagnostics)
end

-- Section 15 (2.3.1.0 final-prep follow-up): bootstrap.log is append-only,
-- so a bare "Runtime verification passed." sentence can be left behind by
-- any past run. With no structured cached-healthy bootstrap state and no
-- current session evidence at all, that historical sentence alone must
-- never prove current health.
local function createHistoricalSuccessOnlyScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "historical-success-log-only-not-proven"
    local runtimeBase = context.extState.runtimeBase
    writeFile(joinPath(runtimeBase, "state", "bootstrap.env"), table.concat({
        "PYTHON_PATH=" .. context.fakePythonPath,
        "FFMPEG_PATH=" .. context.fakeFfmpegPath,
        "STATUS=failed",
        "STATUS_REASON=runtime_verification_failed",
        "BOOTSTRAP_STATUS=failed",
        "VENV_PYTHON=" .. context.fakePythonPath,
        "RUNTIME_VERIFY_DETAIL=failed",
        "",
    }, "\n"))
    writeFile(joinPath(runtimeBase, "logs", "bootstrap.log"), table.concat({
        "bootstrap ok (old run)",
        "Runtime verification passed.",
        "",
    }, "\n"))
    removeTree(joinPath(runtimeBase, "evidence"))
    return context
end

local function assertHistoricalSuccessOnlyScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertf(manifest:find("bootstrap_readiness:%s+cached_unhealthy_or_unrecorded") ~= nil,
        "a non-ok bootstrap.env was not exposed as cached_unhealthy_or_unrecorded provenance:\n" .. manifest)
    assertf(manifest:find("historical_runtime_verification_sentence_seen:%s+yes_not_used_as_current_proof") ~= nil,
        "the historical 'Runtime verification passed.' sentence was not recorded as historical-only:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+not_proven") ~= nil,
        "a historical-only 'Runtime verification passed.' log sentence, with no structured or current-session evidence, proved current health:\n" .. manifest)
end

-- Section 16 (2.3.1.0 final-prep follow-up): fatal-severity classification
-- must follow the same currentness authority as ordinary failure -- a
-- cached-healthy bootstrap claim must never suppress a genuinely current
-- FATAL acceptance phase.
local function createCachedBootstrapCurrentFatalScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "cached-bootstrap-current-fatal"
    -- bootstrap.env/capabilities.env stay untouched (STATUS=ok,
    -- RUNTIME_VERIFY_DETAIL=ok: cached-healthy provenance). One
    -- current-session acceptance phase (identity/timestamp already fresh)
    -- now reports STATUS=fatal explicitly.
    local evidenceRoot = joinPath(context.extState.runtimeBase, "evidence", "current-session")
    local sessionId = "native-apple-silicon-2306-final"
    local phaseDir = joinPath(evidenceRoot, "online_normal")
    writeFile(joinPath(phaseDir, "evidence.env"), table.concat({
        "EVIDENCE_SCHEMA=1",
        "SESSION_ID=" .. sessionId,
        "PHASE=online_normal",
        "DISTRIBUTION=online",
        "STATUS=fatal",
        "TIMESTAMP_UTC=2026-07-24T13:10:00Z",
        "BACKEND=metal",
        "DEVICE=mps",
        "RUNTIME_ARCH=arm64",
        "OUTPUT_VALIDATION_REASON=failed",
        "CURRENT_FATAL_ERROR_COUNT=1",
        "",
    }, "\n"))
    return context
end

local function assertCachedBootstrapCurrentFatalScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertf(manifest:find("bootstrap_readiness:%s+cached_healthy") ~= nil,
        "cached bootstrap-healthy provenance was not exposed:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+not_proven") ~= nil,
        "a cached bootstrap-healthy claim suppressed a genuinely current FATAL acceptance phase:\n" .. manifest)
    assertf(manifest:find("current_fatal_error_count:%s+[1-9]") ~= nil,
        "a current FATAL acceptance phase was not counted as a current fatal error:\n" .. manifest)
end

-- ---------------------------------------------------------------------
-- Fifth follow-up (release/2.3.1.0-final-prep) fixtures: CURRENT worker-run
-- health as an independent proof of current runtime health, with ZERO
-- acceptance-phase fixtures collected. Each fixture explicitly removes the
-- current-session evidence tree, so acceptance_phases_status is
-- not_collected and phases_included is 0 -- final_runtime_health can only
-- reach ok through current worker evidence, never through phases.
--
-- Current run identity uses STEMwerk's own generated run naming
-- (STEMwerk_<epoch>_<ms>_<counter>) plus job evidence that references the
-- run's own ID, exactly like real persisted runs (see
-- deriveCurrentWorkerRunHealth in the production script, which is what
-- these fixtures execute end to end).
-- ---------------------------------------------------------------------

local function currentWorkerRunName()
    return "STEMwerk_" .. tostring(os.time()) .. "_001_1"
end

-- Writes a PROVEN-current session root (session.env with a fresh
-- SESSION_STARTED_UTC, no acceptance-phase directories), so worker runs
-- created afterwards are session-linked CURRENT evidence while the
-- acceptance-phase channel stays explicitly empty (phases_included=0,
-- not_collected). The start is backdated two seconds so same-second runs
-- created just after it always fall inside the session.
local function writeCurrentSessionRoot(context, ageSeconds)
    local evidenceRoot = joinPath(context.extState.runtimeBase, "evidence", "current-session")
    mkdirP(evidenceRoot)
    writeFile(joinPath(evidenceRoot, "session.env"), table.concat({
        "EVIDENCE_SCHEMA=1",
        "SESSION_ID=headless-current-worker-session",
        "SESSION_STARTED_UTC=" .. os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - (tonumber(ageSeconds) or 2)),
        "",
    }, "\n"))
end

-- Writes one persisted run with the given jobs. Each job spec:
--   { name, exit=<number|nil>, done=<bool>, model=<string|nil>,
--     outputCount=<number|nil>, outputNames=<string|nil>,
--     validation=<string|nil>, phaseEvidence=<bool> }
-- phaseEvidence=false writes no phase/timing jsonl at all (a job that
-- never reported completion evidence of its own).
local function writeCurrentWorkerRun(context, runName, jobs)
    local runsRoot = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs")
    for _, job in ipairs(jobs) do
        local jobDir = joinPath(runsRoot, runName, job.name)
        mkdirP(jobDir)
        if job.exit ~= nil then
            writeFile(joinPath(jobDir, "exit_code.txt"), tostring(job.exit) .. "\n")
        end
        if job.done then
            writeFile(joinPath(jobDir, "done.txt"), "DONE\n")
        end
        if job.phaseEvidence ~= false then
            local fields = {
                '"time":' .. tostring(os.time()),
                '"device":"cpu"',
                '"result":"success"',
            }
            if job.model then fields[#fields + 1] = '"model":"' .. job.model .. '"' end
            if job.outputCount then fields[#fields + 1] = '"output_count":' .. tostring(job.outputCount) end
            if job.outputNames then fields[#fields + 1] = '"output_names":"' .. job.outputNames .. '"' end
            if job.validation then fields[#fields + 1] = '"output_validation_reason":"' .. job.validation .. '"' end
            writeFile(joinPath(jobDir, "phase_events.jsonl"), "{" .. table.concat(fields, ",") .. "}\n")
            -- The job_dir field references the run's own ID, giving the run
            -- its unambiguous self-consistent identity (same shape real
            -- runs write).
            writeFile(joinPath(jobDir, "timing_events.jsonl"),
                '{"time":' .. tostring(os.time()) .. ',"event":"done_seen","job_index":"' .. job.name
                .. '","job_dir":"/tmp/' .. runName .. '"}\n')
        end
    end
end

local function successfulWorkerJob(name)
    return {
        name = name,
        exit = 0,
        done = true,
        model = "htdemucs",
        outputCount = 4,
        outputNames = "bass,drums,other,vocals",
        validation = "ok",
    }
end


-- Shared assertions for every zero-phase worker fixture: the acceptance
-- phase channel must be explicitly EMPTY so it cannot be the hidden reason
-- for any PASS.
local function assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("phases_included:%s+0") ~= nil,
        "expected exactly 0 included acceptance phases:\n" .. manifest)
    assertf(manifest:find("acceptance_phases_status:%s+not_collected") ~= nil,
        "expected acceptance_phases_status=not_collected:\n" .. manifest)
    assertf(manifest:find("current_phase_health:%s+not_collected") ~= nil,
        "expected current_phase_health=not_collected:\n" .. manifest)
end

-- EIGHTHFU (eighth follow-up) is declared here, ahead of the "no-phases"
-- fixtures below, so those fixtures can call EIGHTHFU.writeWorkerContextFile
-- / EIGHTHFU.writeCurrentProcessingRecord (defined further down this file)
-- to migrate onto the RunContext authority hardening's structured-identity
-- path. Lua resolves EIGHTHFU.<field> at CALL time (from main(), after the
-- whole file has loaded and every EIGHTHFU field is populated), so the
-- declaration only needs to exist before it is first REFERENCED in a
-- function body that can actually run -- not before every field is filled
-- in textually.
local EIGHTHFU = {}

-- Fixture 1: cached-healthy bootstrap + current successful worker run +
-- ZERO acceptance phases => health proven by worker evidence alone.
local function createCachedBootstrapCurrentWorkerNoPhasesScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "cached-bootstrap-current-worker-no-phases"
    -- bootstrap.env stays untouched (STATUS=ok / RUNTIME_VERIFY_DETAIL=ok:
    -- cached-healthy provenance only).
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    -- RunContext authority hardening migration: this fixture's whole point
    -- is "current worker evidence alone proves health, independent of
    -- acceptance phases" -- that intent only survives the hardening (which
    -- makes structured identity the SOLE current-health authority) if the
    -- run also carries genuine structured identity, not just the legacy
    -- session-timestamp/job_dir-marker evidence writeCurrentWorkerRun
    -- already writes.
    context.runId = "guid-cached-bootstrap-no-phases-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

local function assertCachedBootstrapCurrentWorkerNoPhasesScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("bootstrap_readiness:%s+cached_healthy") ~= nil,
        "cached bootstrap-healthy provenance was not exposed:\n" .. manifest)
    assertf(manifest:find("current_worker_health:%s+ok") ~= nil,
        "current successful worker run did not prove current_worker_health=ok:\n" .. manifest)
    assertf(manifest:find("current_worker_health_run:%s+" .. context.workerRunName) ~= nil,
        "the proving worker run was not identified by its exact run ID:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+current_run_success_contract_met") ~= nil,
        "worker health provenance reason missing:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") ~= nil,
        "current worker evidence with zero acceptance phases did not prove final_runtime_health=ok:\n" .. manifest)
    assertf(manifest:find("final_runtime_health_source:%s+current_worker_evidence") ~= nil,
        "final health source was not attributed to current worker evidence:\n" .. manifest)
end

-- Fixture 2: NO bootstrap health (explicitly failed bootstrap.env) +
-- current successful worker run + ZERO acceptance phases => worker evidence
-- alone still proves health.
local function createNoBootstrapCurrentWorkerNoPhasesScenario(baseRoot)
    local context = createCachedBootstrapCurrentWorkerNoPhasesScenario(baseRoot)
    context.name = "no-bootstrap-current-worker-no-phases"
    writeFile(joinPath(context.extState.runtimeBase, "state", "bootstrap.env"), table.concat({
        "PYTHON_PATH=" .. context.fakePythonPath,
        "FFMPEG_PATH=" .. context.fakeFfmpegPath,
        "STATUS=failed",
        "STATUS_REASON=runtime_verification_failed",
        "BACKEND=rocm",
        "BOOTSTRAP_STATUS=failed",
        "VENV_PYTHON=" .. context.fakePythonPath,
        "RUNTIME_VERIFY_DETAIL=failed",
        "",
    }, "\n"))
    return context
end

local function assertNoBootstrapCurrentWorkerNoPhasesScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("bootstrap_readiness:%s+cached_unhealthy_or_unrecorded") ~= nil,
        "failed bootstrap.env was not exposed as cached_unhealthy_or_unrecorded:\n" .. manifest)
    assertf(manifest:find("current_worker_health:%s+ok") ~= nil,
        "current successful worker run did not prove current_worker_health=ok:\n" .. manifest)
    assertf(manifest:find("current_worker_health_run:%s+" .. context.workerRunName) ~= nil,
        "the proving worker run was not identified by its exact run ID:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") ~= nil,
        "current worker evidence with no bootstrap health and zero phases did not prove final_runtime_health=ok:\n" .. manifest)
    assertf(manifest:find("final_runtime_health_source:%s+current_worker_evidence") ~= nil,
        "final health source was not attributed to current worker evidence:\n" .. manifest)
end

-- Fixture 3: current run where job1 fully succeeds but job2 exits 1, ZERO
-- acceptance phases => one successful job must never clear another
-- required job's failure; worker health is FAILED, not ok.
local function createMixedJobFailureNoPhasesScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "mixed-job-failure-no-phases"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, {
        successfulWorkerJob("job1"),
        { name = "job2", exit = 1, done = false, phaseEvidence = false },
    })
    -- RunContext authority hardening migration: this run must be
    -- structurally CURRENT (not just legacy-session-linked) for
    -- current_worker_health to be evaluated as "failed" rather than
    -- falling back to mere recent-unlinked provenance -- both jobs get
    -- real structured identity, matching a genuinely current run where
    -- job2 has already observably failed.
    context.runId = "guid-mixed-job-failure-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "job1", context.runId, "job1")
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "job2", context.runId, "job2")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "failed", context.workerRunName)
    return context
end

local function assertMixedJobFailureNoPhasesScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+failed") ~= nil,
        "a current run with a failed required job was not classified as worker health FAILED:\n" .. manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "one successful job cleared another required job's failure in the same current run:\n" .. manifest)
    assertf(manifest:find("current_fatal_error_count:%s+[1-9]") ~= nil,
        "an explicitly failed current worker run was not counted as current failure evidence:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite an explicitly failed current worker run:\n" .. manifest)
end

-- Fixture 4: current run, exit 0/DONE, but outputs incomplete for the
-- flow's known expectation (2 found vs 4 expected), ZERO phases =>
-- not healthy (unproven), never a false ok.
local function createIncompleteOutputNoPhasesScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "incomplete-output-no-phases"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, {
        {
            name = "single",
            exit = 0,
            done = true,
            model = "htdemucs",
            outputCount = 2,
            outputNames = "other,vocals",
            validation = "ok",
        },
    })
    -- RunContext authority hardening migration: structured identity is
    -- required for this run to be evaluated as CURRENT at all (rather than
    -- falling back to recent-unlinked, which would report a different,
    -- generic reason instead of this job's own missing-stems reason).
    context.runId = "guid-incomplete-output-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

local function assertIncompleteOutputNoPhasesScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "exit-0/DONE with incomplete outputs was accepted as worker health proof:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+missing_required_stems") ~= nil,
        "incomplete-output run was not labeled with the missing-stems reason:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite incomplete current-run outputs:\n" .. manifest)
end

-- Fixture 5: current run, exit 0/DONE, complete outputs, but validation
-- explicitly FAILED, ZERO phases => not healthy.
local function createValidationFailureNoPhasesScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "validation-failure-no-phases"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, {
        {
            name = "single",
            exit = 0,
            done = true,
            model = "htdemucs",
            outputCount = 4,
            outputNames = "bass,drums,other,vocals",
            validation = "failed",
        },
    })
    return context
end

local function assertValidationFailureNoPhasesScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "exit-0/DONE with failed validation was accepted as worker health proof:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite failed validation in the current run:\n" .. manifest)
end

-- Fixture 6: historical "Runtime verification passed." sentence only (no
-- cached bootstrap health) + current successful worker run + ZERO phases
-- => worker evidence proves health; the historical sentence stays
-- provenance only.
local function createHistoricalLogCurrentWorkerNoPhasesScenario(baseRoot)
    local context = createNoBootstrapCurrentWorkerNoPhasesScenario(baseRoot)
    context.name = "historical-log-current-worker-no-phases"
    writeFile(joinPath(context.extState.runtimeBase, "logs", "bootstrap.log"), table.concat({
        "bootstrap ok (old run)",
        "Runtime verification passed.",
        "",
    }, "\n"))
    return context
end

local function assertHistoricalLogCurrentWorkerNoPhasesScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("historical_runtime_verification_sentence_seen:%s+yes_not_used_as_current_proof") ~= nil,
        "historical success sentence was not kept as provenance-only:\n" .. manifest)
    assertf(manifest:find("current_worker_health:%s+ok") ~= nil,
        "current worker run did not prove health alongside historical-only log evidence:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") ~= nil,
        "current worker evidence did not determine current health over historical provenance:\n" .. manifest)
    assertf(manifest:find("final_runtime_health_source:%s+current_worker_evidence") ~= nil,
        "final health source was not attributed to current worker evidence:\n" .. manifest)
end

-- Fixture 7: cached-healthy bootstrap + ZERO phases + only a HISTORICAL
-- (non-current-identity) successful run => not_proven. The persisted
-- STEMwerk_intel_six run inherited from the present-runtime fixture has
-- full success signals but no current run identity, so it must never
-- prove CURRENT health.
local function createCachedBootstrapOnlyNoPhasesScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "cached-bootstrap-only-no-phases"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    -- Deliberately keeps the inherited STEMwerk_intel_six successful run.
    return context
end

local function assertCachedBootstrapOnlyNoPhasesScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("bootstrap_readiness:%s+cached_healthy") ~= nil,
        "cached bootstrap-healthy provenance was not exposed:\n" .. manifest)
    assertf(manifest:find("current_worker_health:%s+not_proven") ~= nil,
        "a historical successful run without current run identity proved current worker health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+no_current_run_evidence") ~= nil,
        "absence of current worker evidence was not labeled explicitly:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+not_proven") ~= nil,
        "cached bootstrap health plus a historical successful run proved final_runtime_health=ok:\n" .. manifest)
    assertf(manifest:find("final_runtime_health_source:%s+none") ~= nil,
        "no health source may be credited when health is not proven:\n" .. manifest)
end

-- Fixture 8 (failure precedence): current healthy worker run + a genuinely
-- CURRENT failed acceptance phase in the same current context => the
-- current failure wins; worker success must not mask it.
local function createCurrentWorkerCurrentFatalPhaseScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "current-worker-current-fatal-phase-failure-wins"
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    -- RunContext authority hardening migration: structured identity is
    -- required for this worker run to be evaluated CURRENT at all, so the
    -- precedence this fixture actually tests (a current fatal phase must
    -- still win over a current successful worker run) has a genuinely
    -- current worker run to win against in the first place.
    context.runId = "guid-worker-vs-fatal-phase-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    -- The session root and the failing phase must both be fresh for the
    -- worker run to be session-linked CURRENT evidence under the corrected
    -- currentness model; the inherited July-dated phases become stale and
    -- are excluded, leaving this single fresh fatal phase.
    local freshStart = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 2)
    local freshPhase = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 1)
    local evidenceRoot = joinPath(context.extState.runtimeBase, "evidence", "current-session")
    writeFile(joinPath(evidenceRoot, "session.env"), table.concat({
        "EVIDENCE_SCHEMA=1",
        "SESSION_ID=native-apple-silicon-2306-final",
        "SESSION_STARTED_UTC=" .. freshStart,
        "",
    }, "\n"))
    local phaseDir = joinPath(evidenceRoot, "online_normal")
    writeFile(joinPath(phaseDir, "evidence.env"), table.concat({
        "EVIDENCE_SCHEMA=1",
        "SESSION_ID=native-apple-silicon-2306-final",
        "PHASE=online_normal",
        "DISTRIBUTION=online",
        "STATUS=fatal",
        "TIMESTAMP_UTC=" .. freshPhase,
        "BACKEND=metal",
        "DEVICE=mps",
        "RUNTIME_ARCH=arm64",
        "OUTPUT_VALIDATION_REASON=failed",
        "CURRENT_FATAL_ERROR_COUNT=1",
        "",
    }, "\n"))
    return context
end

local function assertCurrentWorkerCurrentFatalPhaseScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertf(manifest:find("current_worker_health:%s+ok") ~= nil,
        "the current successful worker run was not recognized:\n" .. manifest)
    assertf(manifest:find("current_phase_health:%s+failed") ~= nil,
        "the current fatal phase was not classified as phase health FAILED:\n" .. manifest)
    assertf(manifest:find("current_fatal_error_count:%s+[1-9]") ~= nil,
        "the current fatal phase was not counted as current failure evidence:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "current worker success masked a current fatal phase -- failure must win:\n" .. manifest)
    assertf(manifest:find("final_runtime_health_source:%s+none") ~= nil,
        "no health source may be credited while a current failure exists:\n" .. manifest)
end

-- ---------------------------------------------------------------------
-- Sixth follow-up (release/2.3.1.0-final-prep) fixtures: real-format
-- flow-specific worker evidence. These fixtures persist runs in the exact
-- shape real production runs write (verified against actual persisted
-- runs): DrumSep flows record workflow markers, drumsep_helper_output_dir,
-- expected_stems=/found_stems= with the final child stems, and
-- output_validation_reason=ok in separation_log.txt; normal flows record
-- the final stem->path JSON in stdout.txt and "job_dir" in
-- timing_events.jsonl. Identity comes only from those explicit markers,
-- currentness from the full generated run identity, and validation is
-- required exactly where production emits it.
-- ---------------------------------------------------------------------

-- Writes one DrumSep (Direct Kit / Kit Split) job in the real production
-- evidence shape. opts: source ("dks_direct"|"dks_extract"),
-- found (found_stems= value), validation (output_validation_reason value
-- or nil to omit), identityMarker (false to omit all identity markers).
local function writeRealDrumkitJob(context, runName, jobName, opts)
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", runName, jobName)
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "exit_code.txt"), tostring(opts.exit or 0) .. "\n")
    if opts.done ~= false then
        writeFile(joinPath(jobDir, "done.txt"), "DONE\n")
    end
    local lines = {
        (opts.source == "dks_extract")
            and "Drum Kit Split route detected: workflow_mode=drumkit workflow_source=dks_extract"
            or  "Direct Drum Kit Split route detected: workflow_mode=drumkit workflow_source=dks_direct",
        "workflow_mode=drumkit",
        "workflow_source=" .. opts.source,
        "model_id=MDX23C-DrumSep-aufr33-jarredou.ckpt",
    }
    if opts.source == "dks_extract" then
        lines[#lines + 1] = "dks_extract_stage1_runtime=cuda"
        lines[#lines + 1] = "dks_extract_stage1_device=cuda:0"
        lines[#lines + 1] = "dks_extract_stage2_runtime=cpu"
        lines[#lines + 1] = "dks_extract_stage2_device=cpu"
    end
    if opts.identityMarker ~= false then
        lines[#lines + 1] = "drumsep_helper_output_dir=/tmp/" .. runName
            .. (opts.source == "dks_extract" and "/stage2_drumsep" or "")
    end
    if opts.validation then
        lines[#lines + 1] = "output_validation_reason=" .. opts.validation
    end
    lines[#lines + 1] = "expected_stems=" .. (opts.expected or "kick,snare,toms,hihat,ride,crash")
    if opts.found then
        lines[#lines + 1] = "found_stems=" .. opts.found
    end
    lines[#lines + 1] = "timing_utc=2026-08-13T09:00:00 drumsep_helper_returncode=0"
    writeFile(joinPath(jobDir, "separation_log.txt"), table.concat(lines, "\n") .. "\n")
    if opts.identityMarker ~= false then
        local timingFields = '"time":' .. tostring(os.time()) .. ',"event":"done_seen","job_index":"' .. jobName
            .. '","job_dir":"/tmp/' .. runName .. '"'
        -- opts.outputCount simulates a job that only ever reported a bare
        -- output COUNT (e.g. output_count=6) with no parsed stem names --
        -- the count-only evidence class that must never substitute for the
        -- canonical named stem set.
        if opts.outputCount then
            timingFields = timingFields .. ',"output_count":' .. tostring(opts.outputCount)
        end
        writeFile(joinPath(jobDir, "timing_events.jsonl"), "{" .. timingFields .. "}\n")
    end
end

-- Migrated for the RunContext authority hardening: this shared assertion
-- used to accept "current_session" (the legacy session-timestamp path) as
-- proof of current health. That path can never prove current health any
-- more -- every caller now also writes genuine structured identity (see
-- each create*Scenario below), so the correct, still-current-proving
-- classification is "current_processing".
local function assertWorkerProvenZeroPhases(manifest, context)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") ~= nil,
        "real-format successful run did not prove current_worker_health=ok:\n" .. manifest)
    assertf(manifest:find("current_worker_health_run:%s+" .. context.workerRunName) ~= nil,
        "the proving worker run was not identified by its exact run ID:\n" .. manifest)
    assertf(manifest:find("worker_context_identity:%s+current_processing") ~= nil,
        "the proving worker run was not classified as current_processing (structured-identity) evidence:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") ~= nil,
        "real-format successful run with zero phases did not prove final_runtime_health=ok:\n" .. manifest)
    assertf(manifest:find("final_runtime_health_source:%s+current_worker_evidence") ~= nil,
        "final health source was not attributed to current worker evidence:\n" .. manifest)
end

-- Real-format Direct Kit success, ZERO acceptance phases.
local function createRealDirectKitZeroPhasesScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "real-format-direct-kit-zero-phases-success"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = "dks_direct",
        found = "kick,snare,toms,hihat,ride,crash",
        validation = "ok",
    })
    -- RunContext authority hardening migration: real production success
    -- must still prove current health, but only via genuine structured
    -- identity now -- add it alongside the existing real-format marker
    -- evidence above.
    context.runId = "guid-real-direct-kit-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

local function assertRealDirectKitZeroPhasesScenario(bundleDir, context)
    assertWorkerProvenZeroPhases(readManifest(bundleDir), context)
end

-- Real-format Kit Split success, ZERO acceptance phases. Health must come
-- from the FINAL (stage 2) DrumSep child stems, never stage 1 alone.
local function createRealKitSplitZeroPhasesScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "real-format-kit-split-zero-phases-success"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = "dks_extract",
        found = "kick,snare,toms,hihat,ride,crash",
        validation = "ok",
    })
    -- RunContext authority hardening migration (see the Direct Kit
    -- twin above): add genuine structured identity.
    context.runId = "guid-real-kit-split-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

local function assertRealKitSplitZeroPhasesScenario(bundleDir, context)
    assertWorkerProvenZeroPhases(readManifest(bundleDir), context)
end

-- Direct Kit with only 5 of 6 final child stems (crash missing), exit 0,
-- DONE, validation ok: outputs are incomplete for the flow => not healthy.
local function createDirectKitFiveOfSixScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "direct-kit-five-of-six-not-healthy"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = "dks_direct",
        found = "kick,snare,toms,hihat,ride",
        validation = "ok",
    })
    -- RunContext authority hardening migration: structured identity is
    -- required for this run to be evaluated CURRENT at all, so its own
    -- missing-stems reason keeps being reported.
    context.runId = "guid-direct-kit-five-of-six-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

local function assertDirectKitFiveOfSixScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "Direct Kit with 5/6 final child stems proved worker health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+missing_required_stems") ~= nil,
        "5/6 Direct Kit run was not labeled missing_required_stems:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite incomplete Direct Kit child stems:\n" .. manifest)
end

-- Kit Split with only 5 of 6 final child stems => not healthy.
local function createKitSplitFiveOfSixScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "kit-split-five-of-six-not-healthy"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = "dks_extract",
        found = "kick,snare,toms,hihat,ride",
        validation = "ok",
    })
    -- RunContext authority hardening migration (see Direct Kit twin above).
    context.runId = "guid-kit-split-five-of-six-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

local function assertKitSplitFiveOfSixScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "Kit Split with 5/6 final child stems proved worker health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+missing_required_stems") ~= nil,
        "5/6 Kit Split run was not labeled missing_required_stems:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite incomplete Kit Split child stems:\n" .. manifest)
end

-- Eighth follow-up: a bare output_count=6 (no found_stems, no parsed stem
-- names at all) must never substitute for the canonical named DrumSep
-- child-stem set, even though the count matches exactly.

function EIGHTHFU.createDirectKitCountOnlySixScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "direct-kit-count-only-six-rejected"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = "dks_direct",
        outputCount = 6,
        validation = "ok",
    })
    -- RunContext authority hardening migration: structured identity is
    -- required for this run to be evaluated CURRENT at all.
    context.runId = "guid-direct-kit-count-only-six-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function EIGHTHFU.assertDirectKitCountOnlySixScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "Direct Kit output_count=6 with no named stem evidence proved worker health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+missing_canonical_stem_names") ~= nil,
        "count-only Direct Kit run was not labeled missing_canonical_stem_names:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok from Direct Kit count-only evidence:\n" .. manifest)
end

-- Kit Split equivalent of the count-only rejection above.
function EIGHTHFU.createKitSplitCountOnlySixScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "kit-split-count-only-six-rejected"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = "dks_extract",
        outputCount = 6,
        validation = "ok",
    })
    -- RunContext authority hardening migration (see Direct Kit twin above).
    context.runId = "guid-kit-split-count-only-six-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function EIGHTHFU.assertKitSplitCountOnlySixScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "Kit Split output_count=6 with no named stem evidence proved worker health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+missing_canonical_stem_names") ~= nil,
        "count-only Kit Split run was not labeled missing_canonical_stem_names:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok from Kit Split count-only evidence:\n" .. manifest)
end

-- Six ARBITRARY names (not the canonical DrumSep child stems) must never
-- prove health just because the count happens to be 6.
function EIGHTHFU.createDirectKitSixArbitraryNamesScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "direct-kit-six-arbitrary-names-rejected"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = "dks_direct",
        found = "alpha,bravo,charlie,delta,echo,foxtrot",
        validation = "ok",
    })
    -- RunContext authority hardening migration: structured identity is
    -- required for this run to be evaluated CURRENT at all.
    context.runId = "guid-direct-kit-six-arbitrary-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function EIGHTHFU.assertDirectKitSixArbitraryNamesScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "Direct Kit with 6 arbitrary names proved worker health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+missing_required_stems") ~= nil,
        "arbitrary-name Direct Kit run was not labeled missing_required_stems:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok from Direct Kit arbitrary stem names:\n" .. manifest)
end

-- Kit Split equivalent of the six-arbitrary-names rejection above.
function EIGHTHFU.createKitSplitSixArbitraryNamesScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "kit-split-six-arbitrary-names-rejected"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = "dks_extract",
        found = "alpha,bravo,charlie,delta,echo,foxtrot",
        validation = "ok",
    })
    -- RunContext authority hardening migration (see Direct Kit twin above).
    context.runId = "guid-kit-split-six-arbitrary-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function EIGHTHFU.assertKitSplitSixArbitraryNamesScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "Kit Split with 6 arbitrary names proved worker health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+missing_required_stems") ~= nil,
        "arbitrary-name Kit Split run was not labeled missing_required_stems:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok from Kit Split arbitrary stem names:\n" .. manifest)
end

-- Direct Kit with all 6 child stems, exit 0, DONE, but NO validation
-- marker. Production DrumSep flows always emit output_validation_reason,
-- so its absence must not silently count as successful validation.
local function createMissingRequiredValidationScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "missing-required-validation-not-healthy"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = "dks_direct",
        found = "kick,snare,toms,hihat,ride,crash",
        validation = nil,
    })
    -- RunContext authority hardening migration: structured identity is
    -- required for this run to be evaluated CURRENT at all.
    context.runId = "guid-missing-required-validation-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

local function assertMissingRequiredValidationScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "Direct Kit without its validation marker proved worker health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+missing_required_validation") ~= nil,
        "validation-less DrumSep run was not labeled missing_required_validation:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite missing required validation:\n" .. manifest)
end

-- A valid-looking generated run directory whose job text mentions the run
-- ID only as an arbitrary prose substring (no recognized identity marker):
-- must NOT establish current run identity even with exit0/DONE/outputs.
local function createArbitrarySubstringIdentityScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "arbitrary-run-id-substring-does-not-identify-run"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    writeFile(joinPath(jobDir, "done.txt"), "DONE\n")
    writeFile(joinPath(jobDir, "phase_events.jsonl"),
        '{"time":1,"model":"htdemucs","device":"cpu","result":"success","output_count":4,"output_names":"bass,drums,other,vocals","output_validation_reason":"ok"}\n')
    -- Prose mention of the exact run ID, but no job_dir JSON field and no
    -- drumsep_helper_output_dir= marker anywhere.
    writeFile(joinPath(jobDir, "stdout.txt"),
        "operator note: compared against leftover output from " .. context.workerRunName .. " last week\n")
    return context
end

local function assertArbitrarySubstringIdentityScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "an arbitrary prose substring of the run ID established current run identity:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+no_current_run_evidence") ~= nil,
        "unidentified run evidence was not excluded from current worker evidence:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok from evidence with no recognized run identity marker:\n" .. manifest)
end

-- Positive identity control: a normal-flow run in the real production
-- shape whose ONLY run-identity marker is the explicit "job_dir" JSON
-- field in timing_events.jsonl (exactly what real runs write).
local function createExplicitRunIdMarkerScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "explicit-run-id-marker-identifies-run"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    writeFile(joinPath(jobDir, "done.txt"), "DONE\n")
    writeFile(joinPath(jobDir, "timing_events.jsonl"),
        '{"time":' .. tostring(os.time()) .. ',"event":"done_seen","job_index":"single","job_dir":"/tmp/' .. context.workerRunName .. '"}\n')
    -- Real normal-flow runs unconditionally print "model_name=<model>" to
    -- stderr (separation_log.txt) before separation starts (see
    -- audio_separator_process.py's normal-workflow success path); a
    -- positive identity control claiming "the real production shape" must
    -- include it so the model-recognition contract has genuine evidence to
    -- resolve against.
    writeFile(joinPath(jobDir, "separation_log.txt"), "model_name=htdemucs\n")
    writeFile(joinPath(jobDir, "stdout.txt"), table.concat({
        "PROGRESS:92:Writing stems",
        "PROGRESS:100:Complete",
        '{"bass": "/tmp/' .. context.workerRunName .. '/bass.wav", "drums": "/tmp/' .. context.workerRunName .. '/drums.wav", "other": "/tmp/' .. context.workerRunName .. '/other.wav", "vocals": "/tmp/' .. context.workerRunName .. '/vocals.wav"}',
        "",
    }, "\n"))
    -- RunContext authority hardening migration: add genuine structured
    -- identity so this run is evaluated CURRENT via the only authoritative
    -- path now available.
    context.runId = "guid-explicit-run-id-marker-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

local function assertExplicitRunIdMarkerScenario(bundleDir, context)
    assertWorkerProvenZeroPhases(readManifest(bundleDir), context)
end

-- A successful identified run ~20 hours before bundle time, with no
-- current-session correlation and no newer processing evidence: historical
-- provenance only, never current proof.
local function createOldSuccessNotCurrentScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "old-success-alone-not-current"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = "STEMwerk_" .. tostring(os.time() - 72000) .. "_001_1"
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = "dks_direct",
        found = "kick,snare,toms,hihat,ride,crash",
        validation = "ok",
    })
    return context
end

local function assertOldSuccessNotCurrentScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a 20-hour-old success proved CURRENT worker health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+identified_run_outside_current_window") ~= nil,
        "the stale identified run was not labeled as outside the current window:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok from a 20-hour-old success alone:\n" .. manifest)
end

-- Same-second ordering: lower ms/counter succeeds, later ms/counter fails
-- => the later explicit failure wins deterministically.
local function createSameSecondSuccessThenFailureScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "same-second-success-then-failure"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    local epoch = os.time()
    context.workerRunName = "STEMwerk_" .. tostring(epoch) .. "_002_2"
    writeRealDrumkitJob(context, "STEMwerk_" .. tostring(epoch) .. "_001_1", "single", {
        source = "dks_direct",
        found = "kick,snare,toms,hihat,ride,crash",
        validation = "ok",
    })
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = "dks_direct",
        exit = 1,
        done = false,
        found = "kick,snare,toms,hihat,ride,crash",
        validation = "ok",
    })
    -- RunContext authority hardening migration: only the LATER (failing)
    -- run gets structured identity, so it -- and only it -- is the one
    -- structurally selected as current; the earlier successful run is
    -- deliberately left without any, so it cannot interfere.
    context.runId = "guid-same-second-success-then-failure-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "failed", context.workerRunName)
    return context
end

local function assertSameSecondSuccessThenFailureScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+failed") ~= nil,
        "the later same-second failure did not win over the earlier success:\n" .. manifest)
    assertf(manifest:find("current_fatal_error_count:%s+[1-9]") ~= nil,
        "the later same-second failure was not counted as current failure evidence:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a later same-second explicit failure:\n" .. manifest)
end

-- Same-second ordering, reversed: earlier failure, later proven success =>
-- the newer proven success supersedes the older failure.
local function createSameSecondFailureThenSuccessScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "same-second-failure-then-success"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    local epoch = os.time()
    context.workerRunName = "STEMwerk_" .. tostring(epoch) .. "_002_2"
    writeRealDrumkitJob(context, "STEMwerk_" .. tostring(epoch) .. "_001_1", "single", {
        source = "dks_direct",
        exit = 1,
        done = false,
        found = "kick,snare,toms,hihat,ride,crash",
        validation = "ok",
    })
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = "dks_direct",
        found = "kick,snare,toms,hihat,ride,crash",
        validation = "ok",
    })
    -- RunContext authority hardening migration: only the LATER
    -- (succeeding) run gets structured identity, so it is the one
    -- structurally selected as current; the earlier failing run is
    -- deliberately left without any.
    context.runId = "guid-same-second-failure-then-success-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

local function assertSameSecondFailureThenSuccessScenario(bundleDir, context)
    assertWorkerProvenZeroPhases(readManifest(bundleDir), context)
    local manifest = readManifest(bundleDir)
    assertf(manifest:find("current_fatal_error_count:%s+0") ~= nil,
        "the superseded earlier same-second failure was still counted as current:\n" .. manifest)
end

-- ---------------------------------------------------------------------
-- Seventh follow-up (release/2.3.1.0-final-prep) fixtures: canonical
-- DrumSep six-stem requirement, per-job identity, newest-context-only
-- evaluation, current vs recent vs historical worker evidence, and
-- narrow-preset output contracts.
-- ---------------------------------------------------------------------

-- A reduced/malformed expected_stems must never weaken the fixed canonical
-- six-stem requirement for DrumSep flows.
local function createReducedExpectedStemsScenario(baseRoot, source, fixtureName)
    local context = createPresentScenario(baseRoot)
    context.name = fixtureName
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = source,
        found = "kick,snare,toms,hihat,ride",
        expected = "kick,snare,toms,hihat,ride",
        validation = "ok",
    })
    -- RunContext authority hardening migration: structured identity is
    -- required for this run to be evaluated CURRENT at all, so its own
    -- missing-stems reason (rather than a generic non-current reason)
    -- keeps being reported.
    context.runId = "guid-" .. fixtureName .. "-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

local function assertReducedExpectedStemsScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a reduced expected_stems weakened the canonical six-stem requirement:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+missing_required_stems") ~= nil,
        "the missing canonical crash stem was not reported:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a missing canonical child stem:\n" .. manifest)
end

-- Same run directory: job A carries valid explicit identity and full
-- success evidence; job B carries full success evidence but NO identity
-- marker. Job B must not inherit job A's identity, so the run cannot be
-- proven healthy while job B is required.
local function createPerJobIdentityScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "same-run-job-a-identified-job-b-unidentified"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("jobA") })
    local jobB = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "jobB")
    mkdirP(jobB)
    writeFile(joinPath(jobB, "exit_code.txt"), "0\n")
    writeFile(joinPath(jobB, "done.txt"), "DONE\n")
    writeFile(joinPath(jobB, "phase_events.jsonl"),
        '{"time":2,"model":"htdemucs","device":"cpu","result":"success","output_count":4,"output_names":"bass,drums,other,vocals","output_validation_reason":"ok"}\n')
    -- RunContext authority hardening migration: jobA gets genuine
    -- structured identity so the run is structurally selected as current;
    -- jobB deliberately gets none at all, which is the whole point of
    -- this fixture (an unidentified required job must still block health,
    -- not inherit jobA's identity).
    context.runId = "guid-per-job-identity-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "jobA", context.runId, "jobA")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

local function assertPerJobIdentityScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "an unidentified job inherited another job's run identity:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+job_identity_unassociated") ~= nil,
        "the unidentified job was not labeled unassociated:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite an unidentified required job:\n" .. manifest)
end

-- RunContext authority hardening migration: this fixture originally tested
-- conflicting legacy job_dir/drumsep_helper_output_dir MARKERS (timing
-- job_dir names this run; drumsep_helper_output_dir names a different
-- run). That marker-only conflict concept is now provenance-only -- with
-- no worker_context.json at all, this run has no way to be structurally
-- SELECTED as current in the first place, so it can no longer exercise
-- "job_identity_conflicting" as a current-health reason at all (it simply
-- falls out of current-health consideration entirely, like any other
-- legacy-only evidence -- see structured-identity-current family).
--
-- Repurposed here to test the actual NEW authoritative conflict this
-- hardening closes (required fixture #21): a Direct Kit job's
-- worker_context.json (written by the Python worker) disagrees with the
-- DrumSep helper's OWN echoed identity (stage2_drumsep/drumsep_result.json,
-- written independently by the helper subprocess) -- "structured context
-- wins, ignore the helper conflict" must never be applied.
local function createConflictingIdentityScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "direct-kit-worker-helper-identity-conflict"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = "dks_direct",
        found = "kick,snare,toms,hihat,ride,crash",
        validation = "ok",
    })
    context.runId = "guid-direct-kit-conflict-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    -- The DrumSep helper's OWN echoed identity (stage2_drumsep/
    -- drumsep_result.json) disagrees with worker_context.json's run_id --
    -- a genuine worker/helper conflict, never resolved by trusting
    -- whichever one is "structured".
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "single")
    mkdirP(joinPath(jobDir, "stage2_drumsep"))
    writeFile(joinPath(jobDir, "stage2_drumsep", "drumsep_result.json"), table.concat({
        "{",
        '  "run_id": "guid-direct-kit-conflict-helper-mismatch",',
        '  "job_id": "single"',
        "}",
        "",
    }, "\n"))
    return context
end

local function assertConflictingIdentityScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a Direct Kit worker/helper identity conflict was accepted via structured-context-wins:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+job_identity_conflicting") ~= nil,
        "the Direct Kit worker/helper identity conflict was not labeled conflicting:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a Direct Kit worker/helper identity conflict:\n" .. manifest)
end

-- Copied evidence: a current-shaped run directory whose only job's
-- identity markers all name a DIFFERENT run. The evidence must stay with
-- its own run and cannot identify this directory.
local function createCopiedJobEvidenceScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "copied-job-evidence-from-another-run"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    local foreignRun = "STEMwerk_" .. tostring(os.time() - 10) .. "_500_1"
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    writeFile(joinPath(jobDir, "done.txt"), "DONE\n")
    writeFile(joinPath(jobDir, "timing_events.jsonl"),
        '{"time":' .. tostring(os.time()) .. ',"event":"done_seen","job_index":"single","job_dir":"/tmp/' .. foreignRun .. '"}\n')
    writeFile(joinPath(jobDir, "phase_events.jsonl"),
        '{"time":2,"model":"htdemucs","device":"cpu","result":"success","output_count":4,"output_names":"bass,drums,other,vocals","output_validation_reason":"ok"}\n')
    return context
end

local function assertCopiedJobEvidenceScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "copied job evidence from another run identified this run:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+no_current_run_evidence") ~= nil,
        "foreign-identified evidence was not excluded from this run:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok from copied foreign-run evidence:\n" .. manifest)
end

-- The NEWEST identified current context decides: an older proven success
-- must not be used when the newest current context is unproven.
local function createNewerUnprovenSupersedesScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "older-success-newer-unproven"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context, 30)
    local epoch = os.time()
    writeCurrentWorkerRun(context, "STEMwerk_" .. tostring(epoch - 5) .. "_001_1", { successfulWorkerJob("single") })
    context.workerRunName = "STEMwerk_" .. tostring(epoch) .. "_001_1"
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    writeFile(joinPath(jobDir, "done.txt"), "DONE\n")
    -- Identified and complete, but no output evidence at all: unproven.
    writeFile(joinPath(jobDir, "timing_events.jsonl"),
        '{"time":' .. tostring(epoch) .. ',"event":"done_seen","job_index":"single","job_dir":"/tmp/' .. context.workerRunName .. '"}\n')
    -- RunContext authority hardening migration: only the NEWER (unproven)
    -- run gets structured identity, so it -- not the older successful run
    -- -- is the one structurally selected as current, matching this
    -- fixture's actual point (newest current context wins, even unproven).
    context.runId = "guid-older-success-newer-unproven-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

local function assertNewerUnprovenSupersedesScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "an older proven success was used although the newest current context is unproven:\n" .. manifest)
    assertf(manifest:find("current_worker_health_run:%s+" .. context.workerRunName) ~= nil,
        "the newest (unproven) context was not the one evaluated:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+unrecognized_model_contract") ~= nil,
        "the newest unproven context's reason was not reported:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok from an older success despite a newer unproven context:\n" .. manifest)
end

-- Inverse: older explicit failure, newer proven success => the newer
-- success supersedes (distinct epochs).
local function createNewerSuccessSupersedesScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "older-failure-newer-success"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context, 30)
    local epoch = os.time()
    writeRealDrumkitJob(context, "STEMwerk_" .. tostring(epoch - 5) .. "_001_1", "single", {
        source = "dks_direct",
        exit = 1,
        done = false,
        found = "kick,snare,toms,hihat,ride,crash",
        validation = "ok",
    })
    context.workerRunName = "STEMwerk_" .. tostring(epoch) .. "_001_1"
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    -- RunContext authority hardening migration: only the NEWER (succeeding)
    -- run gets structured identity, so it is the one structurally selected
    -- as current; the older failing run is deliberately left without any.
    context.runId = "guid-older-failure-newer-success-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

local function assertNewerSuccessSupersedesScenario(bundleDir, context)
    assertWorkerProvenZeroPhases(readManifest(bundleDir), context)
    local manifest = readManifest(bundleDir)
    assertf(manifest:find("current_fatal_error_count:%s+0") ~= nil,
        "the superseded older failure was still counted as current:\n" .. manifest)
end

-- Same-second ordering with an unproven newest context: no fallback to the
-- same-second older success.
local function createSameSecondNewerUnprovenScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "same-second-success-then-unproven"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    local epoch = os.time()
    writeCurrentWorkerRun(context, "STEMwerk_" .. tostring(epoch) .. "_001_1", { successfulWorkerJob("single") })
    context.workerRunName = "STEMwerk_" .. tostring(epoch) .. "_002_2"
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    writeFile(joinPath(jobDir, "done.txt"), "DONE\n")
    writeFile(joinPath(jobDir, "timing_events.jsonl"),
        '{"time":' .. tostring(epoch) .. ',"event":"done_seen","job_index":"single","job_dir":"/tmp/' .. context.workerRunName .. '"}\n')
    -- RunContext authority hardening migration: only the same-second NEWER
    -- (unproven) run gets structured identity, so it -- not the older
    -- successful run -- is the one structurally selected as current.
    context.runId = "guid-same-second-newer-unproven-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

local function assertSameSecondNewerUnprovenScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "same-second older success was used although the same-second newer context is unproven:\n" .. manifest)
    assertf(manifest:find("current_worker_health_run:%s+" .. context.workerRunName) ~= nil,
        "the same-second newer (unproven) context was not the one evaluated:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite the newest same-second context being unproven:\n" .. manifest)
end

-- A stale session root (started long before bundle time) must not turn an
-- old run into current evidence, even when the run postdates that stale
-- session start.
local function createStaleSessionRootScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "stale-session-root-does-not-admit-old-run"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    local evidenceRoot = joinPath(context.extState.runtimeBase, "evidence", "current-session")
    mkdirP(evidenceRoot)
    writeFile(joinPath(evidenceRoot, "session.env"), table.concat({
        "EVIDENCE_SCHEMA=1",
        "SESSION_ID=stale-acceptance-session",
        "SESSION_STARTED_UTC=" .. os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 72000),
        "",
    }, "\n"))
    context.workerRunName = "STEMwerk_" .. tostring(os.time() - 68400) .. "_001_1"
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = "dks_direct",
        found = "kick,snare,toms,hihat,ride,crash",
        validation = "ok",
    })
    return context
end

local function assertStaleSessionRootScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a stale session root made an old run current:\n" .. manifest)
    assertf(manifest:find("worker_context_identity:%s+historical") ~= nil,
        "the old run behind a stale session root was not classified historical:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok from an old run admitted by a stale session root:\n" .. manifest)
end

-- A fresh, identified, fully successful run with NO session linkage is
-- recent-unlinked provenance: reported positively as recent, but never
-- current health.
local function createRecentUnlinkedNotCurrentScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "recent-unlinked-success-does-not-prove-current"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    return context
end

local function assertRecentUnlinkedNotCurrentScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a recent but unlinked success was claimed as CURRENT worker health:\n" .. manifest)
    assertf(manifest:find("worker_context_identity:%s+recent_unlinked") ~= nil,
        "the unlinked recent run was not classified recent_unlinked:\n" .. manifest)
    assertf(manifest:find("recent_worker_health:%s+ok") ~= nil,
        "the recent successful run was not surfaced as recent provenance:\n" .. manifest)
    assertf(manifest:find("recent_worker_health_run:%s+" .. context.workerRunName) ~= nil,
        "the recent run provenance did not name the run:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+not_proven") ~= nil,
        "recent unlinked success alone proved final_runtime_health=ok:\n" .. manifest)
    assertf(manifest:find("final_runtime_health_source:%s+none") ~= nil,
        "a health source was credited for merely recent evidence:\n" .. manifest)
end

-- Narrow extraction presets (Vocals Only / Drums Only / Bass Only) in
-- released 2.3.1.0 are import-only selections: the worker always separates
-- and records the FULL model stem set (no per-run preset marker is
-- persisted anywhere), so the correct worker-health contract for these
-- runs is the full normal-flow output set. These fixtures use the exact
-- real production evidence shape of such runs.
local function writeRealNormalFlowJob(context, runName, jobName, modelName, stemNames)
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", runName, jobName)
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    writeFile(joinPath(jobDir, "done.txt"), "DONE\n")
    writeFile(joinPath(jobDir, "timing_events.jsonl"),
        '{"time":' .. tostring(os.time()) .. ',"event":"done_seen","job_index":"' .. jobName .. '","job_dir":"/tmp/' .. runName .. '"}\n')
    writeFile(joinPath(jobDir, "separation_log.txt"), table.concat({
        "workflow_source=normal",
        "workflow_mode=stems",
        "model_name=" .. modelName,
        "",
    }, "\n"))
    local pairs = {}
    for _, stem in ipairs(stemNames) do
        pairs[#pairs + 1] = '"' .. stem .. '": "/tmp/' .. runName .. '/' .. stem .. '.wav"'
    end
    writeFile(joinPath(jobDir, "stdout.txt"), table.concat({
        "PROGRESS:92:Writing stems",
        "PROGRESS:100:Complete",
        "{" .. table.concat(pairs, ", ") .. "}",
        "",
    }, "\n"))
end

local function createNarrowPresetSuccessScenario(baseRoot, fixtureName, modelName, stemNames)
    local context = createPresentScenario(baseRoot)
    context.name = fixtureName
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeRealNormalFlowJob(context, context.workerRunName, "single", modelName, stemNames)
    -- RunContext authority hardening migration: add genuine structured
    -- identity (guid keyed by fixtureName, since this parameterized
    -- creator is called back-to-back for vocals/drums/bass-only within
    -- the same test run and must not collide on run_id).
    context.runId = "guid-" .. fixtureName .. "-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

local function assertNarrowPresetSuccessScenario(bundleDir, context)
    assertWorkerProvenZeroPhases(readManifest(bundleDir), context)
end

-- A narrow-preset run whose recorded outputs are missing a stem the
-- recorded model must have produced: incomplete, not healthy.
local function createNarrowPresetIncompleteScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "narrow-preset-incomplete-output-rejected"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeRealNormalFlowJob(context, context.workerRunName, "single", "htdemucs", { "drums", "other", "vocals" })
    -- RunContext authority hardening migration: structured identity is
    -- required for this run to be evaluated CURRENT at all.
    context.runId = "guid-narrow-preset-incomplete-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

local function assertNarrowPresetIncompleteScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a run missing one of its model's outputs proved worker health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+missing_required_stems") ~= nil,
        "the missing output was not reported as missing_required_stems:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite an incomplete output set:\n" .. manifest)
end

-- ---------------------------------------------------------------------
-- Eighth follow-up (release/2.3.1.0-final-prep) fixtures: Normal/6-Stem
-- worker health must require a RECOGNIZED released model AND canonical
-- output stem NAME membership -- never output count alone, and never any
-- inference at all when the model is missing/unrecognized.
-- ---------------------------------------------------------------------

-- Model missing entirely (no model marker anywhere), exit0, DONE, ONE
-- output: must never be inferred healthy just because something is there.
function EIGHTHFU.createNormalMissingModelScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "normal-missing-model-rejected"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, {
        {
            name = "single",
            exit = 0,
            done = true,
            outputCount = 1,
            outputNames = "vocals",
            validation = "ok",
        },
    })
    -- RunContext authority hardening migration: structured identity is
    -- required for this run to be evaluated CURRENT at all.
    context.runId = "guid-normal-missing-model-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function EIGHTHFU.assertNormalMissingModelScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a run with no model marker proved worker health from one output:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+unrecognized_model_contract") ~= nil,
        "a missing model was not labeled unrecognized_model_contract:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a missing model marker:\n" .. manifest)
end

-- Unrecognized model string, exit0, DONE, six outputs: must never be
-- inferred healthy just because the count happens to look like 6-Stem.
function EIGHTHFU.createNormalUnknownModelScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "normal-unknown-model-rejected"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, {
        {
            name = "single",
            exit = 0,
            done = true,
            model = "future_experimental_model",
            outputCount = 6,
            outputNames = "vocals,drums,bass,other,guitar,piano",
            validation = "ok",
        },
    })
    -- RunContext authority hardening migration: structured identity is
    -- required for this run to be evaluated CURRENT at all.
    context.runId = "guid-normal-unknown-model-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function EIGHTHFU.assertNormalUnknownModelScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a run with an unrecognized model proved worker health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+unrecognized_model_contract") ~= nil,
        "an unrecognized model was not labeled unrecognized_model_contract:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite an unrecognized model:\n" .. manifest)
end

-- Recognized 4-stem model (htdemucs) but four ARBITRARY output names:
-- matching count must never substitute for the canonical stem name set.
function EIGHTHFU.createNormalFourArbitraryNamesScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "normal-four-arbitrary-names-rejected"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, {
        {
            name = "single",
            exit = 0,
            done = true,
            model = "htdemucs",
            outputCount = 4,
            outputNames = "alpha,bravo,charlie,delta",
            validation = "ok",
        },
    })
    -- RunContext authority hardening migration: structured identity is
    -- required for this run to be evaluated CURRENT at all.
    context.runId = "guid-normal-four-arbitrary-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function EIGHTHFU.assertNormalFourArbitraryNamesScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "htdemucs with four arbitrary names proved worker health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+missing_required_stems") ~= nil,
        "arbitrary Normal output names were not labeled missing_required_stems:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok from Normal-flow arbitrary output names:\n" .. manifest)
end

-- Recognized 4-stem model (htdemucs) WITH the canonical four output names:
-- must still prove health (no false negative from the new name-set gate).
function EIGHTHFU.createNormalCanonicalFourNamesScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "normal-canonical-four-names-accepted"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    -- RunContext authority hardening migration: structured identity is
    -- required for this run to be evaluated CURRENT at all.
    context.runId = "guid-normal-canonical-four-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function EIGHTHFU.assertNormalCanonicalFourNamesScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") ~= nil,
        "htdemucs with the canonical four output names did not prove worker health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_run:%s+" .. context.workerRunName) ~= nil,
        "the proving worker run was not identified by its exact run ID:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") ~= nil,
        "canonical Normal-flow output names did not prove final_runtime_health=ok:\n" .. manifest)
end

-- Recognized 6-Stem model (htdemucs_6s) but six ARBITRARY output names:
-- matching count must never substitute for the canonical stem name set.
function EIGHTHFU.createSixStemArbitraryNamesScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "six-stem-six-arbitrary-names-rejected"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, {
        {
            name = "single",
            exit = 0,
            done = true,
            model = "htdemucs_6s",
            outputCount = 6,
            outputNames = "alpha,bravo,charlie,delta,echo,foxtrot",
            validation = "ok",
        },
    })
    -- RunContext authority hardening migration: structured identity is
    -- required for this run to be evaluated CURRENT at all.
    context.runId = "guid-six-stem-arbitrary-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function EIGHTHFU.assertSixStemArbitraryNamesScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "htdemucs_6s with six arbitrary names proved worker health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+missing_required_stems") ~= nil,
        "arbitrary 6-Stem output names were not labeled missing_required_stems:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok from 6-Stem arbitrary output names:\n" .. manifest)
end

-- Recognized 6-Stem model (htdemucs_6s) WITH the canonical six output
-- names: must still prove health (no false negative from the new gate).
function EIGHTHFU.createSixStemCanonicalNamesScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "six-stem-canonical-six-names-accepted"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, {
        {
            name = "single",
            exit = 0,
            done = true,
            model = "htdemucs_6s",
            outputCount = 6,
            outputNames = "vocals,drums,bass,other,guitar,piano",
            validation = "ok",
        },
    })
    -- RunContext authority hardening migration: structured identity is
    -- required for this run to be evaluated CURRENT at all.
    context.runId = "guid-six-stem-canonical-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function EIGHTHFU.assertSixStemCanonicalNamesScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") ~= nil,
        "htdemucs_6s with the canonical six output names did not prove worker health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_run:%s+" .. context.workerRunName) ~= nil,
        "the proving worker run was not identified by its exact run ID:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") ~= nil,
        "canonical 6-Stem output names did not prove final_runtime_health=ok:\n" .. manifest)
end

-- ---------------------------------------------------------------------
-- Eighth follow-up: worker/session currentness must require an EXPLICIT
-- shared session identity, not merely a timestamp inside the session
-- window. SHARED_SESSION_ID_CURRENTLY_PERSISTED=no was found by searching
-- every production evidence writer (timing_events.jsonl/phase_events.jsonl/
-- separation_log.txt/stdout.txt across STEMwerk.lua, STEMwerk_Workflow.lua
-- and audio_separator_process.py): none of them ever emit a SESSION_ID (or
-- equivalent) into per-run job evidence, so there is no genuine positive
-- "matching shared session ID" fixture to add (see MATCHING_SESSION_ID
-- note below). What CAN be closed truthfully: if a job's own evidence
-- ever DOES carry an explicit session identity marker that conflicts with
-- session.env's SESSION_ID, that conflict must be honored over the
-- timestamp window.
-- ---------------------------------------------------------------------
function EIGHTHFU.createSessionIdMismatchScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "mismatched-session-id-remains-unlinked"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    local evidenceRoot = joinPath(context.extState.runtimeBase, "evidence", "current-session")
    mkdirP(evidenceRoot)
    writeFile(joinPath(evidenceRoot, "session.env"), table.concat({
        "EVIDENCE_SCHEMA=1",
        "SESSION_ID=SESSION_A",
        "SESSION_STARTED_UTC=" .. os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 2),
        "",
    }, "\n"))
    context.workerRunName = currentWorkerRunName()
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    writeFile(joinPath(jobDir, "done.txt"), "DONE\n")
    -- The run's own evidence names a DIFFERENT session id than session.env
    -- -- a genuine identity conflict, never a value to invent.
    writeFile(joinPath(jobDir, "phase_events.jsonl"),
        '{"time":' .. tostring(os.time())
        .. ',"model":"htdemucs","device":"cpu","result":"success","output_count":4,'
        .. '"output_names":"bass,drums,other,vocals","output_validation_reason":"ok","session_id":"SESSION_B"}\n')
    writeFile(joinPath(jobDir, "timing_events.jsonl"),
        '{"time":' .. tostring(os.time()) .. ',"event":"done_seen","job_index":"single","job_dir":"/tmp/'
        .. context.workerRunName .. '"}\n')
    return context
end

function EIGHTHFU.assertSessionIdMismatchScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a run whose own session_id conflicts with session.env's SESSION_ID proved CURRENT worker health:\n" .. manifest)
    assertf(manifest:find("worker_context_identity:%s+current_session") == nil,
        "a session_id-mismatched run was classified current_session:\n" .. manifest)
    assertf(manifest:find("worker_context_identity:%s+recent_unlinked") ~= nil,
        "a session_id-mismatched run was not classified recent_unlinked:\n" .. manifest)
    assertf(manifest:find("recent_worker_health:%s+ok") ~= nil,
        "the mismatched run's success was not still surfaced as recent provenance:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok from a session_id-mismatched run:\n" .. manifest)
end


-- ---------------------------------------------------------------------
-- RunContext / structured-identity fixtures (2.3.1.0 explicit run/job
-- identity plumbing). Mirrors the exact evidence shape the real Lua/Python
-- writers now produce: worker_context.json in each job's own directory,
-- and one current_processing/<run_id>.json state record per run_id.
-- ---------------------------------------------------------------------

function EIGHTHFU.writeWorkerContextFile(context, runName, jobName, runId, jobId)
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", runName, jobName)
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "worker_context.json"), table.concat({
        "{",
        '  "schema": 1,',
        '  "run_id": "' .. tostring(runId) .. '",',
        '  "job_id": "' .. tostring(jobId) .. '",',
        '  "run_dir_name": "' .. tostring(runName) .. '",',
        '  "started_utc": "2026-07-24T13:00:00Z"',
        "}",
        "",
    }, "\n"))
end

-- started_utc/updated_utc are always "now": the RunContext authority
-- hardening requires the SELECTED current-processing record to itself be
-- fresh (section 11 -- a stale record can never anchor current identity,
-- even if otherwise perfectly well-formed), so every fixture that wants
-- its structured evidence to actually prove/evaluate as current must get
-- a fresh timestamp here. Fixtures that specifically want a STALE record
-- (see EIGHTHFU.writeStaleCurrentProcessingRecord below) use a separate
-- helper rather than overloading this one's default.
function EIGHTHFU.writeCurrentProcessingRecord(context, runId, status, runDirName)
    local dir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "current_processing")
    mkdirP(dir)
    local nowIso = os.date("!%Y-%m-%dT%H:%M:%SZ")
    writeFile(joinPath(dir, tostring(runId) .. ".json"), table.concat({
        "{",
        '  "schema": 1,',
        '  "run_id": "' .. tostring(runId) .. '",',
        '  "run_dir_name": "' .. tostring(runDirName or runId) .. '",',
        '  "started_utc": "' .. nowIso .. '",',
        '  "status": "' .. tostring(status) .. '",',
        '  "updated_utc": "' .. nowIso .. '"',
        "}",
        "",
    }, "\n"))
end

-- Writes a current_processing record whose started_utc/updated_utc are
-- deliberately OLD (outside CURRENT_WORKER_CONTEXT_WINDOW_SECONDS), for
-- the stale-completed-state fixture: a structurally well-formed, valid,
-- filename/run_dir-bound, completed record that must still be rejected
-- from selection purely for being stale (section 11 -- timestamps only
-- ever reject stale identity, they never grant it, but a record that is
-- itself too old to anchor current identity must not be selectable at
-- all).
function EIGHTHFU.writeStaleCurrentProcessingRecord(context, runId, status, runDirName)
    local dir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "current_processing")
    mkdirP(dir)
    local staleIso = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - 7200)
    writeFile(joinPath(dir, tostring(runId) .. ".json"), table.concat({
        "{",
        '  "schema": 1,',
        '  "run_id": "' .. tostring(runId) .. '",',
        '  "run_dir_name": "' .. tostring(runDirName or runId) .. '",',
        '  "started_utc": "' .. staleIso .. '",',
        '  "status": "' .. tostring(status) .. '",',
        '  "updated_utc": "' .. staleIso .. '"',
        "}",
        "",
    }, "\n"))
end

-- ---------------------------------------------------------------------
-- RunContext structured-identity scenarios (2.3.1.0 explicit run/job
-- identity plumbing). These exercise deriveCurrentWorkerRunHealth's new
-- structured-identity channel (worker_context.json + current_processing
-- records) independently of, and in combination with, the pre-existing
-- session-timestamp channel.
-- ---------------------------------------------------------------------

-- 16.1: current_processing.run_id=RUN_A + a successful persisted run whose
-- own worker_context.json names RUN_A -- proves current health via
-- structured identity ALONE (deliberately no session.env / acceptance
-- evidence at all).
function EIGHTHFU.createStructuredIdentityCurrentScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "structured-identity-proves-current"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    local runId = "guid-run-a-" .. tostring(os.time())
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, runId, "completed", context.workerRunName)
    return context
end

function EIGHTHFU.assertStructuredIdentityCurrentScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") ~= nil,
        "structured run_id identity (no session.env at all) did not prove current worker health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_run:%s+" .. context.workerRunName) ~= nil,
        "current worker health did not point at the structurally-identified run:\n" .. manifest)
    assertf(manifest:find("worker_context_identity:%s+current_processing") ~= nil,
        "structured-identity current run was not classified current_processing:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") ~= nil,
        "final_runtime_health did not become ok from structured-identity worker evidence:\n" .. manifest)
end

-- 16.2 / test I: structured identity beats BOTH directions of timestamp
-- ordering. RUN_A is the OLDER directory but its own worker_context.json
-- matches current_processing -- it must become current despite being
-- older. RUN_B is a NEWER directory that ALSO satisfies the legacy
-- session-timestamp window (would win under timestamp-only logic), but
-- its own worker_context.json names a run_id current_processing does NOT
-- know about (e.g. a directory copied/renamed to look newer) -- it must
-- be rejected from current status even though it is newer and
-- session-linked, and surfaces only as recent-unlinked provenance.
function EIGHTHFU.createStructuredIdentityBeatsTimestampScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "structured-identity-beats-timestamp-ordering"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context, 2)
    local runIdA = "guid-run-a-older-" .. tostring(os.time())
    context.runNameA = "STEMwerk_" .. tostring(os.time() - 500) .. "_001_1"
    writeCurrentWorkerRun(context, context.runNameA, { successfulWorkerJob("single") })
    EIGHTHFU.writeWorkerContextFile(context, context.runNameA, "single", runIdA, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, runIdA, "completed", context.runNameA)

    waitNextSecond()
    context.runNameB = "STEMwerk_" .. tostring(os.time()) .. "_002_1"
    writeCurrentWorkerRun(context, context.runNameB, { successfulWorkerJob("single") })
    -- Names a run_id current_processing has never heard of: a copied /
    -- renamed directory pretending to be newer, not the genuine RUN_A.
    EIGHTHFU.writeWorkerContextFile(context, context.runNameB, "single", "guid-run-b-unrelated", "single")
    return context
end

function EIGHTHFU.assertStructuredIdentityBeatsTimestampScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") ~= nil,
        "the OLDER structurally-identified run did not prove current worker health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_run:%s+" .. context.runNameA) ~= nil,
        "current worker health pointed at the newer, structurally-unrelated directory instead of the genuine structurally-identified run:\n" .. manifest)
    assertf(manifest:find("worker_context_identity:%s+current_processing") ~= nil,
        "the structurally-identified run was not classified current_processing:\n" .. manifest)
    assertf(manifest:find(context.runNameB, 1, true) == nil or manifest:find("current_worker_health_run:%s+" .. context.runNameB) == nil,
        "a newer directory with a structured run_id current_processing does not know about became current merely by being newest/session-linked:\n" .. manifest)
end

-- Test G: two jobs in the SAME run directory. Job A's worker_context.json
-- matches current_processing; job B's worker_context.json names a
-- DIFFERENT run_id current_processing does not know about. Even though
-- the run is also session-linked under the legacy path, the mismatched
-- sibling job must veto current status for the run as a whole.
function EIGHTHFU.createMismatchedJobRunIdScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "mismatched-job-run-id-cannot-prove-current"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    writeCurrentSessionRoot(context)
    context.workerRunName = currentWorkerRunName()
    local runId = "guid-run-shared-" .. tostring(os.time())
    writeCurrentWorkerRun(context, context.workerRunName, {
        successfulWorkerJob("jobA"),
        successfulWorkerJob("jobB"),
    })
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "jobA", runId, "jobA")
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "jobB", "guid-run-different-" .. tostring(os.time()), "jobB")
    EIGHTHFU.writeCurrentProcessingRecord(context, runId, "running", context.workerRunName)
    return context
end

function EIGHTHFU.assertMismatchedJobRunIdScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a run with one job's structured run_id mismatched against current_processing still proved current health:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a mismatched sibling job's structured run_id:\n" .. manifest)
end

-- Test F: job A carries valid structured identity matching
-- current_processing and full success evidence; job B (same run) has NO
-- identity evidence of any kind and no output evidence. The run is
-- identifiable (via job A), but missing job identity/evidence on a
-- sibling must still block proving current worker health.
function EIGHTHFU.createMissingJobIdentityScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "missing-job-identity-cannot-prove-current"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    local runId = "guid-run-missing-sibling-" .. tostring(os.time())
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("jobA") })
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "jobA", runId, "jobA")
    EIGHTHFU.writeCurrentProcessingRecord(context, runId, "running", context.workerRunName)
    -- jobB: no worker_context.json, no timing/phase evidence, no exit
    -- code, no done marker -- a job that never reported anything at all.
    local jobBDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "jobB")
    mkdirP(jobBDir)
    return context
end

function EIGHTHFU.assertMissingJobIdentityScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a run with one evidence-less sibling job still proved current worker health:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a required job with no identity/output evidence at all:\n" .. manifest)
end

-- Test H: two DIFFERENT run directories both carry a job whose structured
-- worker_context.json claims the SAME run_id, and that run_id matches the
-- single current_processing record. This is a replayed/duplicated
-- identity file (or a run directory copied wholesale, worker_context.json
-- included) -- genuinely ambiguous, and must never be resolved by quietly
-- picking whichever directory happens to sort newest.
function EIGHTHFU.createReplayedContextScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "replayed-structured-context-cannot-prove-current"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    local sharedRunId = "guid-run-replayed-" .. tostring(os.time())
    context.runNameA = "STEMwerk_" .. tostring(os.time() - 50) .. "_001_1"
    writeCurrentWorkerRun(context, context.runNameA, { successfulWorkerJob("single") })
    EIGHTHFU.writeWorkerContextFile(context, context.runNameA, "single", sharedRunId, "single")

    waitNextSecond()
    context.runNameB = "STEMwerk_" .. tostring(os.time()) .. "_002_1"
    writeCurrentWorkerRun(context, context.runNameB, { successfulWorkerJob("single") })
    EIGHTHFU.writeWorkerContextFile(context, context.runNameB, "single", sharedRunId, "single")

    EIGHTHFU.writeCurrentProcessingRecord(context, sharedRunId, "completed", context.runNameB)
    return context
end

function EIGHTHFU.assertReplayedContextScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "the same run_id claimed by two distinct run directories still proved current worker health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+replayed_run_id_conflict") ~= nil,
        "a replayed/duplicated structured run_id across two directories was not labeled replayed_run_id_conflict:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a replayed structured run_id across two run directories:\n" .. manifest)
end

-- ---------------------------------------------------------------------
-- Ninth follow-up (release/2.3.1.0-final-prep): closes the disclosed gap
-- in the eighth follow-up's RunContext identity plumbing -- structured
-- identity is now the ONLY path that can prove current worker health.
-- These fixtures exercise the required behavioral cases from that
-- hardening's spec section 16 not already covered above: strict JSON
-- validation (malformed/truncated/wrong-schema), job_id authority
-- (missing/wrong/duplicate), current_processing strict validation and
-- filename/run_dir binding, single-selected-context semantics under
-- concurrency, and full lifecycle status gating (running/failed/
-- cancelled/stale-completed).
-- ---------------------------------------------------------------------
local NINTHFU = {}

-- #2: worker_context.json exists but is not valid JSON at all. Must never
-- authenticate -- this run has otherwise-complete marker/output evidence
-- and even a matching current_processing record, so the ONLY thing
-- standing between it and a false "ok" is strict JSON validation.
function NINTHFU.createMalformedWorkerContextScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "malformed-worker-context-json"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    context.runId = "guid-malformed-worker-context-" .. tostring(os.time())
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "worker_context.json"), 'this is not { valid json at all\n')
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function NINTHFU.assertMalformedWorkerContextScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a malformed worker_context.json (not valid JSON) authenticated current health:\n" .. manifest)
    assertf(manifest:find("worker_context_identity:%s+current_processing") == nil,
        "a malformed worker_context.json was classified current_processing:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a malformed worker_context.json:\n" .. manifest)
end

-- #3: worker_context.json is TRUNCATED mid-object, but the run_id value it
-- does contain is the exact string that WOULD match the selected
-- current_processing record if extracted via a loose substring pattern
-- (the same shape the loose parseJsonStringField helper elsewhere in this
-- file would happily accept). A parseable early "run_id" inside broken
-- JSON must not authenticate -- only the strict parser's rejection of the
-- whole (unterminated, no closing brace, no job_id/run_dir_name) object
-- stands between this and a false "ok".
function NINTHFU.createTruncatedWorkerContextScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "truncated-worker-context-with-run-id"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    context.runId = "guid-truncated-worker-context-" .. tostring(os.time())
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "worker_context.json"),
        '{\n  "schema": 1,\n  "run_id": "' .. context.runId .. '"')
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function NINTHFU.assertTruncatedWorkerContextScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a truncated worker_context.json with a matching-looking run_id authenticated current health:\n" .. manifest)
    assertf(manifest:find("worker_context_identity:%s+current_processing") == nil,
        "a truncated worker_context.json was classified current_processing:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a truncated worker_context.json:\n" .. manifest)
end

-- #4: worker_context.json is complete, well-formed JSON with every
-- required field present -- but names an unsupported schema value. Must
-- be rejected exactly like a missing file, never read leniently.
function NINTHFU.createWrongSchemaWorkerContextScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "wrong-worker-context-schema"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    context.runId = "guid-wrong-schema-" .. tostring(os.time())
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "worker_context.json"), table.concat({
        "{",
        '  "schema": 2,',
        '  "run_id": "' .. context.runId .. '",',
        '  "job_id": "single",',
        '  "run_dir_name": "' .. context.workerRunName .. '"',
        "}",
        "",
    }, "\n"))
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function NINTHFU.assertWrongSchemaWorkerContextScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "an unsupported worker_context.json schema value authenticated current health:\n" .. manifest)
    assertf(manifest:find("worker_context_identity:%s+current_processing") == nil,
        "an unsupported worker_context.json schema was classified current_processing:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite an unsupported worker_context.json schema:\n" .. manifest)
end

-- #5: worker_context.json is otherwise well-formed and complete except
-- job_id is entirely absent -- must never fall back to treating the job
-- as anonymously/informally identified.
function NINTHFU.createMissingJobIdScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "missing-job-id"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    context.runId = "guid-missing-job-id-" .. tostring(os.time())
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "worker_context.json"), table.concat({
        "{",
        '  "schema": 1,',
        '  "run_id": "' .. context.runId .. '",',
        '  "run_dir_name": "' .. context.workerRunName .. '"',
        "}",
        "",
    }, "\n"))
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function NINTHFU.assertMissingJobIdScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a worker_context.json missing job_id entirely authenticated current health:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite worker_context.json missing job_id:\n" .. manifest)
end

-- #6: worker_context.json is complete and its run_id matches the selected
-- current-processing record, but job_id names a DIFFERENT job than the
-- one it actually lives in. structuredJobId must be authoritative, not
-- informational.
function NINTHFU.createWrongJobIdScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "wrong-job-id"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    context.runId = "guid-wrong-job-id-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "not-single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function NINTHFU.assertWrongJobIdScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a wrong job_id in worker_context.json authenticated current health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+job_identity_mismatch") ~= nil,
        "a wrong job_id was not labeled job_identity_mismatch:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a wrong job_id in worker_context.json:\n" .. manifest)
end

-- #7: two sibling jobs in the same run both carry a worker_context.json
-- claiming the SAME job_id (one copied onto the other). Even the job whose
-- own directory name happens to match the shared value can never be
-- trusted here -- a duplicated job_id is ambiguous for the run as a whole.
function NINTHFU.createDuplicateJobIdScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "duplicate-job-id"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, {
        successfulWorkerJob("jobA"),
        successfulWorkerJob("jobB"),
    })
    context.runId = "guid-duplicate-job-id-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "jobA", context.runId, "jobA")
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "jobB", context.runId, "jobA")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function NINTHFU.assertDuplicateJobIdScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a job_id duplicated across sibling jobs authenticated current health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+job_identity_conflicting") ~= nil,
        "a duplicated job_id was not labeled job_identity_conflicting:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a job_id duplicated across sibling jobs:\n" .. manifest)
end

-- #12: current_processing/<run_id>.json exists but is not valid JSON.
-- Must be skipped entirely, never guessed at -- even though the job's own
-- worker_context.json is perfectly valid and would otherwise prove health.
function NINTHFU.createMalformedCurrentStateScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "malformed-current-state-json"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    context.runId = "guid-malformed-current-state-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    local dir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "current_processing")
    mkdirP(dir)
    writeFile(joinPath(dir, context.runId .. ".json"), 'not { valid json\n')
    return context
end

function NINTHFU.assertMalformedCurrentStateScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a malformed current_processing state file authenticated current health:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a malformed current_processing state file:\n" .. manifest)
end

-- #13: current_processing/<run_id>.json is truncated mid-object, but does
-- contain the correct run_id string -- a reader relying on substring
-- extraction rather than strict parsing could still accept it.
function NINTHFU.createTruncatedCurrentStateScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "truncated-current-state-with-run-id"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    context.runId = "guid-truncated-current-state-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    local dir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "current_processing")
    mkdirP(dir)
    writeFile(joinPath(dir, context.runId .. ".json"),
        '{\n  "schema": 1,\n  "run_id": "' .. context.runId .. '"')
    return context
end

function NINTHFU.assertTruncatedCurrentStateScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a truncated current_processing state file with a real run_id authenticated current health:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a truncated current_processing state file:\n" .. manifest)
end

-- #14: current_processing/<run_id>.json's FILENAME names one run_id, but
-- its own JSON run_id field names a different one. The worker_context.json
-- for the job even claims the run_id inside the JSON body, which would
-- match if filename binding were not enforced.
function NINTHFU.createStateFilenameMismatchScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "state-filename-run-id-mismatch"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    local filenameRunId = "guid-filename-run-id-" .. tostring(os.time())
    local bodyRunId = "guid-body-run-id-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", bodyRunId, "single")
    local dir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "current_processing")
    mkdirP(dir)
    writeFile(joinPath(dir, filenameRunId .. ".json"), table.concat({
        "{",
        '  "schema": 1,',
        '  "run_id": "' .. bodyRunId .. '",',
        '  "run_dir_name": "' .. context.workerRunName .. '",',
        '  "status": "completed"',
        "}",
        "",
    }, "\n"))
    return context
end

function NINTHFU.assertStateFilenameMismatchScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a current_processing filename/run_id mismatch authenticated current health:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a current_processing filename/run_id mismatch:\n" .. manifest)
end

-- #15: current_processing/<run_id>.json is otherwise valid and filename-
-- bound, but its run_dir_name names a directory that was never actually
-- persisted.
function NINTHFU.createStateRunDirMismatchScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "state-run-dir-mismatch"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    context.runId = "guid-run-dir-mismatch-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", "STEMwerk_never_persisted_directory")
    return context
end

function NINTHFU.assertStateRunDirMismatchScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a current_processing run_dir_name pointing at a non-persisted directory authenticated current health:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a current_processing run_dir_name mismatch:\n" .. manifest)
end

-- #16: a fully valid, fully successful run whose SELECTED current-
-- processing record's status is "running". Running can never prove final
-- (ok) worker health, even with otherwise complete success evidence.
function NINTHFU.createCurrentStateRunningScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "current-state-running"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    context.runId = "guid-current-state-running-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "running", context.workerRunName)
    return context
end

function NINTHFU.assertCurrentStateRunningScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a selected current-processing record with status=running proved current_worker_health=ok:\n" .. manifest)
    assertf(manifest:find("current_worker_health_run:%s+" .. context.workerRunName) ~= nil,
        "the running run was not the one structurally selected/evaluated:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+current_processing_state_running") ~= nil,
        "a running current-processing state was not labeled current_processing_state_running:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a running current-processing state:\n" .. manifest)
end

-- #18: a fully valid run with fully successful job evidence, but the
-- SELECTED current-processing record's status is "failed". This is
-- exactly the case the hardening spec calls out explicitly: a failed
-- processing state plus successful stale job evidence must never read as
-- OK -- the writer's own explicit failure verdict wins.
function NINTHFU.createCurrentStateFailedScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "current-state-failed"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    context.runId = "guid-current-state-failed-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "failed", context.workerRunName)
    return context
end

function NINTHFU.assertCurrentStateFailedScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+failed") ~= nil,
        "a selected current-processing record with status=failed did not force current_worker_health=failed:\n" .. manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "successful stale job evidence overrode an explicit failed current-processing state:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+current_processing_state_failed") ~= nil,
        "a failed current-processing state was not labeled current_processing_state_failed:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a failed current-processing state:\n" .. manifest)
end

-- #19: same as #18 but status="cancelled" -- also a current failure, never
-- a success, regardless of job evidence.
function NINTHFU.createCurrentStateCancelledScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "current-state-cancelled"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    context.runId = "guid-current-state-cancelled-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "cancelled", context.workerRunName)
    return context
end

function NINTHFU.assertCurrentStateCancelledScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+failed") ~= nil,
        "a selected current-processing record with status=cancelled did not force current_worker_health=failed:\n" .. manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "successful stale job evidence overrode an explicit cancelled current-processing state:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+current_processing_state_cancelled") ~= nil,
        "a cancelled current-processing state was not labeled current_processing_state_cancelled:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a cancelled current-processing state:\n" .. manifest)
end

-- #20: a structurally valid, filename/run_dir-bound, "completed" current-
-- processing record whose OWN started/updated timestamps are stale (well
-- outside CURRENT_WORKER_CONTEXT_WINDOW_SECONDS). A retained completed
-- state must not authenticate indefinitely -- timestamps only ever reject
-- stale identity here, they never grant it, but a too-old record must not
-- even be selectable.
function NINTHFU.createStaleCompletedStateScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "stale-completed-state"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    context.runId = "guid-stale-completed-state-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeStaleCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function NINTHFU.assertStaleCompletedStateScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a stale (2h-old) completed current-processing record authenticated current health:\n" .. manifest)
    assertf(manifest:find("worker_context_identity:%s+current_processing") == nil,
        "a stale current-processing record was still classified current_processing:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a stale completed current-processing record:\n" .. manifest)
end

-- #9/#22: two independent, fully valid, fully healthy runs (RUN_A, RUN_B),
-- each with its own worker_context.json and its own current_processing
-- record. Only the newer one (RUN_A) is selected as current; RUN_B's jobs
-- must never be merged into it, and RUN_B is surfaced only as recent
-- provenance, never current.
function NINTHFU.createTwoConcurrentValidRunsScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "two-concurrent-valid-runs-no-cross-merge"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.runNameB = "STEMwerk_" .. tostring(os.time() - 5) .. "_001_1"
    writeCurrentWorkerRun(context, context.runNameB, { successfulWorkerJob("single") })
    local runIdB = "guid-concurrent-run-b-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.runNameB, "single", runIdB, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, runIdB, "completed", context.runNameB)

    waitNextSecond()
    context.workerRunName = "STEMwerk_" .. tostring(os.time()) .. "_002_1"
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    context.runId = "guid-concurrent-run-a-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function NINTHFU.assertTwoConcurrentValidRunsScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") ~= nil,
        "the newer of two independently-valid concurrent runs did not prove current health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_run:%s+" .. context.workerRunName) ~= nil,
        "the newer concurrent run was not the one selected as current:\n" .. manifest)
    assertf(manifest:find(context.runNameB, 1, true) == nil or manifest:find("current_worker_health_run:%s+" .. context.runNameB) == nil,
        "the older concurrent run's jobs were merged into (or replaced) the current verdict:\n" .. manifest)
    assertf(manifest:find("recent_worker_health:%s+ok") ~= nil,
        "the older concurrent run's own success was not surfaced as recent provenance:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") ~= nil,
        "final_runtime_health did not become ok from the correctly-selected newer concurrent run:\n" .. manifest)
end

-- #10: selected RUN_A is successful; a SEPARATE, independently successful
-- RUN_B also has a valid current_processing record, but RUN_A's own
-- (older) record is nonetheless the one selected here because RUN_B's
-- record is deliberately made the NON-newest. RUN_B must never be used to
-- prove or supplement RUN_A's health.
function NINTHFU.createSelectedRunASuccessfulRunBScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "selected-run-a-successful-run-b-cannot-prove-current"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = "STEMwerk_" .. tostring(os.time()) .. "_001_1"
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    context.runId = "guid-selected-run-a-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)

    waitNextSecond()
    context.runNameB = "STEMwerk_" .. tostring(os.time()) .. "_002_1"
    writeCurrentWorkerRun(context, context.runNameB, { successfulWorkerJob("single") })
    local runIdB = "guid-not-selected-run-b-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.runNameB, "single", runIdB, "single")
    -- RUN_B's own state record is deliberately NOT written, so RUN_A (the
    -- only valid current-processing record) remains the sole selectable
    -- context even though RUN_B is the newer directory and is itself
    -- fully successful.
    return context
end

function NINTHFU.assertSelectedRunASuccessfulRunBScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") ~= nil,
        "selected RUN_A did not prove current_worker_health=ok:\n" .. manifest)
    assertf(manifest:find("current_worker_health_run:%s+" .. context.workerRunName) ~= nil,
        "RUN_A was not the run structurally selected/evaluated:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") ~= nil,
        "final_runtime_health did not become ok from the correctly-selected RUN_A:\n" .. manifest)
end

-- #11: selected RUN_A has INCOMPLETE job evidence (unproven); a separate
-- RUN_B is fully healthy and has its own valid current_processing record,
-- but RUN_A remains selected (its own record is the one this cycle
-- resolves) -- current health must reflect RUN_A's incompleteness, never
-- silently fall back to RUN_B's success.
function NINTHFU.createSelectedRunAIncompleteRunBScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "selected-run-a-incomplete-successful-run-b-no-fallback"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = "STEMwerk_" .. tostring(os.time()) .. "_001_1"
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "exit_code.txt"), "0\n")
    writeFile(joinPath(jobDir, "done.txt"), "DONE\n")
    -- Identified and complete, but no output evidence at all: unproven.
    writeFile(joinPath(jobDir, "timing_events.jsonl"),
        '{"time":' .. tostring(os.time()) .. ',"event":"done_seen","job_index":"single","job_dir":"/tmp/' .. context.workerRunName .. '"}\n')
    context.runId = "guid-selected-run-a-incomplete-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)

    waitNextSecond()
    context.runNameB = "STEMwerk_" .. tostring(os.time()) .. "_002_1"
    writeCurrentWorkerRun(context, context.runNameB, { successfulWorkerJob("single") })
    local runIdB = "guid-run-b-not-selected-" .. tostring(os.time())
    EIGHTHFU.writeWorkerContextFile(context, context.runNameB, "single", runIdB, "single")
    -- RUN_B has no current_processing record of its own, so it can never
    -- be selected in place of RUN_A this cycle.
    return context
end

function NINTHFU.assertSelectedRunAIncompleteRunBScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "an incomplete selected RUN_A fell back to a separate healthy RUN_B's success:\n" .. manifest)
    assertf(manifest:find("current_worker_health_run:%s+" .. context.workerRunName) ~= nil,
        "the incomplete selected RUN_A was not the one evaluated:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+unrecognized_model_contract") ~= nil,
        "RUN_A's own incompleteness reason was not reported:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite RUN_A being incomplete:\n" .. manifest)
end

-- ---------------------------------------------------------------------
-- RunContext authority hardening (2.3.1.0 follow-up): closes remaining
-- structured-identity bypasses left after the previous ten commits on
-- this branch -- mandatory per-job worker_context, helper-only identity
-- can never substitute for a missing worker_context, a full (not
-- flat-only) strict JSON decoder for identity files, and the DrumSep
-- helper's REAL per-flow result path/shape (Direct Kit: top-level
-- <job dir>/drumsep_result.json with a nested payload; Kit Split: the
-- same nested payload under <job dir>/stage2_drumsep/).
-- ---------------------------------------------------------------------
local TENTHFU = {}

-- Real DrumSep helper drumsep_result.json success payload, in the ACTUAL
-- shape write_result() in stemwerk_drumsep_process.py produces: run_id/
-- job_id are flat top-level strings, but the rest of the document is NOT
-- flat -- a nested "stems" object and several nested arrays. Used for both
-- Direct Kit (top-level path) and Kit Split (stage2_drumsep path) fixtures
-- since both flows share the exact same writer.
local function realDrumsepResultJson(runId, jobId, outputDir)
    return table.concat({
        "{",
        '  "ok": true,',
        '  "run_id": "' .. runId .. '",',
        '  "job_id": "' .. jobId .. '",',
        '  "stems": {',
        '    "kick": "' .. outputDir .. '/kick.wav",',
        '    "snare": "' .. outputDir .. '/snare.wav"',
        "  },",
        '  "raw_outputs": ["' .. outputDir .. '/kick.wav", "' .. outputDir .. '/snare.wav"],',
        '  "expected_drum_outputs": 6,',
        '  "actual_drum_outputs": 6,',
        '  "output_count_mismatch": false,',
        '  "expected_stems": ["kick", "snare", "toms", "hihat", "ride", "crash"],',
        '  "found_stems": ["kick", "snare", "toms", "hihat", "ride", "crash"],',
        '  "output_validation_reason": "ok",',
        '  "separator_onnx_provider": [],',
        '  "direct_demix_keys": []',
        "}",
        "",
    }, "\n")
end

-- #1 (section 1): job A carries a valid, matching worker_context.json and
-- complete legacy success evidence; job B carries EQUALLY complete legacy
-- success evidence (exit 0, done, real htdemucs 4-stem names, validation
-- ok) but has NO worker_context.json at all. Before this hardening, job
-- B's lack of structured identity was invisible to the run-level success
-- computation (classifyWorkerJob only caught structured evidence that
-- EXISTED but was broken, never evidence that was simply absent), so job A
-- alone authenticating the run let job B ride along to "success" on
-- legacy markers. Now every job contributing to a structurally-current run
-- must itself carry valid worker_context identity.
function TENTHFU.createStructuredSiblingPlusLegacyJobScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "structured-job-plus-legacy-sibling-rejected"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, {
        successfulWorkerJob("a"),
        successfulWorkerJob("b"),
    })
    context.runId = "guid-structured-plus-legacy-" .. tostring(os.time())
    -- Only job "a" gets worker_context.json; job "b" is deliberately left
    -- with legacy evidence only.
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "a", context.runId, "a")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function TENTHFU.assertStructuredSiblingPlusLegacyJobScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a required sibling job with no worker_context.json still let the run prove current health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_run:%s+" .. context.workerRunName) ~= nil,
        "the run was not evaluated as the structurally-selected current run at all:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+job_identity_missing") ~= nil,
        "the missing-worker_context sibling job's reason was not surfaced as job_identity_missing:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a required sibling job missing worker_context.json:\n" .. manifest)
end

-- #2 (section 2): a job has NO worker_context.json at all, but DOES carry
-- a strictly valid, matching DrumSep helper identity (drumsep_result.json
-- with a matching run_id/job_id). Helper evidence may only ever
-- CORROBORATE an already-valid worker_context -- it can never substitute
-- for a missing one.
--
-- Deliberately: (a) a FLAT (not nested) helper payload, so this fixture's
-- rejection can only come from refusing to let helper-only identity
-- substitute for a missing worker_context (section 2/10), never from an
-- unrelated full-JSON-decoder parse failure (section 3) -- the real nested
-- payload shape is separately exercised, and required to SUCCEED, by the
-- Direct Kit / Kit Split real-helper fixtures below; and (b) Kit Split
-- (dks_extract) as the source, with the helper result placed at
-- stage2_drumsep/drumsep_result.json -- the one helper-result location
-- that was ALREADY being read correctly before this hardening (unlike
-- Direct Kit's top-level path, fixed separately by this same commit), so
-- this fixture's rejection can only come from the merge-rule fix, never
-- from an unrelated path-lookup fix.
function TENTHFU.createHelperOnlyIdentityScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "helper-only-identity-rejected"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = "dks_extract",
        found = "kick,snare,toms,hihat,ride,crash",
        validation = "ok",
    })
    context.runId = "guid-helper-only-" .. tostring(os.time())
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "single")
    local stage2Dir = joinPath(jobDir, "stage2_drumsep")
    mkdirP(stage2Dir)
    -- Helper identity ONLY -- deliberately no worker_context.json.
    writeFile(joinPath(stage2Dir, "drumsep_result.json"), table.concat({
        "{",
        '  "run_id": "' .. context.runId .. '",',
        '  "job_id": "single"',
        "}",
        "",
    }, "\n"))
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function TENTHFU.assertHelperOnlyIdentityScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "helper-only identity (no worker_context.json) authenticated current health:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok from helper-only identity with no worker_context.json:\n" .. manifest)
end

-- #3 (section 3): worker_context.json is well-formed EXCEPT the "run_id"
-- key appears twice with the IDENTICAL value both times. The previous flat
-- parser only rejected a repeated key when its two values actually
-- disagreed, silently accepting an exact duplicate -- the strict decoder
-- must reject ANY duplicate key at any level, regardless of whether the
-- values agree.
function TENTHFU.createDuplicateJsonKeyScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "duplicate-identical-json-key-rejected"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    context.runId = "guid-duplicate-key-" .. tostring(os.time())
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "worker_context.json"), table.concat({
        "{",
        '  "schema": 1,',
        '  "run_id": "' .. context.runId .. '",',
        '  "run_id": "' .. context.runId .. '",',
        '  "job_id": "single",',
        '  "run_dir_name": "' .. context.workerRunName .. '"',
        "}",
        "",
    }, "\n"))
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function TENTHFU.assertDuplicateJsonKeyScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a worker_context.json with a duplicate (even identical-value) JSON key authenticated current health:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a duplicate-key worker_context.json:\n" .. manifest)
end

-- #4 (section 3): worker_context.json contains a raw, unescaped control
-- character (a literal TAB byte, 0x09) inside the run_id string value.
-- Must be rejected outright rather than passed through as a literal
-- character. Only worker_context.json's OWN run_id value carries the raw
-- control character; the selected current_processing record (filename and
-- body) uses the clean run_id throughout, so the two can never coincide by
-- a lenient reader trimming/matching them into agreement -- the only way
-- this fixture can be rejected is the control-character check itself
-- rejecting worker_context.json outright (structuredContextInvalid).
function TENTHFU.createControlCharacterJsonScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "invalid-control-character-json-rejected"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeCurrentWorkerRun(context, context.workerRunName, { successfulWorkerJob("single") })
    context.runId = "guid-control-char-" .. tostring(os.time())
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "single")
    mkdirP(jobDir)
    writeFile(joinPath(jobDir, "worker_context.json"), table.concat({
        "{",
        '  "schema": 1,',
        '  "run_id": "' .. context.runId .. "\t" .. '",',
        '  "job_id": "single",',
        '  "run_dir_name": "' .. context.workerRunName .. '"',
        "}",
        "",
    }, "\n"))
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function TENTHFU.assertControlCharacterJsonScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a worker_context.json with a raw unescaped control character authenticated current health:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a worker_context.json with a raw unescaped control character:\n" .. manifest)
end

-- #5/#6 (sections 8/10): Direct Kit's REAL top-level drumsep_result.json
-- (no stage2_drumsep subdirectory), with valid worker_context.json,
-- matching helper identity -- corroborated, must prove current health.
function TENTHFU.createDirectKitRealHelperSuccessScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "direct-kit-real-top-level-helper-success"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = "dks_direct",
        found = "kick,snare,toms,hihat,ride,crash",
        validation = "ok",
    })
    context.runId = "guid-direct-kit-real-helper-" .. tostring(os.time())
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "single")
    mkdirP(jobDir)
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    -- Direct Kit's real result path: <job dir>/drumsep_result.json, NO
    -- stage2_drumsep subdirectory (see audio_separator_process.py's
    -- _is_direct_dks_source branch, which runs the helper directly
    -- against output_root).
    writeFile(joinPath(jobDir, "drumsep_result.json"),
        realDrumsepResultJson(context.runId, "single", jobDir))
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function TENTHFU.assertDirectKitRealHelperSuccessScenario(bundleDir, context)
    assertWorkerProvenZeroPhases(readManifest(bundleDir), context)
end

-- Direct Kit's real top-level drumsep_result.json names a DIFFERENT run_id
-- than the job's own valid worker_context.json -- a genuine conflict, must
-- reject current health rather than either source "winning".
function TENTHFU.createDirectKitRealHelperConflictScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "direct-kit-real-top-level-helper-conflict"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = "dks_direct",
        found = "kick,snare,toms,hihat,ride,crash",
        validation = "ok",
    })
    context.runId = "guid-direct-kit-conflict-" .. tostring(os.time())
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "single")
    mkdirP(jobDir)
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    writeFile(joinPath(jobDir, "drumsep_result.json"),
        realDrumsepResultJson("guid-different-run-" .. tostring(os.time()), "single", jobDir))
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function TENTHFU.assertDirectKitRealHelperConflictScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "Direct Kit's top-level drumsep_result.json conflicting with worker_context.json still proved current health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+job_identity_conflicting") ~= nil,
        "a conflicting Direct Kit top-level helper identity was not labeled job_identity_conflicting:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a conflicting Direct Kit top-level helper identity:\n" .. manifest)
end

-- #7/#8 (sections 9/10): Kit Split's REAL nested drumsep_result.json under
-- stage2_drumsep/, with valid worker_context.json, matching helper
-- identity -- corroborated, must prove current health. This also serves
-- as the "nested JSON parses successfully" proof: the full decoder must
-- accept the real nested "stems" object and array fields, not just flat
-- documents.
function TENTHFU.createKitSplitRealNestedHelperSuccessScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "kit-split-real-nested-helper-success"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = "dks_extract",
        found = "kick,snare,toms,hihat,ride,crash",
        validation = "ok",
    })
    context.runId = "guid-kit-split-real-helper-" .. tostring(os.time())
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "single")
    local stage2Dir = joinPath(jobDir, "stage2_drumsep")
    mkdirP(stage2Dir)
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    -- Kit Split's real result path: <job dir>/stage2_drumsep/drumsep_result.json
    -- (see audio_separator_process.py's _is_extract_dks_source branch,
    -- which runs the helper against stage2_root = output_root/"stage2_drumsep").
    writeFile(joinPath(stage2Dir, "drumsep_result.json"),
        realDrumsepResultJson(context.runId, "single", stage2Dir))
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function TENTHFU.assertKitSplitRealNestedHelperSuccessScenario(bundleDir, context)
    assertWorkerProvenZeroPhases(readManifest(bundleDir), context)
end

-- Kit Split's real nested drumsep_result.json names a DIFFERENT job_id
-- than the job's own valid worker_context.json.
function TENTHFU.createKitSplitRealNestedHelperConflictScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "kit-split-real-nested-helper-conflict"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    writeRealDrumkitJob(context, context.workerRunName, "single", {
        source = "dks_extract",
        found = "kick,snare,toms,hihat,ride,crash",
        validation = "ok",
    })
    context.runId = "guid-kit-split-conflict-" .. tostring(os.time())
    local jobDir = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.workerRunName, "single")
    local stage2Dir = joinPath(jobDir, "stage2_drumsep")
    mkdirP(stage2Dir)
    EIGHTHFU.writeWorkerContextFile(context, context.workerRunName, "single", context.runId, "single")
    writeFile(joinPath(stage2Dir, "drumsep_result.json"),
        realDrumsepResultJson(context.runId, "other-job", stage2Dir))
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function TENTHFU.assertKitSplitRealNestedHelperConflictScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "Kit Split's nested drumsep_result.json conflicting job_id still proved current health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+job_identity_conflicting") ~= nil,
        "a conflicting Kit Split nested helper job_id was not labeled job_identity_conflicting:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a conflicting Kit Split nested helper job_id:\n" .. manifest)
end

-- ---------------------------------------------------------------------
-- release/2.3.1.0-final-prep follow-up: closes the two concrete blockers
-- raised by the latest adversarial review of the RunContext authority
-- hardening above.
--
-- Blocker 1: the selected current-processing record's run_dir_name must
-- bind to exactly ONE physical persisted run directory -- matching
-- run_id alone (the old check) let a wholly separate, unselected, but
-- otherwise fully healthy run directory become "current".
--
-- Blocker 2: SW_LOG.persistRunDiagnostics did not copy Direct Kit's real
-- top-level <job-root>/drumsep_result.json into persisted diagnostics, so
-- a genuine helper/worker_context identity conflict present during a live
-- run could silently disappear before support-bundle evaluation ever saw
-- it. Exercised here through the actual production persistence path
-- (SW_LOG.persistRunDiagnostics), not by hand-placing the file in the
-- already-persisted fixture location.
-- ---------------------------------------------------------------------

-- Test J: directory A is the run the selected current-processing record is
-- actually bound to (run_dir_name=A), but A itself carries no worker
-- evidence at all. Directory B is a wholly separate, fully successful,
-- self-consistent run directory (its own worker_context.json correctly
-- names ITSELF as run_dir_name) whose run_id happens to be the SAME as the
-- selected record's run_id -- everything the old run_id-only selection
-- check required. B's run_dir_name is B, not A, so it must never become
-- current no matter how healthy its own evidence is.
function TENTHFU.createPhysicalRunDirBindingScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "physical-run-dir-binding-b-cannot-become-current"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    local sharedRunId = "guid-physical-bind-" .. tostring(os.time())
    context.runNameA = "STEMwerk_" .. tostring(os.time() - 5) .. "_001_1"
    -- Directory A physically exists (it is what the selected state is
    -- bound to) but carries no worker evidence of its own at all.
    mkdirP(joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs", context.runNameA))
    EIGHTHFU.writeCurrentProcessingRecord(context, sharedRunId, "completed", context.runNameA)

    waitNextSecond()
    context.runNameB = "STEMwerk_" .. tostring(os.time()) .. "_002_1"
    writeCurrentWorkerRun(context, context.runNameB, { successfulWorkerJob("single") })
    -- B's own worker_context.json is fully self-consistent (its
    -- run_dir_name correctly names ITSELF, B) and its run_id matches the
    -- selected record's run_id. The one thing it does not satisfy is being
    -- the physical directory the selected state actually points at (A).
    EIGHTHFU.writeWorkerContextFile(context, context.runNameB, "single", sharedRunId, "single")
    return context
end

function TENTHFU.assertPhysicalRunDirBindingScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "an unselected physical run directory (B) with a matching run_id but the wrong run_dir_name still proved current_worker_health=ok:\n" .. manifest)
    assertf(manifest:find("current_worker_health_run:%s+" .. context.runNameB) == nil,
        "the unselected directory B was reported as the current worker health run:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite current health being proved only by the wrong (unselected) physical run directory:\n" .. manifest)
    assertf(manifest:find("final_runtime_health_source:%s+current_worker_evidence") == nil,
        "final_runtime_health_source was attributed to current_worker_evidence despite the only healthy evidence coming from the non-selected physical directory B:\n" .. manifest)
    -- B remains visible as non-selected provenance -- it is not silently
    -- dropped, it simply cannot prove CURRENT health.
    assertf(manifest:find("recent_worker_health_run:%s+" .. context.runNameB) ~= nil,
        "the non-selected directory B was not surfaced as recent/provenance evidence at all:\n" .. manifest)
end

-- Real DrumSep Direct Kit LIVE job content (pre-persistence), written to a
-- staging directory OUTSIDE the persisted logs/runs tree and then moved
-- into place by the actual SW_LOG.persistRunDiagnostics production copy
-- path -- mirrors the shape audio_separator_process.py's dks_direct branch
-- and worker_context writer really produce during a live run.
function TENTHFU.persistLiveDirectKitJob(baseRoot, context, runName, jobName, workerRunId, workerJobId, helperRunId, helperJobId)
    local liveJobDir = joinPath(baseRoot, "live-direct-kit-processing", runName, jobName)
    mkdirP(liveJobDir)
    writeFile(joinPath(liveJobDir, "exit_code.txt"), "0\n")
    writeFile(joinPath(liveJobDir, "done.txt"), "DONE\n")
    writeFile(joinPath(liveJobDir, "separation_log.txt"), table.concat({
        "Direct Drum Kit Split route detected: workflow_mode=drumkit workflow_source=dks_direct",
        "workflow_mode=drumkit",
        "workflow_source=dks_direct",
        "model_id=MDX23C-DrumSep-aufr33-jarredou.ckpt",
        "drumsep_helper_output_dir=/tmp/" .. runName,
        "output_validation_reason=ok",
        "expected_stems=kick,snare,toms,hihat,ride,crash",
        "found_stems=kick,snare,toms,hihat,ride,crash",
        "timing_utc=2026-08-13T09:00:00 drumsep_helper_returncode=0",
        "",
    }, "\n"))
    writeFile(joinPath(liveJobDir, "timing_events.jsonl"),
        '{"time":' .. tostring(os.time()) .. ',"event":"done_seen","job_index":"' .. jobName
        .. '","job_dir":"/tmp/' .. runName .. '"}\n')
    writeFile(joinPath(liveJobDir, "worker_context.json"), table.concat({
        "{",
        '  "schema": 1,',
        '  "run_id": "' .. tostring(workerRunId) .. '",',
        '  "job_id": "' .. tostring(workerJobId) .. '",',
        '  "run_dir_name": "' .. tostring(runName) .. '",',
        '  "started_utc": "2026-07-24T13:00:00Z"',
        "}",
        "",
    }, "\n"))
    -- Direct Kit's real top-level result path: <job-root>/drumsep_result.json,
    -- no stage2_drumsep subdirectory (see audio_separator_process.py's
    -- _is_direct_dks_source branch, which runs the helper directly against
    -- output_root).
    writeFile(joinPath(liveJobDir, "drumsep_result.json"),
        realDrumsepResultJson(helperRunId, helperJobId, liveJobDir))

    ENV_OVERRIDES = context.env
    SW_LOG.persistRunDiagnostics(liveJobDir)
    ENV_OVERRIDES = nil
end

-- Test K: a valid worker_context.json (run_id=R, job_id=J) plus a top-level
-- drumsep_result.json with a CONFLICTING run_id, both written to a LIVE
-- staging directory and moved into persisted diagnostics only by the real
-- SW_LOG.persistRunDiagnostics call. Before Blocker 2's fix, this real
-- top-level file was silently never copied, so the genuine conflict could
-- never be seen by support-bundle evaluation at all.
function TENTHFU.createDirectKitPersistedHelperConflictScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "direct-kit-persisted-helper-conflict-via-real-persistence"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    context.runId = "guid-direct-kit-persisted-conflict-" .. tostring(os.time())
    TENTHFU.persistLiveDirectKitJob(baseRoot, context, context.workerRunName, "single",
        context.runId, "single",
        "guid-direct-kit-persisted-conflict-DIFFERENT-" .. tostring(os.time()), "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function TENTHFU.assertDirectKitPersistedHelperConflictScenario(bundleDir, context)
    local manifest = readManifest(bundleDir)
    local persistedResultPath = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs",
        context.workerRunName, "single", "drumsep_result.json")
    assertf(fileExists(persistedResultPath),
        "SW_LOG.persistRunDiagnostics did not copy Direct Kit's top-level drumsep_result.json into persisted diagnostics:\n" .. persistedResultPath)
    assertZeroAcceptancePhases(manifest)
    assertf(manifest:find("current_worker_health:%s+ok") == nil,
        "a Direct Kit top-level helper/worker_context identity conflict, surfaced only through real persistRunDiagnostics copying, still proved current health:\n" .. manifest)
    assertf(manifest:find("current_worker_health_reason:%s+job_identity_conflicting") ~= nil,
        "the persisted Direct Kit top-level helper conflict was not labeled job_identity_conflicting:\n" .. manifest)
    assertf(manifest:find("final_runtime_health:%s+ok") == nil,
        "final_runtime_health=ok despite a Direct Kit top-level helper/worker_context conflict surfaced through real persistence:\n" .. manifest)
end

-- Test L: success counterpart -- matching Direct Kit helper identity
-- (same run_id/job_id as worker_context.json), also written to a LIVE
-- staging directory and moved into place only by the real
-- SW_LOG.persistRunDiagnostics call, must still prove current health.
function TENTHFU.createDirectKitPersistedHelperMatchScenario(baseRoot)
    local context = createPresentScenario(baseRoot)
    context.name = "direct-kit-persisted-helper-match-via-real-persistence"
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    clearRuns(context)
    context.workerRunName = currentWorkerRunName()
    context.runId = "guid-direct-kit-persisted-match-" .. tostring(os.time())
    TENTHFU.persistLiveDirectKitJob(baseRoot, context, context.workerRunName, "single",
        context.runId, "single",
        context.runId, "single")
    EIGHTHFU.writeCurrentProcessingRecord(context, context.runId, "completed", context.workerRunName)
    return context
end

function TENTHFU.assertDirectKitPersistedHelperMatchScenario(bundleDir, context)
    local persistedResultPath = joinPath(context.env.HOME, ".cache", "STEMwerk", "logs", "runs",
        context.workerRunName, "single", "drumsep_result.json")
    assertf(fileExists(persistedResultPath),
        "SW_LOG.persistRunDiagnostics did not copy Direct Kit's top-level drumsep_result.json into persisted diagnostics:\n" .. persistedResultPath)
    assertWorkerProvenZeroPhases(readManifest(bundleDir), context)
end

local function assertZipIntegrity(bundleDir)
    local zipPath = bundleDir .. ".zip"
    assertf(fileExists(zipPath), "support bundle ZIP missing: " .. zipPath)
    if not IS_WINDOWS then
        local handle = REAL_IO_POPEN("unzip -t " .. shellQuote(zipPath) .. " 2>&1", "r")
        assertf(handle ~= nil, "could not launch unzip integrity check")
        local output = handle:read("*a") or ""
        local ok = handle:close()
        assertf(ok == true and output:find("No errors detected", 1, true) ~= nil, "support bundle ZIP integrity failed: " .. output)
    end
end

local function runScenario(context, assertionFn)
    ENV_OVERRIDES = context.env
    COMMAND_INTERCEPTOR = makeCommandInterceptor(context)
    reaper = makeReaperMock(context.resourcePath, context.extState)

    local ok, err = pcall(dofile, ACTION_SCRIPT)
    ENV_OVERRIDES = nil
    COMMAND_INTERCEPTOR = nil

    assertf(ok, context.name .. " crashed: " .. tostring(err))
    local bundleDir = latestBundleDir(context.resourcePath)
    assertf(bundleDir ~= nil, context.name .. " did not create a support bundle")
    assertionFn(bundleDir, context)
    return bundleDir
end

local function main()
    math.randomseed(os.time())
    local baseRoot = joinPath(currentTempBase(), "stemwerk-support-bundle-headless-" .. tostring(os.time()) .. "-" .. tostring(math.random(100000, 999999)))
    removeTree(baseRoot)
    mkdirP(baseRoot)

    print("Running headless support bundle collector tests")
    print("Repo root: " .. REPO_ROOT)
    print("Temp root: " .. baseRoot)

    local present = createPresentScenario(baseRoot)
    local presentBundle = runScenario(present, assertPresentScenario)
    assertZipIntegrity(presentBundle)
    print("PASS present-runtime -> " .. presentBundle)

    waitNextSecond()

    local missing = createMissingScenario(baseRoot)
    local missingBundle = runScenario(missing, assertMissingScenario)
    print("PASS missing-runtime -> " .. missingBundle)

    waitNextSecond()

    local failedFallback = createFailedFallbackScenario(joinPath(baseRoot, "failed-fallback"))
    local failedFallbackBundle = runScenario(failedFallback, assertFailedFallbackScenario)
    assertZipIntegrity(failedFallbackBundle)
    print("PASS failed-onnx-fallback -> " .. failedFallbackBundle)

    waitNextSecond()

    local amdRocm = createAmdRocmScenario(joinPath(baseRoot, "amd-rocm"))
    local amdRocmBundle = runScenario(amdRocm, assertAmdRocmScenario)
    print("PASS amd-rocm-device-classification -> " .. amdRocmBundle)

    waitNextSecond()

    local nvidiaCuda = createNvidiaCudaScenario(joinPath(baseRoot, "nvidia-cuda"))
    local nvidiaCudaBundle = runScenario(nvidiaCuda, assertNvidiaCudaScenario)
    print("PASS nvidia-cuda-device-classification -> " .. nvidiaCudaBundle)

    waitNextSecond()

    local shuffled = createShuffledRunAssociationScenario(joinPath(baseRoot, "shuffled-run-assoc"))
    local shuffledBundle = runScenario(shuffled, assertShuffledRunAssociationScenario)
    print("PASS shuffled-run-id-association -> " .. shuffledBundle)

    waitNextSecond()

    local parallelAgg = createParallelAggregationScenario(joinPath(baseRoot, "parallel-aggregation"))
    local parallelAggBundle = runScenario(parallelAgg, assertParallelAggregationScenario)
    print("PASS parallel-output-aggregation -> " .. parallelAggBundle)

    waitNextSecond()

    local directKit = createDirectKitScenario(joinPath(baseRoot, "direct-kit"))
    local directKitBundle = runScenario(directKit, assertDirectKitScenario)
    print("PASS direct-kit-semantic-model -> " .. directKitBundle)

    waitNextSecond()

    local kitSplit = createKitSplitScenario(joinPath(baseRoot, "kit-split"))
    local kitSplitBundle = runScenario(kitSplit, assertKitSplitScenario)
    print("PASS kit-split-two-stage-model -> " .. kitSplitBundle)

    waitNextSecond()

    local noPhases = createHealthyNoAcceptancePhasesScenario(joinPath(baseRoot, "no-acceptance-phases"))
    local noPhasesBundle = runScenario(noPhases, assertHealthyNoAcceptancePhasesScenario)
    print("PASS healthy-runtime-no-acceptance-phases -> " .. noPhasesBundle)

    waitNextSecond()

    local recoveredFatal = createHistoricalRecoveredFatalScenario(joinPath(baseRoot, "historical-recovered-fatal"))
    local recoveredFatalBundle = runScenario(recoveredFatal, assertHistoricalRecoveredFatalScenario)
    print("PASS historical-onnx-failure-recovered -> " .. recoveredFatalBundle)

    waitNextSecond()

    local singleRunUnrelatedSession = createSingleRunUnrelatedSessionScenario(joinPath(baseRoot, "single-run-unrelated-session"))
    local singleRunUnrelatedSessionBundle = runScenario(singleRunUnrelatedSession, assertSingleRunUnrelatedSessionScenario)
    print("PASS single-run-unrelated-session -> " .. singleRunUnrelatedSessionBundle)

    waitNextSecond()

    local missingTokenSession = createMissingTokenSessionScenario(joinPath(baseRoot, "missing-token-session"))
    local missingTokenSessionBundle = runScenario(missingTokenSession, assertMissingTokenSessionScenario)
    print("PASS missing-token-session -> " .. missingTokenSessionBundle)

    waitNextSecond()

    local replayedRunId = createReplayedRunIdScenario(joinPath(baseRoot, "replayed-duplicate-run-id"))
    local replayedRunIdBundle = runScenario(replayedRunId, assertReplayedRunIdScenario)
    print("PASS replayed-duplicate-run-id -> " .. replayedRunIdBundle)

    waitNextSecond()

    local currentNvidiaVsStaleAmd = createCurrentNvidiaVsStaleAmdScenario(joinPath(baseRoot, "current-nvidia-vs-stale-amd"))
    local currentNvidiaVsStaleAmdBundle = runScenario(currentNvidiaVsStaleAmd, assertCurrentNvidiaVsStaleAmdScenario)
    print("PASS current-nvidia-vs-stale-amd-global-state -> " .. currentNvidiaVsStaleAmdBundle)

    waitNextSecond()

    local ambiguousCuda = createAmbiguousCudaDeviceScenario(joinPath(baseRoot, "ambiguous-cuda-device"))
    local ambiguousCudaBundle = runScenario(ambiguousCuda, assertAmbiguousCudaDeviceScenario)
    print("PASS ambiguous-cuda-device-no-vendor-evidence -> " .. ambiguousCudaBundle)

    waitNextSecond()

    local unknownTruthiness = createUnknownTruthinessScenario(joinPath(baseRoot, "unknown-truthiness"))
    local unknownTruthinessBundle = runScenario(unknownTruthiness, assertUnknownTruthinessScenario)
    print("PASS unknown-truthiness-does-not-suppress-real-evidence -> " .. unknownTruthinessBundle)

    waitNextSecond()

    local mixedSuccessParallel = createMixedSuccessParallelScenario(joinPath(baseRoot, "mixed-success-parallel"))
    local mixedSuccessParallelBundle = runScenario(mixedSuccessParallel, assertMixedSuccessParallelScenario)
    print("PASS mixed-success-parallel-jobs -> " .. mixedSuccessParallelBundle)

    waitNextSecond()

    local partialValidation = createPartialValidationScenario(joinPath(baseRoot, "partial-validation"))
    local partialValidationBundle = runScenario(partialValidation, assertPartialValidationScenario)
    print("PASS partial-validation-not-ok -> " .. partialValidationBundle)

    waitNextSecond()

    local unequalOutputCounts = createUnequalOutputCountsScenario(joinPath(baseRoot, "unequal-output-counts"))
    local unequalOutputCountsBundle = runScenario(unequalOutputCounts, assertUnequalOutputCountsScenario)
    print("PASS unequal-output-counts -> " .. unequalOutputCountsBundle)

    waitNextSecond()

    local lateModelResolution = createLateModelResolutionScenario(joinPath(baseRoot, "late-model-resolution"))
    local lateModelResolutionBundle = runScenario(lateModelResolution, assertLateModelResolutionScenario)
    print("PASS late-model-resolution-6stem-parallel -> " .. lateModelResolutionBundle)

    waitNextSecond()

    local crossRunKitSplit = createCrossRunKitSplitScenario(joinPath(baseRoot, "cross-run-kit-split"))
    local crossRunKitSplitBundle = runScenario(crossRunKitSplit, assertCrossRunKitSplitScenario)
    print("PASS cross-run-kit-split-no-leakage -> " .. crossRunKitSplitBundle)

    waitNextSecond()

    local currentFailureDespiteHistoricalSuccess = createCurrentFailureDespiteHistoricalSuccessScenario(joinPath(baseRoot, "current-failure-despite-historical-success"))
    local currentFailureDespiteHistoricalSuccessBundle = runScenario(currentFailureDespiteHistoricalSuccess, assertCurrentFailureDespiteHistoricalSuccessScenario)
    print("PASS current-failure-despite-historical-success -> " .. currentFailureDespiteHistoricalSuccessBundle)

    waitNextSecond()

    local tempResidueIsolation = createTempResidueIsolationScenario(joinPath(baseRoot, "temp-residue-isolation"))
    local tempResidueIsolationBundle = runScenario(tempResidueIsolation, assertTempResidueIsolationScenario)
    print("PASS temp-residue-isolation -> " .. tempResidueIsolationBundle)

    waitNextSecond()

    local additionalMarkers = createAdditionalModelMarkersScenario(joinPath(baseRoot, "additional-model-markers"))
    local additionalMarkersBundle = runScenario(additionalMarkers, assertAdditionalModelMarkersScenario)
    print("PASS additional-model-markers-parsed -> " .. additionalMarkersBundle)

    waitNextSecond()

    local tokenlessLaunch = createTokenlessLaunchAfterValidRunScenario(joinPath(baseRoot, "tokenless-launch-after-valid-run"))
    local tokenlessLaunchBundle = runScenario(tokenlessLaunch, assertTokenlessLaunchAfterValidRunScenario)
    print("PASS tokenless-launch-after-valid-run -> " .. tokenlessLaunchBundle)

    waitNextSecond()

    local heteroJobs = createHeterogeneousJobsSameRunScenario(joinPath(baseRoot, "heterogeneous-jobs-same-run"))
    local heteroJobsBundle = runScenario(heteroJobs, assertHeterogeneousJobsSameRunScenario)
    print("PASS heterogeneous-jobs-same-run-no-fabricated-combo -> " .. heteroJobsBundle)

    waitNextSecond()

    local heteroDrumsep = createHeterogeneousDrumsepSameRunScenario(joinPath(baseRoot, "heterogeneous-drumsep-same-run"))
    local heteroDrumsepBundle = runScenario(heteroDrumsep, assertHeterogeneousDrumsepSameRunScenario)
    print("PASS heterogeneous-drumsep-fields-same-run -> " .. heteroDrumsepBundle)

    waitNextSecond()

    local heteroKitSplit = createHeterogeneousKitSplitSameRunScenario(joinPath(baseRoot, "heterogeneous-kit-split-same-run"))
    local heteroKitSplitBundle = runScenario(heteroKitSplit, assertHeterogeneousKitSplitSameRunScenario)
    print("PASS heterogeneous-kit-split-stages-same-run -> " .. heteroKitSplitBundle)

    waitNextSecond()

    local directKitLeak = createDirectKitGenericModelLeakageScenario(joinPath(baseRoot, "direct-kit-generic-model-leakage"))
    local directKitLeakBundle = runScenario(directKitLeak, assertDirectKitGenericModelLeakageScenario)
    print("PASS direct-kit-generic-model-leakage -> " .. directKitLeakBundle)

    waitNextSecond()

    local mpsCpuFallback = createMpsRequestedCpuEffectiveScenario(joinPath(baseRoot, "mps-requested-cpu-effective"))
    local mpsCpuFallbackBundle = runScenario(mpsCpuFallback, assertMpsRequestedCpuEffectiveScenario)
    print("PASS mps-requested-cpu-effective-fallback -> " .. mpsCpuFallbackBundle)

    waitNextSecond()

    local staleBootstrapCurrentFail = createStaleBootstrapCurrentFailedPhaseScenario(joinPath(baseRoot, "stale-bootstrap-current-failed-phase"))
    local staleBootstrapCurrentFailBundle = runScenario(staleBootstrapCurrentFail, assertStaleBootstrapCurrentFailedPhaseScenario)
    print("PASS stale-healthy-bootstrap-current-failed-phase -> " .. staleBootstrapCurrentFailBundle)

    waitNextSecond()

    local staleTimestampedPhase = createStaleTimestampedPhaseScenario(joinPath(baseRoot, "stale-timestamped-phase"))
    local staleTimestampedPhaseBundle = runScenario(staleTimestampedPhase, assertStaleTimestampedPhaseScenario)
    print("PASS stale-timestamped-phase-cannot-prove-health -> " .. staleTimestampedPhaseBundle)

    waitNextSecond()

    local newerUnrelatedTemp = createNewerUnrelatedTempResidueScenario(joinPath(baseRoot, "newer-unrelated-temp-residue"))
    local newerUnrelatedTempBundle = runScenario(newerUnrelatedTemp, assertNewerUnrelatedTempResidueScenario)
    print("PASS newer-unrelated-temp-residue-lacks-identity -> " .. newerUnrelatedTempBundle)

    waitNextSecond()

    local drumsepHelperArgCpu = createDrumsepHelperArgCpuEffectiveScenario(joinPath(baseRoot, "drumsep-helper-arg-mps-cpu-effective"))
    local drumsepHelperArgCpuBundle = runScenario(drumsepHelperArgCpu, assertDrumsepHelperArgCpuEffectiveScenario)
    print("PASS drumsep-helper-arg-mps-cpu-effective -> " .. drumsepHelperArgCpuBundle)

    waitNextSecond()

    local phaseMissingTimestamp = createPhaseMissingTimestampScenario(joinPath(baseRoot, "phase-missing-timestamp"))
    local phaseMissingTimestampBundle = runScenario(phaseMissingTimestamp, assertPhaseMissingTimestampScenario)
    print("PASS phase-missing-timestamp-cannot-prove-health -> " .. phaseMissingTimestampBundle)

    waitNextSecond()

    local phaseMalformedTimestamp = createPhaseMalformedTimestampScenario(joinPath(baseRoot, "phase-malformed-timestamp"))
    local phaseMalformedTimestampBundle = runScenario(phaseMalformedTimestamp, assertPhaseMalformedTimestampScenario)
    print("PASS phase-malformed-timestamp-cannot-prove-health -> " .. phaseMalformedTimestampBundle)

    waitNextSecond()

    local tempNamePatternOnly = createTempNameMatchesButNoRunIdentityScenario(joinPath(baseRoot, "temp-name-pattern-without-run-identity"))
    local tempNamePatternOnlyBundle = runScenario(tempNamePatternOnly, assertTempNameMatchesButNoRunIdentityScenario)
    print("PASS temp-name-pattern-without-run-identity -> " .. tempNamePatternOnlyBundle)

    waitNextSecond()

    local historicalSuccessOnly = createHistoricalSuccessOnlyScenario(joinPath(baseRoot, "historical-success-log-only"))
    local historicalSuccessOnlyBundle = runScenario(historicalSuccessOnly, assertHistoricalSuccessOnlyScenario)
    print("PASS historical-success-log-only-not-proven -> " .. historicalSuccessOnlyBundle)

    waitNextSecond()

    local cachedBootstrapCurrentFatal = createCachedBootstrapCurrentFatalScenario(joinPath(baseRoot, "cached-bootstrap-current-fatal"))
    local cachedBootstrapCurrentFatalBundle = runScenario(cachedBootstrapCurrentFatal, assertCachedBootstrapCurrentFatalScenario)
    print("PASS cached-bootstrap-current-fatal -> " .. cachedBootstrapCurrentFatalBundle)

    waitNextSecond()

    local cachedBootstrapWorker = createCachedBootstrapCurrentWorkerNoPhasesScenario(joinPath(baseRoot, "cached-bootstrap-current-worker"))
    local cachedBootstrapWorkerBundle = runScenario(cachedBootstrapWorker, assertCachedBootstrapCurrentWorkerNoPhasesScenario)
    print("PASS cached-bootstrap-current-worker-no-phases -> " .. cachedBootstrapWorkerBundle)

    waitNextSecond()

    local noBootstrapWorker = createNoBootstrapCurrentWorkerNoPhasesScenario(joinPath(baseRoot, "no-bootstrap-current-worker"))
    local noBootstrapWorkerBundle = runScenario(noBootstrapWorker, assertNoBootstrapCurrentWorkerNoPhasesScenario)
    print("PASS no-bootstrap-current-worker-no-phases -> " .. noBootstrapWorkerBundle)

    waitNextSecond()

    local mixedJobFailure = createMixedJobFailureNoPhasesScenario(joinPath(baseRoot, "mixed-job-failure-no-phases"))
    local mixedJobFailureBundle = runScenario(mixedJobFailure, assertMixedJobFailureNoPhasesScenario)
    print("PASS mixed-job-failure-no-phases -> " .. mixedJobFailureBundle)

    waitNextSecond()

    local incompleteOutput = createIncompleteOutputNoPhasesScenario(joinPath(baseRoot, "incomplete-output-no-phases"))
    local incompleteOutputBundle = runScenario(incompleteOutput, assertIncompleteOutputNoPhasesScenario)
    print("PASS incomplete-output-no-phases -> " .. incompleteOutputBundle)

    waitNextSecond()

    local validationFailure = createValidationFailureNoPhasesScenario(joinPath(baseRoot, "validation-failure-no-phases"))
    local validationFailureBundle = runScenario(validationFailure, assertValidationFailureNoPhasesScenario)
    print("PASS validation-failure-no-phases -> " .. validationFailureBundle)

    waitNextSecond()

    local historicalLogWorker = createHistoricalLogCurrentWorkerNoPhasesScenario(joinPath(baseRoot, "historical-log-current-worker"))
    local historicalLogWorkerBundle = runScenario(historicalLogWorker, assertHistoricalLogCurrentWorkerNoPhasesScenario)
    print("PASS historical-log-current-worker-no-phases -> " .. historicalLogWorkerBundle)

    waitNextSecond()

    local cachedBootstrapOnly = createCachedBootstrapOnlyNoPhasesScenario(joinPath(baseRoot, "cached-bootstrap-only-no-phases"))
    local cachedBootstrapOnlyBundle = runScenario(cachedBootstrapOnly, assertCachedBootstrapOnlyNoPhasesScenario)
    print("PASS cached-bootstrap-only-no-phases -> " .. cachedBootstrapOnlyBundle)

    waitNextSecond()

    local workerVsFatalPhase = createCurrentWorkerCurrentFatalPhaseScenario(joinPath(baseRoot, "current-worker-current-fatal-phase"))
    local workerVsFatalPhaseBundle = runScenario(workerVsFatalPhase, assertCurrentWorkerCurrentFatalPhaseScenario)
    print("PASS current-worker-current-fatal-phase-failure-wins -> " .. workerVsFatalPhaseBundle)

    waitNextSecond()

    local realDirectKit = createRealDirectKitZeroPhasesScenario(joinPath(baseRoot, "real-direct-kit-zero-phases"))
    local realDirectKitBundle = runScenario(realDirectKit, assertRealDirectKitZeroPhasesScenario)
    print("PASS real-format-direct-kit-zero-phases-success -> " .. realDirectKitBundle)

    waitNextSecond()

    local realKitSplit = createRealKitSplitZeroPhasesScenario(joinPath(baseRoot, "real-kit-split-zero-phases"))
    local realKitSplitBundle = runScenario(realKitSplit, assertRealKitSplitZeroPhasesScenario)
    print("PASS real-format-kit-split-zero-phases-success -> " .. realKitSplitBundle)

    waitNextSecond()

    local directKitFive = createDirectKitFiveOfSixScenario(joinPath(baseRoot, "direct-kit-five-of-six"))
    local directKitFiveBundle = runScenario(directKitFive, assertDirectKitFiveOfSixScenario)
    print("PASS direct-kit-five-of-six-not-healthy -> " .. directKitFiveBundle)

    waitNextSecond()

    local kitSplitFive = createKitSplitFiveOfSixScenario(joinPath(baseRoot, "kit-split-five-of-six"))
    local kitSplitFiveBundle = runScenario(kitSplitFive, assertKitSplitFiveOfSixScenario)
    print("PASS kit-split-five-of-six-not-healthy -> " .. kitSplitFiveBundle)

    waitNextSecond()

    local missingValidation = createMissingRequiredValidationScenario(joinPath(baseRoot, "missing-required-validation"))
    local missingValidationBundle = runScenario(missingValidation, assertMissingRequiredValidationScenario)
    print("PASS missing-required-validation-not-healthy -> " .. missingValidationBundle)

    waitNextSecond()

    local substringIdentity = createArbitrarySubstringIdentityScenario(joinPath(baseRoot, "arbitrary-substring-identity"))
    local substringIdentityBundle = runScenario(substringIdentity, assertArbitrarySubstringIdentityScenario)
    print("PASS arbitrary-run-id-substring-does-not-identify-run -> " .. substringIdentityBundle)

    waitNextSecond()

    local explicitMarker = createExplicitRunIdMarkerScenario(joinPath(baseRoot, "explicit-run-id-marker"))
    local explicitMarkerBundle = runScenario(explicitMarker, assertExplicitRunIdMarkerScenario)
    print("PASS explicit-run-id-marker-identifies-run -> " .. explicitMarkerBundle)

    waitNextSecond()

    local oldSuccess = createOldSuccessNotCurrentScenario(joinPath(baseRoot, "old-success-not-current"))
    local oldSuccessBundle = runScenario(oldSuccess, assertOldSuccessNotCurrentScenario)
    print("PASS old-success-alone-not-current -> " .. oldSuccessBundle)

    waitNextSecond()

    local sameSecondSF = createSameSecondSuccessThenFailureScenario(joinPath(baseRoot, "same-second-success-failure"))
    local sameSecondSFB = runScenario(sameSecondSF, assertSameSecondSuccessThenFailureScenario)
    print("PASS same-second-success-then-failure -> " .. sameSecondSFB)

    waitNextSecond()

    local sameSecondFS = createSameSecondFailureThenSuccessScenario(joinPath(baseRoot, "same-second-failure-success"))
    local sameSecondFSB = runScenario(sameSecondFS, assertSameSecondFailureThenSuccessScenario)
    print("PASS same-second-failure-then-success -> " .. sameSecondFSB)

    waitNextSecond()

    local reducedExpectedDk = createReducedExpectedStemsScenario(joinPath(baseRoot, "reduced-expected-direct-kit"), "dks_direct", "direct-kit-reduced-expected-stems-cannot-weaken")
    local reducedExpectedDkBundle = runScenario(reducedExpectedDk, assertReducedExpectedStemsScenario)
    print("PASS direct-kit-reduced-expected-stems-cannot-weaken -> " .. reducedExpectedDkBundle)

    waitNextSecond()

    local reducedExpectedKs = createReducedExpectedStemsScenario(joinPath(baseRoot, "reduced-expected-kit-split"), "dks_extract", "kit-split-reduced-expected-stems-cannot-weaken")
    local reducedExpectedKsBundle = runScenario(reducedExpectedKs, assertReducedExpectedStemsScenario)
    print("PASS kit-split-reduced-expected-stems-cannot-weaken -> " .. reducedExpectedKsBundle)

    waitNextSecond()

    local perJobIdentity = createPerJobIdentityScenario(joinPath(baseRoot, "per-job-identity"))
    local perJobIdentityBundle = runScenario(perJobIdentity, assertPerJobIdentityScenario)
    print("PASS same-run-job-a-identified-job-b-unidentified -> " .. perJobIdentityBundle)

    waitNextSecond()

    local conflictingIdentity = createConflictingIdentityScenario(joinPath(baseRoot, "conflicting-identity"))
    local conflictingIdentityBundle = runScenario(conflictingIdentity, assertConflictingIdentityScenario)
    print("PASS same-job-conflicting-identity-markers -> " .. conflictingIdentityBundle)

    waitNextSecond()

    local copiedEvidence = createCopiedJobEvidenceScenario(joinPath(baseRoot, "copied-job-evidence"))
    local copiedEvidenceBundle = runScenario(copiedEvidence, assertCopiedJobEvidenceScenario)
    print("PASS copied-job-evidence-from-another-run -> " .. copiedEvidenceBundle)

    waitNextSecond()

    local newerUnproven = createNewerUnprovenSupersedesScenario(joinPath(baseRoot, "newer-unproven-supersedes"))
    local newerUnprovenBundle = runScenario(newerUnproven, assertNewerUnprovenSupersedesScenario)
    print("PASS older-success-newer-unproven -> " .. newerUnprovenBundle)

    waitNextSecond()

    local newerSuccess = createNewerSuccessSupersedesScenario(joinPath(baseRoot, "newer-success-supersedes"))
    local newerSuccessBundle = runScenario(newerSuccess, assertNewerSuccessSupersedesScenario)
    print("PASS older-failure-newer-success -> " .. newerSuccessBundle)

    waitNextSecond()

    local sameSecondUnproven = createSameSecondNewerUnprovenScenario(joinPath(baseRoot, "same-second-newer-unproven"))
    local sameSecondUnprovenBundle = runScenario(sameSecondUnproven, assertSameSecondNewerUnprovenScenario)
    print("PASS same-second-success-then-unproven -> " .. sameSecondUnprovenBundle)

    waitNextSecond()

    local staleSession = createStaleSessionRootScenario(joinPath(baseRoot, "stale-session-root"))
    local staleSessionBundle = runScenario(staleSession, assertStaleSessionRootScenario)
    print("PASS stale-session-root-does-not-admit-old-run -> " .. staleSessionBundle)

    waitNextSecond()

    local recentUnlinked = createRecentUnlinkedNotCurrentScenario(joinPath(baseRoot, "recent-unlinked-not-current"))
    local recentUnlinkedBundle = runScenario(recentUnlinked, assertRecentUnlinkedNotCurrentScenario)
    print("PASS recent-unlinked-success-does-not-prove-current -> " .. recentUnlinkedBundle)

    waitNextSecond()

    local vocalsOnly = createNarrowPresetSuccessScenario(joinPath(baseRoot, "vocals-only"), "real-format-vocals-only-success", "htdemucs", { "bass", "drums", "other", "vocals" })
    local vocalsOnlyBundle = runScenario(vocalsOnly, assertNarrowPresetSuccessScenario)
    print("PASS real-format-vocals-only-success -> " .. vocalsOnlyBundle)

    waitNextSecond()

    local drumsOnly = createNarrowPresetSuccessScenario(joinPath(baseRoot, "drums-only"), "real-format-drums-only-success", "htdemucs", { "bass", "drums", "other", "vocals" })
    local drumsOnlyBundle = runScenario(drumsOnly, assertNarrowPresetSuccessScenario)
    print("PASS real-format-drums-only-success -> " .. drumsOnlyBundle)

    waitNextSecond()

    local bassOnly = createNarrowPresetSuccessScenario(joinPath(baseRoot, "bass-only"), "real-format-bass-only-success", "htdemucs", { "bass", "drums", "other", "vocals" })
    local bassOnlyBundle = runScenario(bassOnly, assertNarrowPresetSuccessScenario)
    print("PASS real-format-bass-only-success -> " .. bassOnlyBundle)

    waitNextSecond()

    local narrowIncomplete = createNarrowPresetIncompleteScenario(joinPath(baseRoot, "narrow-preset-incomplete"))
    local narrowIncompleteBundle = runScenario(narrowIncomplete, assertNarrowPresetIncompleteScenario)
    print("PASS narrow-preset-incomplete-output-rejected -> " .. narrowIncompleteBundle)

    waitNextSecond()

    -- Each remaining eighth-follow-up scenario is wrapped in its own do/end
    -- block so its locals go out of scope immediately: main() is already
    -- near Lua's 200-local-per-function limit, and named locals per
    -- scenario (as used throughout the rest of this file) would overflow
    -- it once this many new fixtures are added in one run.
    do
        local ctx = EIGHTHFU.createDirectKitCountOnlySixScenario(joinPath(baseRoot, "direct-kit-count-only-six"))
        print("PASS direct-kit-count-only-six-rejected -> " .. runScenario(ctx, EIGHTHFU.assertDirectKitCountOnlySixScenario))
    end

    waitNextSecond()

    do
        local ctx = EIGHTHFU.createKitSplitCountOnlySixScenario(joinPath(baseRoot, "kit-split-count-only-six"))
        print("PASS kit-split-count-only-six-rejected -> " .. runScenario(ctx, EIGHTHFU.assertKitSplitCountOnlySixScenario))
    end

    waitNextSecond()

    do
        local ctx = EIGHTHFU.createDirectKitSixArbitraryNamesScenario(joinPath(baseRoot, "direct-kit-six-arbitrary-names"))
        print("PASS direct-kit-six-arbitrary-names-rejected -> " .. runScenario(ctx, EIGHTHFU.assertDirectKitSixArbitraryNamesScenario))
    end

    waitNextSecond()

    do
        local ctx = EIGHTHFU.createKitSplitSixArbitraryNamesScenario(joinPath(baseRoot, "kit-split-six-arbitrary-names"))
        print("PASS kit-split-six-arbitrary-names-rejected -> " .. runScenario(ctx, EIGHTHFU.assertKitSplitSixArbitraryNamesScenario))
    end

    waitNextSecond()

    do
        local ctx = EIGHTHFU.createNormalMissingModelScenario(joinPath(baseRoot, "normal-missing-model"))
        print("PASS normal-missing-model-rejected -> " .. runScenario(ctx, EIGHTHFU.assertNormalMissingModelScenario))
    end

    waitNextSecond()

    do
        local ctx = EIGHTHFU.createNormalUnknownModelScenario(joinPath(baseRoot, "normal-unknown-model"))
        print("PASS normal-unknown-model-rejected -> " .. runScenario(ctx, EIGHTHFU.assertNormalUnknownModelScenario))
    end

    waitNextSecond()

    do
        local ctx = EIGHTHFU.createNormalFourArbitraryNamesScenario(joinPath(baseRoot, "normal-four-arbitrary-names"))
        print("PASS normal-four-arbitrary-names-rejected -> " .. runScenario(ctx, EIGHTHFU.assertNormalFourArbitraryNamesScenario))
    end

    waitNextSecond()

    do
        local ctx = EIGHTHFU.createNormalCanonicalFourNamesScenario(joinPath(baseRoot, "normal-canonical-four-names"))
        print("PASS normal-canonical-four-names-accepted -> " .. runScenario(ctx, EIGHTHFU.assertNormalCanonicalFourNamesScenario))
    end

    waitNextSecond()

    do
        local ctx = EIGHTHFU.createSixStemArbitraryNamesScenario(joinPath(baseRoot, "six-stem-six-arbitrary-names"))
        print("PASS six-stem-six-arbitrary-names-rejected -> " .. runScenario(ctx, EIGHTHFU.assertSixStemArbitraryNamesScenario))
    end

    waitNextSecond()

    do
        local ctx = EIGHTHFU.createSixStemCanonicalNamesScenario(joinPath(baseRoot, "six-stem-canonical-six-names"))
        print("PASS six-stem-canonical-six-names-accepted -> " .. runScenario(ctx, EIGHTHFU.assertSixStemCanonicalNamesScenario))
    end

    waitNextSecond()

    do
        local ctx = EIGHTHFU.createSessionIdMismatchScenario(joinPath(baseRoot, "mismatched-session-id"))
        print("PASS mismatched-session-id-remains-unlinked -> " .. runScenario(ctx, EIGHTHFU.assertSessionIdMismatchScenario))
    end

    waitNextSecond()

    do
        local ctx = EIGHTHFU.createStructuredIdentityCurrentScenario(joinPath(baseRoot, "structured-identity-current"))
        print("PASS structured-identity-proves-current -> " .. runScenario(ctx, EIGHTHFU.assertStructuredIdentityCurrentScenario))
    end

    waitNextSecond()

    do
        local ctx = EIGHTHFU.createStructuredIdentityBeatsTimestampScenario(joinPath(baseRoot, "structured-identity-beats-timestamp"))
        print("PASS structured-identity-beats-timestamp-ordering -> " .. runScenario(ctx, EIGHTHFU.assertStructuredIdentityBeatsTimestampScenario))
    end

    waitNextSecond()

    do
        local ctx = EIGHTHFU.createMismatchedJobRunIdScenario(joinPath(baseRoot, "mismatched-job-run-id"))
        print("PASS mismatched-job-run-id-cannot-prove-current -> " .. runScenario(ctx, EIGHTHFU.assertMismatchedJobRunIdScenario))
    end

    waitNextSecond()

    do
        local ctx = EIGHTHFU.createMissingJobIdentityScenario(joinPath(baseRoot, "missing-job-identity"))
        print("PASS missing-job-identity-cannot-prove-current -> " .. runScenario(ctx, EIGHTHFU.assertMissingJobIdentityScenario))
    end

    waitNextSecond()

    do
        local ctx = EIGHTHFU.createReplayedContextScenario(joinPath(baseRoot, "replayed-structured-context"))
        print("PASS replayed-structured-context-cannot-prove-current -> " .. runScenario(ctx, EIGHTHFU.assertReplayedContextScenario))
    end

    waitNextSecond()

    do
        local ctx = NINTHFU.createMalformedWorkerContextScenario(joinPath(baseRoot, "malformed-worker-context"))
        print("PASS malformed-worker-context-json -> " .. runScenario(ctx, NINTHFU.assertMalformedWorkerContextScenario))
    end

    do
        local ctx = NINTHFU.createTruncatedWorkerContextScenario(joinPath(baseRoot, "truncated-worker-context"))
        print("PASS truncated-worker-context-with-run-id -> " .. runScenario(ctx, NINTHFU.assertTruncatedWorkerContextScenario))
    end

    do
        local ctx = NINTHFU.createWrongSchemaWorkerContextScenario(joinPath(baseRoot, "wrong-worker-context-schema"))
        print("PASS wrong-worker-context-schema -> " .. runScenario(ctx, NINTHFU.assertWrongSchemaWorkerContextScenario))
    end

    do
        local ctx = NINTHFU.createMissingJobIdScenario(joinPath(baseRoot, "missing-job-id"))
        print("PASS missing-job-id -> " .. runScenario(ctx, NINTHFU.assertMissingJobIdScenario))
    end

    do
        local ctx = NINTHFU.createWrongJobIdScenario(joinPath(baseRoot, "wrong-job-id"))
        print("PASS wrong-job-id -> " .. runScenario(ctx, NINTHFU.assertWrongJobIdScenario))
    end

    do
        local ctx = NINTHFU.createDuplicateJobIdScenario(joinPath(baseRoot, "duplicate-job-id"))
        print("PASS duplicate-job-id -> " .. runScenario(ctx, NINTHFU.assertDuplicateJobIdScenario))
    end

    do
        local ctx = NINTHFU.createMalformedCurrentStateScenario(joinPath(baseRoot, "malformed-current-state"))
        print("PASS malformed-current-state-json -> " .. runScenario(ctx, NINTHFU.assertMalformedCurrentStateScenario))
    end

    do
        local ctx = NINTHFU.createTruncatedCurrentStateScenario(joinPath(baseRoot, "truncated-current-state"))
        print("PASS truncated-current-state-with-run-id -> " .. runScenario(ctx, NINTHFU.assertTruncatedCurrentStateScenario))
    end

    do
        local ctx = NINTHFU.createStateFilenameMismatchScenario(joinPath(baseRoot, "state-filename-mismatch"))
        print("PASS state-filename-run-id-mismatch -> " .. runScenario(ctx, NINTHFU.assertStateFilenameMismatchScenario))
    end

    do
        local ctx = NINTHFU.createStateRunDirMismatchScenario(joinPath(baseRoot, "state-run-dir-mismatch"))
        print("PASS state-run-dir-mismatch -> " .. runScenario(ctx, NINTHFU.assertStateRunDirMismatchScenario))
    end

    do
        local ctx = NINTHFU.createCurrentStateRunningScenario(joinPath(baseRoot, "current-state-running"))
        print("PASS current-state-running -> " .. runScenario(ctx, NINTHFU.assertCurrentStateRunningScenario))
    end

    do
        local ctx = NINTHFU.createCurrentStateFailedScenario(joinPath(baseRoot, "current-state-failed"))
        print("PASS current-state-failed -> " .. runScenario(ctx, NINTHFU.assertCurrentStateFailedScenario))
    end

    do
        local ctx = NINTHFU.createCurrentStateCancelledScenario(joinPath(baseRoot, "current-state-cancelled"))
        print("PASS current-state-cancelled -> " .. runScenario(ctx, NINTHFU.assertCurrentStateCancelledScenario))
    end

    do
        local ctx = NINTHFU.createStaleCompletedStateScenario(joinPath(baseRoot, "stale-completed-state"))
        print("PASS stale-completed-state -> " .. runScenario(ctx, NINTHFU.assertStaleCompletedStateScenario))
    end

    waitNextSecond()

    do
        local ctx = NINTHFU.createTwoConcurrentValidRunsScenario(joinPath(baseRoot, "two-concurrent-valid-runs"))
        print("PASS two-concurrent-valid-runs-no-cross-merge -> " .. runScenario(ctx, NINTHFU.assertTwoConcurrentValidRunsScenario))
    end

    waitNextSecond()

    do
        local ctx = NINTHFU.createSelectedRunASuccessfulRunBScenario(joinPath(baseRoot, "selected-run-a-successful-run-b"))
        print("PASS selected-run-a-successful-run-b -> " .. runScenario(ctx, NINTHFU.assertSelectedRunASuccessfulRunBScenario))
    end

    waitNextSecond()

    do
        local ctx = NINTHFU.createSelectedRunAIncompleteRunBScenario(joinPath(baseRoot, "selected-run-a-incomplete-run-b"))
        print("PASS selected-run-a-incomplete-successful-run-b -> " .. runScenario(ctx, NINTHFU.assertSelectedRunAIncompleteRunBScenario))
    end

    do
        local ctx = TENTHFU.createStructuredSiblingPlusLegacyJobScenario(joinPath(baseRoot, "structured-sibling-plus-legacy"))
        print("PASS structured-job-plus-legacy-sibling-rejected -> " .. runScenario(ctx, TENTHFU.assertStructuredSiblingPlusLegacyJobScenario))
    end

    do
        local ctx = TENTHFU.createHelperOnlyIdentityScenario(joinPath(baseRoot, "helper-only-identity"))
        print("PASS helper-only-identity-rejected -> " .. runScenario(ctx, TENTHFU.assertHelperOnlyIdentityScenario))
    end

    do
        local ctx = TENTHFU.createDuplicateJsonKeyScenario(joinPath(baseRoot, "duplicate-json-key"))
        print("PASS duplicate-identical-json-key-rejected -> " .. runScenario(ctx, TENTHFU.assertDuplicateJsonKeyScenario))
    end

    do
        local ctx = TENTHFU.createControlCharacterJsonScenario(joinPath(baseRoot, "control-character-json"))
        print("PASS invalid-control-character-json-rejected -> " .. runScenario(ctx, TENTHFU.assertControlCharacterJsonScenario))
    end

    do
        local ctx = TENTHFU.createDirectKitRealHelperSuccessScenario(joinPath(baseRoot, "direct-kit-real-helper-success"))
        print("PASS direct-kit-real-top-level-helper-success -> " .. runScenario(ctx, TENTHFU.assertDirectKitRealHelperSuccessScenario))
    end

    do
        local ctx = TENTHFU.createDirectKitRealHelperConflictScenario(joinPath(baseRoot, "direct-kit-real-helper-conflict"))
        print("PASS direct-kit-real-top-level-helper-conflict -> " .. runScenario(ctx, TENTHFU.assertDirectKitRealHelperConflictScenario))
    end

    do
        local ctx = TENTHFU.createKitSplitRealNestedHelperSuccessScenario(joinPath(baseRoot, "kit-split-real-nested-helper-success"))
        print("PASS kit-split-real-nested-helper-success -> " .. runScenario(ctx, TENTHFU.assertKitSplitRealNestedHelperSuccessScenario))
    end

    do
        local ctx = TENTHFU.createKitSplitRealNestedHelperConflictScenario(joinPath(baseRoot, "kit-split-real-nested-helper-conflict"))
        print("PASS kit-split-real-nested-helper-conflict -> " .. runScenario(ctx, TENTHFU.assertKitSplitRealNestedHelperConflictScenario))
    end

    do
        local ctx = TENTHFU.createPhysicalRunDirBindingScenario(joinPath(baseRoot, "physical-run-dir-binding"))
        print("PASS physical-run-dir-binding-b-cannot-become-current -> " .. runScenario(ctx, TENTHFU.assertPhysicalRunDirBindingScenario))
    end

    do
        local ctx = TENTHFU.createDirectKitPersistedHelperConflictScenario(joinPath(baseRoot, "direct-kit-persisted-helper-conflict"))
        print("PASS direct-kit-persisted-helper-conflict-via-real-persistence -> " .. runScenario(ctx, TENTHFU.assertDirectKitPersistedHelperConflictScenario))
    end

    do
        local ctx = TENTHFU.createDirectKitPersistedHelperMatchScenario(joinPath(baseRoot, "direct-kit-persisted-helper-match"))
        print("PASS direct-kit-persisted-helper-match-via-real-persistence -> " .. runScenario(ctx, TENTHFU.assertDirectKitPersistedHelperMatchScenario))
    end

    print("All headless support bundle tests passed.")
end

local ok, err = pcall(main)
ENV_OVERRIDES = nil
COMMAND_INTERCEPTOR = nil
if not ok then
    io.stderr:write("Headless support bundle test failed: " .. tostring(err) .. "\n")
    os.exit(1)
end
