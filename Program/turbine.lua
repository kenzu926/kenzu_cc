-- Future-ready Mekanism turbine telemetry service.
local CHECK_INTERVAL = 2

local scriptDirectory = fs.getDir(shell.getRunningProgram())
local WebSocketClient = dofile(fs.combine(scriptDirectory, "ws_client.lua"))
local SafeConsole = dofile(fs.combine(scriptDirectory, "console.lua"))
local server = WebSocketClient.new("turbine")

local function findTurbine()
    local matchedName
    local turbine = peripheral.find("turbineValve", function(foundName)
        matchedName = foundName
        return true
    end)
    if turbine then return turbine, matchedName end

    for _, candidate in ipairs(peripheral.getNames()) do
        if candidate:lower():find("turbine") then
            return peripheral.wrap(candidate), candidate
        end
    end
end

local function safeNumber(device, methodName, fallback)
    local method = device and device[methodName]
    if not method then return fallback or 0 end
    local ok, value = pcall(method)
    return ok and (tonumber(value) or fallback or 0) or (fallback or 0)
end

local function readStatus()
    local turbine, name = findTurbine()
    if not turbine then return nil end

    return {
        peripheral = name or "turbine",
        production = safeNumber(turbine, "getProductionRate"),
        flowRate = safeNumber(turbine, "getFlowRate"),
        maxFlowRate = safeNumber(turbine, "getMaxFlowRate"),
        steamPercent = safeNumber(turbine, "getSteamFilledPercentage") * 100,
        energyPercent = safeNumber(turbine, "getEnergyFilledPercentage") * 100,
        blades = safeNumber(turbine, "getBlades"),
        coils = safeNumber(turbine, "getCoils"),
        vents = safeNumber(turbine, "getVents"),
    }
end

local function statusText()
    local data = readStatus()
    if not data then return "Turbine valve not found" end
    return ("%s\nProduction: %.2f FE/t\nFlow: %.2f / %.2f mB/t\nSteam: %.1f%%\nEnergy: %.1f%%")
        :format(data.peripheral, data.production, data.flowRate, data.maxFlowRate,
            data.steamPercent, data.energyPercent)
end

local function sendStatus()
    local data = readStatus()
    server:send({ type = "turbine_status", data = data })

    term.clear()
    term.setCursorPos(1, 1)
    print("Turbine telemetry")
    print(statusText())
    print("Web: " .. (server:isConnected() and "CONNECTED" or "OFFLINE"))
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
