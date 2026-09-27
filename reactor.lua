-- Mekanism reactor controller service.
local MATRIX_NAME = "inductionPort_0"
local REACTOR_NAME = "fissionReactorLogicAdapter_0"
local MONITOR_NAME = "monitor_0"

local SETTINGS_FILE = "reactor.settings"
local CHECK_INTERVAL = 1

settings.define("reactor.startPercent", {
    description = "Start reactor at or below this energy percentage",
    default = 80,
    type = "number",
})

settings.define("reactor.stopPercent", {
    description = "Stop reactor at or above this energy percentage",
    default = 98,
    type = "number",
})

settings.load(SETTINGS_FILE)

local startPercent = math.floor(settings.get("reactor.startPercent"))
local stopPercent = math.floor(settings.get("reactor.stopPercent"))

-- Keep saved values valid and leave at least 1% between the thresholds.
startPercent = math.max(0, math.min(99, startPercent))
stopPercent = math.max(startPercent + 1, math.min(100, stopPercent))

local matrix = assert(
    peripheral.wrap(MATRIX_NAME),
    "Induction Matrix not found: " .. MATRIX_NAME
)

local reactor = assert(
    peripheral.wrap(REACTOR_NAME),
    "Fission Reactor not found: " .. REACTOR_NAME
)

local monitor = assert(
    peripheral.wrap(MONITOR_NAME),
    "Monitor not found: " .. MONITOR_NAME
)

monitor.setTextScale(0.5)

local width, height = monitor.getSize()
local energy = 0
local reactorRunning = false
local stoppedForHighEnergy = false
local message = "Controller started"

local buttons = {}

local function saveThresholds()
    settings.set("reactor.startPercent", startPercent)
    settings.set("reactor.stopPercent", stopPercent)
    settings.save(SETTINGS_FILE)
end

local function writeCentered(y, text, textColor, backgroundColor)
    text = tostring(text)
    monitor.setTextColor(textColor or colors.white)
    monitor.setBackgroundColor(backgroundColor or colors.black)
    monitor.setCursorPos(math.max(1, math.floor((width - #text) / 2) + 1), y)
    monitor.write(text)
end

local function fill(x1, y1, x2, y2, color)
    monitor.setBackgroundColor(color)
    for y = y1, y2 do
        monitor.setCursorPos(x1, y)
        monitor.write(string.rep(" ", x2 - x1 + 1))
    end
end

local function drawButton(id, x1, y1, x2, y2, label, color)
    buttons[id] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
    fill(x1, y1, x2, y2, color)

    monitor.setBackgroundColor(color)
    monitor.setTextColor(colors.white)
    monitor.setCursorPos(
        x1 + math.max(0, math.floor((x2 - x1 + 1 - #label) / 2)),
        y1 + math.floor((y2 - y1) / 2)
    )
    monitor.write(label)
end

local function drawBar(y, fraction)
    local x1 = 3
    local x2 = width - 2
    local barWidth = math.max(1, x2 - x1 + 1)
    local filled = math.floor(barWidth * fraction + 0.5)

    fill(x1, y, x2, y + 1, colors.gray)
    if filled > 0 then
        fill(x1, y, x1 + filled - 1, y + 1, colors.lime)
    end
end

local function drawScreen()
    width, height = monitor.getSize()
    buttons = {}

    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
    monitor.clear()

    writeCentered(2, "FISSION REACTOR CONTROL", colors.yellow)
    writeCentered(4, ("Energy: %.1f%%"):format(energy * 100), colors.white)
    drawBar(6, energy)

    local stateColor = reactorRunning and colors.lime or colors.red
    writeCentered(9, "Reactor: " .. (reactorRunning and "ON" or "OFF"), stateColor)

    local minusX1 = 3
    local minusX2 = 9
    local plusX1 = width - 8
    local plusX2 = width - 2

    writeCentered(12, ("Start at: %d%%"):format(startPercent), colors.white)
    drawButton("startMinus", minusX1, 11, minusX2, 13, "-", colors.red)
    drawButton("startPlus", plusX1, 11, plusX2, 13, "+", colors.green)

    writeCentered(17, ("Stop at:  %d%%"):format(stopPercent), colors.white)
    drawButton("stopMinus", minusX1, 16, minusX2, 18, "-", colors.red)
    drawButton("stopPlus", plusX1, 16, plusX2, 18, "+", colors.green)

    writeCentered(math.min(height, 21), message, colors.lightGray)

    monitor.setBackgroundColor(colors.black)
    monitor.setTextColor(colors.white)
end

local function updateController()
    energy = matrix.getEnergyFilledPercentage()
    local actualRunning = reactor.getStatus()

    -- If the state changed outside this program, do not treat it as an
    -- automatic high-energy stop. This avoids undoing a manual/safety stop.
    if actualRunning ~= reactorRunning then
        stoppedForHighEnergy = false
    end
    reactorRunning = actualRunning

    if energy >= stopPercent / 100 and reactorRunning then
        reactor.scram()
        reactorRunning = false
        stoppedForHighEnergy = true
        message = "Stopped: battery full"
    elseif energy <= startPercent / 100 and not reactorRunning then
        reactor.activate()
        reactorRunning = true
        stoppedForHighEnergy = false
        message = "Started: battery low"
    end
end

local function isInside(button, x, y)
    return button
        and x >= button.x1 and x <= button.x2
        and y >= button.y1 and y <= button.y2
end

local function handleTouch(x, y)
    local changed = false
    local stopIncreased = false

    if isInside(buttons.startMinus, x, y) then
        startPercent = math.max(0, startPercent - 1)
        changed = true
    elseif isInside(buttons.startPlus, x, y) then
        startPercent = math.min(stopPercent - 1, startPercent + 1)
        changed = true
    elseif isInside(buttons.stopMinus, x, y) then
        stopPercent = math.max(startPercent + 1, stopPercent - 1)
        changed = true
    elseif isInside(buttons.stopPlus, x, y) then
        local newStopPercent = math.min(100, stopPercent + 1)
        stopIncreased = newStopPercent > stopPercent
        stopPercent = newStopPercent
        changed = stopIncreased
    end

    if changed then
        saveThresholds()
        message = "Thresholds saved"
        updateController()

        -- Raising the stop threshold above the current charge cancels only a
        -- stop previously caused by this controller. Normal hysteresis still
        -- applies to manual and safety shutdowns.
        if stopIncreased
            and stoppedForHighEnergy
            and not reactorRunning
            and energy < stopPercent / 100 then
            reactor.activate()
            reactorRunning = true
            stoppedForHighEnergy = false
            message = "Started: stop level raised"
        end

        drawScreen()
    end
end

saveThresholds()
updateController()
drawScreen()

local timer = os.startTimer(CHECK_INTERVAL)

while true do
    local event, arg1, arg2, arg3 = os.pullEvent()

    if event == "timer" and arg1 == timer then
        updateController()
        drawScreen()
        timer = os.startTimer(CHECK_INTERVAL)
    elseif event == "monitor_touch" and arg1 == MONITOR_NAME then
        handleTouch(arg2, arg3)
    elseif event == "monitor_resize" and arg1 == MONITOR_NAME then
        drawScreen()
    end
end
