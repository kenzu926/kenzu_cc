-- Touch pages for shared plans and locally read player leaderboards on monitor_2.
local MONITOR_NAME = "monitor_2"
local CHATBOX_NAME = "chatBox_0"
local REFRESH_INTERVAL = 2
local LEADERBOARD_INTERVAL = 30

local scriptDirectory = fs.getDir(shell.getRunningProgram())
local cacheFile = fs.combine(scriptDirectory, "plans.cache")
local leaderboardCacheFile = fs.combine(scriptDirectory, "leaderboards.cache")
local GatewayClient = dofile(fs.combine(scriptDirectory, "gateway_client.lua"))
local Peripherals = dofile(fs.combine(scriptDirectory, "peripherals.lua"))
local server = GatewayClient.new("plans")
MONITOR_NAME = Peripherals.get("plansMonitor")
CHATBOX_NAME = Peripherals.get("chatBox")

local plans = {}
local lastUpdate = nil
local page = "plans"
local buttons = {}
local leaderboardPage = 1
local leaderboardPages = 1
local leaderboardData = nil
local leaderboardAvailable = false
local leaderboardError = "Waiting for server statistics"
local leaderboardTypes = {
    { id = "time_played", label = "TIME PLAYED" },
    { id = "damage_dealt", label = "DAMAGE DEALT" },
    { id = "deaths", label = "DEATHS" },
    { id = "deaths_per_hour", label = "DEATHS PER HOUR" },
    { id = "distance_walked", label = "DISTANCE WALKED" },
    { id = "jumps", label = "JUMPS" },
    { id = "mob_kills", label = "MOB KILLS" },
    { id = "player_kills", label = "PLAYER KILLS" },
    { id = "time_since_death", label = "TIME SINCE DEATH" },
}

local function loadLeaderboardCache()
    if not fs.exists(leaderboardCacheFile) then return end
    local handle = fs.open(leaderboardCacheFile, "r")
    if not handle then return end
    local ok, decoded = pcall(textutils.unserializeJSON, handle.readAll())
    handle.close()
    if ok and type(decoded) == "table" and type(decoded.boards) == "table" then
        leaderboardData = decoded
    end
end

local function refreshLeaderboards()
    if type(kenzu) ~= "table" or type(kenzu.getLeaderboards) ~= "function" then
        leaderboardAvailable = false
        leaderboardError = "Requires Kenzu CC Bridge 1.3.0"
        return
    end
    local ok, result = pcall(kenzu.getLeaderboards)
    if not ok or type(result) ~= "table" or type(result.boards) ~= "table" then
        leaderboardAvailable = false
        leaderboardError = "Statistics unavailable - retrying"
        return
    end
    local changed = not leaderboardData or leaderboardData.generatedAt ~= result.generatedAt
    leaderboardData = result
    leaderboardAvailable = true
    leaderboardError = nil
    if changed then
        local handle = fs.open(leaderboardCacheFile, "w")
        if handle then
            handle.write(textutils.serializeJSON(result))
            handle.close()
        end
    end
end

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
    local monitor = peripheral.wrap(MONITOR_NAME) or Peripherals.wrap("plansMonitor")
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
    local width, height = monitor.getSize()
    if y < 1 or y > height then return end
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

local function drawPlans()
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
    centered(monitor, 1, "BASE PLANS", colors.cyan, colors.gray)
    centered(monitor, 2, ("OPEN %d   DONE %d   TOTAL %d")
        :format(pending, #plans - pending, #plans), colors.lightGray, colors.gray)

    local divider = math.floor(width / 2) + 1
    local leftX, rightX = 2, divider + 2
    local leftWidth = math.max(10, divider - leftX - 1)
    local rightWidth = math.max(10, width - rightX)
    fill(monitor, 6, colors.gray)
    writeInColumn(monitor, leftX, 6, "OPEN PLANS", leftWidth, colors.yellow, colors.gray)
    writeInColumn(monitor, rightX, 6, "COMPLETED", rightWidth, colors.lime, colors.gray)
    for y = 6, height - 1 do
        writeAt(monitor, divider, y, "|", colors.gray, colors.black)
    end

    drawPlanColumn(monitor, plansByState(false), leftX, leftWidth, 8, height - 2, false)
    drawPlanColumn(monitor, plansByState(true), rightX, rightWidth, 8, height - 2, true)

    fill(monitor, height, colors.gray)
    writeAt(monitor, 2, height,
        (server:isConnected() and "WEB LINK ONLINE" or "CACHED / OFFLINE") .. " | .plan help",
        server:isConnected() and colors.lime or colors.orange, colors.gray)
end

local function button(monitor, x, y, width, label, action, selected, enabled)
    local background = selected and colors.blue or colors.gray
    local foreground = enabled == false and colors.lightGray or colors.white
    local text = tostring(label):sub(1, width)
    local padding = math.max(0, math.floor((width - #text) / 2))
    writeAt(monitor, x, y, string.rep(" ", width), foreground, background)
    writeInColumn(monitor, x + padding, y, text, width - padding, foreground, background)
    if enabled ~= false then
        buttons[#buttons + 1] = { x = x, y = y, width = width, action = action }
    end
end

local function drawLeaderboards()
    local monitor = getMonitor()
    if not monitor then return end
    local width, height = monitor.getSize()
    monitor.setBackgroundColor(colors.black)
    monitor.clear()
    centered(monitor, 1, "PLAYER LEADERBOARDS", colors.cyan)
    centered(monitor, 2, "TOP 3 PLAYERS  |  ALL SERVER RANKINGS", colors.lightGray)

    -- Each card contains one heading and three player rows, separated by two
    -- empty rows from the next card. Never stretch a three-player list vertically.
    local columns = math.max(1, math.min(3, math.floor(width / 32)))
    local rows = math.max(1, math.floor((height - 8) / 6))
    local perPage = math.min(#leaderboardTypes, columns * rows)
    leaderboardPages = math.max(1, math.ceil(#leaderboardTypes / perPage))
    leaderboardPage = math.max(1, math.min(leaderboardPage, leaderboardPages))
    local cardWidth = math.min(42, math.floor((width - 4 - (columns - 1) * 2) / columns))
    local gridWidth = columns * cardWidth + (columns - 1) * 2
    local gridX = math.floor((width - gridWidth) / 2) + 1
    local first = (leaderboardPage - 1) * perPage + 1
    local last = math.min(#leaderboardTypes, first + perPage - 1)
    for index = first, last do
        local offset = index - first
        local x = gridX + (offset % columns) * (cardWidth + 2)
        local y = 7 + math.floor(offset / columns) * 6
        local definition = leaderboardTypes[index]
        local entries = leaderboardData and leaderboardData.boards[definition.id] or {}
        if type(entries) ~= "table" then entries = {} end
        writeInColumn(monitor, x, y, string.rep(" ", cardWidth), cardWidth, colors.white, colors.gray)
        writeInColumn(monitor, x + 1, y, definition.label, cardWidth - 2, colors.cyan, colors.gray)
        local valueWidth = math.min(12, math.floor(cardWidth / 3))
        local nameWidth = cardWidth - valueWidth - 5
        for rank = 1, math.min(3, #entries) do
            local entry = entries[rank]
            local rankColor = rank == 1 and colors.yellow or rank == 2 and colors.lightGray or colors.orange
            writeInColumn(monitor, x, y + rank, "#" .. rank, 3, rankColor)
            writeInColumn(monitor, x + 3, y + rank, entry.name or entry.uuid or "Unknown", nameWidth,
                leaderboardAvailable and entry.online and colors.lime or colors.white)
            local value = tostring(entry.display or entry.value or 0):sub(1, valueWidth)
            writeInColumn(monitor, x + cardWidth - #value, y + rank, value, valueWidth, colors.lightBlue)
        end
        if #entries == 0 then
            writeInColumn(monitor, x + 1, y + 2, leaderboardData and "No non-zero values" or "Waiting for statistics",
                cardWidth - 2, colors.gray)
        end
    end

    local bottom = 7 + math.ceil((last - first + 1) / columns) * 6
    if leaderboardPages > 1 then
        button(monitor, gridX, bottom - 1, 10, "< PREV", function()
            leaderboardPage = leaderboardPage - 1
        end, false, leaderboardPage > 1)
        centered(monitor, bottom - 1, ("TOPS %d / %d"):format(leaderboardPage, leaderboardPages), colors.lightGray)
        button(monitor, gridX + gridWidth - 10, bottom - 1, 10, "NEXT >", function()
            leaderboardPage = leaderboardPage + 1
        end, false, leaderboardPage < leaderboardPages)
    end
    centered(monitor, bottom, leaderboardAvailable and "LOCAL STATS ONLINE - REFRESH 30s"
        or leaderboardError or "CACHED / OFFLINE", leaderboardAvailable and colors.lime or colors.orange)
    centered(monitor, bottom + 1, leaderboardAvailable and "Green name = online"
        or leaderboardData and "Cached values - not live" or "No statistics received", colors.gray)
end

local function draw()
    buttons = {}
    local monitor = getMonitor()
    if not monitor then return end
    local width, height = monitor.getSize()
    if width < 44 or height < 15 then
        monitor.setBackgroundColor(colors.black)
        monitor.clear()
        writeAt(monitor, 1, 1, "Please enlarge monitor_2", colors.orange)
        writeAt(monitor, 1, 2, "Minimum: 44 x 15 characters", colors.gray)
        return
    end
    if page == "plans" then drawPlans() else drawLeaderboards() end
    local tabWidth, gap = 16, 3
    local tabX = math.floor((width - tabWidth * 2 - gap) / 2) + 1
    button(monitor, tabX, 4, tabWidth, "PLANS", function() page = "plans" end, page == "plans")
    button(monitor, tabX + tabWidth + gap, 4, tabWidth, "LEADERBOARD", function() page = "leaderboards" end,
        page == "leaderboards")
end

local function handleTouch(x, y)
    for _, control in ipairs(buttons) do
        if y == control.y and x >= control.x and x < control.x + control.width then
            control.action()
            draw()
            return
        end
    end
end

local helpMessages = {
    ".plan add <name> - add a plan",
    ".plan list - show all plans",
    ".plan complete <id> - complete a plan",
    ".plan delete <id> - delete a plan",
}

local function getChatBox()
    return peripheral.wrap(CHATBOX_NAME)
        or Peripherals.wrap("chatBox")
        or peripheral.find("chatBox")
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

local function sendSafetyBroadcast(messages, formattedMessages, fallbackMessages)
    local chatBox = getChatBox()
    if not chatBox then return end
    if type(messages) ~= "table" then messages = { tostring(messages) } end

    for index, chatMessage in ipairs(messages) do
        local formatted = type(formattedMessages) == "table" and formattedMessages[index] or nil
        local sent = false
        if type(formatted) == "string" and type(chatBox.sendFormattedMessage) == "function" then
            sent = pcall(function()
                chatBox.sendFormattedMessage(
                    formatted, "Reactor Safety", "[]", "&c"
                )
            end)
        end
        if not sent and type(chatBox.sendMessage) == "function" then
            local fallback = type(fallbackMessages) == "table" and fallbackMessages[index] or nil
            local plain = tostring(fallback or chatMessage or "Reactor safety alert")
            if plain:find("[\128-\255]") then
                plain = "Reactor safety alert. Check the control panel."
            end
            pcall(function()
                chatBox.sendMessage(plain, "Reactor Safety", "[]", "&c")
            end)
        end

        -- Advanced Peripherals limits chat messages to roughly one per second.
        -- Safety events may arrive together, so always leave room for the next one.
        sleep(1.1)
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
loadLeaderboardCache()
refreshLeaderboards()
server:connect()
pollUnicodeChat()
draw()
local timer = os.startTimer(REFRESH_INTERVAL)
local leaderboardTimer = os.startTimer(LEADERBOARD_INTERVAL)

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
        and message.type == "peripherals_update" then
        Peripherals.applyRemote(message.peripherals)
        MONITOR_NAME = Peripherals.get("plansMonitor")
        CHATBOX_NAME = Peripherals.get("chatBox")
        draw()
    elseif serverEvent == "message" and type(message) == "table"
        and message.type == "plans_result" then
        sendChat(
            message.messages or { "Command completed" },
            message.username,
            message.formattedMessages
        )
    elseif serverEvent == "message" and type(message) == "table"
        and message.type == "safety_chat" then
        sendSafetyBroadcast(
            message.messages or { "Reactor safety alert" },
            message.formattedMessages,
            message.fallbackMessages
        )
    elseif serverEvent == "connected" or serverEvent == "disconnected" then
        draw()
    end

    if event == "monitor_touch" then
        handleTouch(arg2, arg3)
    elseif event == "timer" and arg1 == leaderboardTimer then
        refreshLeaderboards()
        draw()
        leaderboardTimer = os.startTimer(LEADERBOARD_INTERVAL)
    elseif event == "timer" and arg1 == timer then
        server:connect()
        pollUnicodeChat()
        draw()
        timer = os.startTimer(REFRESH_INTERVAL)
    elseif (event == "monitor_resize")
        or event == Peripherals.RELOAD_EVENT
        or event == "peripheral" or event == "peripheral_detach" then
        MONITOR_NAME = Peripherals.get("plansMonitor")
        CHATBOX_NAME = Peripherals.get("chatBox")
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
