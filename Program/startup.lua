-- Project service launcher.
-- installer.lua is responsible for downloading and updating these files.
local Peripherals
do
    local dir = fs.getDir(shell.getRunningProgram())
    local modPath = fs.combine(dir, "peripherals.lua")
    if fs.exists(modPath) then
        local ok, mod = pcall(dofile, modPath)
        if ok and type(mod) == "table" then Peripherals = mod end
    end
end

local function cfg(key, fallback)
    if Peripherals then
        local ok, value = pcall(Peripherals.get, key)
        if ok and type(value) == "string" and value ~= "" then return value end
    end
    return fallback
end
local function reactorIsReady()
    if Peripherals then
        local ok, found = pcall(Peripherals.findReactors)
        if ok and type(found) == "table" and #found > 0 then return true end
    end
    if Peripherals == nil then
        return peripheral.find("inductionPort") ~= nil
            and peripheral.find("fissionReactorLogicAdapter") ~= nil
    end
    return false
end

-- Machines telemetry discovers boilers/fusion/storages at runtime (on every
-- peripheral event), so it is never skipped: an empty scan just sends nothing.
local function machinesIsReady()
    return true
end

local function meNodeIsReady()
    if peripheral.find("meBridge") or peripheral.find("me_bridge") then return true end
    for _, name in ipairs(peripheral.getNames()) do
        if name:match("^ae2:controller") then return true end
    end
    return false
end

local function turbineIsReady()
    for _, name in ipairs(peripheral.getNames()) do
        if name:lower():find("turbine", 1, true) then return true end
    end
    return false
end

local function overviewMonitorIsReady()
    if Peripherals then return Peripherals.wrap("overviewMonitor") ~= nil end
    return peripheral.isPresent("monitor_1")
end

local function plansMonitorIsReady()
    if Peripherals then return Peripherals.wrap("plansMonitor") ~= nil end
    return peripheral.isPresent("monitor_2")
end

local function overviewRelayIsReady()
    -- Relay scans everything at runtime and works without a modem
    -- (rednet part is skipped then), so it is never skipped either.
    return true
end

local function anyMonitorPresent()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType then
            local ok, isMonitor = pcall(peripheral.hasType, name, "monitor")
            if ok and isMonitor then return true end
        elseif name:lower():find("monitor", 1, true) then
            return true
        end
    end
    return false
end

local function playerDetectorIsReady()
    if Peripherals then return Peripherals.findDetector() ~= nil end
    if peripheral.isPresent("playerDetector_0") then return true end
    for _, name in ipairs(peripheral.getNames()) do
        if name:lower():find("playerdetector", 1, true) then return true end
    end
    return false
end

local PROGRAMS = {
    {
        path = "leaderboards.lua",
        title = "Leaderboards",
        shouldRun = function() return type(kenzu) == "table" end,
    },
    {
        path = "gateway.lua",
        title = "Gateway",
        shouldRun = function() return true end,
    },
    {
        path = "update_agent.lua",
        title = "Update Agent",
        shouldRun = function() return true end,
    },
    {
        path = "remote_terminal.lua",
        title = "Remote Terminal",
        shouldRun = function() return true end,
    },
    {
        path = "overview_monitor.lua",
        title = "Base Overview",
        shouldRun = overviewMonitorIsReady,
    },
    {
        path = "plans_monitor.lua",
        title = "Base Plans",
        shouldRun = plansMonitorIsReady,
    },
    {
        path = "overview_relay.lua",
        title = "Overview Relay",
        shouldRun = overviewRelayIsReady,
    },
    {
        path = "player_presence.lua",
        title = "Player Policy",
        shouldRun = playerDetectorIsReady,
    },
    {
        path = "reactor.lua",
        title = "Reactor",
        shouldRun = reactorIsReady,
    },
    {
        path = "me_node.lua",
        title = "ME Node",
        shouldRun = meNodeIsReady,
    },
    {
        path = "turbine.lua",
        title = "Turbine",
        shouldRun = turbineIsReady,
    },
    {
        path = "machines.lua",
        title = "Machines",
        shouldRun = machinesIsReady,
    },
    {
        path = "monitor_relay.lua",
        title = "Monitor Relay",
        shouldRun = anyMonitorPresent,
    },
    {
        path = "files.lua",
        title = "Files",
        shouldRun = function() return true end,
    },
}

local projectDirectory = fs.getDir(shell.getRunningProgram())
local runnerPath = fs.combine(projectDirectory, "service_runner.lua")

local function projectPath(path)
    return fs.combine(projectDirectory, path)
end

local function printErrorMessage(message)
    term.setTextColor(colors.red)
    print(message)
    term.setTextColor(colors.white)
end

local function findRunningTab(title)
    for tabId = 1, multishell.getCount() do
        if multishell.getTitle(tabId) == title then return tabId end
    end
end

if not multishell or not shell.openTab then
    printErrorMessage(
        "This project requires multishell (use an Advanced Computer)."
    )
    return
end

local launched = 0

for _, program in ipairs(PROGRAMS) do
    local path = projectPath(program.path)
    local existingTab = findRunningTab(program.title)

    if existingTab then
        print(("Already running %s (tab %d)"):format(program.title, existingTab))
    elseif not program.shouldRun() then
        print("Skipped " .. program.title .. " (peripherals not found)")
    elseif not fs.exists(path) then
        printErrorMessage("Missing program: " .. program.path)
    elseif fs.isDir(path) then
        printErrorMessage("Program is a directory: " .. program.path)
    else
        local tabId
        if not fs.exists(runnerPath) then
            tabId = shell.openTab(path)
        else
            tabId = shell.openTab(runnerPath, path, program.title)
        end
        multishell.setTitle(tabId, program.title)
        launched = launched + 1
        print(("Started %s (%s)"):format(program.title, program.path))
    end
end

if launched == 0 then
    printErrorMessage("No matching project services were started.")
end
