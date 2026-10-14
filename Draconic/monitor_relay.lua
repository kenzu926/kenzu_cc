-- Streams attached monitor screens to the website (read-only frames) and
-- injects touch events coming from the website as local monitor_touch events.
-- CC:Tweaked monitors have no getLine(), so frames come from JSON files
-- written by Screen.commit() in the monitor apps (overview/plans/reactor).
-- Runs on any computer with monitors; needs no reboot to reconfigure.
local CAPTURE_INTERVAL = 1
local RESEND_INTERVAL_MS = 5 * 1000

local scriptDirectory = fs.getDir(shell.getRunningProgram())
local GatewayClient = dofile(fs.combine(scriptDirectory, "gateway_client.lua"))
local SafeConsole = dofile(fs.combine(scriptDirectory, "console.lua"))
local Screen = dofile(fs.combine(scriptDirectory, "screen.lua"))
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

local signatures = {}
local lastSentAt = {}

local function sendAll(force)
    local now = os.epoch("utc")
    for _, name in ipairs(findMonitors()) do
        local frame, raw = Screen.readFrame(name)
        if frame and raw then
            if force or raw ~= signatures[name]
                or now - (lastSentAt[name] or 0) >= RESEND_INTERVAL_MS then
                if server:isConnected() then
                    server:send({
                        type = "monitor_frame",
                        monitor = name,
                        computerId = os.getComputerID(),
                        label = os.getComputerLabel(),
                        width = frame.width,
                        height = frame.height,
                        cursorX = frame.cursorX or 1,
                        cursorY = frame.cursorY or 1,
                        cursorBlink = frame.cursorBlink == true,
                        lines = frame.lines,
                        palette = nil,
                        sentAt = now,
                    })
                end
                signatures[name] = raw
                lastSentAt[name] = now
            end
        end
    end
end

local function statusText()
    local lines = {}
    for _, name in ipairs(findMonitors()) do
        local frame = Screen.readFrame(name)
        lines[#lines + 1] = "- " .. name .. (frame and " (frame OK)" or " (no frame yet)")
    end
    if #lines == 0 then lines[1] = "No monitors attached" end
    lines[#lines + 1] = "Gateway: " .. (server:isConnected() and "CONNECTED" or "OFFLINE")
    return "Monitor relay:\n" .. table.concat(lines, "\n")
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
