-- Local overview dashboard for the 6x4 monitor_1.
-- It reads peripherals directly, so it keeps working without the web server.
local MONITOR_NAME = "monitor_1"
local MATRIX_NAME = "inductionPort_0"
local REACTOR_NAME = "fissionReactorLogicAdapter_0"
local ME_STATUS_PROTOCOL = "kenzu_cc.me_status"
local REFRESH_INTERVAL = 1
local REMOTE_TIMEOUT = 20 * 1000
local JOULES_PER_FE = 2.5

local monitor = assert(peripheral.wrap(MONITOR_NAME), "Overview monitor not found: " .. MONITOR_NAME)
local matrix = peripheral.wrap(MATRIX_NAME)
local reactor = peripheral.wrap(REACTOR_NAME)
local lastMEHeartbeat = nil
local meConnected = false
local meCells = 0
local meUsed = 0
local meTotal = 0

monitor.setTextScale(0.5)

local function openWirelessModem()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            local modem = peripheral.wrap(name)
            if modem.isWireless and modem.isWireless() then
                rednet.open(name)
                return true
            end
        end
    end
    return false
end

local hasRednet = openWirelessModem()

local function safeCall(device, method, fallback)
    if not device or not device[method] then return fallback or 0 end
    local ok, value = pcall(device[method])
    if not ok then return fallback or 0 end
    if type(value) == "table" then return tonumber(value.amount or value[1]) or fallback or 0 end
    return tonumber(value) or fallback or 0
end

local function safeBooleanCall(device, method)
    if not device or not device[method] then return false end
    local ok, value = pcall(device[method])
    return ok and value == true
end

local function shorten(value)
    local absolute = math.abs(value)
    if absolute >= 1e15 then return ("%.2f P"):format(value / 1e15) end
    if absolute >= 1e12 then return ("%.2f T"):format(value / 1e12) end
    if absolute >= 1e9 then return ("%.2f G"):format(value / 1e9) end
    if absolute >= 1e6 then return ("%.2f M"):format(value / 1e6) end
    if absolute >= 1e3 then return ("%.1f k"):format(value / 1e3) end
    return ("%.0f"):format(value)
end

local function turbineSummary()
    local count, production, flow = 0, 0, 0
    for _, name in ipairs(peripheral.getNames()) do
        if name:lower():find("turbine", 1, true) then
            local turbine = peripheral.wrap(name)
            if turbine and (turbine.getProductionRate or turbine.getEnergy) then
                count = count + 1
                production = production + safeCall(turbine, "getProductionRate") / JOULES_PER_FE
                flow = flow + safeCall(turbine, "getFlowRate")
            end
        end
    end
    return count, production, flow
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

local function bar(x, y, width, percent, color)
    percent = math.max(0, math.min(100, percent or 0))
    fill(x, y, x + width - 1, y, colors.gray)
    local filled = math.floor(width * percent / 100 + 0.5)
    if filled > 0 then fill(x, y, x + filled - 1, y, color or colors.lime) end
end

local function draw()
    local width, height = monitor.getSize()
    monitor.setBackgroundColor(colors.black)
    monitor.clear()

    fill(1, 1, width, 3, colors.gray)
    text(3, 2, "ATM9 BASE OVERVIEW", colors.cyan, colors.gray)
    text(math.max(3, width - 10), 2, textutils.formatTime(os.time(), true), colors.lightGray, colors.gray)

    local energyPercent = safeCall(matrix, "getEnergyFilledPercentage") * 100
    local stored = safeCall(matrix, "getEnergy") / JOULES_PER_FE
    local capacity = safeCall(matrix, "getMaxEnergy") / JOULES_PER_FE
    local input = safeCall(matrix, "getLastInput") / JOULES_PER_FE
    local output = safeCall(matrix, "getLastOutput") / JOULES_PER_FE
    text(3, 5, "INDUCTION MATRIX", colors.lightBlue)
    text(3, 7, ("Energy  %6.2f%%   %s / %s FE"):format(energyPercent, shorten(stored), shorten(capacity)))
    bar(3, 9, math.max(10, width - 6), energyPercent, energyPercent > 95 and colors.orange or colors.lime)
    text(3, 11, ("Input %s FE/t   Output %s FE/t   Net %s"):format(
        shorten(input), shorten(output), shorten(input - output)), colors.lightGray)

    local running = safeBooleanCall(reactor, "getStatus")
    local temperature = safeCall(reactor, "getTemperature")
    local burn = safeCall(reactor, "getActualBurnRate")
    local coolant = safeCall(reactor, "getCoolantFilledPercentage") * 100
    local fuel = safeCall(reactor, "getFuelFilledPercentage") * 100
    local waste = safeCall(reactor, "getWasteFilledPercentage") * 100
    text(3, 14, "FISSION REACTOR", colors.yellow)
    text(3, 16, running and "ONLINE" or "SCRAMMED", running and colors.lime or colors.red)
    text(16, 16, ("Temp %.1f K   Burn %.2f mB/t"):format(temperature, burn))
    text(3, 18, ("Water %5.1f%%   Fuel %5.1f%%   Waste %5.1f%%"):format(coolant, fuel, waste), colors.lightGray)

    local turbineCount, generation, flow = turbineSummary()
    text(3, 21, "TURBINES", colors.purple)
    text(3, 23, ("%d connected   %s FE/t   Flow %s mB/t"):format(
        turbineCount, shorten(generation), shorten(flow)))

    local meOnline = lastMEHeartbeat and os.epoch("utc") - lastMEHeartbeat <= REMOTE_TIMEOUT
    text(3, 26, "AE2 STORAGE", colors.cyan)
    text(3, 28, meOnline and (meConnected and "CONNECTED" or "DISCONNECTED") or "NODE OFFLINE",
        meOnline and meConnected and colors.lime or colors.red)
    text(20, 28, ("Cells %d   Used %s / %s"):format(meCells, shorten(meUsed), shorten(meTotal)), colors.lightGray)

    local footerY = math.min(height, 31)
    fill(1, footerY, width, footerY, colors.gray)
    text(3, footerY, hasRednet and "LOCAL CONTROL ACTIVE | REDNET ONLINE" or "LOCAL CONTROL ACTIVE | REDNET OFFLINE",
        hasRednet and colors.lime or colors.orange, colors.gray)
end

draw()
local timer = os.startTimer(REFRESH_INTERVAL)
while true do
    local event, arg1, arg2, arg3 = os.pullEvent()
    if event == "timer" and arg1 == timer then
        draw()
        timer = os.startTimer(REFRESH_INTERVAL)
    elseif event == "monitor_resize" and arg1 == MONITOR_NAME then
        draw()
    elseif event == "rednet_message" and arg3 == ME_STATUS_PROTOCOL and type(arg2) == "table" then
        lastMEHeartbeat = os.epoch("utc")
        meConnected = arg2.meConnected == true
        local metrics = type(arg2.metrics) == "table" and arg2.metrics or {}
        local cells = type(metrics.cells) == "table" and metrics.cells or {}
        meCells = #cells
        meUsed = tonumber(metrics.used) or 0
        meTotal = tonumber(metrics.total) or 0
        draw()
    end
end
