local M = {}

-- Toggle debug output here
local DEBUG = false

local function debugLog(...)
    if not DEBUG then return end
    local args = {...}
    for i=1,#args do args[i] = tostring(args[i]) end
    local msg = table.concat(args, " ")
    pcall(function()
        hs.console.printStyledtext("[tp] " .. os.date("%H:%M:%S") .. " " .. msg)
    end)
end

M.debugLog = debugLog

return M
