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
local _running           = false -- true between start() and stop(); guards redundant restarts
local _use_source_colors = true

-- Source-color hold duration in seconds, single-sourced from the SAME shared TOML
-- the floating widget uses (wpm_color_hold_ms via wpm_widget._load_shared_const), so
-- the menubar and widget agree on how long the hotstring color lingers. Hardcoding it
-- (was 3.0) drifted from the widget's 1.0 s (F-L7). Read once at module load.
local COLOR_HOLD_FALLBACK_S = 1.0  -- mirrors wpm_color_hold_ms = 1000 when the TOML is unreadable
local COLOR_HOLD_S = (function()
	local ok, ww = pcall(require, "ui.wpm.wpm_widget")
	local d = ok and type(ww._load_shared_const) == "function" and ww._load_shared_const().source_color_duration
	return (type(d) == "number" and d) or COLOR_HOLD_FALLBACK_S
end)()





-- =================================
-- =================================
-- ======= 1/ UI Operations ========
-- =================================
-- =================================

-- Forward declaration: update_menubar() (the pcall wrapper) is defined before its
-- body so the body can be a plain local function referenced by name below.
local update_menubar_body

--- Fetches the live stats and updates the menubar item.
--- Wrapped end-to-end in a pcall (mirrors tooltip_hotstring.lua / tooltip_llm.lua):
--- this runs on a bare hs.timer callback with no caller to catch a raised error,
--- and there is no hs.uncaughtErrorHandler anywhere in the tree, so an unguarded
--- fault here would silently kill the 0.5 s timer with nothing in the file logger.
local function update_menubar()
	local ok, err = pcall(update_menubar_body)
	if not ok then Logger.error(LOG, "Crash during menubar update: " .. tostring(err) .. ".") end
end

--- Actual menubar-update body, wrapped by update_menubar() above.
update_menubar_body = function()
	local stats = keylogger.get_live_stats()
	local display_wpm = stats.wpm or 0
	local now = hs.timer.absoluteTime() / 1000000000
	local active_source = WPMShared.get_active_source(stats, COLOR_HOLD_S, now)
	
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
	-- Idempotent: the menu tree rebuild re-invokes start() on every refresh. Skip the
	-- redundant timer restart and menubar re-render when already polling — the 0.5 s
	-- timer already keeps the icon fresh.
	if _running then return end
	Logger.debug(LOG, "Starting WPM menubar widget…")
	if not _timer then _timer = hs.timer.new(0.5, update_menubar) end
	_timer:start()
	_running = true
	update_menubar()
	Logger.info(LOG, "WPM menubar widget started successfully.")
end

--- Halts the menubar updating and removes the icon.
function M.stop()
	-- Idempotent: a menu rebuild while the widget is off re-invokes stop() repeatedly.
	-- Nothing to tear down means nothing to log — return before the start/stop banner.
	if not _running and not _timer and not _menubar then return end
	Logger.debug(LOG, "Stopping WPM menubar widget…")
	_running = false
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
