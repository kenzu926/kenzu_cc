-- Read server statistics internally. Never executes Minecraft commands.
local directory = fs.getDir(shell.getRunningProgram())
local Client = dofile(fs.combine(directory, "gateway_client.lua"))
local gateway = Client.new("leaderboards")
local INTERVAL = 30

local function publish()
    gateway:connect()
    local available = type(kenzu) == "table" and type(kenzu.getLeaderboards) == "function"
    local ok, result = false, "Kenzu CC Bridge 1.3.0 is required"
    if available then ok, result = pcall(kenzu.getLeaderboards) end
    if ok and type(result) == "table" and type(result.boards) == "table" then
        gateway:send({ type = "leaderboards_status", available = true,
            boards = result.boards, generatedAt = result.generatedAt })
    else
        gateway:send({ type = "leaderboards_status", available = false,
            error = tostring(result) })
    end
    term.clear()
    term.setCursorPos(1, 1)
    print("Player leaderboards")
    print(ok and "Statistics refreshed (30s interval)" or tostring(result))
end

publish()
local timer = os.startTimer(INTERVAL)
while true do
    local event, a, b = os.pullEvent()
    local status = gateway:handleEvent(event, a, b)
    if status == "connected" then publish() end
    if event == "timer" and a == timer then
        publish()
        timer = os.startTimer(INTERVAL)
    end
end
