-- Project service launcher.
-- Add every standalone long-running program to this list.
local PROGRAMS = {
    { path = "reactor.lua", title = "Reactor" },
}

local function fail(message)
    term.setTextColor(colors.red)
    print(message)
    term.setTextColor(colors.white)
end

if not multishell or not shell.openTab then
    fail("This project requires multishell (use an Advanced Computer).")
    return
end

local launched = 0

for _, program in ipairs(PROGRAMS) do
    if not fs.exists(program.path) then
        fail("Missing program: " .. program.path)
    elseif fs.isDir(program.path) then
        fail("Program is a directory: " .. program.path)
    else
        local tabId = shell.openTab(program.path)
        multishell.setTitle(tabId, program.title)
        launched = launched + 1
        print(("Started %s (%s)"):format(program.title, program.path))
    end
end

if launched == 0 then
    fail("No project services were started.")
end
