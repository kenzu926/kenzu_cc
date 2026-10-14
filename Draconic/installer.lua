-- Installer for the standalone Draconic reactor controller (Draconic/).
-- Usage:
--   wget run https://raw.githubusercontent.com/kenzu926/kenzu_cc/refs/heads/main/Draconic/installer.lua <ws(s)://host:port/ws> <access-token>
-- API modules (peripherals, gateway_client, ...) are frozen duplicates of
-- Program/ from the day this folder was created; re-copy them manually after
-- big shared updates. draconic_reactor.lua itself is independent.
local arguments = { ... }

local REPOSITORY_BASE_URL =
    "https://raw.githubusercontent.com/kenzu926/kenzu_cc/refs/heads/main/Draconic/"

local FILES = {
    "installer.lua",
    "startup.lua",
    "ws_client.lua",
    "gateway_client.lua",
    "gateway.lua",
    "console.lua",
    "peripherals.lua",
    "screen.lua",
    "service_runner.lua",
    "monitor_relay.lua",
    "files.lua",
    "draconic_reactor.lua",
}

local installDirectory = arguments[3]
if installDirectory == nil then installDirectory = shell.dir() end

local function installPath(fileName)
    return fs.combine(installDirectory, fileName)
end

local function removeIfPresent(path)
    if fs.exists(path) then fs.delete(path) end
end

if not http then
    printError("HTTP API is disabled. Cannot install project files.")
    return
end

print("Downloading draconic controller...")
for _, fileName in ipairs(FILES) do
    write("  " .. fileName .. "... ")
    local response, requestError, errorResponse = http.get(
        REPOSITORY_BASE_URL .. fileName, { ["Cache-Control"] = "no-cache" })
    if not response then
        if errorResponse then errorResponse.close() end
        printError("FAILED: " .. tostring(requestError))
        return
    end
    local source = response.readAll()
    response.close()
    if not source or #source == 0 then
        printError("FAILED: empty file")
        return
    end
    local compiled, syntaxError = load(source, "@" .. fileName)
    if not compiled then
        printError("FAILED: " .. tostring(syntaxError))
        return
    end
    local temporaryPath = installPath(fileName) .. ".download"
    removeIfPresent(temporaryPath)
    local output = fs.open(temporaryPath, "w")
    if not output then
        printError("FAILED: cannot write temporary file")
        return
    end
    output.write(source)
    output.close()
    fs.move(temporaryPath, installPath(fileName))
    print("OK")
end

if arguments[1] and arguments[1] ~= "" then
    settings.set("kenzu.serverUrl", arguments[1])
end
if arguments[2] and arguments[2] ~= "" then
    settings.set("kenzu.serverToken", arguments[2])
end
settings.save(installPath("server.settings"))

term.setTextColor(colors.lime)
print("Installation complete.")
term.setTextColor(colors.white)
print("Run 'startup' now, or use 'reboot' to start automatically.")
