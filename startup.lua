-- Project updater and service launcher.
local REPOSITORY_BASE_URL =
    "https://raw.githubusercontent.com/kenzu926/kenzu_cc/refs/heads/main/"

-- Add every standalone long-running program to this list.
local PROGRAMS = {
    { path = "reactor.lua", remote = "reactor.lua", title = "Reactor" },
}

local projectDirectory = fs.getDir(shell.getRunningProgram())

local function projectPath(path)
    return fs.combine(projectDirectory, path)
end

local function printColor(message, color)
    term.setTextColor(color)
    print(message)
    term.setTextColor(colors.white)
end

local function downloadProgram(program)
    if not http then
        return false, "HTTP API is disabled"
    end

    local url = REPOSITORY_BASE_URL .. program.remote
    local response, requestError, errorResponse = http.get(url, {
        ["Cache-Control"] = "no-cache",
    })

    if not response then
        if errorResponse then
            errorResponse.close()
        end
        return false, requestError or "request failed"
    end

    local responseCode = response.getResponseCode()
    local source = response.readAll()
    response.close()

    if responseCode ~= 200 then
        return false, "GitHub returned HTTP " .. tostring(responseCode)
    end

    if not source or #source == 0 then
        return false, "GitHub returned an empty file"
    end

    local compiled, syntaxError = load(source, "@" .. program.path)
    if not compiled then
        return false, "downloaded file has a Lua error: " .. tostring(syntaxError)
    end

    local destination = projectPath(program.path)
    local temporary = destination .. ".download"
    local backup = destination .. ".backup"

    if fs.exists(temporary) then
        fs.delete(temporary)
    end

    local output, openError = fs.open(temporary, "w")
    if not output then
        return false, openError or "cannot create temporary file"
    end

    output.write(source)
    output.close()

    if fs.exists(backup) then
        fs.delete(backup)
    end
    if fs.exists(destination) then
        fs.move(destination, backup)
    end

    local moved, moveError = pcall(fs.move, temporary, destination)
    if not moved then
        if fs.exists(backup) then
            fs.move(backup, destination)
        end
        return false, tostring(moveError)
    end

    if fs.exists(backup) then
        fs.delete(backup)
    end

    return true
end

if not multishell or not shell.openTab then
    printColor(
        "This project requires multishell (use an Advanced Computer).",
        colors.red
    )
    return
end

local launched = 0

for _, program in ipairs(PROGRAMS) do
    local updated, updateError = downloadProgram(program)
    local localPath = projectPath(program.path)

    if updated then
        printColor("Updated " .. program.path, colors.lime)
    elseif fs.exists(localPath) and not fs.isDir(localPath) then
        printColor(
            ("Update failed for %s; using cached file: %s")
                :format(program.path, tostring(updateError)),
            colors.orange
        )
    else
        printColor(
            ("Cannot download %s: %s")
                :format(program.path, tostring(updateError)),
            colors.red
        )
    end

    if fs.exists(localPath) and not fs.isDir(localPath) then
        local tabId = shell.openTab(localPath)
        multishell.setTitle(tabId, program.title)
        launched = launched + 1
        print(("Started %s (%s)"):format(program.title, program.path))
    end
end

if launched == 0 then
    printColor("No project services were started.", colors.red)
end
