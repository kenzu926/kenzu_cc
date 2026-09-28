-- Local IPC client used by project services. gateway.lua owns the only WebSocket.
local Client = {}
Client.__index = Client

local REGISTER_EVENT = "kenzu_gateway_register"
local SEND_EVENT = "kenzu_gateway_send"
local MESSAGE_EVENT = "kenzu_gateway_message"
local STATUS_EVENT = "kenzu_gateway_status"
local REGISTER_INTERVAL_MS = 5000

function Client.new(role)
    return setmetatable({
        role = role,
        connected = false,
        lastRegister = 0,
    }, Client)
end

function Client:isConnected()
    return self.connected
end

function Client:connect()
    local now = os.epoch("utc")
    if now - self.lastRegister >= REGISTER_INTERVAL_MS then
        self.lastRegister = now
        os.queueEvent(REGISTER_EVENT, self.role)
    end
    return self.connected
end

function Client:send(payload)
    if type(payload) ~= "table" then return false end
    os.queueEvent(SEND_EVENT, self.role, payload)
    return self.connected
end

function Client:handleEvent(event, arg1, arg2)
    if event == STATUS_EVENT then
        local wasConnected = self.connected
        self.connected = arg1 == true
        if self.connected and not wasConnected then return "connected" end
        if not self.connected and wasConnected then return "disconnected" end
        return "status"
    end

    if event == MESSAGE_EVENT and (arg1 == self.role or arg1 == "*")
        and type(arg2) == "table" then
        return "message", arg2
    end
end

return Client
