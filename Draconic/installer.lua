-- Installer for the standalone Draconic reactor controller (Draconic/).
-- Usage:
--   wget run https://raw.githubusercontent.com/kenzu926/kenzu_cc/refs/heads/main/Draconic/installer.lua <ws(s)://host:port/ws> <access-token>
-- API modules (peripherals, gateway_client, ...) are frozen duplicates of
-- Program/ from the day this folder was created; re-copy them manually after
-- big shared updates. draconic_reactor.lua itself is independent.
local arguments = { ... }

local GITHUB_BASE_URL =
    "https://raw.githubusercontent.com/kenzu926/kenzu_cc/refs/heads/main/Draconic/"

-- Sources are tried in order: the site mirror first (direct updates without
-- GitHub; files are published there by name, same flat namespace as Program/),
-- then GitHub as a fallback. The site base is derived from the WebSocket URL
-- passed as argument 1 (same host:port, http(s) scheme).
local function sourceBases()
    local bases = {}
    local serverUrl = tostring(arguments[1] or "")
    local host = serverUrl:match("^wss?://([^/]+)")
    if host and host ~= "" then
        local scheme = serverUrl:sub(1, 3) == "wss" and "https://" or "http://"
        bases[#bases + 1] = { url = scheme .. host .. "/program/", label = "Site mirror" }
    end
    bases[#bases + 1] = { url = GITHUB_BASE_URL, label = "GitHub" }
    return bases
end

local function authHeaders()
    local token = tostring(arguments[2] or "")
    local headers = { ["Cache-Control"] = "no-cache" }
    if token ~= "" then headers.Authorization = "Bearer " .. token end
    return headers
end

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
    local source, lastError = nil, nil
    for _, base in ipairs(sourceBases()) do
        local url = base.url .. fileName
        local requestOk, response, requestError, errorResponse =
            pcall(http.get, url, authHeaders())
        if not requestOk or not response then
            if errorResponse then pcall(function() errorResponse.close() end) end
            requestOk, response, requestError, errorResponse = pcall(http.get, url)
        end
        if not requestOk then
            lastError = tostring(response)
        elseif not response then
            if errorResponse then pcall(function() errorResponse.close() end) end
            lastError = requestError or "request failed"
        else
            local responseCode = response.getResponseCode()
            local body = response.readAll()
            pcall(function() response.close() end)
            if responseCode ~= 200 then
                lastError = base.label .. " HTTP " .. tostring(responseCode)
            elseif not body or #body == 0 then
                lastError = base.label .. " empty file"
            else
                source = body
                break
            end
        end
    end
    if not source then
        printError("FAILED: " .. tostring(lastError))
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
