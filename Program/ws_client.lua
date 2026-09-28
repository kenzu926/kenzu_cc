-- Shared asynchronous WebSocket client for CC:Tweaked services.
local Client = {}
Client.__index = Client
-- The native request already has its own timeout. This larger guard prevents
-- opening replacement sockets while CC:Tweaked is still cleaning up a request.
local CONNECT_TIMEOUT_MS = 45 * 1000
local KEEPALIVE_INTERVAL_MS = 5 * 1000
local STALE_CONNECTION_MS = 20 * 1000

function Client.new(role)
    settings.define("kenzu.serverUrl", {
        description = "Kenzu Control WebSocket URL",
        default = "ws://93.170.246.220:3000/ws",
        type = "string",
    })
    settings.define("kenzu.serverToken", {
        description = "Kenzu Control access token",
        default = "",
        type = "string",
    })
    settings.load("server.settings")

    local baseUrl = settings.get("kenzu.serverUrl")
    local separator = baseUrl:find("?", 1, true) and "&" or "?"
    -- CC:Tweaked identifies asynchronous WebSocket events by URL. Every
    -- service on the same computer therefore needs a distinct URL, otherwise
    -- multiple multishell tabs can claim the same websocket_success event.
    local connectionUrl = baseUrl .. separator .. "client="
        .. tostring(role) .. "-" .. tostring(os.getComputerID())

    return setmetatable({
        role = role,
        url = connectionUrl,
        token = settings.get("kenzu.serverToken"),
        socket = nil,
        connecting = false,
        lastAttempt = 0,
        lastPing = 0,
        lastReceived = 0,
        heartbeatConfirmed = false,
        lastError = nil,
    }, Client)
end

function Client:isConnected()
    return self.socket ~= nil
end

function Client:connect()
    if not http then
        return false
    end

    local now = os.epoch("utc")
    if self.socket then
        if self.heartbeatConfirmed and self.lastReceived > 0
            and now - self.lastReceived >= STALE_CONNECTION_MS then
            pcall(self.socket.close)
            self.socket = nil
            self.connecting = false
            self.lastError = "WebSocket heartbeat timed out"
            self.lastAttempt = 0
        elseif now - self.lastPing >= KEEPALIVE_INTERVAL_MS then
            self.lastPing = now
            self:send({ type = "ping", sentAt = now })
        end
        return false
    end

    if self.connecting and now - self.lastAttempt >= CONNECT_TIMEOUT_MS then
        self.connecting = false
        self.lastError = "WebSocket connection timed out"
    end
    if self.connecting then
        return false
    end
    if now - self.lastAttempt < 5000 then
        return false
    end

    self.lastAttempt = now
    local requestOk, started, requestError = pcall(http.websocketAsync, {
        url = self.url,
        timeout = 10,
    })
    if not requestOk then
        -- nativeWebsocket throws when the configured connection limit is full.
        -- Keep the local service alive and retry later instead of crashing it.
        self.lastError = tostring(started)
        self.connecting = false
        if self.lastError:find("Too many websockets", 1, true) then
            -- Give abandoned native requests time to expire and release slots.
            self.lastAttempt = now + 25 * 1000
        end
        return false
    end
    if not started then
        self.lastError = requestError or "WebSocket request rejected"
        self.connecting = false
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
        self.lastReceived = os.epoch("utc")
        self.lastPing = self.lastReceived
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
        self.lastReceived = os.epoch("utc")
        local decoded, decodeError = textutils.unserializeJSON(arg2)
        if not decoded then
            self.lastError = "Invalid server JSON: " .. tostring(decodeError)
            return "invalid_message"
        end
        if decoded.type == "auth_error" then
            self.lastError = tostring(decoded.message or "Invalid access token")
            if self.socket then pcall(self.socket.close) end
            self.socket = nil
            self.connecting = false
            return "disconnected"
        end
        if decoded.type == "pong" then
            self.heartbeatConfirmed = true
            return "pong", decoded
        end
        return "message", decoded
    end
end

return Client
