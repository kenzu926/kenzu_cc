-- Remote file access for the website: list / read / write text files.
-- Strictly jailed to this computer's install directory: ".." segments can
-- never escape the base directory. Text only, 32 KiB per transfer.
local HEARTBEAT_INTERVAL = 5
local MAX_BYTES = 32 * 1024
local MAX_ENTRIES = 200

local scriptDirectory = fs.getDir(shell.getRunningProgram())
local GatewayClient = dofile(fs.combine(scriptDirectory, "gateway_client.lua"))
local SafeConsole = dofile(fs.combine(scriptDirectory, "console.lua"))
local server = GatewayClient.new("files")

local function resolvePath(userPath)
    local parts = {}
    for segment in tostring(userPath or ""):gmatch("[^/\\]+") do
        if segment == "." or segment == "" then
            -- Skip.
        elseif segment == ".." then
            parts[#parts] = nil
        else
            parts[#parts + 1] = segment
        end
    end
    local relative = table.concat(parts, "/")
    return fs.combine(scriptDirectory, relative), relative
end

local function reply(requestId, op, ok, extra)
    local response = {
        type = "file_result",
        requestId = requestId,
        op = op,
        ok = ok,
        computerId = os.getComputerID(),
    }
    if type(extra) == "table" then
        for key, value in pairs(extra) do response[key] = value end
    end
    server:send(response)
end

-- Files holding the master token are never exposed remotely.
local function isProtected(relative)
    local lower = tostring(relative or ""):lower()
    return lower == "server.settings" or lower:match("%.token$") ~= nil
end

local function handleList(message)
    local path, relative = resolvePath(message.path)
    if not fs.exists(path) then
        reply(message.requestId, "file_list", false, { error = "Not found: " .. relative })
        return
    end
    if not fs.isDir(path) then
        reply(message.requestId, "file_list", false, { error = "Not a directory: " .. relative })
        return
    end
    local names = fs.list(path)
    table.sort(names)
    local entries = {}
    for _, name in ipairs(names) do
        if #entries >= MAX_ENTRIES then break end
        if not isProtected(name) then
            local full = fs.combine(path, name)
            local isDir = fs.isDir(full)
            entries[#entries + 1] = {
                name = name,
                isDir = isDir,
                size = isDir and 0 or fs.getSize(full),
            }
        end
    end
    reply(message.requestId, "file_list", true, {
        path = relative,
        entries = entries,
        truncated = #names > MAX_ENTRIES,
    })
end

local function handleRead(message)
    local path, relative = resolvePath(message.path)
    if isProtected(relative) then
        reply(message.requestId, "file_read", false, { error = "Protected file" })
        return
    end
    if not fs.exists(path) then
        reply(message.requestId, "file_read", false, { error = "Not found: " .. relative })
        return
    end
    if fs.isDir(path) then
        reply(message.requestId, "file_read", false, { error = "Is a directory: " .. relative })
        return
    end
    if fs.getSize(path) > 256 * 1024 then
        reply(message.requestId, "file_read", false, { error = "File too large for remote view" })
        return
    end
    local handle = fs.open(path, "r")
    if not handle then
        reply(message.requestId, "file_read", false, { error = "Cannot open: " .. relative })
        return
    end
    local content = handle.readAll() or ""
    handle.close()
    local truncated = false
    if #content > MAX_BYTES then
        content = content:sub(1, MAX_BYTES)
        truncated = true
    end
    reply(message.requestId, "file_read", true, {
        path = relative,
        content = content,
        truncated = truncated,
    })
end

local function handleWrite(message)
    local path, relative = resolvePath(message.path)
    if type(message.content) ~= "string" then
        reply(message.requestId, "file_write", false, { error = "Missing content" })
        return
    end
    if #message.content > MAX_BYTES then
        reply(message.requestId, "file_write", false, { error = "Content exceeds 32 KiB" })
        return
    end
    if fs.exists(path) and fs.isDir(path) then
        reply(message.requestId, "file_write", false, { error = "Is a directory: " .. relative })
        return
    end
    local handle, openError = fs.open(path, "w")
    if not handle then
        reply(message.requestId, "file_write", false, { error = tostring(openError or "Cannot write") })
        return
    end
    handle.write(message.content)
    handle.close()
    reply(message.requestId, "file_write", true, { path = relative })
end

local function statusText()
    return table.concat({
        "Service: remote files",
        "Base: " .. scriptDirectory,
        "Limits: 32 KiB, jailed to install dir",
        "Web: " .. (server:isConnected() and "CONNECTED" or "OFFLINE"),
    }, "\n")
end

server:connect()
local timer = os.startTimer(HEARTBEAT_INTERVAL)

while true do
    local event, arg1, arg2, arg3 = os.pullEvent()
    local serverEvent, message = server:handleEvent(event, arg1, arg2, arg3)

    if serverEvent == "message" and type(message) == "table" then
        local targeted = message.target == nil
            or tostring(message.target) == tostring(os.getComputerID())
        if targeted then
            if message.type == "file_list" then
                handleList(message)
            elseif message.type == "file_read" then
                handleRead(message)
            elseif message.type == "file_write" then
                handleWrite(message)
            elseif message.type == "console_command"
                and (message.target == "files" or message.target == tostring(os.getComputerID())) then
                local ok, output = SafeConsole.execute(message.command, statusText)
                server:send({
                    type = "console_output",
                    requestId = message.requestId,
                    target = "files",
                    computerId = os.getComputerID(),
                    ok = ok,
                    output = output,
                })
            end
        end
    end

    if event == "timer" and arg1 == timer then
        server:connect()
        timer = os.startTimer(HEARTBEAT_INTERVAL)
    end
end
