-- Updates this computer and asks the other Rednet computers to update too.
local arguments = { ... }
local UPDATE_PROTOCOL = "kenzu_cc.update.request"

local scriptDirectory = fs.getDir(shell.getRunningProgram())
local settingsPath = fs.combine(scriptDirectory, "server.settings")
local installerPath = fs.combine(scriptDirectory, "installer.lua")
local isRemoteRequest = arguments[1] == "--remote"
local requestId = isRemoteRequest and arguments[2]
    or (tostring(os.getComputerID()) .. "-" .. tostring(os.epoch("utc")))

local function loadConnectionSettings()
    settings.load(settingsPath)
    return settings.get("kenzu.serverUrl", ""), settings.get("kenzu.serverToken", "")
end

local function openWirelessModems()
    local opened = 0
    for _, name in ipairs(peripheral.getNames()) do
        local modem = peripheral.wrap(name)
        if peripheral.getType(name) == "modem" and modem and modem.isWireless then
            local ok, wireless = pcall(modem.isWireless)
            if ok and wireless then
                rednet.open(name)
                opened = opened + 1
            end
        end
    end
    return opened
end

local serverUrl, serverToken = loadConnectionSettings()

-- Direct updates bypass GitHub: the site itself serves Program/*.lua at
-- <http(s)://host>/program/<file> (same host:port as the WebSocket URL).
-- GitHub stays as a fallback when the site mirror is empty or unreachable.
local GITHUB_INSTALLER_URL =
    "https://raw.githubusercontent.com/kenzu926/kenzu_cc/refs/heads/main/Program/installer.lua"

local function siteProgramBase()
    local host = tostring(serverUrl or ""):match("^wss?://([^/]+)")
    if not host or host == "" then return nil end
    local scheme = tostring(serverUrl):sub(1, 3) == "wss" and "https://" or "http://"
    return scheme .. host .. "/program"
end

local function fetchSource(url, label)
    local headers = { ["Cache-Control"] = "no-cache" }
    if serverToken ~= "" then headers.Authorization = "Bearer " .. serverToken end
    local requestOk, response, requestError, errorResponse = pcall(http.get, url, headers)
    if not requestOk or not response then
        -- Older CC builds reject the headers argument: retry without it.
        if errorResponse then pcall(function() errorResponse.close() end) end
        requestOk, response, requestError, errorResponse = pcall(http.get, url)
    end
    if not requestOk then return nil, tostring(response) end
    if not response then
        if errorResponse then pcall(function() errorResponse.close() end) end
        return nil, requestError or "request failed"
    end
    local responseCode = response.getResponseCode()
    local source = response.readAll()
    pcall(function() response.close() end)
    if responseCode ~= 200 then
        return nil, label .. " returned HTTP " .. tostring(responseCode)
    end
    if not source or #source == 0 then return nil, label .. " returned an empty file" end
    return source
end

local function installerSources()
    local sources = {}
    local base = siteProgramBase()
    if base then sources[#sources + 1] = { url = base .. "/installer.lua", label = "Site mirror" } end
    sources[#sources + 1] = { url = GITHUB_INSTALLER_URL, label = "GitHub" }
    return sources
end

local function downloadMissingInstaller()
    if fs.exists(installerPath) then return true end
    if not http then return false, "HTTP API is disabled" end

    print("Installer is missing; downloading it...")
    local source, lastError = nil, nil
    for _, candidate in ipairs(installerSources()) do
        source, lastError = fetchSource(candidate.url, candidate.label)
        if source then
            print("Source: " .. candidate.label)
            break
        end
        print("  " .. candidate.label .. ": " .. tostring(lastError))
    end
    if not source then return false, lastError or "all sources failed" end

    local compiled, syntaxError = load(source, "@installer.lua")
    if not compiled then return false, "Lua syntax error: " .. tostring(syntaxError) end

    local temporaryPath = installerPath .. ".download"
    if fs.exists(temporaryPath) then fs.delete(temporaryPath) end
    local output, openError = fs.open(temporaryPath, "w")
    if not output then return false, openError or "cannot create installer" end
    output.write(source)
    output.close()
    fs.move(temporaryPath, installerPath)
    return true
end

local installerReady, installerError = downloadMissingInstaller()
if not installerReady then
    printError("Cannot download installer: " .. tostring(installerError))
    return
end

if not isRemoteRequest then
    local modemCount = openWirelessModems()
    if modemCount > 0 then
        -- Never broadcast the WS token: receivers reuse their own local copy.
        -- This only triggers a refresh, it does not authenticate the sender
        -- (see update_agent.lua throttling). Token stays on disk only.
        rednet.broadcast({
            action = "update",
            requestId = requestId,
            senderId = os.getComputerID(),
        }, UPDATE_PROTOCOL)
        print("Update request sent to the other computers.")
        sleep(0.5)
    else
        print("Wireless modem not found; updating only this computer.")
    end
else
    print("Remote update request accepted.")
end

print("Updating computer " .. os.getComputerID() .. "...")
local ran = shell.run(installerPath, serverUrl, serverToken, requestId, scriptDirectory)

settings.load(settingsPath)
local installedRequestId = settings.get("kenzu.lastInstallId")
if not ran or installedRequestId ~= requestId then
    printError("Update failed. The current installation was kept.")
    return
end

term.setTextColor(colors.lime)
print("Update complete. Rebooting...")
term.setTextColor(colors.white)
sleep(1)
os.reboot()
