-- Remote ME-system status and storage node for computer_1.
local REDNET_PROTOCOL = "kenzu_cc.me_status"
local STORAGE_REDNET_PROTOCOL = "kenzu_cc.me_storage"
local CONSOLE_REQUEST_PROTOCOL = "kenzu_cc.console.request"
local CONSOLE_RESPONSE_PROTOCOL = "kenzu_cc.console.response"
local NODE_NAME = "computer_1"
local HEARTBEAT_INTERVAL = 2
local STORAGE_INTERVAL = 5
local STORAGE_CHUNK_SIZE = 100

local scriptDirectory = fs.getDir(shell.getRunningProgram())
local WebSocketClient = dofile(fs.combine(scriptDirectory, "gateway_client.lua"))
local SafeConsole = dofile(fs.combine(scriptDirectory, "console.lua"))
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
    -- Prefer the server-side Kenzu CC Bridge. It exposes real AE2 cell usage,
    -- while some ME Bridge versions only return an estimated aggregate value.
    for _, name in ipairs(peripheral.getNames()) do
        if name:match("^ae2:controller") then
            local controller = peripheral.wrap(name)
            local ok, version = pcall(function()
                return controller.getKenzuApiVersion()
            end)
            if ok and version then
                return controller, "Kenzu AE2 API " .. tostring(version), true, tostring(version)
            end
        end
    end

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
    local device, deviceName, isBridge, detectedAddonVersion = findMEPeripheral()
    if not device then
        return false, "ME peripheral not found", nil, false, nil
    end

    if isBridge and device.isConnected then
        local ok, connected = pcall(device.isConnected)
        if not ok then
            return false, tostring(connected), device,
                detectedAddonVersion ~= nil, detectedAddonVersion
        end
        return connected == true,
            connected and (detectedAddonVersion
                and "Connected via Kenzu CC Bridge" or "Connected via ME Bridge")
                or "ME network offline",
            device,
            detectedAddonVersion ~= nil,
            detectedAddonVersion
    end

    local storageMethod = isBridge and (device.getMaxItemStorage or device.getTotalItemStorage)
    if storageMethod then
        local ok, storage = pcall(storageMethod)
        if ok and storage ~= nil then
            return true,
                detectedAddonVersion and "Connected via Kenzu CC Bridge"
                    or "Connected via ME Bridge",
                device,
                detectedAddonVersion ~= nil,
                detectedAddonVersion
        end
        return false, tostring(storage or "ME network offline"), device,
            detectedAddonVersion ~= nil, detectedAddonVersion
    end

    return peripheral.isPresent(deviceName), "Connected via " .. deviceName, device,
        false, nil
end

local modemName = findWirelessModem()
if modemName then
    rednet.open(modemName)
end

local meConnected = false
local meDetails = "Waiting for ME system"
local meDevice = nil
local addonConnected = false
local addonVersion = nil
local storageDetails = "Waiting for first item scan"
local storageMetrics = { total = 0, used = 0, available = 0, cells = {} }
local storageCellSource = "none"

local function safeCall(device, methodName, fallback)
    local method = device and device[methodName]
    if not method then return fallback end
    local ok, value = pcall(method)
    return ok and value ~= nil and value or fallback
end

local function firstNumber(source, names)
    for _, name in ipairs(names) do
        local value = tonumber(source and source[name])
        if value ~= nil then return value end
    end
    return nil
end

local function cellName(cell, index)
    local item = cell and (cell.item or cell.name or cell.id)
    if type(item) == "table" then
        item = item.displayName or item.name or item.id or item.registryName
    end
    return tostring(item or ("ME storage cell " .. index))
end

local function appendCells(target, rawCells)
    if type(rawCells) ~= "table" then return end
    for index, cell in pairs(rawCells) do
        if type(cell) == "table" and type(cell.cells) == "table" then
            appendCells(target, cell.cells)
        elseif type(cell) == "table" then
            local totalBytes = firstNumber(cell, {
                -- AP 0.8 uses bytes; AP 0.7 uses totalBytes.
                "bytes", "capacity", "maxBytes", "bytesTotal", "totalBytes",
            }) or 0
            local usedBytes = firstNumber(cell, {
                "usedBytes", "used", "bytesUsed",
            })
            local availableBytes = firstNumber(cell, {
                "availableBytes", "freeBytes", "bytesFree",
            })
            if usedBytes == nil and availableBytes ~= nil and totalBytes > 0 then
                usedBytes = math.max(0, totalBytes - availableBytes)
            end
            target[#target + 1] = {
                item = cellName(cell, index),
                cellType = cell.cellType or cell.type or "item",
                totalBytes = totalBytes,
                usedBytes = usedBytes,
                usedKnown = usedBytes ~= nil,
                bytesPerType = tonumber(cell.bytesPerType) or 0,
            }
        end
    end
end

local function refreshStorageMetrics()
    if not meConnected or not meDevice then
        storageMetrics = { total = 0, used = 0, available = 0, cells = {} }
        return
    end
    local cells = {}
    local snapshot = safeCall(meDevice, "getStorageStats", nil)
    local total, used, available
    if type(snapshot) == "table" then
        total = tonumber(snapshot.total) or 0
        used = tonumber(snapshot.used) or 0
        available = tonumber(snapshot.available) or math.max(0, total - used)
        appendCells(cells, snapshot.cells)
        storageCellSource = "Kenzu CC Bridge"
    else
        total = tonumber(safeCall(meDevice, "getMaxItemStorage", nil))
            or tonumber(safeCall(meDevice, "getTotalItemStorage", 0)) or 0
        used = tonumber(safeCall(meDevice, "getUsedItemStorage", 0)) or 0
        available = tonumber(safeCall(meDevice, "getAvailableItemStorage", nil))
            or math.max(0, total - used)
    end
    if #cells == 0 then
        appendCells(cells, safeCall(meDevice, "getCells", nil))
        storageCellSource = "getCells"
    end
    if #cells == 0 then
        appendCells(cells, safeCall(meDevice, "listCells", nil))
        storageCellSource = "listCells"
    end
    if #cells == 0 then
        appendCells(cells, safeCall(meDevice, "getDrives", nil))
        storageCellSource = "getDrives"
    end
    if #cells == 0 and total > 0 then
        -- Some AP/AE2 addon combinations expose aggregate capacity but hide
        -- individual third-party cells. Keep the dashboard useful and honest.
        cells[1] = {
            item = "ME network total (cells unavailable)",
            cellType = "aggregate",
            totalBytes = total,
            usedBytes = used,
            usedKnown = true,
        }
        storageCellSource = "aggregate fallback"
    end
    storageMetrics = {
        total = total,
        used = used,
        available = available,
        cells = cells,
        cellSource = storageCellSource,
    }
end

local function sendStatus()
    meConnected, meDetails, meDevice, addonConnected, addonVersion = getMEStatus()

    if modemName then
        rednet.broadcast({
            version = 1,
            role = "me_node",
            node = NODE_NAME,
            computerId = os.getComputerID(),
            meConnected = meConnected,
            apiModConnected = addonConnected,
            apiModVersion = addonVersion,
            details = meDetails .. " | " .. storageDetails,
            metrics = storageMetrics,
        }, REDNET_PROTOCOL)
    end

    server:send({
        type = "storage_status",
        connected = meConnected,
        apiModConnected = addonConnected,
        apiModVersion = addonVersion,
        details = meDetails .. " | " .. storageDetails,
        metrics = storageMetrics,
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

local function sendStorageMessage(payload)
    -- Prefer the direct WebSocket connection when it is available, but always
    -- mirror storage traffic over Rednet. The reactor computer can relay it to
    -- the website when this node cannot reach the internet itself.
    server:send(payload)
    if modemName then
        rednet.broadcast(payload, STORAGE_REDNET_PROTOCOL)
    end
end

local function sendStorageSnapshot()
    if not meConnected or not meDevice then
        storageDetails = "Item scan waiting for ME connection"
        return
    end

    refreshStorageMetrics()

    local listMethod = meDevice.listItems
    local methodArguments = {}
    if not listMethod and meDevice.getItems then
        listMethod = meDevice.getItems
        -- Advanced Peripherals 0.8 requires an empty filter to return all items.
        methodArguments = { {} }
    end

    if not listMethod then
        storageDetails = "No listItems/getItems method"
        return
    end

    storageDetails = "Reading ME items..."
    local ok, items, listError = pcall(listMethod, table.unpack(methodArguments))
    if not ok or type(items) ~= "table" then
        storageDetails = "Item scan error: "
            .. tostring(listError or items or "Unable to read ME items")
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
    sendStorageMessage({
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
        sendStorageMessage({
            type = "storage_chunk",
            snapshotId = snapshotId,
            items = chunk,
        })
    end

    sendStorageMessage({
        type = "storage_end",
        snapshotId = snapshotId,
    })
    storageDetails = "Sent " .. #compactItems .. " item types | cells: "
        .. #storageMetrics.cells .. " via " .. storageCellSource
end

local function drawStatus()
    term.clear()
    term.setCursorPos(1, 1)
    print("ME status node")
    print("Computer: " .. NODE_NAME)
    print("Rednet ID: " .. os.getComputerID())
    print("Modem: " .. tostring(modemName or "NOT FOUND"))
    print("ME System: " .. (meConnected and "CONNECTED" or "DISCONNECTED"))
    print("Kenzu API mod: " .. (addonConnected
        and ("ACTIVE v" .. tostring(addonVersion)) or "NOT DETECTED"))
    local uplink = server:isConnected() and "DIRECT"
        or (modemName and "REDNET RELAY" or "OFFLINE")
    print("Web uplink: " .. uplink)
    print("Details: " .. meDetails)
    print("Storage: " .. storageDetails)
    if server.lastError then
        print("Web error: " .. server.lastError)
    end
end

local function consoleStatus()
    return table.concat({
        "Service: ME storage node",
        "Computer: " .. NODE_NAME,
        "ME: " .. (meConnected and "CONNECTED" or "DISCONNECTED"),
        "Kenzu API mod: " .. (addonConnected
            and ("ACTIVE v" .. tostring(addonVersion)) or "NOT DETECTED"),
        "Uplink: " .. (server:isConnected() and "DIRECT" or "REDNET RELAY"),
        "Details: " .. meDetails,
        "Storage: " .. storageDetails,
    }, "\n")
end

local function executeConsoleCommand(command, replyOverRednet)
    local ok, output = SafeConsole.execute(command.command, consoleStatus)
    local response = {
        type = "console_output",
        requestId = command.requestId,
        target = "storage_node",
        computerId = os.getComputerID(),
        ok = ok,
        output = output,
    }

    if replyOverRednet and modemName then
        rednet.broadcast(response, CONSOLE_RESPONSE_PROTOCOL)
    else
        server:send(response)
    end
end

server:connect()
sendStatus()
drawStatus()

local heartbeatTimer = os.startTimer(HEARTBEAT_INTERVAL)
local storageTimer = os.startTimer(1)

while true do
    local event, arg1, arg2, arg3 = os.pullEvent()
    local serverEvent, serverMessage = server:handleEvent(event, arg1, arg2, arg3)

    if serverEvent == "connected" then
        sendStatus()
        sendStorageSnapshot()
        drawStatus()
    elseif serverEvent == "disconnected" then
        drawStatus()
    elseif serverEvent == "message" and type(serverMessage) == "table"
        and serverMessage.type == "console_command"
        and (serverMessage.target == "storage_node"
            or serverMessage.target == tostring(os.getComputerID())) then
        executeConsoleCommand(serverMessage, false)
    end

    if event == "timer" and arg1 == heartbeatTimer then
        server:connect()
        sendStatus()
        drawStatus()
        heartbeatTimer = os.startTimer(HEARTBEAT_INTERVAL)
    elseif event == "timer" and arg1 == storageTimer then
        -- Refresh the heartbeat before a potentially slow full ME item scan.
        sendStatus()
        sendStorageSnapshot()
        sendStatus()
        storageTimer = os.startTimer(STORAGE_INTERVAL)
    elseif event == "peripheral" or event == "peripheral_detach" then
        modemName = findWirelessModem()
        if modemName and not rednet.isOpen(modemName) then
            rednet.open(modemName)
        end
        sendStatus()
        drawStatus()
    elseif event == "rednet_message" and arg3 == CONSOLE_REQUEST_PROTOCOL then
        local command = arg2
        if type(command) == "table" and command.type == "console_command"
            and (command.target == "storage_node"
                or command.target == tostring(os.getComputerID())) then
            executeConsoleCommand(command, true)
        end
    end
end
