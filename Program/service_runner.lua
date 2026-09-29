-- Restarts a project service if it exits or crashes.
local programPath, serviceName = ...
serviceName = serviceName or programPath or "Service"

local isReactorService = tostring(programPath):match("reactor%.lua$") ~= nil
    or tostring(serviceName):lower() == "reactor"

local function failSafeScram()
    if not isReactorService then return end
    local adapter = peripheral.wrap("fissionReactorLogicAdapter_0")
        or peripheral.find("fissionReactorLogicAdapter")
    if not adapter or type(adapter.scram) ~= "function" then
        printError("EMERGENCY: reactor adapter unavailable")
        return
    end
    local ok, failure = pcall(adapter.scram)
    local statusOk, running = pcall(adapter.getStatus)
    if ok and statusOk and running == false then
        printError("Emergency SCRAM confirmed after controller failure")
    else
        printError("EMERGENCY SCRAM NOT CONFIRMED: " .. tostring(failure or running))
    end
end

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
    failSafeScram()
    term.setTextColor(colors.orange)
    local restartDelay = isReactorService and 0.5 or 3
    print(("Restarting in %.1f seconds..."):format(restartDelay))
    term.setTextColor(colors.white)
    sleep(restartDelay)
end
