-- Remote ME-system status node for computer_1.
local PROTOCOL = "kenzu_cc.me_status"
local NODE_NAME = "computer_1"
local HEARTBEAT_INTERVAL = 2

local function findWirelessModem()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            local modem = peripheral.wrap(name)
            if modem.isWireless and modem.isWireless() then
                return name
            end
        end
    end
end

local function findMEBridge()
    return peripheral.find("meBridge") or peripheral.find("me_bridge")
end

local function getMEStatus()
    local bridge = findMEBridge()
    if not bridge then
        return false, "ME Bridge not found"
    end

    if bridge.isConnected then
        local ok, connected = pcall(bridge.isConnected)
        if not ok then
            return false, tostring(connected)
        end
        return connected == true, connected and "Connected" or "ME network offline"
    end

    -- Compatibility fallback for older Advanced Peripherals versions.
    if bridge.getTotalItemStorage then
        local ok, storage = pcall(bridge.getTotalItemStorage)
        if ok and storage ~= nil then
            return true, "Connected"
        end
        return false, tostring(storage or "ME network offline")
    end

    return false, "Unsupported ME Bridge"
end

local modemName = findWirelessModem()
assert(modemName, "Wireless modem not found")
rednet.open(modemName)

while true do
    local meConnected, details = getMEStatus()

    rednet.broadcast({
        version = 1,
        role = "me_node",
        node = NODE_NAME,
        computerId = os.getComputerID(),
        meConnected = meConnected,
        details = details,
    }, PROTOCOL)

    term.clear()
    term.setCursorPos(1, 1)
    print("ME status node")
    print("Computer: " .. NODE_NAME)
    print("Rednet ID: " .. os.getComputerID())
    print("Modem: " .. modemName)
    print("ME System: " .. (meConnected and "CONNECTED" or "DISCONNECTED"))
    if not meConnected then
        print("Reason: " .. details)
    end

    sleep(HEARTBEAT_INTERVAL)
end
