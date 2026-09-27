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

local function findMEPeripheral()
    local bridge = peripheral.find("meBridge") or peripheral.find("me_bridge")
    if bridge then
        return bridge, "ME Bridge", true
    end

    for _, name in ipairs(peripheral.getNames()) do
        if name:match("^ae2:controller") then
            return peripheral.wrap(name), name, false
        end
    end
end

local function getMEStatus()
    local device, deviceName, isBridge = findMEPeripheral()
    if not device then
        return false, "ME peripheral not found"
    end

    if isBridge and device.isConnected then
        local ok, connected = pcall(device.isConnected)
        if not ok then
            return false, tostring(connected)
        end
        return connected == true,
            connected and "Connected via ME Bridge" or "ME network offline"
    end

    -- Compatibility fallback for older Advanced Peripherals versions.
    if isBridge and device.getTotalItemStorage then
        local ok, storage = pcall(device.getTotalItemStorage)
        if ok and storage ~= nil then
            return true, "Connected via ME Bridge"
        end
        return false, tostring(storage or "ME network offline")
    end

    -- A directly attached AE2 controller has no Advanced Peripherals
    -- isConnected() method. Its presence confirms the wired connection.
    return peripheral.isPresent(deviceName), "Connected via " .. deviceName
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
    print("Details: " .. details)

    sleep(HEARTBEAT_INTERVAL)
end
