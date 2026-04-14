--- ui/tooltip/tooltip_hotstring.lua

--- ==============================================================================
--- MODULE: Tooltip Hotstring
--- DESCRIPTION:
--- Manages standard text alerts and simple hotstring expansions.
--- 
--- FEATURES & RATIONALE:
--- 1. Lightweight Rendering: Designed for simple text without AI diffs.
--- 2. Failsafe Watchers: Dismisses on any standard user interaction.
--- ==============================================================================

local M = {}
local hs = hs
local Logger = require("lib.logger")
local LOG = "tooltip_hotstring"

local Config = require("ui.tooltip.config")
local Renderer = require("ui.tooltip.renderer")

local _state = {
	bg_color = nil,
	is_visible = false
}

local _watchers = {}
local _idle_timer = nil





-- ================================
-- ================================
-- ======= 1/ Event Control =======
-- ================================
-- ================================

--- Clears active timers and sets a new idle timeout if applicable.
local function reset_idle_timer()
	if _idle_timer and type(_idle_timer.stop) == "function" then _idle_timer:stop() end
	local active_timeout = Config.settings.timeout_sec
	
	if active_timeout > 0 then
		_idle_timer = hs.timer.doAfter(active_timeout, M.hide)
	end
end

--- Terminates all active keyboard and mouse watchers.
local function stop_watchers()
	for _, watcher in ipairs(_watchers) do 
		if watcher and type(watcher.stop) == "function" then watcher:stop() end 
	end
	_watchers = {}
	
	if _idle_timer and type(_idle_timer.stop) == "function" then 
		_idle_timer:stop()
		_idle_timer = nil 
	end
end

--- Starts OS-level interception to hide the tooltip upon any simple interaction.
local function start_watchers()
	stop_watchers()
	reset_idle_timer()
	
	local event_types = hs.eventtap.event.types
	
	local ok_mouse, watcher_mouse = pcall(hs.eventtap.new, { event_types.mouseMoved, event_types.leftMouseDown, event_types.rightMouseDown, event_types.scrollWheel }, function()
		M.hide()
		return false
	end)
	
	if ok_mouse and watcher_mouse then 
		watcher_mouse:start()
		table.insert(_watchers, watcher_mouse) 
	end

	local ok_key, watcher_key = pcall(hs.eventtap.new, { event_types.keyDown }, function(event)
		local keycode = event:getKeyCode()
		local ignored_keycodes = { 54, 55, 56, 58, 59, 60, 105, 107, 113, 106, 64, 79, 80, 90 }
		
		for _, ignored_code in ipairs(ignored_keycodes) do
			if keycode == ignored_code then return false end
		end
		
		M.hide()
		return false
	end)
	
	if ok_key and watcher_key then 
		watcher_key:start()
		table.insert(_watchers, watcher_key) 
	else 
		Logger.error(LOG, "Failed to mount keyboard event listener.") 
	end
end





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

function M.hide()
	pcall(function()
		stop_watchers()
		_state.bg_color = nil
		_state.is_visible = false
		Renderer.hide()
	end)
end

function M.show(content, is_llm_origin, is_enabled, background_color)
	local ok, err = pcall(function()
		if not is_enabled then return end
		if content == nil or tostring(content) == "" then M.hide(); return end

		_state.bg_color = Config.settings.colorization_enabled and (type(background_color) == "table" and background_color or nil) or nil
		_state.is_visible = true
		
		local styled_content = type(content) == "userdata" and content or hs.styledtext.new(tostring(content), {
			font  = { name = Config.fonts.main, size = Config.sizes.main, traits = is_llm_origin and { italic = true } or {} },
			color = is_llm_origin and { white = 0.80, alpha = 1.0 } or { white = 1.00, alpha = 1.0 },
		})
		
		Renderer.render(styled_content, _state, start_watchers)
	end)
	
	if not ok then Logger.error(LOG, "Crash during standard tooltip rendering: " .. tostring(err) .. ".") end
end

function M.is_visible()
	return _state.is_visible
end

return M
