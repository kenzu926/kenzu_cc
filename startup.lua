-- Project service launcher.
-- installer.lua is responsible for downloading and updating these files.
local PROGRAMS = {
    { path = "reactor.lua", title = "Reactor" },
}

local projectDirectory = fs.getDir(shell.getRunningProgram())

local function projectPath(path)
    return fs.combine(projectDirectory, path)
end

local function printErrorMessage(message)
    term.setTextColor(colors.red)
    print(message)
    term.setTextColor(colors.white)
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

    if not fs.exists(path) then
        printErrorMessage("Missing program: " .. program.path)
    elseif fs.isDir(path) then
        printErrorMessage("Program is a directory: " .. program.path)
    else
        local tabId = shell.openTab(path)
        multishell.setTitle(tabId, program.title)
        launched = launched + 1
        print(("Started %s (%s)"):format(program.title, program.path))
    end
end

if launched == 0 then
    printErrorMessage("No project services were started. Run installer.lua first.")
end
