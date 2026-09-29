-- Player presence observer for playerDetector_0.
-- The server-side mod is authoritative; this service triggers an immediate
-- sync on detector transitions and displays the current policy state.
local DETECTOR_NAME = "playerDetector_0"
local INTERVAL = 2

local detector
local previousCount
local lastResult = "Waiting for first scan"

local function findDetector()
    local exact = peripheral.wrap(DETECTOR_NAME)
    if exact then return exact, DETECTOR_NAME end
    for _, peripheralName in ipairs(peripheral.getNames()) do
        local matchesName = peripheralName:lower():find("playerdetector", 1, true) ~= nil
        local matchesType = peripheral.hasType
            and peripheral.hasType(peripheralName, "playerDetector")
        if matchesName or matchesType then
            return peripheral.wrap(peripheralName), peripheralName
        end
    end
end

local function onlinePlayers()
    if not detector or not detector.getOnlinePlayers then return nil, {} end
    local ok, players = pcall(detector.getOnlinePlayers)
    if not ok or type(players) ~= "table" then return nil, {} end
    local count = 0
    for _ in pairs(players) do count = count + 1 end
    return count, players
end

local function expectedDifficulty(count)
    return count and count > 0 and "hard" or "peaceful"
end

local function syncPolicy()
    if type(kenzu) ~= "table" or type(kenzu.syncPlayerDifficulty) ~= "function" then
        lastResult = "Kenzu CC Bridge 1.2.0 is not installed"
        return
    end
    local ok, result = pcall(kenzu.syncPlayerDifficulty)
    if not ok then
        lastResult = "Mod API error: " .. tostring(result)
        return
    end
    if type(result) == "table" then
        lastResult = ("Server: %s | Players: %s"):format(
            tostring(result.difficulty or "unknown"), tostring(result.players or "?"))
    else
        lastResult = "Difficulty synchronized"
    end
end

local function draw(count, players, detectorName)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.cyan)
    print("Player difficulty policy")
    term.setTextColor(colors.white)
    print("Detector: " .. tostring(detectorName or "OFFLINE"))
    print("Online: " .. tostring(count or 0))
    print("Expected: " .. expectedDifficulty(count):upper())
    print("Mod API: " .. (type(kenzu) == "table" and "CONNECTED" or "OFFLINE"))
    print(lastResult)
    if type(players) == "table" and count and count > 0 then
        print("Players:")
        for _, name in pairs(players) do print("- " .. tostring(name)) end
    end
end

local function refresh(force)
    local detectorName
    detector, detectorName = findDetector()
    local count, players = onlinePlayers()
    if count == nil then
        lastResult = "Player detector is unavailable"
    elseif force or previousCount == nil or count ~= previousCount then
        syncPolicy()
        previousCount = count
    end
    draw(count, players, detectorName)
end

refresh(true)
local timer = os.startTimer(INTERVAL)
while true do
    local event, arg1 = os.pullEvent()
    if event == "timer" and arg1 == timer then
        refresh(false)
        timer = os.startTimer(INTERVAL)
    elseif event == "peripheral" or event == "peripheral_detach" then
        refresh(true)
    end
end
