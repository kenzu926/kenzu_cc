-- Machines telemetry service: induction matrices, other energy storages
-- (draconic / RF), Mekanism boilers and fusion reactors.
-- Sends energy_status + machines_status to the website and mirrors a compact
-- snapshot over rednet for overview monitors.
local CHECK_INTERVAL = 5
local JOULES_PER_FE = 2.5
local SNAPSHOT_PROTOCOL = "kenzu_cc.overview.snapshot"

local scriptDirectory = fs.getDir(shell.getRunningProgram())
local GatewayClient = dofile(fs.combine(scriptDirectory, "gateway_client.lua"))
local SafeConsole = dofile(fs.combine(scriptDirectory, "console.lua"))
local Peripherals = dofile(fs.combine(scriptDirectory, "peripherals.lua"))
local server = GatewayClient.new("machines")

local function openWirelessModem()
    local ok, names = pcall(peripheral.getNames)
    if not ok or type(names) ~= "table" then return nil end
    for _, name in ipairs(names) do
        local typeOk, isModem = pcall(peripheral.hasType, name, "modem")
        if typeOk and isModem then
            local wrapOk, modem = pcall(peripheral.wrap, name)
            if wrapOk and modem and modem.isWireless then
                local wirelessOk, wireless = pcall(modem.isWireless)
                if wirelessOk and wireless then
                    pcall(rednet.open, name)
                    return name
                end
            end
        end
    end
end

local wirelessModemName = openWirelessModem()

local function safeNumber(device, methodName, fallback)
    local method = device and device[methodName]
    if type(method) ~= "function" then return fallback or 0 end
    local ok, value = pcall(method)
    if not ok then return fallback or 0 end
    if type(value) == "table" then value = value.amount or value[1] end
    return tonumber(value) or fallback or 0
end

-- Generic getter probing: calls every no-arg get*/is*/has* method and keeps
-- numbers, booleans and short strings. Setters (set*) and actions (scram,
-- activate, ...) are never called, so probing is side-effect free.
-- Returns map methodName -> value plus normalized lookup.
local function probeGetters(device, peripheralName, limit)
    local probed, order, seen = {}, {}, {}
    if type(device) ~= "table" then return probed, order end
    local candidates = {}
    local methodsOk, methods = pcall(peripheral.getMethods, peripheralName)
    if methodsOk and type(methods) == "table" then
        for _, methodName in ipairs(methods) do
            candidates[#candidates + 1] = methodName
        end
    end
    -- Fallback: some modded peripherals fail getMethods by network name;
    -- their method table itself is still enumerable.
    local pairsOk, pairKeys = pcall(function()
        local keys = {}
        for key, value in pairs(device) do
            if type(key) == "string" and type(value) == "function" then
                keys[#keys + 1] = key
            end
        end
        return keys
    end)
    if pairsOk and type(pairKeys) == "table" then
        for _, methodName in ipairs(pairKeys) do
            candidates[#candidates + 1] = methodName
        end
    end
    for _, methodName in ipairs(candidates) do
        if #order >= (limit or 24) then break end
        if type(methodName) == "string" and not seen[methodName]
            and (methodName:sub(1, 3) == "get"
                or methodName:sub(1, 2) == "is"
                or methodName:sub(1, 3) == "has") then
            seen[methodName] = true
            local method = device[methodName]
            if type(method) == "function" then
                local ok, value = pcall(method)
                if ok then
                    if type(value) == "table" then value = value.amount or value[1] end
                    if type(value) == "number" and value == value then
                        probed[methodName] = value
                        order[#order + 1] = methodName
                    elseif type(value) == "boolean" then
                        probed[methodName] = value
                        order[#order + 1] = methodName
                    elseif type(value) == "string" and #value <= 48 then
                        probed[methodName] = value
                        order[#order + 1] = methodName
                    end
                end
            end
        end
    end
    return probed, order
end

local function normName(methodName)
    return tostring(methodName or ""):lower()
end

-- First probe entry whose normalized name contains one of the keywords.
local function pickNumber(probed, order, keywords)
    for _, keyword in ipairs(keywords) do
        for _, methodName in ipairs(order) do
            if normName(methodName):find(keyword, 1, true) then
                local value = tonumber(probed[methodName])
                if value ~= nil then return value, methodName end
            end
        end
    end
    return 0, nil
end

-- Mekanism filled percentages are 0..1 fractions; plain counters are not.
local function asPercent(value)
    value = tonumber(value) or 0
    if value > 0 and value <= 1 then return value * 100 end
    return value
end

-- Builds the extra map from an already probed table, skipping used keys.
local function probeExtraFiltered(probed, order, used, limit)
    local extra = {}
    local count = 0
    for _, methodName in ipairs(order) do
        if count >= (limit or 12) then break end
        if not used[methodName] then
            local value = probed[methodName]
            if type(value) == "number" or type(value) == "boolean" then
                extra[methodName] = value
                count = count + 1
            elseif type(value) == "string" and #value <= 48 then
                extra[methodName] = value
                count = count + 1
            end
        end
    end
    return extra
end

local function readEnergyUnit(entry)
    local device = entry.device
    if entry.kind == "induction" then
        local stored = safeNumber(device, "getEnergy") / JOULES_PER_FE
        local capacity = safeNumber(device, "getMaxEnergy") / JOULES_PER_FE
        return {
            peripheral = entry.name,
            kind = "induction",
            stored = stored,
            capacity = capacity,
            input = safeNumber(device, "getLastInput") / JOULES_PER_FE,
            output = safeNumber(device, "getLastOutput") / JOULES_PER_FE,
            energyPercent = safeNumber(device, "getEnergyFilledPercentage") * 100,
        }
    end
    local stored = safeNumber(device, "getEnergyStored")
    local capacity = safeNumber(device, "getMaxEnergyStored")
    local input = safeNumber(device, "getTransferRate")
    if input == 0 then input = safeNumber(device, "getLastInput") end
    local output = safeNumber(device, "getLastOutput")
    if stored == 0 and capacity == 0 then
        -- Unknown energy peripheral: pick by method-name substrings.
        local probed, order = probeGetters(device, entry.name, 24)
        if stored == 0 then
            stored = pickNumber(probed, order, { "energystored", "storedenergy", "stored" })
        end
        if capacity == 0 then
            capacity = pickNumber(probed, order,
                { "maxenergystored", "maxstored", "maxenergy", "capacity" })
        end
        if input == 0 then
            input = pickNumber(probed, order, { "transferrate", "transfer", "input" })
        end
        if output == 0 then
            output = pickNumber(probed, order, { "output" })
        end
    end
    local energyPercent = 0
    if capacity > 0 then energyPercent = stored / capacity * 100 end
    return {
        peripheral = entry.name,
        kind = entry.kind,
        stored = stored,
        capacity = capacity,
        input = input,
        output = output,
        energyPercent = energyPercent,
    }
end

local function readBoiler(entry)
    local device = entry.device
    local probed, order = probeGetters(device, entry.name, 24)
    local used = {}
    local waterPercent = 0
    if device and device.getWaterFilledPercentage then
        waterPercent = safeNumber(device, "getWaterFilledPercentage") * 100
        used.getWaterFilledPercentage = true
    else
        local value, key = pickNumber(probed, order, { "waterfilled", "water" })
        waterPercent = asPercent(value)
        if key then used[key] = true end
    end
    local steamPercent = 0
    if device and device.getSteamFilledPercentage then
        steamPercent = safeNumber(device, "getSteamFilledPercentage") * 100
        used.getSteamFilledPercentage = true
    else
        local value, key = pickNumber(probed, order, { "steamfilled", "steam" })
        steamPercent = asPercent(value)
        if key then used[key] = true end
    end
    return {
        peripheral = entry.name,
        waterPercent = waterPercent,
        steamPercent = steamPercent,
        extra = probeExtraFiltered(probed, order, used, 12),
    }
end

local function readFusion(entry)
    local device = entry.device
    local probed, order = probeGetters(device, entry.name, 24)
    local used = {}
    local plasmaTemp, plasmaKey = pickNumber(probed, order,
        { "plasmatemperature", "plasmatemp", "plasma" })
    if plasmaKey then used[plasmaKey] = true end
    if plasmaTemp == 0 and device and device.getPlasmaTemperature then
        plasmaTemp = safeNumber(device, "getPlasmaTemperature")
        used.getPlasmaTemperature = true
    end
    local caseTemp, caseKey = pickNumber(probed, order,
        { "casetemperature", "casetemp", "case" })
    if caseKey then used[caseKey] = true end
    if caseTemp == 0 and device and device.getCaseTemperature then
        caseTemp = safeNumber(device, "getCaseTemperature")
        used.getCaseTemperature = true
    end
    local injectionRate, injKey = pickNumber(probed, order,
        { "injectionrate", "inject" })
    if injKey then used[injKey] = true end
    if injectionRate == 0 and device and device.getInjectionRate then
        injectionRate = safeNumber(device, "getInjectionRate")
        used.getInjectionRate = true
    end
    return {
        peripheral = entry.name,
        plasmaTemp = plasmaTemp,
        caseTemp = caseTemp,
        injectionRate = injectionRate,
        extra = probeExtraFiltered(probed, order, used, 12),
    }
end

local function readStatuses()
    local energyUnits = {}
    for _, entry in ipairs(Peripherals.findEnergyStorages()) do
        energyUnits[#energyUnits + 1] = readEnergyUnit(entry)
    end
    local boilers = {}
    for _, entry in ipairs(Peripherals.findBoilers()) do
        boilers[#boilers + 1] = readBoiler(entry)
    end
    local fusion = {}
    for _, entry in ipairs(Peripherals.findFusionReactors()) do
        fusion[#fusion + 1] = readFusion(entry)
    end
    return energyUnits, boilers, fusion
end

local function statusText(energyUnits, boilers, fusion)
    if not energyUnits then
        energyUnits, boilers, fusion = readStatuses()
    end
    local lines = {
        "Service: machines telemetry",
        ("Energy units: %d"):format(#energyUnits),
        ("Boilers: %d"):format(#boilers),
        ("Fusion reactors: %d"):format(#fusion),
    }
    for _, unit in ipairs(energyUnits) do
        lines[#lines + 1] = ("  [%s] %s: %.1f%%"):format(
            unit.kind, unit.peripheral, unit.energyPercent)
    end
    for _, boiler in ipairs(boilers) do
        lines[#lines + 1] = ("  boiler %s: water %.1f%% steam %.1f%%"):format(
            boiler.peripheral, boiler.waterPercent, boiler.steamPercent)
    end
    for _, reactor in ipairs(fusion) do
        local extraCount = 0
        if type(reactor.extra) == "table" then
            for _ in pairs(reactor.extra) do extraCount = extraCount + 1 end
        end
        lines[#lines + 1] = ("  fusion %s: plasma %.0f K case %.0f K inj %s (+%d)"):format(
            reactor.peripheral, reactor.plasmaTemp, reactor.caseTemp,
            tostring(reactor.injectionRate), extraCount)
    end
    lines[#lines + 1] = "Gateway: " .. (server:isConnected() and "CONNECTED" or "OFFLINE")
    return table.concat(lines, "\n")
end

local function sendStatus()
    local energyUnits, boilers, fusion = readStatuses()
    server:send({ type = "energy_status", units = energyUnits })
    server:send({ type = "machines_status", boilers = boilers, fusion = fusion })
    if wirelessModemName then
        pcall(rednet.broadcast, {
            version = 1,
            computerId = os.getComputerID(),
            sentAt = os.epoch("utc"),
            energyUnits = energyUnits,
            boilers = boilers,
            fusion = fusion,
        }, SNAPSHOT_PROTOCOL)
    end

    term.clear()
    term.setCursorPos(1, 1)
    print(statusText(energyUnits, boilers, fusion))
end

server:connect()
sendStatus()
local timer = os.startTimer(CHECK_INTERVAL)

while true do
    local event, arg1, arg2, arg3 = os.pullEvent()
    local serverEvent, message = server:handleEvent(event, arg1, arg2, arg3)

    if serverEvent == "message" and type(message) == "table" then
        if message.type == "peripherals_update" then
            Peripherals.applyRemote(message.peripherals)
            sendStatus()
        elseif message.type == "console_command"
            and (message.target == "machines"
                or message.target == tostring(os.getComputerID())) then
            local ok, output = SafeConsole.execute(message.command, statusText)
            server:send({
                type = "console_output",
                requestId = message.requestId,
                target = "machines",
                computerId = os.getComputerID(),
                ok = ok,
                output = output,
            })
        end
    end

    if event == "timer" and arg1 == timer then
        server:connect()
        sendStatus()
        timer = os.startTimer(CHECK_INTERVAL)
    elseif event == Peripherals.RELOAD_EVENT
        or event == "peripheral" or event == "peripheral_detach" then
        sendStatus()
    end
end
