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
        "input=" .. joinPath(tempDir, "input.wav"),
        "source=" .. mediaBase,
        "project=" .. projectPath,
        "",
    }, "\n"))
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
    assertf(fileExists(joinPath(bundleDir, "temp_inventory.txt")), "temp_inventory.txt missing")
    assertf(fileExists(joinPath(bundleDir, "runtime_state", "bootstrap.env")), "bootstrap.env not copied")
    assertf(fileExists(joinPath(bundleDir, "runtime_state", "capabilities.env")), "capabilities.env not copied")
    assertf(fileExists(joinPath(bundleDir, "runtime_logs", "bootstrap.log")), "bootstrap.log not copied")
    assertf(fileExists(joinPath(bundleDir, "temp_logs", "STEMwerk_fake_present", "separation_log.txt")), "temp separation log not copied")
    assertf(fileExists(joinPath(bundleDir, "temp_logs", "STEMwerk_fake_present", "stdout.txt")), "temp stdout log not copied")

    local diagnostics = readFile(joinPath(bundleDir, "diagnostics.txt")) or ""
    local pythonDiagnostics = readFile(joinPath(bundleDir, "python_diagnostics.txt")) or ""
    local tempInventory = readFile(joinPath(bundleDir, "temp_inventory.txt")) or ""
    local allText = readBundleText(bundleDir)

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
    assertf(fileExists(joinPath(bundleDir, "temp_inventory.txt")), "temp_inventory.txt missing")

    local diagnostics = readFile(joinPath(bundleDir, "diagnostics.txt")) or ""
    local pythonDiagnostics = readFile(joinPath(bundleDir, "python_diagnostics.txt")) or ""

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

    assertNoForbiddenFiles(bundleDir)
    assertMaxFileSize(bundleDir, 1024 * 1024)
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
    print("PASS present-runtime -> " .. presentBundle)

    waitNextSecond()

    local missing = createMissingScenario(baseRoot)
    local missingBundle = runScenario(missing, assertMissingScenario)
    print("PASS missing-runtime -> " .. missingBundle)

    print("All headless support bundle tests passed.")
end

local ok, err = pcall(main)
ENV_OVERRIDES = nil
COMMAND_INTERCEPTOR = nil
if not ok then
    io.stderr:write("Headless support bundle test failed: " .. tostring(err) .. "\n")
    os.exit(1)
end
