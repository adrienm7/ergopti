--- ui/wpm/wpm_menubar.lua

--- ==============================================================================
--- MODULE: WPM Menubar UI
--- DESCRIPTION:
--- Displays the current Words-Per-Minute typing speed directly in the macOS
--- global menubar.
---
--- FEATURES & RATIONALE:
--- 1. Unobtrusive: Only appears when the user is actively typing.
--- 2. Decoupled: Polls the core keylogger engine autonomously.
--- ==============================================================================

local M = {}
local hs = hs
local keylogger = require("modules.keylogger")

local _menubar = nil
local _timer   = nil





-- =================================
-- =================================
-- ======= 1/ UI Operations ========
-- =================================
-- =================================

--- Fetches the live stats and updates the menubar item.
local function update_menubar()
	local stats = keylogger.get_live_stats()
	local display_wpm = stats.wpm or 0
	
	if display_wpm > 0 then
		if not _menubar then _menubar = hs.menubar.new() end
		_menubar:setTitle("⌨️ " .. display_wpm .. " MPM")
	else
		if _menubar then _menubar:delete(); _menubar = nil end
	end
end





-- =====================================
-- =====================================
-- ======= 2/ Public Control API =======
-- =====================================
-- =====================================

--- Starts the menubar monitoring loop.
function M.start()
	if not _timer then _timer = hs.timer.new(1.0, update_menubar) end
	_timer:start()
	update_menubar()
end

--- Halts the menubar updating and removes the icon.
function M.stop()
	if _timer then _timer:stop(); _timer = nil end
	if _menubar then _menubar:delete(); _menubar = nil end
end

return M
