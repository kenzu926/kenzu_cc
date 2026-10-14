-- Draconic Evolution reactor controller service.
-- Watches a draconic reactor via its `draconic_reactor` peripheral and two
-- flux gates (energy input gate + output gate), regulates the input gate to
-- hold the target field strength and SCRAMs/charges on danger.
-- Logic follows the proven drmon algorithm (acidjazz/Dragonbones-reap):
--   inputFlow = fieldDrainRate / (1 - targetStrength/100)
-- All DE calls are pcall-guarded, so missing/renamed methods degrade to
-- "unknown" instead of crashing. Touch UI lives on a 3x3 monitor.
local SETTINGS_FILE = "draconic.settings"
local SAFETY_INTERVAL = 1
local TELEMETRY_INTERVAL = 2

local scriptDirectory = fs.getDir(shell.getRunningProgram())
local WebSocketClient = dofile(fs.combine(scriptDirectory, "gateway_client.lua"))
local SafeConsole = dofile(fs.combine(scriptDirectory, "console.lua"))
local Screen = dofile(fs.combine(scriptDirectory, "screen.lua"))
local server = WebSocketClient.new("draconic")

settings.define("draconic.targetStrength", {
    description = "Hold field strength at this percent",
    default = 50,
    type = "number",
})
settings.define("draconic.maxTemperature", { default = 8000, type = "number" })
settings.define("draconic.safeTemperature", { default = 3000, type = "number" })
settings.define("draconic.lowFieldPercent", { default = 15, type = "number" })
settings.define("draconic.fuelMinPercent", { default = 10, type = "number" })
settings.define("draconic.activateOnCharged", { default = true, type = "boolean" })
settings.define("draconic.autoInput", { default = true, type = "boolean" })
settings.define("draconic.manualInput", { default = 222000, type = "number" })
settings.define("draconic.outputGate", {
    description = "Peripheral name of the OUTPUT flux gate (empty = auto)",
    default = "",
    type = "string",
})
settings.define("draconic.inputGate", {
    description = "Peripheral name of the INPUT flux gate (empty = auto)",
    default = "",
    type = "string",
})
settings.define("draconic.monitor", {
    description = "Monitor for the 3x3 touch UI",
    default = "monitor_0",
    type = "string",
})
settings.load(SETTINGS_FILE)

local targetStrength = math.max(10, math.min(95, tonumber(settings.get("draconic.targetStrength")) or 50))
local maxTemperature = math.max(1000, tonumber(settings.get("draconic.maxTemperature")) or 8000)
local safeTemperature = math.max(500, tonumber(settings.get("draconic.safeTemperature")) or 3000)
local lowFieldPercent = math.max(1, math.min(90, tonumber(settings.get("draconic.lowFieldPercent")) or 15))
local fuelMinPercent = math.max(1, math.min(50, tonumber(settings.get("draconic.fuelMinPercent")) or 10))
local activateOnCharged = settings.get("draconic.activateOnCharged") ~= false
local autoInput = settings.get("draconic.autoInput") ~= false
local manualInput = math.max(0, tonumber(settings.get("draconic.manualInput")) or 222000)
local outputGateName = tostring(settings.get("draconic.outputGate") or "")
local inputGateName = tostring(settings.get("draconic.inputGate") or "")
local MONITOR_NAME = tostring(settings.get("draconic.monitor") or "monitor_0")
if MONITOR_NAME == "" then MONITOR_NAME = "monitor_0" end

local function saveSettings()
    settings.set("draconic.targetStrength", targetStrength)
    settings.set("draconic.maxTemperature", maxTemperature)
    settings.set("draconic.safeTemperature", safeTemperature)
    settings.set("draconic.lowFieldPercent", lowFieldPercent)
    settings.set("draconic.fuelMinPercent", fuelMinPercent)
    settings.set("draconic.activateOnCharged", activateOnCharged)
    settings.set("draconic.autoInput", autoInput)
    settings.set("draconic.manualInput", manualInput)
    settings.set("draconic.outputGate", outputGateName)
    settings.set("draconic.inputGate", inputGateName)
    settings.set("draconic.monitor", MONITOR_NAME)
    settings.save(SETTINGS_FILE)
end

-- --------------------------------------------------------------------------
-- Discovery (no asserts: everything degrades to "missing").
-- --------------------------------------------------------------------------

local function hasTypeSafe(name, peripheralType)
    if not peripheral.hasType then return false end
    local ok, result = pcall(peripheral.hasType, name, peripheralType)
    return ok and result == true
end

local function findReactor()
    local direct = peripheral.find("draconic_reactor")
    if direct then
        for _, name in ipairs(peripheral.getNames()) do
            if peripheral.wrap(name) == direct then return direct, name end
        end
        return direct, "draconic_reactor"
    end
    for _, name in ipairs(peripheral.getNames()) do
        if name:lower():find("draconic", 1, true)
            and not name:lower():find("storage", 1, true)
            and not name:lower():find("core", 1, true) then
            local device = peripheral.wrap(name)
            if device and device.getReactorInfo then
                return device, name
            end
        end
    end
    return nil, nil
end

local function findGates()
    local result = {}
    local seen = {}
    local function add(name)
        if type(name) == "string" and name ~= "" and not seen[name]
            and peripheral.isPresent(name) then
            local device = peripheral.wrap(name)
            if device and (device.getSignalLowFlow or device.getFlow) then
                seen[name] = true
                result[#result + 1] = { name = name, device = device }
            end
        end
    end
    add(outputGateName)
    add(inputGateName)
    for _, name in ipairs(peripheral.getNames()) do
        if hasTypeSafe(name, "flow_gate") or hasTypeSafe(name, "flux_gate")
            or name:lower():find("flow_gate", 1, true)
            or name:lower():find("flux_gate", 1, true) then
            add(name)
        end
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

local reactor, reactorName = findReactor()
local gates = findGates()

local function pickGate(configured, index)
    if configured ~= "" then
        for _, entry in ipairs(gates) do
            if entry.name == configured then return entry end
        end
    end
    return gates[index]
end

local function refreshPeripherals()
    local found, foundName = findReactor()
    if found then
        reactor, reactorName = found, foundName
    elseif reactorName and not peripheral.isPresent(reactorName) then
        reactor = nil
    end
    gates = findGates()
end

local function gateFlow(entry)
    if not entry or not entry.device then return nil end
    local device = entry.device
    if device.getSignalLowFlow then
        local ok, value = pcall(device.getSignalLowFlow)
        if ok then return tonumber(value) end
    end
    if device.getFlow then
        local ok, value = pcall(device.getFlow)
        if ok then return tonumber(value) end
    end
    return nil
end

local function setGateFlow(entry, value)
    if not entry or not entry.device then return false end
    value = math.max(0, math.floor(tonumber(value) or 0))
    local device = entry.device
    if device.setSignalLowFlow then
        local ok = pcall(device.setSignalLowFlow, value)
        return ok == true
    end
    if device.setFlow then
        local ok = pcall(device.setFlow, value)
        return ok == true
    end
    return false
end

-- --------------------------------------------------------------------------
-- State + safety loop.
-- --------------------------------------------------------------------------

local info = nil           -- last getReactorInfo() table
local infoOk = false
local action = "Waiting for reactor"
local emergencyCharge = false
local emergencyTemp = false
local message = "Controller started"
local outputGate = pickGate(outputGateName, 1)
local inputGate = pickGate(inputGateName, 2)
if outputGate and inputGate and outputGate.name == inputGate.name then
    inputGate = nil -- same gate twice: wait for explicit binding
end

local function fieldPercent()
    if not infoOk or not info then return nil end
    local field = tonumber(info.fieldStrength)
    local maxField = tonumber(info.maxFieldStrength)
    if field == nil or maxField == nil or maxField <= 0 then return nil end
    return field / maxField * 100
end

local function fuelPercent()
    if not infoOk or not info then return nil end
    local used = tonumber(info.fuelConversion)
    local maxFuel = tonumber(info.maxFuelConversion)
    if used == nil or maxFuel == nil or maxFuel <= 0 then return nil end
    return 100 - used / maxFuel * 100
end

local function satPercent()
    if not infoOk or not info then return nil end
    local sat = tonumber(info.energySaturation)
    local maxSat = tonumber(info.maxEnergySaturation)
    if sat == nil or maxSat == nil or maxSat <= 0 then return nil end
    return sat / maxSat * 100
end

local function updateController()
    if not reactor then
        info, infoOk = nil, false
        message = "Reactor peripheral missing"
        return
    end
    local ok, result = pcall(reactor.getReactorInfo)
    if not ok or type(result) ~= "table" then
        info, infoOk = nil, false
        message = "getReactorInfo failed: " .. tostring(result)
        return
    end
    info, infoOk = result, true
    local status = tostring(info.status or "unknown")
    local field = fieldPercent()
    local fuel = fuelPercent()
    local temperature = tonumber(info.temperature)

    -- Charging sequence: open the input gate wide.
    if status == "charging" then
        if inputGate then setGateFlow(inputGate, 900000) end
        emergencyCharge = false
        message = "Charging: input gate wide open"
    end

    -- Cooled down after an overheat stop: go back online.
    if emergencyTemp and status == "stopping"
        and temperature ~= nil and temperature < safeTemperature then
        if reactor.activateReactor then pcall(reactor.activateReactor) end
        emergencyTemp = false
        message = "Cooled down, reactivated"
    end

    -- Charged: go online when allowed.
    if status == "charged" and activateOnCharged then
        if reactor.activateReactor then pcall(reactor.activateReactor) end
        message = "Charged, activated"
    end

    -- Online: regulate the input gate, or hold the manual value.
    if status == "online" then
        if autoInput then
            local drain = tonumber(info.fieldDrainRate)
            if drain ~= nil and inputGate then
                local flow = drain / (1 - targetStrength / 100)
                setGateFlow(inputGate, flow)
            end
        elseif inputGate then
            setGateFlow(inputGate, manualInput)
        end
        if message:sub(1, 7) ~= "Started"
            and message:sub(1, 8) ~= "Holding " then
            message = ("Holding field ~%d%%"):format(targetStrength)
        end
    end

    -- Failsafes (checked every tick, latched via emergency flags/messages).
    if fuel ~= nil and fuel <= fuelMinPercent and status == "online" then
        if reactor.stopReactor then pcall(reactor.stopReactor) end
        action = "Fuel below " .. fuelMinPercent .. "%, refuel"
        message = action
        return
    end
    if field ~= nil and field <= lowFieldPercent and status == "online" then
        if reactor.stopReactor then pcall(reactor.stopReactor) end
        if reactor.chargeReactor then pcall(reactor.chargeReactor) end
        emergencyCharge = true
        action = "Field < " .. lowFieldPercent .. "%, emergency charge"
        message = action
        return
    end
    if temperature ~= nil and temperature > maxTemperature then
        if reactor.stopReactor then pcall(reactor.stopReactor) end
        emergencyTemp = true
        action = "Temp > " .. maxTemperature
        message = action
        return
    end
    if action:sub(1, 5) ~= "Field" and action:sub(1, 4) ~= "Temp"
        and action:sub(1, 4) ~= "Fuel" then
        action = "Nominal"
    end
end

-- --------------------------------------------------------------------------
-- Telemetry.
-- --------------------------------------------------------------------------

local function sendStatus()
    local data = {
        peripheral = reactorName,
        connected = infoOk,
        status = infoOk and tostring(info.status or "unknown") or "offline",
        temperature = infoOk and tonumber(info.temperature) or nil,
        fieldPercent = fieldPercent(),
        satPercent = satPercent(),
        fuelPercent = fuelPercent(),
        generationRate = infoOk and tonumber(info.generationRate) or nil,
        fieldDrainRate = infoOk and tonumber(info.fieldDrainRate) or nil,
        targetStrength = targetStrength,
        autoInput = autoInput,
        outputGate = outputGate and outputGate.name or nil,
        outputFlow = gateFlow(outputGate),
        inputGate = inputGate and inputGate.name or nil,
        inputFlow = gateFlow(inputGate),
        action = action,
        message = message,
    }
    server:send({ type = "draconic_status", data = data })
end

local function consoleStatus()
    local lines = {
        "Service: draconic reactor controller",
        "Reactor: " .. tostring(reactorName or "MISSING"),
        "Status: " .. (infoOk and tostring(info.status) or "OFFLINE"),
        ("Field: %s (target %d%%)"):format(
            fieldPercent() and ("%.1f%%"):format(fieldPercent()) or "?",
            targetStrength),
        "Action: " .. action,
        "Web: " .. (server:isConnected() and "CONNECTED" or "OFFLINE"),
    }
    return table.concat(lines, "\n")
end

-- --------------------------------------------------------------------------
-- 3x3 touch UI (STATUS / CONTROL tabs).
-- --------------------------------------------------------------------------

local tab = "status"
local buttons = {}
local monitor = Screen.attach(MONITOR_NAME)
if monitor then pcall(monitor.setTextScale, 0.5) end

local function text(x, y, value, color, background)
    if not monitor then return end
    local width, height = monitor.getSize()
    if y < 1 or y > height or x > width then return end
    monitor.setCursorPos(math.max(1, x), y)
    monitor.setTextColor(color or colors.white)
    monitor.setBackgroundColor(background or colors.black)
    monitor.write(tostring(value):sub(1, math.max(0, width - x + 1)))
end

local function fillRow(y, color)
    if not monitor then return end
    local width, height = monitor.getSize()
    if y < 1 or y > height then return end
    monitor.setCursorPos(1, y)
    monitor.setBackgroundColor(color)
    monitor.write(string.rep(" ", width))
end

local function centered(y, value, color, background)
    if not monitor then return end
    local width = monitor.getSize()
    value = tostring(value)
    text(math.max(1, math.floor((width - #value) / 2) + 1), y, value, color, background)
end

local function bar(y, percent, color)
    if not monitor then return end
    local width = monitor.getSize()
    percent = math.max(0, math.min(100, tonumber(percent) or 0))
    local inner = math.max(8, width - 2)
    fillRow(y, colors.gray)
    local amount = math.floor(inner * percent / 100 + 0.5)
    if amount > 0 then
        monitor.setCursorPos(2, y)
        monitor.setBackgroundColor(color or colors.lime)
        monitor.write(string.rep(" ", math.min(amount, inner)))
    end
    monitor.setBackgroundColor(colors.black)
end

local function button(x, y, width, label, actionFn, selected)
    if not monitor then return end
    monitor.setCursorPos(x, y)
    monitor.setTextColor(colors.white)
    monitor.setBackgroundColor(selected and colors.blue or colors.gray)
    monitor.write(string.rep(" ", width))
    local labelText = tostring(label):sub(1, width)
    monitor.setCursorPos(x + math.max(0, math.floor((width - #labelText) / 2)), y)
    monitor.write(labelText)
    monitor.setBackgroundColor(colors.black)
    buttons[#buttons + 1] = { x = x, y = y, width = width, action = actionFn }
end

local function fmtInt(value)
    value = tonumber(value) or 0
    local negative = value < 0
    value = math.floor(math.abs(value) + 0.5)
    local textValue = tostring(value)
    local grouped = ""
    while #textValue > 3 do
        grouped = " " .. textValue:sub(-3) .. grouped
        textValue = textValue:sub(1, -4)
    end
    return (negative and "-" or "") .. textValue .. grouped
end

local function statusColor()
    if not infoOk or not info then return colors.red end
    local status = tostring(info.status or "")
    if status == "online" or status == "charged" then return colors.lime end
    if status == "charging" then return colors.orange end
    return colors.gray
end

local function drawStatusTab(y1, y2, width)
    local y = y1
    centered(y, "STATUS: " .. (infoOk and tostring(info.status):upper() or "OFFLINE"),
        statusColor())
    y = y + 2
    text(2, y, "GEN " .. fmtInt(infoOk and info.generationRate or 0) .. " RF/t", colors.lime)
    y = y + 1
    local temperature = infoOk and tonumber(info.temperature) or 0
    local tempColor = colors.lime
    if temperature >= maxTemperature then tempColor = colors.red
    elseif temperature >= 5000 then tempColor = colors.orange end
    text(2, y, ("TEMP %s C"):format(fmtInt(temperature)), tempColor)
    y = y + 2
    local sat = satPercent() or 0
    text(2, y, ("SATURATION %.1f%%"):format(sat), colors.white)
    bar(y + 1, sat, colors.blue)
    y = y + 3
    local field = fieldPercent()
    text(2, y, ("FIELD %s (T %d%%)"):format(
        field and ("%.1f%%"):format(field) or "--", targetStrength),
        field and colors.white or colors.orange)
    bar(y + 1, field or 0,
        (field or 0) >= targetStrength and colors.lime or colors.orange)
    y = y + 3
    local fuel = fuelPercent()
    text(2, y, ("FUEL %s"):format(fuel and ("%.1f%%"):format(fuel) or "--"), colors.white)
    bar(y + 1, fuel or 0, (fuel or 100) >= 30 and colors.lime or colors.red)
    y = y + 3
    text(2, y, ("OUT %s RF/t"):format(fmtInt(gateFlow(outputGate) or 0)), colors.lightBlue)
    y = y + 1
    text(2, y, ("IN  %s RF/t %s"):format(fmtInt(gateFlow(inputGate) or 0),
        autoInput and "[AUTO]" or "[MAN]"), colors.lightBlue)
    y = y + 2
    if y <= y2 then text(2, y, tostring(action):sub(1, width - 4), colors.gray) end
end

local function adjustGate(entry, delta)
    if not entry then
        message = "Gate not bound (see GATES)"
        return
    end
    local current = gateFlow(entry) or 0
    if setGateFlow(entry, current + delta) then
        message = ("Gate %s -> %s"):format(entry.name, fmtInt(current + delta))
    else
        message = "Gate write failed"
    end
end

local function gateRow(y, label, entry, withAuto)
    text(2, y, ("%s: %s RF/t"):format(label, fmtInt(gateFlow(entry) or 0)), colors.white)
    local steps = { 1000, 10000, 100000 }
    local labels = { "-", "--", "---", "+", "++", "+++" }
    local handlers = {}
    for i, step in ipairs(steps) do
        handlers[i] = function() adjustGate(entry, -step) end
    end
    for i, step in ipairs(steps) do
        handlers[3 + i] = function() adjustGate(entry, step) end
    end
    local xs = { 2, 7, 12, 27, 32, 37 }
    for i = 1, 6 do
        button(xs[i], y + 1, 4, labels[i], handlers[i])
    end
    if withAuto then
        button(19, y + 1, 6, autoInput and "AUTO" or "MAN", function()
            autoInput = not autoInput
            if not autoInput and inputGate then
                manualInput = gateFlow(inputGate) or manualInput
            end
            saveSettings()
        end, autoInput)
    end
end

local function drawControlTab(y1, y2, width)
    local y = y1
    text(2, y, "OUTPUT GATE", colors.yellow)
    y = y + 1
    gateRow(y, "OUT", outputGate, false)
    y = y + 3
    if y + 3 <= y2 then
        text(2, y, "INPUT GATE", colors.yellow)
        y = y + 1
        gateRow(y, "IN", inputGate, true)
        y = y + 3
    end
    if y + 1 <= y2 then
        text(2, y, ("TARGET FIELD %d%%"):format(targetStrength), colors.white)
        button(math.max(2, width - 13), y, 4, "-5", function()
            targetStrength = math.max(10, targetStrength - 5)
            saveSettings()
        end)
        button(math.max(2, width - 8), y, 4, "+5", function()
            targetStrength = math.min(95, targetStrength + 5)
            saveSettings()
        end)
        y = y + 2
    end
    if y <= y2 and reactor then
        button(2, y, 10, "CHARGE", function()
            if reactor.chargeReactor then pcall(reactor.chargeReactor) end
            message = "Charge requested"
        end)
        button(14, y, 10, "STOP", function()
            if reactor.stopReactor then pcall(reactor.stopReactor) end
            message = "Stop requested"
        end)
        button(26, y, 10, "START", function()
            if reactor.activateReactor then pcall(reactor.activateReactor) end
            message = "Start requested"
        end)
    end
end

local function draw()
    buttons = {}
    if not monitor then
        monitor = Screen.attach(MONITOR_NAME)
        if monitor then pcall(monitor.setTextScale, 0.5) else return end
    end
    local width, height = monitor.getSize()
    if width < 44 or height < 20 then
        monitor.setBackgroundColor(colors.black)
        monitor.clear()
        monitor.setCursorPos(1, 1)
        monitor.setTextColor(colors.orange)
        monitor.write("Enlarge monitor (min 44x20)")
        return
    end
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
    fillRow(1, colors.gray)
    centered(1, "DRACONIC REACTOR", colors.purple, colors.gray)
    local tabWidth = 12
    local tabX = math.floor((width - tabWidth * 2 - 3) / 2) + 1
    button(tabX, 3, tabWidth, "STATUS", function() tab = "status" end, tab == "status")
    button(tabX + tabWidth + 3, 3, tabWidth, "CONTROL", function() tab = "control" end, tab == "control")
    text(2, 4, tostring(message):sub(1, width - 4), colors.lightGray)
    if tab == "status" then
        drawStatusTab(6, height - 1, width)
    else
        drawControlTab(6, height - 1, width)
    end
    fillRow(height, colors.gray)
    text(2, height,
        (server:isConnected() and "WEB LINK" or "LOCAL ONLY") .. " | " .. tostring(reactorName or "NO REACTOR"),
        server:isConnected() and colors.lime or colors.orange, colors.gray)
    Screen.commit(MONITOR_NAME)
end

local function handleTouch(x, y)
    for _, control in ipairs(buttons) do
        if y == control.y and x >= control.x and x < control.x + control.width then
            control.action()
            saveSettings()
            updateController()
            sendStatus()
            draw()
            return
        end
    end
end

local function swapGates()
    local gatesNow = findGates()
    if #gatesNow >= 2 then
        outputGate = gatesNow[1]
        inputGate = gatesNow[2]
        outputGateName, inputGateName = outputGate.name, inputGate.name
    else
        outputGate = pickGate(outputGateName, 1)
        inputGate = pickGate(inputGateName, 2)
    end
    if outputGate and inputGate and outputGate.name == inputGate.name then
        inputGate = nil
    end
    saveSettings()
end

updateController()
server:connect()
swapGates()
draw()
sendStatus()

local safetyTimer = os.startTimer(SAFETY_INTERVAL)
local telemetryTimer = os.startTimer(TELEMETRY_INTERVAL)

while true do
    local event, arg1, arg2, arg3 = os.pullEvent()
    local serverEvent, serverMessage = server:handleEvent(event, arg1, arg2, arg3)

    if serverEvent == "connected" then
        message = "Web server connected"
        sendStatus()
        draw()
    elseif serverEvent == "disconnected" then
        message = "Web server disconnected"
        draw()
    elseif serverEvent == "message" and type(serverMessage) == "table" then
        if serverMessage.type == "console_command"
            and (serverMessage.target == "draconic"
                or serverMessage.target == tostring(os.getComputerID())) then
            local ok, output = SafeConsole.execute(serverMessage.command, consoleStatus)
            server:send({
                type = "console_output",
                requestId = serverMessage.requestId,
                target = "draconic",
                computerId = os.getComputerID(),
                ok = ok,
                output = output,
            })
        elseif serverMessage.type == "peripherals_update" then
            draw()
        end
    end

    if event == "timer" and arg1 == safetyTimer then
        refreshPeripherals()
        updateController()
        draw()
        safetyTimer = os.startTimer(SAFETY_INTERVAL)
    elseif event == "timer" and arg1 == telemetryTimer then
        server:connect()
        updateController()
        sendStatus()
        draw()
        telemetryTimer = os.startTimer(TELEMETRY_INTERVAL)
    elseif event == "monitor_touch" then
        handleTouch(arg2, arg3)
    elseif event == "monitor_resize" then
        draw()
    elseif event == "peripheral" or event == "peripheral_detach" then
        refreshPeripherals()
        swapGates()
        draw()
    end
end
