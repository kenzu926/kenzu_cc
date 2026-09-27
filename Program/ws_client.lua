-- Shared asynchronous WebSocket client for CC:Tweaked services.
local Client = {}
Client.__index = Client

function Client.new(role)
    settings.define("kenzu.serverUrl", {
        description = "Kenzu Control WebSocket URL",
        default = "ws://127.0.0.1:3000/ws",
        type = "string",
    })
    settings.define("kenzu.serverToken", {
        description = "Kenzu Control access token",
        default = "",
        type = "string",
    })
    settings.load("server.settings")

    return setmetatable({
        role = role,
        url = settings.get("kenzu.serverUrl"),
        token = settings.get("kenzu.serverToken"),
        socket = nil,
        connecting = false,
        lastAttempt = 0,
        lastError = nil,
    }, Client)
end

function Client:isConnected()
    return self.socket ~= nil
end

function Client:connect()
    if self.socket or self.connecting or not http then
        return false
    end

    local now = os.epoch("utc")
    if now - self.lastAttempt < 5000 then
        return false
    end

    self.lastAttempt = now
    local started, requestError = http.websocketAsync(self.url)
    if not started then
        self.lastError = requestError or "WebSocket request rejected"
        return false
    end

    self.connecting = true
    return true
end

function Client:send(payload)
    if not self.socket then
        return false
    end

    local encoded = textutils.serializeJSON(payload)
    local sent, sendError = pcall(self.socket.send, encoded)
    if not sent then
        self.lastError = tostring(sendError)
        self.socket = nil
        self.connecting = false
        return false
    end

    return true
end

function Client:handleEvent(event, arg1, arg2, arg3)
    if event == "websocket_success" and arg1 == self.url then
        self.socket = arg2
        self.connecting = false
        self.lastError = nil
        self:send({
            type = "hello",
            role = self.role,
            token = self.token,
            computerId = os.getComputerID(),
            label = os.getComputerLabel(),
        })
        return "connected"
    end

    if event == "websocket_failure" and arg1 == self.url then
        self.socket = nil
        self.connecting = false
        self.lastError = tostring(arg2)
        return "disconnected"
    end

    if event == "websocket_closed" and arg1 == self.url then
        self.socket = nil
        self.connecting = false
        self.lastError = tostring(arg2 or "Connection closed")
        return "disconnected"
    end

    if event == "websocket_message" and arg1 == self.url and not arg3 then
        local decoded, decodeError = textutils.unserializeJSON(arg2)
        if not decoded then
            self.lastError = "Invalid server JSON: " .. tostring(decodeError)
            return "invalid_message"
        end
        return "message", decoded
    end
end

return Client
