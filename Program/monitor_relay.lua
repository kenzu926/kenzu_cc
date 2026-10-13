-- Streams attached monitor screens to the website (read-only frames) and
-- injects touch events coming from the website as local monitor_touch events.
-- Runs on any computer with monitors; needs no reboot to reconfigure.
local CAPTURE_INTERVAL = 1
local RESEND_INTERVAL_MS = 5 * 1000

local scriptDirectory = fs.getDir(shell.getRunningProgram())
local GatewayClient = dofile(fs.combine(scriptDirectory, "gateway_client.lua"))
local SafeConsole = dofile(fs.combine(scriptDirectory, "console.lua"))
local Peripherals
if fs.exists(fs.combine(scriptDirectory, "peripherals.lua")) then
    Peripherals = dofile(fs.combine(scriptDirectory, "peripherals.lua"))
end
local server = GatewayClient.new("monitor")

local function hasMonitorType(name)
    if not peripheral.hasType then return true end
    local ok, result = pcall(peripheral.hasType, name, "monitor")
    return ok and result == true
end

local function findMonitors()
    local seen, result = {}, {}
    local function add(name)
        if type(name) == "string" and name ~= "" and not seen[name]
            and peripheral.isPresent(name) and hasMonitorType(name) then
            seen[name] = true
            result[#result + 1] = name
        end
    end
    if Peripherals then
        for _, key in ipairs({ "monitor", "overviewMonitor", "plansMonitor" }) do
            local ok, name = pcall(Peripherals.get, key)
            if ok then add(name) end
        end
    end
    for _, name in ipairs(peripheral.getNames()) do add(name) end
    table.sort(result)
    return result
end

local function paletteSnapshot(device)
    if not device.getPaletteColor then return nil end
    local palette = {}
    for index = 0, 15 do
        local ok, r, g, b = pcall(device.getPaletteColor, 2 ^ index)
        if not ok or type(r) ~= "number" then return nil end
        palette[index + 1] = {
            math.floor(r * 255 + 0.5),
            math.floor(g * 255 + 0.5),
            math.floor(b * 255 + 0.5),
        }
    end
    return palette
end

local signatures = {}
local lastSentAt = {}

local function captureFrame(name)
    local device = peripheral.wrap(name)
    if not device or not device.getLine or not device.getSize then return nil end
    local okSize, width, height = pcall(device.getSize)
    if not okSize or type(width) ~= "number" or type(height) ~= "number" then return nil end
    width = math.max(1, math.min(300, width))
    height = math.max(1, math.min(200, height))
    local lines, signatureParts = {}, {}
    for y = 1, height do
        local ok, textValue, fgValue, bgValue = pcall(device.getLine, y)
        if not ok then return nil end
        lines[y] = {
            text = tostring(textValue or ""),
            fg = tostring(fgValue or ""),
            bg = tostring(bgValue or ""),
        }
        signatureParts[#signatureParts + 1] =
            tostring(textValue or "") .. tostring(fgValue or "") .. tostring(bgValue or "")
    end
    local cursorX, cursorY = 1, 1
    if device.getCursorPos then
        local ok, x, y = pcall(device.getCursorPos)
        if ok and type(x) == "number" then cursorX, cursorY = x, y end
    end
    local cursorBlink = false
    if device.getCursorBlink then
        local ok, blink = pcall(device.getCursorBlink)
        if ok then cursorBlink = blink == true end
    end
    signatureParts[#signatureParts + 1] =
        table.concat({ cursorX, cursorY, cursorBlink and 1 or 0 }, ":")
    return {
        type = "monitor_frame",
        monitor = name,
        computerId = os.getComputerID(),
        label = os.getComputerLabel(),
        width = width,
        height = height,
        cursorX = cursorX,
        cursorY = cursorY,
        cursorBlink = cursorBlink,
        lines = lines,
        palette = paletteSnapshot(device),
        sentAt = os.epoch("utc"),
    }, table.concat(signatureParts, "|")
end

local function sendAll(force)
    local now = os.epoch("utc")
    for _, name in ipairs(findMonitors()) do
        local frame, signature = captureFrame(name)
        if frame then
            if force or signature ~= signatures[name]
                or now - (lastSentAt[name] or 0) >= RESEND_INTERVAL_MS then
                if server:isConnected() then server:send(frame) end
                signatures[name] = signature
                lastSentAt[name] = now
            end
        end
    end
end

local function statusText()
    local names = findMonitors()
    local lines = { "Monitor relay: " .. #names }
    for _, name in ipairs(names) do lines[#lines + 1] = "- " .. name end
    lines[#lines + 1] = "Gateway: " .. (server:isConnected() and "CONNECTED" or "OFFLINE")
    return table.concat(lines, "\n")
end

local function handleTouch(message)
    local name = tostring(message.monitor or "")
    if name == "" or not peripheral.isPresent(name) or not hasMonitorType(name) then return end
    local device = peripheral.wrap(name)
    if not device or not device.getSize then return end
    local _, width, height = pcall(device.getSize)
    local x = math.floor(tonumber(message.x) or 0)
    local y = math.floor(tonumber(message.y) or 0)
    if type(width) == "number" then x = math.max(1, math.min(width, x)) end
    if type(height) == "number" then y = math.max(1, math.min(height, y)) end
    if x >= 1 and y >= 1 then
        os.queueEvent("monitor_touch", name, x, y)
        sendAll(true)
    end
end

server:connect()
sendAll(true)
local timer = os.startTimer(CAPTURE_INTERVAL)

while true do
    local event, arg1, arg2, arg3 = os.pullEvent()
    local serverEvent, message = server:handleEvent(event, arg1, arg2, arg3)

    if serverEvent == "connected" then
        sendAll(true)
    elseif serverEvent == "message" and type(message) == "table" then
        if message.type == "monitor_touch" then
            handleTouch(message)
        elseif message.type == "console_command"
            and (message.target == "monitor" or message.target == tostring(os.getComputerID())) then
            local ok, output = SafeConsole.execute(message.command, statusText)
            server:send({
                type = "console_output",
                requestId = message.requestId,
                target = "monitor",
                computerId = os.getComputerID(),
                ok = ok,
                output = output,
            })
        elseif message.type == "peripherals_update" and Peripherals then
            Peripherals.applyRemote(message.peripherals)
            sendAll(true)
        end
    end

    if event == "timer" and arg1 == timer then
        server:connect()
        sendAll(false)
        timer = os.startTimer(CAPTURE_INTERVAL)
    elseif event == "monitor_touch" or event == "monitor_resize"
        or event == "peripheral" or event == "peripheral_detach"
        or (Peripherals and event == Peripherals.RELOAD_EVENT) then
        sendAll(true)
    end
end
