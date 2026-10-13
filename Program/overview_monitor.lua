-- 6x4 tabbed overview dashboard (monitor_1): ENERGY / REACTORS / TURBINES / ME.
-- Local devices plus rednet data from another computer (legacy + snapshot).
local scriptDirectory = fs.getDir(shell.getRunningProgram())
local Peripherals = dofile(fs.combine(scriptDirectory, "peripherals.lua"))
local MONITOR_NAME = Peripherals.get("overviewMonitor")
local MATRIX_NAME = Peripherals.get("matrix")
local REACTOR_NAME = Peripherals.get("reactor")
local ME_NAME = Peripherals.get("meBridge")
local ME_STATUS_PROTOCOL = "kenzu_cc.me_status"
local REACTOR_PROTOCOL = "kenzu_cc.overview.reactor"
local TURBINE_PROTOCOL = "kenzu_cc.overview.turbines"
local SNAPSHOT_PROTOCOL = "kenzu_cc.overview.snapshot"
local REFRESH_INTERVAL = 1
local REMOTE_TIMEOUT = 10 * 1000
local JOULES_PER_FE = 2.5
local STARTED_AT = os.epoch("utc")

local monitor = Peripherals.wrap("overviewMonitor")
if not monitor then
    -- No assert: show hint on the local terminal, keep rednet relay working.
    print("Overview monitor not found: " .. tostring(MONITOR_NAME))
    print("Run: peripheral_config set overviewMonitor <name>")
end
if monitor then pcall(monitor.setTextScale, 0.5) end

local matrix = peripheral.wrap(MATRIX_NAME)
local reactor = peripheral.wrap(REACTOR_NAME)
local meBridge

-- Tabs + paging state.
local tab = "energy"
local buttons = {}
local energyPage = 1
local reactorPage = 1
local turbinePage = 1
local cellPage = 1

-- Local snapshots (rebuilt every refresh).
local localEnergy = {}
local localReactors = {}
local localTurbines = {}
local localME = { connected = false, total = 0, used = 0, available = 0, cells = {}, cellSource = "none" }

-- Remote data.
local remoteMatrices = {}
local remoteReactors = {}
local remoteTurbines = nil
local remoteEnergyUnits = {}
local remoteBoilers = {}
local remoteFusion = {}
local matrixHeartbeat, reactorHeartbeat, turbineHeartbeat
local energyHeartbeat, boilerHeartbeat, fusionHeartbeat, meHeartbeat
local meConnectedRemote = false
local remoteMEMetrics = { total = 0, used = 0, available = 0, cells = {}, cellSource = "none" }

local function openWirelessModem()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            local modem = peripheral.wrap(name)
            if modem and modem.isWireless then
                local ok, wireless = pcall(modem.isWireless)
                if ok and wireless then
                    rednet.open(name)
                    return true
                end
            end
        end
    end
    return false
end

local hasRednet = openWirelessModem()

local function findMEBridge()
    -- Match the same peripherals as me_node.lua, including the server-side
    -- addon which is exposed under an ae2:controller_* name.
    for _, name in ipairs(peripheral.getNames()) do
        if name:match("^ae2:controller") then
            local controller = peripheral.wrap(name)
            local ok, version = pcall(function() return controller.getKenzuApiVersion() end)
            if ok and version then return controller end
        end
    end
    local bridge = peripheral.find("meBridge") or peripheral.find("me_bridge")
    if bridge then return bridge end
    local exact = peripheral.wrap(ME_NAME)
    if exact then return exact end
    for _, name in ipairs(peripheral.getNames()) do
        if name:match("^ae2:controller") then return peripheral.wrap(name) end
    end
end

meBridge = findMEBridge()

local function safeRawCall(device, method)
    if not device or not device[method] then return nil end
    local ok, value = pcall(device[method])
    if not ok then return nil end
    return value
end

local function safeNumber(device, method, fallback)
    local value = safeRawCall(device, method)
    if type(value) == "table" then value = value.amount or value[1] end
    return tonumber(value) or fallback or 0
end

local function safeBoolean(device, method, fallback)
    local value = safeRawCall(device, method)
    if value == nil then return fallback == true end
    return value == true
end

local function countEntries(value)
    if type(value) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    return count
end

local function firstNumber(source, names)
    if type(source) ~= "table" then return nil end
    for _, key in ipairs(names) do
        local value = tonumber(source[key])
        if value ~= nil then return value end
    end
    return nil
end

local function shorten(value)
    value = tonumber(value) or 0
    local absolute = math.abs(value)
    if absolute >= 1e15 then return ("%.2fP"):format(value / 1e15) end
    if absolute >= 1e12 then return ("%.2fT"):format(value / 1e12) end
    if absolute >= 1e9 then return ("%.2fG"):format(value / 1e9) end
    if absolute >= 1e6 then return ("%.2fM"):format(value / 1e6) end
    if absolute >= 1e3 then return ("%.1fk"):format(value / 1e3) end
    return ("%.0f"):format(value)
end

local function isFresh(timestamp)
    return timestamp ~= nil and os.epoch("utc") - timestamp <= REMOTE_TIMEOUT
end

local function hasTypeSafe(name, peripheralType)
    if not peripheral.hasType then return false end
    local ok, result = pcall(peripheral.hasType, name, peripheralType)
    return ok and result == true
end

local function listNames()
    local ok, names = pcall(peripheral.getNames)
    if ok and type(names) == "table" then return names end
    return {}
end

-- --------------------------------------------------------------------------
-- Local scans (all matching peripherals, not only the configured one).
-- --------------------------------------------------------------------------

local function scanLocalEnergy()
    local result = {}
    local seen = {}
    local candidates = {}
    if type(MATRIX_NAME) == "string" and MATRIX_NAME ~= "" then
        candidates[#candidates + 1] = MATRIX_NAME
    end
    for _, name in ipairs(listNames()) do
        local lower = name:lower()
        if lower:find("induction", 1, true)
            or hasTypeSafe(name, "inductionPort")
            or hasTypeSafe(name, "induction_port") then
            candidates[#candidates + 1] = name
        end
    end
    for _, name in ipairs(candidates) do
        if not seen[name] then
            seen[name] = true
            local device = peripheral.wrap(name)
            if device and (device.getEnergy or device.getEnergyFilledPercentage or device.getMaxEnergy) then
                local stored = safeNumber(device, "getEnergy") / JOULES_PER_FE
                local capacity = safeNumber(device, "getMaxEnergy") / JOULES_PER_FE
                local percent = safeNumber(device, "getEnergyFilledPercentage") * 100
                if capacity > 0 and percent == 0 then
                    percent = stored / capacity * 100
                end
                result[#result + 1] = {
                    name = name,
                    kind = "IND",
                    stored = stored,
                    capacity = capacity,
                    percent = percent,
                    input = safeNumber(device, "getLastInput") / JOULES_PER_FE,
                    output = safeNumber(device, "getLastOutput") / JOULES_PER_FE,
                    source = "LOCAL",
                }
            end
        end
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

local function readReactorEntry(device, name, source)
    return {
        name = name,
        running = safeBoolean(device, "getStatus"),
        temperature = safeNumber(device, "getTemperature"),
        actualBurnRate = safeNumber(device, "getActualBurnRate"),
        coolantPercent = safeNumber(device, "getCoolantFilledPercentage") * 100,
        fuelPercent = safeNumber(device, "getFuelFilledPercentage") * 100,
        wastePercent = safeNumber(device, "getWasteFilledPercentage") * 100,
        damage = safeNumber(device, "getDamagePercent"),
        source = source or "LOCAL",
    }
end

local function scanLocalReactors()
    local result = {}
    local seen = {}
    local candidates = {}
    if type(REACTOR_NAME) == "string" and REACTOR_NAME ~= "" then
        candidates[#candidates + 1] = REACTOR_NAME
    end
    for _, name in ipairs(listNames()) do
        local lower = name:lower()
        if lower:find("fissionreactor", 1, true)
            or hasTypeSafe(name, "fissionReactorLogicAdapter")
            or hasTypeSafe(name, "fission_reactor") then
            candidates[#candidates + 1] = name
        end
    end
    for _, name in ipairs(candidates) do
        if not seen[name] then
            seen[name] = true
            local device = peripheral.wrap(name)
            if device and (device.getStatus or device.getTemperature or device.getFuelFilledPercentage) then
                result[#result + 1] = readReactorEntry(device, name, "LOCAL")
            end
        end
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

local function scanLocalTurbines()
    local result = {}
    local found = nil
    if Peripherals and Peripherals.findTurbines then
        local ok, list = pcall(Peripherals.findTurbines)
        if ok and type(list) == "table" then found = list end
    end
    if found == nil then
        found = {}
        local pattern = "turbine"
        if Peripherals and Peripherals.turbinePattern then
            local ok, value = pcall(Peripherals.turbinePattern)
            if ok and type(value) == "string" and value ~= "" then pattern = value end
        end
        for _, name in ipairs(listNames()) do
            local device = peripheral.wrap(name)
            local isTurbine = false
            if Peripherals and Peripherals.isTurbine then
                local ok, value = pcall(Peripherals.isTurbine, name, device)
                isTurbine = ok and value == true
            else
                isTurbine = name:lower():find(pattern, 1, true) ~= nil
                    and device ~= nil
                    and (device.getProductionRate or device.getFlowRate)
            end
            if isTurbine and device then
                found[#found + 1] = { name = name, device = device }
            end
        end
    end
    for _, entry in ipairs(found) do
        local device = entry.device or peripheral.wrap(entry.name)
        if device then
            result[#result + 1] = {
                name = entry.name or "TURBINE",
                production = safeNumber(device, "getProductionRate") / JOULES_PER_FE,
                flowRate = safeNumber(device, "getFlowRate"),
                maxFlowRate = safeNumber(device, "getMaxFlowRate"),
                steamPercent = safeNumber(device, "getSteamFilledPercentage") * 100,
                source = "LOCAL",
            }
        end
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

local function appendLocalCells(target, rawCells)
    if type(rawCells) ~= "table" then return end
    for index, cell in pairs(rawCells) do
        if type(cell) == "table" and type(cell.cells) == "table" then
            appendLocalCells(target, cell.cells)
        elseif type(cell) == "table" then
            local totalBytes = firstNumber(cell, { "bytes", "capacity", "maxBytes", "bytesTotal", "totalBytes" }) or 0
            local usedBytes = firstNumber(cell, { "usedBytes", "used", "bytesUsed" })
            local availableBytes = firstNumber(cell, { "availableBytes", "freeBytes", "bytesFree" })
            if usedBytes == nil and availableBytes ~= nil and totalBytes > 0 then
                usedBytes = math.max(0, totalBytes - availableBytes)
            end
            local item = cell.item or cell.name or cell.id
            if type(item) == "table" then
                item = item.displayName or item.name or item.id or item.registryName
            end
            target[#target + 1] = {
                item = tostring(item or ("ME storage cell " .. tostring(index))),
                cellType = cell.cellType or cell.type or "item",
                totalBytes = totalBytes,
                usedBytes = usedBytes,
                usedKnown = usedBytes ~= nil,
                bytesPerType = tonumber(cell.bytesPerType) or 0,
            }
        end
    end
end

local function scanLocalME()
    local snapshot = { connected = false, total = 0, used = 0, available = 0, cells = {}, cellSource = "none" }
    if not meBridge then return snapshot end
    local stats = safeRawCall(meBridge, "getStorageStats")
    local cells = {}
    if type(stats) == "table" then
        snapshot.total = tonumber(stats.total) or 0
        snapshot.used = tonumber(stats.used) or 0
        snapshot.available = tonumber(stats.available) or math.max(0, snapshot.total - snapshot.used)
        appendLocalCells(cells, stats.cells)
        snapshot.cellSource = "Kenzu CC Bridge"
    else
        snapshot.total = safeNumber(meBridge, "getMaxItemStorage")
        if snapshot.total == 0 then snapshot.total = safeNumber(meBridge, "getTotalItemStorage") end
        snapshot.used = safeNumber(meBridge, "getUsedItemStorage")
        snapshot.available = safeNumber(meBridge, "getAvailableItemStorage", math.max(0, snapshot.total - snapshot.used))
    end
    if #cells == 0 then
        appendLocalCells(cells, safeRawCall(meBridge, "getCells"))
        if #cells > 0 then snapshot.cellSource = "getCells" end
    end
    if #cells == 0 then
        appendLocalCells(cells, safeRawCall(meBridge, "listCells"))
        if #cells > 0 then snapshot.cellSource = "listCells" end
    end
    if #cells == 0 then
        appendLocalCells(cells, safeRawCall(meBridge, "getDrives"))
        if #cells > 0 then snapshot.cellSource = "getDrives" end
    end
    if #cells == 0 and snapshot.total > 0 then
        cells[1] = {
            item = "ME network total (cells unavailable)",
            cellType = "aggregate",
            totalBytes = snapshot.total,
            usedBytes = snapshot.used,
            usedKnown = true,
        }
        snapshot.cellSource = "aggregate fallback"
    end
    snapshot.cells = cells
    snapshot.connected = safeBoolean(meBridge, "isConnected", true)
    return snapshot
end

local function refreshLocal()
    localEnergy = scanLocalEnergy()
    localReactors = scanLocalReactors()
    localTurbines = scanLocalTurbines()
    localME = scanLocalME()
end

-- --------------------------------------------------------------------------
-- Remote normalization (tolerate missing fields).
-- --------------------------------------------------------------------------

local function detectEnergyKind(raw, fallbackName)
    if type(raw) == "table" and type(raw.kind) == "string" and raw.kind ~= "" then
        return raw.kind:upper():sub(1, 3)
    end
    local haystack = tostring((type(raw) == "table" and (raw.name or raw.peripheral)) or fallbackName or ""):lower()
    if haystack:find("draconic", 1, true) then return "DRA" end
    if haystack:find("induction", 1, true) or haystack:find("matrix", 1, true) then return "IND" end
    return "PWR"
end

local function normalizeEnergy(raw, fallbackName)
    if type(raw) ~= "table" then return nil end
    local stored = firstNumber(raw, { "storedEnergy", "stored", "energyStored", "energy" }) or 0
    local capacity = firstNumber(raw, { "capacity", "maxEnergy", "max", "energyCapacity" }) or 0
    local percent = firstNumber(raw, { "energyPercent", "percent", "filledPercent", "fillPercent" })
    if percent == nil then
        local fraction = firstNumber(raw, { "filledPercentage", "fillFraction" })
        if fraction ~= nil then percent = fraction * 100 end
    end
    if percent == nil and capacity > 0 then percent = stored / capacity * 100 end
    return {
        name = tostring(raw.name or raw.peripheral or raw.id or fallbackName or "REMOTE ENERGY"),
        kind = detectEnergyKind(raw, fallbackName),
        stored = stored,
        capacity = capacity,
        percent = percent or 0,
        input = firstNumber(raw, { "input", "lastInput", "inputRate" }),
        output = firstNumber(raw, { "output", "lastOutput", "outputRate" }),
    }
end

local function percentField(raw, names)
    local value = firstNumber(raw, names)
    if value == nil then return 0 end
    if value > 0 and value <= 1 then return value * 100 end
    return value
end

local function normalizeReactor(raw, sender)
    if type(raw) ~= "table" then return nil end
    local running = raw.running == true or raw.active == true or raw.status == true
    if not running and type(raw.status) == "string" then
        running = raw.status:lower():find("on") ~= nil
    end
    return {
        name = tostring(raw.name or raw.peripheral or ("REACTOR " .. tostring(sender))),
        peripheral = tostring(raw.peripheral or raw.name or tostring(sender)),
        running = running,
        temperature = firstNumber(raw, { "temperature", "temp", "heat" }) or 0,
        actualBurnRate = firstNumber(raw, { "actualBurnRate", "burnRate", "burn" }) or 0,
        coolantPercent = percentField(raw, { "coolantPercent", "coolant", "waterPercent", "water" }),
        fuelPercent = percentField(raw, { "fuelPercent", "fuel", "fuelFilled" }),
        wastePercent = percentField(raw, { "wastePercent", "waste" }),
        damage = firstNumber(raw, { "damage", "damagePercent" }) or 0,
    }
end

local function normalizeTurbine(raw, index, sender)
    if type(raw) ~= "table" then return nil end
    return {
        name = tostring(raw.name or raw.peripheral or ("TURBINE " .. tostring(index))),
        production = firstNumber(raw, { "production", "generation", "rate", "productionRate" }) or 0,
        flowRate = firstNumber(raw, { "flowRate", "flow" }) or 0,
        maxFlowRate = firstNumber(raw, { "maxFlowRate", "maxFlow" }) or 0,
        steamPercent = percentField(raw, { "steamPercent", "steam" }),
    }
end

local function normalizeFusion(raw, index, sender)
    if type(raw) ~= "table" then return nil end
    return {
        name = tostring(raw.name or raw.peripheral or ("FUSION " .. tostring(index or sender))),
        plasmaTemp = firstNumber(raw, { "plasmaTemp", "plasmaTemperature", "plasma" }) or 0,
        caseTemp = firstNumber(raw, { "caseTemp", "caseTemperature", "case", "temperature", "temp" }) or 0,
        injectionRate = firstNumber(raw, { "injectionRate", "injection", "fuelRate" }),
    }
end

local function normalizeBoiler(raw, index, sender)
    if type(raw) ~= "table" then return nil end
    return {
        name = tostring(raw.name or raw.peripheral or ("BOILER " .. tostring(index or sender))),
        waterPercent = percentField(raw, { "waterPercent", "water", "waterFilled" }),
        steamPercent = percentField(raw, { "steamPercent", "steam", "steamFilled" }),
    }
end

local function normalizeMEcells(rawCells)
    local result = {}
    appendLocalCells(result, rawCells)
    -- appendLocalCells already normalizes item/cellType/totalBytes/usedBytes.
    -- Keep entries that carry at least a name even when byte fields are absent.
    return result
end

-- --------------------------------------------------------------------------
-- Drawing helpers (kept).
-- --------------------------------------------------------------------------

local function fill(x1, y1, x2, y2, background)
    if not monitor then return end
    local width, height = monitor.getSize()
    x1, y1 = math.max(1, x1), math.max(1, y1)
    x2, y2 = math.min(width, x2), math.min(height, y2)
    if x1 > x2 or y1 > y2 then return end
    monitor.setBackgroundColor(background)
    for y = y1, y2 do
        monitor.setCursorPos(x1, y)
        monitor.write(string.rep(" ", x2 - x1 + 1))
    end
end

local function text(x, y, value, color, background)
    if not monitor then return end
    local width, height = monitor.getSize()
    if y < 1 or y > height or x > width then return end
    value = tostring(value)
    monitor.setCursorPos(math.max(1, x), y)
    monitor.setTextColor(color or colors.white)
    monitor.setBackgroundColor(background or colors.black)
    monitor.write(value:sub(1, math.max(0, width - x + 1)))
end

local function centered(y, value, color, background)
    if not monitor then return end
    local width = monitor.getSize()
    value = tostring(value)
    text(math.max(1, math.floor((width - #value) / 2) + 1), y, value, color, background)
end

local function bar(x, y, width, percent, color, rows)
    if not monitor then return end
    percent = math.max(0, math.min(100, tonumber(percent) or 0))
    rows = rows or 1
    fill(x, y, x + width - 1, y + rows - 1, colors.gray)
    local amount = math.floor(width * percent / 100 + 0.5)
    if amount > 0 then fill(x, y, x + amount - 1, y + rows - 1, color or colors.lime) end
end

local function sectionHeader(y, label, source, color)
    if not monitor then return end
    local width = monitor.getSize()
    fill(1, y, width, y, color)
    text(2, y, label, colors.black, color)
    local sourceColor = colors.lime
    if source == "OFFLINE" then sourceColor = colors.red end
    if source == "STALE" then sourceColor = colors.orange end
    text(math.max(2, width - #source), y, source, sourceColor, color)
end

local function meter(y, label, percent, color, rows)
    if not monitor then return end
    local width = monitor.getSize()
    rows = rows or 2
    text(3, y, label, colors.lightGray)
    text(math.max(3, width - 8), y, ("%6.1f%%"):format(tonumber(percent) or 0), colors.white)
    bar(3, y + 1, math.max(8, width - 6), percent, color, rows)
end

local function button(x, y, width, label, action, selected, enabled)
    if not monitor then return end
    local background = selected and colors.blue or colors.gray
    local foreground = enabled == false and colors.lightGray or colors.white
    local value = tostring(label):sub(1, width)
    local padding = math.max(0, math.floor((width - #value) / 2))
    monitor.setCursorPos(x, y)
    monitor.setTextColor(foreground)
    monitor.setBackgroundColor(background)
    monitor.write(string.rep(" ", width))
    monitor.setCursorPos(x + padding, y)
    monitor.write(value)
    if enabled ~= false then
        buttons[#buttons + 1] = { x = x, y = y, width = width, action = action }
    end
end

local function moscowDateTime()
    local seconds = math.floor(os.epoch("utc") / 1000) + 3 * 60 * 60
    local ok, value = pcall(os.date, "!%d.%m.%Y %H:%M:%S", seconds)
    return ok and value or textutils.formatTime(os.time() + 3, true)
end

local function uptime()
    local seconds = math.max(0, math.floor((os.epoch("utc") - STARTED_AT) / 1000))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor(seconds % 3600 / 60)
    return ("UP %02d:%02d:%02d"):format(hours, minutes, seconds % 60)
end

-- --------------------------------------------------------------------------
-- Combined data builders.
-- --------------------------------------------------------------------------

local function energyEntries()
    local result = {}
    for _, entry in ipairs(localEnergy) do
        result[#result + 1] = {
            name = entry.name, kind = entry.kind,
            stored = entry.stored, capacity = entry.capacity,
            percent = entry.percent, input = entry.input, output = entry.output,
            source = "LOCAL",
        }
    end
    local matrixFresh = isFresh(matrixHeartbeat)
    for _, raw in ipairs(remoteMatrices) do
        if type(raw) == "table" then
            local normalized = raw.stored ~= nil and raw or normalizeEnergy(raw, "REMOTE MATRIX")
            if normalized then
                normalized.source = matrixFresh and "REDNET" or "STALE"
                result[#result + 1] = normalized
            end
        end
    end
    local unitsFresh = isFresh(energyHeartbeat)
    for _, raw in ipairs(remoteEnergyUnits) do
        if type(raw) == "table" then
            local normalized = raw.stored ~= nil and raw or normalizeEnergy(raw, "REMOTE UNIT")
            if normalized then
                normalized.source = unitsFresh and "REDNET" or "STALE"
                result[#result + 1] = normalized
            end
        end
    end
    return result
end

local function reactorEntries()
    local result = {}
    for _, entry in ipairs(localReactors) do
        result[#result + 1] = entry
    end
    local fresh = isFresh(reactorHeartbeat)
    for _, raw in ipairs(remoteReactors) do
        if type(raw) == "table" then
            local normalized = raw.temperature ~= nil and raw or normalizeReactor(raw, "?")
            if normalized then
                normalized.source = fresh and "REDNET" or "STALE"
                result[#result + 1] = normalized
            end
        end
    end
    return result
end

local function turbineEntries()
    if #localTurbines > 0 then return localTurbines, "LOCAL" end
    if type(remoteTurbines) == "table" then
        return remoteTurbines, isFresh(turbineHeartbeat) and "REDNET" or "STALE"
    end
    return {}, "OFFLINE"
end

local function meSnapshot()
    local localOk = meBridge ~= nil
        and (localME.connected or (tonumber(localME.total) or 0) > 0 or #(localME.cells or {}) > 0)
    if localOk then return localME, "LOCAL" end
    if meHeartbeat then
        return {
            connected = meConnectedRemote,
            total = tonumber(remoteMEMetrics.total) or 0,
            used = tonumber(remoteMEMetrics.used) or 0,
            available = tonumber(remoteMEMetrics.available) or 0,
            cells = remoteMEMetrics.cells or {},
            cellSource = remoteMEMetrics.cellSource or "rednet",
        }, isFresh(meHeartbeat) and "REDNET" or "STALE"
    end
    return { connected = false, total = 0, used = 0, available = 0, cells = {}, cellSource = "none" }, "OFFLINE"
end

local function cellTypeLabel(rawType)
    local key = tostring(rawType or "item"):lower()
    if key == "item" then return "ITEMS" end
    if key == "fluid" then return "FLUIDS" end
    return tostring(rawType or "item"):upper()
end

-- --------------------------------------------------------------------------
-- Tab content.
-- --------------------------------------------------------------------------

local function drawPaging(y, current, pages, onPrev, onNext, width)
    if pages <= 1 then return end
    button(2, y, 10, "< PREV", onPrev, false, current > 1)
    centered(y, ("PAGE %d / %d"):format(current, pages), colors.lightGray)
    button(math.max(2, width - 11), y, 10, "NEXT >", onNext, false, current < pages)
end

local function drawEnergyTab(y1, y2, width)
    local entries = energyEntries()
    local stored, capacity, localCount, remoteCount = 0, 0, 0, 0
    for _, entry in ipairs(entries) do
        if entry.source == "LOCAL" then
            localCount = localCount + 1
        elseif entry.source == "REDNET" then
            remoteCount = remoteCount + 1
        end
        if entry.source == "LOCAL" or entry.source == "REDNET" then
            stored = stored + (tonumber(entry.stored) or 0)
            capacity = capacity + (tonumber(entry.capacity) or 0)
        end
    end
    local percent = capacity > 0 and stored / capacity * 100 or 0
    text(2, y1, ("TOTAL %s / %s FE  %5.1f%%"):format(shorten(stored), shorten(capacity), percent), colors.white)
    text(2, y1 + 1, ("STORES %d  LOCAL %d  REMOTE %d"):format(#entries, localCount, remoteCount), colors.lightGray)
    local listTop = y1 + 3
    if #entries == 0 then
        text(2, listTop, "NO ENERGY DATA", colors.orange)
        return "OFFLINE"
    end
    local rowsPer = 4
    local avail = y2 - listTop + 1
    local perPage = math.max(1, math.floor(avail / rowsPer))
    local pages = math.max(1, math.ceil(#entries / perPage))
    if pages > 1 then
        perPage = math.max(1, math.floor((avail - 1) / rowsPer))
        pages = math.max(1, math.ceil(#entries / perPage))
    end
    energyPage = math.max(1, math.min(energyPage, pages))
    local first = (energyPage - 1) * perPage + 1
    local last = math.min(#entries, first + perPage - 1)
    local nameWidth = math.max(10, width - 14)
    for index = first, last do
        local entry = entries[index]
        local r = listTop + (index - first) * rowsPer
        if r + 2 <= y2 then
            local stale = entry.source == "STALE"
            text(2, r, ("[%s] %s"):format(entry.kind or "PWR", tostring(entry.name):sub(1, nameWidth)),
                stale and colors.orange or colors.cyan)
            text(math.max(2, width - 7), r, ("%5.1f%%"):format(tonumber(entry.percent) or 0), colors.white)
            local io = ""
            if entry.input ~= nil or entry.output ~= nil then
                io = ("  IN %s OUT %s"):format(shorten(entry.input or 0), shorten(entry.output or 0))
            end
            text(2, r + 1, ("%s / %s FE%s [%s]"):format(
                shorten(entry.stored), shorten(entry.capacity), io, entry.source or "?"), colors.lightGray)
            local color = colors.lime
            if stale then color = colors.orange
            elseif (tonumber(entry.percent) or 0) >= 95 then color = colors.orange end
            bar(2, r + 2, math.max(8, width - 4), entry.percent, color, 1)
        end
    end
    if pages > 1 then
        drawPaging(y2, energyPage, pages, function() energyPage = energyPage - 1 end,
            function() energyPage = energyPage + 1 end, width)
    end
    if remoteCount > 0 and localCount > 0 then return "LOCAL+REDNET" end
    if remoteCount > 0 then return "REDNET" end
    if localCount > 0 then return "LOCAL" end
    return "STALE"
end

local function drawReactorsTab(y1, y2, width)
    local reactors = reactorEntries()
    local localCount = #localReactors
    local remoteCount = #reactors - localCount
    text(2, y1, ("FISSION %d  LOCAL %d  REMOTE %d"):format(#reactors, localCount, math.max(0, remoteCount)), colors.white)
    local fusion = {}
    if type(remoteFusion) == "table" then
        for _, raw in ipairs(remoteFusion) do
            if type(raw) == "table" then fusion[#fusion + 1] = raw end
        end
    end
    local boilers = {}
    if type(remoteBoilers) == "table" then
        for _, raw in ipairs(remoteBoilers) do
            if type(raw) == "table" then boilers[#boilers + 1] = raw end
        end
    end
    local fusionRows = #fusion > 0 and (math.min(#fusion, 4) * 2 + 1) or 0
    local boilerRows = #boilers > 0 and (math.min(#boilers, 6) + 1) or 0
    local listTop = y1 + 2
    local listBottom = y2 - fusionRows - boilerRows
    local pagingReserved = 0
    local rowsPer = 3
    local perPage = math.max(1, math.floor(math.max(0, listBottom - listTop + 1) / rowsPer))
    local pages = math.max(1, math.ceil(math.max(1, #reactors) / perPage))
    if #reactors == 0 then pages = 1 end
    if pages > 1 then
        pagingReserved = 1
        perPage = math.max(1, math.floor(math.max(0, listBottom - listTop + 1 - 1) / rowsPer))
        pages = math.max(1, math.ceil(#reactors / perPage))
    end
    reactorPage = math.max(1, math.min(reactorPage, pages))
    if #reactors == 0 then
        text(2, listTop, "NO FISSION DATA", colors.orange)
    else
        local nameWidth = math.max(10, width - 12)
        local first = (reactorPage - 1) * perPage + 1
        local last = math.min(#reactors, first + perPage - 1)
        for index = first, last do
            local entry = reactors[index]
            local r = listTop + (index - first) * rowsPer
            if r + 2 <= listBottom then
                local running = entry.running == true
                local statusColor = colors.red
                local statusText = "OFF"
                if running then statusText, statusColor = "ON", colors.lime end
                if entry.source == "STALE" then statusColor = colors.orange end
                text(2, r, tostring(entry.name or "?"):sub(1, nameWidth), colors.yellow)
                text(math.max(2, width - 4), r, statusText, statusColor)
                text(2, r + 1, ("T %.0fK BURN %.2f DMG %.1f%%"):format(
                    tonumber(entry.temperature) or 0,
                    tonumber(entry.actualBurnRate) or 0,
                    tonumber(entry.damage) or 0), colors.lightGray)
                text(2, r + 2, ("W %d%% F %d%% X %d%%"):format(
                    tonumber(entry.coolantPercent) or 0,
                    tonumber(entry.fuelPercent) or 0,
                    tonumber(entry.wastePercent) or 0), colors.cyan)
            end
        end
    end
    local y = listBottom + 1
    if pages > 1 and y <= y2 then
        drawPaging(y, reactorPage, pages, function() reactorPage = reactorPage - 1 end,
            function() reactorPage = reactorPage + 1 end, width)
        y = y + 1
    elseif pages <= 1 and #reactors > 0 and y <= y2 then
        y = y + 0
    end
    if #fusion > 0 then
        if y <= y2 then text(2, y, "FUSION", colors.purple) y = y + 1 end
        for i = 1, math.min(#fusion, 4) do
            if y + 1 <= y2 then
                local f = fusion[i]
                text(2, y, tostring(f.name or ("FUSION " .. i)):sub(1, width - 4), colors.white)
                y = y + 1
                local inj = f.injectionRate ~= nil and (" INJ " .. shorten(f.injectionRate)) or ""
                text(2, y, ("PL %.0fK CASE %.0fK%s"):format(
                    tonumber(f.plasmaTemp) or 0, tonumber(f.caseTemp) or 0, inj):sub(1, width - 4), colors.lightGray)
                y = y + 1
            end
        end
    end
    if #boilers > 0 then
        if y <= y2 then text(2, y, "BOILERS", colors.lightBlue) y = y + 1 end
        for i = 1, math.min(#boilers, 6) do
            if y <= y2 then
                local b = boilers[i]
                text(2, y, ("%s W %d%% S %d%%"):format(
                    tostring(b.name or ("BOILER " .. i)):sub(1, math.max(8, width - 20)),
                    tonumber(b.waterPercent) or 0, tonumber(b.steamPercent) or 0):sub(1, width - 2),
                    colors.lightGray)
                y = y + 1
            end
        end
    end
    if localCount > 0 and remoteCount > 0 then return "LOCAL+REDNET" end
    if localCount > 0 then return "LOCAL" end
    if remoteCount > 0 and isFresh(reactorHeartbeat) then return "REDNET" end
    if remoteCount > 0 then return "STALE" end
    if #fusion > 0 or #boilers > 0 then return "REDNET" end
    return "OFFLINE"
end

local function drawTurbinesTab(y1, y2, width)
    local units, source = turbineEntries()
    local production, flow, maxFlow, steam = 0, 0, 0, 0
    for _, unit in ipairs(units) do
        production = production + (tonumber(unit.production) or 0)
        flow = flow + (tonumber(unit.flowRate) or 0)
        maxFlow = maxFlow + (tonumber(unit.maxFlowRate) or 0)
        steam = steam + (tonumber(unit.steamPercent) or 0)
    end
    if #units > 0 then steam = steam / #units end
    text(2, y1, ("%d UNITS  GEN %s FE/t"):format(#units, shorten(production)), colors.white)
    text(2, y1 + 1, ("FLOW %s/%s  STEAM %5.1f%%"):format(shorten(flow), shorten(maxFlow), steam), colors.lightGray)
    local listTop = y1 + 3
    if #units == 0 then
        text(2, listTop, "NO TURBINE DATA", colors.orange)
        return "OFFLINE"
    end
    local rowsPer = 2
    local avail = y2 - listTop + 1
    local perPage = math.max(1, math.floor(avail / rowsPer))
    local pages = math.max(1, math.ceil(#units / perPage))
    if pages > 1 then
        perPage = math.max(1, math.floor((avail - 1) / rowsPer))
        pages = math.max(1, math.ceil(#units / perPage))
    end
    turbinePage = math.max(1, math.min(turbinePage, pages))
    local first = (turbinePage - 1) * perPage + 1
    local last = math.min(#units, first + perPage - 1)
    local nameWidth = math.max(10, width - 22)
    for index = first, last do
        local unit = units[index]
        local r = listTop + (index - first) * rowsPer
        if r + 1 <= y2 then
            text(2, r, tostring(unit.name or ("TURBINE " .. index)):sub(1, nameWidth), colors.purple)
            text(math.max(2, width - 19), r, ("%s FE/t"):format(shorten(unit.production)), colors.white)
            text(2, r + 1, ("FLOW %s/%s STEAM %d%%"):format(
                shorten(unit.flowRate), shorten(unit.maxFlowRate),
                tonumber(unit.steamPercent) or 0):sub(1, width - 2), colors.lightGray)
        end
    end
    if pages > 1 then
        drawPaging(y2, turbinePage, pages, function() turbinePage = turbinePage - 1 end,
            function() turbinePage = turbinePage + 1 end, width)
    end
    return source
end

local function drawMETab(y1, y2, width)
    local metrics, source = meSnapshot()
    local cells = {}
    if type(metrics.cells) == "table" then
        for _, cell in ipairs(metrics.cells) do
            if type(cell) == "table" then cells[#cells + 1] = cell end
        end
        if #cells == 0 then
            for _, cell in pairs(metrics.cells) do
                if type(cell) == "table" then cells[#cells + 1] = cell end
            end
        end
    end
    local total = tonumber(metrics.total) or 0
    local used = tonumber(metrics.used) or 0
    local percent = total > 0 and used / total * 100 or 0
    -- Group by cellType (generic, no hardcoded type list beyond labels).
    local groups = {}
    local order = {}
    for _, cell in ipairs(cells) do
        local rawType = cell.cellType or cell.type or "item"
        local key = tostring(rawType):lower()
        local group = groups[key]
        if not group then
            group = { key = key, label = cellTypeLabel(rawType), count = 0, used = 0, total = 0 }
            groups[key] = group
            order[#order + 1] = group
        end
        group.count = group.count + 1
        group.total = group.total + (tonumber(cell.totalBytes) or 0)
        if cell.usedKnown ~= false and tonumber(cell.usedBytes) ~= nil then
            group.used = group.used + tonumber(cell.usedBytes)
        end
    end
    table.sort(order, function(a, b) return a.total > b.total end)
    local y = y1
    local connectedText = metrics.connected and "CONNECTED" or "DISCONNECTED"
    text(2, y, ("ME %s  CELLS %d"):format(connectedText, #cells),
        metrics.connected and colors.lime or colors.red)
    y = y + 1
    for _, group in ipairs(order) do
        if y + 2 <= y2 - 8 then
            local groupPercent = group.total > 0 and group.used / group.total * 100 or 0
            text(2, y, ("%s x%d  %s/%s"):format(group.label, group.count,
                shorten(group.used), shorten(group.total)):sub(1, width - 10), colors.cyan)
            text(math.max(2, width - 7), y, ("%5.1f%%"):format(groupPercent), colors.white)
            bar(2, y + 1, math.max(8, width - 4), groupPercent, colors.cyan, 1)
            y = y + 3
        end
    end
    -- Top cells by usedBytes.
    local ranked = {}
    for _, cell in ipairs(cells) do
        if tonumber(cell.usedBytes) ~= nil then ranked[#ranked + 1] = cell end
    end
    table.sort(ranked, function(a, b)
        return (tonumber(a.usedBytes) or 0) > (tonumber(b.usedBytes) or 0)
    end)
    local perTop = 5
    local topPages = math.max(1, math.ceil(math.max(1, #ranked) / perTop))
    if #ranked == 0 then topPages = 1 end
    cellPage = math.max(1, math.min(cellPage, topPages))
    if y <= y2 - 3 then
        text(2, y, "TOP CELLS", colors.yellow)
        y = y + 1
    end
    if #ranked == 0 then
        if y <= y2 - 2 then
            text(2, y, total > 0 and "cells unavailable - aggregate only" or "NO CELL DATA", colors.orange)
            y = y + 1
        end
    else
        local first = (cellPage - 1) * perTop + 1
        local last = math.min(#ranked, first + perTop - 1)
        for index = first, last do
            if y <= y2 - 2 then
                local cell = ranked[index]
                local cellTotal = tonumber(cell.totalBytes) or 0
                local cellUsed = tonumber(cell.usedBytes) or 0
                local cellPercent = cellTotal > 0 and cellUsed / cellTotal * 100 or 0
                text(2, y, tostring(cell.item or ("CELL " .. index)):sub(1, math.max(10, width - 10)), colors.white)
                text(math.max(2, width - 7), y, ("%5.1f%%"):format(cellPercent), colors.lightGray)
                y = y + 1
            end
        end
        if topPages > 1 and y <= y2 - 2 then
            drawPaging(y, cellPage, topPages, function() cellPage = cellPage - 1 end,
                function() cellPage = cellPage + 1 end, width)
            y = y + 1
        end
    end
    local cellSource = metrics.cellSource
    if y <= y2 then
        text(2, y2 - 1, ("USED %s/%s  %5.1f%%"):format(shorten(used), shorten(total), percent), colors.white)
        local sourceLine = "SRC " .. source
        if type(cellSource) == "string" and cellSource ~= "" and cellSource ~= "none" then
            sourceLine = sourceLine .. " VIA " .. cellSource:sub(1, math.max(0, width - #sourceLine - 6))
        end
        text(2, y2, sourceLine:sub(1, width - 2), source == "OFFLINE" and colors.red
            or source == "STALE" and colors.orange or colors.lightGray)
    end
    return source
end

-- --------------------------------------------------------------------------
-- Frame.
-- --------------------------------------------------------------------------

local TABS = {
    { id = "energy", label = "ENERGY" },
    { id = "reactors", label = "REACTORS" },
    { id = "turbines", label = "TURBINES" },
    { id = "me", label = "ME" },
}

local function drawTabButtons(width)
    if width >= 78 then
        local tabWidth, gap = 16, 3
        local tabX = math.floor((width - tabWidth * 4 - gap * 3) / 2) + 1
        for i, definition in ipairs(TABS) do
            button(tabX + (i - 1) * (tabWidth + gap), 4, tabWidth, definition.label,
                function() tab = definition.id end, tab == definition.id)
        end
    else
        local tabWidth = math.max(10, math.floor((width - 6) / 2))
        local leftX = 3
        local rightX = width - tabWidth - 1
        button(leftX, 3, tabWidth, TABS[1].label, function() tab = TABS[1].id end, tab == TABS[1].id)
        button(rightX, 3, tabWidth, TABS[2].label, function() tab = TABS[2].id end, tab == TABS[2].id)
        button(leftX, 4, tabWidth, TABS[3].label, function() tab = TABS[3].id end, tab == TABS[3].id)
        button(rightX, 4, tabWidth, TABS[4].label, function() tab = TABS[4].id end, tab == TABS[4].id)
    end
end

local function draw()
    if not monitor then
        monitor = Peripherals.wrap("overviewMonitor")
        if monitor then pcall(monitor.setTextScale, 0.5) else return end
    end
    local width, height = monitor.getSize()
    buttons = {}
    if width < 44 or height < 15 then
        monitor.setBackgroundColor(colors.black)
        monitor.clear()
        monitor.setCursorPos(1, 1)
        monitor.setTextColor(colors.orange)
        monitor.setBackgroundColor(colors.black)
        monitor.write("Please enlarge monitor_1")
        monitor.setCursorPos(1, 2)
        monitor.setTextColor(colors.gray)
        monitor.write("Minimum: 44 x 15 characters")
        return
    end
    monitor.setBackgroundColor(colors.black)
    monitor.clear()

    fill(1, 1, width, 2, colors.gray)
    centered(1, 'ATM9 - OVERVIEW', colors.cyan, colors.gray)
    text(3, 2, moscowDateTime() .. " MSK", colors.white, colors.gray)
    local up = uptime()
    text(math.max(3, width - #up - 1), 2, up, colors.lightGray, colors.gray)

    drawTabButtons(width)

    local contentTop, contentBottom = 6, height - 1
    local source = "OFFLINE"
    if tab == "energy" then
        source = drawEnergyTab(contentTop, contentBottom, width) or source
    elseif tab == "reactors" then
        source = drawReactorsTab(contentTop, contentBottom, width) or source
    elseif tab == "turbines" then
        source = drawTurbinesTab(contentTop, contentBottom, width) or source
    else
        source = drawMETab(contentTop, contentBottom, width) or source
    end

    fill(1, height, width, height, colors.gray)
    text(2, height, hasRednet and "REDNET LINK ACTIVE" or "REDNET LINK OFFLINE",
        hasRednet and colors.lime or colors.red, colors.gray)
    local right = tostring(source or "OFFLINE")
    text(math.max(2, width - #right), height, right, colors.yellow, colors.gray)
end

local function handleTouch(x, y)
    for _, control in ipairs(buttons) do
        if y == control.y and x >= control.x and x < control.x + control.width then
            control.action()
            draw()
            return
        end
    end
end

refreshLocal()
draw()
local timer = os.startTimer(REFRESH_INTERVAL)
while true do
    local event, arg1, arg2, arg3 = os.pullEvent()
    if event == "timer" and arg1 == timer then
        MONITOR_NAME = Peripherals.get("overviewMonitor")
        MATRIX_NAME = Peripherals.get("matrix")
        REACTOR_NAME = Peripherals.get("reactor")
        ME_NAME = Peripherals.get("meBridge")
        monitor = Peripherals.wrap("overviewMonitor") or monitor
        if monitor then pcall(monitor.setTextScale, 0.5) end
        matrix = peripheral.wrap(MATRIX_NAME) or matrix
        reactor = peripheral.wrap(REACTOR_NAME) or reactor
        meBridge = findMEBridge()
        refreshLocal()
        draw()
        timer = os.startTimer(REFRESH_INTERVAL)
    elseif event == "monitor_touch" then
        handleTouch(arg2, arg3)
    elseif event == "monitor_resize" then
        draw()
    elseif event == "rednet_message" and arg3 == REACTOR_PROTOCOL and type(arg2) == "table" then
        local now = os.epoch("utc")
        local sender = tostring(arg1)
        if type(arg2.matrix) == "table" then
            local entry = normalizeEnergy(arg2.matrix, "MATRIX " .. sender)
            if entry then
                entry.peripheral = sender
                remoteMatrices = { entry }
                matrixHeartbeat = now
            end
        end
        if type(arg2.reactor) == "table" then
            local entry = normalizeReactor(arg2.reactor, sender)
            if entry then
                if not entry.peripheral then entry.peripheral = sender end
                remoteReactors = { entry }
                reactorHeartbeat = now
            end
        end
        draw()
    elseif event == "rednet_message" and arg3 == TURBINE_PROTOCOL and type(arg2) == "table" then
        local now = os.epoch("utc")
        local sender = tostring(arg1)
        if type(arg2.turbines) == "table" then
            local list = {}
            for index, raw in ipairs(arg2.turbines) do
                local entry = normalizeTurbine(raw, index, sender)
                if entry then list[#list + 1] = entry end
            end
            remoteTurbines = list
            turbineHeartbeat = now
        end
        if type(arg2.matrix) == "table" then
            local entry = normalizeEnergy(arg2.matrix, "MATRIX " .. sender)
            if entry then
                entry.peripheral = sender
                remoteMatrices = { entry }
                matrixHeartbeat = now
            end
        end
        if type(arg2.reactor) == "table" then
            local entry = normalizeReactor(arg2.reactor, sender)
            if entry then
                if not entry.peripheral then entry.peripheral = sender end
                remoteReactors = { entry }
                reactorHeartbeat = now
            end
        end
        draw()
    elseif event == "rednet_message" and arg3 == SNAPSHOT_PROTOCOL and type(arg2) == "table" then
        local now = os.epoch("utc")
        local sender = tostring(arg1)
        if type(arg2.matrices) == "table" then
            local list = {}
            for _, raw in ipairs(arg2.matrices) do
                local entry = normalizeEnergy(raw, "MATRIX " .. sender)
                if entry then list[#list + 1] = entry end
            end
            remoteMatrices = list
            matrixHeartbeat = now
        elseif type(arg2.matrix) == "table" then
            local entry = normalizeEnergy(arg2.matrix, "MATRIX " .. sender)
            if entry then
                entry.peripheral = sender
                remoteMatrices = { entry }
                matrixHeartbeat = now
            end
        end
        if type(arg2.reactors) == "table" then
            local list = {}
            for _, raw in ipairs(arg2.reactors) do
                local entry = normalizeReactor(raw, sender)
                if entry then list[#list + 1] = entry end
            end
            remoteReactors = list
            reactorHeartbeat = now
        elseif type(arg2.reactor) == "table" then
            local entry = normalizeReactor(arg2.reactor, sender)
            if entry then
                if not entry.peripheral then entry.peripheral = sender end
                remoteReactors = { entry }
                reactorHeartbeat = now
            end
        end
        if type(arg2.turbines) == "table" then
            local list = {}
            for index, raw in ipairs(arg2.turbines) do
                local entry = normalizeTurbine(raw, index, sender)
                if entry then list[#list + 1] = entry end
            end
            remoteTurbines = list
            turbineHeartbeat = now
        end
        if type(arg2.energyUnits) == "table" then
            local list = {}
            for index, raw in ipairs(arg2.energyUnits) do
                local entry = normalizeEnergy(raw, "UNIT " .. sender .. " " .. index)
                if entry then list[#list + 1] = entry end
            end
            remoteEnergyUnits = list
            energyHeartbeat = now
        end
        if type(arg2.boilers) == "table" then
            local list = {}
            for index, raw in ipairs(arg2.boilers) do
                local entry = normalizeBoiler(raw, index, sender)
                if entry then list[#list + 1] = entry end
            end
            remoteBoilers = list
            boilerHeartbeat = now
        end
        if type(arg2.fusion) == "table" then
            local list = {}
            if arg2.fusion.plasmaTemp ~= nil or arg2.fusion.plasmaTemperature ~= nil
                or arg2.fusion.plasma ~= nil or arg2.fusion.caseTemp ~= nil
                or arg2.fusion.name ~= nil then
                local entry = normalizeFusion(arg2.fusion, 1, sender)
                if entry then list[1] = entry end
            else
                for index, raw in ipairs(arg2.fusion) do
                    local entry = normalizeFusion(raw, index, sender)
                    if entry then list[#list + 1] = entry end
                end
            end
            remoteFusion = list
            fusionHeartbeat = now
        end
        draw()
    elseif event == "rednet_message" and arg3 == ME_STATUS_PROTOCOL and type(arg2) == "table" then
        local metrics = type(arg2.metrics) == "table" and arg2.metrics or {}
        remoteMEMetrics = {
            total = tonumber(metrics.total) or 0,
            used = tonumber(metrics.used) or 0,
            available = tonumber(metrics.available)
                or math.max(0, (tonumber(metrics.total) or 0) - (tonumber(metrics.used) or 0)),
            cells = normalizeMEcells(metrics.cells),
            cellSource = tostring(metrics.cellSource or arg2.cellSource or "rednet"),
        }
        meConnectedRemote = arg2.meConnected == true
        meHeartbeat = os.epoch("utc")
        draw()
    elseif event == Peripherals.RELOAD_EVENT
        or event == "peripheral" or event == "peripheral_detach" then
        MONITOR_NAME = Peripherals.get("overviewMonitor")
        MATRIX_NAME = Peripherals.get("matrix")
        REACTOR_NAME = Peripherals.get("reactor")
        ME_NAME = Peripherals.get("meBridge")
        monitor = Peripherals.wrap("overviewMonitor") or peripheral.wrap(MONITOR_NAME)
        if monitor then pcall(monitor.setTextScale, 0.5) end
        matrix = peripheral.wrap(MATRIX_NAME)
        reactor = peripheral.wrap(REACTOR_NAME)
        meBridge = findMEBridge()
        refreshLocal()
        draw()
    end
end
