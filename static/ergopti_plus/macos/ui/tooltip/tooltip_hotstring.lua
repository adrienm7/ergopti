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
local Keycodes = require("lib.keycodes")
local LOG = "tooltip_hotstring"

local Config = require("ui.tooltip.config")
local Renderer = require("ui.tooltip.renderer")

local _state = {
	bg_color = nil,
	is_visible = false
}

local _watchers = {}
local _idle_timer = nil

-- Dequeue state for per-row expiry (destacking). When rows carry distinct
-- durations, each row's expire_at is tracked separately. The dequeue timer
-- fires at the earliest deadline, prunes expired rows, and re-renders the
-- remaining stack. nil means no dequeue cycle is active.
local _dequeue_rows  = nil
local _dequeue_timer = nil
-- Forward declaration — assigned after M.hide and M.show_stacked are defined.
local _dequeue_tick





-- ================================
--- ================================
-- ======= 1/ Event Control =======
--- ================================
-- ================================

--- Clears active timers and sets a new idle timeout if applicable.
--- When a dequeue cycle is running the timer is suppressed — the dequeue
--- manages its own end and an idle timer would kill the surviving rows early.
local function reset_idle_timer()
	if _idle_timer and type(_idle_timer.stop) == "function" then _idle_timer:stop() end
	-- Suppress the idle timer during a dequeue cycle; _dequeue_timer owns
	-- the hide lifecycle and fires exactly when the last row expires.
	if _dequeue_rows then return end
	local active_timeout = Config.settings.timeout_sec
	if active_timeout > 0 then
		_idle_timer = hs.timer.doAfter(active_timeout, M.hide)
	end
end

--- Stops the dequeue timer and clears dequeue state.
local function stop_dequeue()
	if _dequeue_timer then
		pcall(function() _dequeue_timer:stop() end)
		_dequeue_timer = nil
	end
	_dequeue_rows = nil
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
	stop_dequeue()
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
		local ignored_keycodes = {
			54, 55, 56, 58, 59, 60,
			Keycodes.F13_KARABINER_RETURN,
			Keycodes.F14_KARABINER_BACKSPACE,
			Keycodes.F15_KARABINER_ESCAPE,
			Keycodes.F16_LLM_CHAIN_SIGNAL,
			Keycodes.F17_CYCLE_WINDOWS,
			Keycodes.F20_LAYER_NAV_ENTERED,
			Keycodes.LAYER_SYN_1,
			Keycodes.LAYER_SYN_2,
			Keycodes.LAYER_SYN_3,
		}
		
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
--- =============================
-- ======= 2/ Public API =======
--- =============================
-- =============================

function M.hide()
	pcall(function()
		stop_watchers()
		_state.bg_color = nil
		_state.is_visible = false
		Renderer.hide()
	end)
end

--- Resets internal state and stops watchers without hiding the shared canvas.
--- Used when transitioning to the LLM tooltip so the canvas content is overwritten
--- in-place rather than first blanked then redrawn, which would produce a visible gap.
function M.dismiss_silent()
	pcall(function()
		stop_watchers()
		_state.bg_color = nil
		_state.is_visible = false
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

--- Shows a persistent loading indicator with no auto-dismiss timer and no interaction watchers.
--- The indicator stays until explicitly replaced or hidden — it must never self-dismiss
--- mid-generation, which would leave a blank gap before the prediction tooltip arrives.
--- @param content string|userdata The loading text to display.
--- @param is_enabled boolean Guard clause to prevent rendering if disabled.
--- @param background_color table|nil Optional background tint.
function M.show_loading(content, is_enabled, background_color)
	local ok, err = pcall(function()
		if not is_enabled then return end
		if content == nil or tostring(content) == "" then M.hide(); return end

		-- Stop any existing watchers/timers from a previous state before rendering
		stop_watchers()

		_state.bg_color = Config.settings.colorization_enabled and (type(background_color) == "table" and background_color or nil) or nil
		_state.is_visible = true

		local styled_content = type(content) == "userdata" and content or hs.styledtext.new(tostring(content), {
			font  = { name = Config.fonts.main, size = Config.sizes.main, traits = { italic = true } },
			color = { white = 0.80, alpha = 1.0 },
		})

		-- No start_watchers callback — the canvas stays up until replaced programmatically
		Renderer.render(styled_content, _state, nil)
	end)

	if not ok then Logger.error(LOG, "Crash during loading indicator rendering: " .. tostring(err) .. ".") end
end

function M.is_visible()
	return _state.is_visible
end

--- Shows a stacked multi-row tooltip where each row has its own tint.
--- Rows are { text, tint, trigger_label, dimmed, duration }.
--- When rows carry distinct non-zero duration values the dequeue path activates:
--- each row tracks its own expire_at timestamp and a timer prunes expired rows
--- and re-renders the remaining stack, so a short row disappears first and
--- longer rows stay visible. When all durations are identical (or zero) the
--- simple single-timer path (set by tooltip.set_timeout before this call) is
--- used unchanged — this is the common case when all categories share a delay.
--- @param rows table Array of row descriptor objects (may contain expire_at for rebuild calls).
--- @param is_enabled boolean Guard clause — skips render if false.
function M.show_stacked(rows, is_enabled)
	local ok, err = pcall(function()
		if not is_enabled then return end
		if not rows or #rows == 0 then M.hide(); return end
		stop_dequeue()
		_state.is_visible = true

		-- Detect whether this is a dequeue rebuild (rows already carry expire_at)
		-- or a fresh first show (duration fields present, no expire_at yet).
		local is_rebuild = rows[1] and rows[1].expire_at ~= nil

		-- For fresh shows: detect mixed durations to decide which path to use.
		local first_dur, mixed, any_dur = nil, false, false
		if not is_rebuild then
			for _, row in ipairs(rows) do
				local d = (type(row.duration) == "number" and row.duration > 0) and row.duration or nil
				if d then
					any_dur = true
					if first_dur == nil then first_dur = d
					elseif d ~= first_dur then mixed = true end
				end
			end
		end

		if is_rebuild or (any_dur and mixed) then
			-- Dequeue path — stamp expiry times (or reuse existing ones for rebuilds).
			local FLOOR, DEC = 0.05, 0.2
			local now = hs.timer.secondsSinceEpoch()
			_dequeue_rows = {}
			local next_expire = nil
			for _, row in ipairs(rows) do
				local copy = {}
				for k, v in pairs(row) do copy[k] = v end
				if not copy.expire_at then
					local d = (type(row.duration) == "number" and row.duration > 0) and row.duration or nil
					copy.expire_at = d and (now + math.max(FLOOR, d - DEC)) or nil
				end
				table.insert(_dequeue_rows, copy)
				if copy.expire_at and (not next_expire or copy.expire_at < next_expire) then
					next_expire = copy.expire_at
				end
			end
			-- Pass nil for start_watchers on rebuild so start_watchers() does
			-- not call stop_dequeue() and erase _dequeue_rows mid-cycle.
			-- The watchers from the initial show are still running.
			local watcher_cb = is_rebuild and nil or start_watchers
			Renderer.render_stacked(rows, _state, watcher_cb)
			if next_expire then
				local delay = math.max(0.05, next_expire - hs.timer.secondsSinceEpoch())
				_dequeue_timer = hs.timer.doAfter(delay, _dequeue_tick)
			end
		else
			-- Simple path — global timeout already set by caller via tooltip.set_timeout.
			Renderer.render_stacked(rows, _state, start_watchers)
		end
	end)
	if not ok then Logger.error(LOG, "Crash during stacked tooltip rendering: " .. tostring(err) .. ".") end
end

--- Hides the stacked canvas alongside the standard one.
local _original_hide = M.hide
M.hide = function()
	_original_hide()
	pcall(Renderer.hide_stacked)
end

-- Assign the dequeue tick function now that M.hide and M.show_stacked exist.
-- Prunes expired rows and re-renders the surviving stack, or hides when empty.
_dequeue_tick = function()
	pcall(function()
		if not _dequeue_rows then return end
		local remaining = {}
		local t = hs.timer.secondsSinceEpoch()
		for _, row in ipairs(_dequeue_rows) do
			if not row.expire_at or t < row.expire_at then
				table.insert(remaining, row)
			end
		end
		if #remaining == 0 then
			M.hide()
			return
		end
		-- Pass remaining rows back through show_stacked so the dequeue timer
		-- re-arms itself for the next expiry. expire_at fields are preserved
		-- so the rebuild branch is detected and existing timestamps reused.
		M.show_stacked(remaining, true)
	end)
end

return M
