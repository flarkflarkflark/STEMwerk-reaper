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
    -- Bootstrap/capabilities are untouched (still healthy: STATUS=ok,
    -- RUNTIME_VERIFY_DETAIL=ok), but the optional fixed six-phase
    -- acceptance-evidence tree was never collected for this session.
    removeTree(joinPath(context.extState.runtimeBase, "evidence"))
    return context
end

local function assertHealthyNoAcceptancePhasesScenario(bundleDir)
    local manifest = readManifest(bundleDir)
    assertf(manifest:find("final_runtime_health:%s+ok") ~= nil,
        "healthy runtime with no acceptance-phase fixtures was reported as not_proven:\n" .. manifest)
    assertf(manifest:find("acceptance_phases_status:%s+not_collected") ~= nil,
        "0/6 acceptance phases was not labeled not_collected:\n" .. manifest)
    assertf(manifest:find("phases_included:%s+0") ~= nil, "expected 0 phases included:\n" .. manifest)
    assertf(manifest:find("manifest_status:%s+complete") ~= nil,
        "missing OPTIONAL acceptance-phase fixtures alone flipped manifest_status to warning:\n" .. manifest)
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

    print("All headless support bundle tests passed.")
end

local ok, err = pcall(main)
ENV_OVERRIDES = nil
COMMAND_INTERCEPTOR = nil
if not ok then
    io.stderr:write("Headless support bundle test failed: " .. tostring(err) .. "\n")
    os.exit(1)
end
