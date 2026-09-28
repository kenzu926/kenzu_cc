-- Updates this computer and asks the other Rednet computers to update too.
local arguments = { ... }
local UPDATE_PROTOCOL = "kenzu_cc.update.request"
local INSTALLER_URL =
    "https://raw.githubusercontent.com/kenzu926/kenzu_cc/refs/heads/main/Program/installer.lua"

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

local function downloadMissingInstaller()
    if fs.exists(installerPath) then return true end
    if not http then return false, "HTTP API is disabled" end

    print("Installer is missing; downloading it...")
    local requestOk, response, requestError, errorResponse = pcall(http.get, INSTALLER_URL, {
        ["Cache-Control"] = "no-cache",
    })
    if not requestOk then return false, tostring(response) end
    if not response then
        if errorResponse then errorResponse.close() end
        return false, requestError or "request failed"
    end

    local responseCode = response.getResponseCode()
    local source = response.readAll()
    response.close()
    if responseCode ~= 200 then
        return false, "GitHub returned HTTP " .. tostring(responseCode)
    end
    if not source or #source == 0 then return false, "GitHub returned an empty file" end

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
    if modemCount > 0 and serverToken ~= "" then
        rednet.broadcast({
            action = "update",
            requestId = requestId,
            token = serverToken,
            senderId = os.getComputerID(),
        }, UPDATE_PROTOCOL)
        print("Update request sent to the other computers.")
        sleep(0.5)
    elseif modemCount == 0 then
        print("Wireless modem not found; updating only this computer.")
    else
        print("Server token is empty; updating only this computer.")
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
