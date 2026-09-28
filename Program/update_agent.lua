-- Receives authenticated update requests from another project computer.
local UPDATE_PROTOCOL = "kenzu_cc.update.request"
local REQUEST_TTL = 60 * 1000

local scriptDirectory = fs.getDir(shell.getRunningProgram())
local settingsPath = fs.combine(scriptDirectory, "server.settings")
local updatePath = fs.combine(scriptDirectory, "update.lua")
local handledRequests = {}

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

local function expectedToken()
    settings.load(settingsPath)
    return settings.get("kenzu.serverToken", "")
end

local function purgeOldRequests(now)
    for requestId, receivedAt in pairs(handledRequests) do
        if now - receivedAt > REQUEST_TTL then handledRequests[requestId] = nil end
    end
end

local function startUpdate(requestId)
    if not fs.exists(updatePath) then
        printError("Update command is missing: " .. updatePath)
        return
    end

    if multishell and shell.openTab then
        local tabId = shell.openTab(updatePath, "--remote", requestId)
        multishell.setTitle(tabId, "Updating")
    else
        shell.run(updatePath, "--remote", requestId)
    end
end

local modemCount = openWirelessModems()
print("Update agent started")
print("Wireless modems: " .. modemCount)

while true do
    local event, arg1, arg2, arg3 = os.pullEvent()

    if event == "rednet_message" and arg3 == UPDATE_PROTOCOL then
        local senderId, message = arg1, arg2
        local token = expectedToken()
        local now = os.epoch("utc")
        purgeOldRequests(now)

        if type(message) == "table"
            and message.action == "update"
            and senderId ~= os.getComputerID()
            and type(message.requestId) == "string"
            and token ~= ""
            and message.token == token
            and not handledRequests[message.requestId] then
            handledRequests[message.requestId] = now
            print("Update requested by computer " .. tostring(senderId))
            startUpdate(message.requestId)
        end
    elseif event == "peripheral" or event == "peripheral_detach" then
        openWirelessModems()
    end
end
