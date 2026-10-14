-- Draconic reactor computer launcher.
local function monitorPresent()
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

local PROGRAMS = {
    { path = "gateway.lua", title = "Gateway" },
    { path = "draconic_reactor.lua", title = "Draconic" },
    { path = "monitor_relay.lua", title = "Monitor Relay", when = monitorPresent },
    { path = "files.lua", title = "Files" },
}

local projectDirectory = fs.getDir(shell.getRunningProgram())
local runnerPath = fs.combine(projectDirectory, "service_runner.lua")

if not multishell or not shell.openTab then
    term.setTextColor(colors.red)
    print("This project requires multishell (use an Advanced Computer).")
    term.setTextColor(colors.white)
    return
end

local function findRunningTab(title)
    for tabId = 1, multishell.getCount() do
        if multishell.getTitle(tabId) == title then return tabId end
    end
end

local launched = 0
for _, program in ipairs(PROGRAMS) do
    local path = fs.combine(projectDirectory, program.path)
    if findRunningTab(program.title) then
        print("Already running " .. program.title)
    elseif program.when and not program.when() then
        print("Skipped " .. program.title .. " (peripherals not found)")
    elseif not fs.exists(path) then
        term.setTextColor(colors.red)
        print("Missing program: " .. program.path)
        term.setTextColor(colors.white)
    else
        local tabId = shell.openTab(runnerPath, path, program.title)
        multishell.setTitle(tabId, program.title)
        launched = launched + 1
        print("Started " .. program.title)
    end
end

if launched == 0 then
    term.setTextColor(colors.red)
    print("No draconic services were started.")
    term.setTextColor(colors.white)
end
