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

local function plansByState(done)
    local result = {}
    for _, plan in ipairs(plans) do
        if (plan.done == true) == done then result[#result + 1] = plan end
    end
    table.sort(result, function(left, right)
        return (tonumber(left.number) or 0) < (tonumber(right.number) or 0)
    end)
    return result
end

local function writeInColumn(monitor, x, y, value, maximumWidth, foreground, background)
    writeAt(monitor, x, y, tostring(value):sub(1, math.max(0, maximumWidth)),
        foreground, background)
end

local function drawPlanColumn(monitor, columnPlans, x, width, firstRow, lastRow, done)
    local textX = x + 9
    local textWidth = math.max(8, width - 9)
    local y = firstRow
    local rendered = 0

    for _, plan in ipairs(columnPlans) do
        local label = plan.translationPending and "Translation pending" or plan.text
        local lines = wrap(label or "Unnamed task", textWidth)
        local extraRows = done and 1 or 0
        if y + #lines + extraRows - 1 > lastRow then break end

        writeInColumn(monitor, x, y, done and "[x]" or "[ ]", 3,
            done and colors.lime or colors.yellow)
        writeInColumn(monitor, x + 4, y,
            ("#%s"):format(tostring(plan.number or "?")), 5, colors.lightBlue)
        for _, line in ipairs(lines) do
            writeInColumn(monitor, textX, y, line, textWidth,
                done and colors.lightGray or colors.white)
            y = y + 1
        end
        if done then
            writeInColumn(monitor, textX, y,
                "Done by: " .. tostring(plan.completedBy or "Unknown"),
                textWidth, colors.cyan)
            y = y + 1
        end
        y = y + 1
        rendered = rendered + 1
    end

    local remaining = #columnPlans - rendered
    if remaining > 0 then
        writeInColumn(monitor, x, lastRow,
            ("+%d more on website"):format(remaining), width, colors.orange)
    elseif #columnPlans == 0 then
        writeInColumn(monitor, x, firstRow, done and "No completed plans" or "No open plans",
            width, colors.gray)
    end
end

local function draw()
    local monitor = getMonitor()
    if not monitor then return end
    local width, height = monitor.getSize()
    monitor.setBackgroundColor(colors.black)
    monitor.clear()

    local pending = 0
    for _, plan in ipairs(plans) do
        if plan.done ~= true then pending = pending + 1 end
    end

    fill(monitor, 1, colors.gray)
    fill(monitor, 2, colors.gray)
    fill(monitor, 3, colors.gray)
    centered(monitor, 1, "BASE PLANS", colors.cyan, colors.gray)
    centered(monitor, 2, ".plan help - for help", colors.white, colors.gray)
    centered(monitor, 3, ("OPEN %d   DONE %d   TOTAL %d")
        :format(pending, #plans - pending, #plans), colors.lightGray, colors.gray)

    local divider = math.floor(width / 2) + 1
    local leftX, rightX = 2, divider + 2
    local leftWidth = math.max(10, divider - leftX - 1)
    local rightWidth = math.max(10, width - rightX)
    fill(monitor, 5, colors.gray)
    writeInColumn(monitor, leftX, 5, "OPEN PLANS", leftWidth, colors.yellow, colors.gray)
    writeInColumn(monitor, rightX, 5, "COMPLETED", rightWidth, colors.lime, colors.gray)
    for y = 4, height - 1 do
        writeAt(monitor, divider, y, "|", colors.gray, colors.black)
    end

    drawPlanColumn(monitor, plansByState(false), leftX, leftWidth, 7, height - 2, false)
    drawPlanColumn(monitor, plansByState(true), rightX, rightWidth, 7, height - 2, true)

    fill(monitor, height, colors.gray)
    writeAt(monitor, 2, height,
        server:isConnected() and "WEB LINK ONLINE" or "CACHED / OFFLINE",
        server:isConnected() and colors.lime or colors.orange, colors.gray)
end

local helpMessages = {
    ".plan add <name> - add a plan",
    ".plan list - show all plans",
    ".plan complete <id> - complete a plan",
    ".plan delete <id> - delete a plan",
}

local function getChatBox()
    return peripheral.wrap(CHATBOX_NAME) or peripheral.find("chatBox")
end

local function toCodepoints(value)
    local result = {}
    local ok = pcall(function()
        for _, codepoint in utf8.codes(tostring(value or "")) do
            result[#result + 1] = codepoint
        end
    end)
    return ok and result or nil
end

local function sendChat(messages, username, formattedMessages)
    local chatBox = getChatBox()
    if not chatBox or type(username) ~= "string" or username == "" then return end
    if type(messages) ~= "table" then messages = { tostring(messages) } end
    for index, chatMessage in ipairs(messages) do
        local formatted = type(formattedMessages) == "table" and formattedMessages[index] or nil
        local sent = false
        if type(formatted) == "string" and type(chatBox.sendFormattedMessageToPlayer) == "function" then
            sent = pcall(function()
                chatBox.sendFormattedMessageToPlayer(
                    formatted, username, "Plans", "[]", "&b"
                )
            end)
        end
        if not sent then
            local plain = tostring(chatMessage)
            if plain:find("[\128-\255]") then
                plain = "Unicode message unavailable. Update Advanced Peripherals."
            end
            pcall(function()
                chatBox.sendMessageToPlayer(plain, username, "Plans", "[]", "&b")
            end)
        end
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
            sendChat({ "Usage: .plan add <name>" }, username)
            return
        end
        server:send({
            type = "plans_command",
            action = "add",
            textCodepoints = toCodepoints(argument),
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
            sendChat({ ("Usage: .plan %s <id>"):format(command) }, username)
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
    sendChat({ "Unknown command. Use .plan help" }, username)
end

local function hasUnicodeChatBridge()
    return type(kenzu) == "table" and type(kenzu.pollPlanChatMessages) == "function"
end

local function pollUnicodeChat()
    if not hasUnicodeChatBridge() then return end
    local ok, batch = pcall(kenzu.pollPlanChatMessages)
    if not ok or type(batch) ~= "table" or type(batch.messages) ~= "table" then return end
    for _, chatMessage in ipairs(batch.messages) do
        local characters = {}
        if type(chatMessage.codepoints) == "table" then
            for _, codepoint in ipairs(chatMessage.codepoints) do
                local valid, character = pcall(utf8.char, tonumber(codepoint))
                if valid then characters[#characters + 1] = character end
            end
        end
        local rawMessage = table.concat(characters)
        if rawMessage:match("^%$?%.plan") then
            handleChatCommand(tostring(chatMessage.username or ""), rawMessage)
        end
    end
end

loadCache()
server:connect()
pollUnicodeChat()
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
        sendChat(
            message.messages or { "Command completed" },
            message.username,
            message.formattedMessages
        )
    elseif serverEvent == "connected" or serverEvent == "disconnected" then
        draw()
    end

    if event == "timer" and arg1 == timer then
        server:connect()
        pollUnicodeChat()
        draw()
        timer = os.startTimer(REFRESH_INTERVAL)
    elseif (event == "monitor_resize" and arg1 == MONITOR_NAME)
        or event == "peripheral" or event == "peripheral_detach" then
        draw()
    elseif event == "chat" and not hasUnicodeChatBridge() then
        local username = arg1
        local utf8Message = arg5 or arg2
        if tostring(utf8Message or ""):match("^%$?%.plan") then
            local subcommand = tostring(utf8Message):match("^%$?%.plan%s*(%S*)") or ""
            if server:isConnected() or subcommand == "" or subcommand:lower() == "help" then
                handleChatCommand(username, utf8Message)
            else
                sendChat({ "Plans server is unavailable" }, username)
            end
        end
    end
end
