-- Interactive CraftOS terminal mirrored to the Kenzu Control website.
-- This runs in its own multishell tab, so reactor automation remains isolated.
local scriptDirectory = fs.getDir(shell.getRunningProgram())
local WebSocketClient = dofile(fs.combine(scriptDirectory, "gateway_client.lua"))
local server = WebSocketClient.new("terminal")
local TERMINAL_FRAME_PROTOCOL = "kenzu_cc.terminal.frame"
local TERMINAL_INPUT_PROTOCOL = "kenzu_cc.terminal.input"

local FRAME_INTERVAL = 0.20
local parent = term.current()
local width, height = parent.getSize()
local terminal = window.create(parent, 1, 1, width, height, true)
local previousTerminal = term.redirect(terminal)
local shellCoroutine
local shellFilter
local lastFrameSignature = nil
local lastFrameAt = 0

local function openWirelessModem()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            local modem = peripheral.wrap(name)
            if modem.isWireless and modem.isWireless() then
                rednet.open(name)
                return true
            end
        end
    end
    return false
end

local hasRednet = openWirelessModem()

local function startShell()
    shellCoroutine = coroutine.create(function()
        shell.run("shell")
    end)
    local ok, result = coroutine.resume(shellCoroutine)
    if not ok then
        term.setTextColor(colors.red)
        print(tostring(result))
        term.setTextColor(colors.white)
        shellFilter = nil
    else
        shellFilter = result
    end
end

local function resumeShell(event)
    if not shellCoroutine or coroutine.status(shellCoroutine) == "dead" then
        startShell()
    end
    if not event or not event[1] then return end
    if shellFilter and shellFilter ~= event[1] and event[1] ~= "terminate" then return end

    local ok, result = coroutine.resume(shellCoroutine, table.unpack(event))
    if not ok then
        term.setCursorBlink(false)
        term.setTextColor(colors.red)
        print(tostring(result))
        term.setTextColor(colors.white)
        startShell()
    else
        shellFilter = result
        if coroutine.status(shellCoroutine) == "dead" then startShell() end
    end
end

local function paletteSnapshot()
    local palette = {}
    for index = 0, 15 do
        local red, green, blue = terminal.getPaletteColor(2 ^ index)
        palette[index + 1] = {
            math.floor(red * 255 + 0.5),
            math.floor(green * 255 + 0.5),
            math.floor(blue * 255 + 0.5),
        }
    end
    return palette
end

local function frameSnapshot()
    local lines = {}
    local signatureParts = {}
    width, height = terminal.getSize()
    for y = 1, height do
        local text, foreground, background = terminal.getLine(y)
        lines[y] = { text = text, fg = foreground, bg = background }
        signatureParts[#signatureParts + 1] = text .. foreground .. background
    end
    local cursorX, cursorY = terminal.getCursorPos()
    local cursorBlink = terminal.getCursorBlink()
    signatureParts[#signatureParts + 1] = table.concat({ cursorX, cursorY, cursorBlink and 1 or 0 }, ":")
    return {
        type = "terminal_frame",
        width = width,
        height = height,
        cursorX = cursorX,
        cursorY = cursorY,
        cursorBlink = cursorBlink,
        lines = lines,
        palette = paletteSnapshot(),
        computerId = os.getComputerID(),
        label = os.getComputerLabel(),
    }, table.concat(signatureParts, "|")
end

local function sendFrame(force)
    local frame, signature = frameSnapshot()
    local now = os.epoch("utc")
    if force or signature ~= lastFrameSignature or now - lastFrameAt >= 4000 then
        if server:isConnected() then server:send(frame) end
        if hasRednet then rednet.broadcast(frame, TERMINAL_FRAME_PROTOCOL) end
        lastFrameSignature = signature
        lastFrameAt = now
    end
end

local function keyCode(name)
    if type(name) ~= "string" then return nil end
    return keys[name]
end

local function handleRemoteInput(message)
    local eventName = message.event
    if eventName == "key" or eventName == "key_up" then
        local code = keyCode(message.key)
        if code then resumeShell({ eventName, code, message.held == true }) end
    elseif eventName == "char" and type(message.value) == "string" then
        resumeShell({ "char", message.value:sub(1, 1) })
    elseif eventName == "paste" and type(message.value) == "string" then
        resumeShell({ "paste", message.value:sub(1, 4096) })
    elseif eventName == "terminate" then
        resumeShell({ "terminate" })
    elseif eventName == "mouse_click" or eventName == "mouse_up"
        or eventName == "mouse_drag" or eventName == "mouse_scroll" then
        local button = tonumber(message.button)
        local x = tonumber(message.x)
        local y = tonumber(message.y)
        if button and x and y then
            resumeShell({ eventName, button, math.floor(x), math.floor(y) })
        end
    end
    sendFrame(true)
end

startShell()
server:connect()
local frameTimer = os.startTimer(FRAME_INTERVAL)

while true do
    local event = table.pack(os.pullEventRaw())
    local serverEvent, serverMessage = server:handleEvent(table.unpack(event, 1, event.n))

    if serverEvent == "connected" then
        lastFrameSignature = nil
        sendFrame(true)
    elseif serverEvent == "message" and type(serverMessage) == "table"
        and serverMessage.type == "terminal_input" then
        handleRemoteInput(serverMessage)
    end

    if event[1] == "timer" and event[2] == frameTimer then
        server:connect()
        sendFrame(false)
        frameTimer = os.startTimer(FRAME_INTERVAL)
    elseif event[1] == "term_resize" then
        width, height = parent.getSize()
        terminal.reposition(1, 1, width, height)
        resumeShell({ "term_resize" })
        sendFrame(true)
    elseif event[1] == "rednet_message" and event[4] == TERMINAL_INPUT_PROTOCOL
        and type(event[3]) == "table"
        and tostring(event[3].target) == tostring(os.getComputerID()) then
        handleRemoteInput(event[3])
    elseif type(event[1]) == "string" and event[1]:find("^kenzu_gateway_") then
        -- Gateway IPC events belong to project services, not the nested shell.
    elseif event[1] ~= "websocket_success"
        and event[1] ~= "websocket_failure"
        and event[1] ~= "websocket_message"
        and event[1] ~= "websocket_closed" then
        resumeShell(event)
    end
end

term.redirect(previousTerminal)
