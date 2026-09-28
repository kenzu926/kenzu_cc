-- Restarts a project service if it exits or crashes.
local programPath, serviceName = ...
serviceName = serviceName or programPath or "Service"

if not programPath or not fs.exists(programPath) then
    error("Missing service program: " .. tostring(programPath), 0)
end

while true do
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
    term.setCursorPos(1, 1)
    print("Starting " .. serviceName .. "...")

    local protected, result = pcall(shell.run, programPath)
    term.setTextColor(colors.red)
    if not protected then
        print("Service crashed: " .. tostring(result))
    elseif result == false then
        print("Service stopped with an error.")
    else
        print("Service exited.")
    end
    term.setTextColor(colors.orange)
    print("Restarting in 3 seconds...")
    term.setTextColor(colors.white)
    sleep(3)
end
