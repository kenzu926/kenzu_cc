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

local function probeExtra(device, candidates, limit)
    local extra = {}
    local count = 0
    for _, methodName in ipairs(candidates) do
        if count >= (limit or 12) then break end
        local method = device and device[methodName]
        if type(method) == "function" then
            local ok, value = pcall(method)
            if ok then
                if type(value) == "table" then value = value.amount or value[1] end
                if type(value) == "number" or type(value) == "boolean" then
                    extra[methodName] = value
                    count = count + 1
                elseif tonumber(value) ~= nil then
                    extra[methodName] = tonumber(value)
                    count = count + 1
                end
            end
        end
    end
    return extra
end

local BOILER_EXTRA = {
    "getHeatedCoolantFilledPercentage", "getCoolantFilledPercentage",
    "getBoilRate", "getMaxBoilRate", "getTemperature",
    "getEnvironmentalLoss", "getWater", "getWaterCapacity",
    "getSteam", "getSteamCapacity",
}

local FUSION_EXTRA = {
    "getMinInjectionRate", "getMaxInjectionRate",
    "getDeuteriumFilledPercentage", "getTritiumFilledPercentage",
    "getDTFuelFilledPercentage", "getWaterFilledPercentage",
    "getSteamFilledPercentage",
}

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
    return {
        peripheral = entry.name,
        waterPercent = safeNumber(device, "getWaterFilledPercentage") * 100,
        steamPercent = safeNumber(device, "getSteamFilledPercentage") * 100,
        extra = probeExtra(device, BOILER_EXTRA, 12),
    }
end

local function readFusion(entry)
    local device = entry.device
    return {
        peripheral = entry.name,
        plasmaTemp = safeNumber(device, "getPlasmaTemperature"),
        caseTemp = safeNumber(device, "getCaseTemperature"),
        injectionRate = safeNumber(device, "getInjectionRate"),
        extra = probeExtra(device, FUSION_EXTRA, 12),
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
        lines[#lines + 1] = ("  fusion %s: plasma %.0f K case %.0f K inj %s"):format(
            reactor.peripheral, reactor.plasmaTemp, reactor.caseTemp,
            tostring(reactor.injectionRate))
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
