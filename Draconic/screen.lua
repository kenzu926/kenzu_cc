-- Shared screen-capture buffer for monitor apps and monitor_relay.
-- CC:Tweaked monitors have no getLine(), so screens cannot be scraped.
-- Instead apps draw through a proxy (same method names as the peripheral);
-- the proxy records every cell and commits a JSON frame file which
-- monitor_relay (another multishell tab, shared filesystem) forwards to
-- the website. Touch handling stays on the real monitor, unchanged.
local Screen = {}

local registry = {}
local scriptDirectory = nil
pcall(function()
    if shell and shell.getRunningProgram then
        scriptDirectory = fs.getDir(shell.getRunningProgram())
    end
end)

local function frameFile(name)
    local safe = tostring(name or "monitor"):gsub("[^%w]", "_")
    local file = "screen-" .. safe .. ".json"
    if scriptDirectory then return fs.combine(scriptDirectory, file) end
    return file
end

function Screen.framePath(name)
    return frameFile(name)
end

local function toHex(color)
    if type(colors) == "table" and colors.toBlit then
        local ok, hex = pcall(colors.toBlit, color)
        if ok and type(hex) == "string" and #hex == 1 then return hex end
    end
    return "0"
end

local function blankRow(width)
    local row = {}
    for x = 1, width do row[x] = { text = " ", fg = "0", bg = "f" } end
    return row
end

local function ensureRows(entry)
    for y = 1, entry.height do
        if not entry.rows[y] then entry.rows[y] = blankRow(entry.width) end
    end
end

local function buildProxy(entry)
    local proxy = {}

    function proxy.getSize()
        local device = entry.device
        if device and device.getSize then
            local ok, width, height = pcall(device.getSize)
            if ok and type(width) == "number" and type(height) == "number" then
                return width, height
            end
        end
        return entry.width, entry.height
    end

    function proxy.getTextScale()
        local device = entry.device
        if device and device.getTextScale then
            local ok, scale = pcall(device.getTextScale)
            if ok and type(scale) == "number" then return scale end
        end
        return 0.5
    end

    function proxy.setTextScale(scale)
        local device = entry.device
        if device and device.setTextScale then pcall(device.setTextScale, scale) end
        local width, height = proxy.getSize()
        entry.width, entry.height = width, height
        entry.rows = {}
        entry.x, entry.y = 1, 1
        ensureRows(entry)
    end

    function proxy.setCursorPos(x, y)
        entry.x = math.floor(tonumber(x) or 1)
        entry.y = math.floor(tonumber(y) or 1)
        local device = entry.device
        if device and device.setCursorPos then pcall(device.setCursorPos, x, y) end
    end

    function proxy.getCursorPos()
        return entry.x, entry.y
    end

    function proxy.setTextColor(color)
        entry.fg = toHex(color)
        local device = entry.device
        if device and device.setTextColor then pcall(device.setTextColor, color) end
    end
    proxy.setTextColour = proxy.setTextColor

    function proxy.setBackgroundColor(color)
        entry.bg = toHex(color)
        local device = entry.device
        if device and device.setBackgroundColor then
            pcall(device.setBackgroundColor, color)
        end
    end
    proxy.setBackgroundColour = proxy.setBackgroundColor

    function proxy.isColor()
        local device = entry.device
        if device and device.isColor then
            local ok, value = pcall(device.isColor)
            if ok then return value end
        end
        return true
    end
    proxy.isColour = proxy.isColor

    local function putChar(char, fg, bg)
        while entry.y > entry.height do
            table.remove(entry.rows, 1)
            entry.rows[entry.height] = blankRow(entry.width)
            entry.y = entry.height
        end
        if entry.y >= 1 and entry.x >= 1 and entry.x <= entry.width then
            if not entry.rows[entry.y] then entry.rows[entry.y] = blankRow(entry.width) end
            entry.rows[entry.y][entry.x] = { text = char, fg = fg, bg = bg }
        end
        entry.x = entry.x + 1
        if entry.x > entry.width then
            entry.x = 1
            entry.y = entry.y + 1
        end
    end

    function proxy.write(text)
        text = tostring(text or "")
        for i = 1, #text do putChar(text:sub(i, i), entry.fg, entry.bg) end
        local device = entry.device
        if device and device.write then pcall(device.write, text) end
    end

    function proxy.blit(text, fgColors, bgColors)
        text = tostring(text or "")
        fgColors = tostring(fgColors or "")
        bgColors = tostring(bgColors or "")
        for i = 1, #text do
            local fg = fgColors:sub(i, i)
            local bg = bgColors:sub(i, i)
            if fg == "" then fg = entry.fg end
            if bg == "" then bg = entry.bg end
            putChar(text:sub(i, i), fg, bg)
        end
        local device = entry.device
        if device and device.blit then pcall(device.blit, text, fgColors, bgColors) end
    end

    function proxy.scroll(lines)
        lines = math.floor(tonumber(lines) or 0)
        if lines > 0 then
            for _ = 1, lines do
                table.remove(entry.rows, 1)
                entry.rows[entry.height] = blankRow(entry.width)
            end
        elseif lines < 0 then
            for _ = 1, -lines do
                table.remove(entry.rows)
                table.insert(entry.rows, 1, blankRow(entry.width))
            end
        end
        local device = entry.device
        if device and device.scroll then pcall(device.scroll, lines) end
    end

    function proxy.clear()
        entry.rows = {}
        ensureRows(entry)
        local device = entry.device
        if device and device.clear then pcall(device.clear) end
    end

    function proxy.clearLine()
        if entry.y >= 1 and entry.y <= entry.height then
            entry.rows[entry.y] = blankRow(entry.width)
        end
        local device = entry.device
        if device and device.clearLine then pcall(device.clearLine) end
    end

    return proxy
end

-- Returns a drawing proxy for a monitor peripheral, or nil when detached.
function Screen.attach(name)
    local key = tostring(name or "")
    if key == "" then return nil end
    local entry = registry[key]
    if not entry then
        entry = {
            device = nil,
            width = 51, height = 19, x = 1, y = 1,
            fg = toHex(colors and colors.white), bg = toHex(colors and colors.black),
            rows = {},
        }
        entry.proxy = buildProxy(entry)
        registry[key] = entry
    end
    if peripheral.isPresent(key) then
        entry.device = peripheral.wrap(key)
    else
        entry.device = nil
        return nil
    end
    local width, height = entry.proxy.getSize()
    if width ~= entry.width or height ~= entry.height then
        entry.width, entry.height = width, height
        entry.rows = {}
    end
    ensureRows(entry)
    return entry.proxy
end

-- Writes the current buffer to the frame file. Returns true on success.
function Screen.commit(name)
    local key = tostring(name or "")
    local entry = registry[key]
    if not entry then return false end
    local ok = pcall(function()
        local lines = {}
        for y = 1, entry.height do
            local row = entry.rows[y] or blankRow(entry.width)
            local textParts, fgParts, bgParts = {}, {}, {}
            for x = 1, entry.width do
                local cell = row[x] or { text = " ", fg = "0", bg = "f" }
                textParts[#textParts + 1] = cell.text
                fgParts[#fgParts + 1] = cell.fg
                bgParts[#bgParts + 1] = cell.bg
            end
            lines[y] = {
                text = table.concat(textParts),
                fg = table.concat(fgParts),
                bg = table.concat(bgParts),
            }
        end
        local payload = textutils.serializeJSON({
            width = entry.width,
            height = entry.height,
            cursorX = entry.x,
            cursorY = entry.y,
            cursorBlink = false,
            lines = lines,
        })
        local path = frameFile(key)
        local temporary = path .. ".tmp"
        if fs.exists(temporary) then fs.delete(temporary) end
        local handle = fs.open(temporary, "w")
        if not handle then return end
        handle.write(payload)
        handle.close()
        if fs.exists(path) then fs.delete(path) end
        fs.move(temporary, path)
    end)
    return ok == true
end

-- Reads a frame file written by Screen.commit. Returns frame, raw text.
function Screen.readFrame(name)
    local path = frameFile(tostring(name or ""))
    if not fs.exists(path) then return nil end
    local handle = fs.open(path, "r")
    if not handle then return nil end
    local raw = handle.readAll()
    handle.close()
    if type(raw) ~= "string" or raw == "" then return nil end
    local ok, decoded = pcall(textutils.unserializeJSON, raw)
    if not ok or type(decoded) ~= "table" then return nil end
    if type(decoded.width) ~= "number" or type(decoded.lines) ~= "table" then return nil end
    return decoded, raw
end

return Screen
