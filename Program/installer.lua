-- Installer/updater for kenzu_cc.
-- Recommended usage:
-- wget run <installer URL> ws://93.170.246.220:3000/ws <access-token>

local arguments = { ... }

local REPOSITORY_BASE_URL =
    "https://raw.githubusercontent.com/kenzu926/kenzu_cc/refs/heads/main/Program/"

local FILES = {
    "installer.lua",
    "startup.lua",
    "update.lua",
    "update_agent.lua",
    "ws_client.lua",
    "gateway_client.lua",
    "gateway.lua",
    "console.lua",
    "reactor.lua",
    "me_node.lua",
    "turbine.lua",
    "remote_terminal.lua",
    "overview_monitor.lua",
    "overview_relay.lua",
    "service_runner.lua",
}

-- The updater passes its own directory as argument 4. A direct `wget run`
-- installation keeps using the directory in which the command was started.
local installDirectory = arguments[4]
if installDirectory == nil then installDirectory = shell.dir() end

local function installPath(fileName)
    return fs.combine(installDirectory, fileName)
end

local function removeIfPresent(path)
    if fs.exists(path) then
        fs.delete(path)
    end
end

local function cleanTemporaryFiles()
    for _, fileName in ipairs(FILES) do
        removeIfPresent(installPath(fileName) .. ".download")
    end
end

local function download(fileName)
    local url = REPOSITORY_BASE_URL .. fileName
    local response, requestError, errorResponse = http.get(url, {
        ["Cache-Control"] = "no-cache",
    })

    if not response then
        if errorResponse then
            errorResponse.close()
        end
        return false, requestError or "request failed"
    end

    local responseCode = response.getResponseCode()
    local source = response.readAll()
    response.close()

    if responseCode ~= 200 then
        return false, "GitHub returned HTTP " .. tostring(responseCode)
    end
    if not source or #source == 0 then
        return false, "GitHub returned an empty file"
    end

    local compiled, syntaxError = load(source, "@" .. fileName)
    if not compiled then
        return false, "Lua syntax error: " .. tostring(syntaxError)
    end

    local temporaryPath = installPath(fileName) .. ".download"
    removeIfPresent(temporaryPath)

    local output, openError = fs.open(temporaryPath, "w")
    if not output then
        return false, openError or "cannot create temporary file"
    end

    output.write(source)
    output.close()
    return true
end

local originalExisted = {}
local backupCreated = {}

local function restoreBackups()
    for _, fileName in ipairs(FILES) do
        local destination = installPath(fileName)
        local backup = destination .. ".backup"

        if backupCreated[fileName] and fs.exists(backup) then
            removeIfPresent(destination)
            fs.move(backup, destination)
        elseif not originalExisted[fileName] then
            -- This file did not exist before installation.
            removeIfPresent(destination)
        end
    end
end

if not http then
    printError("HTTP API is disabled. Cannot install project files.")
    return
end

print("Downloading kenzu_cc...")
cleanTemporaryFiles()

for _, fileName in ipairs(FILES) do
    write("  " .. fileName .. "... ")
    local downloaded, downloadError = download(fileName)

    if not downloaded then
        printError("FAILED")
        printError(tostring(downloadError))
        cleanTemporaryFiles()
        return
    end

    print("OK")
end

local installed, installError = pcall(function()
    for _, fileName in ipairs(FILES) do
        local destination = installPath(fileName)
        local backup = destination .. ".backup"

        removeIfPresent(backup)
        originalExisted[fileName] = fs.exists(destination)
        if originalExisted[fileName] then
            fs.move(destination, backup)
            backupCreated[fileName] = true
        end
    end

    for _, fileName in ipairs(FILES) do
        local destination = installPath(fileName)
        fs.move(destination .. ".download", destination)
    end
end)

if not installed then
    restoreBackups()
    cleanTemporaryFiles()
    printError("Installation failed: " .. tostring(installError))
    return
end

for _, fileName in ipairs(FILES) do
    removeIfPresent(installPath(fileName) .. ".backup")
end

if arguments[1] and arguments[1] ~= "" then
    settings.set("kenzu.serverUrl", arguments[1])
end
if arguments[2] and arguments[2] ~= "" then
    settings.set("kenzu.serverToken", arguments[2])
end
settings.set("kenzu.lastInstallAt", os.epoch("utc"))
settings.set("kenzu.lastInstallId", arguments[3] or tostring(os.epoch("utc")))
settings.save(installPath("server.settings"))

term.setTextColor(colors.lime)
print("Installation complete.")
term.setTextColor(colors.white)
if arguments[1] then
    print("WebSocket server: " .. arguments[1])
end
if arguments[2] then
    print("Access token saved.")
end
print("Run 'startup' now, or use 'reboot' to start automatically.")
