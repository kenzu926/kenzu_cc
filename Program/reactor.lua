-- Mekanism fission reactor controller service (multi-unit).
-- Discovers all fission reactors via Peripherals.findReactors() and runs an
-- independent safety loop for each of them. Thresholds are shared.
-- Peripheral names are configurable via peripheral_config.lua /
-- peripherals.settings and applied live (no reboot). Exact names first,
-- type/name auto-discovery as fallback so a rename never kills safety loop.
local scriptDirectory = fs.getDir(shell.getRunningProgram())
local WebSocketClient = dofile(fs.combine(scriptDirectory, "gateway_client.lua"))
local SafeConsole = dofile(fs.combine(scriptDirectory, "console.lua"))
local Peripherals = dofile(fs.combine(scriptDirectory, "peripherals.lua"))
local server = WebSocketClient.new("reactor")

local MATRIX_NAME = Peripherals.get("matrix")
local REACTOR_NAME = Peripherals.get("reactor")
local MONITOR_NAME = Peripherals.get("monitor")
local ME_STATUS_PROTOCOL = "kenzu_cc.me_status"
local ME_STORAGE_PROTOCOL = "kenzu_cc.me_storage"
local CONSOLE_REQUEST_PROTOCOL = "kenzu_cc.console.request"
local CONSOLE_RESPONSE_PROTOCOL = "kenzu_cc.console.response"
local TERMINAL_FRAME_PROTOCOL = "kenzu_cc.terminal.frame"
local TERMINAL_INPUT_PROTOCOL = "kenzu_cc.terminal.input"
local OVERVIEW_REACTOR_PROTOCOL = "kenzu_cc.overview.reactor"
local REMOTE_TIMEOUT = 20 * 1000

local SETTINGS_FILE = "reactor.settings"
local SAFETY_INTERVAL = 0.25
local TELEMETRY_INTERVAL = 1
local MAX_ALLOWED_TEMPERATURE = 1100
local MAX_ALLOWED_DAMAGE_PERCENT = 10
local MAX_ALLOWED_WASTE_PERCENT = 90
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
settings.define("reactor.temperatureStop", { default = 1100, type = "number" })
settings.define("reactor.damageStopPercent", { default = 0, type = "number" })
settings.define("reactor.wasteStopPercent", { default = 90, type = "number" })
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
local temperatureStop = math.max(600,
    math.min(MAX_ALLOWED_TEMPERATURE, settings.get("reactor.temperatureStop")))
local damageStopPercent = math.max(0,
    math.min(MAX_ALLOWED_DAMAGE_PERCENT, settings.get("reactor.damageStopPercent")))
local wasteStopPercent = math.max(50,
    math.min(MAX_ALLOWED_WASTE_PERCENT, settings.get("reactor.wasteStopPercent")))
local manualHold = settings.get("reactor.manualHold") == true

-- Keep saved values valid and leave at least 1% between the thresholds.
startPercent = math.max(0, math.min(99, startPercent))
stopPercent = math.max(startPercent + 1, math.min(100, stopPercent))

local matrix = nil
local matrixName = MATRIX_NAME
local reactor = nil -- primary unit device (legacy mirror, see units[1])
local units = {} -- { name, device, running, stoppedForSafety, safetyStopReason, manualHold, alertStages }
local selectedUnit = 1
local monitorName = Peripherals.get("monitor")
local monitor = nil
do
    local ok, device = pcall(Peripherals.wrap, "monitor")
    if ok and device then monitor = device end
end
-- monitor_0 is only a local control panel. Reactor safety, telemetry and web
-- control must continue to work when that monitor is removed or renamed.
if monitor then pcall(monitor.setTextScale, 0.5) end

-- Legacy mirrors of the primary unit state. Kept so console/term output and
-- the single-unit fields behave exactly as before.
local energy = 0
local reactorRunning = false
local stoppedForSafety = false
local safetyStopReason = nil
local alertStages = {}

local function syncPrimary()
    local primary = units[1]
    if primary then
        reactor = primary.device
        REACTOR_NAME = primary.name
        reactorRunning = primary.running
        stoppedForSafety = primary.stoppedForSafety
        safetyStopReason = primary.safetyStopReason
        manualHold = primary.manualHold
        alertStages = primary.alertStages
    else
        reactor = nil
        reactorRunning = false
    end
end

local function refreshPeripherals()
    MATRIX_NAME = Peripherals.get("matrix")
    REACTOR_NAME = Peripherals.get("reactor")
    MONITOR_NAME = Peripherals.get("monitor")
    monitorName = MONITOR_NAME
    local nextMatrix, nextMatrixName = Peripherals.findMatrix()
    if nextMatrix then
        matrix = nextMatrix
        if type(nextMatrixName) == "string" then matrixName = nextMatrixName end
    elseif matrixName and not peripheral.isPresent(matrixName) then
        matrix = nil
    end
    local byName = {}
    for _, unit in ipairs(units) do byName[unit.name] = unit end
    local discovered = Peripherals.findReactors()
    local nextUnits = {}
    for _, entry in ipairs(discovered) do
        local old = byName[entry.name]
        if old then
            old.device = entry.device
            nextUnits[#nextUnits + 1] = old
        else
            nextUnits[#nextUnits + 1] = {
                name = entry.name,
                device = entry.device,
                running = false,
                stoppedForSafety = false,
                safetyStopReason = nil,
                manualHold = manualHold,
                alertStages = {},
            }
        end
    end
    units = nextUnits
    if selectedUnit > math.max(1, #units) then selectedUnit = math.max(1, #units) end
    if selectedUnit < 1 then selectedUnit = 1 end
    syncPrimary()
    if REACTOR_NAME == nil or REACTOR_NAME == "" then
        REACTOR_NAME = Peripherals.get("reactor")
    end
    local wrapOk, nextMonitor = pcall(Peripherals.wrap, "monitor")
    if wrapOk and nextMonitor then
        monitor = nextMonitor
    elseif monitor and monitorName and not peripheral.isPresent(monitorName) then
        monitor = nil
    end
    if monitor then pcall(monitor.setTextScale, 0.5) end
end

local function findWirelessModem()
    local ok, names = pcall(peripheral.getNames)
    if not ok or type(names) ~= "table" then return nil end
    for _, name in ipairs(names) do
        local typeOk, isModem = pcall(peripheral.hasType, name, "modem")
        if typeOk and isModem then
            local wrapOk, modem = pcall(peripheral.wrap, name)
            if wrapOk and modem and modem.isWireless then
                local wirelessOk, wireless = pcall(modem.isWireless)
                if wirelessOk and wireless then return name end
            end
        end
    end
end

local wirelessModemName = findWirelessModem()
if wirelessModemName then
    pcall(rednet.open, wirelessModemName)
end

local width, height = 51, 19
if monitor then
    local sizeOk, w, h = pcall(monitor.getSize)
    if sizeOk and w then width, height = w, h end
end
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
    settings.set("reactor.temperatureStop", temperatureStop)
    settings.set("reactor.damageStopPercent", damageStopPercent)
    settings.set("reactor.wasteStopPercent", wasteStopPercent)
    if units[1] then
        settings.set("reactor.manualHold", units[1].manualHold)
    else
        settings.set("reactor.manualHold", manualHold)
    end
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

local function selectedUnitState()
    return units[selectedUnit]
end

local function drawScreen()
    if monitor and monitorName and not peripheral.isPresent(monitorName) then
        monitor = nil
    end
    if not monitor then return end
    local sizeOk, w, h = pcall(monitor.getSize)
    if sizeOk and w and h then width, height = w, h end
    local drawOk = pcall(function()
        buttons = {}

        monitor.setBackgroundColor(colors.black)
        monitor.setTextColor(colors.white)
        monitor.clear()

        local unit = selectedUnitState()
        local unitLabel = unit
            and (unit.name .. " (" .. selectedUnit .. "/" .. #units .. ")")
            or "NO REACTORS"
        drawButton("unitPrev", 3, 1, 7, 3, "<", colors.gray)
        drawButton("unitNext", width - 6, 1, width - 2, 3, ">", colors.gray)
        writeCentered(2, unitLabel, colors.yellow)

        writeCentered(4, ("Energy: %.1f%%"):format(energy * 100), colors.white)
        drawBar(6, energy)

        local shownRunning = unit and unit.running or false
        local stateColor = shownRunning and colors.lime or colors.red
        writeCentered(9, "Reactor: " .. (shownRunning and "ON" or "OFF"), stateColor)
        if unit and unit.stoppedForSafety then
            writeCentered(10, "HELD: " .. tostring(unit.safetyStopReason or "safety"), colors.orange)
        end

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
    end)
    if not drawOk then monitor = nil end
end

local function checkedNumber(method)
    if type(method) ~= "function" then return nil end
    local ok, value = pcall(method)
    if not ok then return nil end
    return tonumber(value)
end

local function readSafetySnapshotFor(device)
    if not matrix or not device then
        return { statusValid = false, running = false }
    end
    local statusOk, running = pcall(device.getStatus)
    return {
        statusValid = statusOk and type(running) == "boolean",
        running = statusOk and running == true,
        energy = checkedNumber(matrix.getEnergyFilledPercentage),
        temperature = checkedNumber(device.getTemperature),
        damage = checkedNumber(device.getDamagePercent),
        coolant = checkedNumber(device.getCoolantFilledPercentage),
        heatedCoolant = checkedNumber(device.getHeatedCoolantFilledPercentage),
        fuel = checkedNumber(device.getFuelFilledPercentage),
        waste = checkedNumber(device.getWasteFilledPercentage),
    }
end

local function readSafetySnapshot()
    return readSafetySnapshotFor(reactor)
end

local function sendSafetyAlert(channel, stage, value, threshold, unit)
    if not server:isConnected() then return false end
    return server:send({
        type = "safety_alert",
        channel = channel,
        stage = stage,
        value = value,
        threshold = threshold,
        unit = unit,
        at = os.epoch("utc"),
    })
end

local function risingStage(value, threshold, margin, strict)
    if value == nil then return 0 end
    if (strict and value > threshold) or (not strict and value >= threshold) then return 2 end
    local warningAt = threshold - margin
    if value > 0 and value >= warningAt then return 1 end
    return 0
end

local function fallingStage(value, threshold, margin)
    if value == nil then return 0 end
    if value <= threshold then return 2 end
    if value <= threshold + margin then return 1 end
    return 0
end

local function updateAlertStage(stages, channel, stage, value, threshold, unit)
    stages = stages or alertStages
    local previous = stages[channel] or 0
    if stage == 0 then
        -- Re-arm only after the value leaves the warning zone completely. This
        -- prevents chat spam when a measurement oscillates around its limit.
        stages[channel] = 0
    elseif stage > previous then
        local stageName = stage == 2 and "triggered" or "warning"
        if sendSafetyAlert(channel, stageName, value, threshold, unit) then
            stages[channel] = stage
        end
    end
end

local function updateSafetyAlerts(snapshot, stages)
    stages = stages or alertStages
    updateAlertStage(stages, "energy", safetyEnergyEnabled
            and risingStage(snapshot.energy and snapshot.energy * 100, stopPercent, 10) or 0,
        snapshot.energy and snapshot.energy * 100, stopPercent, "%")
    updateAlertStage(stages, "steam", safetySteamEnabled
            and risingStage(snapshot.heatedCoolant and snapshot.heatedCoolant * 100,
                steamStopPercent, 10) or 0,
        snapshot.heatedCoolant and snapshot.heatedCoolant * 100, steamStopPercent, "%")
    updateAlertStage(stages, "water", safetyWaterEnabled
            and fallingStage(snapshot.coolant and snapshot.coolant * 100,
                waterStopPercent, 10) or 0,
        snapshot.coolant and snapshot.coolant * 100, waterStopPercent, "%")
    updateAlertStage(stages, "fuel", safetyFuelEnabled
            and fallingStage(snapshot.fuel and snapshot.fuel * 100,
                fuelStopPercent, 10) or 0,
        snapshot.fuel and snapshot.fuel * 100, fuelStopPercent, "%")
    updateAlertStage(stages, "temperature",
        risingStage(snapshot.temperature, temperatureStop, 100),
        snapshot.temperature, temperatureStop, " K")
    updateAlertStage(stages, "damage",
        risingStage(snapshot.damage, damageStopPercent, 1, true),
        snapshot.damage, damageStopPercent, "%")
    updateAlertStage(stages, "waste",
        risingStage(snapshot.waste and snapshot.waste * 100, wasteStopPercent, 10),
        snapshot.waste and snapshot.waste * 100, wasteStopPercent, "%")

    local sensorFault = not snapshot.statusValid
        or snapshot.temperature == nil or snapshot.damage == nil or snapshot.waste == nil
        or (safetyEnergyEnabled and snapshot.energy == nil)
        or (safetySteamEnabled and snapshot.heatedCoolant == nil)
        or (safetyWaterEnabled and snapshot.coolant == nil)
        or (safetyFuelEnabled and snapshot.fuel == nil)
    updateAlertStage(stages, "sensors", sensorFault and 2 or 0, nil, nil, "")
end

local function getSafetyStopReason(snapshot)
    -- Missing critical telemetry is unsafe: never assume a failed sensor is zero.
    if not snapshot.statusValid then return "reactor status unavailable" end
    if snapshot.temperature == nil then return "temperature sensor unavailable" end
    if snapshot.damage == nil then return "damage sensor unavailable" end
    if snapshot.waste == nil then return "waste sensor unavailable" end
    if safetyEnergyEnabled and snapshot.energy == nil then return "battery sensor unavailable" end
    if safetySteamEnabled and snapshot.heatedCoolant == nil then return "heated coolant sensor unavailable" end
    if safetyWaterEnabled and snapshot.coolant == nil then return "coolant sensor unavailable" end
    if safetyFuelEnabled and snapshot.fuel == nil then return "fuel sensor unavailable" end

    -- These limits are mandatory and cannot be disabled from the website.
    if snapshot.temperature >= temperatureStop then return "high temperature" end
    if snapshot.damage > damageStopPercent then return "reactor damage" end
    if snapshot.waste * 100 >= wasteStopPercent then return "waste threshold" end

    if safetyEnergyEnabled and snapshot.energy >= stopPercent / 100 then
        return "battery threshold"
    end
    if safetySteamEnabled and snapshot.heatedCoolant >= steamStopPercent / 100 then
        return "heated coolant threshold"
    end
    if safetyWaterEnabled and snapshot.coolant <= waterStopPercent / 100 then
        return "coolant threshold"
    end
    if safetyFuelEnabled and snapshot.fuel <= fuelStopPercent / 100 then
        return "fuel threshold"
    end
end

local function emergencyScram(unit, reason)
    unit.stoppedForSafety = true
    unit.safetyStopReason = reason
    -- Only the normal battery cycle may restart automatically. Every reactor
    -- fault stays latched until a player explicitly starts it again.
    unit.manualHold = reason ~= "battery threshold"

    local device = unit.device
    local commandOk, commandError = false, "reactor peripheral missing"
    local statusOk, stillRunning = false, nil
    if device and device.scram then commandOk, commandError = pcall(device.scram) end
    if device and device.getStatus then statusOk, stillRunning = pcall(device.getStatus) end
    unit.running = not statusOk or stillRunning == true
    syncPrimary()
    if commandOk and statusOk and not unit.running then
        message = "SAFETY SCRAM: " .. reason
        unit.alertStages.scram = 0
    else
        message = "SCRAM UNCONFIRMED: " .. reason
            .. (commandOk and "" or " / " .. tostring(commandError))
        if (unit.alertStages.scram or 0) < 2
            and sendSafetyAlert("scram", "failed", nil, nil, "") then
            unit.alertStages.scram = 2
        end
    end
    saveThresholds()
    return not unit.running
end

local function activateAndConfirm(unit)
    local device = unit.device
    if not device or not device.activate then
        message = "START FAILED: reactor peripheral missing (" .. tostring(unit.name) .. ")"
        return false
    end
    local commandOk, commandError = pcall(device.activate)
    local statusOk, actualRunning = pcall(device.getStatus)
    if not commandOk or not statusOk or actualRunning ~= true then
        unit.running = statusOk and actualRunning == true
        syncPrimary()
        message = "START FAILED: " .. tostring(commandError or "status unconfirmed")
        return false
    end
    unit.running = true
    unit.stoppedForSafety = false
    unit.safetyStopReason = nil
    unit.manualHold = false
    syncPrimary()
    saveThresholds()
    return true
end

local function updateUnit(unit)
    local snapshot = readSafetySnapshotFor(unit.device)
    if snapshot.energy ~= nil then energy = snapshot.energy end
    updateSafetyAlerts(snapshot, unit.alertStages)
    local actualRunning = snapshot.running

    -- A state change made directly in-game is a manual command. Remember a
    -- manual stop so the low-energy automation cannot immediately undo it.
    if snapshot.statusValid and actualRunning ~= unit.running and not unit.stoppedForSafety then
        unit.manualHold = not actualRunning
        saveThresholds()
    end
    if snapshot.statusValid then unit.running = actualRunning end

    local stopReason = getSafetyStopReason(snapshot)
    if stopReason then
        if unit.running or not snapshot.statusValid then
            emergencyScram(unit, stopReason)
        elseif stopReason ~= "battery threshold" then
            unit.stoppedForSafety = true
            unit.safetyStopReason = stopReason
            unit.manualHold = true
            saveThresholds()
        end
        return
    end

    -- Starting it directly in the reactor GUI is an explicit acknowledgement,
    -- but only after every mandatory sensor is back in a safe state.
    if unit.running and unit.stoppedForSafety then
        unit.stoppedForSafety = false
        unit.safetyStopReason = nil
        unit.manualHold = false
        message = "Manual in-game restart acknowledged"
        saveThresholds()
    end

    if unit.running or unit.manualHold then return end
    local batteryMayStart = snapshot.energy ~= nil and snapshot.energy <= startPercent / 100
    if unit.stoppedForSafety then
        if unit.safetyStopReason == "battery threshold" and batteryMayStart then
            if activateAndConfirm(unit) then message = "Started: battery below start threshold" end
        end
    elseif safetyEnergyEnabled and batteryMayStart then
        if activateAndConfirm(unit) then message = "Started: battery below start threshold" end
    end
end

local function updateController()
    for _, unit in ipairs(units) do
        updateUnit(unit)
    end
    syncPrimary()
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

local function readUnitEntry(unit)
    local device = unit.device
    local function rm(methodName)
        if not device then return nil end
        local method = device[methodName]
        if type(method) ~= "function" then return nil end
        local ok, value = pcall(method)
        if not ok then return nil end
        return tonumber(value)
    end
    local statusOk, liveRunning = false, nil
    if device and device.getStatus then statusOk, liveRunning = pcall(device.getStatus) end
    local statusValid = statusOk and type(liveRunning) == "boolean"
    -- Never publish the cached controller state as live telemetry. The reactor
    -- may have been stopped in its GUI between controller ticks.
    if statusValid then
        unit.running = liveRunning
        syncPrimary()
    end
    local burnRate = rm("getBurnRate")
    local actualBurnRate = rm("getActualBurnRate")
    local maxBurnRate = rm("getMaxBurnRate")
    return {
        peripheral = unit.name,
        running = statusValid and liveRunning == true,
        statusValid = statusValid,
        temperature = rm("getTemperature") or 0,
        damage = rm("getDamagePercent") or 0,
        coolantPercent = (rm("getCoolantFilledPercentage") or 0) * 100,
        fuelPercent = (rm("getFuelFilledPercentage") or 0) * 100,
        wastePercent = (rm("getWasteFilledPercentage") or 0) * 100,
        heatedCoolantPercent = (rm("getHeatedCoolantFilledPercentage") or 0) * 100,
        burnRate = burnRate or 0,
        actualBurnRate = actualBurnRate or 0,
        maxBurnRate = maxBurnRate or 0,
        coolant = safeAmount(device and device.getCoolant),
        coolantCapacity = rm("getCoolantCapacity") or 0,
        waste = safeAmount(device and device.getWaste),
        wasteCapacity = rm("getWasteCapacity") or 0,
        fuel = safeAmount(device and device.getFuel),
        fuelCapacity = rm("getFuelCapacity") or 0,
        heatedCoolant = safeAmount(device and device.getHeatedCoolant),
        heatedCoolantCapacity = rm("getHeatedCoolantCapacity") or 0,
        heatingRate = rm("getHeatingRate") or 0,
        startPercent = startPercent,
        stopPercent = stopPercent,
        safetyStopped = unit.stoppedForSafety == true,
        safetyReason = unit.safetyStopReason,
        manualHold = unit.manualHold == true,
    }
end

local function sendReactorStatus()
    refreshPeripherals()
    local function m(methodName) return matrix and matrix[methodName] end
    local primaryDevice = units[1] and units[1].device or nil
    local function r(methodName) return primaryDevice and primaryDevice[methodName] end
    local storedEnergy = safeNumber(m("getEnergy")) / JOULES_PER_FE
    local capacity = safeNumber(m("getMaxEnergy")) / JOULES_PER_FE
    local input = safeNumber(m("getLastInput")) / JOULES_PER_FE
    local output = safeNumber(m("getLastOutput")) / JOULES_PER_FE
    local statusOk, liveRunning = false, nil
    if primaryDevice and primaryDevice.getStatus then
        statusOk, liveRunning = pcall(primaryDevice.getStatus)
    end
    local statusValid = statusOk and type(liveRunning) == "boolean"
    local burnRate = checkedNumber(r("getBurnRate"))
    local actualBurnRate = checkedNumber(r("getActualBurnRate"))
    local maxBurnRate = checkedNumber(r("getMaxBurnRate"))

    -- Never publish the cached controller state as live telemetry. The reactor
    -- may have been stopped in its GUI between controller ticks.
    if statusValid then
        if units[1] then units[1].running = liveRunning end
        syncPrimary()
    end

    local matrixData = {
            name = MATRIX_NAME,
            energyPercent = energy * 100,
            storedEnergy = storedEnergy,
            capacity = capacity,
            input = input,
            output = output,
            net = input - output,
            energyNeeded = safeNumber(m("getEnergyNeeded")) / JOULES_PER_FE,
            energyUnit = "FE",
            joulesPerFE = JOULES_PER_FE,
            peripheral = MATRIX_NAME,
        }

    local reactorData = {
            name = units[1] and units[1].name or REACTOR_NAME,
            running = statusValid and liveRunning == true,
            statusValid = statusValid,
            startPercent = startPercent,
            stopPercent = stopPercent,
            temperature = safeNumber(r("getTemperature")),
            damage = safeNumber(r("getDamagePercent")),
            coolantPercent = safeNumber(r("getCoolantFilledPercentage")) * 100,
            coolant = safeAmount(r("getCoolant")),
            coolantCapacity = safeNumber(r("getCoolantCapacity")),
            wastePercent = safeNumber(r("getWasteFilledPercentage")) * 100,
            waste = safeAmount(r("getWaste")),
            wasteCapacity = safeNumber(r("getWasteCapacity")),
            burnRate = burnRate or 0,
            burnRateValid = burnRate ~= nil,
            actualBurnRate = actualBurnRate or 0,
            actualBurnRateValid = actualBurnRate ~= nil,
            maxBurnRate = maxBurnRate or 0,
            maxBurnRateValid = maxBurnRate ~= nil and maxBurnRate > 0,
            fuelPercent = safeNumber(r("getFuelFilledPercentage")) * 100,
            fuel = safeAmount(r("getFuel")),
            fuelCapacity = safeNumber(r("getFuelCapacity")),
            heatedCoolantPercent = safeNumber(r("getHeatedCoolantFilledPercentage")) * 100,
            heatedCoolant = safeAmount(r("getHeatedCoolant")),
            heatedCoolantCapacity = safeNumber(r("getHeatedCoolantCapacity")),
            heatingRate = safeNumber(r("getHeatingRate")),
            environmentalLoss = safeNumber(r("getEnvironmentalLoss")),
            boilEfficiency = safeNumber(r("getBoilEfficiency")) * 100,
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
                failSafe = true,
                temperatureStop = temperatureStop,
                wasteStopPercent = wasteStopPercent,
                damageStopPercent = damageStopPercent,
                stopped = stoppedForSafety,
                reason = safetyStopReason,
                manualHold = manualHold,
            },
            remoteComputerOnline = isRemoteOnline(),
            remoteMEConnected = remoteMEConnected,
        }

    local reactorsData = {}
    for _, unit in ipairs(units) do
        reactorsData[#reactorsData + 1] = readUnitEntry(unit)
    end
    syncPrimary()

    server:send({ type = "matrix_status", data = matrixData })
    server:send({ type = "reactor_status", data = reactorData })
    server:send({ type = "reactors_status", reactors = reactorsData })

    if wirelessModemName then
        rednet.broadcast({
            version = 1,
            computerId = os.getComputerID(),
            matrix = matrixData,
            reactor = reactorData,
            reactors = reactorsData,
        }, OVERVIEW_REACTOR_PROTOCOL)
    end
end

local function consoleStatus()
    local lines = {
        "Service: reactor controller",
        "Matrix: " .. MATRIX_NAME,
        ("Energy: %.2f%%"):format(energy * 100),
        ("Reactors: %d"):format(#units),
    }
    for i, unit in ipairs(units) do
        local marker = (i == selectedUnit) and "*" or " "
        lines[#lines + 1] = ( "%s%d. %s: %s%s"):format(
            marker, i, unit.name,
            unit.running and "ONLINE" or "SCRAMMED",
            unit.stoppedForSafety and (" (HELD: " .. tostring(unit.safetyStopReason or "safety") .. ")") or "")
    end
    lines[#lines + 1] = "Manual hold: " .. (manualHold and "ON" or "OFF")
    lines[#lines + 1] = ("Thresholds: %d%% / %d%%"):format(startPercent, stopPercent)
    lines[#lines + 1] = "ME node: " .. (isRemoteOnline() and "ONLINE" or "OFFLINE")
    lines[#lines + 1] = "Web: " .. (server:isConnected() and "CONNECTED" or "OFFLINE")
    return table.concat(lines, "\n")
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

-- Website commands may carry an optional string field `peripheral` with the
-- unit name. set_safety / set_thresholds are global. Unit commands without a
-- matching unit are ignored silently (no response).
local function findUnitByName(name)
    if type(name) ~= "string" or name == "" then return nil end
    for _, unit in ipairs(units) do
        if unit.name == name then return unit end
    end
    return nil
end

local function targetUnit(command)
    if type(command.peripheral) == "string" and command.peripheral ~= "" then
        return findUnitByName(command.peripheral)
    end
    return units[1]
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
        local newTemperature = tonumber(command.temperatureStop)
        local newDamage = tonumber(command.damageStopPercent)
        local newWaste = tonumber(command.wasteStopPercent)
        if not newEnergyStart or not newEnergyStop
            or newEnergyStart < 0 or newEnergyStop > 100
            or newEnergyStart >= newEnergyStop
            or not newSteam or not newWater or not newFuel
            or newSteam < 1 or newSteam > 100
            or newWater < 0 or newWater > 99
            or newFuel < 0 or newFuel > 99
            or not newTemperature or newTemperature < 600
            or newTemperature > MAX_ALLOWED_TEMPERATURE
            or not newDamage or newDamage < 0
            or newDamage > MAX_ALLOWED_DAMAGE_PERCENT
            or not newWaste or newWaste < 50
            or newWaste > MAX_ALLOWED_WASTE_PERCENT then
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
        temperatureStop = math.floor(newTemperature)
        damageStopPercent = math.floor(newDamage)
        wasteStopPercent = math.floor(newWaste)
        saveThresholds()
        updateController()
        sendCommandResult(command, true, "Safety settings saved")
        return
    end

    if command.action == "reactor_scram" then
        local unit = targetUnit(command)
        if not unit then return end
        local device = unit.device
        if not device or not device.scram then
            unit.manualHold = true
            saveThresholds()
            syncPrimary()
            sendCommandResult(command, false, "Reactor peripheral missing")
            return
        end
        local ok, commandError = pcall(device.scram)
        local statusOk, stillRunning = pcall(device.getStatus)
        if ok and statusOk and stillRunning == false then
            unit.running = false
            unit.stoppedForSafety = false
            unit.safetyStopReason = nil
            unit.manualHold = true
            syncPrimary()
            saveThresholds()
            message = "SCRAM from web"
            sendCommandResult(command, true, "Reactor stopped")
        else
            unit.running = not statusOk or stillRunning == true
            unit.manualHold = true
            syncPrimary()
            saveThresholds()
            message = "WEB SCRAM UNCONFIRMED"
            sendCommandResult(command, false,
                tostring(commandError or "Reactor still reports active"))
        end
        return
    end

    if command.action == "reactor_start" then
        local unit = targetUnit(command)
        if not unit then return end
        local snapshot = readSafetySnapshotFor(unit.device)
        local stopReason = getSafetyStopReason(snapshot)
        local forceDisabled = false
        if unit.device and unit.device.isForceDisabled then
            local forceCheckOk, forceCheckValue = pcall(unit.device.isForceDisabled)
            forceDisabled = not forceCheckOk or forceCheckValue == true
        end

        if forceDisabled or stopReason then
            sendCommandResult(command, false,
                "Safety check blocked reactor start: " .. tostring(
                    forceDisabled and "force-disabled" or stopReason))
            return
        end

        if activateAndConfirm(unit) then
            message = "Started from web"
            sendCommandResult(command, true, "Reactor started")
        else
            sendCommandResult(command, false, message)
        end
        return
    end

    if command.action == "set_burn_rate" then
        local unit = targetUnit(command)
        if not unit then return end
        local device = unit.device
        if not device or not device.getMaxBurnRate then
            sendCommandResult(command, false, "Reactor burn-rate telemetry is unavailable")
            return
        end
        local burnRate = tonumber(command.burnRate)
        local maxBurnRate = checkedNumber(device.getMaxBurnRate)
        if not maxBurnRate or maxBurnRate <= 0 then
            sendCommandResult(command, false, "Reactor burn-rate telemetry is unavailable")
            return
        end
        if not burnRate or burnRate < 0.1 or burnRate > maxBurnRate then
            sendCommandResult(command, false, "Burn rate must be between 0.1 and " .. tostring(maxBurnRate))
            return
        end

        local ok, commandError = pcall(device.setBurnRate, burnRate)
        local confirmedRate = checkedNumber(device.getBurnRate)
        if ok and confirmedRate and math.abs(confirmedRate - burnRate) < 0.051 then
            message = ("Burn rate set to %.2f mB/t"):format(confirmedRate)
            sendCommandResult(command, true, message)
        else
            sendCommandResult(command, false,
                tostring(commandError or "Reactor did not confirm the burn rate"))
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

    if isInside(buttons.unitPrev, x, y) then
        if #units > 0 then
            selectedUnit = selectedUnit - 1
            if selectedUnit < 1 then selectedUnit = #units end
        end
        drawScreen()
        return
    elseif isInside(buttons.unitNext, x, y) then
        if #units > 0 then
            selectedUnit = selectedUnit + 1
            if selectedUnit > #units then selectedUnit = 1 end
        end
        drawScreen()
        return
    end

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

refreshPeripherals()
saveThresholds()
updateController()
server:connect()
drawScreen()

local function sendPeripheralsStatus()
    server:send({
        type = "peripherals_status",
        computerRole = "reactor",
        peripherals = Peripherals.all(),
        resolved = { matrix = MATRIX_NAME, reactor = REACTOR_NAME, monitor = monitorName },
    })
end

local safetyTimer = os.startTimer(SAFETY_INTERVAL)
local telemetryTimer = os.startTimer(TELEMETRY_INTERVAL)

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
        elseif serverMessage.type == "peripherals_update" then
            local applied = Peripherals.applyRemote(serverMessage.peripherals)
            refreshPeripherals()
            message = "Peripherals updated from web: " .. tostring(applied)
            updateController()
            sendReactorStatus()
            sendPeripheralsStatus()
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

    if event == "timer" and arg1 == safetyTimer then
        updateController()
        safetyTimer = os.startTimer(SAFETY_INTERVAL)
    elseif event == "timer" and arg1 == telemetryTimer then
        server:connect()
        updateController()
        sendReactorStatus()
        drawScreen()
        telemetryTimer = os.startTimer(TELEMETRY_INTERVAL)
    elseif event == "monitor_touch" and arg1 == monitorName then
        handleTouch(arg2, arg3)
    elseif event == "monitor_resize" and arg1 == monitorName then
        drawScreen()
    elseif event == Peripherals.RELOAD_EVENT
        or event == "peripheral" or event == "peripheral_detach" then
        refreshPeripherals()
        sendPeripheralsStatus()
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
