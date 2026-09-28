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

if not fs.exists(installerPath) then
    printError("Missing installer: " .. installerPath)
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
