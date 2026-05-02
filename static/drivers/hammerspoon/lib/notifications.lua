--- lib/notifications.lua

--- ==============================================================================
--- MODULE: Notifications & Logging
--- DESCRIPTION:
--- Provides robust, fail-safe wrappers around Hammerspoon’s native
--- notification system and console logging. Automatically resolves paths
--- to load the application logo.
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("lib.logger")

local LOG = "notifications"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

M.DEBUG = false

local _logo_path  = ""
local _logo_image = nil

-- Safely resolve the absolute path to the favicon based on this file’s location
pcall(function()
	local _src  = debug.getinfo(1, "S").source
	local _base = (_src:sub(1,1) == "@" and _src:sub(2) or _src):match("^(.*[/\\])") or "./"
	_logo_path  = _base .. "../../../img/logo/logo_simple.png"
end)





-- ===================================
-- ===================================
-- ======= 2/ Internal Helpers =======
-- ===================================
-- ===================================

--- Safely loads and caches the Ergopti+ logo image for notifications.
--- @return userdata|nil The hs.image object, or nil if loading fails.
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

--- Sends a system notification with the Ergopti+ branding.
--- @param title_or_msg string Main title when body is provided, or message when body is omitted.
--- @param body string|nil Optional detail body.
function M.notify(title_or_msg, body)
    if title_or_msg == nil then return end
    local title_text = "Ergopti+"
    local info_text = tostring(title_or_msg)

    if body ~= nil then
        title_text = tostring(title_or_msg)
        info_text = tostring(body)
    end
    
    -- Ensure the notification process never crashes the script
    pcall(function()
        local n = hs.notify.new({
            title           = title_text,
            informativeText = info_text,
            contentImage    = _get_logo(),
        })
        if n and type(n.send) == "function" then 
            n:send() 
        end
    end)
	
	Logger.info(LOG, "Notification dispatched successfully:", title_text, info_text)
end

--- Prints styled debug information to the Hammerspoon console if DEBUG is enabled.
--- @param ... any Variadic arguments to print.
function M.debugLog(...)
	if not M.DEBUG then return end
	
	local args = {...}
	local parts = {}
	
	for i = 1, select("#", ...) do
		table.insert(parts, tostring(args[i]))
	end
	
	local msg = table.concat(parts, " ")
	
	pcall(function()
		hs.console.printStyledtext("[Ergopti+] " .. os.date("%H:%M:%S") .. " " .. msg)
	end)
end

return M
