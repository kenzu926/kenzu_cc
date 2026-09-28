-- Safe remote diagnostics shared by all Kenzu CC services.
local Console = {}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function limit(value)
    value = tostring(value or "")
    if #value > 4000 then
        return value:sub(1, 4000) .. "\n... output truncated"
    end
    return value
end

local function peripheralSummary()
    local result = {}
    for _, name in ipairs(peripheral.getNames()) do
        local types = { peripheral.getType(name) }
        result[#result + 1] = name .. "  [" .. table.concat(types, ", ") .. "]"
    end
    table.sort(result)
    return #result > 0 and table.concat(result, "\n") or "No peripherals attached"
end

function Console.execute(command, statusProvider)
    command = trim(command)
    local verb, argument = command:match("^(%S+)%s*(.-)$")
    verb = verb and verb:lower() or ""

    if verb == "help" or verb == "?" then
        return true, table.concat({
            "Safe diagnostic commands:",
            "  status              current service state",
            "  peripherals         attached peripheral list",
            "  methods <name>      peripheral methods",
            "  id                  computer ID and label",
            "  uptime              in-game computer uptime",
            "  help                this help",
        }, "\n")
    end

    if verb == "status" then
        if statusProvider then
            local ok, value = pcall(statusProvider)
            return ok, limit(ok and value or value)
        end
        return true, "Service is running"
    end

    if verb == "peripherals" then
        return true, limit(peripheralSummary())
    end

    if verb == "methods" then
        if argument == "" or not peripheral.isPresent(argument) then
            return false, "Peripheral not found. Usage: methods <name>"
        end
        local methods = peripheral.getMethods(argument) or {}
        table.sort(methods)
        return true, limit(table.concat(methods, "\n"))
    end

    if verb == "id" then
        return true, ("Computer ID: %d\nLabel: %s"):format(
            os.getComputerID(),
            os.getComputerLabel() or "<none>"
        )
    end

    if verb == "uptime" then
        return true, ("%.1f seconds"):format(os.clock())
    end

    return false, "Unknown or unsafe command. Run 'help'."
end

return Console
