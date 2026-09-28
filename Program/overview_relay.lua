-- Local Rednet telemetry relay for monitor_1 on another computer.
-- This service has no web connection and keeps working independently.
local MATRIX_NAME = "inductionPort_0"
local REACTOR_NAME = "fissionReactorLogicAdapter_0"
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

local modemName = assert(openWirelessModem(), "Wireless modem not found")

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
    return name:lower():find("turbine", 1, true) ~= nil
        and device
        and (device.getProductionRate or device.getFlowRate)
end

local function readSnapshot()
    local matrix = peripheral.wrap(MATRIX_NAME)
    local reactor = peripheral.wrap(REACTOR_NAME)
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

    local matrixData
    if matrix then
        matrixData = {
            energyPercent = number(matrix, "getEnergyFilledPercentage") * 100,
            storedEnergy = number(matrix, "getEnergy") / JOULES_PER_FE,
            capacity = number(matrix, "getMaxEnergy") / JOULES_PER_FE,
            input = number(matrix, "getLastInput") / JOULES_PER_FE,
            output = number(matrix, "getLastOutput") / JOULES_PER_FE,
        }
    end

    local reactorData
    if reactor then
        reactorData = {
            running = boolean(reactor, "getStatus"),
            temperature = number(reactor, "getTemperature"),
            actualBurnRate = number(reactor, "getActualBurnRate"),
            coolantPercent = number(reactor, "getCoolantFilledPercentage") * 100,
            fuelPercent = number(reactor, "getFuelFilledPercentage") * 100,
            wastePercent = number(reactor, "getWasteFilledPercentage") * 100,
            damage = number(reactor, "getDamagePercent"),
        }
    end

    return {
        version = 1,
        computerId = os.getComputerID(),
        sentAt = os.epoch("utc"),
        matrix = matrixData,
        reactor = reactorData,
        turbines = turbines,
    }
end

local function sendSnapshot()
    local snapshot = readSnapshot()
    rednet.broadcast(snapshot, SNAPSHOT_PROTOCOL)
    term.clear()
    term.setCursorPos(1, 1)
    print("Overview telemetry relay")
    print("Modem: " .. modemName)
    print("Matrix: " .. (snapshot.matrix and "CONNECTED" or "OFFLINE"))
    print("Reactor: " .. (snapshot.reactor and "CONNECTED" or "OFFLINE"))
    print("Turbines: " .. #snapshot.turbines)
end

sendSnapshot()
local timer = os.startTimer(INTERVAL)
while true do
    local event, arg1 = os.pullEvent()
    if event == "timer" and arg1 == timer then
        sendSnapshot()
        timer = os.startTimer(INTERVAL)
    elseif event == "peripheral" or event == "peripheral_detach" then
        sendSnapshot()
    end
end
