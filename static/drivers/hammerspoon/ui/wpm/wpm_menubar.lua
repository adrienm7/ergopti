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
	local source = stats.source or "none"
	local source_time = stats.source_time or 0
	local now = hs.timer.absoluteTime() / 1000000000
	
	local active_source = "none"
	if source ~= "none" and (now - source_time) <= 3.0 then
		active_source = source
	end
	
	local ok_tooltip, tooltip = pcall(require, "ui.tooltip")
	local tooltip_visible = false
	if ok_tooltip and type(tooltip) == "table" and type(tooltip.is_visible) == "function" then
		tooltip_visible = tooltip.is_visible()
	end
	
	if display_wpm > 0 or tooltip_visible or (active_source ~= "none") then
		if not _menubar then _menubar = hs.menubar.new() end
		
		-- Ajout d'un fond coloré translucide pour garantir la lisibilité du texte blanc en Menubar
		local bg_color = nil
		if active_source == "hotstring" then bg_color = { hex = "#ff3b30", alpha = 0.5 }
		elseif active_source == "llm" then bg_color = { hex = "#af52de", alpha = 0.5 } end
		
		local attrs = { 
			font = { name = ".AppleSystemUIFont", size = 13 }, 
			color = { white = 1, alpha = 1 } 
		}
		if bg_color then attrs.backgroundColor = bg_color end
		
		local styled_title = hs.styledtext.new(display_wpm .. " MPM ", attrs)
		_menubar:setTitle(styled_title)
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
	if not _timer then _timer = hs.timer.new(0.5, update_menubar) end
	_timer:start()
	update_menubar()
end

--- Halts the menubar updating and removes the icon.
function M.stop()
	if _timer then _timer:stop(); _timer = nil end
	if _menubar then _menubar:delete(); _menubar = nil end
end

return M
