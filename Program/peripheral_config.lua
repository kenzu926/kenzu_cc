-- peripheral_config <list|get|set|clear|reset|test|names>
-- Edits peripherals.settings on this computer without reboot.
-- Other tabs pick the change up via kenzu_peripherals_changed event,
-- or on the next peripheral event / telemetry tick.
-- Can also be run from the website terminal.
local arguments = { ... }

local scriptDirectory = fs.getDir(shell.getRunningProgram())
local Peripherals = dofile(fs.combine(scriptDirectory, "peripherals.lua"))

local function printStatus()
    local all = Peripherals.all()
    print("Peripheral bindings (" .. Peripherals.SETTINGS_FILE .. "):")
    for _, key in ipairs(Peripherals.KEYS) do
        local configured = all[key]
        local present = peripheral.isPresent(configured)
        local marker = present and "OK " or "MISS"
        print(("  [%s] %-15s = %s"):format(marker, key, configured))
    end
    print("Use: peripheral_config set <key> <name>  (no reboot needed)")
end

local command = arguments[1]

if command == nil or command == "list" then
    printStatus()
    return
end

if command == "keys" then
    print(table.concat(Peripherals.KEYS, " "))
    return
end

if command == "names" then
    for _, name in ipairs(peripheral.getNames()) do
        local ptype = peripheral.getType(name)
        print(name .. "  [" .. tostring(ptype) .. "]")
    end
    return
end

if command == "get" then
    local key = arguments[2]
    if not key then printError("Usage: peripheral_config get <key>") return end
    print(key .. " = " .. tostring(Peripherals.get(key)))
    return
end

if command == "set" then
    local key, name = arguments[2], arguments[3]
    if not key or not name then
        printError("Usage: peripheral_config set <key> <name>")
        return
    end
    local ok, err = Peripherals.set(key, name)
    if not ok then printError(tostring(err)) return end
    Peripherals.notifyChanged()
    if peripheral.isPresent(name) then
        print("Saved " .. key .. " = " .. name .. " (present, applied live)")
    else
        print("Saved " .. key .. " = " .. name .. " (WARNING: not attached right now)")
    end
    return
end

if command == "clear" then
    local key = arguments[2]
    if not key then printError("Usage: peripheral_config clear <key>") return end
    local ok, err = Peripherals.clear(key)
    if not ok then printError(tostring(err)) return end
    Peripherals.notifyChanged()
    print("Reset " .. key .. " to default " .. tostring(Peripherals.get(key)))
    return
end

if command == "reset" then
    Peripherals.reset()
    Peripherals.notifyChanged()
    print("All bindings reset to defaults.")
    printStatus()
    return
end

if command == "test" then
    local matrices = Peripherals.findMatrices()
    print("matrices: " .. #matrices .. " (pattern '" .. Peripherals.matrixPattern() .. "')")
    for _, entry in ipairs(matrices) do print("  - " .. entry.name) end
    local reactors = Peripherals.findReactors()
    print("reactors: " .. #reactors .. " (pattern '" .. Peripherals.reactorPattern() .. "')")
    for _, entry in ipairs(reactors) do print("  - " .. entry.name) end
    local me, meName, meHow = Peripherals.findME()
    print("me:      " .. tostring(meName) .. " [" .. tostring(meHow) .. "] "
        .. (me and "OK" or "MISSING"))
    local turbines = Peripherals.findTurbines()
    print("turbines: " .. #turbines .. " (pattern '" .. Peripherals.turbinePattern() .. "')")
    for _, entry in ipairs(turbines) do print("  - " .. entry.name) end
    local boilers = Peripherals.findBoilers()
    print("boilers: " .. #boilers .. " (pattern '" .. Peripherals.boilerPattern() .. "')")
    for _, entry in ipairs(boilers) do print("  - " .. entry.name) end
    local fusion = Peripherals.findFusionReactors()
    print("fusion: " .. #fusion .. " (pattern '" .. Peripherals.fusionPattern() .. "')")
    for _, entry in ipairs(fusion) do
        local suffix = ""
        local methodsOk, methods = pcall(peripheral.getMethods, entry.name)
        if methodsOk and type(methods) == "table" then
            suffix = (" [methods: %d]"):format(#methods)
        else
            suffix = " [methods unreadable]"
        end
        print("  - " .. entry.name .. suffix)
    end
    local storages = Peripherals.findEnergyStorages()
    local draconic = 0
    for _, entry in ipairs(storages) do
        if entry.kind == "draconic" or entry.kind == "other" then draconic = draconic + 1 end
    end
    print("energy: " .. #storages .. " storages, " .. draconic
        .. " draconic/other (pattern '" .. Peripherals.draconicPattern() .. "')")
    for _, entry in ipairs(storages) do
        if entry.kind ~= "induction" then print("  - [" .. entry.kind .. "] " .. entry.name) end
    end
    for _, key in ipairs({ "monitor", "overviewMonitor", "plansMonitor", "chatBox", "playerDetector" }) do
        local device, name = Peripherals.wrap(key)
        print(key .. ": " .. tostring(name) .. (device and " OK" or " MISSING"))
    end
    local modems, wireless = {}, {}
    for _, name in ipairs(peripheral.getNames()) do
        local ok, isModem = pcall(peripheral.hasType, name, "modem")
        if ok and isModem then
            modems[#modems + 1] = name
            local modem = peripheral.wrap(name)
            if modem and modem.isWireless then
                local wirelessOk, isWireless = pcall(modem.isWireless)
                if wirelessOk and isWireless then wireless[#wireless + 1] = name end
            end
        end
    end
    print("modems: " .. #modems .. " total, " .. #wireless .. " wireless")
    for _, name in ipairs(modems) do print("  - " .. name) end
    return
end

printError("Unknown command. Use: list | get | set | clear | reset | test | names")
