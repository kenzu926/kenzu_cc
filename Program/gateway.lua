-- The only project service which owns an internet WebSocket connection.
local TICK_INTERVAL = 1
local REGISTER_EVENT = "kenzu_gateway_register"
local SEND_EVENT = "kenzu_gateway_send"
local MESSAGE_EVENT = "kenzu_gateway_message"
local STATUS_EVENT = "kenzu_gateway_status"

local scriptDirectory = fs.getDir(shell.getRunningProgram())
local WebSocketClient = dofile(fs.combine(scriptDirectory, "ws_client.lua"))
local server = WebSocketClient.new("gateway")
local services = {}

local function serviceList()
    local result = {}
    for service in pairs(services) do result[#result + 1] = service end
    table.sort(result)
    return result
end

local function announceServices()
    server:send({
        type = "service_announce",
        services = serviceList(),
    })
end

local function broadcastStatus()
    os.queueEvent(STATUS_EVENT, server:isConnected())
end

local function relay(service, payload)
    if type(service) ~= "string" or type(payload) ~= "table" then return end
    local isNew = not services[service]
    services[service] = true
    if isNew then announceServices() end
    local message = {}
    for key, value in pairs(payload) do message[key] = value end
    message.service = service
    server:send(message)
end

local function drawStatus()
    term.clear()
    term.setCursorPos(1, 1)
    print("Kenzu WebSocket Gateway")
    print("Web: " .. (server:isConnected() and "CONNECTED" or "OFFLINE"))
    local registered = serviceList()
    print("Services: " .. (#registered > 0 and table.concat(registered, ", ") or "waiting"))
    if server.lastError then print("Last error: " .. tostring(server.lastError)) end
end

server:connect()
broadcastStatus()
drawStatus()
local timer = os.startTimer(TICK_INTERVAL)

while true do
    local event, arg1, arg2, arg3 = os.pullEvent()
    local serverEvent, message = server:handleEvent(event, arg1, arg2, arg3)

    if serverEvent == "connected" then
        announceServices()
        broadcastStatus()
        drawStatus()
    elseif serverEvent == "disconnected" then
        broadcastStatus()
        drawStatus()
    elseif serverEvent == "message" and type(message) == "table" then
        os.queueEvent(MESSAGE_EVENT, message.targetService or "*", message)
    end

    if event == REGISTER_EVENT and type(arg1) == "string" then
        local isNew = not services[arg1]
        services[arg1] = true
        os.queueEvent(STATUS_EVENT, server:isConnected())
        if isNew then announceServices() end
        drawStatus()
    elseif event == SEND_EVENT then
        relay(arg1, arg2)
    elseif event == "timer" and arg1 == timer then
        server:connect()
        broadcastStatus()
        drawStatus()
        timer = os.startTimer(TICK_INTERVAL)
    end
end
