--- ui/tooltip/tooltip_hotstring.lua

--- ==============================================================================
--- MODULE: Tooltip Hotstring
--- DESCRIPTION:
--- Manages standard text alerts and simple hotstring expansions.
--- 
--- FEATURES & RATIONALE:
--- 1. Lightweight Rendering: Designed for simple text without AI diffs.
--- 2. Failsafe Watchers: Dismisses on any standard user interaction.
--- 3. Stacked dequeue: per-row expiry logic mirrors AHK lib/tooltip.ahk and
---    _shared/modules/tooltip/dequeue.js (see SPEC.md § 7.1).
--- ==============================================================================

local M = {}
local hs = hs
local Logger = require("lib.logger")
local Keycodes = require("lib.keycodes")
local LOG = "tooltip_hotstring"

local Config = require("ui.tooltip.config")
local Renderer = require("ui.tooltip.renderer")
local Dequeue = require("ui.tooltip.dequeue")

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

local _dequeue_opts = {
	duration_field = "duration",
	expire_field   = "expire_at",
	timeout_decrement_sec = Config.timing.timeout_decrement_sec,
	timeout_floor_sec     = Config.timing.timeout_floor_sec,
}





-- ================================
-- ================================
-- ======= 1/ Event Control =======
-- ================================
-- ================================

--- Stops keyboard/mouse watchers and the idle timer without touching dequeue
--- state. Used when (re)arming watchers during an active dequeue cycle.
local function stop_watchers_only()
	for _, watcher in ipairs(_watchers) do
		if watcher and type(watcher.stop) == "function" then watcher:stop() end
	end
	_watchers = {}

	if _idle_timer and type(_idle_timer.stop) == "function" then
		_idle_timer:stop()
		_idle_timer = nil
	end
end

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

--- Terminates watchers, idle timer, and any active dequeue cycle.
local function stop_watchers()
	stop_watchers_only()
	stop_dequeue()
end

--- Starts OS-level interception to hide the tooltip upon any simple interaction.
local function start_watchers()
	-- Only tear down prior watchers — never stop_dequeue() here. Clearing
	-- dequeue state on the initial stacked show was the root cause of the
	-- missing destack behaviour (rows vanished all at once).
	stop_watchers_only()
	reset_idle_timer()
	
	local event_types = hs.eventtap.event.types
	
	-- mouseMoved intentionally excluded: trackpad fires it at 200+ Hz, adding
	-- HID-thread latency while the tooltip is visible. Clicks and scrolls are
	-- sufficient for dismissal; pure mouse movement must not block input delivery.
	-- The dequeue-cycle comment still holds for the remaining event types.
	local ok_mouse, watcher_mouse = pcall(hs.eventtap.new, { event_types.leftMouseDown, event_types.rightMouseDown, event_types.scrollWheel }, function()
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
		-- A real keystroke is an authoritative dismissal — bypass dequeue guard.
		M.hide_forced()
		return false
	end)
	
	if ok_key and watcher_key then 
		watcher_key:start()
		table.insert(_watchers, watcher_key) 
	else 
		Logger.error(LOG, "Failed to mount keyboard event listener.") 
	end
end

--- Arms the one-shot dequeue timer for the next row expiry.
local function arm_dequeue_timer()
	if _dequeue_timer then
		pcall(function() _dequeue_timer:stop() end)
		_dequeue_timer = nil
	end
	if not _dequeue_rows then return end
	local delay = Dequeue.next_expiry_delay_sec(_dequeue_rows, hs.timer.secondsSinceEpoch(), _dequeue_opts)
	if delay and delay <= 0 then
		-- All rows are permanent (no expire_at), so fire _dequeue_tick immediately;
		-- without this _dequeue_rows stays non-nil and M.hide() is blocked forever (M-10)
		hs.timer.doAfter(0, _dequeue_tick)
	else
		_dequeue_timer = hs.timer.doAfter(delay, _dequeue_tick)
	end
end





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Forces the tooltip to hide regardless of any active dequeue cycle.
--- Only call this when an authoritative dismissal is required (e.g. the
--- keyboard watcher detected a real typing key, or an explicit hide() call
--- from outside the tooltip subsystem).
function M.hide_forced()
	pcall(function()
		stop_watchers()
		_state.bg_color = nil
		_state.is_visible = false
		Renderer.hide()
	end)
end

function M.hide()
	-- Mirror AHK's _TooltipDequeueActive guard: while a dequeue cycle is
	-- running, external hide() calls from mouse/scroll watchers are ignored
	-- so that rows with longer durations survive past the first row's expiry.
	-- The dequeue tick itself calls hide_forced() when the last row expires.
	if _dequeue_rows then return end
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
		-- Hide the stacked canvas (hotstring preview) when transitioning away;
		-- without this it survives the LLM tooltip transition and stays on screen
		-- as an orphaned layer behind the new prediction canvas (E1 audit fix).
		pcall(Renderer.hide_stacked)
		stop_watchers()
		_state.bg_color = nil
		_state.is_visible = false
	end)
end

function M.show(content, is_llm_origin, is_enabled, background_color)
	local ok, err = pcall(function()
		if not is_enabled then return end
		if content == nil or tostring(content) == "" then M.hide_forced(); return end

		-- Dismantle any active dequeue cycle before starting fresh — a stale
		-- dequeue timer would fire after this call and replace the new content
		-- with its pruned rows, erasing what we just rendered (E3 audit fix).
		stop_dequeue()
		-- Hide any surviving stacked canvas from a prior hotstring expansion
		-- that was not cleaned up by a transition function (E1 audit fix).
		pcall(Renderer.hide_stacked)

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
		if content == nil or tostring(content) == "" then M.hide_forced(); return end

		-- Stop any existing watchers/timers from a previous state before rendering
		stop_watchers()
		-- Hide any surviving stacked canvas from a prior hotstring preview;
		-- the loading indicator must render above a clean surface (E1 audit fix).
		pcall(Renderer.hide_stacked)

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
		if not rows or #rows == 0 then M.hide_forced(); return end

		-- Use the canonical Dequeue analysis so that any row (not just row[1])
		-- carrying an expire_at stamp is detected — checking only the first row
		-- caused premature stop_dequeue() on partial-expiry rebuilds (M-09)
		local is_rebuild = Dequeue.analyze_durations(rows, _dequeue_opts)
		if not is_rebuild then
			stop_dequeue()
		end

		_state.is_visible = true

		if Dequeue.should_use_dequeue_path(rows, _dequeue_opts) then
			local now = hs.timer.secondsSinceEpoch()
			_dequeue_rows = select(1, Dequeue.stamp_expiry_times(rows, now, _dequeue_opts))

			local watcher_cb = is_rebuild and nil or start_watchers
			Renderer.render_stacked(_dequeue_rows, _state, watcher_cb)
			arm_dequeue_timer()
		else
			stop_dequeue()
			Renderer.render_stacked(rows, _state, start_watchers)
		end
	end)
	if not ok then Logger.error(LOG, "Crash during stacked tooltip rendering: " .. tostring(err) .. ".") end
end

--- Hides the stacked canvas alongside the standard one (authoritative).
local _original_hide_forced = M.hide_forced
M.hide_forced = function()
	_original_hide_forced()
	pcall(Renderer.hide_stacked)
end

--- Hides both canvases unless a dequeue cycle is active (respects guard).
M.hide = function()
	if _dequeue_rows then return end
	M.hide_forced()
end

-- Assign the dequeue tick function now that M.hide and M.show_stacked exist.
-- Prunes expired rows and re-renders the surviving stack, or hides when empty.
_dequeue_tick = function()
	pcall(function()
		if not _dequeue_rows then return end
		local remaining = Dequeue.prune_expired(_dequeue_rows, hs.timer.secondsSinceEpoch(), _dequeue_opts)
		if #remaining == 0 then
			M.hide_forced()
			return
		end
		M.show_stacked(remaining, true)
	end)
end

return M