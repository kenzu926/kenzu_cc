-- Project service launcher.
-- installer.lua is responsible for downloading and updating these files.
local function reactorIsReady()
    return peripheral.find("inductionPort") ~= nil
        and peripheral.find("fissionReactorLogicAdapter") ~= nil
        and peripheral.find("monitor") ~= nil
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

local PROGRAMS = {
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
        if program.path == "remote_terminal.lua" or not fs.exists(runnerPath) then
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
