-- @description STEMwerk: Setup (internal)
-- @author flarkAUDIO <flarkaudio@pm.me>
-- @version 2.2.2.2.2
-- @changelog
--   2026-03-15: Added live Linux setup status window and stricter post-bootstrap verification.
-- @link Repository https://github.com/flarkflarkflark/STEMwerk
--
-- TODO(v2.2.2.3+):
-- - Expand language support beyond EN/NL/DE.
-- - Target additional languages: Chinese, Russian, Spanish, French, Portuguese,
--   Korean, Italian, Finnish, Vietnamese.
-- - Make STEMwerk Setup window multilingual.
-- - Add/use setup language selector.
-- - Persist selected setup language via ExtState("STEMwerk", "language").
-- - Keep main UI, setup UI, support-bundle/status messages, and first-run flow
--   on the same language setting.
-- - Use EN as default/fallback when unset or unknown.

local EXT_SECTION = "STEMwerk"
local BOOTSTRAP_GUARD_STALE_SECONDS = 600
local BOOTSTRAP_GUARD_STARTUP_GRACE_SECONDS = 8

local function msgBox(title, text, type)
    return reaper.ShowMessageBox(tostring(text), tostring(title), type or 0)
end

local function openActionList()
    if reaper and reaper.Main_OnCommand then
        reaper.Main_OnCommand(40605, 0)
        return true
    end
    msgBox(
        "STEMwerk Setup",
        "Open the REAPER Action List via: Actions -> Show action list",
        0
    )
    return false
end

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

-- Forward-declare shared helpers before any setup action closures use them.
-- Lua resolves locals lexically at function definition time; without these,
-- early functions such as runSupportBundleAction can accidentally resolve a
-- helper as a global and crash later (for example: global 'fileExists').
local fileExists
local pathExists
local ensureDir
local quoteArg
local execProcess
local trim
local showDeferredFinalWindow

local function setupPlatformLabel()
    if OS == "Windows" then return "Windows" end
    if OS == "macOS" then return "macOS" end
    return "Linux"
end

local function readSetupScriptVersion()
    local info = debug.getinfo(1, "S")
    local source = (info and info.source) or ""
    local path = source:match("^@(.*)$")
    if not path or path == "" then
        return ""
    end
    local f = io.open(path, "r")
    if not f then
        return ""
    end
    for _ = 1, 40 do
        local line = f:read("*l")
        if not line then break end
        local version = line:match("^%-%-%s*@version%s+([%w%._%-]+)")
        if version and version ~= "" then
            f:close()
            return version
        end
    end
    f:close()
    return ""
end

local SETUP_VERSION = readSetupScriptVersion()

local function setupWindowTitle(platformLabel)
    local title = "STEMwerk Setup"
    if platformLabel and platformLabel ~= "" then
        title = title .. " [" .. tostring(platformLabel) .. "]"
    end
    if SETUP_VERSION ~= "" then
        title = title .. " (v" .. SETUP_VERSION .. ")"
    end
    return title
end

local function getScriptDir()
    local info = debug.getinfo(1, "S")
    return (info and info.source and info.source:match("@?(.*[/\\])")) or ""
end

local RAW_SCRIPT_DIR = getScriptDir()
local PATH_HELPER = nil
local linuxEnvPrefix
local appendLogLine
local helperOk, helperMod = pcall(dofile, RAW_SCRIPT_DIR .. "STEMwerk_Path_Helper.lua")
if helperOk and type(helperMod) == "table" then
    PATH_HELPER = helperMod
end
local INSTALL = PATH_HELPER and PATH_HELPER.resolveInstallRoot(RAW_SCRIPT_DIR, { os = OS }) or {
    ok = true,
    root = RAW_SCRIPT_DIR,
    actual = RAW_SCRIPT_DIR,
    scriptsDir = RAW_SCRIPT_DIR,
    canonicalMismatch = false,
    canonical = "",
}

local function warnInstallMismatch()
    if not INSTALL.ok then
        return
    end
    if not INSTALL.canonicalMismatch or INSTALL.canonical == "" then
        return
    end
    msgBox(
        "STEMwerk Setup",
        "STEMwerk is not installed in the canonical REAPER Scripts path.\n\n"
            .. "Preferred:\n" .. tostring(INSTALL.canonical or "(unknown)") .. "\n\n"
            .. "Current runtime install:\n" .. tostring(INSTALL.root or RAW_SCRIPT_DIR) .. "\n\n"
            .. "Setup uses this actual location for bootstrap resolution.",
        0
    )
end

if not INSTALL.ok then
    msgBox(
        "STEMwerk Setup",
        "STEMwerk runtime location could not be resolved.\n\nReinstall STEMwerk and run STEMwerk-SETUP.lua from REAPER.",
        0
    )
    return
end

local INSTALL_ROOT = INSTALL.root or RAW_SCRIPT_DIR
local SCRIPT_DIR = INSTALL.scriptsDir or RAW_SCRIPT_DIR
warnInstallMismatch()

local function resolveSetupScriptsDir()
    if SCRIPT_DIR and SCRIPT_DIR ~= "" then
        return SCRIPT_DIR
    end
    local info = debug.getinfo(1, "S")
    local source = (info and info.source) or ""
    local currentPath = source:match("^@(.*)$") or source:match("^(.*)$") or ""
    local currentDir = currentPath:match("^(.*[/\\])") or ""
    if currentDir == "" then
        local _, actionPath = reaper.get_action_context()
        currentDir = (actionPath and actionPath:match("^(.*[/\\])")) or ""
    end
    local setupDir = currentDir
    if setupDir:match("[/\\]_internal[/\\]$") then
        setupDir = setupDir:gsub("[/\\]_internal[/\\]$", PATH_SEP)
    end
    return setupDir
end

local function launchMainStemwerkScript()
    local scriptsDir = resolveSetupScriptsDir()
    local mainScript = tostring(scriptsDir or "") .. "STEMwerk.lua"
    local exists = false
    do
        local f = io.open(mainScript, "r")
        if f then
            f:close()
            exists = true
        end
    end
    if not exists then
        msgBox(
            "STEMwerk Setup",
            "Could not find main script:\n\n" .. tostring(mainScript) .. "\n\nRun STEMwerk.lua manually from the REAPER Action List.",
            0
        )
        return false
    end
    local ok, err = pcall(dofile, mainScript)
    if not ok then
        msgBox(
            "STEMwerk Setup",
            "Could not open STEMwerk.lua automatically.\n\nError:\n" .. tostring(err) .. "\n\nRun STEMwerk.lua manually from the REAPER Action List.",
            0
        )
        return false
    end
    return true
end

local function runSupportBundleAction()
    local scriptsDir = resolveSetupScriptsDir()
    local supportScript = tostring(scriptsDir or "") .. "STEMwerk_Save_Support_Bundle.lua"
    if not fileExists(supportScript) then
        msgBox(
            "STEMwerk Setup",
            "Missing support bundle script:\n\n" .. tostring(supportScript) .. "\n\nReinstall STEMwerk.",
            0
        )
        return false
    end
    local ok, err = pcall(dofile, supportScript)
    if not ok then
        msgBox(
            "STEMwerk Setup",
            "Could not create the STEMwerk support bundle.\n\nError:\n" .. tostring(err),
            0
        )
        return false
    end
    return true
end

local function runSetFfmpegPathAction()
    local scriptsDir = resolveSetupScriptsDir()
    local ffmpegScript = tostring(scriptsDir or "") .. "STEMwerk_Set_FFmpegPath.lua"
    if not fileExists(ffmpegScript) then
        msgBox(
            "STEMwerk Setup",
            "Missing FFmpeg path script:\n\n" .. tostring(ffmpegScript) .. "\n\nReinstall STEMwerk.",
            0
        )
        return false
    end
    local ok, err = pcall(dofile, ffmpegScript)
    if not ok then
        msgBox(
            "STEMwerk Setup",
            "Could not open FFmpeg path setup.\n\nError:\n" .. tostring(err),
            0
        )
        return false
    end
    return true
end

quoteArg = function(s)
    s = tostring(s)
    if s:find('"') then
        s = s:gsub('"', '\\"')
    end
    if s:find("%s") then
        return '"' .. s .. '"'
    end
    return s
end

local function parseExecProcessResult(result)
    if type(result) ~= "string" then
        return nil, ""
    end
    local firstLine, rest = result:match("^([^\r\n]*)\r?\n?(.*)$")
    local rc = tonumber(firstLine)
    if rc == nil then
        return nil, result
    end
    return rc, rest or ""
end

local function exec(cmd, timeoutMs)
    timeoutMs = timeoutMs or 1200000
    if reaper and reaper.ExecProcess then
        local rc, out = parseExecProcessResult(reaper.ExecProcess(cmd, timeoutMs))
        return tonumber(rc) or -1, out or ""
    end
    local ok = os.execute(cmd)
    return (ok == true or ok == 0) and 0 or 1, ""
end

local function execCapture(cmd, timeoutMs)
    local rc, out = exec(cmd, timeoutMs or 20000)
    out = out or ""
    if out ~= "" then
        return rc, out
    end
    if OS == "Windows" then
        local wrapped = 'cmd.exe /d /c ' .. quoteArg(cmd .. ' 2>&1')
        local rc2, out2 = exec(wrapped, timeoutMs or 20000)
        out2 = out2 or ""
        if out2 ~= "" then
            return rc2, out2
        end
    end
    if OS ~= "Windows" then
        local h = io.popen(cmd .. " 2>&1")
        if h then
            local content = h:read("*a") or ""
            local ok, _, code = h:close()
            if ok == true then
                rc = 0
            elseif type(code) == "number" then
                rc = code
            end
            return rc, content
        end
    end
    return rc, out
end

execProcess = function(cmd, timeoutMs)
    return execCapture(cmd, timeoutMs or 20000)
end

local function probeOutputHasUsefulDevices(out)
    if not out or out == "" then return false end
    if out:find("STEMWERK_CUDA_DEVICE\t", 1, true) then return true end
    if out:find("STEMWERK_DML_DEVICE\t", 1, true) then return true end
    if out:find("STEMWERK_MPS_DEVICE\t", 1, true) then return true end
    if out:find("STEMWERK_SELECTED_DEVICE\tcuda:", 1, true) then return true end
    if out:find("STEMWERK_SELECTED_DEVICE\tdirectml", 1, true) then return true end
    if out:find("STEMWERK_SELECTED_DEVICE\tmps", 1, true) then return true end
    if out:match('"cuda_available"%s*:%s*true') then return true end
    if out:match('"cuda_count"%s*:%s*[1-9]%d*') then return true end
    if out:match('"directml_possible"%s*:%s*true') then return true end
    if out:match('"mps_available"%s*:%s*true') then return true end
    return false
end

local function directRuntimeDeviceProbe(pythonPath)
    if not pythonPath or pythonPath == "" or not fileExists(pythonPath) then
        return nil, nil
    end

    local py = [[
import json, importlib.util
env = {}
try:
    import torch
    env['torch'] = getattr(torch, '__version__', '')
    env['cuda_available'] = bool(torch.cuda.is_available())
    env['cuda_count'] = int(torch.cuda.device_count()) if env['cuda_available'] else 0
    env['cuda_names'] = [torch.cuda.get_device_name(i) for i in range(env['cuda_count'])] if env['cuda_available'] else []
    try:
        env['mps_available'] = bool(getattr(torch.backends, 'mps', None) is not None and torch.backends.mps.is_available())
    except Exception:
        env['mps_available'] = False
except Exception as e:
    env['torch_error'] = str(e)
    env['cuda_available'] = False
    env['cuda_count'] = 0
    env['cuda_names'] = []
    env['mps_available'] = False
env['directml_possible'] = importlib.util.find_spec('torch_directml') is not None
print('STEMWERK_ENV_JSON ' + json.dumps(env, ensure_ascii=False))
for i, n in enumerate(env.get('cuda_names', [])):
    print(f'STEMWERK_CUDA_DEVICE\tcuda:{i}\t{n}')
if env.get('mps_available'):
    print('STEMWERK_MPS_DEVICE\tmps\tApple MPS')
if env.get('directml_possible'):
    try:
        import torch_directml
        c = torch_directml.device_count()
        for i in range(c):
            print(f'STEMWERK_DML_DEVICE\tdirectml:{i}\tDirectML GPU {i}')
        if c == 1:
            print('STEMWERK_DML_ALIAS\tdirectml\tdirectml:0')
    except Exception:
        pass
]]

    local prefix = linuxEnvPrefix()
    local cmd = prefix .. quoteArg(pythonPath) .. " -c " .. quoteArg(py)
    local rc, out = execCapture(cmd, 30000)
    out = out or ""
    if out ~= "" then
        return out, rc
    end
    return nil, rc
end

fileExists = function(path)
    if not path or path == "" then return false end
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

pathExists = function(path)
    if not path or path == "" then return false end
    local ok = os.rename(path, path)
    if ok then return true end
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    return false
end

ensureDir = function(path)
    if not path or path == "" then return false end
    local quoted = quoteArg(path)
    if OS == "Windows" then
        os.execute("mkdir " .. quoted .. " 2>nul")
    else
        os.execute("mkdir -p " .. quoted .. " 2>/dev/null")
    end
    return true
end

local function ensureWritableDir(path)
    if not path or path == "" then return false end
    ensureDir(path)
    local testPath = path .. PATH_SEP .. ".stemwerk_write_test"
    local f = io.open(testPath, "w")
    if not f then return false end
    f:write("ok")
    f:close()
    os.remove(testPath)
    return true
end

local function getHome()
    if OS == "Windows" then
        return os.getenv("USERPROFILE") or "C:\\Users\\Default"
    end
    return os.getenv("HOME") or "/tmp"
end

local function getRuntimeBase()
    local override = reaper and reaper.GetExtState and reaper.GetExtState(EXT_SECTION, "runtimeBase") or ""
    if override ~= "" then
        return override
    end
    local home = getHome()
    local candidates = {}
    if OS == "Windows" then
        local localAppData = os.getenv("LOCALAPPDATA") or ""
        if localAppData ~= "" then
            table.insert(candidates, localAppData .. "\\STEMwerk")
        end
    elseif OS == "macOS" then
        table.insert(candidates, home .. "/Library/Application Support/STEMwerk")
    else
        local xdg = os.getenv("XDG_DATA_HOME") or ""
        if xdg ~= "" then
            table.insert(candidates, xdg .. "/STEMwerk")
        end
        table.insert(candidates, home .. "/.local/share/STEMwerk")
    end
    for _, base in ipairs(candidates) do
        if ensureWritableDir(base) then
            return base
        end
    end
    return candidates[1] or (home .. PATH_SEP .. ".STEMwerk")
end

local function getRuntimePaths()
    local base = getRuntimeBase()
    local runtimeRoot = base
    local runtimeState = base .. PATH_SEP .. "state"
    local runtimeLogs = base .. PATH_SEP .. "logs"
    local runtimeCache = base .. PATH_SEP .. "cache"
    local venvDir = base .. PATH_SEP .. ".venv"
    return {
        base = base,
        runtimeRoot = runtimeRoot,
        runtimeState = runtimeState,
        runtimeLogs = runtimeLogs,
        runtimeCache = runtimeCache,
        venvDir = venvDir,
        venvPython = OS == "Windows" and (venvDir .. "\\Scripts\\python.exe") or (venvDir .. "/bin/python"),
    }
end

local function getModelCacheDir()
    local home = getHome()
    if OS == "Windows" then
        local localAppData = os.getenv("LOCALAPPDATA") or ""
        if localAppData ~= "" then
            return localAppData .. "\\STEMwerk\\models"
        end
        return home .. "\\AppData\\Local\\STEMwerk\\models"
    elseif OS == "macOS" then
        return home .. "/Library/Application Support/STEMwerk/models"
    else
        local xdg = os.getenv("XDG_DATA_HOME") or ""
        if xdg ~= "" then
            return xdg .. "/STEMwerk/models"
        end
        return home .. "/.local/share/STEMwerk/models"
    end
end

local setExt
local getExt

local function runtimeLooksPresent(runtime)
    if not runtime or not runtime.base or runtime.base == "" then return false end
    local stateFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.env"
    local capFile = runtime.runtimeState .. PATH_SEP .. "capabilities.env"
    local modelDir = getModelCacheDir()
    return fileExists(runtime.venvPython)
        or pathExists(runtime.venvDir)
        or fileExists(stateFile)
        or fileExists(capFile)
        or pathExists(modelDir)
        or getExt("pythonPath") ~= ""
        or getExt("ffmpegPath") ~= ""
end

local function parseStateFile(path)
    local data = {}
    local f = io.open(path, "r")
    if not f then return data end
    for line in f:lines() do
        local key, value = line:match("^([A-Z0-9_]+)%s*=%s*(.*)$")
        if key and value then
            data[key] = value:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\r", "")
        end
    end
    f:close()
    return data
end

setExt = function(key, value)
    if reaper and reaper.SetExtState then
        reaper.SetExtState(EXT_SECTION, key, tostring(value), true)
    end
end

getExt = function(key)
    if reaper and reaper.GetExtState then
        return tostring(reaper.GetExtState(EXT_SECTION, key) or "")
    end
    return ""
end

trim = function(s)
    if s == nil then return "" end
    local t = tostring(s)
    t = t:gsub("^%s+", "")
    t = t:gsub("%s+$", "")
    return t
end

local function humanizeToken(token)
    local value = trim(token)
    if value == "" then return "" end
    value = value:gsub("_", " ")
    value = value:gsub("%s+", " ")
    value = value:gsub("^%l", string.upper)
    return value
end

local function prettySetupStatus(status)
    local lower = trim(status):lower()
    if lower == "" then return "Unknown" end
    if lower == "ok" then return "Completed" end
    if lower == "running" then return "Running" end
    if lower == "missing_python" then return "Missing Python" end
    if lower == "missing_ffmpeg" then return "Missing FFmpeg" end
    if lower == "deps_failed" then return "Dependency setup failed" end
    if lower == "venv_failed" then return "Virtual environment setup failed" end
    if lower == "pip_failed" then return "Pip setup failed" end
    if lower == "disabled" then return "Disabled" end
    if lower == "failed" then return "Failed" end
    return humanizeToken(status)
end

local function prettySetupReason(reason)
    if not reason or reason == "" then return "" end
    local parts = {}
    local seen = {}
    for raw in tostring(reason):gmatch("[^;]+") do
        local part = trim(raw)
        local lower = part:lower()
        if lower == "python_install_failed" then
            part = "Python install failed"
        elseif lower == "python_not_found" then
            part = "No supported Python found"
        elseif lower == "python_unsupported" or lower == "unsupported_python_version" then
            part = "System Python is unsupported. STEMwerk will use its managed Python runtime for Repair/Rebuild."
        elseif lower == "managed_python_unavailable" then
            part = "STEMwerk could not install its managed Python runtime. Install Python 3.10, 3.11, or 3.12 manually, then run Repair/Rebuild."
        elseif lower == "venv_create_failed" then
            part = "Could not create Python virtual environment"
        elseif lower == "pip_upgrade_failed" then
            part = "Could not upgrade pip/setuptools/wheel"
        elseif lower == "ffmpeg_install_failed" then
            part = "FFmpeg install failed"
        elseif lower == "ffmpeg_not_found" then
            part = "STEMwerk could not find FFmpeg"
        elseif lower == "ffmpeg_shim_path" then
            part = "Windows shim FFmpeg path detected (install a real ffmpeg.exe)"
        elseif lower == "stemwerk_core_bundle_incomplete" then
            part = "Bundled stemwerk-core package is incomplete"
        elseif lower == "stemwerk_core_install_failed" then
            part = "stemwerk-core install failed"
        elseif lower == "stemwerk_core_missing" or lower == "stemwerk_core_missing_after_setup" then
            part = "stemwerk-core is missing after setup"
        elseif lower == "audio_separator_install_failed" then
            part = "audio-separator install failed"
        elseif lower == "audio_separator_torch_unavailable" then
            part = "audio-separator install failed: PyTorch is unavailable for this macOS/Python/architecture combination"
        elseif lower == "audio_separator_torch_unavailable_macos_intel" then
            part = "audio-separator install failed: PyTorch is unavailable for this Intel macOS/Python combination (use the official STEMwerk runtime package or a supported macOS/Python combination)"
        elseif lower == "audio_runtime_deps_install_failed" then
            part = "Audio runtime dependencies install failed"
        elseif lower == "julius_install_failed" then
            part = "julius dependency install failed"
        elseif lower == "onnxruntime_install_failed" then
            part = "ONNX Runtime install failed"
        elseif lower == "onnxruntime_missing_after_setup" then
            part = "ONNX Runtime is missing after setup"
        elseif lower == "audio_separator_runtime_check_failed" then
            part = "audio-separator runtime verification failed"
        elseif lower == "audio_separator_missing_after_setup" then
            part = "audio-separator is missing after setup"
        elseif lower == "torch_pin_repair_failed" then
            part = "macOS Torch pin repair failed; run Rebuild venv/Repair to install the pinned torch stack"
        elseif lower == "torch_pin_assert_failed" then
            part = "Unsupported Torch runtime detected. STEMwerk 2.2.2.2.x requires the pinned Torch stack for Demucs/audio-separator 0.23. Run Repair/Rebuild to restore the supported runtime."
        elseif lower == "torch_too_new_for_demucs" or lower == "torch_runtime_unsupported" then
            part = "Unsupported Torch runtime detected. STEMwerk 2.2.2.2.x requires the pinned Torch stack for Demucs/audio-separator 0.23. Run Repair/Rebuild to restore the supported runtime."
        elseif lower == "torchaudio_missing_for_demucs" then
            part = "Incomplete Torch runtime detected: torchaudio is missing. Run Repair/Rebuild to restore the supported runtime."
        elseif lower == "backend_runtime_install_failed" then
            part = "GPU backend runtime install failed; CPU fallback used"
        elseif lower == "backend_runtime_verify_failed" then
            part = "GPU backend runtime verification failed; CPU fallback used"
        elseif lower == "backend_install_failed" then
            part = "Backend install failed; CPU fallback used"
        elseif lower == "backend_force_cpu" then
            part = "CPU fallback forced"
        elseif lower == "bootstrap_timeout" then
            part = "Bootstrap timed out"
        elseif lower == "bootstrap_process_exited" then
            part = "Bootstrap process exited unexpectedly"
        elseif lower == "launch_failed" then
            part = "Bootstrap launch failed"
        elseif lower == "missing_bootstrap" then
            part = "Bootstrap script is missing"
        elseif lower == "windows_installer_only" then
            part = "On Windows, setup is handled by the installer"
        elseif lower == "postbootstrap_failed" then
            part = "Post-bootstrap reporting step failed"
        elseif lower == "runtime_write_test_failed" then
            part = "Runtime directory write test failed"
        elseif lower == "execution_policy_restricted" then
            part = "PowerShell execution policy is restrictive for script execution"
        end
        local key = part:lower()
        if key ~= "" and not seen[key] then
            seen[key] = true
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "; ")
end

local function prettyCheckError(err)
    local lower = trim(err):lower()
    if lower == "" then return "" end
    if lower == "python_missing" then return "Python path is missing" end
    if lower == "python_unsupported" then return "System Python is unsupported. STEMwerk will use its managed Python runtime for Repair/Rebuild." end
    if lower == "python_unusable" then return "Python executable is unusable" end
    if lower == "ffmpeg_missing" then return "FFmpeg path is missing" end
    if lower == "ffmpeg_unusable" then return "FFmpeg executable is unusable" end
    if lower == "audio_separator_missing" then return "audio-separator runtime is missing" end
    if lower == "stemwerk_core_missing" then return "stemwerk-core package is missing" end
    if lower == "torch_too_new_for_demucs" or lower == "torch_runtime_unsupported" then
        return "Unsupported Torch runtime detected. STEMwerk 2.2.2.2.x requires the pinned Torch stack for Demucs/audio-separator 0.23. Run Repair/Rebuild to restore the supported runtime."
    end
    if lower == "torchaudio_missing_for_demucs" then
        return "Incomplete Torch runtime detected: torchaudio is missing. Run Repair/Rebuild to restore the supported runtime."
    end
    if lower == "numpy_too_new_for_demucs" then return "NumPy version is too new for bundled Demucs/audio-separator; run Rebuild venv/Repair" end
    if lower == "macos_demucs_runtime_incompatible" then return "macOS Demucs/audio-separator runtime check failed; run Rebuild venv/Repair" end
    return humanizeToken(err)
end

local function formatCheckErrors(errors)
    local out = {}
    local seen = {}
    for _, e in ipairs(errors or {}) do
        local label = prettyCheckError(e)
        local key = label:lower()
        if key ~= "" and not seen[key] then
            seen[key] = true
            out[#out + 1] = label
        end
    end
    if #out == 0 then
        return "none"
    end
    return table.concat(out, ", ")
end

local function extractLastLogLine(logLines)
    for i = #(logLines or {}), 1, -1 do
        local line = trim(logLines[i] or "")
        if line ~= "" then
            line = line:gsub("^STEMWERK_STATUS%s+detail=", "")
            line = line:gsub("^STEMWERK_STATUS%s+", "")
            if line ~= "" then
                return line
            end
        end
    end
    return ""
end

local function prettyBackendReason(reason)
    if not reason or reason == "" then return "" end
    local parts = {}
    local seen = {}
    for raw in tostring(reason):gmatch("[^;]+") do
        local part = trim(raw)
        local lower = part:lower()
        if lower == "device_probe_failed" then
            part = "No compatible GPU detected; using CPU"
        elseif lower == "backend_install_failed" then
            part = "Backend install failed; using CPU"
        elseif lower == "backend_force_cpu" then
            part = "CPU fallback forced"
        elseif lower == "python_unsupported" or lower == "unsupported_python_version" then
            part = "Unsupported Python version (need 3.10-3.12)"
        elseif lower == "python_not_found" then
            part = "No supported Python found (need 3.10-3.12)"
        elseif lower == "bootstrap_cuda_confirmed" then
            part = "CUDA runtime confirmed by installer"
        elseif lower == "bootstrap_directml_confirmed" then
            part = "DirectML runtime confirmed by installer"
        elseif lower == "mps_unavailable" then
            part = "MPS unavailable; using CPU"
        end
        local key = part:lower()
        if key ~= "" and not seen[key] then
            seen[key] = true
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "; ")
end

local function prettyBackendNote(note)
    local value = trim(note)
    if value == "" then return "" end
    local lower = value:lower()
    if lower == "non_official_rocm_distro" then
        return "ROCm was enabled on a non-official Linux distro. This can work, but it is outside AMD's officially supported distro list."
    end
    local text = value:gsub("_", " ")
    text = text:gsub("%s+", " ")
    text = text:gsub("^%l", string.upper)
    return text
end

local function formatStepStatus(state)
    local stepIndex = trim(state.STEP_INDEX or "")
    local stepTotal = trim(state.STEP_TOTAL or "")
    local stepLabel = trim(state.STEP_LABEL or "")
    if stepIndex == "" and stepTotal == "" and stepLabel == "" then return "" end

    local prefix = ""
    if stepIndex ~= "" and stepTotal ~= "" then
        prefix = "Step " .. stepIndex .. "/" .. stepTotal
    elseif stepIndex ~= "" then
        prefix = "Step " .. stepIndex
    end

    if prefix ~= "" and stepLabel ~= "" then
        return prefix .. ": " .. stepLabel
    end
    if prefix ~= "" then return prefix end
    return stepLabel
end

local function stripQuotes(s)
    s = trim(s)
    if s == "" then return "" end
    return (s:match('^"(.*)"$') or s:match("^'(.*)'$") or s):gsub("^%s*", ""):gsub("%s*$", "")
end

local function isAbsolutePath(path)
    if OS == "Windows" then
        return path:match("^[A-Za-z]:[\\/]") ~= nil
    end
    return path:match("^/") ~= nil
end

local function resolvePath(raw)
    local value = stripQuotes(raw)
    if value == "" then return "" end
    if isAbsolutePath(value) then return value end
    if value:find("[/\\]") then
        return getScriptDir() .. value
    end
    return value
end

linuxEnvPrefix = function()
    if OS ~= "Linux" then return "" end
    return "env -u HIP_VISIBLE_DEVICES -u HSA_OVERRIDE_GFX_VERSION -u ROCR_VISIBLE_DEVICES -u CUDA_VISIBLE_DEVICES "
end

local function runCommandWithProbe(path, suffix, expectPattern, timeoutMs)
    if not path or path == "" then return false end
    if not fileExists(path) then return false end

    local cmd = quoteArg(path) .. suffix
    if OS ~= "Linux" then
        local rc, out = exec(cmd, timeoutMs or 12000)
        if rc == 0 then
            return true
        end

        local h = io.popen(cmd .. " 2>&1")
        if not h then return false end
        local output = h:read("*a") or ""
        local ok, _, code = h:close()
        local combined = (out or "") .. "\n" .. output
        if expectPattern and combined:find(expectPattern, 1, true) then
            return true
        end
        if expectPattern == nil and ((ok == true) or (code == 0) or combined ~= "") then
            return true
        end
        return false
    end

    local h = io.popen(cmd .. " 2>&1")
    if not h then return false end
    local output = h:read("*a") or ""
    local ok, _, code = h:close()
    local combined = (out or "") .. "\n" .. output
    if expectPattern and combined:find(expectPattern, 1, true) then
        return true
    end
    if expectPattern == nil and ((ok == true) or (code == 0) or combined ~= "") then
        return true
    end
    return false
end

local function canRunPython(path)
    path = resolvePath(path)
    if not runCommandWithProbe(path, " --version", "Python", 15000) then
        return false
    end
    if OS == "Linux" or OS == "macOS" then
        local cmd = quoteArg(path) .. " -c " .. quoteArg("import sys; print('{}.{}.{}'.format(sys.version_info[0], sys.version_info[1], sys.version_info[2]))")
        local rc, out = execProcess(cmd, 12000)
        local major, minor = tostring(out or ""):match("(%d+)%.(%d+)")
        if tonumber(rc) ~= 0 or not major or not minor then
            return false
        end
        major = tonumber(major) or 0
        minor = tonumber(minor) or 0
        return major == 3 and minor >= 10 and minor <= 12
    end
    return true
end

local function canRunFfmpeg(path)
    path = resolvePath(path)
    return runCommandWithProbe(path, " -version", "ffmpeg version", 8000)
end

local function pythonVersionText(path)
    path = resolvePath(path)
    if path == "" or not fileExists(path) then return "" end
    local cmd = quoteArg(path) .. " -c " .. quoteArg("import platform; print(platform.python_version())")
    local rc, out = execProcess(cmd, 12000)
    if tonumber(rc) ~= 0 then return "" end
    return trim((out or ""):match("([0-9]+%.[0-9]+%.[0-9]+)") or (out or ""):match("([0-9]+%.[0-9]+)") or "")
end

local function checkPinnedTorchRuntime(path)
    path = resolvePath(path)
    local result = {
        ok = false,
        torchVersion = "",
        torchaudioVersion = "",
        torchSupported = "no",
        torchaudioPresent = "no",
        driftDetected = "yes",
        driftReason = "torch_runtime_probe_failed",
        error = "torch_runtime_unsupported",
    }
    if path == "" or not fileExists(path) then
        result.driftReason = "python_missing"
        return result
    end
    local script = [=[
import sys

def core(ver):
    return str(ver).split("+", 1)[0]

def parse_major_minor(ver):
    try:
        parts = core(ver).split(".")
        return int(parts[0]), int(parts[1])
    except Exception:
        return 999, 999

try:
    import torch
    torch_ver = core(getattr(torch, "__version__", ""))
except Exception as exc:
    print("TORCH_VERSION=")
    print("TORCHAUDIO_VERSION=")
    print("TORCH_SUPPORTED=no")
    print("TORCHAUDIO_PRESENT=no")
    print("RUNTIME_DRIFT_DETECTED=yes")
    print("RUNTIME_DRIFT_REASON=torch_import_failed")
    sys.exit(1)

try:
    import torchaudio
    torchaudio_ver = core(getattr(torchaudio, "__version__", ""))
    torchaudio_present = "yes"
except Exception:
    torchaudio_ver = "missing"
    torchaudio_present = "no"

try:
    import numpy
    numpy_ver = core(getattr(numpy, "__version__", "0.0.0"))
    numpy_major = int(numpy_ver.split(".", 1)[0])
except Exception:
    numpy_major = 0

major, minor = parse_major_minor(torch_ver)
torch_supported = (major, minor) < (2, 6)
reason = ""
if not torch_supported:
    reason = "torch_too_new_for_demucs"
elif torchaudio_present != "yes":
    reason = "torchaudio_missing_for_demucs"
elif numpy_major >= 2:
    reason = "numpy_too_new_for_demucs"

print("TORCH_VERSION=" + str(torch_ver))
print("TORCHAUDIO_VERSION=" + str(torchaudio_ver))
print("TORCH_SUPPORTED=" + ("yes" if torch_supported else "no"))
print("TORCHAUDIO_PRESENT=" + torchaudio_present)
print("RUNTIME_DRIFT_DETECTED=" + ("yes" if reason else "no"))
print("RUNTIME_DRIFT_REASON=" + reason)
sys.exit(0 if not reason else 1)
]=]
    local cmd = quoteArg(path) .. " -c " .. quoteArg(script)
    local rc, out = execProcess(cmd, 15000)
    local text = tostring(out or "")
    for line in text:gmatch("[^\r\n]+") do
        local k, v = line:match("^([A-Z0-9_]+)=(.*)$")
        if k == "TORCH_VERSION" then result.torchVersion = trim(v)
        elseif k == "TORCHAUDIO_VERSION" then result.torchaudioVersion = trim(v)
        elseif k == "TORCH_SUPPORTED" then result.torchSupported = trim(v)
        elseif k == "TORCHAUDIO_PRESENT" then result.torchaudioPresent = trim(v)
        elseif k == "RUNTIME_DRIFT_DETECTED" then result.driftDetected = trim(v)
        elseif k == "RUNTIME_DRIFT_REASON" then result.driftReason = trim(v)
        end
    end
    result.ok = tonumber(rc) == 0 and result.driftDetected == "no"
    if result.driftReason == "torchaudio_missing_for_demucs" then
        result.error = "torchaudio_missing_for_demucs"
    elseif result.driftReason == "torch_too_new_for_demucs" then
        result.error = "torch_too_new_for_demucs"
    elseif result.driftReason == "numpy_too_new_for_demucs" then
        result.error = "numpy_too_new_for_demucs"
    elseif result.ok then
        result.error = nil
    end
    return result
end

local function resolveUnixFfmpegFallback()
    for _, candidate in ipairs({
        getExt("ffmpegPath"),
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/opt/local/bin/ffmpeg",
        "/opt/homebrew/opt/ffmpeg/bin/ffmpeg",
        "/usr/local/opt/ffmpeg/bin/ffmpeg",
        "/usr/bin/ffmpeg",
        "/snap/bin/ffmpeg",
    }) do
        local resolved = resolvePath(candidate)
        if resolved ~= "" and fileExists(resolved) then
            return resolved
        end
    end
    return ""
end

local function canImportAudioSeparator(path)
    path = resolvePath(path)
    if not path or path == "" then return false end
    if not fileExists(path) then return false end
    local fullCmd = quoteArg(path) .. " -c " .. quoteArg("import audio_separator; import onnxruntime; from audio_separator.separator import Separator")
    if OS == "macOS" then
        local rc = select(1, exec(fullCmd, 15000))
        if rc == 0 then
            return true
        end
        local lightCmd = quoteArg(path) .. " -c " .. quoteArg("import audio_separator; import onnxruntime")
        local rc2 = select(1, exec(lightCmd, 15000))
        return rc2 == 0
    end
    if OS ~= "Linux" then
        local rc = select(1, exec(fullCmd, 15000))
        return rc == 0
    end
    local h = io.popen(fullCmd .. " 2>&1")
    if not h then return false end
    local output = h:read("*a") or ""
    local ok, _, code = h:close()
    if ok == true or code == 0 then
        return true
    end
    return (output ~= "")
end

local function canImportStemwerkCore(path)
    path = resolvePath(path)
    if not path or path == "" then return false end
    if not fileExists(path) then return false end
    local cmd = quoteArg(path) .. " -c " .. quoteArg("import stemwerk_core")
    if OS ~= "Linux" then
        local rc = select(1, exec(cmd, 15000))
        return rc == 0
    end
    local h = io.popen(cmd .. " 2>&1")
    if not h then return false end
    local output = h:read("*a") or ""
    local ok, _, code = h:close()
    if ok == true or code == 0 then
        return true
    end
    return (output ~= "")
end

local function canImportStemwerkCore(path)
    path = resolvePath(path)
    if not path or path == "" then return false end
    if not fileExists(path) then return false end
    local cmd = quoteArg(path) .. " -c " .. quoteArg("import stemwerk_core")
    if OS ~= "Linux" then
        local rc = select(1, exec(cmd, 15000))
        return rc == 0
    end
    local h = io.popen(cmd .. " 2>&1")
    if not h then return false end
    local output = h:read("*a") or ""
    local ok, _, code = h:close()
    if ok == true or code == 0 then
        return true
    end
    return (output ~= "")
end

local function readTail(path, maxLines)
    local lines = {}
    local max = maxLines or 20
    local f = io.open(path, "r")
    if not f then return lines end
    for line in f:lines() do
        if #lines >= max then
            table.remove(lines, 1)
        end
        lines[#lines + 1] = trim(line)
    end
    f:close()
    return lines
end

local function wrapLine(line, maxLen)
    if #line <= maxLen then return { line } end
    local out = {}
    local s = line
    while #s > maxLen do
        local chunk = s:sub(1, maxLen)
        local cut = chunk:match("^(.*)%s+[%w%p]*$")
        if cut and #cut > 0 then
            out[#out + 1] = cut
            s = s:sub(#cut + 1)
            s = s:gsub("^%s+", "")
        else
            out[#out + 1] = chunk
            s = s:sub(maxLen + 1)
        end
    end
    if s ~= "" then out[#out + 1] = s end
    return out
end

local function setLinuxLogLineColor(line)
    if not line then
        gfx.set(0.08, 0.08, 0.08, 1)
        return
    end
    if line:match("^STAGE:") then
        gfx.set(0.92, 0.45, 0.10, 1)
    elseif line:match("^STEP%s+1/%d+:") then
        gfx.set(1.0, 100 / 255, 100 / 255, 1)
    elseif line:match("^STEP%s+2/%d+:") then
        gfx.set(100 / 255, 200 / 255, 1.0, 1)
    elseif line:match("^STEP%s+3/%d+:") then
        gfx.set(150 / 255, 100 / 255, 1.0, 1)
    elseif line:match("^STEP%s+4/%d+:") then
        gfx.set(100 / 255, 1.0, 100 / 255, 1)
    elseif line:match("^STEP%s+%d+/%d+:") then
        gfx.set(0.40, 0.78, 1.0, 1)
    elseif line:match("^=+$") or line:match("^- rocminfo:") or line:match("^- rocm%-smi:") then
        gfx.set(0.50, 0.50, 0.50, 1)
    else
        gfx.set(0.82, 0.84, 0.87, 1)
    end
end

local function drawStemwerkTitleWindows(y, fontSize)
    local x = 18
    local letters = { "S", "T", "E", "M" }
    local colors = {
        { 255, 100, 100 },
        { 100, 200, 255 },
        { 150, 100, 255 },
        { 100, 255, 150 },
    }
    gfx.setfont(1, "Arial", fontSize)
    local xPos = x
    for i = 1, #letters do
        local c = colors[i]
        gfx.set(c[1] / 255, c[2] / 255, c[3] / 255, 1)
        gfx.x = xPos
        gfx.y = y
        gfx.drawstr(letters[i])
        xPos = xPos + gfx.measurestr(letters[i])
    end
    gfx.set(1, 1, 1, 1)
    gfx.x = xPos
    gfx.y = y
    gfx.drawstr("werk Setup [Windows]")
end

local function drawStemwerkInline(x, y, fontSize, prefix, suffix)
    local letters = { "S", "T", "E", "M" }
    local colors = {
        { 255, 100, 100 },
        { 100, 200, 255 },
        { 150, 100, 255 },
        { 100, 255, 150 },
    }
    gfx.setfont(1, "Arial", fontSize)
    gfx.set(1, 1, 1, 1)
    gfx.x = x
    gfx.y = y
    if prefix and prefix ~= "" then
        gfx.drawstr(prefix)
        x = x + gfx.measurestr(prefix)
    end
    for i = 1, #letters do
        local c = colors[i]
        gfx.set(c[1] / 255, c[2] / 255, c[3] / 255, 1)
        gfx.x = x
        gfx.y = y
        gfx.drawstr(letters[i])
        x = x + gfx.measurestr(letters[i])
    end
    gfx.set(1, 1, 1, 1)
    if suffix and suffix ~= "" then
        gfx.x = x
        gfx.y = y
        gfx.drawstr(suffix)
    end
end

local function probeRuntimeDevices(pythonPath, separatorScript)
    if not pythonPath or pythonPath == "" or not fileExists(pythonPath) then
        return nil, nil, "python_missing"
    end
    if not separatorScript or separatorScript == "" or not fileExists(separatorScript) then
        return nil, nil, "separator_missing"
    end

    local prefix = linuxEnvPrefix()
    local cmd1 = prefix .. quoteArg(pythonPath) .. " -u " .. quoteArg(separatorScript) .. " --list-devices-machine"
    local rc1, out1 = execCapture(cmd1, 30000)
    if probeOutputHasUsefulDevices(out1) then
        return out1, rc1, nil
    end

    local cmd2 = prefix .. quoteArg(pythonPath) .. " -u " .. quoteArg(separatorScript) .. " --list-devices"
    local rc2, out2 = execCapture(cmd2, 30000)
    if probeOutputHasUsefulDevices(out2) then
        return out2, rc2, nil
    end

    local out3, rc3 = directRuntimeDeviceProbe(pythonPath)
    if out3 and out3 ~= "" then
        return out3, rc3, nil
    end
    return nil, rc2 or rc1, "device_probe_failed"
end

local function extractEnvJson(deviceOut)
    if not deviceOut then return nil end
    for line in deviceOut:gmatch("[^\r\n]+") do
        if line:match("^STEMWERK_ENV_JSON%s+") then
            return line:gsub("^STEMWERK_ENV_JSON%s+", "")
        end
    end
    return nil
end

local function envJsonValue(envJson, key)
    if not envJson or envJson == "" then return "" end
    local s = envJson:match('"' .. key .. '"%s*:%s*"(.-)"')
    if s ~= nil then return s end
    local b = envJson:match('"' .. key .. '"%s*:%s*(true|false)')
    if b ~= nil then return b end
    local n = envJson:match('"' .. key .. '"%s*:%s*([%d%.%-]+)')
    if n ~= nil then return n end
    local null = envJson:match('"' .. key .. '"%s*:%s*(null)')
    if null ~= nil then return "null" end
    return ""
end

local function collectDeviceNames(deviceOut)
    if not deviceOut then return "" end
    local names = {}
    for line in deviceOut:gmatch("[^\r\n]+") do
        if line:match("^STEMWERK_DEVICE\t") then
            local _, name = line:match("^STEMWERK_DEVICE\t([^\t]*)\t([^\t]*)")
            if name and name ~= "" then
                names[#names + 1] = name
            end
        elseif line:match("^STEMWERK_CUDA_DEVICE\t") then
            local _, name = line:match("^STEMWERK_CUDA_DEVICE\t([^\t]*)\t(.*)$")
            if name and name ~= "" then
                names[#names + 1] = name
            end
        elseif line:match("^STEMWERK_DML_DEVICE\t") then
            local _, name = line:match("^STEMWERK_DML_DEVICE\t([^\t]*)\t(.*)$")
            if name and name ~= "" then
                names[#names + 1] = name
            end
        elseif line:match("^STEMWERK_MPS_DEVICE\t") then
            local _, name = line:match("^STEMWERK_MPS_DEVICE\t([^\t]*)\t(.*)$")
            if name and name ~= "" then
                names[#names + 1] = name
            end
        end
    end
    return table.concat(names, ", ")
end

local function detectBackendFromProbe(deviceOut, envJson)
    local cudaAvail = envJson and envJson:find('"cuda_available"%s*:%s*true') ~= nil
    local cudaCount = envJson and tonumber(envJson:match('"cuda_count"%s*:%s*(%d+)')) or 0
    local hasCuda = deviceOut and (
        deviceOut:find("cuda:")
        or deviceOut:find("STEMWERK_CUDA_DEVICE")
        or deviceOut:find("STEMWERK_TORCH_GPU")
        or deviceOut:find("STEMWERK_SELECTED_DEVICE\tcuda:")
    ) or false
    local hasMps = deviceOut and (deviceOut:find("STEMWERK_MPS_DEVICE") or deviceOut:find("\tmps\t")) or false
    local directmlPossible = envJson and envJson:find('"directml_possible"%s*:%s*true') ~= nil
    local hasDirectml = deviceOut and (
        deviceOut:find("directml")
        or deviceOut:find("STEMWERK_DML_DEVICE")
        or deviceOut:find("STEMWERK_SELECTED_DEVICE\tdirectml")
    ) or false
    local backend = "cpu"
    local reason = ""

    if not hasCuda and cudaAvail and cudaCount > 0 then
        hasCuda = true
    end

    if OS == "macOS" then
        if hasMps then
            backend = "metal"
        else
            reason = "mps_unavailable"
        end
    elseif OS == "Windows" then
        if hasCuda then
            backend = "cuda"
        elseif hasDirectml then
            backend = "directml"
        else
            reason = "no_gpu_detected"
        end
    else
        local hipPresent = envJson
            and envJson:find('"torch_hip"%s*:%s*[^n]')
            and not envJson:find('"torch_hip"%s*:%s*null')
            and not envJson:find('"torch_hip"%s*:%s*""')
        local cudaAvail = envJson and envJson:find('"cuda_available"%s*:%s*true') ~= nil
        local cudaCount = envJson and tonumber(envJson:match('"cuda_count"%s*:%s*(%d+)')) or 0
        local rocmHost = envJson and envJson:find('"rocm_path_exists"%s*:%s*true') ~= nil
        local rocmOk = hipPresent and cudaAvail and cudaCount > 0

        if rocmOk then
            backend = "rocm"
        elseif hasCuda then
            backend = "cuda"
        else
            if rocmHost then
                reason = "rocm_probe_failed"
            else
                reason = "no_gpu_detected"
            end
        end
    end

    if backend == "cpu" and envJson then
        if reason == "" then
            if OS == "Linux" and envJson:find('"cuda_available"%s*:%s*false') then
                reason = "cuda_unavailable"
            elseif OS == "macOS" and envJson:find('"mps_available"%s*:%s*false') then
                reason = "mps_unavailable"
            elseif OS == "Windows" and directmlPossible == false then
                reason = "directml_unavailable"
            end
        end
    end

    return backend, reason
end

local function profileForBackend(backend)
    backend = backend or "cpu"
    if OS == "Windows" then
        return "windows-" .. backend
    elseif OS == "macOS" then
        return "mac-" .. backend
    end
    return "linux-" .. backend
end

local function writeCapabilities(path, data, deviceOut)
    local f = io.open(path, "w")
    if not f then return false end
    f:write("CAP_VERSION=1\n")
    f:write("PROFILE=" .. tostring(data.profile or "") .. "\n")
    f:write("BACKEND=" .. tostring(data.backend or "") .. "\n")
    f:write("BACKEND_REASON=" .. tostring(data.backendReason or "") .. "\n")
    if data.backendNote and data.backendNote ~= "" then
        f:write("BACKEND_NOTE=" .. tostring(data.backendNote) .. "\n")
    end
    f:write("SUPPORTED_PYTHON_FOUND=" .. tostring(data.supportedPythonFound or "") .. "\n")
    f:write("DETECTED_PYTHON_VERSION=" .. tostring(data.detectedPythonVersion or "") .. "\n")
    f:write("SUPPORTED_PYTHON_RANGE=" .. tostring(data.supportedPythonRange or "") .. "\n")
    f:write("PYTHON_PATH=" .. tostring(data.pythonPath or "") .. "\n")
    f:write("FFMPEG_PATH=" .. tostring(data.ffmpegPath or "") .. "\n")
    f:write("RUNTIME_BASE=" .. tostring(data.runtimeBase or "") .. "\n")
    f:write("BOOTSTRAP_STATUS=" .. tostring(data.bootstrapStatus or "") .. "\n")
    f:write("BOOTSTRAP_REASON=" .. tostring(data.bootstrapReason or "") .. "\n")
    f:write("VERIFICATION=" .. tostring(data.verification or "") .. "\n")
    f:write("AUDIO_SEPARATOR=" .. tostring(data.audioSeparator or "") .. "\n")
    f:write("STEMWERK_CORE=" .. tostring(data.stemwerkCore or "") .. "\n")
    f:write("TORCH_VERSION=" .. tostring(data.torchVersion or "") .. "\n")
    f:write("TORCHAUDIO_VERSION=" .. tostring(data.torchaudioVersion or "") .. "\n")
    f:write("TORCH_SUPPORTED=" .. tostring(data.torchSupported or "") .. "\n")
    f:write("TORCHAUDIO_PRESENT=" .. tostring(data.torchaudioPresent or "") .. "\n")
    f:write("RUNTIME_DRIFT_DETECTED=" .. tostring(data.runtimeDriftDetected or "") .. "\n")
    f:write("RUNTIME_DRIFT_REASON=" .. tostring(data.runtimeDriftReason or "") .. "\n")
    f:write("DEVICE_NAMES=" .. tostring(data.deviceNames or "") .. "\n")
    if data.envJson and data.envJson ~= "" then
        f:write("ENV_JSON=" .. tostring(data.envJson) .. "\n")
    end
    if deviceOut and deviceOut ~= "" then
        f:write("DEVICES_OUTPUT_BEGIN\n")
        f:write(deviceOut)
        if deviceOut:sub(-1) ~= "\n" then
            f:write("\n")
        end
        f:write("DEVICES_OUTPUT_END\n")
    end
    f:close()
    return true
end

local function updateBootstrapEnv(path, kv)
    if not path or path == "" or type(kv) ~= "table" then return false end
    local lines = {}
    local seen = {}
    local f = io.open(path, "r")
    if f then
        for line in f:lines() do
            local key = line:match("^([A-Z0-9_]+)=")
            if key and kv[key] ~= nil then
                lines[#lines + 1] = key .. "=" .. tostring(kv[key])
                seen[key] = true
            else
                lines[#lines + 1] = line
            end
        end
        f:close()
    end
    for k, v in pairs(kv) do
        if not seen[k] then
            lines[#lines + 1] = k .. "=" .. tostring(v)
        end
    end
    local out = io.open(path, "w")
    if not out then return false end
    for _, line in ipairs(lines) do
        out:write(line .. "\n")
    end
    out:close()
    return true
end

local readBootstrapPid
local writeBootstrapGuard
local isProcessAlive
local safePerformPostBootstrap

local function psSingleQuote(value)
    local quoted = tostring(value or "")
    quoted = quoted:gsub("'", "''")
    return "'" .. quoted .. "'"
end

local function readBootstrapGuard(path)
    if not PATH_HELPER or not path or path == "" then
        return {}
    end
    local ok, data = pcall(PATH_HELPER.readEnvFile, path)
    if ok and type(data) == "table" then
        return data
    end
    return {}
end

local function inspectBootstrapGuard(guardPath, pidFile)
    local guard = readBootstrapGuard(guardPath)
    if guard.STATUS ~= "running" then
        return "idle", guard, nil, false
    end

    local pid = readBootstrapPid(pidFile)
    if not pid and guard.PID and guard.PID ~= "" then
        pid = tonumber(guard.PID) or tonumber(trim(guard.PID))
    end
    local pidAlive = pid and isProcessAlive(pid) or false
    if pid and pidAlive then
        return "running", guard, pid, true
    end
    if pid and not pidAlive then
        return "stale", guard, pid, false
    end

    local updatedAt = tonumber(guard.UPDATED_AT) or 0
    local age = updatedAt > 0 and (os.time() - updatedAt) or (BOOTSTRAP_GUARD_STALE_SECONDS + 1)
    if age <= BOOTSTRAP_GUARD_STARTUP_GRACE_SECONDS then
        return "starting", guard, pid, false
    end

    return "stale", guard, pid, false
end

local function isBootstrapBusy(guardPath, pidFile)
    local state, guard, pid = inspectBootstrapGuard(guardPath, pidFile)
    if state == "running" or state == "starting" then
        return true, tostring(guard.SCRIPT_PATH or ""), pid
    end
    if state == "stale" then
        return false, tostring(guard.SCRIPT_PATH or ""), pid, "stale"
    end
    return false, "", nil, "idle"
end

local function recoverStaleBootstrapGuard(guardPath, pidFile)
    local state, guard = inspectBootstrapGuard(guardPath, pidFile)
    if state ~= "stale" then
        return false
    end
    writeBootstrapGuard(
        guardPath,
        "failed",
        "stale_bootstrap_run",
        tostring(guard.SCRIPT_PATH or "")
    )
    return true
end

local function isWindowsProcessAlive(pid)
    if not pid then
        return false
    end
    local cmd = "tasklist /FI " .. quoteArg("PID eq " .. tostring(pid)) .. " /NH /FO CSV 2>nul"
    local h = io.popen(cmd)
    if not h then
        return false
    end
    local output = h:read("*a") or ""
    h:close()
    return output:find("," .. tostring(pid) .. ",", 1, true) ~= nil
        or output:find(',"' .. tostring(pid) .. '",', 1, true) ~= nil
end

isProcessAlive = function(pid)
    if OS == "Windows" then
        return isWindowsProcessAlive(pid)
    end
    local ok = os.execute("kill -0 " .. tostring(pid) .. " >/dev/null 2>&1")
    return (ok == true or ok == 0)
end

readBootstrapPid = function(pidFile)
    local f = io.open(pidFile, "r")
    if not f then
        return nil
    end
    local pidText = trim(f:read("*a") or "")
    f:close()
    local pid = tonumber(pidText)
    if pid then
        return pid
    end
    return nil
end

writeBootstrapGuard = function(guardPath, status, reason, scriptPath, pid)
    if not PATH_HELPER then return end
    PATH_HELPER.writeEnvFile(guardPath, {
        STATUS = status,
        REASON = reason,
        SCRIPT_PATH = scriptPath or "",
        UPDATED_AT = os.time(),
        PID = pid and tostring(pid) or "",
    })
end

local function showStatusWindow(stateFile, logFile, finalMessage)
    if not gfx then
        if finalMessage then
            msgBox("STEMwerk Setup", finalMessage, finalMessage:find("failed") and 16 or 0)
        end
        return
    end

    local state = parseStateFile(stateFile)
    local msg = finalMessage
    if not msg or msg == "" then
        local tail = readTail(logFile, 24)
        local lastLogLine = extractLastLogLine(tail)
        local lines = {
            "Setup status: " .. prettySetupStatus(state.STATUS or "unknown"),
        }
        if state.STATUS_REASON and state.STATUS_REASON ~= "" then
            lines[#lines + 1] = "Reason: " .. tostring(prettySetupReason(state.STATUS_REASON))
        end
        if lastLogLine ~= "" then
            lines[#lines + 1] = "Last log line: " .. tostring(lastLogLine)
        end
        if state.PYTHON_PATH or state.VENV_PYTHON then
            lines[#lines + 1] = "Python: " .. tostring(state.PYTHON_PATH or state.VENV_PYTHON or "")
        end
        if state.FFMPEG_PATH then
            lines[#lines + 1] = "FFmpeg: " .. tostring(state.FFMPEG_PATH or "")
        end
        lines[#lines + 1] = "Log: " .. tostring(logFile or "")
        msg = table.concat(lines, "\n")
    end
    msgBox("STEMwerk Setup", msg, (tostring(msg):find("failed") and 16) or 0)
end

local function waitForBootstrapState(stateFile, logFile, runtimeState)
    local pidFile = runtimeState .. PATH_SEP .. "bootstrap.pid"
    local started = os.time()
    local status
    local done = false
    while not done do
        status = parseStateFile(stateFile)
        if status.STATUS == "ok" or status.STATUS == "missing_python" or status.STATUS == "missing_ffmpeg" or status.STATUS == "deps_failed" or status.STATUS == "venv_failed" then
            done = true
            break
        end
        local pid = readBootstrapPid(pidFile)
        if pid then
            local ok = isProcessAlive(pid)
            if not ok then
                done = true
                break
            end
        end
        if os.time() - started > 1800 then
            done = true
            break
        end
        os.execute("sleep 0.2")
    end
    status = parseStateFile(stateFile)
    local final = (status.STATUS == "ok") or (status.STATUS == nil and status.PYTHON_PATH ~= nil and status.FFMPEG_PATH ~= nil)
    showStatusWindow(stateFile, logFile, final and "Bootstrap completed." or "Bootstrap failed.")
    return final, status
end

local function runBootstrap(runtime)
    local stateFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.env"
    local logFile = runtime.runtimeLogs .. PATH_SEP .. "bootstrap.log"
    ensureDir(runtime.runtimeState)
    ensureDir(runtime.runtimeLogs)

    if OS == "Windows" then
        return false, stateFile, logFile, {
            STATUS = "disabled",
            STATUS_REASON = "windows_installer_only",
        }
    end

    local scriptPath = PATH_HELPER.getBootstrapScriptPath(INSTALL_ROOT, OS, PATH_SEP)
    local cmd
    if OS == "macOS" then
        cmd = '/bin/sh ' .. quoteArg(scriptPath)
            .. " --runtime-base " .. quoteArg(runtime.base)
            .. " --state-file " .. quoteArg(stateFile)
            .. " --log-file " .. quoteArg(logFile)
    else
        cmd = '/bin/sh ' .. quoteArg(scriptPath)
            .. " --runtime-base " .. quoteArg(runtime.base)
            .. " --state-file " .. quoteArg(stateFile)
            .. " --log-file " .. quoteArg(logFile)
    end

    local guardPath = PATH_HELPER.getBootstrapGuardPath(runtime.runtimeState, PATH_SEP)
    if not fileExists(scriptPath) then
        PATH_HELPER.writeEnvFile(guardPath, {
            STATUS = "failed",
            REASON = "missing_bootstrap",
            SCRIPT_PATH = scriptPath,
            UPDATED_AT = os.time(),
        })
        msgBox("STEMwerk Setup", "Bootstrap script missing:\n\n" .. tostring(scriptPath), 0)
        return false, stateFile, logFile
    end

    PATH_HELPER.writeEnvFile(guardPath, {
        STATUS = "running",
        REASON = "launching",
        SCRIPT_PATH = scriptPath,
        UPDATED_AT = os.time(),
    })

    if OS == "Linux" then
        local pidFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.pid"
        local background = cmd .. " </dev/null >" .. quoteArg(logFile) .. " 2>&1 & echo $! > " .. quoteArg(pidFile)
        local launchRc = select(1, exec(background, 1800000))
        if launchRc ~= 0 then
            PATH_HELPER.writeEnvFile(guardPath, {
                STATUS = "failed",
                REASON = "launch_failed",
                SCRIPT_PATH = scriptPath,
                UPDATED_AT = os.time(),
            })
            return false, stateFile, logFile
        end
        local final, status = waitForBootstrapState(stateFile, logFile, runtime.runtimeState)
        PATH_HELPER.writeEnvFile(guardPath, {
            STATUS = final and "ok" or "failed",
            REASON = final and "completed" or "bootstrap_failed",
            SCRIPT_PATH = scriptPath,
            UPDATED_AT = os.time(),
        })
        return final, stateFile, logFile, status
    end

    local rc = select(1, exec(cmd, 1800000))
    if rc == 0 then
        local state = parseStateFile(stateFile)
        PATH_HELPER.writeEnvFile(guardPath, {
            STATUS = "ok",
            REASON = "completed",
            SCRIPT_PATH = scriptPath,
            UPDATED_AT = os.time(),
        })
        return true, stateFile, logFile, state
    end
    PATH_HELPER.writeEnvFile(guardPath, {
        STATUS = "failed",
        REASON = "launch_failed",
        SCRIPT_PATH = scriptPath,
        UPDATED_AT = os.time(),
    })
    return false, stateFile, logFile, parseStateFile(stateFile)
end

local function launchWindowsBootstrap(runtime, stateFile, logFile, scriptPath)
    -- Windows REAPER-side bootstrap is disabled; installer handles heavy setup.
    return false
end

local WINDOWS_SETUP = nil

local function windowsDrawStatus(state, logLines, pidAlive, pid)
    local w, h = gfx.w, gfx.h
    local lastLogLine = extractLastLogLine(logLines or {})
    gfx.set(0, 0, 0, 1)
    gfx.rect(0, 0, w, h, 1)
    gfx.set(1, 1, 1, 1)

    local y = 16
    drawStemwerkTitleWindows(y, 26)
    y = y + 30

    gfx.setfont(1, "Arial", 18)
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("Windows bootstrap in progress")
    y = y + 24
    gfx.setfont(1, "Arial", 18)
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("Phase: " .. ((state.STATUS == "running" or state.STATUS == "" or not state.STATUS) and "Bootstrapping" or "Finalizing"))
    y = y + 22

    local statusLine = "Status: " .. tostring(prettySetupStatus(state.STATUS or "running"))
    gfx.x = 18
    gfx.y = y
    gfx.drawstr(statusLine)
    y = y + 20
    if state.STATUS_REASON and state.STATUS_REASON ~= "" then
        gfx.x = 18
        gfx.y = y
        gfx.drawstr("Reason: " .. tostring(prettySetupReason(state.STATUS_REASON)))
        y = y + 20
    end
    if lastLogLine ~= "" then
        gfx.x = 18
        gfx.y = y
        gfx.drawstr("Last log: " .. tostring(lastLogLine))
        y = y + 20
    end

    gfx.x = 18
    gfx.y = y
    gfx.drawstr("Python: " .. tostring(state.PYTHON_PATH or state.VENV_PYTHON or ""))
    y = y + 20
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("FFmpeg: " .. tostring(state.FFMPEG_PATH or ""))
    y = y + 20
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("PID: " .. tostring(pid or "") .. " (alive: " .. tostring(pidAlive) .. ")")
    y = y + 20
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("Log: " .. tostring(WINDOWS_SETUP.logFile))
    y = y + 20
    gfx.x = 18
    gfx.y = y
    gfx.drawstr("Recent log lines (newest last):")
    y = y + 20

    gfx.setfont(1, "Courier New", 16)
    for _, line in ipairs(logLines) do
        local wrapped = wrapLine(line, 120)
        for _, wl in ipairs(wrapped) do
            gfx.x = 18
            gfx.y = y
            gfx.drawstr(wl)
            y = y + 18
        end
    end
end

local function drawWindowsFinal(finalLines, finalSuccess)
    local w, h = gfx.w, gfx.h
    gfx.set(0, 0, 0, 1)
    gfx.rect(0, 0, w, h, 1)
    gfx.set(1, 1, 1, 1)

    local y = 18
    drawStemwerkTitleWindows(y, 26)
    y = y + 30
    gfx.setfont(1, "Arial Bold", 28)
    gfx.x = 18
    gfx.y = y
    if finalSuccess then
        gfx.set(0.2, 0.9, 0.2, 1)
        local headline = "Setup complete — run STEMwerk.lua from the REAPER Action List"
        local wrapped = wrapLine(headline, 90)
        for _, wl in ipairs(wrapped) do
            gfx.drawstr(wl)
            y = y + 26
            gfx.x = 18
            gfx.y = y
        end
        y = y - 26
    else
        gfx.set(1.0, 0.4, 0.1, 1)
        gfx.drawstr("Setup was not completely successful.")
    end
    gfx.set(1, 1, 1, 1)
    y = y + 34

    gfx.setfont(1, "Arial", 18)
    local startIdx = 1
    if finalSuccess and finalLines and finalLines[1] == "Setup complete — run STEMwerk.lua from the REAPER Action List" then
        startIdx = 2
    elseif (not finalSuccess) and finalLines and finalLines[1] == "Setup was not completely successful." then
        startIdx = 2
    end
    for i = startIdx, #(finalLines or {}) do
        local line = finalLines[i]
        local wrapped = wrapLine(line, 120)
        for _, wl in ipairs(wrapped) do
            gfx.x = 18
            gfx.y = y
            gfx.drawstr(wl)
            y = y + 18
        end
    end

    gfx.setfont(1, "Arial", 14)
    gfx.x = 18
    gfx.y = h - 28
    gfx.drawstr("Press Esc or close this window to continue.")

    if WINDOWS_SETUP and finalSuccess then
        local btnW = 200
        local btnH = 26
        local btnY = h - 64
        WINDOWS_SETUP.buttons = {
            { label = "Open Action List", x = 18, y = btnY, w = btnW, h = btnH, action = "open_action_list" },
        }
        gfx.setfont(1, "Arial", 13)
        for _, b in ipairs(WINDOWS_SETUP.buttons) do
            drawButton(b.label, b.x, b.y, b.w, b.h)
        end
    end
end

local function finalizeWindowsSetup(result)
    if not WINDOWS_SETUP or not result then return end
    WINDOWS_SETUP.finalized = true
    local finalMessage = (type(result) == "table" and type(result.finalMessage) == "table") and result.finalMessage or {
        "Setup was not completely successful.",
        "Reason: invalid result payload."
    }
    WINDOWS_SETUP.finalMessage = finalMessage
    WINDOWS_SETUP.finalSuccess = result.success == true
    WINDOWS_SETUP.summaryText = table.concat(finalMessage, "\n")
    writeBootstrapGuard(
        WINDOWS_SETUP.guardPath,
        WINDOWS_SETUP.finalSuccess and "ok" or "failed",
        WINDOWS_SETUP.finalSuccess and "completed" or "bootstrap_failed",
        WINDOWS_SETUP.bootstrapScript,
        readBootstrapPid(WINDOWS_SETUP.pidFile)
    )
end

local function windowsSetupTick()
    if not WINDOWS_SETUP or not gfx then return end

    local state = parseStateFile(WINDOWS_SETUP.stateFile)
    local logLines = readTail(WINDOWS_SETUP.logFile, 32)
    local pid = readBootstrapPid(WINDOWS_SETUP.pidFile)
    local pidAlive = false
    if pid then
        pidAlive = isWindowsProcessAlive(pid)
    end

    if not WINDOWS_SETUP.finalized then
        local status = state.STATUS or ""
        local elapsed = os.time() - (WINDOWS_SETUP.startedAt or os.time())
        if status ~= "" and status ~= "running" then
            local result = safePerformPostBootstrap(WINDOWS_SETUP.runtime, WINDOWS_SETUP.stateFile, WINDOWS_SETUP.logFile, status == "ok", state, WINDOWS_SETUP.separatorScript)
            finalizeWindowsSetup(result)
        elseif status == "launch_failed" then
            local result = safePerformPostBootstrap(WINDOWS_SETUP.runtime, WINDOWS_SETUP.stateFile, WINDOWS_SETUP.logFile, false, state, WINDOWS_SETUP.separatorScript)
            finalizeWindowsSetup(result)
        elseif pid == nil and (status == "" or status == "running") and elapsed >= 5 then
            local result = safePerformPostBootstrap(WINDOWS_SETUP.runtime, WINDOWS_SETUP.stateFile, WINDOWS_SETUP.logFile, false, state, WINDOWS_SETUP.separatorScript)
            finalizeWindowsSetup(result)
        elseif pid ~= nil and not pidAlive and (status == "" or status == "running") and elapsed >= 5 then
            local stateDead = parseStateFile(WINDOWS_SETUP.stateFile)
            if stateDead.STATUS == "" or stateDead.STATUS == nil then
                stateDead.STATUS = "pid_dead"
                stateDead.STATUS_REASON = "bootstrap_process_exited"
            end
            local result = safePerformPostBootstrap(WINDOWS_SETUP.runtime, WINDOWS_SETUP.stateFile, WINDOWS_SETUP.logFile, false, stateDead, WINDOWS_SETUP.separatorScript)
            finalizeWindowsSetup(result)
        elseif elapsed >= 1800 then
            local stateTimeout = parseStateFile(WINDOWS_SETUP.stateFile)
            if stateTimeout.STATUS == "" or stateTimeout.STATUS == nil then
                stateTimeout.STATUS = "timeout"
                stateTimeout.STATUS_REASON = "bootstrap_timeout"
            end
            local result = safePerformPostBootstrap(WINDOWS_SETUP.runtime, WINDOWS_SETUP.stateFile, WINDOWS_SETUP.logFile, false, stateTimeout, WINDOWS_SETUP.separatorScript)
            finalizeWindowsSetup(result)
        end
    end

    if WINDOWS_SETUP.finalized then
        drawWindowsFinal(WINDOWS_SETUP.finalMessage, WINDOWS_SETUP.finalSuccess)
    else
        windowsDrawStatus(state, logLines, pidAlive, pid)
    end

    gfx.update()
    if WINDOWS_SETUP and WINDOWS_SETUP.finalized and WINDOWS_SETUP.buttons then
        local cap = gfx.mouse_cap
        local last = WINDOWS_SETUP.lastMouseCap or 0
        local clicked = (cap & 1) == 1 and (last & 1) == 0
        WINDOWS_SETUP.lastMouseCap = cap
        if clicked then
            for _, b in ipairs(WINDOWS_SETUP.buttons) do
                if isMouseIn(b.x, b.y, b.w, b.h) then
                    if b.action == "open_action_list" then
                        openActionList()
                    end
                    break
                end
            end
        end
    end
    local key = gfx.getchar()
    if key == 27 or key == -1 then
        if not WINDOWS_SETUP.finalized then
            writeBootstrapGuard(WINDOWS_SETUP.guardPath, "failed", "user_closed", WINDOWS_SETUP.bootstrapScript)
            if WINDOWS_SETUP.summaryText == "" then
                local result = safePerformPostBootstrap(
                    WINDOWS_SETUP.runtime,
                    WINDOWS_SETUP.stateFile,
                    WINDOWS_SETUP.logFile,
                    false,
                    parseStateFile(WINDOWS_SETUP.stateFile),
                    WINDOWS_SETUP.separatorScript
                )
                finalizeWindowsSetup(result)
            end
        end
        gfx.quit()
        WINDOWS_SETUP = nil
        return
    end

    reaper.defer(windowsSetupTick)
end

local function startWindowsSetup(runtime, separatorScript)
    msgBox(
        "STEMwerk Setup",
        "On Windows, setup runs in the installer.\n\n"
            .. "This REAPER script only verifies/repairs and will not launch bootstrap installers.\n\n"
            .. "Please re-run the Windows installer if setup is incomplete.",
        0
    )
    return
end

local function verifyRuntimePaths(state)
    state = state or {}
    local resolved = {
        pythonPath = resolvePath(state.PYTHON_PATH or state.VENV_PYTHON or ""),
        ffmpegPath = resolvePath(state.FFMPEG_PATH or ""),
    }
    local errors = {}
    local pythonOk = false
    local ffmpegOk = false
    local audioOk = false
    local torchRuntime = {
        ok = false,
        torchVersion = "",
        torchaudioVersion = "",
        torchSupported = "unknown",
        torchaudioPresent = "unknown",
        driftDetected = "unknown",
        driftReason = "",
    }
    local detectedPythonVersion = trim(state.DETECTED_PYTHON_VERSION or "")
    local supportedPythonFound = trim(state.SUPPORTED_PYTHON_FOUND or "")
    local supportedPythonRange = trim(state.SUPPORTED_PYTHON_RANGE or "")
    if supportedPythonRange == "" and (OS == "Linux" or OS == "macOS") then
        supportedPythonRange = "3.10-3.12"
    end

    if resolved.pythonPath == "" then
        if trim(state.STATUS_REASON or "") == "python_unsupported" then
            errors[#errors + 1] = "python_unsupported"
        else
            errors[#errors + 1] = "python_missing"
        end
    else
        detectedPythonVersion = detectedPythonVersion ~= "" and detectedPythonVersion or pythonVersionText(resolved.pythonPath)
        if canRunPython(resolved.pythonPath) then
            pythonOk = true
            supportedPythonFound = supportedPythonFound ~= "" and supportedPythonFound or "yes"
            setExt("pythonPath", resolved.pythonPath)
        else
            if (OS == "Linux" or OS == "macOS") and detectedPythonVersion ~= "" then
                errors[#errors + 1] = "python_unsupported"
                supportedPythonFound = "no"
            else
                errors[#errors + 1] = "python_unusable"
            end
        end
    end
    if supportedPythonFound == "" then
        supportedPythonFound = pythonOk and "yes" or "no"
    end

    if resolved.ffmpegPath == "" then
        errors[#errors + 1] = "ffmpeg_missing"
    else
        if canRunFfmpeg(resolved.ffmpegPath) then
            ffmpegOk = true
            setExt("ffmpegPath", resolved.ffmpegPath)
        else
            errors[#errors + 1] = "ffmpeg_unusable"
        end
    end

    if pythonOk and ffmpegOk and not canImportAudioSeparator(resolved.pythonPath) then
        errors[#errors + 1] = "audio_separator_missing"
        audioOk = false
    else
        audioOk = pythonOk and ffmpegOk
    end

    if pythonOk and ffmpegOk and not canImportStemwerkCore(resolved.pythonPath) then
        errors[#errors + 1] = "stemwerk_core_missing"
    end
    if pythonOk then
        torchRuntime = checkPinnedTorchRuntime(resolved.pythonPath)
        if not torchRuntime.ok and torchRuntime.error then
            errors[#errors + 1] = torchRuntime.error
        end
    end

    return {
        pythonPath = resolved.pythonPath,
        ffmpegPath = resolved.ffmpegPath,
        pythonOk = pythonOk,
        ffmpegOk = ffmpegOk,
        audioOk = audioOk,
        detectedPythonVersion = detectedPythonVersion,
        supportedPythonFound = supportedPythonFound,
        supportedPythonRange = supportedPythonRange,
        torchVersion = torchRuntime.torchVersion,
        torchaudioVersion = torchRuntime.torchaudioVersion,
        torchSupported = torchRuntime.torchSupported,
        torchaudioPresent = torchRuntime.torchaudioPresent,
        runtimeDriftDetected = torchRuntime.driftDetected,
        runtimeDriftReason = torchRuntime.driftReason,
        errors = errors,
    }
end

local function performPostBootstrap(runtime, stateFile, logFile, bootstrapSuccess, bootstrapState, separatorScript)
    local state = {}
    if type(bootstrapState) == "table" then
        for k, v in pairs(bootstrapState) do
            state[k] = v
        end
    end
    local latestState = parseStateFile(stateFile)
    if type(latestState) == "table" then
        for k, v in pairs(latestState) do
            if v ~= nil and v ~= "" then
                state[k] = v
            end
        end
    end

    if (not state.PYTHON_PATH or state.PYTHON_PATH == "") and (not state.VENV_PYTHON or state.VENV_PYTHON == "") then
        local extPythonPath = getExt("pythonPath")
        if extPythonPath ~= "" then
            state.PYTHON_PATH = extPythonPath
        end
    end
    if OS == "macOS" then
        local venvPython = resolvePath(state.VENV_PYTHON or "")
        if venvPython ~= "" and fileExists(venvPython) and canRunPython(venvPython) then
            state.PYTHON_PATH = venvPython
            updateBootstrapEnv(stateFile, { PYTHON_PATH = venvPython })
        end
    end
    if not state.FFMPEG_PATH or state.FFMPEG_PATH == "" then
        local extFfmpegPath = getExt("ffmpegPath")
        if extFfmpegPath ~= "" then
            state.FFMPEG_PATH = extFfmpegPath
        end
        if (not state.FFMPEG_PATH or state.FFMPEG_PATH == "") and OS ~= "Windows" then
            local autoFfmpegPath = resolveUnixFfmpegFallback()
            if autoFfmpegPath ~= "" then
                state.FFMPEG_PATH = autoFfmpegPath
            end
        end
    end

    if state.PYTHON_PATH and state.PYTHON_PATH ~= "" then
        setExt("pythonPath", state.PYTHON_PATH)
    elseif state.VENV_PYTHON and state.VENV_PYTHON ~= "" then
        setExt("pythonPath", state.VENV_PYTHON)
    end
    if state.FFMPEG_PATH and state.FFMPEG_PATH ~= "" then
        setExt("ffmpegPath", state.FFMPEG_PATH)
    end

    local verification = verifyRuntimePaths(state)
    local errors = verification.errors
    local verifiedRuntimeOk = verification.pythonOk and verification.ffmpegOk and #errors == 0
    local effectiveBootstrapSuccess = bootstrapSuccess or verifiedRuntimeOk

    if verifiedRuntimeOk and state.STATUS ~= "ok" then
        if appendLogLine then
            appendLogLine(logFile, "INFO: post-bootstrap verification succeeded; normalizing stale bootstrap state to ok")
        else
            local lf = io.open(logFile, "a")
            if lf then
                lf:write("INFO: post-bootstrap verification succeeded; normalizing stale bootstrap state to ok\n")
                lf:close()
            end
        end
        state.STATUS = "ok"
        state.STATUS_REASON = ""
    end

    local finalMessage = {}
    local failureClass = nil

    local deviceOut, probeRc, probeErr = probeRuntimeDevices(verification.pythonPath, separatorScript)
    local envJson = extractEnvJson(deviceOut or "")
    local deviceNames = collectDeviceNames(deviceOut or "")
    if OS == "Linux" then
        local torchVer = envJsonValue(envJson, "torch")
        local hipVer = envJsonValue(envJson, "torch_hip")
        local cudaAvail = envJsonValue(envJson, "cuda_available")
        local cudaCount = envJsonValue(envJson, "cuda_count")
        local lf = io.open(logFile, "a")
        if lf then
            lf:write(
                "CAP_PROBE torch=" .. tostring(torchVer)
                .. " hip=" .. tostring(hipVer)
                .. " cuda_available=" .. tostring(cudaAvail)
                .. " cuda_count=" .. tostring(cudaCount)
                .. " devices=" .. tostring(deviceNames)
                .. "\n"
            )
            lf:close()
        end
    end
    local backend, backendReason = detectBackendFromProbe(deviceOut, envJson)
    if probeErr and probeErr ~= "" then
        backendReason = probeErr
    end
    if OS == "Windows" and verifiedRuntimeOk and (probeErr == "device_probe_failed" or deviceOut == nil or deviceOut == "") then
        local bootstrapBackend = trim(state.BACKEND or "")
        local bootstrapProfile = trim(state.PROFILE or "")
        if bootstrapBackend == "cuda" and bootstrapProfile == "windows-cuda" then
            backend = "cuda"
            backendReason = "bootstrap_cuda_confirmed"
        elseif bootstrapBackend == "directml" and bootstrapProfile == "windows-directml" then
            backend = "directml"
            backendReason = "bootstrap_directml_confirmed"
        end
    end
    if OS == "Windows" and backend == "cpu" and verifiedRuntimeOk then
        local bootstrapBackend = trim(state.BACKEND or "")
        local bootstrapProfile = trim(state.PROFILE or "")
        local envCudaAvail = envJsonValue(envJson, "cuda_available") == "true"
        local envCudaCount = tonumber(envJsonValue(envJson, "cuda_count")) or 0
        local sawCudaRuntime = envCudaAvail or envCudaCount > 0
            or (deviceOut and (deviceOut:find("STEMWERK_TORCH_GPU\tcuda:") or deviceOut:find("STEMWERK_SELECTED_DEVICE\tcuda:")))
        local sawDirectMlRuntime = deviceOut and (
            deviceOut:find("STEMWERK_DEVICE\tdirectml")
            or deviceOut:find("STEMWERK_DML_DEVICE\tdirectml")
            or deviceOut:find("STEMWERK_SELECTED_DEVICE\tdirectml")
        )
        if bootstrapBackend == "cuda" and sawCudaRuntime then
            backend = "cuda"
            backendReason = "bootstrap_cuda_confirmed"
        elseif bootstrapBackend == "directml" and sawDirectMlRuntime and bootstrapProfile == "windows-directml" then
            backend = "directml"
            backendReason = "bootstrap_directml_confirmed"
        end
    end
    if state.BACKEND_REASON and state.BACKEND_REASON ~= "" then
        local priorBackend = trim(state.BACKEND or "")
        local sameBackend = (priorBackend == "") or (priorBackend == backend)
        if backend == "cpu" or sameBackend then
            if backendReason ~= "" then
                backendReason = backendReason .. "; " .. state.BACKEND_REASON
            else
                backendReason = state.BACKEND_REASON
            end
        end
    end
    local backendReasonLabel = prettyBackendReason(backendReason)
    local backendNote = state.BACKEND_NOTE and tostring(state.BACKEND_NOTE) or ""
    local backendNoteLabel = prettyBackendNote(backendNote)
    local profile = profileForBackend(backend)

    local function hasError(key)
        for _, e in ipairs(errors or {}) do
            if e == key then return true end
        end
        return false
    end
    local venvExists = runtime and runtime.venvPython and fileExists(runtime.venvPython)
    local audioStatus = "ok"
    local coreStatus = "ok"
    if not verification.pythonOk or not venvExists then
        audioStatus = venvExists and "not_checked" or "no_runtime"
        coreStatus = venvExists and "not_checked" or "no_runtime"
    else
        audioStatus = hasError("audio_separator_missing") and "missing" or "ok"
        coreStatus = hasError("stemwerk_core_missing") and "missing" or "ok"
    end
    local verificationStatus = (effectiveBootstrapSuccess and (state.STATUS == "ok" or state.STATUS == nil) and #errors == 0) and "ok" or "failed"

    ensureDir(runtime.runtimeState)
    local capPath = runtime.runtimeState .. PATH_SEP .. "capabilities.env"
    local wroteCaps = writeCapabilities(capPath, {
        profile = profile,
        backend = backend,
        backendReason = backendReason,
        backendNote = backendNote,
        supportedPythonFound = verification.supportedPythonFound,
        detectedPythonVersion = verification.detectedPythonVersion,
        supportedPythonRange = verification.supportedPythonRange,
        torchVersion = verification.torchVersion,
        torchaudioVersion = verification.torchaudioVersion,
        torchSupported = verification.torchSupported,
        torchaudioPresent = verification.torchaudioPresent,
        runtimeDriftDetected = verification.runtimeDriftDetected,
        runtimeDriftReason = verification.runtimeDriftReason,
        pythonPath = verification.pythonPath,
        ffmpegPath = verification.ffmpegPath,
        runtimeBase = runtime.base,
        bootstrapStatus = state.STATUS or "",
        bootstrapReason = state.STATUS_REASON or "",
        verification = verificationStatus,
        audioSeparator = audioStatus,
        stemwerkCore = coreStatus,
        deviceNames = deviceNames,
        envJson = envJson,
    }, deviceOut)
    if not wroteCaps then
        local lf = io.open(logFile, "a")
        if lf then
            lf:write("WARN: failed to write capabilities file: " .. tostring(capPath) .. "\n")
            lf:close()
        end
    end
    local syncKv = {
        PROFILE = profile or "",
        BACKEND = backend or "",
        BACKEND_REASON = backendReason or "",
        BACKEND_NOTE = backendNote or "",
        STEMWERK_SETUP_VERSION = SETUP_VERSION or "",
    }
    if verificationStatus == "ok" then
        syncKv.STATUS = "ok"
        syncKv.STATUS_REASON = ""
    end
    local synced = updateBootstrapEnv(stateFile, syncKv)
    if not synced then
        local lf = io.open(logFile, "a")
        if lf then
            lf:write("WARN: failed to sync bootstrap.env with capability profile/backend\n")
            lf:close()
        end
    end

    if (effectiveBootstrapSuccess and (state.STATUS == "ok" or state.STATUS == nil) and #errors == 0) then
        finalMessage[#finalMessage + 1] = "Setup complete — run STEMwerk.lua from the REAPER Action List"
        finalMessage[#finalMessage + 1] = ""
        finalMessage[#finalMessage + 1] = "Python path: " .. tostring(verification.pythonPath)
        finalMessage[#finalMessage + 1] = "FFmpeg path: " .. tostring(verification.ffmpegPath)
        finalMessage[#finalMessage + 1] = "Profile: " .. tostring(profile)
        finalMessage[#finalMessage + 1] = "Backend: " .. tostring(backend)
        if backendReasonLabel and backendReasonLabel ~= "" then
            finalMessage[#finalMessage + 1] = "Backend reason: " .. tostring(backendReasonLabel)
        end
        if backendNoteLabel ~= "" then
            finalMessage[#finalMessage + 1] = "Note: " .. tostring(backendNoteLabel)
        end
        if deviceNames and deviceNames ~= "" then
            finalMessage[#finalMessage + 1] = "Devices: " .. tostring(deviceNames)
        end
        finalMessage[#finalMessage + 1] = "Capabilities: " .. tostring(capPath)
        finalMessage[#finalMessage + 1] = "Log: " .. tostring(logFile)
        finalMessage[#finalMessage + 1] = ""
        return { success = true, finalMessage = finalMessage }
    end

    if state.STATUS and state.STATUS ~= "ok" then
        failureClass = "bootstrap_failed"
    else
        failureClass = "verification_failed"
    end

    finalMessage[#finalMessage + 1] = "Setup was not completely successful."
    finalMessage[#finalMessage + 1] = ""
    finalMessage[#finalMessage + 1] = "Status: " .. tostring(prettySetupStatus(state.STATUS or "unknown"))
    if state.STATUS_REASON and state.STATUS_REASON ~= "" then
        finalMessage[#finalMessage + 1] = "Reason: " .. tostring(prettySetupReason(state.STATUS_REASON))
    end
    finalMessage[#finalMessage + 1] = "Failure: " .. failureClass
    finalMessage[#finalMessage + 1] = "Checks: " .. formatCheckErrors(errors)
    if hasError("python_unsupported") or trim(state.STATUS_REASON or "") == "python_unsupported" then
        local detected = trim(verification.detectedPythonVersion or state.DETECTED_PYTHON_VERSION or "")
        finalMessage[#finalMessage + 1] = ""
        if detected ~= "" then
            finalMessage[#finalMessage + 1] = "System Python " .. detected .. " is unsupported. STEMwerk will use its managed Python runtime for Repair/Rebuild."
        else
            finalMessage[#finalMessage + 1] = "System Python is unsupported. STEMwerk will use its managed Python runtime for Repair/Rebuild."
        end
    end
    if hasError("torch_too_new_for_demucs") or hasError("torch_runtime_unsupported") then
        local torchVersion = trim(verification.torchVersion or "")
        finalMessage[#finalMessage + 1] = ""
        finalMessage[#finalMessage + 1] = "Unsupported Torch runtime detected: torch "
            .. (torchVersion ~= "" and torchVersion or "unknown")
            .. ". STEMwerk 2.2.2.2.x requires the pinned Torch stack for Demucs/audio-separator 0.23. Run Repair/Rebuild to restore the supported runtime."
    end
    if hasError("torchaudio_missing_for_demucs") then
        finalMessage[#finalMessage + 1] = ""
        finalMessage[#finalMessage + 1] = "Incomplete Torch runtime detected: torchaudio is missing. Run Repair/Rebuild to restore the supported runtime."
    end
    if hasError("ffmpeg_missing") or hasError("ffmpeg_unusable") or trim(state.STATUS or "") == "missing_ffmpeg" then
        finalMessage[#finalMessage + 1] = ""
        finalMessage[#finalMessage + 1] = "Missing FFmpeg"
        finalMessage[#finalMessage + 1] = "STEMwerk could not find FFmpeg."
        finalMessage[#finalMessage + 1] = ""
        finalMessage[#finalMessage + 1] = "Install FFmpeg with Homebrew:"
        finalMessage[#finalMessage + 1] = "  brew install ffmpeg"
        finalMessage[#finalMessage + 1] = "Already installed? Use Set FFmpeg Path."
    end
    finalMessage[#finalMessage + 1] = ""
    finalMessage[#finalMessage + 1] = "Python path: " .. tostring(verification.pythonPath)
    finalMessage[#finalMessage + 1] = "FFmpeg path: " .. tostring(verification.ffmpegPath)
    finalMessage[#finalMessage + 1] = "Profile: " .. tostring(profile)
    finalMessage[#finalMessage + 1] = "Backend: " .. tostring(backend)
    if backendReasonLabel and backendReasonLabel ~= "" then
        finalMessage[#finalMessage + 1] = "Backend reason: " .. tostring(backendReasonLabel)
    end
    if backendNoteLabel ~= "" then
        finalMessage[#finalMessage + 1] = "Note: " .. tostring(backendNoteLabel)
    end
    if deviceNames and deviceNames ~= "" then
        finalMessage[#finalMessage + 1] = "Devices: " .. tostring(deviceNames)
    end
    finalMessage[#finalMessage + 1] = "Capabilities: " .. tostring(capPath)
    finalMessage[#finalMessage + 1] = "Log: " .. tostring(logFile)
    finalMessage[#finalMessage + 1] = ""
    finalMessage[#finalMessage + 1] = "You can run setup again or fix paths manually."
    return { success = false, finalMessage = finalMessage }
end

safePerformPostBootstrap = function(runtime, stateFile, logFile, bootstrapSuccess, bootstrapState, separatorScript)
    local ok, result = pcall(performPostBootstrap, runtime, stateFile, logFile, bootstrapSuccess, bootstrapState, separatorScript)
    if ok and type(result) == "table" then
        return result
    end
    local state = type(bootstrapState) == "table" and bootstrapState or parseStateFile(stateFile)
    if type(state) ~= "table" then
        state = {}
    end
    local lf = io.open(logFile, "a")
    if lf then
        lf:write("WARN: performPostBootstrap failed, falling back to hard fail path.\n")
        if not ok and type(result) == "string" then
            lf:write("WARN: " .. tostring(result) .. "\n")
        end
        lf:close()
    end
    return {
        success = false,
        finalMessage = {
            "Setup was not completely successful.",
            "",
            "Status: " .. tostring(prettySetupStatus(state.STATUS or "unknown")),
            "Reason: " .. tostring(prettySetupReason("postbootstrap_failed")),
            "",
            "An internal setup reporting step failed.",
            "Please run STEMwerk-SETUP.lua again.",
        },
    }
end

appendLogLine = function(logFile, line)
    if not logFile or logFile == "" then return end
    local lf = io.open(logFile, "a")
    if not lf then return end
    lf:write(tostring(line or "") .. "\n")
    lf:close()
end

local function runPipInstall(pythonPath, package, logFile)
    if not pythonPath or pythonPath == "" or not package or package == "" then return false end
    local cmd = quoteArg(pythonPath) .. " -m pip install " .. package
    if logFile and logFile ~= "" then
        cmd = cmd .. " >> " .. quoteArg(logFile) .. " 2>&1"
    end
    local rc = select(1, exec(cmd, 180000))
    return rc == 0
end

local function isWindowsFfmpegShimPath(path)
    if not path or path == "" then return false end
    local p = tostring(path):lower()
    return p:find("\\microsoft\\winget\\links\\ffmpeg.exe", 1, true)
        or p:find("\\windowsapps\\ffmpeg", 1, true)
        or p:find("/microsoft/winget/links/ffmpeg.exe", 1, true)
        or p:find("/windowsapps/ffmpeg", 1, true)
end

local function summarizeInstallerState(state)
    local lines = {}
    if state and next(state) ~= nil then
        lines[#lines + 1] = "Installer status: " .. tostring(prettySetupStatus(state.STATUS or "unknown"))
        if state.STATUS_REASON and state.STATUS_REASON ~= "" then
            lines[#lines + 1] = "Installer reason: " .. tostring(prettySetupReason(state.STATUS_REASON))
        end
        if state.PYTHON_PATH and state.PYTHON_PATH ~= "" then
            lines[#lines + 1] = "Python: " .. tostring(state.PYTHON_PATH)
        end
        if state.FFMPEG_PATH and state.FFMPEG_PATH ~= "" and not isWindowsFfmpegShimPath(state.FFMPEG_PATH) then
            lines[#lines + 1] = "FFmpeg: " .. tostring(state.FFMPEG_PATH)
        end
    else
        lines[#lines + 1] = "Installer state not found. Please run the STEMwerk Setup Installer again."
    end
    return lines
end

local function isWindowsStorePythonPath(path)
    if not path or path == "" then return false end
    local p = tostring(path):lower()
    return p:find("\\microsoft\\windowsapps\\python", 1, true)
        or p:find("/microsoft/windowsapps/python", 1, true)
end

local function findWindowsPythonFallback()
    local h = io.popen("where python 2>nul")
    if not h then return "" end
    local out = h:read("*a") or ""
    h:close()
    for line in out:gmatch("[^\r\n]+") do
        local p = trim(line)
        if p ~= "" and fileExists(p) and not isWindowsStorePythonPath(p) then
            return p
        end
    end
    return ""
end

local function findWindowsRuntimeFfmpeg(runtime)
    local candidates = {
        runtime.base .. "\\ffmpeg\\bin\\ffmpeg.exe",
        runtime.base .. "\\ffmpeg\\ffmpeg.exe",
        runtime.base .. "\\bin\\ffmpeg.exe",
    }
    for _, p in ipairs(candidates) do
        if fileExists(p) then
            return p
        end
    end
    return ""
end

local function findWindowsFfmpegFallback(runtime)
    local runtimePath = findWindowsRuntimeFfmpeg(runtime)
    if runtimePath ~= "" then
        return runtimePath
    end
    local h = io.popen("where ffmpeg 2>nul")
    if not h then return "" end
    local out = h:read("*a") or ""
    h:close()
    for line in out:gmatch("[^\r\n]+") do
        local p = trim(line)
        if p ~= "" and fileExists(p) and not isWindowsFfmpegShimPath(p) then
            return p
        end
    end
    return ""
end
local function isValidFfmpegPath(path)
    return path ~= "" and fileExists(path) and not isWindowsFfmpegShimPath(path)
end

local WINDOWS_VERIFY = nil

local function drawWindowsVerify()
    if not WINDOWS_VERIFY or not gfx then return end
    local w, h = gfx.w, gfx.h
    gfx.set(0, 0, 0, 1)
    gfx.rect(0, 0, w, h, 1)
    gfx.set(1, 1, 1, 1)

    local y = 16
    drawStemwerkTitleWindows(y, 24)
    y = y + 30

    gfx.setfont(1, "Arial", 18)
    gfx.x = 18
    gfx.y = y
    if WINDOWS_VERIFY.finalized and WINDOWS_VERIFY.finalSuccess then
        gfx.set(0.2, 0.9, 0.2, 1)
    else
        gfx.set(1, 1, 1, 1)
    end
    gfx.drawstr(WINDOWS_VERIFY.title or "Verifying runtime...")
    gfx.set(1, 1, 1, 1)
    y = y + 24

    gfx.setfont(1, "Arial", 16)
    for _, line in ipairs(WINDOWS_VERIFY.statusLines or {}) do
        local wrapped = wrapLine(line, 120)
        for _, wl in ipairs(wrapped) do
            gfx.x = 18
            gfx.y = y
            gfx.drawstr(wl)
            y = y + 18
        end
    end

    if WINDOWS_VERIFY.finalized then
        gfx.setfont(1, "Arial", 14)
        gfx.x = 18
        gfx.y = h - 28
        gfx.drawstr("Press Esc or close this window to continue.")
    end
end

local function finalizeWindowsVerify(success, lines)
    if not WINDOWS_VERIFY then return end
    local runtime = WINDOWS_VERIFY.runtime
    local separatorScript = WINDOWS_VERIFY.separatorScript
    local stateFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.env"
    local logFile = runtime.runtimeLogs .. PATH_SEP .. "bootstrap.log"
    local finalLines = lines or WINDOWS_VERIFY.statusLines or {}
    if success and finalLines[1] == "Setup complete — run STEMwerk.lua from the REAPER Action List" then
        table.remove(finalLines, 1)
    end
    WINDOWS_VERIFY = nil
    reaper.defer(function()
        showDeferredFinalWindow(runtime, stateFile, logFile, finalLines, success == true, separatorScript, true)
    end)
end

local function windowsVerifyTick()
    if not WINDOWS_VERIFY or not gfx then return end

    drawWindowsVerify()
    gfx.update()

    local key = gfx.getchar()
    if key == 27 or key == -1 then
        gfx.quit()
        WINDOWS_VERIFY = nil
        return
    end

    if WINDOWS_VERIFY.finalized then
        reaper.defer(windowsVerifyTick)
        return
    end

    -- First frame drawn; begin stepwise checks on subsequent ticks
    local step = WINDOWS_VERIFY.step or 0
    if step == 0 then
        WINDOWS_VERIFY.step = 1
        reaper.defer(windowsVerifyTick)
        return
    end

    local runtime = WINDOWS_VERIFY.runtime
    local stateFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.env"
    local logFile = runtime.runtimeLogs .. PATH_SEP .. "bootstrap.log"

    if step == 1 then
        WINDOWS_VERIFY.statusLines = { "Reading installer state..." }
        WINDOWS_VERIFY.state = parseStateFile(stateFile)
        WINDOWS_VERIFY.hasState = (WINDOWS_VERIFY.state and next(WINDOWS_VERIFY.state) ~= nil)
        WINDOWS_VERIFY.step = 2
        reaper.defer(windowsVerifyTick)
        return
    end

    if step == 2 then
        WINDOWS_VERIFY.statusLines = { "Resolving Python path..." }
        local state = WINDOWS_VERIFY.state or {}
        local pythonPath = resolvePath((state.PYTHON_PATH and state.PYTHON_PATH ~= "" and state.PYTHON_PATH)
            or (state.VENV_PYTHON and state.VENV_PYTHON ~= "" and state.VENV_PYTHON)
            or runtime.venvPython)
        if pythonPath == "" or isWindowsStorePythonPath(pythonPath) then
            pythonPath = resolvePath(findWindowsPythonFallback())
        end
        WINDOWS_VERIFY.pythonPath = pythonPath
        WINDOWS_VERIFY.step = 3
        reaper.defer(windowsVerifyTick)
        return
    end

    if step == 3 then
        WINDOWS_VERIFY.statusLines = { "Resolving FFmpeg path..." }
        local state = WINDOWS_VERIFY.state or {}
        local ffmpegPath = ""
        local shimFound = ""

        -- 1) local runtime FFmpeg
        ffmpegPath = resolvePath(findWindowsRuntimeFfmpeg(runtime))
        if not isValidFfmpegPath(ffmpegPath) then
            ffmpegPath = ""
        end

        -- 2) bootstrap.env FFMPEG_PATH
        local statePath = resolvePath(state.FFMPEG_PATH or "")
        if statePath ~= "" and isWindowsFfmpegShimPath(statePath) then
            shimFound = statePath
            statePath = ""
            state.FFMPEG_PATH = ""
            updateBootstrapEnv(stateFile, { FFMPEG_PATH = "" })
        end
        if ffmpegPath == "" and isValidFfmpegPath(statePath) then
            ffmpegPath = statePath
        end

        -- 3) manual override (ExtState)
        local extPath = resolvePath(getExt("ffmpegPath"))
        if extPath ~= "" and isWindowsFfmpegShimPath(extPath) then
            if shimFound == "" then shimFound = extPath end
            extPath = ""
            setExt("ffmpegPath", "")
        end
        if ffmpegPath == "" and isValidFfmpegPath(extPath) then
            ffmpegPath = extPath
        end

        -- 4) PATH fallback (non-shim only)
        if ffmpegPath == "" then
            ffmpegPath = resolvePath(findWindowsFfmpegFallback(runtime))
            if ffmpegPath ~= "" and isWindowsFfmpegShimPath(ffmpegPath) then
                if shimFound == "" then shimFound = ffmpegPath end
                ffmpegPath = ""
            end
        end

        if shimFound ~= "" then
            WINDOWS_VERIFY.ffmpegShim = shimFound
        end
        if ffmpegPath == "" and shimFound ~= "" then
            state.STATUS = "missing_ffmpeg"
            state.STATUS_REASON = "ffmpeg_shim_path"
            updateBootstrapEnv(stateFile, {
                STATUS = "missing_ffmpeg",
                STATUS_REASON = "ffmpeg_shim_path",
                FFMPEG_PATH = "",
            })
        end

        WINDOWS_VERIFY.ffmpegPath = ffmpegPath
        WINDOWS_VERIFY.step = 4
        reaper.defer(windowsVerifyTick)
        return
    end

    if step == 4 then
        WINDOWS_VERIFY.statusLines = { "Checking Python..." }
        local pythonOk = WINDOWS_VERIFY.pythonPath ~= "" and fileExists(WINDOWS_VERIFY.pythonPath)
            and canRunPython(WINDOWS_VERIFY.pythonPath)
        WINDOWS_VERIFY.pythonOk = pythonOk
        WINDOWS_VERIFY.step = 5
        reaper.defer(windowsVerifyTick)
        return
    end

    if step == 5 then
        WINDOWS_VERIFY.statusLines = { "Checking FFmpeg..." }
        local ffmpegOk = WINDOWS_VERIFY.ffmpegPath ~= "" and fileExists(WINDOWS_VERIFY.ffmpegPath)
            and canRunFfmpeg(WINDOWS_VERIFY.ffmpegPath)
        WINDOWS_VERIFY.ffmpegOk = ffmpegOk
        WINDOWS_VERIFY.step = 6
        reaper.defer(windowsVerifyTick)
        return
    end

    if step == 6 then
        WINDOWS_VERIFY.statusLines = { "Checking stemwerk-core..." }
        local coreOk = false
        if WINDOWS_VERIFY.pythonOk then
            coreOk = canImportStemwerkCore(WINDOWS_VERIFY.pythonPath)
        end
        WINDOWS_VERIFY.coreOk = coreOk
        WINDOWS_VERIFY.step = 7
        reaper.defer(windowsVerifyTick)
        return
    end

    if step == 7 then
        WINDOWS_VERIFY.statusLines = { "Checking audio-separator..." }
        local sepOk = false
        if WINDOWS_VERIFY.pythonOk then
            sepOk = canImportAudioSeparator(WINDOWS_VERIFY.pythonPath)
        end
        WINDOWS_VERIFY.sepOk = sepOk
        WINDOWS_VERIFY.step = 8
        reaper.defer(windowsVerifyTick)
        return
    end

    if step == 8 then
        local state = WINDOWS_VERIFY.state or {}
        local lines = {}
        local ok = WINDOWS_VERIFY.pythonOk and WINDOWS_VERIFY.ffmpegOk and WINDOWS_VERIFY.coreOk and WINDOWS_VERIFY.sepOk
        local metadataComplete = WINDOWS_VERIFY.hasState and state.INSTALLER == "1"
        if ok then
            state.STATUS = "ok"
            state.STATUS_REASON = ""
            state.PYTHON_PATH = WINDOWS_VERIFY.pythonPath
            state.FFMPEG_PATH = WINDOWS_VERIFY.ffmpegPath
            updateBootstrapEnv(stateFile, {
                STATUS = "ok",
                STATUS_REASON = "",
                PYTHON_PATH = WINDOWS_VERIFY.pythonPath,
                FFMPEG_PATH = WINDOWS_VERIFY.ffmpegPath,
            })
            local result = safePerformPostBootstrap(runtime, stateFile, logFile, true, state, WINDOWS_VERIFY.separatorScript)
            if not metadataComplete then
                result.finalMessage[#result.finalMessage + 1] = ""
                result.finalMessage[#result.finalMessage + 1] = "Note: Installer metadata was incomplete, but runtime checks passed."
            end
            finalizeWindowsVerify(true, result.finalMessage)
            return
        end

        lines[#lines + 1] = "STEMwerk runtime is not ready yet."
        lines[#lines + 1] = ""
        for _, line in ipairs(summarizeInstallerState(state)) do
            lines[#lines + 1] = line
        end
        if WINDOWS_VERIFY.ffmpegShim and WINDOWS_VERIFY.ffmpegShim ~= "" then
            lines[#lines + 1] = ""
            lines[#lines + 1] = "Detected unsupported Windows FFmpeg shim:"
            lines[#lines + 1] = "  " .. tostring(WINDOWS_VERIFY.ffmpegShim)
        end
        lines[#lines + 1] = ""
        if not WINDOWS_VERIFY.pythonOk then
            lines[#lines + 1] = "Python runtime is missing or unusable. Please run the STEMwerk Setup Installer again."
            lines[#lines + 1] = "Manual/test ZIP installs require a working Python 3.11 (64-bit) runtime."
        elseif not WINDOWS_VERIFY.ffmpegOk then
            lines[#lines + 1] = "FFmpeg is missing."
            lines[#lines + 1] = "Install FFmpeg or re-run the installer, then re-run setup."
            if WINDOWS_VERIFY.ffmpegShim and WINDOWS_VERIFY.ffmpegShim ~= "" then
                lines[#lines + 1] = "Windows shim paths (WinGet/WindowsApps) are not supported."
            end
        elseif not WINDOWS_VERIFY.coreOk or not WINDOWS_VERIFY.sepOk then
            lines[#lines + 1] = "Dependencies are incomplete."
            lines[#lines + 1] = "Re-run the installer to repair the runtime."
        else
            lines[#lines + 1] = "Repair could not complete."
            lines[#lines + 1] = "Re-run the installer or check the log for details."
        end
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Log: " .. tostring(logFile)
        finalizeWindowsVerify(false, lines)
        return
    end
end

local function windowsVerifyStart(runtime, separatorScript, reuseWindow)
    ensureDir(runtime.runtimeState)
    ensureDir(runtime.runtimeLogs)
    if not reuseWindow then
        gfx.init(setupWindowTitle("Windows"), 900, 620, 0, 140, 100)
    end
    WINDOWS_VERIFY = {
        runtime = runtime,
        separatorScript = separatorScript,
        step = 0,
        statusLines = { "Starting verification..." },
        title = "Verifying runtime...",
        finalized = false,
        finalSuccess = false,
    }
    reaper.defer(windowsVerifyTick)
end

local function windowsVerifyRepair(runtime, separatorScript)
    windowsVerifyStart(runtime, separatorScript)
end

local LINUX_SETUP = nil
local SETUP_MENU = nil
local SETUP_MENU_DEFAULT_W = 1260
local SETUP_MENU_DEFAULT_H = 904
local LINUX_SETUP_FONT_SCALE_KEY = "linuxSetupFontScale"
local LINUX_SETUP_FONT_SCALE_DEFAULT = 1.0
local LINUX_SETUP_FONT_SCALE_MIN = 0.7
local LINUX_SETUP_FONT_SCALE_MAX = 3.0
local LINUX_SETUP_FONT_SCALE_STEP = 0.1

local function clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

local function getLinuxSetupFontScale()
    local raw = tonumber(getExt(LINUX_SETUP_FONT_SCALE_KEY) or "")
    if not raw then return LINUX_SETUP_FONT_SCALE_DEFAULT end
    return clamp(raw, LINUX_SETUP_FONT_SCALE_MIN, LINUX_SETUP_FONT_SCALE_MAX)
end

local function saveLinuxSetupFontScale(scale)
    setExt(LINUX_SETUP_FONT_SCALE_KEY, string.format("%.2f", clamp(scale, LINUX_SETUP_FONT_SCALE_MIN, LINUX_SETUP_FONT_SCALE_MAX)))
end

local function linuxFontSize(baseSize)
    local scale = (LINUX_SETUP and LINUX_SETUP.fontScale)
        or (SETUP_MENU and SETUP_MENU.fontScale)
        or getLinuxSetupFontScale()
    return math.max(10, math.floor((baseSize * scale) + 0.5))
end

local function linuxWrapWidth(baseWidth)
    local scale = (LINUX_SETUP and LINUX_SETUP.fontScale)
        or (SETUP_MENU and SETUP_MENU.fontScale)
        or getLinuxSetupFontScale()
    return math.max(48, math.floor((baseWidth / scale) + 0.5))
end

local function linuxInfoWrapCharsForColumn(colW)
    local labelW = math.max(90, math.floor(colW * 0.22))
    local valueW = math.max(72, colW - labelW - 8)
    local charW = math.max(6, linuxFontSize(13) * 0.56)
    return math.max(18, math.floor(valueW / charW))
end

local function linuxLineHeight(baseHeight)
    local scale = (LINUX_SETUP and LINUX_SETUP.fontScale)
        or (SETUP_MENU and SETUP_MENU.fontScale)
        or getLinuxSetupFontScale()
    return math.max(12, math.floor((baseHeight * scale) + 0.5))
end

local function adjustLinuxSetupFontScale(delta)
    local target = LINUX_SETUP or SETUP_MENU
    if not target then return end
    local nextScale = clamp((target.fontScale or 1.0) + delta, LINUX_SETUP_FONT_SCALE_MIN, LINUX_SETUP_FONT_SCALE_MAX)
    if math.abs(nextScale - (target.fontScale or 1.0)) < 0.001 then return end
    target.fontScale = nextScale
    saveLinuxSetupFontScale(nextScale)
end

local function resetLinuxSetupFontScale()
    local target = LINUX_SETUP or SETUP_MENU
    if not target then return end
    target.fontScale = LINUX_SETUP_FONT_SCALE_DEFAULT
    saveLinuxSetupFontScale(LINUX_SETUP_FONT_SCALE_DEFAULT)
end

local function linuxPidAlive(pidFile)
    local f = io.open(pidFile, "r")
    if not f then return false, nil end
    local pidText = trim(f:read("*a") or "")
    local pid = tonumber(pidText)
    f:close()
    if not pid then return false, nil end
    local ok = os.execute("kill -0 " .. pid .. " >/dev/null 2>&1")
    return (ok == true or ok == 0), pid
end

local function captureLinuxWindowGeometry()
    if not (gfx and gfx.dock) then return nil end
    local dockState, wx, wy, ww, wh = gfx.dock(-1, 0, 0, 0, 0)
    if type(wx) ~= "number" or type(wy) ~= "number" or type(ww) ~= "number" or type(wh) ~= "number" then
        return nil
    end
    if ww <= 0 or wh <= 0 then
        return nil
    end
    return {
        dockState = dockState or 0,
        x = math.floor(wx),
        y = math.floor(wy),
        w = math.floor(ww),
        h = math.floor(wh),
    }
end

local function restoreLinuxWindowGeometry()
    if not (LINUX_SETUP and LINUX_SETUP.windowGeometry and gfx and gfx.dock) then return end
    if LINUX_SETUP.geometryRestored then return end
    local g = LINUX_SETUP.windowGeometry
    gfx.dock(g.dockState or 0, g.x or 0, g.y or 0, g.w or 0, g.h or 0)
    LINUX_SETUP.geometryRestored = true
end

local function tryExec(cmd)
    local ok = os.execute(cmd)
    return ok == true or ok == 0
end

local function copyToClipboard(text)
    if reaper and reaper.CF_SetClipboard then
        reaper.CF_SetClipboard(text or "")
        return true
    end
    if OS == "macOS" then
        local tmp = os.tmpname()
        local f = io.open(tmp, "w")
        if f then
            f:write(text or "")
            f:close()
        end
        local ok = tryExec("pbcopy < " .. quoteArg(tmp) .. " 2>/dev/null")
        os.remove(tmp)
        return ok
    end
    if OS == "Linux" then
        local tmp = os.tmpname()
        local f = io.open(tmp, "w")
        if f then
            f:write(text or "")
            f:close()
        end
        local ok = tryExec("wl-copy < " .. quoteArg(tmp) .. " 2>/dev/null")
        if not ok then
            ok = tryExec("xclip -selection clipboard < " .. quoteArg(tmp) .. " 2>/dev/null")
        end
        os.remove(tmp)
        return ok
    end
    return false
end

local function openPath(path)
    if not path or path == "" then return end
    if reaper and reaper.CF_ShellExecute then
        reaper.CF_ShellExecute(path)
        return
    end
    if OS == "macOS" then
        tryExec("open " .. quoteArg(path) .. " >/dev/null 2>&1 &")
        return
    end
    if OS == "Linux" then
        tryExec("xdg-open " .. quoteArg(path) .. " >/dev/null 2>&1 &")
    end
end

local function isWindowsPythonAliasPath(path)
    local p = trim(path):lower()
    return p == "python" or p == "python.exe" or p == "py" or p == "py.exe"
end

local function setupResolveWindowsPython(runtime, state, capState)
    local capPython = resolvePath(capState and capState.PYTHON_PATH or "")
    local statePython = resolvePath((state and (state.PYTHON_PATH or state.VENV_PYTHON)) or "")
    local extPythonRaw = trim(getExt("pythonPath") or "")
    local extPython = resolvePath(extPythonRaw)

    local function usablePath(p)
        if p == "" then return false end
        if not isAbsolutePath(p) then return false end
        if isWindowsStorePythonPath(p) then return false end
        return fileExists(p)
    end

    local extValid = usablePath(extPython) and (not isWindowsPythonAliasPath(extPythonRaw))
    if extValid then
        return extPython, "ExtState"
    end
    if usablePath(capPython) then
        return capPython, "capabilities.env"
    end
    if usablePath(statePython) then
        return statePython, "bootstrap.env"
    end
    local runtimePython = resolvePath(runtime and runtime.venvPython or "")
    if usablePath(runtimePython) then
        return runtimePython, "runtime venv"
    end
    return extPython ~= "" and extPython or statePython, "unresolved"
end

local function buildWindowsSetupOverview(runtime, setupVersion, lastSetupVersion)
    local stateFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.env"
    local capFile = runtime.runtimeState .. PATH_SEP .. "capabilities.env"
    local state = fileExists(stateFile) and parseStateFile(stateFile) or {}
    local capState = fileExists(capFile) and parseStateFile(capFile) or {}
    local extPythonRaw = trim(getExt("pythonPath") or "")
    local extFfmpeg = trim(getExt("ffmpegPath") or "")
    local profile = trim(capState.PROFILE or state.PROFILE or "")
    local backend = trim(capState.BACKEND or state.BACKEND or "")
    local verification = trim(capState.VERIFICATION or "")
    local status = trim(state.STATUS or "")
    local reason = trim(state.STATUS_REASON or "")
    local ffmpeg = trim(resolvePath(capState.FFMPEG_PATH or state.FFMPEG_PATH or extFfmpeg))
    local python, pythonSource = setupResolveWindowsPython(runtime, state, capState)
    local needsRepair = false

    if status ~= "" and status ~= "ok" then needsRepair = true end
    if verification ~= "" and verification ~= "ok" then needsRepair = true end
    if trim(capState.AUDIO_SEPARATOR or "") == "missing" then needsRepair = true end
    if trim(capState.STEMWERK_CORE or "") == "missing" then needsRepair = true end
    if python == "" or (not isAbsolutePath(python)) or (not fileExists(python)) then needsRepair = true end
    if ffmpeg == "" or (not fileExists(ffmpeg)) then needsRepair = true end

    local deps = {
        audio_separator = trim(capState.AUDIO_SEPARATOR or ""),
        stemwerk_core = trim(capState.STEMWERK_CORE or ""),
        samplerate = trim(capState.SAMPLERATE or state.SAMPLERATE or ""),
        julius = trim(capState.JULIUS or state.JULIUS or ""),
    }
    for k, v in pairs(deps) do
        if v == "" then deps[k] = "unknown" end
    end

    return {
        runtimeBase = runtime.base or "",
        modelDir = getModelCacheDir(),
        setupStatus = (status ~= "" and status or "unknown"),
        setupReason = reason,
        profile = (profile ~= "" and profile or "unknown"),
        backend = (backend ~= "" and backend or "unknown"),
        pythonPath = python or "",
        pythonSource = pythonSource or "unknown",
        extPython = extPythonRaw ~= "" and extPythonRaw or "(empty)",
        ffmpegPath = ffmpeg ~= "" and ffmpeg or "unknown",
        verification = verification ~= "" and verification or "unknown",
        deps = deps,
        updateDetected = lastSetupVersion ~= "" and setupVersion ~= "" and lastSetupVersion ~= setupVersion,
        needsRepair = needsRepair,
    }
end

local function drawButton(label, x, y, w, h, style)
    local bg = { 0.2, 0.2, 0.2, 1 }
    local border = { 1, 1, 1, 1 }
    if style == "primary" then
        bg = { 0.96, 0.48, 0.10, 1 }
        border = { 1, 0.78, 0.40, 1 }
    end
    gfx.set(bg[1], bg[2], bg[3], bg[4])
    gfx.rect(x, y, w, h, 1)
    gfx.set(border[1], border[2], border[3], border[4])
    gfx.rect(x, y, w, h, 0)
    gfx.setfont(1, "Arial", linuxFontSize(13))
    gfx.set(1, 1, 1, 1)
    gfx.x = x + 8
    gfx.y = y + math.max(2, math.floor((h - linuxLineHeight(13)) / 2))
    gfx.drawstr(label)
end

local function isMouseIn(x, y, w, h)
    return gfx.mouse_x >= x and gfx.mouse_x <= (x + w) and gfx.mouse_y >= y and gfx.mouse_y <= (y + h)
end

local function drawLinuxPanel(x, y, w, h, bg, border)
    gfx.set(bg[1], bg[2], bg[3], bg[4] or 1)
    gfx.rect(x, y, w, h, 1)
    gfx.set(border[1], border[2], border[3], border[4] or 1)
    gfx.rect(x, y, w, h, 0)
end

local buildLinuxLogDisplayLines
local syncLinuxLogScroll
local drawLinuxScrollbar

local function linuxValueColor(kind, isSuccess)
    if kind == "python_path" then
        return { 1.0, 100 / 255, 100 / 255, 1 }
    elseif kind == "ffmpeg_path" then
        return { 100 / 255, 200 / 255, 1.0, 1 }
    elseif kind == "cap_path" then
        return { 150 / 255, 100 / 255, 1.0, 1 }
    elseif kind == "log_path" then
        return { 100 / 255, 1.0, 150 / 255, 1 }
    elseif kind == "status_ok" then
        return { 0.25, 0.95, 0.35, 1 }
    elseif kind == "status_fail" then
        return { 1.0, 0.45, 0.15, 1 }
    elseif kind == "note" then
        return { 0.96, 0.76, 0.45, 1 }
    elseif kind == "muted" then
        return { 0.72, 0.74, 0.78, 1 }
    elseif isSuccess then
        return { 0.96, 0.96, 0.97, 1 }
    end
    return { 0.92, 0.92, 0.94, 1 }
end

local function resolveLinuxPythonPath(state)
    for _, candidate in ipairs({
        state.PYTHON_PATH or "",
        state.VENV_PYTHON or "",
        (LINUX_SETUP and LINUX_SETUP.runtime and LINUX_SETUP.runtime.venvPython) or "",
    }) do
        local resolved = resolvePath(candidate)
        if resolved ~= "" and (fileExists(resolved) or resolved:match("/%.venv/bin/python$")) then
            return resolved
        end
    end
    return ""
end

local function resolveLinuxFfmpegPath(state)
    for _, candidate in ipairs({
        state.FFMPEG_PATH or "",
        getExt("ffmpegPath"),
        "/usr/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/opt/local/bin/ffmpeg",
        "/snap/bin/ffmpeg",
    }) do
        local resolved = resolvePath(candidate)
        if resolved ~= "" and fileExists(resolved) then
            return resolved
        end
    end
    return ""
end

local function measureLinuxInfoRows(rows, wrapWidth)
    local total = 0
    for _, row in ipairs(rows or {}) do
        local wrapped = wrapLine(tostring(row.value or ""), wrapWidth)
        local rowLines = math.max(1, #wrapped)
        if row.maxLines and row.maxLines > 0 then
            rowLines = math.min(rowLines, row.maxLines)
        end
        total = total + rowLines
    end
    return total
end

local function drawLinuxInfoRows(x, y, w, rows, wrapWidth, rowGap, successMode)
    gfx.setfont(1, "Arial Bold", linuxFontSize(13))
    local longestLabelW = 0
    for _, row in ipairs(rows or {}) do
        local lw = gfx.measurestr((row.label or "") .. ":")
        if lw > longestLabelW then longestLabelW = lw end
    end
    local labelW = math.max(100, math.min(math.floor(w * 0.42), math.floor(longestLabelW + 16)))
    local valueX = x + labelW
    local lineH = linuxLineHeight(18)
    rowGap = rowGap or linuxLineHeight(4)
    wrapWidth = wrapWidth or linuxWrapWidth(90)

    for _, row in ipairs(rows or {}) do
        local wrapped = wrapLine(tostring(row.value or ""), wrapWidth)
        if row.maxLines and row.maxLines > 0 and #wrapped > row.maxLines then
            local clipped = {}
            for i = 1, row.maxLines do
                clipped[i] = wrapped[i]
            end
            clipped[row.maxLines] = tostring(clipped[row.maxLines] or "") .. " ..."
            wrapped = clipped
        end
        gfx.setfont(1, "Arial Bold", linuxFontSize(13))
        gfx.set(0.72, 0.74, 0.78, 1)
        gfx.x = x
        gfx.y = y
        gfx.drawstr((row.label or "") .. ":")

        gfx.setfont(1, "Arial", linuxFontSize(13))
        local color = linuxValueColor(row.kind, successMode)
        gfx.set(color[1], color[2], color[3], color[4] or 1)
        for idx, line in ipairs(wrapped) do
            gfx.x = valueX
            gfx.y = y
            gfx.drawstr(line)
            if idx < #wrapped then
                y = y + lineH
            end
        end
        y = y + lineH + rowGap
    end
    return y
end

local function splitLinuxInfoRows(rows, leftLabels)
    local left = {}
    local right = {}
    local labelSet = {}
    for _, label in ipairs(leftLabels or {}) do
        labelSet[tostring(label)] = true
    end
    for _, row in ipairs(rows or {}) do
        local key = tostring(row.label or "")
        if labelSet[key] then
            left[#left + 1] = row
        else
            right[#right + 1] = row
        end
    end
    if #left == 0 and #right > 0 then
        left[#left + 1] = right[1]
        table.remove(right, 1)
    end
    return left, right
end

local function normalizeLinuxUiState(state, pidAlive)
    local out = {}
    for k, v in pairs(state or {}) do
        out[k] = v
    end
    if pidAlive and trim(out.STATUS or "") == "ok" then
        out.STATUS = "running"
    end
    return out
end

local function buildLinuxStatusRows(state, pidAlive, pid, lastLogLine)
    local rows = {}
    local stepLine = formatStepStatus(state)
    local note = prettyBackendNote(state.BACKEND_NOTE or "")

    rows[#rows + 1] = {
        label = "Phase",
        value = ((state.STATUS == "running" or state.STATUS == "" or not state.STATUS) and "Bootstrapping" or "Finalizing"),
        kind = "muted",
    }
    rows[#rows + 1] = {
        label = "Status",
        value = prettySetupStatus(state.STATUS or "running") .. ((LINUX_SETUP and LINUX_SETUP.spinner) and (" [" .. LINUX_SETUP.spinner .. "]") or ""),
        kind = (trim(state.STATUS or "") == "ok") and "status_ok" or "muted",
    }
    if trim(state.STATUS_REASON or "") ~= "" then
        rows[#rows + 1] = { label = "Reason", value = prettySetupReason(state.STATUS_REASON), kind = "muted", maxLines = 2 }
    end
    if stepLine ~= "" then
        rows[#rows + 1] = { label = "Step", value = stepLine:gsub("^Step%s*", ""), kind = "muted" }
    end
    if trim(state.PROFILE or "") ~= "" then
        rows[#rows + 1] = { label = "Profile", value = tostring(state.PROFILE), kind = "muted" }
    end
    if trim(state.BACKEND or "") ~= "" then
        rows[#rows + 1] = { label = "Backend", value = tostring(state.BACKEND), kind = "muted" }
    end
    rows[#rows + 1] = { label = "Python", value = resolveLinuxPythonPath(state), kind = "python_path" }
    rows[#rows + 1] = { label = "FFmpeg", value = resolveLinuxFfmpegPath(state), kind = "ffmpeg_path" }
    if trim(lastLogLine or "") ~= "" then
        rows[#rows + 1] = { label = "Last Log", value = tostring(lastLogLine), kind = "muted", maxLines = 1 }
    end
    rows[#rows + 1] = { label = "PID", value = tostring(pid or "") .. " (alive: " .. tostring(pidAlive) .. ")", kind = "muted" }
    rows[#rows + 1] = { label = "Log", value = tostring(LINUX_SETUP and LINUX_SETUP.logFile or ""), kind = "log_path" }
    if note ~= "" then
        rows[#rows + 1] = { label = "Note", value = note, kind = "note", maxLines = 2 }
    end
    return rows
end

local function buildLinuxFinalRows(state, capState, runtime, logFile, finalSuccess)
    local rows = {}
    local pythonPath = trim(capState.PYTHON_PATH or state.PYTHON_PATH or resolveLinuxPythonPath(state))
    local ffmpegPath = trim(capState.FFMPEG_PATH or state.FFMPEG_PATH or resolveLinuxFfmpegPath(state))
    local profile = trim(capState.PROFILE or state.PROFILE or "")
    local backend = trim(capState.BACKEND or state.BACKEND or "")
    local backendReason = prettyBackendReason(capState.BACKEND_REASON or state.BACKEND_REASON or "")
    local backendNote = prettyBackendNote(capState.BACKEND_NOTE or state.BACKEND_NOTE or "")
    local deviceNames = trim(capState.DEVICE_NAMES or "")

    rows[#rows + 1] = { label = "Python", value = pythonPath, kind = "python_path" }
    rows[#rows + 1] = { label = "FFmpeg", value = ffmpegPath, kind = "ffmpeg_path" }
    if profile ~= "" then
        rows[#rows + 1] = { label = "Profile", value = profile, kind = "muted" }
    end
    if backend ~= "" then
        rows[#rows + 1] = { label = "Backend", value = backend, kind = finalSuccess and "status_ok" or "status_fail" }
    end
    if trim(state.STATUS_REASON or "") ~= "" then
        rows[#rows + 1] = { label = "Reason", value = prettySetupReason(state.STATUS_REASON), kind = "muted", maxLines = 2 }
    end
    if backendReason ~= "" then
        rows[#rows + 1] = { label = "Backend reason", value = backendReason, kind = "muted", maxLines = 2 }
    end
    if backendNote ~= "" then
        rows[#rows + 1] = { label = "Note", value = backendNote, kind = "note", maxLines = 2 }
    end
    if deviceNames ~= "" then
        rows[#rows + 1] = { label = "Devices", value = deviceNames, kind = "muted", maxLines = 1 }
    end
    rows[#rows + 1] = { label = "Capabilities", value = tostring((runtime and runtime.runtimeState or "") .. PATH_SEP .. "capabilities.env"), kind = "cap_path", maxLines = 1 }
    rows[#rows + 1] = { label = "Log", value = tostring(logFile or ""), kind = "log_path", maxLines = 1 }
    return rows
end

local function drawLinuxLogPanel(logX, logY, logW, logH, logLines, footerText)
    drawLinuxPanel(logX, logY, logW, logH, { 0.06, 0.06, 0.07, 1 }, { 0.22, 0.22, 0.24, 1 })

    local logHeaderY = logY + 12
    gfx.setfont(1, "Arial Bold", linuxFontSize(14))
    gfx.set(1, 1, 1, 1)
    gfx.x = logX + 14
    gfx.y = logHeaderY
    gfx.drawstr("Console output")

    local logInnerPad = 14
    local scrollbarW = 24
    local logBodyY = logHeaderY + 22
    local footerH = 28
    local availableBodyH = logH - (logBodyY - logY) - footerH - logInnerPad
    local logBodyH = math.max(80, availableBodyH)
    local logTextX = logX + logInnerPad
    local logTextY = logBodyY
    local logTextW = math.max(120, logW - (logInnerPad * 2) - scrollbarW - 8)
    local logLineH = linuxLineHeight(14)
    local wrapWidth = linuxWrapWidth(132)
    local displayLines = buildLinuxLogDisplayLines(logLines, wrapWidth)
    local visibleLines = math.max(1, math.floor(logBodyH / logLineH))
    local totalLines = #displayLines
    syncLinuxLogScroll(totalLines, visibleLines)
    local startIdx = math.max(1, totalLines - visibleLines - (LINUX_SETUP.logScroll or 0) + 1)
    local endIdx = math.min(totalLines, startIdx + visibleLines - 1)

    LINUX_SETUP.logRect = { x = logTextX, y = logTextY, w = logTextW, h = logBodyH }
    LINUX_SETUP.scrollbarRect = { x = logX + logW - logInnerPad - scrollbarW, y = logBodyY, w = scrollbarW, h = logBodyH }
    LINUX_SETUP.visibleLogLines = visibleLines
    LINUX_SETUP.totalLogLines = totalLines

    gfx.setfont(1, "Courier New", linuxFontSize(12))
    local drawY = logTextY
    for i = startIdx, endIdx do
        local item = displayLines[i]
        setLinuxLogLineColor(item and item.source or "")
        gfx.x = logTextX
        gfx.y = drawY
        gfx.drawstr(item and item.text or "")
        drawY = drawY + logLineH
    end

    drawLinuxScrollbar(LINUX_SETUP.scrollbarRect, totalLines, visibleLines)
    local footerY = logY + logH - footerH
    gfx.set(0.30, 0.30, 0.33, 1)
    gfx.line(logX + 1, footerY - 1, logX + logW - 2, footerY - 1)
    gfx.set(0.11, 0.11, 0.12, 1)
    gfx.rect(logX + 1, footerY, logW - 2, footerH, 1)
    gfx.set(0.24, 0.24, 0.26, 1)
    gfx.rect(logX + 1, footerY, logW - 2, footerH, 0)
    gfx.set(0.70, 0.70, 0.72, 1)
    gfx.setfont(1, "Arial", linuxFontSize(11))
    gfx.x = logX + 14
    gfx.y = footerY + math.max(4, math.floor((footerH - linuxFontSize(11)) / 2) - 1)
    gfx.drawstr(footerText or "Console wheel scrolls. Wheel outside console zooms text. Use +/- or 0 for text size.")
    gfx.set(1, 1, 1, 1)
end

local function drawIntroActionButton(label, x, y, w, h, accent, hovered, primary)
    local fill = primary and { accent[1], accent[2], accent[3], hovered and 0.95 or 0.82 } or { 0.16, 0.16, 0.18, hovered and 1 or 0.92 }
    local border = primary and { accent[1], accent[2], accent[3], 1 } or { 0.34, 0.34, 0.38, 1 }
    gfx.set(fill[1], fill[2], fill[3], fill[4])
    gfx.rect(x, y, w, h, 1)
    gfx.set(border[1], border[2], border[3], border[4])
    gfx.rect(x, y, w, h, 0)
    gfx.set(1, 1, 1, 1)
    gfx.setfont(1, primary and "Arial Bold" or "Arial", linuxFontSize(13))
    local tw = gfx.measurestr(label)
    gfx.x = x + math.floor((w - tw) / 2)
    gfx.y = y + math.max(4, math.floor((h - linuxFontSize(13)) / 2) - 1)
    gfx.drawstr(label)
end

local function showStyledIntroDialog(runtime)
    local runtimeBase = tostring(runtime and runtime.base or "")
    local intro =
        "Run this setup once in REAPER before using STEMwerk.lua.\n\n"
        .. "STEMwerk will check and repair components if needed:\n\n"
        .. "- Python runtime\n"
        .. "- FFmpeg\n"
        .. "- STEMwerk venv in:\n  " .. runtimeBase .. "\n\n"
        .. "Continue?"
    return msgBox("STEMwerk Setup", intro, 4) == 6
end

buildLinuxLogDisplayLines = function(logLines, wrapWidth)
    local out = {}
    for _, line in ipairs(logLines or {}) do
        local wrapped = wrapLine(line, wrapWidth)
        for _, wl in ipairs(wrapped) do
            out[#out + 1] = { text = wl, source = line }
        end
    end
    return out
end

syncLinuxLogScroll = function(totalLines, visibleLines)
    if not LINUX_SETUP then return 0 end
    local maxScroll = math.max(0, totalLines - visibleLines)
    LINUX_SETUP.logScroll = clamp(LINUX_SETUP.logScroll or 0, 0, maxScroll)
    return maxScroll
end

local function adjustLinuxLogScroll(delta, totalLines, visibleLines)
    if not LINUX_SETUP then return end
    local maxScroll = syncLinuxLogScroll(totalLines, visibleLines)
    LINUX_SETUP.logScroll = clamp((LINUX_SETUP.logScroll or 0) + delta, 0, maxScroll)
end

drawLinuxScrollbar = function(rect, totalLines, visibleLines)
    if not rect then return end
    local x, y, w, h = rect.x, rect.y, rect.w, rect.h
    gfx.set(0.10, 0.10, 0.10, 1)
    gfx.rect(x, y, w, h, 1)
    gfx.set(0.35, 0.35, 0.35, 1)
    gfx.rect(x, y, w, h, 0)

    if totalLines <= 0 or visibleLines >= totalLines then
        gfx.set(0.22, 0.22, 0.22, 1)
        gfx.rect(x + 2, y + 2, w - 4, h - 4, 1)
        return
    end

    local maxScroll = math.max(1, totalLines - visibleLines)
    local thumbH = math.max(20, math.floor((visibleLines / totalLines) * h))
    local travel = math.max(1, h - thumbH)
    local scrollRatio = (LINUX_SETUP and LINUX_SETUP.logScroll or 0) / maxScroll
    local thumbY = y + math.floor((1 - scrollRatio) * travel)
    gfx.set(0.34, 0.34, 0.34, 1)
    gfx.rect(x + 2, thumbY + 2, w - 4, math.max(8, thumbH - 4), 1)
end

local function linuxCurrentStep(state)
    local idx = tonumber(trim(state.STEP_INDEX or ""))
    if idx and idx >= 1 and idx <= 4 then
        if LINUX_SETUP and LINUX_SETUP.lastStepIndex and idx < LINUX_SETUP.lastStepIndex then
            return LINUX_SETUP.lastStepIndex
        end
        if LINUX_SETUP then
            LINUX_SETUP.lastStepIndex = idx
        end
        return idx
    end
    if trim(state.STATUS or "") == "ok" then
        if LINUX_SETUP then
            LINUX_SETUP.lastStepIndex = 4
        end
        return 4
    end
    if LINUX_SETUP and LINUX_SETUP.lastStepIndex and LINUX_SETUP.lastStepIndex >= 1 then
        return LINUX_SETUP.lastStepIndex
    end
    return 1
end

local function linuxActiveStepFill(state, logLines)
    if trim(state.STATUS or "") == "ok" then
        if LINUX_SETUP then
            LINUX_SETUP.stepFillByIndex = LINUX_SETUP.stepFillByIndex or {}
            LINUX_SETUP.stepFillByIndex[4] = 1
        end
        return 1
    end
    local stepIndex = linuxCurrentStep(state)
    local stepFillByIndex = nil
    local cachedFill = 0.08
    if LINUX_SETUP then
        LINUX_SETUP.stepFillByIndex = LINUX_SETUP.stepFillByIndex or {}
        stepFillByIndex = LINUX_SETUP.stepFillByIndex
        cachedFill = tonumber(stepFillByIndex[stepIndex] or 0.08) or 0.08
        for s = 1, stepIndex - 1 do
            stepFillByIndex[s] = 1
        end
    end
    for i = #logLines, 1, -1 do
        local line = tostring(logLines[i] or "")
        local pct = tonumber(line:match("(%d+)%%"))
        if pct and pct >= 0 and pct <= 100 then
            local fill = math.max(cachedFill, clamp(pct / 100, 0.08, 1.0))
            if stepFillByIndex then
                stepFillByIndex[stepIndex] = fill
            end
            return fill
        end
        local current, total = line:match("([%d%.]+)%s*/%s*([%d%.]+)%s*GB")
        current = tonumber(current)
        total = tonumber(total)
        if current and total and total > 0 then
            local fill = math.max(cachedFill, clamp(current / total, 0.08, 1.0))
            if stepFillByIndex then
                stepFillByIndex[stepIndex] = fill
            end
            return fill
        end
    end
    local creepFill = clamp(cachedFill + 0.006, 0.08, 0.92)
    if stepFillByIndex then
        stepFillByIndex[stepIndex] = creepFill
    end
    return creepFill
end

local function linuxProgressPercent(state, logLines)
    if trim(state.STATUS or "") == "ok" then
        if LINUX_SETUP then
            LINUX_SETUP.lastProgressPct = 100
        end
        return 100, 1
    end
    local idx = linuxCurrentStep(state)
    local activeFill = linuxActiveStepFill(state, logLines or {})
    local segment = 100 / 4
    local completed = (idx - 1) * segment
    local pct = completed + (activeFill * segment)
    if LINUX_SETUP then
        local prev = tonumber(LINUX_SETUP.lastProgressPct or 0) or 0
        pct = math.max(prev, pct)
        LINUX_SETUP.lastProgressPct = pct
    end
    return math.floor(pct + 0.5), activeFill
end

local function linuxStageColor(stepIndex)
    local colors = {
        { 255, 100, 100 },
        { 100, 200, 255 },
        { 150, 100, 255 },
        { 100, 255, 100 },
    }
    local c = colors[tonumber(stepIndex or 0) or 0] or colors[4]
    return c[1] / 255, c[2] / 255, c[3] / 255
end

local function setupUiLabel()
    return setupPlatformLabel()
end

local function drawLinuxStepLegend(x, y, w, state, logLines)
    local labels = {
        "1. Runtime",
        "2. Python + venv",
        "3. FFmpeg",
        "4. Finalizing",
    }
    local colors = {
        { 255, 100, 100 },
        { 100, 200, 255 },
        { 150, 100, 255 },
        { 100, 255, 100 },
    }
    local currentStep = linuxCurrentStep(state)
    local done = trim(state.STATUS or "") == "ok"
    local gap = 14
    local colW = math.floor((w - gap * 3) / 4)
    local trackH = math.max(10, linuxLineHeight(10))

    for i = 1, 4 do
        local colX = x + ((i - 1) * (colW + gap))
        local c = colors[i]
        local isCompleted = done or i < currentStep
        local isActive = (not done) and i == currentStep
        if isCompleted or isActive then
            gfx.set(c[1] / 255, c[2] / 255, c[3] / 255, 1)
            gfx.setfont(1, "Arial Bold", linuxFontSize(13))
        else
            gfx.set(0.42, 0.42, 0.42, 1)
            gfx.setfont(1, "Arial", linuxFontSize(13))
        end
        gfx.x = colX
        gfx.y = y
        gfx.drawstr(labels[i])

        local trackY = y + linuxLineHeight(20)
        gfx.set(0.20, 0.20, 0.22, 1)
        gfx.rect(colX, trackY, colW, trackH, 1)
        if isCompleted then
            gfx.set(c[1] / 255, c[2] / 255, c[3] / 255, 1)
            gfx.rect(colX, trackY, colW, trackH, 1)
            gfx.set(c[1] / 255, c[2] / 255, c[3] / 255, 1)
            gfx.rect(colX, trackY, colW, trackH, 0)
        elseif isActive then
            gfx.set(0.20, 0.20, 0.22, 1)
            gfx.rect(colX, trackY, colW, trackH, 1)
            gfx.set(c[1] / 255, c[2] / 255, c[3] / 255, 1)
            gfx.rect(colX, trackY, colW, trackH, 0)
        else
            gfx.set(0.34, 0.34, 0.36, 1)
            gfx.rect(colX, trackY, colW, trackH, 0)
        end
    end
end

local function linuxDrawStatus(state, logLines, pidAlive, pid)
    local uiState = normalizeLinuxUiState(state, pidAlive)
    local lastLogLine = extractLastLogLine(logLines or {})
    local w, h = gfx.w, gfx.h
    gfx.set(0.03, 0.03, 0.04, 1)
    gfx.rect(0, 0, w, h, 1)
    gfx.set(0.97, 0.55, 0.05, 1)
    gfx.rect(0, 0, w, math.max(8, linuxLineHeight(8)), 1)

    local outerPad = 18
    local gap = 16
    local infoX = outerPad
    local infoY = 22
    local infoW = w - (outerPad * 2)
    local infoIntroLines = {
        "Setup is running. Keep this window open.",
        "Progress and logs update in real time.",
    }
    local infoRows = buildLinuxStatusRows(uiState, pidAlive, pid, lastLogLine)
    local leftRows, rightRows = splitLinuxInfoRows(infoRows, {
        "Phase", "Status", "Step", "Profile", "Backend", "Python", "FFmpeg"
    })
    local infoColGap = math.max(10, linuxLineHeight(10))
    local infoContentW = infoW - 28
    local infoColW = math.floor((infoContentW - infoColGap) / 2)
    local leftWrap = linuxInfoWrapCharsForColumn(infoColW)
    local rightWrap = linuxInfoWrapCharsForColumn(infoColW)
    local infoHeaderH = linuxLineHeight(24)
    local infoBodyLineH = linuxLineHeight(18)
    local infoRowGap = linuxLineHeight(3)
    local infoRowsLeftH = (measureLinuxInfoRows(leftRows, leftWrap) * infoBodyLineH) + (#leftRows * infoRowGap)
    local infoRowsRightH = (measureLinuxInfoRows(rightRows, rightWrap) * infoBodyLineH) + (#rightRows * infoRowGap)
    local infoRowsH = math.max(infoRowsLeftH, infoRowsRightH)
    local progressH = math.max(18, linuxLineHeight(18))
    local legendGap = linuxLineHeight(14)
    local contentBottomY = (infoY + 14) + linuxLineHeight(28) + linuxLineHeight(22) + (#infoIntroLines * infoBodyLineH) + linuxLineHeight(6) + infoRowsH
    local legendY = contentBottomY + legendGap
    local progressY = legendY + linuxLineHeight(36)
    local infoH = (progressY + progressH + 14) - infoY
    local logX = outerPad
    local logY = infoY + infoH + gap
    local logW = infoW
    local logH = math.max(160, h - logY - outerPad)

    drawLinuxPanel(infoX, infoY, infoW, infoH, { 0.08, 0.08, 0.09, 1 }, { 0.26, 0.26, 0.28, 1 })

    local y = infoY + 14
    drawStemwerkInline(infoX + 14, y, linuxFontSize(22), "", "werk Setup [" .. setupUiLabel() .. "]")
    y = y + linuxLineHeight(28)

    gfx.setfont(1, "Arial Bold", linuxFontSize(14))
    gfx.set(1, 1, 1, 1)
    gfx.x = infoX + 14
    gfx.y = y
    gfx.drawstr("Installing")
    y = y + linuxLineHeight(22)

    gfx.setfont(1, "Arial", linuxFontSize(13))
    gfx.set(0.82, 0.85, 0.90, 1)
    for _, line in ipairs(infoIntroLines) do
        gfx.x = infoX + 14
        gfx.y = y
        gfx.drawstr(line)
        y = y + infoBodyLineH
    end

    y = y + linuxLineHeight(6)
    local rowTopY = y
    drawLinuxInfoRows(infoX + 14, rowTopY, infoColW, leftRows, leftWrap, infoRowGap, false)
    drawLinuxInfoRows(infoX + 14 + infoColW + infoColGap, rowTopY, infoColW, rightRows, rightWrap, infoRowGap, false)

    drawLinuxStepLegend(infoX + 14, legendY, infoW - 28, uiState, logLines)

    local progressX = infoX + 14
    local progressW = infoW - 28
    local progressPct = linuxProgressPercent(uiState, logLines)
    local pr, pg, pb = linuxStageColor(linuxCurrentStep(uiState))
    gfx.set(0.18, 0.18, 0.19, 1)
    gfx.rect(progressX, progressY, progressW, progressH, 1)
    gfx.set(0.32, 0.32, 0.34, 1)
    gfx.rect(progressX, progressY, progressW, progressH, 0)
    gfx.set(pr, pg, pb, 1)
    gfx.rect(progressX, progressY, math.floor(progressW * (progressPct / 100)), progressH, 1)
    drawLinuxLogPanel(logX, logY, logW, logH, logLines, "Console wheel scrolls. Ctrl+wheel outside console zooms text. Use +/- or 0 for text size.")
end

local function linuxDrawFinal(finalLines, finalSuccess, state, logLines, pid)
    local w, h = gfx.w, gfx.h
    gfx.set(0.03, 0.03, 0.04, 1)
    gfx.rect(0, 0, w, h, 1)
    gfx.set(0.97, 0.55, 0.05, 1)
    gfx.rect(0, 0, w, math.max(8, linuxLineHeight(8)), 1)

    local outerPad = 18
    local gap = 16
    local infoX = outerPad
    local infoY = 22
    local infoW = w - (outerPad * 2)
    local btnGap = 12
    local actionH = linuxLineHeight(104)
    local minActionH = linuxLineHeight(84)
    local minLogH = math.max(96, linuxLineHeight(92))
    local capState = parseStateFile((LINUX_SETUP and LINUX_SETUP.capFile) or "")
    local infoRows = buildLinuxFinalRows(state or {}, capState, LINUX_SETUP and LINUX_SETUP.runtime, LINUX_SETUP and LINUX_SETUP.logFile, finalSuccess)
    local leftRows, rightRows = splitLinuxInfoRows(infoRows, {
        "Python", "FFmpeg", "Profile", "Backend"
    })
    local infoColGap = math.max(10, linuxLineHeight(10))
    local infoContentW = infoW - 28
    local infoColW = math.floor((infoContentW - infoColGap) / 2)
    local leftWrap = linuxInfoWrapCharsForColumn(infoColW)
    local rightWrap = linuxInfoWrapCharsForColumn(infoColW)
    local infoLineH = linuxLineHeight(18)
    local infoRowGap = linuxLineHeight(2)
    local infoRowsLeftH = (measureLinuxInfoRows(leftRows, leftWrap) * infoLineH) + (#leftRows * infoRowGap)
    local infoRowsRightH = (measureLinuxInfoRows(rightRows, rightWrap) * infoLineH) + (#rightRows * infoRowGap)
    local infoRowsH = math.max(infoRowsLeftH, infoRowsRightH)
    local progressH = math.max(18, linuxLineHeight(18))
    local legendGap = linuxLineHeight(14)
    local contentBottomY = (infoY + 14) + linuxLineHeight(28) + linuxLineHeight(26) + linuxLineHeight(30) + infoRowsH
    local legendY = contentBottomY + legendGap
    local progressY = legendY + linuxLineHeight(36)
    local infoHCalculated = (progressY + progressH + 14) - infoY
    local maxInfoH = h - outerPad - actionH - gap - infoY - gap - minLogH
    if maxInfoH < 140 then
        actionH = minActionH
        maxInfoH = h - outerPad - actionH - gap - infoY - gap - minLogH
    end
    local infoH = math.min(infoHCalculated, math.max(140, maxInfoH))
    local footerY = h - outerPad - actionH
    local logX = outerPad
    local logY = infoY + infoH + gap
    local logW = infoW
    local logH = math.max(40, footerY - gap - logY)

    drawLinuxPanel(infoX, infoY, infoW, infoH, { 0.08, 0.08, 0.09, 1 }, { 0.26, 0.26, 0.28, 1 })
    drawLinuxPanel(outerPad, footerY, infoW, actionH, { 0.08, 0.08, 0.09, 1 }, { 0.26, 0.26, 0.28, 1 })

    local y = infoY + 14
    drawStemwerkInline(infoX + 14, y, linuxFontSize(22), "", "werk Setup [" .. setupUiLabel() .. "]")
    y = y + linuxLineHeight(28)
    gfx.setfont(1, "Arial", linuxFontSize(16))
    gfx.set(0.92, 0.92, 0.94, 1)
    gfx.x = infoX + 14
    gfx.y = y
    gfx.drawstr(setupUiLabel() .. " live setup UI active")
    y = y + linuxLineHeight(26)
    gfx.setfont(1, "Arial Bold", linuxFontSize(20))
    if finalSuccess then
        gfx.set(0.20, 0.92, 0.28, 1)
        gfx.x = infoX + 14
        gfx.y = y
        gfx.drawstr("Setup complete.")
    else
        gfx.set(1.0, 0.42, 0.12, 1)
        gfx.x = infoX + 14
        gfx.y = y
        gfx.drawstr("Setup was not completely successful.")
    end
    y = y + linuxLineHeight(30)
    local rowTopY = y
    drawLinuxInfoRows(infoX + 14, rowTopY, infoColW, leftRows, leftWrap, infoRowGap, finalSuccess)
    drawLinuxInfoRows(infoX + 14 + infoColW + infoColGap, rowTopY, infoColW, rightRows, rightWrap, infoRowGap, finalSuccess)

    local finalState = {}
    for k, v in pairs(state or {}) do
        finalState[k] = v
    end
    if finalSuccess then
        finalState.STATUS = "ok"
        finalState.STEP_INDEX = "4"
    end

    drawLinuxStepLegend(infoX + 14, legendY, infoW - 28, finalState, logLines or {})

    local progressX = infoX + 14
    local progressW = infoW - 28
    local progressPct = finalSuccess and 100 or select(1, linuxProgressPercent(finalState, logLines or {}))
    local pr, pg, pb = linuxStageColor(linuxCurrentStep(finalState))
    gfx.set(0.18, 0.18, 0.19, 1)
    gfx.rect(progressX, progressY, progressW, progressH, 1)
    gfx.set(0.32, 0.32, 0.34, 1)
    gfx.rect(progressX, progressY, progressW, progressH, 0)
    gfx.set(pr, pg, pb, 1)
    gfx.rect(progressX, progressY, math.floor(progressW * (progressPct / 100)), progressH, 1)

    drawLinuxLogPanel(logX, logY, logW, logH, logLines or {}, "")

    local actionButtons = {}
    if finalSuccess then
        actionButtons[#actionButtons + 1] = { label = "Open STEMwerk", action = "open_stemwerk", style = "primary" }
    else
        actionButtons[#actionButtons + 1] = { label = "Repair", action = "repair", style = "primary" }
        actionButtons[#actionButtons + 1] = { label = "Rebuild venv", action = "rebuild_venv" }
        actionButtons[#actionButtons + 1] = { label = "Set FFmpeg Path...", action = "set_ffmpeg_path" }
    end
    actionButtons[#actionButtons + 1] = { label = "Open Log", action = "open_log" }
    actionButtons[#actionButtons + 1] = { label = "Open Capabilities", action = "open_cap" }
    actionButtons[#actionButtons + 1] = { label = "Save Support Bundle", action = "save_support_bundle" }
    actionButtons[#actionButtons + 1] = { label = "Open Action List", action = "open_action_list" }
    actionButtons[#actionButtons + 1] = { label = "Open REAPER Help", action = "open_help" }
    actionButtons[#actionButtons + 1] = { label = "Copy Summary", action = "copy_summary" }
    actionButtons[#actionButtons + 1] = { label = "Copy Log Path", action = "copy_log" }
    actionButtons[#actionButtons + 1] = { label = "Copy Capabilities", action = "copy_cap" }
    local buttonAreaW = infoW - 28
    local buttonStartX = outerPad + 14
    local preferredCols = 4
    if buttonAreaW < 980 then preferredCols = 3 end
    if buttonAreaW < 760 then preferredCols = 2 end
    local footerTextH = linuxLineHeight(18)
    local footerTextY = footerY + actionH - footerTextH - 8
    local buttonsTop = footerY + 10
    local buttonsBottom = footerTextY - 6
    local rowGap = 8
    local minBtnH = math.max(18, linuxLineHeight(18))

    local function computeFooterGrid(cols)
        local rows = math.ceil(#actionButtons / cols)
        local btnW = math.floor((buttonAreaW - (btnGap * (cols - 1))) / cols)
        local availH = math.max(0, buttonsBottom - buttonsTop)
        local btnH = math.floor((availH - (rowGap * (rows - 1))) / rows)
        return cols, rows, btnW, btnH
    end

    local cols, rows, btnW, btnH = computeFooterGrid(preferredCols)
    while btnH < minBtnH and cols < 4 do
        cols = cols + 1
        cols, rows, btnW, btnH = computeFooterGrid(cols)
    end
    btnH = math.max(16, btnH)

    if LINUX_SETUP then
        LINUX_SETUP.buttons = {}
        for i, b in ipairs(actionButtons) do
            local row = math.floor((i - 1) / cols)
            local col = (i - 1) % cols
            local bx = buttonStartX + (col * (btnW + btnGap))
            local by = buttonsTop + (row * (btnH + rowGap))
            LINUX_SETUP.buttons[#LINUX_SETUP.buttons + 1] = {
                label = b.label,
                x = bx,
                y = by,
                w = btnW,
                h = btnH,
                action = b.action,
                style = b.style,
            }
        end
        gfx.setfont(1, "Arial", linuxFontSize(13))
        for _, b in ipairs(LINUX_SETUP.buttons) do
            drawButton(b.label, b.x, b.y, b.w, b.h, b.style)
        end
    end

    gfx.setfont(1, "Arial", linuxFontSize(12))
    gfx.set(0.70, 0.70, 0.72, 1)
    local helpText = "Console wheel: scroll. Ctrl+wheel or +/-/0: text zoom."
    gfx.x = outerPad + 14
    gfx.y = footerTextY
    gfx.drawstr(helpText)

    local footerText = string.format("Esc/close to continue.  Text %.0f%%", ((LINUX_SETUP and LINUX_SETUP.fontScale) or 1.0) * 100)
    local footerW = gfx.measurestr(footerText)
    gfx.x = outerPad + infoW - 14 - footerW
    gfx.y = footerTextY
    gfx.drawstr(footerText)
end

local verifyExistingSetup
local startLinuxSetup

local function linuxSetupTick()
    if not LINUX_SETUP then return end
    if not gfx then return end

    if LINUX_SETUP.launchPending and LINUX_SETUP.launchCmd then
        if OS == "macOS" then
            tryExec(LINUX_SETUP.launchCmd)
        else
            exec(LINUX_SETUP.launchCmd, 20000)
        end
        LINUX_SETUP.launchPending = false
    end

    local state = parseStateFile(LINUX_SETUP.stateFile)
    local logLines = readTail(LINUX_SETUP.logFile, 400)
    local pidAlive, pid = linuxPidAlive(LINUX_SETUP.pidFile)
    if pidAlive then
        LINUX_SETUP.pidSeen = true
    end

    local spinner = { "|", "/", "-", "\\" }
    local idx = (LINUX_SETUP.spinnerIndex or 1)
    LINUX_SETUP.spinner = spinner[idx]
    LINUX_SETUP.spinnerIndex = (idx % #spinner) + 1
    local wheel = gfx.mouse_wheel or 0
    local lastWheel = LINUX_SETUP.lastMouseWheel or 0
    if wheel ~= lastWheel then
        local wheelStep = (wheel > lastWheel) and 3 or -3
        if LINUX_SETUP.logRect and isMouseIn(LINUX_SETUP.logRect.x, LINUX_SETUP.logRect.y, LINUX_SETUP.logRect.w, LINUX_SETUP.logRect.h) then
            adjustLinuxLogScroll(wheelStep, LINUX_SETUP.totalLogLines or 0, LINUX_SETUP.visibleLogLines or 1)
        else
            local ctrlHeld = ((gfx.mouse_cap or 0) & 4) == 4
            if ctrlHeld then
                if wheel > lastWheel then
                    adjustLinuxSetupFontScale(LINUX_SETUP_FONT_SCALE_STEP)
                else
                    adjustLinuxSetupFontScale(-LINUX_SETUP_FONT_SCALE_STEP)
                end
            end
        end
        LINUX_SETUP.lastMouseWheel = wheel
    end

    if not LINUX_SETUP.finalized then
        local status = state.STATUS or ""
        if not pidAlive and status ~= "" and status ~= "running" then
            local result = safePerformPostBootstrap(LINUX_SETUP.runtime, LINUX_SETUP.stateFile, LINUX_SETUP.logFile, status == "ok", state, LINUX_SETUP.separatorScript)
            LINUX_SETUP.finalized = true
            LINUX_SETUP.finalMessage = result.finalMessage
            LINUX_SETUP.finalSuccess = result.success
            LINUX_SETUP.summaryText = table.concat(result.finalMessage or {}, "\n")
        elseif not pidAlive and (status == "" or status == "running") then
            local elapsed = os.time() - (LINUX_SETUP.startedAt or os.time())
            if LINUX_SETUP.pidSeen or elapsed >= 5 then
                local result = safePerformPostBootstrap(LINUX_SETUP.runtime, LINUX_SETUP.stateFile, LINUX_SETUP.logFile, status == "ok", state, LINUX_SETUP.separatorScript)
                LINUX_SETUP.finalized = true
                LINUX_SETUP.finalMessage = result.finalMessage
                LINUX_SETUP.finalSuccess = result.success
                LINUX_SETUP.summaryText = table.concat(result.finalMessage or {}, "\n")
            end
        end
    end

    if LINUX_SETUP.finalized then
        restoreLinuxWindowGeometry()
        linuxDrawFinal(LINUX_SETUP.finalMessage, LINUX_SETUP.finalSuccess, state, logLines, pid)
        if LINUX_SETUP.finalSuccess
            and not LINUX_SETUP.postActionRefreshQueued
            and (LINUX_SETUP.mode == "repair" or LINUX_SETUP.mode == "rebuild-venv") then
            LINUX_SETUP.postActionRefreshQueued = true
            local runtime = LINUX_SETUP.runtime
            local separatorScript = LINUX_SETUP.separatorScript
            local refreshStateFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.env"
            local refreshCapFile = runtime.runtimeState .. PATH_SEP .. "capabilities.env"
            local attempts = 0
            local function reopenWithFreshState()
                attempts = attempts + 1
                local freshState = parseStateFile(refreshStateFile)
                local freshCaps = parseStateFile(refreshCapFile)
                local stateReady = fileExists(refreshStateFile) and next(freshState) ~= nil
                local ffmpegReady = trim(freshState.FFMPEG_PATH or freshCaps.FFMPEG_PATH or resolveLinuxFfmpegPath(freshState)) ~= ""
                if (stateReady and ffmpegReady) or attempts >= 12 then
                    if gfx then gfx.quit() end
                    LINUX_SETUP = nil
                    verifyExistingSetup(runtime, separatorScript)
                    return
                end
                reaper.defer(reopenWithFreshState)
            end
            reaper.defer(reopenWithFreshState)
            return
        end
    else
        linuxDrawStatus(state, logLines, pidAlive, pid)
    end

    gfx.update()
    if LINUX_SETUP and LINUX_SETUP.finalized and LINUX_SETUP.buttons then
        local cap = gfx.mouse_cap
        local last = LINUX_SETUP.lastMouseCap or 0
        local clicked = (cap & 1) == 1 and (last & 1) == 0
        LINUX_SETUP.lastMouseCap = cap
        if clicked then
            for _, b in ipairs(LINUX_SETUP.buttons) do
                if isMouseIn(b.x, b.y, b.w, b.h) then
                    if b.action == "copy_summary" then
                        copyToClipboard(LINUX_SETUP.summaryText or "")
                    elseif b.action == "copy_log" then
                        copyToClipboard(LINUX_SETUP.logFile or "")
                    elseif b.action == "copy_cap" then
                        copyToClipboard(LINUX_SETUP.capFile or "")
                    elseif b.action == "open_log" then
                        openPath(LINUX_SETUP.logFile)
                    elseif b.action == "open_cap" then
                        openPath(LINUX_SETUP.capFile)
                    elseif b.action == "open_action_list" then
                        openActionList()
                    elseif b.action == "open_help" then
                        openPath(LINUX_SETUP.helpFile)
                    elseif b.action == "save_support_bundle" then
                        gfx.quit()
                        LINUX_SETUP = nil
                        reaper.defer(function()
                            runSupportBundleAction()
                        end)
                        return
                    elseif b.action == "set_ffmpeg_path" then
                        gfx.quit()
                        LINUX_SETUP = nil
                        reaper.defer(function()
                            runSetFfmpegPathAction()
                        end)
                        return
                    elseif b.action == "repair" then
                        local runtime = LINUX_SETUP.runtime
                        local separatorScript = LINUX_SETUP.separatorScript or (SCRIPT_DIR .. "audio_separator_process.py")
                        gfx.quit()
                        LINUX_SETUP = nil
                        startLinuxSetup(runtime, separatorScript, "repair")
                        return
                    elseif b.action == "rebuild_venv" then
                        local runtime = LINUX_SETUP.runtime
                        local separatorScript = LINUX_SETUP.separatorScript or (SCRIPT_DIR .. "audio_separator_process.py")
                        gfx.quit()
                        LINUX_SETUP = nil
                        startLinuxSetup(runtime, separatorScript, "rebuild-venv")
                        return
                    elseif b.action == "open_stemwerk" then
                        gfx.quit()
                        LINUX_SETUP = nil
                        reaper.defer(function()
                            launchMainStemwerkScript()
                        end)
                        return
                    end
                    break
                end
            end
        end
    end
    if LINUX_SETUP and not LINUX_SETUP.finalized then
        local cap = gfx.mouse_cap
        local last = LINUX_SETUP.lastMouseCap or 0
        local clicked = (cap & 1) == 1 and (last & 1) == 0
        LINUX_SETUP.lastMouseCap = cap
        if clicked and LINUX_SETUP.scrollbarRect and isMouseIn(LINUX_SETUP.scrollbarRect.x, LINUX_SETUP.scrollbarRect.y, LINUX_SETUP.scrollbarRect.w, LINUX_SETUP.scrollbarRect.h) then
            local rect = LINUX_SETUP.scrollbarRect
            local total = LINUX_SETUP.totalLogLines or 0
            local visible = LINUX_SETUP.visibleLogLines or 1
            if total > visible then
                local ratio = clamp((gfx.mouse_y - rect.y) / math.max(1, rect.h), 0, 1)
                local maxScroll = math.max(0, total - visible)
                LINUX_SETUP.logScroll = math.floor((1 - ratio) * maxScroll + 0.5)
            end
        end
    end
    if LINUX_SETUP and LINUX_SETUP.finalized then
        local cap = gfx.mouse_cap
        local last = LINUX_SETUP.lastMouseCap or 0
        local clicked = (cap & 1) == 1 and (last & 1) == 0
        if clicked and LINUX_SETUP.scrollbarRect and isMouseIn(LINUX_SETUP.scrollbarRect.x, LINUX_SETUP.scrollbarRect.y, LINUX_SETUP.scrollbarRect.w, LINUX_SETUP.scrollbarRect.h) then
            local rect = LINUX_SETUP.scrollbarRect
            local total = LINUX_SETUP.totalLogLines or 0
            local visible = LINUX_SETUP.visibleLogLines or 1
            if total > visible then
                local ratio = clamp((gfx.mouse_y - rect.y) / math.max(1, rect.h), 0, 1)
                local maxScroll = math.max(0, total - visible)
                LINUX_SETUP.logScroll = math.floor((1 - ratio) * maxScroll + 0.5)
            end
        end
    end
    local key = gfx.getchar()
    if key == 43 or key == 61 then
        adjustLinuxSetupFontScale(LINUX_SETUP_FONT_SCALE_STEP)
    elseif key == 45 or key == 95 then
        adjustLinuxSetupFontScale(-LINUX_SETUP_FONT_SCALE_STEP)
    elseif key == 48 then
        resetLinuxSetupFontScale()
    elseif key == 30064 then
        adjustLinuxLogScroll(5, LINUX_SETUP and LINUX_SETUP.totalLogLines or 0, LINUX_SETUP and LINUX_SETUP.visibleLogLines or 1)
    elseif key == 1685026670 then
        adjustLinuxLogScroll(-5, LINUX_SETUP and LINUX_SETUP.totalLogLines or 0, LINUX_SETUP and LINUX_SETUP.visibleLogLines or 1)
    end
    if key == -1 or (LINUX_SETUP.finalized and key == 27) then
        gfx.quit()
        LINUX_SETUP = nil
        return
    end
    reaper.defer(linuxSetupTick)
end

local function appendSetupLog(runtime, line, replace)
    if not runtime or not runtime.runtimeLogs then return end
    ensureDir(runtime.runtimeLogs)
    local logFile = runtime.runtimeLogs .. PATH_SEP .. "bootstrap.log"
    local mode = replace and "w" or "a"
    local f = io.open(logFile, mode)
    if not f then return end
    f:write(tostring(line or "") .. "\n")
    f:close()
end

local function removeDirRecursive(path)
    if not path or path == "" or OS == "Windows" then
        return false, "unsupported_or_empty_path", -1, ""
    end
    local cmd = "rm -rf " .. quoteArg(path)
    local rc, out = execCapture(cmd, 120000)
    out = trim(out or "")
    if rc == 0 and not pathExists(path) then
        return true, nil, rc, out
    end
    if rc == 0 and pathExists(path) then
        return false, "path_still_exists_after_delete", rc, out
    end
    return false, "rm_failed", rc, out
end

local function normalizePathForSafety(path)
    local p = resolvePath(path or "")
    if p == "" then return "" end
    p = p:gsub("\\", "/")
    p = p:gsub("/+$", "")
    return p
end

local function canonicalizeDir(path)
    local raw = resolvePath(path or "")
    if raw == "" then return nil, "empty_path" end
    if not pathExists(raw) then return nil, "path_missing" end
    local cmd = 'cd ' .. quoteArg(raw) .. ' >/dev/null 2>&1 && pwd -P'
    local rc, out = execCapture(cmd, 4000)
    if rc ~= 0 then
        return nil, "canonical_resolution_failed"
    end
    local canon = normalizePathForSafety(trim((out or ""):match("([^\r\n]+)") or ""))
    if canon == "" then
        return nil, "canonical_empty"
    end
    return canon, nil
end

local function canonicalizeParentAndJoin(path)
    local raw = resolvePath(path or "")
    if raw == "" then return nil, "empty_path" end
    local norm = normalizePathForSafety(raw)
    local parent = norm:match("^(.*)/[^/]+$") or ""
    local leaf = norm:match("([^/]+)$") or ""
    if parent == "" or leaf == "" then
        return nil, "invalid_path"
    end
    local canonParent, err = canonicalizeDir(parent)
    if not canonParent then
        return nil, err or "canonical_parent_failed"
    end
    return canonParent .. "/" .. leaf, nil
end

local function startsWithPath(path, prefix)
    path = normalizePathForSafety(path)
    prefix = normalizePathForSafety(prefix)
    if path == "" or prefix == "" then return false end
    return path == prefix or path:sub(1, #prefix + 1) == (prefix .. "/")
end

local function getCanonicalReaperResourcePath()
    local rp = PATH_HELPER and PATH_HELPER.getReaperResourcePath and PATH_HELPER.getReaperResourcePath(OS, PATH_SEP) or ""
    if rp == "" then return nil end
    return canonicalizeDir(rp)
end

local function getCanonicalScriptsInstallPath()
    local canonical = PATH_HELPER and PATH_HELPER.getCanonicalInstallRoot and PATH_HELPER.getCanonicalInstallRoot(OS, PATH_SEP) or ""
    if canonical == "" then return nil end
    return canonicalizeParentAndJoin(canonical)
end

local function validateCanonicalDeleteTarget(targetPath, expectedPath, label, allowMissingTarget)
    local targetCanon, targetErr
    if allowMissingTarget and not pathExists(targetPath) then
        targetCanon, targetErr = canonicalizeParentAndJoin(targetPath)
    else
        targetCanon, targetErr = canonicalizeDir(targetPath)
    end
    if not targetCanon then
        return false, targetErr or "target_canonical_failed", nil, nil
    end
    local expectedCanon, expectedErr = canonicalizeParentAndJoin(expectedPath)
    if not expectedCanon then
        return false, expectedErr or "expected_canonical_failed", targetCanon, nil
    end
    if targetCanon ~= expectedCanon then
        return false, "target_mismatch", targetCanon, expectedCanon
    end
    local homeCanon = canonicalizeDir(getHome())
    if homeCanon and targetCanon == homeCanon then
        return false, "forbidden_home_path", targetCanon, expectedCanon
    end
    local resourceCanon = getCanonicalReaperResourcePath()
    if resourceCanon and (targetCanon == resourceCanon or startsWithPath(targetCanon, resourceCanon)) then
        return false, "forbidden_resource_path", targetCanon, expectedCanon
    end
    local scriptsCanon = getCanonicalScriptsInstallPath()
    if scriptsCanon and (targetCanon == scriptsCanon or startsWithPath(targetCanon, scriptsCanon)) then
        return false, "forbidden_scripts_path", targetCanon, expectedCanon
    end
    if targetCanon == "/" then
        return false, "root_path", targetCanon, expectedCanon
    end
    return true, nil, targetCanon, expectedCanon
end

local function uniqueTrashPath(trashRoot, prefix)
    if not trashRoot or trashRoot == "" then return nil, "missing_trash_root" end
    local stamp = os.date("%Y%m%d-%H%M%S")
    for index = 0, 99 do
        local suffix = (index == 0) and stamp or (stamp .. "-" .. tostring(index))
        local candidate = trashRoot .. PATH_SEP .. prefix .. "-" .. suffix
        if not pathExists(candidate) then
            return candidate, nil
        end
    end
    return nil, "trash_target_collision"
end

local function dirIsEmpty(path)
    if not path or path == "" then return true end
    local rc, out = execCapture("find " .. quoteArg(path) .. " -mindepth 1 -print -quit", 4000)
    if rc ~= 0 then
        return true
    end
    return trim(out or "") == ""
end

local function estimateDirSize(path)
    if not path or path == "" then return "unknown" end
    local rc, out = execCapture("du -sh " .. quoteArg(path), 6000)
    if rc ~= 0 then
        return "unknown"
    end
    local first = trim((out or ""):match("^(%S+)") or "")
    return first ~= "" and first or "unknown"
end

local function appendDeleteAudit(line)
    local auditPath = getHome() .. "/.stemwerk_setup_delete.log"
    local f = io.open(auditPath, "a")
    if not f then return end
    f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(line or "") .. "\n")
    f:close()
end

local function getModelsDeleteContext(runtime)
    local modelDir = resolvePath(getModelCacheDir())
    local baseDir = resolvePath((runtime and runtime.base) or getRuntimeBase())
    local modelNorm = normalizePathForSafety(modelDir)
    local baseNorm = normalizePathForSafety(baseDir)
    local homeNorm = normalizePathForSafety(getHome())
    local expectedSuffix = "/STEMwerk/models"
    local insideBase = (baseNorm ~= "") and (modelNorm == (baseNorm .. "/models") or modelNorm:sub(1, #baseNorm + 1) == (baseNorm .. "/"))
    local safeSuffix = modelNorm:sub(-#expectedSuffix) == expectedSuffix
    local unsafe = modelNorm == "" or modelNorm == "/" or modelNorm == baseNorm or modelNorm == homeNorm
    local canonOk, canonReason, targetCanon, expectedCanon = validateCanonicalDeleteTarget(modelDir, getModelCacheDir(), "models")
    return {
        modelDir = modelDir,
        baseDir = baseDir,
        unsafe = unsafe,
        safeSuffix = safeSuffix,
        insideBase = insideBase,
        canonOk = canonOk,
        canonReason = canonReason,
        targetCanon = targetCanon,
        expectedCanon = expectedCanon,
    }
end

local function deleteDownloadedModels(runtime, opts)
    opts = opts or {}

    local function fail(text, code)
        if not opts.noDialogs then
            msgBox("STEMwerk Setup", text, code or 16)
        end
        return false, text
    end

    local function info(text)
        if not opts.noDialogs then
            msgBox("STEMwerk Setup", text, 0)
        end
        return true, text
    end

    if OS == "Windows" then
        return fail("Delete models is currently available only on Linux/macOS in this setup flow.", 0)
    end

    local ctx = getModelsDeleteContext(runtime)
    local modelDir = ctx.modelDir
    local baseDir = ctx.baseDir
    local unsafe = ctx.unsafe
    local safeSuffix = ctx.safeSuffix
    local insideBase = ctx.insideBase
    local canonOk = ctx.canonOk

    appendSetupLog(runtime, "Delete-models selected", false)
    appendSetupLog(runtime, "Delete-models path: " .. tostring(modelDir), false)
    appendDeleteAudit("Delete-models selected path=" .. tostring(modelDir))

    if not pathExists(modelDir) then
        appendSetupLog(runtime, "Delete-models: directory does not exist", false)
        return info(
            "Model cache directory does not exist.\n\nPath: " .. tostring(modelDir) .. "\n\nNothing was deleted."
        )
    end

    if unsafe or not safeSuffix or not insideBase or not canonOk then
        appendSetupLog(runtime, "Delete-models blocked by safety checks", false)
        appendDeleteAudit("Delete-models blocked reason=" .. tostring(ctx.canonReason or "path_safety"))
        return fail(
            "Safety check blocked model deletion.\n\n"
                .. "Resolved path: " .. tostring(modelDir) .. "\n"
                .. "Expected under: " .. tostring(baseDir) .. "/models\n"
                .. "Canonical target: " .. tostring(ctx.targetCanon or "(unresolved)") .. "\n"
                .. "Canonical expected: " .. tostring(ctx.expectedCanon or "(unresolved)") .. "\n\n"
                .. "Nothing was deleted.",
            16
        )
    end

    local sizeText = estimateDirSize(modelDir)
    local empty = dirIsEmpty(modelDir)
    appendSetupLog(runtime, "Delete-models exists: yes", false)
    appendSetupLog(runtime, "Delete-models empty: " .. tostring(empty), false)
    appendSetupLog(runtime, "Delete-models estimated size: " .. tostring(sizeText), false)
    if empty then
        return info("Model cache is already empty.\n\nPath: " .. tostring(modelDir) .. "\n\nNothing was deleted.")
    end

    if not opts.skipConfirm then
        local confirm1 =
            "Delete downloaded STEMwerk models?\n\n"
            .. "Path: " .. tostring(modelDir) .. "\n"
            .. "Estimated size: " .. tostring(sizeText) .. "\n\n"
            .. "This cannot be undone.\n"
            .. "The models will need to be downloaded again later."
        if msgBox("STEMwerk Setup", confirm1, 4) ~= 6 then
            appendSetupLog(runtime, "Delete-models cancelled at first confirmation", false)
            return false, "Delete models cancelled."
        end

        local confirm2 =
            "Final confirmation:\n\n"
            .. "Delete downloaded STEMwerk models now?\n"
            .. "Path: " .. tostring(modelDir) .. "\n\n"
            .. "STEMwerk setup will reopen with live progress after deletion."
        if msgBox("STEMwerk Setup", confirm2, 4) ~= 6 then
            appendSetupLog(runtime, "Delete-models cancelled at second confirmation", false)
            return false, "Delete models cancelled."
        end
    end

    local trashRoot = (runtime and runtime.runtimeState or (baseDir .. PATH_SEP .. "state")) .. PATH_SEP .. "model-trash"
    ensureDir(trashRoot)
    local trashPath, trashErr = uniqueTrashPath(trashRoot, "models")
    if not trashPath then
        appendSetupLog(runtime, "Delete-models aborted: unable to allocate trash path (" .. tostring(trashErr) .. ")", false)
        appendDeleteAudit("Delete-models aborted trash reason=" .. tostring(trashErr))
        return fail("Unable to allocate a safe trash destination for models.\n\nNothing was deleted.", 16)
    end

    local moved = os.rename(modelDir, trashPath)
    if moved then
        appendSetupLog(runtime, "Delete-models moved to trash path: " .. tostring(trashPath), false)
        appendDeleteAudit("Delete-models moved to trash path=" .. tostring(trashPath))
        ensureDir(modelDir)
        exec("rm -rf " .. quoteArg(trashPath) .. " >/dev/null 2>&1 &", 1000)
        appendSetupLog(runtime, "Delete-models background cleanup started", false)
        appendDeleteAudit("Delete-models background cleanup started")
        return info(
            "Downloaded models were removed.\n\n"
                .. "Removed path: " .. tostring(modelDir) .. "\n\n"
                .. "STEMwerk setup will now reopen with live progress."
        )
    end

    appendSetupLog(runtime, "Delete-models move to trash failed; aborting safely", false)
    appendDeleteAudit("Delete-models move to trash failed; no direct delete fallback")
    return fail(
        "Failed to move downloaded model cache to a safe trash location.\n\nPath: " .. tostring(modelDir) .. "\n\nNothing was deleted.",
        16
    )
end

local function getRuntimeDeleteContext(runtime)
    local runtimeDir = resolvePath((runtime and runtime.base) or getRuntimeBase())
    local runtimeNorm = normalizePathForSafety(runtimeDir)
    local expectedNorm = normalizePathForSafety(getRuntimeBase())
    local homeNorm = normalizePathForSafety(getHome())
    local safeSuffix = runtimeNorm:sub(-9) == "/STEMwerk"
    local unsafe = runtimeNorm == "" or runtimeNorm == "/" or runtimeNorm == homeNorm
    local matchesExpected = (runtimeNorm ~= "" and expectedNorm ~= "") and PATH_HELPER.pathEquals(runtimeNorm, expectedNorm, OS)
    local canonOk, canonReason, targetCanon, expectedCanon = validateCanonicalDeleteTarget(runtimeDir, getRuntimeBase(), "runtime")
    return {
        runtimeDir = runtimeDir,
        runtimeNorm = runtimeNorm,
        expectedNorm = expectedNorm,
        unsafe = unsafe,
        safeSuffix = safeSuffix,
        matchesExpected = matchesExpected,
        canonOk = canonOk,
        canonReason = canonReason,
        targetCanon = targetCanon,
        expectedCanon = expectedCanon,
    }
end

local function deleteRuntimeBase(runtime, opts)
    opts = opts or {}

    local function fail(text, code)
        if not opts.noDialogs then
            msgBox("STEMwerk Setup", text, code or 16)
        end
        return false, text
    end

    local function info(text)
        if not opts.noDialogs then
            msgBox("STEMwerk Setup", text, 0)
        end
        return true, text
    end

    if OS == "Windows" then
        return fail("Delete runtime is currently available only on Linux/macOS in this setup flow.", 0)
    end

    local ctx = getRuntimeDeleteContext(runtime)
    local runtimeDir = ctx.runtimeDir
    local runtimeNorm = ctx.runtimeNorm
    local expectedNorm = ctx.expectedNorm
    local safeSuffix = ctx.safeSuffix
    local unsafe = ctx.unsafe
    local matchesExpected = ctx.matchesExpected
    local canonOk = ctx.canonOk

    appendSetupLog(runtime, "Delete-runtime selected", false)
    appendSetupLog(runtime, "Delete-runtime path: " .. tostring(runtimeDir), false)
    appendDeleteAudit("Delete-runtime selected path=" .. tostring(runtimeDir))

    if not pathExists(runtimeDir) then
        appendSetupLog(runtime, "Delete-runtime: directory does not exist", false)
        appendDeleteAudit("Delete-runtime directory missing")
        return info("Runtime directory does not exist.\n\nPath: " .. tostring(runtimeDir) .. "\n\nNothing was deleted.")
    end

    if unsafe or not safeSuffix or not matchesExpected or not canonOk then
        appendSetupLog(runtime, "Delete-runtime blocked by safety checks", false)
        appendDeleteAudit("Delete-runtime blocked reason=" .. tostring(ctx.canonReason or "path_safety"))
        return fail(
            "Safety check blocked runtime deletion.\n\n"
                .. "Resolved path: " .. tostring(runtimeDir) .. "\n"
                .. "Expected runtime: " .. tostring(expectedNorm) .. "\n"
                .. "Canonical target: " .. tostring(ctx.targetCanon or "(unresolved)") .. "\n"
                .. "Canonical expected: " .. tostring(ctx.expectedCanon or "(unresolved)") .. "\n\n"
                .. "Nothing was deleted.",
            16
        )
    end

    local sizeText = estimateDirSize(runtimeDir)
    local empty = dirIsEmpty(runtimeDir)
    appendSetupLog(runtime, "Delete-runtime exists: yes", false)
    appendSetupLog(runtime, "Delete-runtime empty: " .. tostring(empty), false)
    appendSetupLog(runtime, "Delete-runtime estimated size: " .. tostring(sizeText), false)
    appendDeleteAudit("Delete-runtime exists=yes empty=" .. tostring(empty) .. " size=" .. tostring(sizeText))
    if empty then
        return info("Runtime directory is already empty.\n\nPath: " .. tostring(runtimeDir) .. "\n\nNothing was deleted.")
    end

    if not opts.skipConfirm then
        local confirm1 =
            "Delete runtime - Full reset (venv, state, logs, models)?\n\n"
            .. "Path: " .. tostring(runtimeDir) .. "\n"
            .. "Estimated size: " .. tostring(sizeText) .. "\n\n"
            .. "This deletes runtime, .venv, state, logs, and downloaded models.\n"
            .. "This cannot be undone."
        if msgBox("STEMwerk Setup", confirm1, 4) ~= 6 then
            appendSetupLog(runtime, "Delete-runtime cancelled at first confirmation", false)
            appendDeleteAudit("Delete-runtime cancelled at first confirmation")
            return false, "Delete runtime cancelled."
        end

        local confirm2 =
            "Final confirmation:\n\n"
            .. "Delete runtime - Full reset now?\n"
            .. "Path: " .. tostring(runtimeDir) .. "\n\n"
            .. "STEMwerk setup will reopen with live progress after deletion."
        if msgBox("STEMwerk Setup", confirm2, 4) ~= 6 then
            appendSetupLog(runtime, "Delete-runtime cancelled at second confirmation", false)
            appendDeleteAudit("Delete-runtime cancelled at second confirmation")
            return false, "Delete runtime cancelled."
        end
    end

    local parent = runtimeNorm:match("^(.*)/[^/]+$") or ""
    if parent == "" or parent == "/" then
        appendSetupLog(runtime, "Delete-runtime aborted: unsafe parent", false)
        appendDeleteAudit("Delete-runtime aborted: unsafe parent")
        return fail("Runtime deletion aborted due to unsafe parent path.\n\nNothing was deleted.", 16)
    end

    local trashRoot = parent .. "/.stemwerk-runtime-trash"
    ensureDir(trashRoot)
    local trashPath, trashErr = uniqueTrashPath(trashRoot, "runtime")
    if not trashPath then
        appendDeleteAudit("Delete-runtime aborted trash reason=" .. tostring(trashErr))
        return fail("Unable to allocate a safe trash destination for runtime.\n\nNothing was deleted.", 16)
    end

    local moved = os.rename(runtimeDir, trashPath)
    if moved then
        appendDeleteAudit("Delete-runtime moved to trash path=" .. tostring(trashPath))
        exec("rm -rf " .. quoteArg(trashPath) .. " >/dev/null 2>&1 &", 1000)
        appendDeleteAudit("Delete-runtime background cleanup started")
        return info(
            "Runtime was removed.\n\n"
                .. "Removed path: " .. tostring(runtimeDir) .. "\n\n"
                .. "STEMwerk setup will now reopen with live progress."
        )
    end

    appendDeleteAudit("Delete-runtime move to trash failed; no direct delete fallback")
    return fail("Failed to move runtime directory to a safe trash location.\n\nPath: " .. tostring(runtimeDir) .. "\n\nNothing was deleted.", 16)
end

local function clearTransientSetupState(runtime)
    local stateFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.env"
    local pidFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.pid"
    local capFile = runtime.runtimeState .. PATH_SEP .. "capabilities.env"
    local guardPath = PATH_HELPER.getBootstrapGuardPath(runtime.runtimeState, PATH_SEP)
    os.remove(stateFile)
    os.remove(capFile)
    os.remove(pidFile)
    if guardPath and guardPath ~= "" then
        os.remove(guardPath)
    end
end

-- Verify-only path: fast file-existence checks only, no subprocess, no package import,
-- no io.popen. Opens the existing LINUX_SETUP window in pre-finalized mode so REAPER
-- never blocks. Heavy imports (torch, audio_separator) are intentionally skipped.
showDeferredFinalWindow = function(runtime, stateFile, logFile, finalMessage, finalSuccess, separatorScript, reuseWindow)
    if not gfx then
        msgBox("STEMwerk Setup", table.concat(finalMessage or {}, "\n"), finalSuccess and 0 or 16)
        return
    end

    local pidFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.pid"
    local capFile = runtime.runtimeState .. PATH_SEP .. "capabilities.env"
    if not reuseWindow then
        gfx.init(setupWindowTitle(setupUiLabel()), 1260, 904, 0, 120, 80)
    end
    LINUX_SETUP = {
        runtime         = runtime,
        mode            = "final",
        separatorScript = separatorScript,
        stateFile       = stateFile,
        logFile         = logFile,
        pidFile         = pidFile,
        capFile         = capFile,
        helpFile        = (OS == "Linux") and (RAW_SCRIPT_DIR .. "STEMwerk_Linux_Setup_Guide.txt")
                          or "https://www.reaper.fm/userguide.php",
        launchCmd       = nil,
        launchPending   = false,
        spinnerIndex    = 1,
        finalized       = true,
        finalMessage    = finalMessage,
        finalSuccess    = finalSuccess == true,
        summaryText     = table.concat(finalMessage or {}, "\n"),
        pidSeen         = false,
        startedAt       = os.time(),
        lastMouseCap    = 0,
        lastMouseWheel  = gfx.mouse_wheel or 0,
        fontScale       = getLinuxSetupFontScale(),
        logScroll       = 0,
        stepFillByIndex = {},
        lastStepIndex   = 4,
        lastProgressPct = 100,
        geometryRestored = false,
        windowGeometry  = captureLinuxWindowGeometry(),
    }
    reaper.defer(linuxSetupTick)
end

verifyExistingSetup = function(runtime, separatorScript)
    local stateFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.env"
    local logFile = runtime.runtimeLogs .. PATH_SEP .. "bootstrap.log"
    local pidFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.pid"
    local capFile = runtime.runtimeState .. PATH_SEP .. "capabilities.env"
    ensureDir(runtime.runtimeState)
    ensureDir(runtime.runtimeLogs)
    appendSetupLog(runtime, "Verify-only run (" .. setupUiLabel() .. ")", not fileExists(logFile))
    appendSetupLog(runtime, "Mode: verify-only (file checks, no subprocess, no package import)", false)
    appendSetupLog(runtime, "Models kept: " .. getModelCacheDir(), false)

    local state = parseStateFile(stateFile)
    local capState = parseStateFile(capFile)
    local pythonPath = trim(resolvePath(state.PYTHON_PATH or state.VENV_PYTHON or capState.PYTHON_PATH or resolveLinuxPythonPath(state)))
    local ffmpegPath = trim(resolvePath(state.FFMPEG_PATH or capState.FFMPEG_PATH or resolveLinuxFfmpegPath(state)))
    local stateStatus = state.STATUS or ""
    local stateOk = fileExists(stateFile) and state and next(state) ~= nil
        and (stateStatus == "ok" or stateStatus == "")

    local checks = {
        { label = "bootstrap.env",       ok = stateOk,
          detail = fileExists(stateFile) and ("Status: " .. tostring(stateStatus ~= "" and stateStatus or "ok")) or "Not found" },
        { label = "capabilities.env",    ok = fileExists(capFile),
          detail = fileExists(capFile) and capFile or "Not found" },
        { label = "Python path",         ok = pythonPath ~= "" and fileExists(pythonPath),
          detail = pythonPath ~= "" and pythonPath or "Not set in bootstrap.env" },
        { label = "FFmpeg path",         ok = ffmpegPath ~= "" and fileExists(ffmpegPath),
          detail = ffmpegPath ~= "" and ffmpegPath or "Not set in bootstrap.env/capabilities.env" },
        { label = "Virtual environment", ok = pathExists(runtime.venvDir),
          detail = pathExists(runtime.venvDir) and runtime.venvDir or ("Not found: " .. tostring(runtime.venvDir)) },
    }
    local allOk = true
    for _, c in ipairs(checks) do
        appendSetupLog(runtime, (c.ok and "  OK: " or "FAIL: ") .. c.label .. ": " .. tostring(c.detail), false)
        if not c.ok then allOk = false end
    end
    appendSetupLog(runtime, "Result: " .. (allOk and "OK (file checks passed)" or "FAIL (needs repair)"), false)
    appendSetupLog(runtime, "Note: imports (torch, audio_separator) not checked; run Repair if separation fails.", false)

    if runtime.base and runtime.base ~= "" then
        updateBootstrapEnv(stateFile, {
            RUNTIME_BASE = runtime.base,
            STEMWERK_SETUP_VERSION = SETUP_VERSION or "",
        })
    end

    local finalMessage = {}
    if allOk then
        finalMessage[#finalMessage + 1] = "Verify only: file checks passed."
        finalMessage[#finalMessage + 1] = "(Lightweight check only — imports and devices not verified)"
    else
        finalMessage[#finalMessage + 1] = "Verify only: one or more checks failed."
        finalMessage[#finalMessage + 1] = "Run Repair / rerun setup to fix the installation."
    end
    finalMessage[#finalMessage + 1] = ""
    for _, c in ipairs(checks) do
        finalMessage[#finalMessage + 1] = (c.ok and "[OK]  " or "[--]  ") .. c.label .. ": " .. tostring(c.detail)
    end
    finalMessage[#finalMessage + 1] = ""
    finalMessage[#finalMessage + 1] = "Log: " .. tostring(logFile)

    showDeferredFinalWindow(runtime, stateFile, logFile, finalMessage, allOk, separatorScript)
end

-- (showExistingRuntimeSetupMenu removed: replaced by non-blocking startExistingRuntimeSetupMenu below)

startLinuxSetup = function(runtime, separatorScript, mode)
    mode = tostring(mode or "repair")
    if mode ~= "repair" and mode ~= "rebuild-venv" then
        mode = "repair"
    end
    local stateFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.env"
    local logFile = runtime.runtimeLogs .. PATH_SEP .. "bootstrap.log"
    local pidFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.pid"
    local capFile = runtime.runtimeState .. PATH_SEP .. "capabilities.env"
    local guardPath = PATH_HELPER.getBootstrapGuardPath(runtime.runtimeState, PATH_SEP)
    ensureDir(runtime.runtimeState)
    ensureDir(runtime.runtimeLogs)

    clearTransientSetupState(runtime)
    if mode == "rebuild-venv" then
        appendSetupLog(runtime, "Setup run started (" .. setupUiLabel() .. ")", true)
        appendSetupLog(runtime, "Mode: rebuild-venv", false)
        appendSetupLog(runtime, "Keeping downloaded models: " .. getModelCacheDir(), false)
        appendSetupLog(runtime, "Removing virtual environment: " .. runtime.venvDir, false)
        local expectedVenv = resolvePath((runtime and runtime.base or getRuntimeBase()) .. PATH_SEP .. ".venv")
        local venvOk, venvReason, venvCanon, expectedVenvCanon = validateCanonicalDeleteTarget(runtime.venvDir, expectedVenv, "venv", true)
        if not venvOk then
            appendSetupLog(runtime, "Rebuild-venv blocked: " .. tostring(venvReason), false)
            appendDeleteAudit("Rebuild-venv blocked reason=" .. tostring(venvReason) .. " target=" .. tostring(venvCanon) .. " expected=" .. tostring(expectedVenvCanon))
            msgBox(
                "STEMwerk Setup",
                "Safety check blocked virtual environment rebuild.\n\n"
                    .. "Target: " .. tostring(runtime.venvDir) .. "\n"
                    .. "Canonical target: " .. tostring(venvCanon or "(unresolved)") .. "\n"
                    .. "Canonical expected: " .. tostring(expectedVenvCanon or "(unresolved)") .. "\n\n"
                    .. "Nothing was deleted.",
                16
            )
            return
        end
        local venvExistsBefore = pathExists(runtime.venvDir)
        appendSetupLog(runtime, "Rebuild-venv target exists before delete: " .. tostring(venvExistsBefore), false)
        appendSetupLog(runtime, "Rebuild-venv canonical target: " .. tostring(venvCanon or "(unresolved)"), false)
        appendSetupLog(runtime, "Rebuild-venv canonical expected: " .. tostring(expectedVenvCanon or "(unresolved)"), false)
        if venvExistsBefore then
            local okRemove, removeReason, removeRc, removeOut = removeDirRecursive(runtime.venvDir)
            if not okRemove then
                appendSetupLog(
                    runtime,
                    "Rebuild-venv delete failed: reason=" .. tostring(removeReason) .. " rc=" .. tostring(removeRc),
                    false
                )
                if removeOut and removeOut ~= "" then
                    appendSetupLog(runtime, "Rebuild-venv delete output: " .. tostring(removeOut), false)
                end
                appendDeleteAudit(
                    "Rebuild-venv delete failed path=" .. tostring(runtime.venvDir)
                        .. " reason=" .. tostring(removeReason)
                        .. " rc=" .. tostring(removeRc)
                )
                msgBox(
                    "STEMwerk Setup",
                    "Could not remove the virtual environment.\n\n"
                        .. "Target: " .. tostring(runtime.venvDir) .. "\n"
                        .. "Reason: " .. tostring(removeReason or "delete_failed") .. "\n\n"
                        .. "Close REAPER and try again, or remove this folder manually.\n\n"
                        .. "Log: " .. tostring(logFile),
                    16
                )
                return
            end
        end
        if pathExists(runtime.venvDir) then
            appendSetupLog(runtime, "Rebuild-venv delete failed: target still exists after delete attempt", false)
            appendDeleteAudit("Rebuild-venv delete failed path still exists=" .. tostring(runtime.venvDir))
            msgBox(
                "STEMwerk Setup",
                "Could not remove the virtual environment.\n\n"
                    .. "Target: " .. tostring(runtime.venvDir) .. "\n\n"
                    .. "Close REAPER and try again, or remove this folder manually.\n\n"
                    .. "Log: " .. tostring(logFile),
                16
            )
            return
        end
    else
        appendSetupLog(runtime, "Setup run started (" .. setupUiLabel() .. ")", true)
        appendSetupLog(runtime, "Mode: repair", false)
        appendSetupLog(runtime, "Keeping downloaded models: " .. getModelCacheDir(), false)
    end
    local sf = io.open(stateFile, "w")
    if sf then
        sf:write("STATUS=running\n")
        sf:write("STATUS_REASON=\n")
        sf:write("MODE=" .. tostring(mode) .. "\n")
        sf:close()
    end

    local scriptPath = PATH_HELPER.getBootstrapScriptPath(INSTALL_ROOT, OS, PATH_SEP)
    local launcherPath = PATH_HELPER.getBootstrapLauncherPath(INSTALL_ROOT, OS, PATH_SEP)
    if not fileExists(scriptPath) then
        PATH_HELPER.writeEnvFile(guardPath, {
            STATUS = "failed",
            REASON = "missing_bootstrap",
            SCRIPT_PATH = scriptPath,
            UPDATED_AT = os.time(),
        })
        msgBox("STEMwerk Setup", "Bootstrap script missing:\n\n" .. tostring(scriptPath), 0)
        return
    end

    local envPrefix = linuxEnvPrefix()
    local cmd
    if fileExists(launcherPath) then
        cmd = envPrefix .. '/bin/sh ' .. quoteArg(launcherPath)
            .. " --runtime-base " .. quoteArg(runtime.base)
            .. " --state-file " .. quoteArg(stateFile)
            .. " --log-file " .. quoteArg(logFile)
            .. " --mode " .. quoteArg(mode)
            .. " --pid-file " .. quoteArg(pidFile)
            .. " --bootstrap-script " .. quoteArg(scriptPath)
    else
        cmd = envPrefix .. '/bin/sh ' .. quoteArg(scriptPath)
            .. " --runtime-base " .. quoteArg(runtime.base)
            .. " --state-file " .. quoteArg(stateFile)
            .. " --log-file " .. quoteArg(logFile)
            .. " --mode " .. quoteArg(mode)
            .. " </dev/null >" .. quoteArg(logFile) .. " 2>&1 & echo $! > " .. quoteArg(pidFile)
    end

    PATH_HELPER.writeEnvFile(guardPath, {
        STATUS = "running",
        REASON = "launching",
        SCRIPT_PATH = scriptPath,
        UPDATED_AT = os.time(),
    })
    local launchPending = (OS == "macOS")
    if not launchPending then
        exec(cmd, 20000)
    end
    gfx.init(setupWindowTitle(setupUiLabel()), 1260, 904, 0, 120, 80)
    LINUX_SETUP = {
        runtime = runtime,
        mode = mode,
        separatorScript = separatorScript,
        stateFile = stateFile,
        logFile = logFile,
        pidFile = pidFile,
        capFile = capFile,
        helpFile = (OS == "Linux") and (RAW_SCRIPT_DIR .. "STEMwerk_Linux_Setup_Guide.txt")
            or "https://www.reaper.fm/userguide.php",
        launchCmd = launchPending and cmd or nil,
        launchPending = launchPending,
        spinnerIndex = 1,
        finalized = false,
        finalMessage = nil,
        pidSeen = false,
        startedAt = os.time(),
        finalSuccess = false,
        summaryText = "",
        lastMouseCap = 0,
        lastMouseWheel = gfx.mouse_wheel or 0,
        fontScale = getLinuxSetupFontScale(),
        logScroll = 0,
        stepFillByIndex = {},
        lastStepIndex = 1,
        lastProgressPct = 0,
        geometryRestored = false,
        windowGeometry = captureLinuxWindowGeometry(),
    }
    reaper.defer(linuxSetupTick)
end

-- Deferred tick for the existing-runtime setup mode selection menu.
-- Draws the window, handles input, and dispatches to verifyExistingSetup /
-- startLinuxSetup / cancel. Never blocks the REAPER UI thread.
local function existingRuntimeSetupMenuTick()
    if not SETUP_MENU then return end
    local m = SETUP_MENU
    local w, h = gfx.w, gfx.h

    local outerPad = math.max(10, math.floor(w * 0.02))
    local panelX = outerPad
    local panelY = math.max(12, math.floor(h * 0.03))
    local panelW = w - outerPad * 2
    local panelH = h - panelY - outerPad
    local bodyPad = math.max(10, linuxLineHeight(10))
    local bodyX = panelX + bodyPad
    local bodyY = panelY + bodyPad
    local bodyW = panelW - (bodyPad * 2)
    local choices = m.choices
    local modal = m.confirmModal

    local function cappedWrap(text, charWidth, maxLines)
        local lines = wrapLine(tostring(text or ""), math.max(8, charWidth or 8))
        if maxLines and #lines > maxLines then
            local out = {}
            for i = 1, maxLines do out[i] = lines[i] end
            out[maxLines] = out[maxLines] .. " ..."
            return out
        end
        return lines
    end

    -- Zoom controls: Ctrl+wheel, +/- and 0 use shared persisted scale helpers.
    local wheel = gfx.mouse_wheel or 0
    local lastWheel = m.lastMouseWheel or 0
    if wheel ~= lastWheel then
        local ctrlHeld = ((gfx.mouse_cap or 0) & 4) == 4
        if ctrlHeld then
            if wheel > lastWheel then
                adjustLinuxSetupFontScale(LINUX_SETUP_FONT_SCALE_STEP)
            else
                adjustLinuxSetupFontScale(-LINUX_SETUP_FONT_SCALE_STEP)
            end
        end
        m.lastMouseWheel = wheel
    end

    -- Background
    gfx.set(0.03, 0.03, 0.04, 1)
    gfx.rect(0, 0, w, h, 1)
    gfx.set(0.97, 0.55, 0.05, 1)
    gfx.rect(0, 0, w, math.max(8, linuxLineHeight(8)), 1)
    drawLinuxPanel(panelX, panelY, panelW, panelH, { 0.08, 0.08, 0.09, 1 }, { 0.26, 0.26, 0.29, 1 })

    local scale = m.fontScale or 1.0
    local compact = (w < 760 or h < 460 or scale >= 2.6)
    local tiny = (w < 560 or h < 360)
    local showSubs = not compact

    local cols = 3
    if bodyW < 980 or scale >= 2.2 then cols = 3 end
    if bodyW < 700 or scale >= 2.8 then cols = 2 end
    if bodyW < 420 then cols = 1 end

    local btnGapX = math.max(8, math.floor(linuxLineHeight(8)))
    local btnGapY = math.max(8, math.floor(linuxLineHeight(8)))

    local function buildButtonLayout(colCount, withSubs)
        local btnW = math.floor((bodyW - btnGapX * (colCount - 1)) / colCount)
        local subByChoice = {}
        local labelH = linuxLineHeight(16)
        local subH = linuxLineHeight(12)
        local subMaxLines = 1
        if withSubs then
            local subChars = math.max(8, math.floor((btnW - 20) / math.max(6, linuxFontSize(10) * 0.56)))
            local subCap = (scale >= 2.4) and 1 or 2
            for i, c in ipairs(choices) do
                local lines = cappedWrap(c.sub, subChars, subCap)
                subByChoice[i] = lines
                subMaxLines = math.max(subMaxLines, #lines)
            end
        else
            for i = 1, #choices do subByChoice[i] = {} end
        end

        local topPad = math.max(8, linuxLineHeight(8))
        local bottomPad = math.max(8, linuxLineHeight(8))
        local innerGap = withSubs and math.max(4, linuxLineHeight(4)) or 0
        local subtitleBlock = withSubs and (subMaxLines * subH) or 0
        local btnH = math.max(56, topPad + labelH + innerGap + subtitleBlock + bottomPad)
        local rows = math.ceil(#choices / colCount)
        local btnBlockH = rows * btnH + (rows - 1) * btnGapY
        local btnY = panelY + panelH - btnBlockH - math.max(10, linuxLineHeight(10))
        return {
            cols = colCount,
            btnW = btnW,
            btnH = btnH,
            btnY = btnY,
            labelH = labelH,
            subH = subH,
            innerGap = innerGap,
            subByChoice = subByChoice,
        }
    end

    local layout = buildButtonLayout(cols, showSubs)

    local footerText = string.format("Ctrl+wheel zooms text. Use +/- or 0 for text size. Esc = cancel.  Text %.0f%%", scale * 100)
    if compact then
        footerText = string.format("Ctrl+wheel / +/- / 0. Esc = cancel.  Text %.0f%%", scale * 100)
    end
    gfx.setfont(1, "Arial", linuxFontSize(11))
    local footerChars = math.max(16, math.floor(bodyW / math.max(6, linuxFontSize(11) * 0.56)))
    local footerLines = cappedWrap(footerText, footerChars, compact and 1 or 2)
    local footerLineH = linuxLineHeight(14)
    local footerH = #footerLines * footerLineH
    local footerBottomPad = math.max(8, linuxLineHeight(8))
    local footerY = panelY + panelH - footerBottomPad - footerH
    local tooltipTextH = linuxLineHeight(14)
    local tooltipBoxH = tooltipTextH + 4
    local tooltipY = footerY - math.max(6, linuxLineHeight(6)) - tooltipBoxH
    local rows = math.ceil(#choices / layout.cols)
    local btnBlockH = (rows * layout.btnH) + ((rows - 1) * btnGapY)
    layout.btnY = tooltipY - math.max(8, linuxLineHeight(8)) - btnBlockH
    local infoBottom = layout.btnY - math.max(8, linuxLineHeight(8))

    -- Info content is drawn only when it fits; this prevents overlap in tiny windows.
    local y = bodyY
    drawStemwerkInline(bodyX, y, linuxFontSize(22), "", "werk Setup [" .. setupUiLabel() .. "]")
    y = y + linuxLineHeight(30)

    gfx.setfont(1, "Arial Bold", linuxFontSize(14))
    gfx.set(0.92, 0.92, 0.94, 1)
    gfx.x = bodyX
    gfx.y = y
    gfx.drawstr("Existing runtime found. Choose what to do:")
    y = y + linuxLineHeight(26)

    if not tiny then
        local runtimeChars = math.max(18, math.floor((bodyW - 28) / math.max(6, linuxFontSize(12) * 0.58)))
        local runtimeLines = cappedWrap(tostring(m.runtime.base), runtimeChars, compact and 1 or 3)
        local pathBoxH = linuxLineHeight(18) + (#runtimeLines * linuxLineHeight(15)) + 14
        if y + pathBoxH <= infoBottom then
            drawLinuxPanel(bodyX, y, bodyW, pathBoxH, { 0.06, 0.06, 0.07, 1 }, { 0.19, 0.19, 0.22, 1 })
            gfx.setfont(1, "Arial", linuxFontSize(12))
            gfx.set(0.55, 0.57, 0.62, 1)
            gfx.x = bodyX + 14
            gfx.y = y + 6
            gfx.drawstr("Runtime:")
            gfx.setfont(1, "Courier New", linuxFontSize(12))
            gfx.set(0.86, 0.88, 0.92, 1)
            local pathY = y + 6 + linuxLineHeight(16)
            for _, line in ipairs(runtimeLines) do
                gfx.x = bodyX + 14
                gfx.y = pathY
                gfx.drawstr(line)
                pathY = pathY + linuxLineHeight(15)
            end
            y = y + pathBoxH + 10
        end
    end

    if not tiny then
        gfx.setfont(1, "Arial", linuxFontSize(12))
        local modelLabel = "Models: "
        local modelLabelW = gfx.measurestr(modelLabel)
        local modelChars = math.max(16, math.floor((bodyW - modelLabelW) / math.max(6, linuxFontSize(12) * 0.58)))
        local modelLines = cappedWrap(tostring(m.modelDir), modelChars, compact and 1 or 2)
        local modelH = math.max(1, #modelLines) * linuxLineHeight(16)
        if y + modelH <= infoBottom then
            gfx.set(0.55, 0.57, 0.62, 1)
            gfx.x = bodyX
            gfx.y = y
            gfx.drawstr(modelLabel)
            gfx.set(0.80, 0.82, 0.86, 1)
            for i, line in ipairs(modelLines) do
                gfx.x = bodyX + modelLabelW
                gfx.y = y + ((i - 1) * linuxLineHeight(16))
                gfx.drawstr(line)
            end
            y = y + modelH + linuxLineHeight(4)
        end
    end

    -- Version info block
    if not tiny and y + linuxLineHeight(16) <= infoBottom then
        gfx.setfont(1, "Arial", linuxFontSize(12))
        local cv = m.currentVersion or ""
        local lv = m.lastSetupVersion or ""
        if cv ~= "" or lv ~= "" then
            local verLabel = "Setup script: v" .. (cv ~= "" and cv or "?")
            if lv ~= "" then
                verLabel = verLabel .. "   Last run: v" .. lv
            else
                verLabel = verLabel .. "   Last run: (unknown)"
            end
            gfx.set(0.55, 0.57, 0.62, 1)
            gfx.x = bodyX
            gfx.y = y
            gfx.drawstr(verLabel)
            y = y + linuxLineHeight(16)
        end
    end

    if OS == "Windows" and m.windowsOverview then
        local o = m.windowsOverview
        local statusLine = "Last setup: " .. tostring(prettySetupStatus(o.setupStatus))
        if trim(o.setupReason or "") ~= "" then
            statusLine = statusLine .. " (" .. tostring(prettySetupReason(o.setupReason)) .. ")"
        end
        local rows = {
            "Profile/backend: " .. tostring(o.profile) .. " / " .. tostring(o.backend),
            "Python: " .. tostring(o.pythonPath) .. " [" .. tostring(o.pythonSource) .. "]",
            "FFmpeg: " .. tostring(o.ffmpegPath),
            "Verification: " .. tostring(o.verification),
            "audio_separator: " .. tostring(o.deps.audio_separator),
            "stemwerk_core: " .. tostring(o.deps.stemwerk_core),
            "samplerate: " .. tostring(o.deps.samplerate),
            "julius: " .. tostring(o.deps.julius),
        }
        if y + linuxLineHeight(16) <= infoBottom then
            gfx.setfont(1, "Arial", linuxFontSize(12))
            gfx.set(o.needsRepair and 0.97 or 0.55, o.needsRepair and 0.80 or 0.57, o.needsRepair and 0.15 or 0.62, 1)
            gfx.x = bodyX
            gfx.y = y
            gfx.drawstr(statusLine)
            y = y + linuxLineHeight(16)
        end
        local rowChars = math.max(18, math.floor((bodyW - 20) / math.max(6, linuxFontSize(11) * 0.56)))
        gfx.setfont(1, "Arial", linuxFontSize(11))
        gfx.set(0.78, 0.80, 0.84, 1)
        for _, line in ipairs(rows) do
            local wrapped = cappedWrap(line, rowChars, 2)
            for _, wl in ipairs(wrapped) do
                if y + linuxLineHeight(14) > infoBottom then break end
                gfx.x = bodyX
                gfx.y = y
                gfx.drawstr(wl)
                y = y + linuxLineHeight(14)
            end
            if y + linuxLineHeight(14) > infoBottom then break end
        end
    end

    if m.updateDetected and y + linuxLineHeight(18) <= infoBottom then
        gfx.setfont(1, "Arial Bold", linuxFontSize(12))
        gfx.set(0.97, 0.80, 0.15, 1)
        gfx.x = bodyX
        gfx.y = y
        gfx.drawstr("Update detected — Repair recommended to apply new dependencies.")
        y = y + linuxLineHeight(18)
    end

    if not compact and y + linuxLineHeight(18) <= infoBottom then
        gfx.setfont(1, "Arial", linuxFontSize(12))
        gfx.set(0.38, 0.72, 0.46, 1)
        gfx.x = bodyX
        gfx.y = y
        gfx.drawstr("Models are kept in Check only, Repair, and Rebuild venv.")
        y = y + linuxLineHeight(18)
    end

    if not compact and y + linuxLineHeight(18) <= infoBottom then
        gfx.setfont(1, "Arial", linuxFontSize(12))
        gfx.set(0.90, 0.52, 0.24, 1)
        gfx.x = bodyX
        gfx.y = y
        gfx.drawstr("Delete models... and Delete runtime... are destructive advanced actions.")
        y = y + linuxLineHeight(18)
    end

    if y + linuxLineHeight(18) <= infoBottom then
        gfx.setfont(1, "Arial Bold", linuxFontSize(13))
        if m.updateDetected then
            gfx.set(0.97, 0.80, 0.15, 1)
            gfx.x = bodyX
            gfx.y = y
            gfx.drawstr("Update detected — run Repair to apply changes")
        else
            gfx.set(0.20, 0.92, 0.28, 1)
            gfx.x = bodyX
            gfx.y = y
            gfx.drawstr("Existing runtime detected - choose an action below")
        end
        y = y + linuxLineHeight(22)
    end

    -- Mid panel: content-sized summary box (no empty space).
    local midPanelY = y + linuxLineHeight(6)
    local midPanelAvailH = (footerY - math.max(10, linuxLineHeight(10))) - midPanelY
    local perItem = linuxLineHeight(16)
    local cv = m.currentVersion or ""
    local lv = m.lastSetupVersion or ""
    local verRow = ""
    if cv ~= "" then
        verRow = "Script v" .. cv
        if lv ~= "" then
            verRow = verRow .. "  |  Last setup v" .. lv
            if m.updateDetected then verRow = verRow .. "  ← update" end
        end
    end
    local hasVerRow = verRow ~= ""
    local contentH = 12 + linuxLineHeight(18)
        + (hasVerRow and linuxLineHeight(16) or 0)
        + #choices * perItem
        + 10
    local midPanelH = math.min(contentH, midPanelAvailH)
    if midPanelH >= linuxLineHeight(40) then
        drawLinuxPanel(bodyX, midPanelY, bodyW, midPanelH, { 0.06, 0.06, 0.07, 1 }, { 0.22, 0.22, 0.24, 1 })

        local iy = midPanelY + 12
        gfx.setfont(1, "Arial Bold", linuxFontSize(13))
        gfx.set(0.92, 0.92, 0.94, 1)
        gfx.x = bodyX + 12
        gfx.y = iy
        gfx.drawstr("Mode summary")
        iy = iy + linuxLineHeight(18)

        if hasVerRow and iy + linuxLineHeight(16) <= midPanelY + midPanelH - 10 then
            gfx.setfont(1, "Arial", linuxFontSize(11))
            gfx.set(m.updateDetected and 0.97 or 0.45, m.updateDetected and 0.80 or 0.47, m.updateDetected and 0.15 or 0.54, 1)
            gfx.x = bodyX + 12
            gfx.y = iy
            gfx.drawstr(verRow)
            iy = iy + linuxLineHeight(16)
        end

        local maxItems = math.max(1, math.floor(((midPanelY + midPanelH - 10) - iy) / perItem))
        local shown = math.min(#choices, maxItems)
        for i = 1, shown do
            local c = choices[i]
            local summaryLabel = tostring(c.label or ""):gsub("%.%.%.$", "")
            gfx.set(c.accent[1], c.accent[2], c.accent[3], 1)
            gfx.rect(bodyX + 12, iy + 4, 6, math.max(6, linuxLineHeight(6)), 1)
            gfx.setfont(1, "Arial", linuxFontSize(12))
            gfx.set(0.82, 0.84, 0.88, 1)
            gfx.x = bodyX + 24
            gfx.y = iy
            gfx.drawstr(summaryLabel .. " - " .. c.sub)
            iy = iy + perItem
        end
    end

    local hoveredChoice = nil
    local chosen = nil
    for i, c in ipairs(choices) do
        local row = math.floor((i - 1) / layout.cols)
        local col = (i - 1) % layout.cols
        local bx = bodyX + col * (layout.btnW + btnGapX)
        local by = layout.btnY + row * (layout.btnH + btnGapY)
        local hot = isMouseIn(bx, by, layout.btnW, layout.btnH)
        if hot then hoveredChoice = c end

        local acc = c.accent
        local topH = math.max(5, linuxLineHeight(5))
        gfx.set(0.16, 0.16, 0.17, 1)
        gfx.rect(bx, by, layout.btnW, layout.btnH, 1)
        gfx.set(0.28, 0.28, 0.30, 1)
        gfx.rect(bx, by, layout.btnW, layout.btnH, 0)
        gfx.set(acc[1], acc[2], acc[3], hot and 1.0 or 0.72)
        gfx.rect(bx, by, layout.btnW, topH, 1)
        if hot then
            gfx.set(acc[1], acc[2], acc[3], 0.25)
            gfx.rect(bx + 1, by + topH + 1, layout.btnW - 2, layout.btnH - topH - 2, 1)
        end

        local subLines = layout.subByChoice[i] or {}
        local contentH = layout.labelH + ((#subLines > 0) and (layout.innerGap + (#subLines * layout.subH)) or 0)
        local contentY = by + math.max(6, math.floor((layout.btnH - contentH) / 2))

        gfx.setfont(1, "Arial Bold", linuxFontSize(14))
        gfx.set(1, 1, 1, 1)
        local lw = gfx.measurestr(c.label)
        gfx.x = bx + math.floor((layout.btnW - lw) / 2)
        gfx.y = contentY
        gfx.drawstr(c.label)

        if #subLines > 0 then
            gfx.setfont(1, "Arial", linuxFontSize(10))
            gfx.set(0.84, 0.84, 0.86, hot and 0.98 or 0.70)
            local subY = contentY + layout.labelH + layout.innerGap
            for _, line in ipairs(subLines) do
                local sw = gfx.measurestr(line)
                gfx.x = bx + math.floor((layout.btnW - sw) / 2)
                gfx.y = subY
                gfx.drawstr(line)
                subY = subY + layout.subH
            end
        end
    end

    -- Optional tooltip line for hovered action (extra user info)
    if hoveredChoice then
        local tip = hoveredChoice.label .. ": " .. hoveredChoice.sub
        gfx.setfont(1, "Arial", linuxFontSize(11))
        local tipChars = math.max(14, math.floor(bodyW / math.max(6, linuxFontSize(11) * 0.56)))
        local tipLines = cappedWrap(tip, tipChars, 1)
        local tipY = tooltipY + math.max(1, math.floor((tooltipBoxH - tooltipTextH) / 2))
        if tooltipY >= bodyY then
            gfx.set(0.14, 0.14, 0.15, 0.98)
            gfx.rect(bodyX, tooltipY, bodyW, tooltipBoxH, 1)
            gfx.set(0.26, 0.26, 0.30, 1)
            gfx.rect(bodyX, tooltipY, bodyW, tooltipBoxH, 0)
            gfx.set(0.85, 0.87, 0.90, 1)
            gfx.x = bodyX + 6
            gfx.y = tipY
            gfx.drawstr(tipLines[1] or "")
        end
    end

    gfx.setfont(1, "Arial", linuxFontSize(11))
    gfx.set(0.40, 0.42, 0.46, 1)
    local footerLineY = footerY
    for _, line in ipairs(footerLines) do
        gfx.x = bodyX
        gfx.y = footerLineY
        gfx.drawstr(line)
        footerLineY = footerLineY + footerLineH
    end

    if m.noticeText and m.noticeText ~= "" then
        local showNotice = (not m.noticeUntil) or (os.time() <= m.noticeUntil)
        if showNotice then
            local noticeChars = math.max(16, math.floor(bodyW / math.max(6, linuxFontSize(11) * 0.56)))
            local noticeLines = cappedWrap(m.noticeText, noticeChars, 2)
            local noticeH = (#noticeLines * linuxLineHeight(14)) + 6
            local noticeY = layout.btnY - noticeH - math.max(6, linuxLineHeight(6))
            if noticeY >= bodyY then
                gfx.set(0.13, 0.18, 0.14, 0.96)
                gfx.rect(bodyX, noticeY, bodyW, noticeH, 1)
                gfx.set(0.22, 0.34, 0.24, 1)
                gfx.rect(bodyX, noticeY, bodyW, noticeH, 0)
                gfx.set(0.82, 0.95, 0.84, 1)
                gfx.setfont(1, "Arial", linuxFontSize(11))
                local ny = noticeY + 3
                for _, line in ipairs(noticeLines) do
                    gfx.x = bodyX + 6
                    gfx.y = ny
                    gfx.drawstr(line)
                    ny = ny + linuxLineHeight(14)
                end
            end
        else
            m.noticeText = nil
            m.noticeUntil = nil
        end
    end

    local modalYes = nil
    local modalNo = nil
    if modal then
        gfx.set(0, 0, 0, 0.60)
        gfx.rect(panelX, panelY, panelW, panelH, 1)

        local mw = math.max(520, math.floor(bodyW * 0.74))
        local mh = math.max(220, linuxLineHeight(210))
        local mx = bodyX + math.floor((bodyW - mw) / 2)
        local my = bodyY + math.max(20, math.floor((panelH - mh) / 2))
        drawLinuxPanel(mx, my, mw, mh, { 0.12, 0.12, 0.13, 1 }, { 0.30, 0.30, 0.32, 1 })

        local tx = mx + 14
        local ty = my + 12
        local isRuntime = modal.kind == "runtime"
        local title
        if modal.step == 1 then
            title = isRuntime and "Delete runtime - Full reset?" or "Delete downloaded models?"
        else
            title = "Final confirmation"
        end
        gfx.setfont(1, "Arial Bold", linuxFontSize(15))
        gfx.set(0.95, 0.95, 0.96, 1)
        gfx.x = tx
        gfx.y = ty
        gfx.drawstr(title)
        ty = ty + linuxLineHeight(24)

        gfx.setfont(1, "Arial", linuxFontSize(12))
        gfx.set(0.84, 0.86, 0.90, 1)
        local bodyLines = {
            "Path: " .. tostring(modal.runtimeDir or ""),
            "Estimated size: " .. tostring(modal.sizeText or "unknown"),
            "",
        }
        if modal.step == 1 then
            if isRuntime then
                bodyLines[#bodyLines + 1] = "This deletes runtime, .venv, state, logs, and downloaded models."
                bodyLines[#bodyLines + 1] = "This cannot be undone."
            else
                bodyLines[#bodyLines + 1] = "This deletes only the downloaded model cache."
                bodyLines[#bodyLines + 1] = "Models will be downloaded again when needed."
            end
        else
            if isRuntime then
                bodyLines[#bodyLines + 1] = "Delete runtime - Full reset now?"
            else
                bodyLines[#bodyLines + 1] = "Delete downloaded models now?"
            end
            bodyLines[#bodyLines + 1] = "Setup will reopen with live progress after deletion."
        end
        for _, line in ipairs(bodyLines) do
            gfx.x = tx
            gfx.y = ty
            gfx.drawstr(line)
            ty = ty + linuxLineHeight(16)
        end

        local bW = math.max(96, linuxLineHeight(88))
        local bH = math.max(28, linuxLineHeight(26))
        local bGap = 10
        local by = my + mh - bH - 12
        local bx2 = mx + mw - bW - 14
        local bx1 = bx2 - bGap - bW
        modalYes = { x = bx1, y = by, w = bW, h = bH }
        modalNo = { x = bx2, y = by, w = bW, h = bH }
        drawButton((modal.step == 1) and "Yes" or "Delete", modalYes.x, modalYes.y, modalYes.w, modalYes.h)
        drawButton("Cancel", modalNo.x, modalNo.y, modalNo.w, modalNo.h)
    end

    local ch = gfx.getchar()
    if modal then
        if ch < 0 or ch == 27 then
            m.confirmModal = nil
            gfx.update()
            reaper.defer(existingRuntimeSetupMenuTick)
            return
        end

        local mouseDown = (gfx.mouse_cap & 1) == 1
        local lastModalMouse = m.modalMouseWasDown or false
        if mouseDown and not lastModalMouse then
            if modalYes and isMouseIn(modalYes.x, modalYes.y, modalYes.w, modalYes.h) then
                if modal.step == 1 then
                    modal.step = 2
                else
                    local ok, msg
                    if modal.kind == "models" then
                        ok, msg = deleteDownloadedModels(m.runtime, { skipConfirm = true, noDialogs = true })
                    else
                        ok, msg = deleteRuntimeBase(m.runtime, { skipConfirm = true, noDialogs = true })
                    end
                    m.confirmModal = nil
                    if ok then
                        if modal.kind == "models" then
                            m.noticeText = msg or "Model cache deleted."
                            m.noticeUntil = os.time() + 10
                        else
                            local runtime = m.runtime
                            local separatorScript = m.separatorScript
                            if msg and msg ~= "" then
                                msgBox("STEMwerk Setup", tostring(msg), 0)
                            end
                            gfx.quit()
                            SETUP_MENU = nil
                            verifyExistingSetup(runtime, separatorScript)
                        end
                        return
                    end
                    m.noticeText = msg or "Delete action failed."
                    m.noticeUntil = os.time() + 8
                end
            elseif modalNo and isMouseIn(modalNo.x, modalNo.y, modalNo.w, modalNo.h) then
                m.confirmModal = nil
            end
        end
        m.modalMouseWasDown = mouseDown
        gfx.update()
        reaper.defer(existingRuntimeSetupMenuTick)
        return
    end

    if ch == 43 or ch == 61 then
        adjustLinuxSetupFontScale(LINUX_SETUP_FONT_SCALE_STEP)
    elseif ch == 45 or ch == 95 then
        adjustLinuxSetupFontScale(-LINUX_SETUP_FONT_SCALE_STEP)
    elseif ch == 48 then
        resetLinuxSetupFontScale()
    elseif ch < 0 or ch == 27 then
        chosen = "cancel"
    end

    if not chosen then
        local mouseDown = (gfx.mouse_cap & 1) == 1
        if mouseDown and not m.mouseWasDown then
            for i, c in ipairs(choices) do
                local row = math.floor((i - 1) / layout.cols)
                local col = (i - 1) % layout.cols
                local bx = bodyX + col * (layout.btnW + btnGapX)
                local by = layout.btnY + row * (layout.btnH + btnGapY)
                if isMouseIn(bx, by, layout.btnW, layout.btnH) then
                    chosen = c.id
                    break
                end
            end
        end
        m.mouseWasDown = mouseDown
    end

    gfx.update()

    if chosen == "open-logs" then
        openPath(m.runtime.runtimeLogs)
        reaper.defer(existingRuntimeSetupMenuTick)
        return
    end

    if chosen == "open-runtime" then
        openPath(m.runtime.base)
        reaper.defer(existingRuntimeSetupMenuTick)
        return
    end

    if chosen == "delete-runtime" then
        local ctx = getRuntimeDeleteContext(m.runtime)
        m.confirmModal = {
            step = 1,
            kind = "runtime",
            runtimeDir = ctx.runtimeDir,
            sizeText = estimateDirSize(ctx.runtimeDir),
        }
        reaper.defer(existingRuntimeSetupMenuTick)
        return
    end

    if chosen == "delete-models" then
        local ctx = getModelsDeleteContext(m.runtime)
        m.confirmModal = {
            step = 1,
            kind = "models",
            runtimeDir = ctx.modelDir,
            sizeText = estimateDirSize(ctx.modelDir),
        }
        reaper.defer(existingRuntimeSetupMenuTick)
        return
    end

    if chosen then
        local runtime = m.runtime
        local separatorScript = m.separatorScript
        SETUP_MENU = nil
        if chosen == "verify" then
            if OS == "Windows" then
                windowsVerifyStart(runtime, separatorScript, true)
            else
                gfx.quit()
                verifyExistingSetup(runtime, separatorScript)
            end
        elseif chosen == "repair" or chosen == "rebuild-venv" then
            if OS == "Windows" then
                windowsVerifyStart(runtime, separatorScript, true)
            else
                gfx.quit()
                startLinuxSetup(runtime, separatorScript, chosen)
            end
        elseif chosen == "support-bundle" then
            gfx.quit()
            reaper.defer(function()
                runSupportBundleAction()
            end)
        elseif chosen == "cancel" then
            gfx.quit()
        end
        return
    end

    reaper.defer(existingRuntimeSetupMenuTick)
end

-- Initializes the gfx window and kicks off the deferred menu tick.
-- Returns immediately; REAPER remains responsive while the menu is open.
local function startExistingRuntimeSetupMenu(runtime, separatorScript)
    local stateFileForVer = runtime.runtimeState .. PATH_SEP .. "bootstrap.env"
    local storedState = fileExists(stateFileForVer) and parseStateFile(stateFileForVer) or {}
    local lastSetupVersion = trim(storedState.STEMWERK_SETUP_VERSION or "")
    local currentVersion = SETUP_VERSION or ""
    local versionMatch = (lastSetupVersion == "" or lastSetupVersion == currentVersion)
    local updateDetected = (lastSetupVersion ~= "" and lastSetupVersion ~= currentVersion)

    local windowsOverview = nil
    if OS == "Windows" then
        windowsOverview = buildWindowsSetupOverview(runtime, currentVersion, lastSetupVersion)
    end

    local choices = {
        { id = "verify",       label = "Check only",   sub = "Fast check, no reinstall",         accent = { 0.22, 0.70, 0.50 } },
        { id = "repair",       label = "Repair",        sub = "Rerun setup, keep models",          accent = { 0.92, 0.55, 0.10 } },
        { id = "rebuild-venv", label = "Rebuild venv",  sub = "Recreate Python env, keep models", accent = { 0.45, 0.52, 0.90 } },
        { id = "support-bundle", label = "Save Support Bundle", sub = "Collect logs and diagnostics, no changes", accent = { 0.26, 0.60, 0.88 } },
        { id = "open-logs",    label = "Open logs folder", sub = "Open runtime logs", accent = { 0.35, 0.56, 0.82 } },
        { id = "open-runtime", label = "Open runtime folder", sub = "Open runtime base", accent = { 0.35, 0.56, 0.82 } },
    }
    if OS ~= "Windows" then
        choices[#choices + 1] = { id = "delete-models",label = "Delete models...", sub = "Cache reset; re-download when needed",  accent = { 0.88, 0.28, 0.28 } }
        choices[#choices + 1] = { id = "delete-runtime",label = "Delete runtime...", sub = "Full reset; removes venv + models", accent = { 0.82, 0.22, 0.22 } }
    end
    choices[#choices + 1] = { id = "cancel", label = "Cancel", sub = "Exit without changes", accent = { 0.38, 0.38, 0.42 } }

    SETUP_MENU = {
        runtime         = runtime,
        separatorScript = separatorScript,
        modelDir        = getModelCacheDir(),
        mouseWasDown    = false,
        lastMouseWheel  = gfx.mouse_wheel or 0,
        fontScale       = math.max(getLinuxSetupFontScale(), LINUX_SETUP_FONT_SCALE_DEFAULT),
        currentVersion  = currentVersion,
        lastSetupVersion = lastSetupVersion,
        updateDetected  = updateDetected,
        windowsOverview = windowsOverview,
        choices = choices,
    }
    gfx.init(setupWindowTitle(setupUiLabel()), SETUP_MENU_DEFAULT_W, SETUP_MENU_DEFAULT_H, 0, 120, 80)
    reaper.defer(existingRuntimeSetupMenuTick)
end

local function shouldSkipMacBootstrap(runtime)
    if OS ~= "macOS" then return false end
    if not PATH_HELPER then return false end
    local guardPath = PATH_HELPER.getBootstrapGuardPath(runtime.runtimeState, PATH_SEP)
    if not guardPath or guardPath == "" or not fileExists(guardPath) then return false end
    local guard = readBootstrapGuard(guardPath)
    if tostring(guard.STATUS or "") ~= "ok" or tostring(guard.REASON or "") ~= "completed" then
        return false
    end
    local stateFile = runtime.runtimeState .. PATH_SEP .. "bootstrap.env"
    if not fileExists(stateFile) then return false end
    local state = parseStateFile(stateFile)
    if not state or next(state) == nil then return false end
    if state.RUNTIME_BASE and state.RUNTIME_BASE ~= "" and runtime.base and runtime.base ~= "" then
        if not PATH_HELPER.pathEquals(state.RUNTIME_BASE, runtime.base, OS) then return false end
    end
    local verification = verifyRuntimePaths(state)
    local ok = verification and verification.pythonOk and verification.ffmpegOk and #(verification.errors or {}) == 0
    if not ok then return false end
    local logFile = runtime.runtimeLogs .. PATH_SEP .. "bootstrap.log"
    return true, stateFile, logFile, state
end

local function main()
    local runtime = getRuntimePaths()
    local hasRuntime = runtimeLooksPresent(runtime)
    setExt("runtimeBase", runtime.base)
    local separatorScript = SCRIPT_DIR .. "audio_separator_process.py"
    if fileExists(separatorScript) then
        setExt("separatorScript", separatorScript)
    end

    if OS == "Windows" then
        startExistingRuntimeSetupMenu(runtime, separatorScript)
        return
    end

    if OS == "Linux" or OS == "macOS" then
        if hasRuntime then
            startExistingRuntimeSetupMenu(runtime, separatorScript)
            return
        end

        local intro =
            "Run this setup once in REAPER before using STEMwerk.lua.\n\n"
            .. "STEMwerk will prepare a runtime in:\n  " .. runtime.base .. "\n\n"
            .. "Downloaded models will be kept in:\n  " .. getModelCacheDir() .. "\n\n"
            .. "Continue with first-time setup?"
        if msgBox("STEMwerk Setup", intro, 4) ~= 6 then
            return
        end

        if OS == "macOS" then
            local skip, stateFile, logFile, state = shouldSkipMacBootstrap(runtime)
            if skip then
                local result = safePerformPostBootstrap(runtime, stateFile, logFile, true, state, separatorScript)
                showDeferredFinalWindow(runtime, stateFile, logFile, result.finalMessage, result.success, separatorScript)
                return
            end
        end

        startLinuxSetup(runtime, separatorScript, "repair")
        return
    end

    local bootstrapSuccess, stateFile, logFile, bootstrapState = runBootstrap(runtime)
    local result = safePerformPostBootstrap(runtime, stateFile, logFile, bootstrapSuccess, bootstrapState, separatorScript)
    if OS == "Windows" then
        showStatusWindow(stateFile, logFile, table.concat(result.finalMessage, "\n"))
    else
        showDeferredFinalWindow(runtime, stateFile, logFile, result.finalMessage, result.success, separatorScript)
    end
end

main()
