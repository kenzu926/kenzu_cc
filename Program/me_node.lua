-- Remote ME-system status and storage node for computer_1.
local REDNET_PROTOCOL = "kenzu_cc.me_status"
local NODE_NAME = "computer_1"
local HEARTBEAT_INTERVAL = 2
local STORAGE_INTERVAL = 5
local STORAGE_CHUNK_SIZE = 100

local scriptDirectory = fs.getDir(shell.getRunningProgram())
local WebSocketClient = dofile(fs.combine(scriptDirectory, "ws_client.lua"))
local server = WebSocketClient.new("storage_node")

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
        return false, "ME peripheral not found", nil
    end

    if isBridge and device.isConnected then
        local ok, connected = pcall(device.isConnected)
        if not ok then
            return false, tostring(connected), device
        end
        return connected == true,
            connected and "Connected via ME Bridge" or "ME network offline",
            device
    end

    if isBridge and device.getTotalItemStorage then
        local ok, storage = pcall(device.getTotalItemStorage)
        if ok and storage ~= nil then
            return true, "Connected via ME Bridge", device
        end
        return false, tostring(storage or "ME network offline"), device
    end

    return peripheral.isPresent(deviceName), "Connected via " .. deviceName, device
end

local modemName = findWirelessModem()
if modemName then
    rednet.open(modemName)
end

local meConnected = false
local meDetails = "Waiting for ME system"
local meDevice = nil

local function sendStatus()
    meConnected, meDetails, meDevice = getMEStatus()

    if modemName then
        rednet.broadcast({
            version = 1,
            role = "me_node",
            node = NODE_NAME,
            computerId = os.getComputerID(),
            meConnected = meConnected,
            details = meDetails,
        }, REDNET_PROTOCOL)
    end

    server:send({
        type = "storage_status",
        connected = meConnected,
        details = meDetails,
    })
end

local function compactItem(item)
    return {
        name = item.name or "unknown",
        displayName = item.displayName or item.name or "Unknown item",
        count = tonumber(item.amount or item.count) or 0,
        fingerprint = item.fingerprint,
    }
end

local function sendStorageSnapshot()
    if not server:isConnected() or not meConnected or not meDevice then
        return
    end
    if not meDevice.listItems then
        return
    end

    local ok, items, listError = pcall(meDevice.listItems)
    if not ok or type(items) ~= "table" then
        meDetails = tostring(listError or items or "Unable to read ME items")
        return
    end

    local compactItems = {}
    for _, item in pairs(items) do
        compactItems[#compactItems + 1] = compactItem(item)
    end
    table.sort(compactItems, function(left, right)
        return left.count > right.count
    end)

    local snapshotId = tostring(os.epoch("utc"))
    server:send({
        type = "storage_begin",
        snapshotId = snapshotId,
        total = #compactItems,
    })

    for index = 1, #compactItems, STORAGE_CHUNK_SIZE do
        local chunk = {}
        local lastIndex = math.min(index + STORAGE_CHUNK_SIZE - 1, #compactItems)
        for itemIndex = index, lastIndex do
            chunk[#chunk + 1] = compactItems[itemIndex]
        end
        server:send({
            type = "storage_chunk",
            snapshotId = snapshotId,
            items = chunk,
        })
    end

    server:send({
        type = "storage_end",
        snapshotId = snapshotId,
    })
end

local function drawStatus()
    term.clear()
    term.setCursorPos(1, 1)
    print("ME status node")
    print("Computer: " .. NODE_NAME)
    print("Rednet ID: " .. os.getComputerID())
    print("Modem: " .. tostring(modemName or "NOT FOUND"))
    print("ME System: " .. (meConnected and "CONNECTED" or "DISCONNECTED"))
    print("Web server: " .. (server:isConnected() and "CONNECTED" or "OFFLINE"))
    print("Details: " .. meDetails)
    if server.lastError then
        print("Web error: " .. server.lastError)
    end
end

server:connect()
sendStatus()
drawStatus()

local heartbeatTimer = os.startTimer(HEARTBEAT_INTERVAL)
local storageTimer = os.startTimer(1)

while true do
    local event, arg1, arg2, arg3 = os.pullEvent()
    local serverEvent = server:handleEvent(event, arg1, arg2, arg3)

    if serverEvent == "connected" then
        sendStatus()
        sendStorageSnapshot()
        drawStatus()
    elseif serverEvent == "disconnected" then
        drawStatus()
    end

    if event == "timer" and arg1 == heartbeatTimer then
        server:connect()
        sendStatus()
        drawStatus()
        heartbeatTimer = os.startTimer(HEARTBEAT_INTERVAL)
    elseif event == "timer" and arg1 == storageTimer then
        sendStorageSnapshot()
        storageTimer = os.startTimer(STORAGE_INTERVAL)
    elseif event == "peripheral" or event == "peripheral_detach" then
        modemName = findWirelessModem()
        if modemName and not rednet.isOpen(modemName) then
            rednet.open(modemName)
        end
        sendStatus()
        drawStatus()
    end
end
