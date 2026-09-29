-- Displays the shared web todo list on monitor_2.
local MONITOR_NAME = "monitor_2"
local CHATBOX_NAME = "chatBox_0"
local REFRESH_INTERVAL = 2

local scriptDirectory = fs.getDir(shell.getRunningProgram())
local cacheFile = fs.combine(scriptDirectory, "plans.cache")
local GatewayClient = dofile(fs.combine(scriptDirectory, "gateway_client.lua"))
local server = GatewayClient.new("plans")

local plans = {}
local lastUpdate = nil

local function loadCache()
    if not fs.exists(cacheFile) then return end
    local handle = fs.open(cacheFile, "r")
    if not handle then return end
    local decoded = textutils.unserializeJSON(handle.readAll())
    handle.close()
    if type(decoded) == "table" and type(decoded.plans) == "table" then
        plans = decoded.plans
        lastUpdate = decoded.updatedAt
    end
end

local function saveCache()
    local handle = fs.open(cacheFile, "w")
    if not handle then return end
    handle.write(textutils.serializeJSON({ plans = plans, updatedAt = lastUpdate }))
    handle.close()
end

local function getMonitor()
    local monitor = peripheral.wrap(MONITOR_NAME)
    if monitor then monitor.setTextScale(0.5) end
    return monitor
end

local function writeAt(monitor, x, y, value, foreground, background)
    local width, height = monitor.getSize()
    if y < 1 or y > height or x > width then return end
    monitor.setCursorPos(math.max(1, x), y)
    monitor.setTextColor(foreground or colors.white)
    monitor.setBackgroundColor(background or colors.black)
    monitor.write(tostring(value):sub(1, math.max(0, width - x + 1)))
end

local function fill(monitor, y, color)
    local width = monitor.getSize()
    monitor.setCursorPos(1, y)
    monitor.setBackgroundColor(color)
    monitor.write(string.rep(" ", width))
end

local function centered(monitor, y, value, foreground, background)
    local width = monitor.getSize()
    value = tostring(value)
    writeAt(monitor, math.max(1, math.floor((width - #value) / 2) + 1), y,
        value, foreground, background)
end

local function wrap(value, width)
    local result = {}
    local line = ""
    for word in tostring(value):gmatch("%S+") do
        if #word > width then
            if #line > 0 then result[#result + 1], line = line, "" end
            while #word > width do
                result[#result + 1] = word:sub(1, width)
                word = word:sub(width + 1)
            end
        end
        if #line == 0 then
            line = word
        elseif #line + #word + 1 <= width then
            line = line .. " " .. word
        else
            result[#result + 1] = line
            line = word
        end
    end
    if #line > 0 then result[#result + 1] = line end
    if #result == 0 then result[1] = "" end
    return result
end

local function sortedPlans()
    local result = {}
    for _, plan in ipairs(plans) do result[#result + 1] = plan end
    table.sort(result, function(left, right)
        if (left.done == true) ~= (right.done == true) then return left.done ~= true end
        return (tonumber(left.number) or 0) < (tonumber(right.number) or 0)
    end)
    return result
end

local function draw()
    local monitor = getMonitor()
    if not monitor then return end
    local width, height = monitor.getSize()
    monitor.setBackgroundColor(colors.black)
    monitor.clear()

    fill(monitor, 1, colors.gray)
    fill(monitor, 2, colors.gray)
    fill(monitor, 3, colors.gray)
    centered(monitor, 2, "BASE PLANS", colors.cyan, colors.gray)

    local pending = 0
    for _, plan in ipairs(plans) do
        if plan.done ~= true then pending = pending + 1 end
    end
    writeAt(monitor, 2, 4, ("OPEN %d   DONE %d   TOTAL %d")
        :format(pending, #plans - pending, #plans), colors.lightGray)

    local y = 6
    local availableWidth = math.max(8, width - 13)
    for index, plan in ipairs(sortedPlans()) do
        if y > height - 2 then break end
        local done = plan.done == true
        local marker = done and "[x]" or "[ ]"
        local color = done and colors.gray or colors.white
        writeAt(monitor, 2, y, marker, done and colors.lime or colors.yellow)
        writeAt(monitor, 6, y, ("#%s"):format(tostring(plan.number or "?")), colors.lightBlue)
        local label = plan.translationPending and "Translation pending" or plan.text
        local lines = wrap(label or "Unnamed task", availableWidth)
        for lineIndex, line in ipairs(lines) do
            if y > height - 2 then break end
            writeAt(monitor, 13, y, line, color)
            y = y + 1
            if lineIndex == 1 and #lines > 1 then
                writeAt(monitor, 2, y, " |", colors.gray)
            end
        end
        if index < #plans then y = y + 1 end
    end

    if #plans == 0 then
        centered(monitor, math.max(7, math.floor(height / 2)),
            "No plans yet", colors.lightGray)
    elseif y > height - 2 then
        writeAt(monitor, math.max(2, width - 18), height - 1,
            "More on website...", colors.orange)
    end

    fill(monitor, height, colors.gray)
    writeAt(monitor, 2, height,
        server:isConnected() and "WEB LINK ONLINE" or "CACHED / OFFLINE",
        server:isConnected() and colors.lime or colors.orange, colors.gray)
end

local helpMessages = {
    ".plan add <название> — добавить план",
    ".plan list — показать список",
    ".plan complete <id> — выполнить",
    ".plan delete <id> — удалить",
}

local function getChatBox()
    return peripheral.wrap(CHATBOX_NAME) or peripheral.find("chatBox")
end

local function sendChat(messages, username)
    local chatBox = getChatBox()
    if not chatBox or type(username) ~= "string" or username == "" then return end
    if type(messages) ~= "table" then messages = { tostring(messages) } end
    for index, chatMessage in ipairs(messages) do
        pcall(function()
            chatBox.sendMessageToPlayer(
                tostring(chatMessage), username, "Plans", "[]", "&b", nil, true
            )
        end)
        if index < #messages then sleep(1.1) end
    end
end

local function handleChatCommand(username, rawMessage)
    local command, argument = tostring(rawMessage or "")
        :match("^%$?%.plan%s*(%S*)%s*(.-)%s*$")
    if command == nil then return end
    command = command:lower()

    if command == "" or command == "help" then
        sendChat(helpMessages, username)
        return
    end
    if command == "add" then
        if argument == "" then
            sendChat({ "Использование: .plan add <название>" }, username)
            return
        end
        server:send({
            type = "plans_command",
            action = "add",
            text = argument,
            username = username,
            requestId = tostring(os.epoch("utc")),
        })
        return
    end
    if command == "list" then
        server:send({
            type = "plans_command",
            action = "list",
            username = username,
            requestId = tostring(os.epoch("utc")),
        })
        return
    end
    if command == "complete" or command == "delete" then
        local planNumber = tonumber(argument:match("^#?(%d+)$"))
        if not planNumber then
            sendChat({ ("Использование: .plan %s <id>"):format(command) }, username)
            return
        end
        server:send({
            type = "plans_command",
            action = command,
            id = planNumber,
            username = username,
            requestId = tostring(os.epoch("utc")),
        })
        return
    end
    sendChat({ "Неизвестная команда. Используйте .plan help" }, username)
end

loadCache()
server:connect()
draw()
local timer = os.startTimer(REFRESH_INTERVAL)

while true do
    local event, arg1, arg2, arg3, arg4, arg5 = os.pullEvent()
    local serverEvent, message = server:handleEvent(event, arg1, arg2, arg3)

    if serverEvent == "message" and type(message) == "table"
        and message.type == "plans_update" and type(message.plans) == "table" then
        plans = message.plans
        lastUpdate = message.updatedAt
        saveCache()
        draw()
    elseif serverEvent == "message" and type(message) == "table"
        and message.type == "plans_result" then
        sendChat(message.messages or { "Команда выполнена" }, message.username)
    elseif serverEvent == "connected" or serverEvent == "disconnected" then
        draw()
    end

    if event == "timer" and arg1 == timer then
        server:connect()
        draw()
        timer = os.startTimer(REFRESH_INTERVAL)
    elseif (event == "monitor_resize" and arg1 == MONITOR_NAME)
        or event == "peripheral" or event == "peripheral_detach" then
        draw()
    elseif event == "chat" then
        local username = arg1
        local utf8Message = arg5 or arg2
        if tostring(utf8Message or ""):match("^%$?%.plan") then
            local subcommand = tostring(utf8Message):match("^%$?%.plan%s*(%S*)") or ""
            if server:isConnected() or subcommand == "" or subcommand:lower() == "help" then
                handleChatCommand(username, utf8Message)
            else
                sendChat({ "Сервер планов недоступен" }, username)
            end
        end
    end
end
