-- Local Rednet telemetry relay for monitor_1 on another computer.
-- This service has no web connection and keeps working independently.
local scriptDirectory = fs.getDir(shell.getRunningProgram())
local Peripherals = dofile(fs.combine(scriptDirectory, "peripherals.lua"))
local SNAPSHOT_PROTOCOL = "kenzu_cc.overview.snapshot"
local INTERVAL = 2
local JOULES_PER_FE = 2.5

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

-- No modem is fine: rednet relay is skipped, local scans still run.
-- (The website gets the same data over the gateway anyway.)
local modemName = openWirelessModem()
if modemName == nil then
    print("Overview telemetry relay: no wireless modem, rednet disabled")
end

local function raw(device, method)
    if not device or not device[method] then return nil end
    local ok, value = pcall(device[method])
    return ok and value or nil
end

local function number(device, method, fallback)
    local value = raw(device, method)
    if type(value) == "table" then value = value.amount or value[1] end
    return tonumber(value) or fallback or 0
end

local function boolean(device, method)
    return raw(device, method) == true
end

local function isTurbine(name, device)
    return Peripherals.isTurbine(name, device)
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

local function probeExtra(device, candidates, limit)
    local extra = {}
    local count = 0
    for _, methodName in ipairs(candidates) do
        if count >= (limit or 12) then break end
        local value = raw(device, methodName)
        if type(value) == "table" then value = value.amount or value[1] end
        if type(value) == "number" or type(value) == "boolean" then
            extra[methodName] = value
            count = count + 1
        elseif tonumber(value) ~= nil then
            extra[methodName] = tonumber(value)
            count = count + 1
        end
    end
    return extra
end

local function readSnapshot()
    local turbines = {}

    for _, name in ipairs(peripheral.getNames()) do
        local device = peripheral.wrap(name)
        if isTurbine(name, device) then
            turbines[#turbines + 1] = {
                peripheral = name,
                production = number(device, "getProductionRate") / JOULES_PER_FE,
                flowRate = number(device, "getFlowRate"),
                maxFlowRate = number(device, "getMaxFlowRate"),
                steamPercent = number(device, "getSteamFilledPercentage") * 100,
            }
        end
    end

    -- All induction matrices (primary first for legacy `matrix` field).
    local matrices = {}
    for _, entry in ipairs(Peripherals.findMatrices()) do
        matrices[#matrices + 1] = {
            peripheral = entry.name,
            kind = "induction",
            energyPercent = number(entry.device, "getEnergyFilledPercentage") * 100,
            storedEnergy = number(entry.device, "getEnergy") / JOULES_PER_FE,
            capacity = number(entry.device, "getMaxEnergy") / JOULES_PER_FE,
            input = number(entry.device, "getLastInput") / JOULES_PER_FE,
            output = number(entry.device, "getLastOutput") / JOULES_PER_FE,
        }
    end

    -- All fission reactors (primary first for legacy `reactor` field).
    local reactors = {}
    for _, entry in ipairs(Peripherals.findReactors()) do
        local statusOk, running = pcall(entry.device.getStatus)
        reactors[#reactors + 1] = {
            peripheral = entry.name,
            running = statusOk and running == true,
            statusValid = statusOk and type(running) == "boolean",
            temperature = number(entry.device, "getTemperature"),
            actualBurnRate = number(entry.device, "getActualBurnRate"),
            coolantPercent = number(entry.device, "getCoolantFilledPercentage") * 100,
            fuelPercent = number(entry.device, "getFuelFilledPercentage") * 100,
            wastePercent = number(entry.device, "getWasteFilledPercentage") * 100,
            damage = number(entry.device, "getDamagePercent"),
        }
    end

    -- All energy storages: induction matrices plus draconic/other units.
    local energyUnits = {}
    for _, unit in ipairs(matrices) do
        energyUnits[#energyUnits + 1] = {
            peripheral = unit.peripheral,
            kind = "induction",
            stored = unit.storedEnergy,
            capacity = unit.capacity,
            input = unit.input,
            output = unit.output,
            energyPercent = unit.energyPercent,
        }
    end
    for _, entry in ipairs(Peripherals.findEnergyStorages()) do
        if entry.kind ~= "induction" then
            local stored = number(entry.device, "getEnergyStored")
            local capacity = number(entry.device, "getMaxEnergyStored")
            local energyPercent = 0
            if capacity > 0 then energyPercent = stored / capacity * 100 end
            local input = number(entry.device, "getTransferRate")
            if input == 0 then input = number(entry.device, "getLastInput") end
            energyUnits[#energyUnits + 1] = {
                peripheral = entry.name,
                kind = entry.kind,
                stored = stored,
                capacity = capacity,
                input = input,
                output = number(entry.device, "getLastOutput"),
                energyPercent = energyPercent,
            }
        end
    end

    local boilers = {}
    for _, entry in ipairs(Peripherals.findBoilers()) do
        boilers[#boilers + 1] = {
            peripheral = entry.name,
            waterPercent = number(entry.device, "getWaterFilledPercentage") * 100,
            steamPercent = number(entry.device, "getSteamFilledPercentage") * 100,
            extra = probeExtra(entry.device, BOILER_EXTRA, 12),
        }
    end

    local fusion = {}
    for _, entry in ipairs(Peripherals.findFusionReactors()) do
        fusion[#fusion + 1] = {
            peripheral = entry.name,
            plasmaTemp = number(entry.device, "getPlasmaTemperature"),
            caseTemp = number(entry.device, "getCaseTemperature"),
            injectionRate = number(entry.device, "getInjectionRate"),
            extra = probeExtra(entry.device, FUSION_EXTRA, 12),
        }
    end

    local matrixData
    if matrices[1] then
        matrixData = {
            energyPercent = matrices[1].energyPercent,
            storedEnergy = matrices[1].storedEnergy,
            capacity = matrices[1].capacity,
            input = matrices[1].input,
            output = matrices[1].output,
        }
    end

    local reactorData
    if reactors[1] then
        reactorData = {
            running = reactors[1].running,
            temperature = reactors[1].temperature,
            actualBurnRate = reactors[1].actualBurnRate,
            coolantPercent = reactors[1].coolantPercent,
            fuelPercent = reactors[1].fuelPercent,
            wastePercent = reactors[1].wastePercent,
            damage = reactors[1].damage,
        }
    end

    return {
        version = 1,
        computerId = os.getComputerID(),
        sentAt = os.epoch("utc"),
        matrix = matrixData,
        reactor = reactorData,
        turbines = turbines,
        reactors = reactors,
        matrices = matrices,
        energyUnits = energyUnits,
        boilers = boilers,
        fusion = fusion,
    }
end

local function sendSnapshot()
    local snapshot = readSnapshot()
    if modemName then
        pcall(rednet.broadcast, snapshot, SNAPSHOT_PROTOCOL)
    end
    term.clear()
    term.setCursorPos(1, 1)
    print("Overview telemetry relay")
    print("Modem: " .. tostring(modemName or "NOT FOUND (rednet off)"))
    print("Matrix: " .. (snapshot.matrix and "CONNECTED" or "OFFLINE"))
    print("Reactor: " .. (snapshot.reactor and ("CONNECTED x" .. #snapshot.reactors) or "OFFLINE"))
    print("Turbines: " .. #snapshot.turbines)
    print("Energy units: " .. #snapshot.energyUnits)
    print("Boilers: " .. #snapshot.boilers)
    print("Fusion: " .. #snapshot.fusion)
end

sendSnapshot()
local timer = os.startTimer(INTERVAL)
while true do
    local event, arg1 = os.pullEvent()
    if event == "timer" and arg1 == timer then
        sendSnapshot()
        timer = os.startTimer(INTERVAL)
    elseif event == Peripherals.RELOAD_EVENT
        or event == "peripheral" or event == "peripheral_detach" then
        sendSnapshot()
    end
end
