local M = {}

-- Toggle debug output here
local DEBUG = false

-- ── Notifications ────────────────────────────────────────────────────────────
-- Derive the absolute path to the hammerspoon config directory from this file's
-- location so the logo path stays portable across machines.
local _src = debug.getinfo(1, "S").source
local _base = (_src:sub(1,1) == "@" and _src:sub(2) or _src):match("^(.*[/\\])") or "./"
local _logo_path = _base .. "../../../favicon.png"
local _logo_image = nil

local function _get_logo()
    if not _logo_image then
        _logo_image = hs.image.imageFromPath(_logo_path)
    end
    return _logo_image
end

--- Send a notification with the Ergopti+ branding.
---
--- Args:
---     msg: The informative text to display.
function M.notify(msg)
    local n = hs.notify.new({
        title           = "Ergopti+",
        informativeText = msg,
        contentImage    = _get_logo(),
    })
    n:send()
end

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
