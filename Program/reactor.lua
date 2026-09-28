-- Mekanism reactor controller service.
local MATRIX_NAME = "inductionPort_0"
local REACTOR_NAME = "fissionReactorLogicAdapter_0"
local MONITOR_NAME = "monitor_0"
local ME_STATUS_PROTOCOL = "kenzu_cc.me_status"
local ME_STORAGE_PROTOCOL = "kenzu_cc.me_storage"
local CONSOLE_REQUEST_PROTOCOL = "kenzu_cc.console.request"
local CONSOLE_RESPONSE_PROTOCOL = "kenzu_cc.console.response"
local TERMINAL_FRAME_PROTOCOL = "kenzu_cc.terminal.frame"
local TERMINAL_INPUT_PROTOCOL = "kenzu_cc.terminal.input"
local REMOTE_TIMEOUT = 20 * 1000

local scriptDirectory = fs.getDir(shell.getRunningProgram())
local WebSocketClient = dofile(fs.combine(scriptDirectory, "gateway_client.lua"))
local SafeConsole = dofile(fs.combine(scriptDirectory, "console.lua"))
local server = WebSocketClient.new("reactor")

local SETTINGS_FILE = "reactor.settings"
local CHECK_INTERVAL = 1
-- Mekanism's ComputerCraft API reports energy in Joules even when the game UI
-- is configured to display Forge Energy. Default conversion: 1 FE = 2.5 J.
local JOULES_PER_FE = 2.5

settings.define("reactor.startPercent", {
    description = "Start reactor at or below this energy percentage",
    default = 80,
    type = "number",
})

settings.define("reactor.stopPercent", {
    description = "Stop reactor at or above this energy percentage",
    default = 98,
    type = "number",
})
settings.define("reactor.safetyEnergyEnabled", { default = true, type = "boolean" })
settings.define("reactor.safetySteamEnabled", { default = true, type = "boolean" })
settings.define("reactor.safetyWaterEnabled", { default = true, type = "boolean" })
settings.define("reactor.safetyFuelEnabled", { default = true, type = "boolean" })
settings.define("reactor.steamStopPercent", { default = 95, type = "number" })
settings.define("reactor.waterStopPercent", { default = 10, type = "number" })
settings.define("reactor.fuelStopPercent", { default = 5, type = "number" })
settings.define("reactor.manualHold", {
    description = "Keep the reactor stopped after a manual SCRAM",
    default = false,
    type = "boolean",
})

settings.load(SETTINGS_FILE)

local startPercent = math.floor(settings.get("reactor.startPercent"))
local stopPercent = math.floor(settings.get("reactor.stopPercent"))
local safetyEnergyEnabled = settings.get("reactor.safetyEnergyEnabled")
local safetySteamEnabled = settings.get("reactor.safetySteamEnabled")
local safetyWaterEnabled = settings.get("reactor.safetyWaterEnabled")
local safetyFuelEnabled = settings.get("reactor.safetyFuelEnabled")
local steamStopPercent = math.max(1, math.min(100, settings.get("reactor.steamStopPercent")))
local waterStopPercent = math.max(0, math.min(99, settings.get("reactor.waterStopPercent")))
local fuelStopPercent = math.max(0, math.min(99, settings.get("reactor.fuelStopPercent")))
local manualHold = settings.get("reactor.manualHold") == true

-- Keep saved values valid and leave at least 1% between the thresholds.
startPercent = math.max(0, math.min(99, startPercent))
stopPercent = math.max(startPercent + 1, math.min(100, stopPercent))

local matrix = assert(
    peripheral.wrap(MATRIX_NAME),
    "Induction Matrix not found: " .. MATRIX_NAME
)

local reactor = assert(
    peripheral.wrap(REACTOR_NAME),
    "Fission Reactor not found: " .. REACTOR_NAME
)

local monitor = assert(
    peripheral.wrap(MONITOR_NAME),
    "Monitor not found: " .. MONITOR_NAME
)

monitor.setTextScale(0.5)

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

local wirelessModemName = findWirelessModem()
if wirelessModemName then
    rednet.open(wirelessModemName)
end

local width, height = monitor.getSize()
local energy = 0
local reactorRunning = false
local stoppedForSafety = false
local safetyStopReason = nil
local message = wirelessModemName
    and "Controller started"
    or "Wireless modem not found"
local lastRemoteHeartbeat = nil
local remoteMEConnected = false
local remoteComputerId = nil

local buttons = {}

local function saveThresholds()
    settings.set("reactor.startPercent", startPercent)
    settings.set("reactor.stopPercent", stopPercent)
    settings.set("reactor.safetyEnergyEnabled", safetyEnergyEnabled)
    settings.set("reactor.safetySteamEnabled", safetySteamEnabled)
    settings.set("reactor.safetyWaterEnabled", safetyWaterEnabled)
    settings.set("reactor.safetyFuelEnabled", safetyFuelEnabled)
    settings.set("reactor.steamStopPercent", steamStopPercent)
    settings.set("reactor.waterStopPercent", waterStopPercent)
    settings.set("reactor.fuelStopPercent", fuelStopPercent)
    settings.set("reactor.manualHold", manualHold)
    settings.save(SETTINGS_FILE)
end

local function writeCentered(y, text, textColor, backgroundColor)
    text = tostring(text)
    monitor.setTextColor(textColor or colors.white)
    monitor.setBackgroundColor(backgroundColor or colors.black)
    monitor.setCursorPos(math.max(1, math.floor((width - #text) / 2) + 1), y)
    monitor.write(text)
end

local function fill(x1, y1, x2, y2, color)
    monitor.setBackgroundColor(color)
    for y = y1, y2 do
        monitor.setCursorPos(x1, y)
        monitor.write(string.rep(" ", x2 - x1 + 1))
    end
end

local function drawButton(id, x1, y1, x2, y2, label, color)
    buttons[id] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
    fill(x1, y1, x2, y2, color)

    monitor.setBackgroundColor(color)
    monitor.setTextColor(colors.white)
    monitor.setCursorPos(
        x1 + math.max(0, math.floor((x2 - x1 + 1 - #label) / 2)),
        y1 + math.floor((y2 - y1) / 2)
    )
    monitor.write(label)
end

local function drawBar(y, fraction)
    local x1 = 3
    local x2 = width - 2
    local barWidth = math.max(1, x2 - x1 + 1)
    local filled = math.floor(barWidth * fraction + 0.5)

    fill(x1, y, x2, y + 1, colors.gray)
    if filled > 0 then
        fill(x1, y, x1 + filled - 1, y + 1, colors.lime)
    end
end

local function isRemoteOnline()
    return lastRemoteHeartbeat ~= nil
        and os.epoch("utc") - lastRemoteHeartbeat <= REMOTE_TIMEOUT
end

local function drawScreen()
    width, height = monitor.getSize()
    buttons = {}

    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()

    writeCentered(2, "FISSION REACTOR CONTROL", colors.yellow)
    writeCentered(4, ("Energy: %.1f%%"):format(energy * 100), colors.white)
    drawBar(6, energy)

    local stateColor = reactorRunning and colors.lime or colors.red
    writeCentered(9, "Reactor: " .. (reactorRunning and "ON" or "OFF"), stateColor)

    local minusX1 = 3
    local minusX2 = 9
    local plusX1 = width - 8
    local plusX2 = width - 2

    writeCentered(12, ("Start at: %d%%"):format(startPercent), colors.white)
    drawButton("startMinus", minusX1, 11, minusX2, 13, "-", colors.red)
    drawButton("startPlus", plusX1, 11, plusX2, 13, "+", colors.green)

    writeCentered(17, ("Stop at:  %d%%"):format(stopPercent), colors.white)
    drawButton("stopMinus", minusX1, 16, minusX2, 18, "-", colors.red)
    drawButton("stopPlus", plusX1, 16, plusX2, 18, "+", colors.green)

    local remoteOnline = isRemoteOnline()
    writeCentered(
        21,
        "Computer 1: " .. (remoteOnline and "ONLINE" or "OFFLINE"),
        remoteOnline and colors.lime or colors.red
    )

    local meText = "UNKNOWN"
    local meColor = colors.orange
    if remoteOnline then
        meText = remoteMEConnected and "CONNECTED" or "DISCONNECTED"
        meColor = remoteMEConnected and colors.lime or colors.red
    end
    writeCentered(23, "ME System: " .. meText, meColor)

    if remoteOnline and remoteComputerId then
        writeCentered(25, "Rednet ID: " .. remoteComputerId, colors.lightGray)
    end

    writeCentered(
        27,
        "Web: " .. (server:isConnected() and "ONLINE" or "OFFLINE"),
        server:isConnected() and colors.lime or colors.red
    )
    writeCentered(math.min(height, 29), message, colors.lightGray)

    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
end

local function readPercent(method, fallback)
    if not method then return fallback or 0 end
    local ok, value = pcall(method)
    return ok and (tonumber(value) or fallback or 0) or (fallback or 0)
end

local function getSafetyStopReason()
    if safetyEnergyEnabled and energy >= stopPercent / 100 then return "battery threshold" end
    if safetySteamEnabled
        and readPercent(reactor.getHeatedCoolantFilledPercentage) >= steamStopPercent / 100 then
        return "heated coolant threshold"
    end
    if safetyWaterEnabled
        and readPercent(reactor.getCoolantFilledPercentage) <= waterStopPercent / 100 then
        return "coolant threshold"
    end
    if safetyFuelEnabled
        and readPercent(reactor.getFuelFilledPercentage) <= fuelStopPercent / 100 then
        return "fuel threshold"
    end
end

local function updateController()
    energy = matrix.getEnergyFilledPercentage()
    local actualRunning = reactor.getStatus()

    -- A state change made directly in-game is a manual command. Remember a
    -- manual stop so the low-energy automation cannot immediately undo it.
    if actualRunning ~= reactorRunning then
        manualHold = not actualRunning
        stoppedForSafety = false
        safetyStopReason = nil
        saveThresholds()
    end
    reactorRunning = actualRunning

    local stopReason = getSafetyStopReason()
    if stopReason and reactorRunning then
        reactor.scram()
        reactorRunning = false
        manualHold = false
        stoppedForSafety = true
        safetyStopReason = stopReason
        message = "Safety stop: " .. stopReason
    elseif not stopReason and not reactorRunning
        and not manualHold
        and ((stoppedForSafety
                and (safetyStopReason ~= "battery threshold"
                    or energy <= startPercent / 100))
            or (not stoppedForSafety
                and safetyEnergyEnabled
                and energy <= startPercent / 100)) then
        reactor.activate()
        reactorRunning = true
        stoppedForSafety = false
        safetyStopReason = nil
        message = "Started: safety conditions restored"
    end
end

local function safeNumber(method, fallback)
    if not method then
        return fallback or 0
    end
    local ok, value = pcall(method)
    if not ok then
        return fallback or 0
    end
    return tonumber(value) or fallback or 0
end

local function safeAmount(method)
    if not method then return 0 end
    local ok, value = pcall(method)
    if not ok then return 0 end
    if type(value) == "table" then
        return tonumber(value.amount or value[1]) or 0
    end
    return tonumber(value) or 0
end

local function sendReactorStatus()
    local storedEnergy = safeNumber(matrix.getEnergy) / JOULES_PER_FE
    local capacity = safeNumber(matrix.getMaxEnergy) / JOULES_PER_FE
    local input = safeNumber(matrix.getLastInput) / JOULES_PER_FE
    local output = safeNumber(matrix.getLastOutput) / JOULES_PER_FE

    server:send({
        type = "matrix_status",
        data = {
            name = MATRIX_NAME,
            energyPercent = energy * 100,
            storedEnergy = storedEnergy,
            capacity = capacity,
            input = input,
            output = output,
            net = input - output,
            energyNeeded = safeNumber(matrix.getEnergyNeeded) / JOULES_PER_FE,
            energyUnit = "FE",
            joulesPerFE = JOULES_PER_FE,
        },
    })

    server:send({
        type = "reactor_status",
        data = {
            name = REACTOR_NAME,
            running = reactorRunning,
            startPercent = startPercent,
            stopPercent = stopPercent,
            temperature = safeNumber(reactor.getTemperature),
            damage = safeNumber(reactor.getDamagePercent),
            coolantPercent = safeNumber(reactor.getCoolantFilledPercentage) * 100,
            coolant = safeAmount(reactor.getCoolant),
            coolantCapacity = safeNumber(reactor.getCoolantCapacity),
            wastePercent = safeNumber(reactor.getWasteFilledPercentage) * 100,
            waste = safeAmount(reactor.getWaste),
            wasteCapacity = safeNumber(reactor.getWasteCapacity),
            burnRate = safeNumber(reactor.getBurnRate),
            actualBurnRate = safeNumber(reactor.getActualBurnRate),
            maxBurnRate = safeNumber(reactor.getMaxBurnRate),
            fuelPercent = safeNumber(reactor.getFuelFilledPercentage) * 100,
            fuel = safeAmount(reactor.getFuel),
            fuelCapacity = safeNumber(reactor.getFuelCapacity),
            heatedCoolantPercent = safeNumber(reactor.getHeatedCoolantFilledPercentage) * 100,
            heatedCoolant = safeAmount(reactor.getHeatedCoolant),
            heatedCoolantCapacity = safeNumber(reactor.getHeatedCoolantCapacity),
            heatingRate = safeNumber(reactor.getHeatingRate),
            environmentalLoss = safeNumber(reactor.getEnvironmentalLoss),
            boilEfficiency = safeNumber(reactor.getBoilEfficiency) * 100,
            safety = {
                energyEnabled = safetyEnergyEnabled,
                steamEnabled = safetySteamEnabled,
                waterEnabled = safetyWaterEnabled,
                fuelEnabled = safetyFuelEnabled,
                energyStopPercent = stopPercent,
                energyStartPercent = startPercent,
                steamStopPercent = steamStopPercent,
                waterStopPercent = waterStopPercent,
                fuelStopPercent = fuelStopPercent,
                stopped = stoppedForSafety,
                reason = safetyStopReason,
                manualHold = manualHold,
            },
            remoteComputerOnline = isRemoteOnline(),
            remoteMEConnected = remoteMEConnected,
        },
    })
end

local function consoleStatus()
    return table.concat({
        "Service: reactor controller",
        "Matrix: " .. MATRIX_NAME,
        ("Energy: %.2f%%"):format(energy * 100),
        "Reactor: " .. (reactorRunning and "ONLINE" or "SCRAMMED"),
        "Manual hold: " .. (manualHold and "ON" or "OFF"),
        ("Thresholds: %d%% / %d%%"):format(startPercent, stopPercent),
        "ME node: " .. (isRemoteOnline() and "ONLINE" or "OFFLINE"),
        "Web: " .. (server:isConnected() and "CONNECTED" or "OFFLINE"),
    }, "\n")
end

local function handleConsoleCommand(command)
    local ok, output = SafeConsole.execute(command.command, consoleStatus)
    server:send({
        type = "console_output",
        requestId = command.requestId,
        target = "reactor",
        computerId = os.getComputerID(),
        ok = ok,
        output = output,
    })
end

local function sendCommandResult(command, ok, resultMessage)
    server:send({
        type = "command_result",
        requestId = command.requestId,
        ok = ok,
        message = resultMessage,
    })
end

local function handleServerCommand(command)
    if command.action == "set_thresholds" then
        local newStart = tonumber(command.startPercent)
        local newStop = tonumber(command.stopPercent)

        if not newStart or not newStop
            or newStart < 0 or newStop > 100 or newStart >= newStop then
            sendCommandResult(command, false, "Invalid threshold values")
            return
        end

        startPercent = math.floor(newStart)
        stopPercent = math.floor(newStop)
        saveThresholds()
        updateController()
        message = "Thresholds updated from web"
        sendCommandResult(command, true, "Thresholds saved")
        return
    end

    if command.action == "set_safety" then
        local newEnergyStart = tonumber(command.energyStartPercent)
        local newEnergyStop = tonumber(command.energyStopPercent)
        local newSteam = tonumber(command.steamStopPercent)
        local newWater = tonumber(command.waterStopPercent)
        local newFuel = tonumber(command.fuelStopPercent)
        if not newEnergyStart or not newEnergyStop
            or newEnergyStart < 0 or newEnergyStop > 100
            or newEnergyStart >= newEnergyStop
            or not newSteam or not newWater or not newFuel
            or newSteam < 1 or newSteam > 100
            or newWater < 0 or newWater > 99
            or newFuel < 0 or newFuel > 99 then
            sendCommandResult(command, false, "Invalid safety thresholds")
            return
        end
        safetyEnergyEnabled = command.energyEnabled == true
        safetySteamEnabled = command.steamEnabled == true
        safetyWaterEnabled = command.waterEnabled == true
        safetyFuelEnabled = command.fuelEnabled == true
        startPercent = math.floor(newEnergyStart)
        stopPercent = math.floor(newEnergyStop)
        steamStopPercent = math.floor(newSteam)
        waterStopPercent = math.floor(newWater)
        fuelStopPercent = math.floor(newFuel)
        saveThresholds()
        updateController()
        sendCommandResult(command, true, "Safety settings saved")
        return
    end

    if command.action == "reactor_scram" then
        local ok, commandError = pcall(reactor.scram)
        if ok then
            reactorRunning = false
            stoppedForSafety = false
            safetyStopReason = nil
            manualHold = true
            saveThresholds()
            message = "SCRAM from web"
            sendCommandResult(command, true, "Reactor stopped")
        else
            sendCommandResult(command, false, tostring(commandError))
        end
        return
    end

    if command.action == "reactor_start" then
        local damage = safeNumber(reactor.getDamagePercent, 100)
        local coolant = safeNumber(reactor.getCoolantFilledPercentage, 0)
        local waste = safeNumber(reactor.getWasteFilledPercentage, 1)
        local forceDisabled = false
        if reactor.isForceDisabled then
            local forceCheckOk, forceCheckValue = pcall(reactor.isForceDisabled)
            forceDisabled = not forceCheckOk or forceCheckValue == true
        end

        if forceDisabled or damage >= 100 or coolant <= 0.05 or waste >= 0.90 then
            sendCommandResult(command, false, "Safety check blocked reactor start")
            return
        end

        local ok, commandError = pcall(reactor.activate)
        if ok then
            reactorRunning = true
            stoppedForSafety = false
            safetyStopReason = nil
            manualHold = false
            saveThresholds()
            message = "Started from web"
            sendCommandResult(command, true, "Reactor started")
        else
            sendCommandResult(command, false, tostring(commandError))
        end
        return
    end

    if command.action == "set_burn_rate" then
        local burnRate = tonumber(command.burnRate)
        local maxBurnRate = safeNumber(reactor.getMaxBurnRate)
        if not burnRate or burnRate < 0 or burnRate > maxBurnRate then
            sendCommandResult(command, false, "Burn rate must be between 0 and " .. tostring(maxBurnRate))
            return
        end

        local ok, commandError = pcall(reactor.setBurnRate, burnRate)
        if ok then
            message = ("Burn rate set to %.2f mB/t"):format(burnRate)
            sendCommandResult(command, true, message)
        else
            sendCommandResult(command, false, tostring(commandError))
        end
        return
    end

    sendCommandResult(command, false, "Unknown reactor command")
end

local function isInside(button, x, y)
    return button
        and x >= button.x1 and x <= button.x2
        and y >= button.y1 and y <= button.y2
end

local function handleTouch(x, y)
    local changed = false

    if isInside(buttons.startMinus, x, y) then
        startPercent = math.max(0, startPercent - 1)
        changed = true
    elseif isInside(buttons.startPlus, x, y) then
        startPercent = math.min(stopPercent - 1, startPercent + 1)
        changed = true
    elseif isInside(buttons.stopMinus, x, y) then
        stopPercent = math.max(startPercent + 1, stopPercent - 1)
        changed = true
    elseif isInside(buttons.stopPlus, x, y) then
        local newStopPercent = math.min(100, stopPercent + 1)
        stopPercent = newStopPercent
        changed = true
    end

    if changed then
        saveThresholds()
        message = "Thresholds saved"
        updateController()

        drawScreen()
    end
end

saveThresholds()
updateController()
server:connect()
drawScreen()

local timer = os.startTimer(CHECK_INTERVAL)

while true do
    local event, arg1, arg2, arg3 = os.pullEvent()
    local serverEvent, serverMessage = server:handleEvent(event, arg1, arg2, arg3)

    if serverEvent == "connected" then
        message = "Web server connected"
        sendReactorStatus()
        drawScreen()
    elseif serverEvent == "disconnected" then
        message = "Web server disconnected"
        drawScreen()
    elseif serverEvent == "message" and type(serverMessage) == "table" then
        if serverMessage.type == "command" then
            handleServerCommand(serverMessage)
            updateController()
            sendReactorStatus()
            drawScreen()
        elseif serverMessage.type == "console_command"
            and (serverMessage.target == "reactor"
                or serverMessage.target == tostring(os.getComputerID())) then
            handleConsoleCommand(serverMessage)
        elseif serverMessage.type == "console_command"
            and serverMessage.target == "storage_node"
            and wirelessModemName then
            rednet.broadcast(serverMessage, CONSOLE_REQUEST_PROTOCOL)
        elseif serverMessage.type == "terminal_input" and wirelessModemName then
            rednet.broadcast(serverMessage, TERMINAL_INPUT_PROTOCOL)
        end
    end

    if event == "timer" and arg1 == timer then
        server:connect()
        updateController()
        sendReactorStatus()
        drawScreen()
        timer = os.startTimer(CHECK_INTERVAL)
    elseif event == "monitor_touch" and arg1 == MONITOR_NAME then
        handleTouch(arg2, arg3)
    elseif event == "monitor_resize" and arg1 == MONITOR_NAME then
        drawScreen()
    elseif event == "rednet_message" and arg3 == ME_STATUS_PROTOCOL then
        local payload = arg2
        if type(payload) == "table"
            and payload.role == "me_node" then
            lastRemoteHeartbeat = os.epoch("utc")
            remoteMEConnected = payload.meConnected == true
            remoteComputerId = arg1
            server:send({
                type = "storage_status",
                connected = remoteMEConnected,
                details = payload.details or "Connected through Rednet relay",
                computerId = arg1,
                metrics = payload.metrics,
            })
            drawScreen()
        end
    elseif event == "rednet_message" and arg3 == ME_STORAGE_PROTOCOL then
        local payload = arg2
        if type(payload) == "table"
            and (payload.type == "storage_begin"
                or payload.type == "storage_chunk"
                or payload.type == "storage_end") then
            server:send(payload)
        end
    elseif event == "rednet_message" and arg3 == CONSOLE_RESPONSE_PROTOCOL then
        local payload = arg2
        if type(payload) == "table" and payload.type == "console_output" then
            payload.computerId = payload.computerId or arg1
            server:send(payload)
        end
    elseif event == "rednet_message" and arg3 == TERMINAL_FRAME_PROTOCOL then
        local payload = arg2
        if type(payload) == "table" and payload.type == "terminal_frame" then
            payload.computerId = payload.computerId or arg1
            server:send(payload)
        end
    end
end
