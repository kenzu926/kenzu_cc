-- 6x4 base dashboard. The monitor may be attached to the ME node while
-- reactor, matrix and turbines are attached to another computer.
local MONITOR_NAME = "monitor_1"
local MATRIX_NAME = "inductionPort_0"
local REACTOR_NAME = "fissionReactorLogicAdapter_0"
local ME_NAME = "meBridge_0"
local ME_STATUS_PROTOCOL = "kenzu_cc.me_status"
local REACTOR_PROTOCOL = "kenzu_cc.overview.reactor"
local TURBINE_PROTOCOL = "kenzu_cc.overview.turbines"
local SNAPSHOT_PROTOCOL = "kenzu_cc.overview.snapshot"
local REFRESH_INTERVAL = 1
local REMOTE_TIMEOUT = 10 * 1000
local JOULES_PER_FE = 2.5
local STARTED_AT = os.epoch("utc")

local monitor = assert(peripheral.wrap(MONITOR_NAME), "Overview monitor not found: " .. MONITOR_NAME)
local matrix = peripheral.wrap(MATRIX_NAME)
local reactor = peripheral.wrap(REACTOR_NAME)
local meBridge
local remoteMatrix, remoteReactor, remoteTurbines
local reactorHeartbeat, turbineHeartbeat, meHeartbeat
local remoteME = { connected = false, cells = 0, used = 0, total = 0 }

monitor.setTextScale(0.5)

local function openWirelessModem()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            local modem = peripheral.wrap(name)
            if modem and modem.isWireless then
                local ok, wireless = pcall(modem.isWireless)
                if ok and wireless then
                    rednet.open(name)
                    return true
                end
            end
        end
    end
    return false
end

local hasRednet = openWirelessModem()

local function findMEBridge()
    local exact = peripheral.wrap(ME_NAME)
    if exact then return exact end
    for _, name in ipairs(peripheral.getNames()) do
        local device = peripheral.wrap(name)
        local lower = name:lower()
        if device and (lower:find("mebridge", 1, true)
                or device.getStorageStats
                or device.getMaxItemStorage
                or device.getTotalItemStorage) then
            return device
        end
    end
end

meBridge = findMEBridge()

local function safeRawCall(device, method)
    if not device or not device[method] then return nil end
    local ok, value = pcall(device[method])
    if not ok then return nil end
    return value
end

local function safeNumber(device, method, fallback)
    local value = safeRawCall(device, method)
    if type(value) == "table" then value = value.amount or value[1] end
    return tonumber(value) or fallback or 0
end

local function safeBoolean(device, method, fallback)
    local value = safeRawCall(device, method)
    if value == nil then return fallback == true end
    return value == true
end

local function countEntries(value)
    if type(value) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    return count
end

local function shorten(value)
    value = tonumber(value) or 0
    local absolute = math.abs(value)
    if absolute >= 1e15 then return ("%.2fP"):format(value / 1e15) end
    if absolute >= 1e12 then return ("%.2fT"):format(value / 1e12) end
    if absolute >= 1e9 then return ("%.2fG"):format(value / 1e9) end
    if absolute >= 1e6 then return ("%.2fM"):format(value / 1e6) end
    if absolute >= 1e3 then return ("%.1fk"):format(value / 1e3) end
    return ("%.0f"):format(value)
end

local function isFresh(timestamp)
    return timestamp ~= nil and os.epoch("utc") - timestamp <= REMOTE_TIMEOUT
end

local function matrixStats()
    if matrix then
        return {
            energyPercent = safeNumber(matrix, "getEnergyFilledPercentage") * 100,
            storedEnergy = safeNumber(matrix, "getEnergy") / JOULES_PER_FE,
            capacity = safeNumber(matrix, "getMaxEnergy") / JOULES_PER_FE,
            input = safeNumber(matrix, "getLastInput") / JOULES_PER_FE,
            output = safeNumber(matrix, "getLastOutput") / JOULES_PER_FE,
        }, "LOCAL"
    end
    if type(remoteMatrix) == "table" then
        return remoteMatrix, isFresh(reactorHeartbeat) and "REDNET" or "STALE"
    end
    return {}, "OFFLINE"
end

local function reactorStats()
    if reactor then
        return {
            running = safeBoolean(reactor, "getStatus"),
            temperature = safeNumber(reactor, "getTemperature"),
            actualBurnRate = safeNumber(reactor, "getActualBurnRate"),
            coolantPercent = safeNumber(reactor, "getCoolantFilledPercentage") * 100,
            fuelPercent = safeNumber(reactor, "getFuelFilledPercentage") * 100,
            wastePercent = safeNumber(reactor, "getWasteFilledPercentage") * 100,
            damage = safeNumber(reactor, "getDamagePercent"),
        }, "LOCAL"
    end
    if type(remoteReactor) == "table" then
        return remoteReactor, isFresh(reactorHeartbeat) and "REDNET" or "STALE"
    end
    return {}, "OFFLINE"
end

local function localTurbines()
    local statuses = {}
    for _, name in ipairs(peripheral.getNames()) do
        if name:lower():find("turbine", 1, true) then
            local device = peripheral.wrap(name)
            if device and (device.getProductionRate or device.getFlowRate) then
                statuses[#statuses + 1] = {
                    production = safeNumber(device, "getProductionRate") / JOULES_PER_FE,
                    flowRate = safeNumber(device, "getFlowRate"),
                    maxFlowRate = safeNumber(device, "getMaxFlowRate"),
                    steamPercent = safeNumber(device, "getSteamFilledPercentage") * 100,
                }
            end
        end
    end
    return statuses
end

local function turbineStats()
    local statuses = localTurbines()
    local source = "LOCAL"
    if #statuses == 0 then
        if type(remoteTurbines) == "table" then
            statuses = remoteTurbines
            source = isFresh(turbineHeartbeat) and "REDNET" or "STALE"
        else
            source = "OFFLINE"
        end
    end
    local result = { count = #statuses, production = 0, flow = 0, maxFlow = 0, steam = 0 }
    for _, value in ipairs(statuses) do
        result.production = result.production + (tonumber(value.production) or 0)
        result.flow = result.flow + (tonumber(value.flowRate) or 0)
        result.maxFlow = result.maxFlow + (tonumber(value.maxFlowRate) or 0)
        result.steam = result.steam + (tonumber(value.steamPercent) or 0)
    end
    if result.count > 0 then result.steam = result.steam / result.count end
    return result, source
end

local function meStats()
    if meBridge then
        local snapshot = safeRawCall(meBridge, "getStorageStats")
        local total = type(snapshot) == "table" and tonumber(snapshot.total) or nil
        local used = type(snapshot) == "table" and tonumber(snapshot.used) or nil
        local cells = type(snapshot) == "table" and countEntries(snapshot.cells) or 0
        total = total or safeNumber(meBridge, "getMaxItemStorage")
        if total == 0 then total = safeNumber(meBridge, "getTotalItemStorage") end
        used = used or safeNumber(meBridge, "getUsedItemStorage")
        if cells == 0 then
            cells = countEntries(safeRawCall(meBridge, "getCells"))
            if cells == 0 then cells = countEntries(safeRawCall(meBridge, "listCells")) end
        end
        return {
            connected = safeBoolean(meBridge, "isConnected", true),
            cells = cells,
            used = used,
            total = total,
        }, "LOCAL"
    end
    if meHeartbeat then return remoteME, isFresh(meHeartbeat) and "REDNET" or "STALE" end
    return { connected = false, cells = 0, used = 0, total = 0 }, "OFFLINE"
end

local function fill(x1, y1, x2, y2, background)
    local width, height = monitor.getSize()
    x1, y1 = math.max(1, x1), math.max(1, y1)
    x2, y2 = math.min(width, x2), math.min(height, y2)
    if x1 > x2 or y1 > y2 then return end
    monitor.setBackgroundColor(background)
    for y = y1, y2 do
        monitor.setCursorPos(x1, y)
        monitor.write(string.rep(" ", x2 - x1 + 1))
    end
end

local function text(x, y, value, color, background)
    local width, height = monitor.getSize()
    if y < 1 or y > height or x > width then return end
    value = tostring(value)
    monitor.setCursorPos(math.max(1, x), y)
    monitor.setTextColor(color or colors.white)
    monitor.setBackgroundColor(background or colors.black)
    monitor.write(value:sub(1, math.max(0, width - x + 1)))
end

local function centered(y, value, color, background)
    local width = monitor.getSize()
    value = tostring(value)
    text(math.max(1, math.floor((width - #value) / 2) + 1), y, value, color, background)
end

local function bar(x, y, width, percent, color, rows)
    percent = math.max(0, math.min(100, tonumber(percent) or 0))
    rows = rows or 1
    fill(x, y, x + width - 1, y + rows - 1, colors.gray)
    local amount = math.floor(width * percent / 100 + 0.5)
    if amount > 0 then fill(x, y, x + amount - 1, y + rows - 1, color or colors.lime) end
end

local function sectionHeader(y, label, source, color)
    local width = monitor.getSize()
    fill(1, y, width, y, color)
    text(2, y, label, colors.black, color)
    local sourceColor = colors.lime
    if source == "OFFLINE" then sourceColor = colors.red end
    if source == "STALE" then sourceColor = colors.orange end
    text(math.max(2, width - #source), y, source, sourceColor, color)
end

local function meter(y, label, percent, color, rows)
    local width = monitor.getSize()
    rows = rows or 2
    text(3, y, label, colors.lightGray)
    text(math.max(3, width - 8), y, ("%6.1f%%"):format(tonumber(percent) or 0), colors.white)
    bar(3, y + 1, math.max(8, width - 6), percent, color, rows)
end

local function moscowDateTime()
    local seconds = math.floor(os.epoch("utc") / 1000) + 3 * 60 * 60
    local ok, value = pcall(os.date, "!%d.%m.%Y %H:%M:%S", seconds)
    return ok and value or textutils.formatTime(os.time() + 3, true)
end

local function uptime()
    local seconds = math.max(0, math.floor((os.epoch("utc") - STARTED_AT) / 1000))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor(seconds % 3600 / 60)
    return ("UP %02d:%02d:%02d"):format(hours, minutes, seconds % 60)
end

local function draw()
    local width, height = monitor.getSize()
    local matrixData, matrixSource = matrixStats()
    local reactorData, reactorSource = reactorStats()
    local turbines, turbineSource = turbineStats()
    local storage, meSource = meStats()
    local energy = tonumber(matrixData.energyPercent) or 0
    local stored = tonumber(matrixData.storedEnergy) or 0
    local capacity = tonumber(matrixData.capacity) or 0
    local input = tonumber(matrixData.input) or 0
    local output = tonumber(matrixData.output) or 0

    monitor.setBackgroundColor(colors.black)
    monitor.clear()

    fill(1, 1, width, 5, colors.gray)
    centered(2, 'ATM9 - "Maids in stockings"(gornichnyye v chulochkakh)', colors.cyan, colors.gray)
    text(3, 4, moscowDateTime() .. " MSK", colors.white, colors.gray)
    local up = uptime()
    text(math.max(3, width - #up - 1), 4, up, colors.lightGray, colors.gray)

    sectionHeader(7, " INDUCTION MATRIX", matrixSource, colors.lightBlue)
    text(3, 9, ("%s / %s FE"):format(shorten(stored), shorten(capacity)), colors.white)
    meter(10, "ENERGY", energy, energy >= 95 and colors.orange or colors.lime, 2)
    text(3, 14, ("IN %s FE/t   OUT %s FE/t   NET %s"):format(
        shorten(input), shorten(output), shorten(input - output)), colors.lightGray)

    sectionHeader(16, " FISSION REACTOR", reactorSource, colors.yellow)
    local running = reactorData.running == true
    text(3, 18, running and "ONLINE" or "SCRAMMED", running and colors.lime or colors.red)
    text(16, 18, ("TEMP %.0f K  BURN %.2f mB/t  DAMAGE %.1f%%"):format(
        tonumber(reactorData.temperature) or 0,
        tonumber(reactorData.actualBurnRate) or 0,
        tonumber(reactorData.damage) or 0), colors.lightGray)
    meter(20, "WATER", reactorData.coolantPercent, colors.blue, 2)
    meter(24, "FUEL", reactorData.fuelPercent, colors.green, 2)
    meter(28, "WASTE", reactorData.wastePercent, colors.red, 2)

    sectionHeader(32, " TURBINES", turbineSource, colors.purple)
    text(3, 34, ("%d UNITS   GENERATION %s FE/t"):format(turbines.count, shorten(turbines.production)), colors.white)
    local flowPercent = turbines.maxFlow > 0 and turbines.flow / turbines.maxFlow * 100 or 0
    meter(35, ("FLOW %s/%s mB/t"):format(shorten(turbines.flow), shorten(turbines.maxFlow)), flowPercent, colors.purple, 2)
    meter(39, "STEAM BUFFER", turbines.steam, colors.lightBlue, 2)

    sectionHeader(43, " AE2 STORAGE", meSource, colors.cyan)
    local storagePercent = storage.total > 0 and storage.used / storage.total * 100 or 0
    text(3, 45, storage.connected and ("CONNECTED   CELLS " .. storage.cells) or "DISCONNECTED",
        storage.connected and colors.lime or colors.red)
    meter(46, ("USED %s/%s"):format(shorten(storage.used), shorten(storage.total)), storagePercent, colors.cyan, 2)

    fill(1, height, width, height, colors.gray)
    text(2, height, hasRednet and "REDNET LINK ACTIVE" or "REDNET LINK OFFLINE",
        hasRednet and colors.lime or colors.red, colors.gray)
    text(math.max(2, width - 20), height, "LOCAL SAFETY ACTIVE", colors.yellow, colors.gray)
end

draw()
local timer = os.startTimer(REFRESH_INTERVAL)
while true do
    local event, arg1, arg2, arg3 = os.pullEvent()
    if event == "timer" and arg1 == timer then
        matrix = peripheral.wrap(MATRIX_NAME)
        reactor = peripheral.wrap(REACTOR_NAME)
        meBridge = findMEBridge()
        draw()
        timer = os.startTimer(REFRESH_INTERVAL)
    elseif event == "monitor_resize" and arg1 == MONITOR_NAME then
        draw()
    elseif event == "rednet_message" and arg3 == REACTOR_PROTOCOL and type(arg2) == "table" then
        remoteMatrix = arg2.matrix
        remoteReactor = arg2.reactor
        reactorHeartbeat = os.epoch("utc")
        draw()
    elseif event == "rednet_message" and arg3 == TURBINE_PROTOCOL and type(arg2) == "table" then
        remoteTurbines = arg2.turbines
        turbineHeartbeat = os.epoch("utc")
        draw()
    elseif event == "rednet_message" and arg3 == SNAPSHOT_PROTOCOL and type(arg2) == "table" then
        local now = os.epoch("utc")
        if type(arg2.matrix) == "table" then
            remoteMatrix = arg2.matrix
            reactorHeartbeat = now
        end
        if type(arg2.reactor) == "table" then
            remoteReactor = arg2.reactor
            reactorHeartbeat = now
        end
        if type(arg2.turbines) == "table" then
            remoteTurbines = arg2.turbines
            turbineHeartbeat = now
        end
        draw()
    elseif event == "rednet_message" and arg3 == ME_STATUS_PROTOCOL and type(arg2) == "table" then
        local metrics = type(arg2.metrics) == "table" and arg2.metrics or {}
        remoteME = {
            connected = arg2.meConnected == true,
            cells = countEntries(metrics.cells),
            used = tonumber(metrics.used) or 0,
            total = tonumber(metrics.total) or 0,
        }
        meHeartbeat = os.epoch("utc")
        draw()
    elseif event == "peripheral" or event == "peripheral_detach" then
        matrix = peripheral.wrap(MATRIX_NAME)
        reactor = peripheral.wrap(REACTOR_NAME)
        meBridge = findMEBridge()
        draw()
    end
end
