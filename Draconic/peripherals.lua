-- Central peripheral binding registry for kenzu_cc.
-- Replaces hardcoded "inductionPort_0" / "monitor_2" etc scattered over services.
-- Bindings live in peripherals.settings next to the programs and can be changed
-- at runtime via peripheral_config.lua or from the website (peripherals_update).
-- Services must re-wrap handles on RELOAD_EVENT / peripheral events, never assert().
local Peripherals = {}

Peripherals.RELOAD_EVENT = "kenzu_peripherals_changed"
Peripherals.SETTINGS_FILE = "peripherals.settings"

Peripherals.DEFAULTS = {
    matrix = "inductionPort_0",
    reactor = "fissionReactorLogicAdapter_0",
    monitor = "monitor_0",
    overviewMonitor = "monitor_1",
    plansMonitor = "monitor_2",
    chatBox = "chatBox_0",
    playerDetector = "playerDetector_0",
    meBridge = "meBridge_0",
    turbinePattern = "turbine",
    reactorPattern = "fissionReactorLogicAdapter",
    matrixPattern = "inductionPort",
    boilerPattern = "boiler",
    fusionPattern = "fusion",
    draconicPattern = "draconic",
}

local KEYS = {}
for key in pairs(Peripherals.DEFAULTS) do KEYS[#KEYS + 1] = key end
table.sort(KEYS)
Peripherals.KEYS = KEYS

local scriptDirectory = nil
pcall(function()
    if shell and shell.getRunningProgram then
        scriptDirectory = fs.getDir(shell.getRunningProgram())
    end
end)

local function settingsPath()
    if scriptDirectory then return fs.combine(scriptDirectory, Peripherals.SETTINGS_FILE) end
    return Peripherals.SETTINGS_FILE
end

local function defineDefaults()
    for _, key in ipairs(KEYS) do
        pcall(settings.define, "kenzu.peripheral." .. key, {
            description = "Peripheral binding: " .. key,
            default = Peripherals.DEFAULTS[key],
            type = "string",
        })
    end
end

function Peripherals.load()
    defineDefaults()
    pcall(settings.load, settingsPath())
end

function Peripherals.get(key)
    Peripherals.load()
    local configured = settings.get("kenzu.peripheral." .. key)
    if type(configured) == "string" and configured ~= "" then return configured end
    return Peripherals.DEFAULTS[key]
end

function Peripherals.all()
    local result = {}
    for _, key in ipairs(KEYS) do result[key] = Peripherals.get(key) end
    return result
end

function Peripherals.set(key, value, saveNow)
    if Peripherals.DEFAULTS[key] == nil then return false, "Unknown key: " .. tostring(key) end
    if type(value) ~= "string" or value == "" then return false, "Name must be a non-empty string" end
    if #value > 64 then return false, "Name too long (max 64)" end
    if not value:match("^[%w_:%.%-]+$") then
        return false, "Only letters, digits, _:.- allowed"
    end
    defineDefaults()
    pcall(settings.load, settingsPath())
    settings.set("kenzu.peripheral." .. key, value)
    if saveNow ~= false then pcall(settings.save, settingsPath()) end
    return true
end

function Peripherals.clear(key, saveNow)
    if Peripherals.DEFAULTS[key] == nil then return false, "Unknown key" end
    defineDefaults()
    pcall(settings.load, settingsPath())
    settings.set("kenzu.peripheral." .. key, Peripherals.DEFAULTS[key])
    if saveNow ~= false then pcall(settings.save, settingsPath()) end
    return true
end

function Peripherals.reset()
    defineDefaults()
    pcall(settings.load, settingsPath())
    for _, key in ipairs(KEYS) do settings.set("kenzu.peripheral." .. key, Peripherals.DEFAULTS[key]) end
    pcall(settings.save, settingsPath())
end

function Peripherals.notifyChanged()
    os.queueEvent(Peripherals.RELOAD_EVENT)
end

-- Apply a table received from the website ({ matrix = "...", ... }).
-- Returns applied count. Unknown keys are ignored, invalid values are skipped.
function Peripherals.applyRemote(values)
    if type(values) ~= "table" then return 0 end
    local applied = 0
    for _, key in ipairs(KEYS) do
        local value = values[key]
        if type(value) == "string" and value ~= "" then
            local ok = Peripherals.set(key, value, false)
            if ok then applied = applied + 1 end
        end
    end
    if applied > 0 then
        pcall(settings.save, settingsPath())
        Peripherals.notifyChanged()
    end
    return applied
end

-- Exact wrap of the configured name. Returns nil instead of erroring.
function Peripherals.wrap(key)
    local name = Peripherals.get(key)
    if type(name) ~= "string" or name == "" then return nil, nil end
    if not peripheral.isPresent(name) then return nil, name end
    local ok, device = pcall(peripheral.wrap, name)
    if not ok or device == nil then return nil, name end
    return device, name
end

local function hasTypeSafe(name, peripheralType)
    if not peripheral.hasType then return false end
    local ok, result = pcall(peripheral.hasType, name, peripheralType)
    return ok and result == true
end

function Peripherals.findByType(peripheralType)
    for _, name in ipairs(peripheral.getNames()) do
        if hasTypeSafe(name, peripheralType) then
            local device = peripheral.wrap(name)
            if device then return device, name end
        end
    end
end

-- Matrix / reactor: exact name first, then type fallback.
function Peripherals.findMatrix()
    local device, name = Peripherals.wrap("matrix")
    if device then return device, name, "configured" end
    for _, fallbackType in ipairs({ "inductionPort", "induction_port" }) do
        device, name = Peripherals.findByType(fallbackType)
        if device then return device, name, "auto-type" end
    end
    for _, peripheralName in ipairs(peripheral.getNames()) do
        if peripheralName:lower():find("induction", 1, true) then
            local wrapped = peripheral.wrap(peripheralName)
            if wrapped then return wrapped, peripheralName, "auto-name" end
        end
    end
    return nil, Peripherals.get("matrix"), "missing"
end

function Peripherals.findReactor()
    local device, name = Peripherals.wrap("reactor")
    if device then return device, name, "configured" end
    for _, fallbackType in ipairs({ "fissionReactorLogicAdapter", "fission_reactor" }) do
        device, name = Peripherals.findByType(fallbackType)
        if device then return device, name, "auto-type" end
    end
    for _, peripheralName in ipairs(peripheral.getNames()) do
        if peripheralName:lower():find("fissionreactor", 1, true) then
            local wrapped = peripheral.wrap(peripheralName)
            if wrapped then return wrapped, peripheralName, "auto-name" end
        end
    end
    return nil, Peripherals.get("reactor"), "missing"
end

function Peripherals.findMonitor(key)
    key = key or "monitor"
    local device, name = Peripherals.wrap(key)
    if device then return device, name, "configured" end
    return nil, Peripherals.get(key), "missing"
end

function Peripherals.findChatBox()
    local device, name = Peripherals.wrap("chatBox")
    if device then return device, name, "configured" end
    local found = peripheral.find("chatBox")
    if found then
        for _, peripheralName in ipairs(peripheral.getNames()) do
            if peripheralName:lower():find("chatbox", 1, true) then
                return found, peripheralName, "auto-name"
            end
        end
        return found, "chatBox?", "auto-type"
    end
    return nil, Peripherals.get("chatBox"), "missing"
end

function Peripherals.findDetector()
    local device, name = Peripherals.wrap("playerDetector")
    if device then return device, name, "configured" end
    for _, peripheralName in ipairs(peripheral.getNames()) do
        if peripheralName:lower():find("playerdetector", 1, true)
            or hasTypeSafe(peripheralName, "playerDetector") then
            local wrapped = peripheral.wrap(peripheralName)
            if wrapped then return wrapped, peripheralName, "auto-name" end
        end
    end
    return nil, Peripherals.get("playerDetector"), "missing"
end

function Peripherals.findME()
    -- Prefer the server-side Kenzu bridge (ae2:controller with API version).
    for _, peripheralName in ipairs(peripheral.getNames()) do
        if peripheralName:match("^ae2:controller") then
            local controller = peripheral.wrap(peripheralName)
            if controller then
                local ok, version = pcall(function() return controller.getKenzuApiVersion() end)
                if ok and version then return controller, peripheralName, "kenzu-bridge" end
            end
        end
    end
    local bridge = peripheral.find("meBridge") or peripheral.find("me_bridge")
    if bridge then return bridge, "meBridge", "auto-type" end
    local device, name = Peripherals.wrap("meBridge")
    if device then return device, name, "configured" end
    for _, peripheralName in ipairs(peripheral.getNames()) do
        if peripheralName:match("^ae2:controller") then
            return peripheral.wrap(peripheralName), peripheralName, "auto-name"
        end
    end
    return nil, Peripherals.get("meBridge"), "missing"
end

function Peripherals.turbinePattern()
    local pattern = Peripherals.get("turbinePattern")
    if type(pattern) ~= "string" or pattern == "" then pattern = "turbine" end
    return pattern:lower()
end

function Peripherals.isTurbine(peripheralName, device)
    if type(peripheralName) ~= "string" then return false end
    local lower = peripheralName:lower()
    local pattern = Peripherals.turbinePattern()
    if lower:find(pattern, 1, true) then
        if device == nil then return true end
        if device.getProductionRate or device.getFlowRate then return true end
        -- Name matches but device has no turbine methods: still accept so a
        -- renamed peripheral does not silently disappear from discovery.
        return true
    end
    if hasTypeSafe(peripheralName, "turbineValue")
        or hasTypeSafe(peripheralName, "turbineValve") then
        return true
    end
    return false
end

function Peripherals.findTurbines()
    local result = {}
    local ok, names = pcall(peripheral.getNames)
    if not ok or type(names) ~= "table" then return result end
    for _, peripheralName in ipairs(names) do
        local wrapOk, device = pcall(peripheral.wrap, peripheralName)
        if wrapOk and device and Peripherals.isTurbine(peripheralName, device) then
            result[#result + 1] = { name = peripheralName, device = device }
        end
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

local function patternOf(key, fallback)
    local ok, value = pcall(Peripherals.get, key)
    if ok and type(value) == "string" and value ~= "" then return value:lower() end
    return fallback
end

function Peripherals.reactorPattern()
    return patternOf("reactorPattern", "fissionreactorlogicadapter")
end

function Peripherals.matrixPattern()
    return patternOf("matrixPattern", "inductionport")
end

function Peripherals.boilerPattern()
    return patternOf("boilerPattern", "boiler")
end

function Peripherals.fusionPattern()
    return patternOf("fusionPattern", "fusion")
end

function Peripherals.draconicPattern()
    return patternOf("draconicPattern", "draconic")
end

local function hasMethods(device, ...)
    if type(device) ~= "table" then return false end
    for i = 1, select("#", ...) do
        if type(device[select(i, ...)]) ~= "function" then return false end
    end
    return true
end

function Peripherals.isFissionReactor(peripheralName, device)
    if type(peripheralName) ~= "string" then return false end
    if hasTypeSafe(peripheralName, "fissionReactorLogicAdapter") then return true end
    if device ~= nil and hasMethods(device, "getBurnRate", "getDamagePercent", "getTemperature") then
        return true
    end
    if device == nil then
        local wrapOk, wrapped = pcall(peripheral.wrap, peripheralName)
        if wrapOk and wrapped
            and hasMethods(wrapped, "getBurnRate", "getDamagePercent", "getTemperature") then
            return true
        end
    end
    return peripheralName:lower():find(Peripherals.reactorPattern(), 1, true) ~= nil
end

function Peripherals.findReactors()
    local result = {}
    local ok, names = pcall(peripheral.getNames)
    if not ok or type(names) ~= "table" then return result end
    for _, peripheralName in ipairs(names) do
        local wrapOk, device = pcall(peripheral.wrap, peripheralName)
        if wrapOk and device and Peripherals.isFissionReactor(peripheralName, device) then
            result[#result + 1] = { name = peripheralName, device = device }
        end
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

local function isInductionSignature(device)
    return hasMethods(device, "getEnergy", "getMaxEnergy")
        and (device.getEnergyFilledPercentage ~= nil
            or device.getLastInput ~= nil
            or device.getLastOutput ~= nil)
end

function Peripherals.isMatrix(peripheralName, device)
    return Peripherals.isInduction(peripheralName, device)
end

function Peripherals.isInduction(peripheralName, device)
    if type(peripheralName) ~= "string" then return false end
    if hasTypeSafe(peripheralName, "inductionPort")
        or hasTypeSafe(peripheralName, "induction_port") then
        return true
    end
    if device ~= nil and isInductionSignature(device) then return true end
    if device == nil then
        local wrapOk, wrapped = pcall(peripheral.wrap, peripheralName)
        if wrapOk and wrapped and isInductionSignature(wrapped) then return true end
    end
    if peripheralName:lower():find(Peripherals.matrixPattern(), 1, true) then
        if device == nil then return true end
        if device.getEnergy or device.getEnergyFilledPercentage then return true end
        return true
    end
    return false
end

function Peripherals.findMatrices()
    local result = {}
    local ok, names = pcall(peripheral.getNames)
    if not ok or type(names) ~= "table" then return result end
    for _, peripheralName in ipairs(names) do
        local wrapOk, device = pcall(peripheral.wrap, peripheralName)
        if wrapOk and device and Peripherals.isInduction(peripheralName, device) then
            result[#result + 1] = { name = peripheralName, device = device }
        end
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

function Peripherals.isBoiler(peripheralName, device)
    if type(peripheralName) ~= "string" then return false end
    -- A fusion logic adapter also carries tanks: never a boiler.
    if hasTypeSafe(peripheralName, "fusionReactorLogicAdapter") then return false end
    if type(device) == "table" and device.getPlasmaTemperature ~= nil then return false end
    local lower = peripheralName:lower()
    local pattern = Peripherals.boilerPattern()
    local nameMatch = lower:find(pattern, 1, true) ~= nil
    if device ~= nil then
        if hasMethods(device, "getWaterFilledPercentage", "getSteamFilledPercentage")
            and device.getBurnRate == nil then
            return true
        end
        if nameMatch
            and (device.getWaterFilledPercentage or device.getSteamFilledPercentage
                or device.getBoilRate or device.getTemperature) then
            return true
        end
        -- A plain tank/chest with "boiler" in its name is not a boiler.
        local inventoryOnly = (device.pullItems ~= nil or device.pushItems ~= nil
                or device.pullFluid ~= nil or device.pushFluid ~= nil)
            and device.getWaterFilledPercentage == nil
            and device.getSteamFilledPercentage == nil
            and device.getBoilRate == nil
            and device.getTemperature == nil
        if nameMatch and not (device.getBurnRate and device.getDamagePercent)
            and not inventoryOnly then
            return true
        end
        return false
    end
    if nameMatch then return true end
    local wrapOk, wrapped = pcall(peripheral.wrap, peripheralName)
    if wrapOk and wrapped then
        return Peripherals.isBoiler(peripheralName, wrapped)
    end
    return false
end

function Peripherals.findBoilers()
    local result = {}
    local ok, names = pcall(peripheral.getNames)
    if not ok or type(names) ~= "table" then return result end
    for _, peripheralName in ipairs(names) do
        local wrapOk, device = pcall(peripheral.wrap, peripheralName)
        if wrapOk and device and Peripherals.isBoiler(peripheralName, device) then
            result[#result + 1] = { name = peripheralName, device = device }
        end
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

function Peripherals.isFusion(peripheralName, device)
    if type(peripheralName) ~= "string" then return false end
    if hasTypeSafe(peripheralName, "fusionReactorLogicAdapter") then return true end
    if device ~= nil and device.getPlasmaTemperature ~= nil then return true end
    if device == nil then
        local wrapOk, wrapped = pcall(peripheral.wrap, peripheralName)
        if wrapOk then device = wrapped end
    end
    -- Inventory-only blocks (chests, tanks, drawer controllers) must never
    -- count as reactors even when their network name contains "fusion".
    if type(device) == "table"
        and (device.pullItems ~= nil or device.pushItems ~= nil
            or device.pullFluid ~= nil or device.pushFluid ~= nil) then
        return false
    end
    return peripheralName:lower():find(Peripherals.fusionPattern(), 1, true) ~= nil
end

function Peripherals.findFusionReactors()
    local result = {}
    local ok, names = pcall(peripheral.getNames)
    if not ok or type(names) ~= "table" then return result end
    for _, peripheralName in ipairs(names) do
        local wrapOk, device = pcall(peripheral.wrap, peripheralName)
        if wrapOk and device and Peripherals.isFusion(peripheralName, device) then
            result[#result + 1] = { name = peripheralName, device = device }
        end
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

local function hasStoredEnergy(device)
    return type(device) == "table"
        and device.getEnergyStored ~= nil and device.getMaxEnergyStored ~= nil
end

function Peripherals.isDraconicEnergy(peripheralName, device)
    if type(peripheralName) ~= "string" then return false end
    if Peripherals.isInduction(peripheralName, device) then return false end
    if device == nil then
        local wrapOk, wrapped = pcall(peripheral.wrap, peripheralName)
        if wrapOk then device = wrapped end
    end
    if peripheralName:lower():find(Peripherals.draconicPattern(), 1, true) then
        if device == nil then return true end
        if hasStoredEnergy(device) then return true end
        return true
    end
    if hasStoredEnergy(device) and not isInductionSignature(device) then return true end
    return false
end

function Peripherals.findEnergyStorages()
    local result = {}
    local ok, names = pcall(peripheral.getNames)
    if not ok or type(names) ~= "table" then return result end
    for _, peripheralName in ipairs(names) do
        local wrapOk, device = pcall(peripheral.wrap, peripheralName)
        if wrapOk and device then
            local kind = nil
            if Peripherals.isInduction(peripheralName, device) then
                kind = "induction"
            elseif Peripherals.isDraconicEnergy(peripheralName, device) then
                kind = "draconic"
            elseif hasStoredEnergy(device) then
                kind = "other"
            end
            if kind then
                result[#result + 1] = { name = peripheralName, device = device, kind = kind }
            end
        end
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

function Peripherals.status()
    local result = {}
    for _, key in ipairs(KEYS) do
        local configured = Peripherals.get(key)
        local present = type(configured) == "string"
            and peripheral.isPresent(configured) == true
        result[key] = { configured = configured, present = present }
    end
    result._names = peripheral.getNames()
    return result
end

-- Storage-cell category from a key-type id or cell item id.
-- Returns item|fluid|chemical|source|mana|energy or nil (caller falls back).
function Peripherals.cellCategory(token)
    if type(token) ~= "string" or token == "" then return nil end
    local hay = token:lower()
    if hay:find("chemic", 1, true) then return "chemical" end
    if hay:find("fluid", 1, true) or hay:find("liquid", 1, true) then return "fluid" end
    if hay:find("source", 1, true) then return "source" end
    if hay:find("mana", 1, true) then return "mana" end
    if hay:find("flux", 1, true) or hay:find("energy", 1, true) then return "energy" end
    if hay:find("item", 1, true) then return "item" end
    if hay:find("cell", 1, true) or hay:find("disk", 1, true) or hay:find("drive", 1, true) then
        return "item"
    end
    return nil
end

return Peripherals
