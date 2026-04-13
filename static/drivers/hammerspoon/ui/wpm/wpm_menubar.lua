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
--- 3. Dynamic Styling: Matches widget coloring dynamically with a background.
--- ==============================================================================

local M = {}

local hs        = hs
local keylogger = require("modules.keylogger")
local WPMShared = require("ui.wpm.shared")
local Logger    = require("lib.logger")

local LOG = "wpm_menubar"

local _menubar           = nil
local _timer             = nil
local _use_source_colors = true





-- =================================
-- =================================
-- ======= 1/ UI Operations ========
-- =================================
-- =================================

--- Fetches the live stats and updates the menubar item.
local function update_menubar()
	local stats = keylogger.get_live_stats()
	local display_wpm = stats.wpm or 0
	local now = hs.timer.absoluteTime() / 1000000000
	local active_source = WPMShared.get_active_source(stats, 3.0, now)
	
	local ok_tooltip, tooltip = pcall(require, "ui.tooltip")
	local tooltip_visible = false
	if ok_tooltip and type(tooltip) == "table" and type(tooltip.is_visible) == "function" then
		tooltip_visible = tooltip.is_visible()
	end
	
	if display_wpm > 0 or tooltip_visible or (active_source ~= "none") then
		if not _menubar then 
			_menubar = hs.menubar.new() 
			Logger.debug(LOG, "Menubar item created.")
		end
		
		-- Add a translucent background to preserve readability in the menubar
		local bg_color = nil
		if _use_source_colors and active_source ~= "none" then
			bg_color = WPMShared.get_source_color(active_source, 0.5)
		end
		
		local attrs = { 
			font = { name = ".AppleSystemUIFont", size = 13 }, 
			color = { white = 1, alpha = 1 } 
		}
		if bg_color then attrs.backgroundColor = bg_color end
		
		local styled_title = hs.styledtext.new(WPMShared.format_mpm_label(display_wpm, true), attrs)
		_menubar:setTitle(styled_title)
	else
		if _menubar then 
			_menubar:delete()
			_menubar = nil 
			Logger.debug(LOG, "Menubar item hidden (idle).")
		end
	end
end





-- =====================================
-- =====================================
-- ======= 2/ Public Control API =======
-- =====================================
-- =====================================

--- Starts the menubar monitoring loop.
function M.start()
	Logger.debug(LOG, "Starting WPM menubar widget…")
	if not _timer then _timer = hs.timer.new(0.5, update_menubar) end
	_timer:start()
	update_menubar()
	Logger.info(LOG, "WPM menubar widget started successfully.")
end

--- Halts the menubar updating and removes the icon.
function M.stop()
	Logger.debug(LOG, "Stopping WPM menubar widget…")
	if _timer then _timer:stop(); _timer = nil end
	if _menubar then _menubar:delete(); _menubar = nil end
	Logger.info(LOG, "WPM menubar widget stopped.")
end

--- Enables or disables source-based menubar coloring.
--- @param enabled boolean Whether source colors should be active.
function M.set_use_source_colors(enabled)
	_use_source_colors = enabled ~= false
end

return M
