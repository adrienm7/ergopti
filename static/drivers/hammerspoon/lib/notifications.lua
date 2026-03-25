-- lib/notifications.lua

-- ===========================================================================
-- Notifications & Logging Module.
--
-- Provides robust, fail-safe wrappers around Hammerspoon’s native
-- notification system (hs.notify) and console logging (hs.console).
-- Automatically resolves relative paths to load the application logo.
-- ===========================================================================

local M = {}





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

--- Toggle debug output globally for the module
M.DEBUG = false

local _logo_path  = ""
local _logo_image = nil

-- Safely resolve the absolute path to the favicon based on this file’s location
pcall(function()
    local _src  = debug.getinfo(1, "S").source
    local _base = (_src:sub(1,1) == "@" and _src:sub(2) or _src):match("^(.*[/\\])") or "./"
    _logo_path  = _base .. "../../../favicon.png"
end)





-- ===================================
-- ===================================
-- ======= 2/ Internal Helpers =======
-- ===================================
-- ===================================

--- Safely loads and caches the Ergopti+ logo image for notifications
--- @return userdata|nil The hs.image object, or nil if loading fails
local function _get_logo()
    if not _logo_image and _logo_path ~= "" then
        local ok, img = pcall(hs.image.imageFromPath, _logo_path)
        if ok and img then 
            _logo_image = img 
        end
    end
    return _logo_image
end





-- =============================
-- =============================
-- ======= 3/ Public API =======
-- =============================
-- =============================

--- Sends a system notification with the Ergopti+ branding
--- @param msg string The informative text to display
function M.notify(msg)
    if msg == nil then return end
    
    -- Ensure the notification process never crashes the script
    pcall(function()
        local n = hs.notify.new({
            title           = "Ergopti+",
            informativeText = tostring(msg),
            contentImage    = _get_logo(),
        })
        if n and type(n.send) == "function" then 
            n:send() 
        end
    end)
end

--- Prints styled debug information to the Hammerspoon console if DEBUG is enabled
--- Accepts variadic arguments just like print()
function M.debugLog(...)
    if not M.DEBUG then return end
    
    local args = {...}
    local parts = {}
    
    -- Safely convert all arguments to strings
    for i = 1, select("#", ...) do
        table.insert(parts, tostring(args[i]))
    end
    
    local msg = table.concat(parts, " ")
    
    pcall(function()
        hs.console.printStyledtext("[Ergopti+] " .. os.date("%H:%M:%S") .. " " .. msg)
    end)
end

return M
