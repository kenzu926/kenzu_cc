-- Mekanism turbine telemetry service with automatic multi-turbine discovery.
local CHECK_INTERVAL = 2
local JOULES_PER_FE = 2.5
local OVERVIEW_TURBINE_PROTOCOL = "kenzu_cc.overview.turbines"

local scriptDirectory = fs.getDir(shell.getRunningProgram())
local GatewayClient = dofile(fs.combine(scriptDirectory, "gateway_client.lua"))
local SafeConsole = dofile(fs.combine(scriptDirectory, "console.lua"))
local server = GatewayClient.new("turbine")

local function openWirelessModem()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            local modem = peripheral.wrap(name)
            if modem and modem.isWireless then
                local ok, wireless = pcall(modem.isWireless)
                if ok and wireless then
                    rednet.open(name)
                    return name
                end
            end
        end
    end
end

local wirelessModemName = openWirelessModem()

local function hasPeripheralType(name, peripheralType)
    if not peripheral.hasType then return false end
    local ok, result = pcall(peripheral.hasType, name, peripheralType)
    return ok and result == true
end

local function isTurbine(name)
    local lowerName = name:lower()
    return lowerName:match("^turbinevalue") ~= nil
        or lowerName:match("^turbinevalve") ~= nil
        or hasPeripheralType(name, "turbineValue")
        or hasPeripheralType(name, "turbineValve")
        or lowerName:find("turbine", 1, true) ~= nil
end

local function findTurbines()
    local turbines = {}
    for _, name in ipairs(peripheral.getNames()) do
        if isTurbine(name) then
            local device = peripheral.wrap(name)
            if device then turbines[#turbines + 1] = { name = name, device = device } end
        end
    end
    table.sort(turbines, function(left, right) return left.name < right.name end)
    return turbines
end

local function safeNumber(device, methodName, fallback)
    local method = device and device[methodName]
    if not method then return fallback or 0 end
    local ok, value = pcall(method)
    return ok and (tonumber(value) or fallback or 0) or (fallback or 0)
end

local function safeAmount(device, methodName)
    local method = device and device[methodName]
    if not method then return 0 end
    local ok, value = pcall(method)
    if not ok then return 0 end
    if type(value) == "table" then return tonumber(value.amount or value[1]) or 0 end
    return tonumber(value) or 0
end

local function readTurbine(entry)
    local turbine = entry.device
    return {
        peripheral = entry.name,
        production = safeNumber(turbine, "getProductionRate") / JOULES_PER_FE,
        flowRate = safeNumber(turbine, "getFlowRate"),
        maxFlowRate = safeNumber(turbine, "getMaxFlowRate"),
        steamPercent = safeNumber(turbine, "getSteamFilledPercentage") * 100,
        steam = safeAmount(turbine, "getSteam"),
        steamCapacity = safeNumber(turbine, "getSteamCapacity"),
        energyPercent = safeNumber(turbine, "getEnergyFilledPercentage") * 100,
        blades = safeNumber(turbine, "getBlades"),
        coils = safeNumber(turbine, "getCoils"),
        vents = safeNumber(turbine, "getVents"),
    }
end

local function readStatuses()
    local statuses = {}
    for _, entry in ipairs(findTurbines()) do
        statuses[#statuses + 1] = readTurbine(entry)
    end
    return statuses
end

local function statusText(statuses)
    statuses = statuses or readStatuses()
    if #statuses == 0 then return "No turbineValue peripherals found" end

    local lines = { "Turbines: " .. #statuses }
    for _, data in ipairs(statuses) do
        lines[#lines + 1] = ("%s: %.2f FE/t, %.2f/%.2f mB/t, energy %.1f%%")
            :format(data.peripheral, data.production, data.flowRate,
                data.maxFlowRate, data.energyPercent)
    end
    return table.concat(lines, "\n")
end

local function sendStatus()
    local statuses = readStatuses()
    server:send({ type = "turbines_status", turbines = statuses })
    if wirelessModemName then
        rednet.broadcast({
            version = 1,
            computerId = os.getComputerID(),
            turbines = statuses,
        }, OVERVIEW_TURBINE_PROTOCOL)
    end

    term.clear()
    term.setCursorPos(1, 1)
    print("Turbine telemetry")
    print(statusText(statuses))
    print("Gateway: " .. (server:isConnected() and "CONNECTED" or "OFFLINE"))
end

server:connect()
sendStatus()
local timer = os.startTimer(CHECK_INTERVAL)

while true do
    local event, arg1, arg2, arg3 = os.pullEvent()
    local serverEvent, message = server:handleEvent(event, arg1, arg2, arg3)

    if serverEvent == "message" and type(message) == "table"
        and message.type == "console_command"
        and (message.target == "turbine" or message.target == tostring(os.getComputerID())) then
        local ok, output = SafeConsole.execute(message.command, statusText)
        server:send({
            type = "console_output",
            requestId = message.requestId,
            target = "turbine",
            computerId = os.getComputerID(),
            ok = ok,
            output = output,
        })
    end

    if event == "timer" and arg1 == timer then
        server:connect()
        sendStatus()
        timer = os.startTimer(CHECK_INTERVAL)
    elseif event == "peripheral" or event == "peripheral_detach" then
        sendStatus()
    end
end
