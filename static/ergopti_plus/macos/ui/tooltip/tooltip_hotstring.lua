--- ui/tooltip/tooltip_hotstring.lua

--- ==============================================================================
--- MODULE: Tooltip Hotstring
--- DESCRIPTION:
--- Manages standard text alerts and simple hotstring expansions.
--- 
--- FEATURES & RATIONALE:
--- 1. Lightweight Rendering: Designed for simple text without AI diffs.
--- 2. Failsafe Watchers: Dismisses on any standard user interaction.
--- 3. Stacked dequeue: per-row expiry logic mirrors AHK infra/tooltip.ahk and
---    _shared/modules/tooltip/dequeue.js (see SPEC.md § 7.1).
--- ==============================================================================

local M = {}
local hs = hs
local Logger = require("infra.logger")
local EventProvenance = require("adapters.event_provenance")
local SyntheticInput = require("adapters.synthetic_input")
local Keycodes = require("infra.keycodes")
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
local _watcher_session_active = false
local _watcher_epoch = 0
local _ui_generation = 0
local REQUIRED_WATCHER_COUNT = 2

-- Dequeue state for per-row expiry (destacking). When rows carry distinct
-- durations, each row's expire_at is tracked separately. The dequeue timer
-- fires at the earliest deadline, prunes expired rows, and re-renders the
-- remaining stack. nil means no dequeue cycle is active.
local _dequeue_rows  = nil
local _dequeue_timer = nil
-- Exact rows owned by the committed stacked canvas. Unlike _dequeue_rows this
-- also covers an all-infinite stack, which has no dequeue cycle but may still
-- carry an interceptor/provider action lease.
local _visible_rows = nil
-- Forward declaration — assigned after M.hide and M.show_stacked are defined.
local _dequeue_tick

local _dequeue_opts = {
	duration_field = "duration",
	expire_field   = "expire_at",
	timeout_decrement_sec = Config.timing.timeout_decrement_sec,
	timeout_floor_sec     = Config.timing.timeout_floor_sec,
}

--- Invalidates work classified against an older tooltip render.
local function advance_ui_generation()
	_ui_generation = _ui_generation + 1
end

--- Defers a mutation only while the render that classified it still owns UI.
--- @param label string Diagnostic label.
--- @param fn function Deferred mutation.
--- @param ... any Arguments.
--- @return boolean scheduled
local function defer_session_action(label, fn, ...)
	local args = table.pack(...)
	local generation = _ui_generation
	return SyntheticInput.defer_after_callback(label, function()
		if generation ~= _ui_generation or not _watcher_session_active then return end
		return fn(table.unpack(args, 1, args.n))
	end)
end

--- Reads a timer's live state across native hs.timer and the test double.
--- @param timer table|userdata Timer object.
--- @return boolean ok
--- @return boolean|any running_or_error
local function timer_running(timer)
	local ok, result = pcall(function()
		local probe = timer and timer.running
		if type(probe) == "function" then return probe(timer) end
		if type(probe) == "boolean" then return probe end
		error("running status is unavailable")
	end)
	return ok, result
end

--- Stops a timer and proves the native object is no longer running.
--- @param timer table|userdata Timer object.
--- @param label string Diagnostic label.
--- @return boolean stopped
local function stop_timer_verified(timer, label)
	if not timer or type(timer.stop) ~= "function" then
		Logger.error(LOG, "Cannot stop %s: invalid timer.", label)
		return false
	end
	local stop_ok, stop_err = pcall(timer.stop, timer)
	if not stop_ok then
		Logger.error(LOG, "Failed to stop %s: %s.", label, tostring(stop_err))
	end
	local status_ok, running = timer_running(timer)
	if status_ok and running == false then return true end
	if not status_ok or running ~= false then
		Logger.error(LOG, "Cannot verify stopped %s: %s.", label,
			tostring(status_ok and "timer remained running" or running))
		return false
	end
	return true
end





-- ================================
-- ================================
-- ======= 1/ Event Control =======
-- ================================
-- ================================

--- Stops keyboard/mouse watchers and the idle timer without touching dequeue
--- state. Used when (re)arming watchers during an active dequeue cycle. A tap
--- whose stop cannot be verified remains owned so no replacement can duplicate it.
--- @return boolean True when every watcher and the idle timer were revoked.
local function stop_watchers_only()
	advance_ui_generation()
	_watcher_epoch = _watcher_epoch + 1
	_watcher_session_active = false
	local residual_watchers = {}
	for _, watcher in ipairs(_watchers) do
		local stop_ok = false
		if watcher and type(watcher.stop) == "function" then
			local ok, err = pcall(watcher.stop, watcher)
			stop_ok = ok
			if not ok then Logger.error(LOG, "Failed to stop dismissal event listener: %s.", tostring(err)) end
		else
			Logger.error(LOG, "Cannot stop dismissal event listener: invalid watcher.")
		end

		local status_ok, enabled = false, nil
		if watcher and type(watcher.isEnabled) == "function" then
			status_ok, enabled = pcall(watcher.isEnabled, watcher)
		end
		if not status_ok or enabled ~= false then
			if stop_ok then
				Logger.error(LOG, "Dismissal event listener remained enabled after stop.")
			end
			residual_watchers[#residual_watchers + 1] = watcher
		end
	end
	_watchers = residual_watchers

	local timer_stopped = true
	if _idle_timer then
		timer_stopped = stop_timer_verified(_idle_timer, "tooltip idle timer")
		if timer_stopped then _idle_timer = nil end
	end
	return #_watchers == 0 and timer_stopped
end

--- Reports whether every dismissal watcher exists and remains enabled.
--- @return boolean True when the complete watcher set can be reused.
local function watchers_are_active()
	if not _watcher_session_active then return false end
	if #_watchers ~= REQUIRED_WATCHER_COUNT then return false end
	for _, watcher in ipairs(_watchers) do
		if not watcher or type(watcher.isEnabled) ~= "function" then return false end
		local ok, enabled = pcall(watcher.isEnabled, watcher)
		if not ok or enabled ~= true then return false end
	end
	return true
end

--- Starts and retains one watcher without letting an OS failure escape rendering.
--- @param watcher table|nil Eventtap object.
--- @param label string Diagnostic watcher label.
--- @return boolean True when the watcher started successfully.
local function activate_watcher(watcher, label)
	if not watcher then
		Logger.error(LOG, "Cannot start %s event listener: invalid watcher.", label)
		return false
	end
	-- Own the object before start(): the underlying tap may already be enabled
	-- even when the wrapper throws, and losing it would allow a duplicate tap.
	_watchers[#_watchers + 1] = watcher
	if type(watcher.start) ~= "function" then
		Logger.error(LOG, "Cannot start %s event listener: invalid watcher.", label)
		return false
	end
	local ok, err = pcall(watcher.start, watcher)
	if not ok then
		Logger.error(LOG, "Failed to start %s event listener: %s.", label, tostring(err))
		return false
	end
	if type(watcher.isEnabled) ~= "function" then
		Logger.error(LOG, "Cannot verify %s event listener: isEnabled is unavailable.", label)
		return false
	end
	local enabled_ok, enabled = pcall(watcher.isEnabled, watcher)
	if not enabled_ok or enabled ~= true then
		Logger.error(LOG, "%s event listener did not enable: %s.", label,
			tostring(enabled_ok and "CGEventTapCreate failed" or enabled))
		return false
	end
	return true
end

--- Clears active timers and sets a new idle timeout if applicable.
--- When a dequeue cycle is running the timer is suppressed — the dequeue
--- manages its own end and an idle timer would kill the surviving rows early.
--- @return boolean True when the deadline is owned and usable.
local function reset_idle_timer()
	if _idle_timer then
		if not stop_timer_verified(_idle_timer, "tooltip idle timer") then return false end
		_idle_timer = nil
	end
	-- Suppress the idle timer during a dequeue cycle; _dequeue_timer owns
	-- the hide lifecycle and fires exactly when the last row expires.
	if _dequeue_rows then return true end
	local active_timeout = Config.settings.timeout_sec
	if active_timeout > 0 then
		local generation = _ui_generation
		local timer_handle = nil
		local timer_ok, timer_or_err = pcall(hs.timer.doAfter, active_timeout, function()
			if not timer_handle or _idle_timer ~= timer_handle then return end
			_idle_timer = nil
			if generation ~= _ui_generation or not _watcher_session_active then return end
			M.hide()
		end)
		if timer_ok then timer_handle = timer_or_err end
		if timer_ok and timer_or_err then _idle_timer = timer_or_err end
		local status_ok, running = false, nil
		if timer_ok then status_ok, running = timer_running(timer_or_err) end
		if not timer_ok or not timer_or_err or type(timer_or_err.stop) ~= "function"
			or not status_ok or running ~= true then
			Logger.error(LOG, "Cannot arm tooltip idle timer: %s.",
				tostring(timer_ok and (status_ok and "timer did not start" or running) or timer_or_err))
			if _idle_timer and stop_timer_verified(_idle_timer, "invalid tooltip idle timer") then
				_idle_timer = nil
			end
			return false
		end
	end
	return true
end

--- Stops the dequeue deadline while preserving its handle on any failure.
--- @return boolean stopped
local function stop_dequeue_timer()
	if not _dequeue_timer then return true end
	if not stop_timer_verified(_dequeue_timer, "tooltip dequeue timer") then return false end
	_dequeue_timer = nil
	return true
end

--- Stops the dequeue timer and clears dequeue state.
--- @return boolean stopped
local function stop_dequeue()
	local stopped = stop_dequeue_timer()
	_dequeue_rows = nil
	return stopped
end

--- Terminates watchers, idle timer, and any active dequeue cycle.
local function stop_watchers()
	local watchers_stopped = stop_watchers_only()
	local dequeue_stopped = stop_dequeue()
	return watchers_stopped and dequeue_stopped
end

--- Starts OS-level interception to hide the tooltip upon any simple interaction.
local function start_watchers()
	if watchers_are_active() then
		if reset_idle_timer() then return true end
		M.hide_forced()
		return false
	end

	-- Only tear down prior watchers — never stop_dequeue() here. Clearing
	-- dequeue state on the initial stacked show was the root cause of the
	-- missing destack behaviour (rows vanished all at once).
	if not stop_watchers_only() then
		M.hide_forced()
		return false
	end
	if not reset_idle_timer() then
		M.hide_forced()
		return false
	end
	_watcher_session_active = true
	_watcher_epoch = _watcher_epoch + 1
	local watcher_epoch = _watcher_epoch
	
	local event_types = hs.eventtap.event.types
	local activation_ok = true
	
	-- mouseMoved intentionally excluded: trackpad fires it at 200+ Hz, adding
	-- HID-thread latency while the tooltip is visible. Clicks and scrolls are
	-- sufficient for dismissal; pure mouse movement must not block input delivery.
	-- The dequeue-cycle comment still holds for the remaining event types.
	local ok_mouse, watcher_mouse
	ok_mouse, watcher_mouse = pcall(hs.eventtap.new, { event_types.leftMouseDown, event_types.rightMouseDown, event_types.scrollWheel }, function(event)
		if not _watcher_session_active or watcher_epoch ~= _watcher_epoch then return false end
		local provenance, status, fence = EventProvenance.classify_with_fence(
			event, "tooltip.hotstring_mouse")
		local fence_events = fence and fence.events or nil
		if provenance ~= nil then return false, fence_events end
		if status ~= EventProvenance.STATUS_UNREADABLE then
			defer_session_action("hotstring tooltip mouse dismissal", M.hide)
		end
		return false, fence_events
	end)
	
	if ok_mouse then
		if not activate_watcher(watcher_mouse, "mouse") then activation_ok = false end
	else
		activation_ok = false
		Logger.error(LOG, "Failed to mount mouse event listener: %s.", tostring(watcher_mouse))
	end

	local ok_key, watcher_key
	ok_key, watcher_key = pcall(hs.eventtap.new, { event_types.keyDown }, function(event)
		if not _watcher_session_active or watcher_epoch ~= _watcher_epoch then return false end
		local provenance, status, fence = EventProvenance.classify_with_fence(
			event, "tooltip.hotstring")
		local fence_events = fence and fence.events or nil
		local function finish(consume) return consume == true, fence_events end
		if provenance then return finish(false) end
		if status == EventProvenance.STATUS_UNREADABLE then
			return finish(false)
		end
		local key_ok, keycode = pcall(event.getKeyCode, event)
		if not key_ok or type(keycode) ~= "number" then
			defer_session_action("hotstring tooltip key diagnostic",
				function()
					Logger.error(LOG, "Cannot read dismissal keycode: %s.", tostring(keycode))
				end)
			return finish(false)
		end
		local ignored_keycodes = {
			54, 55, 56, 58, 59, 60,
			-- Escape belongs to the persistent trap, not to this watcher. This tap
			-- is created per render, so it is always NEWER than the trap and runs
			-- first: hiding here and returning false left the trap looking at an
			-- already-invisible tooltip, which is its signal to pass Escape
			-- through. The keystroke then reached the app and opened Raycast on
			-- every dismissal after the first show. Ignoring it lets the trap see
			-- a visible tooltip, consume the key, and dismiss properly.
			Keycodes.ESCAPE,
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
			if keycode == ignored_code then return finish(false) end
		end
		-- A real keystroke is an authoritative dismissal — bypass dequeue guard.
		defer_session_action("hotstring tooltip key dismissal", M.hide_forced)
		return finish(false)
	end)
	
	if ok_key then
		if not activate_watcher(watcher_key, "keyboard") then activation_ok = false end
	else
		activation_ok = false
		Logger.error(LOG, "Failed to mount keyboard event listener: %s.", tostring(watcher_key))
	end

	if not activation_ok or not watchers_are_active() then
		stop_watchers_only()
		M.hide_forced()
		return false
	end
	return true
end

--- Runs watcher activation across the renderer callback boundary. Renderer
--- catches callback exceptions internally, so callers need an explicit status.
--- @return boolean ready Full verified set is active.
--- @return boolean crashed Activation raised unexpectedly.
local function activate_watchers_safely()
	local ok, result = xpcall(start_watchers, debug.traceback)
	if not ok then
		Logger.error(LOG, "Crash during dismissal watcher activation: %s.", tostring(result))
		return false, true
	end
	return result == true, false
end

--- Arms the one-shot dequeue timer for the next row expiry.
local function arm_dequeue_timer()
	if not stop_dequeue_timer() then return false end
	if not _dequeue_rows then return true end
	local delay = Dequeue.next_expiry_delay_sec(_dequeue_rows, hs.timer.secondsSinceEpoch(), _dequeue_opts)
	local schedule_delay = delay and math.max(0, delay) or 0
	local generation = _ui_generation
	local timer_handle = nil
	local timer_ok, timer_or_err = pcall(hs.timer.doAfter, schedule_delay, function()
		if _dequeue_timer ~= timer_handle then return end
		_dequeue_timer = nil
		if generation ~= _ui_generation then return end
		_dequeue_tick()
	end)
	if timer_ok then timer_handle = timer_or_err end
	if timer_ok and timer_or_err then _dequeue_timer = timer_or_err end
	local status_ok, running = false, nil
	if timer_ok then status_ok, running = timer_running(timer_or_err) end
	if not timer_ok or not timer_or_err or type(timer_or_err.stop) ~= "function"
		or not status_ok or running ~= true then
		Logger.error(LOG, "Cannot arm tooltip dequeue timer: %s.",
			tostring(timer_ok and (status_ok and "timer did not start" or running) or timer_or_err))
		if _dequeue_timer and stop_timer_verified(_dequeue_timer, "invalid tooltip dequeue timer") then
			_dequeue_timer = nil
		end
		return false
	end
	return true
end





-- =============================
-- =============================
-- ======= 2/ Public API =======
-- =============================
-- =============================

--- Runs a teardown transition without allowing an exception to disappear at an
--- eventtap/timer boundary.  Native renderer methods use strict booleans: a
--- protected call succeeding with nil/false is still a failed transition.
--- @param label string Stable operation label for the file logger.
--- @param callback function Zero-arity transition.
--- @return boolean committed
local function run_boolean_transition(label, callback)
	local ok, result = xpcall(callback, debug.traceback)
	if not ok then
		Logger.error(LOG, "%s failed: %s.", label, tostring(result))
		return false
	end
	return result == true
end

--- Forces the tooltip to hide regardless of any active dequeue cycle.
--- Only call this when an authoritative dismissal is required (e.g. the
--- keyboard watcher detected a real typing key, or an explicit hide() call
--- from outside the tooltip subsystem).
function M.hide_forced()
	local watchers_stopped = run_boolean_transition(
		"Hotstring tooltip watcher teardown", stop_watchers)
	local standard_hidden = run_boolean_transition(
		"Standard tooltip canvas teardown", Renderer.hide)
	local stacked_hidden = run_boolean_transition(
		"Stacked tooltip canvas teardown", Renderer.hide_stacked)
	-- Visibility follows the native surfaces.  A watcher may remain orphaned and
	-- still force the public return false, but it must not keep an already-hidden
	-- tooltip logically visible.
	if standard_hidden and stacked_hidden then
		_state.bg_color = nil
		_state.is_visible = false
		_visible_rows = nil
	end
	return watchers_stopped and standard_hidden and stacked_hidden
end

function M.hide()
	-- Mirror AHK's _TooltipDequeueActive guard: while a dequeue cycle is
	-- running, external hide() calls from mouse/scroll watchers are ignored
	-- so that rows with longer durations survive past the first row's expiry.
	-- The dequeue tick itself calls hide_forced() when the last row expires.
	if _dequeue_rows then return true end
	return M.hide_forced()
end

--- Resets internal state and stops watchers without hiding the shared canvas.
--- Used when transitioning to the LLM tooltip so the canvas content is overwritten
--- in-place rather than first blanked then redrawn, which would produce a visible gap.
function M.dismiss_silent()
	-- Hide the stacked canvas (hotstring preview) when transitioning away;
	-- without this it survives the LLM tooltip transition and stays on screen
	-- as an orphaned layer behind the new prediction canvas (E1 audit fix).
	local stacked_hidden = run_boolean_transition(
		"Stacked tooltip transition teardown", Renderer.hide_stacked)
	local watchers_stopped = run_boolean_transition(
		"Hotstring tooltip transition watcher teardown", stop_watchers)
	if stacked_hidden and watchers_stopped then
		_state.bg_color = nil
		_state.is_visible = false
		_visible_rows = nil
		return true
	end
	-- A silent in-place handoff is no longer safe.  Attempt authoritative cleanup
	-- while preserving the failed return so the LLM owner cannot publish success.
	M.hide_forced()
	return false
end

function M.show(content, is_llm_origin, is_enabled, background_color)
	local rendered = false
	local ok, err = pcall(function()
		if not is_enabled then return end
		if content == nil or tostring(content) == "" then M.hide_forced(); return end
		advance_ui_generation()

		-- Dismantle any active dequeue cycle before starting fresh — a stale
		-- dequeue timer would fire after this call and replace the new content
		-- with its pruned rows, erasing what we just rendered (E3 audit fix).
		if not stop_dequeue() then
			M.hide_forced()
			return
		end
		-- Hide any surviving stacked canvas from a prior hotstring expansion
		-- that was not cleaned up by a transition function (E1 audit fix).
		if Renderer.hide_stacked() ~= true then
			M.hide_forced()
			return
		end

		_state.bg_color = Config.settings.colorization_enabled and (type(background_color) == "table" and background_color or nil) or nil

		local styled_content = type(content) == "userdata" and content or hs.styledtext.new(tostring(content), {
			font  = { name = Config.fonts.main, size = Config.sizes.main, traits = is_llm_origin and { italic = true } or {} },
			color = is_llm_origin and { white = 0.80, alpha = 1.0 } or { white = 1.00, alpha = 1.0 },
		})

		local watcher_callback_ran = false
		local watcher_activation_ok = false
		local watcher_activation_crashed = false
		local render_committed = Renderer.render(styled_content, _state, function()
			watcher_callback_ran = true
			watcher_activation_ok, watcher_activation_crashed = activate_watchers_safely()
		end)
		if render_committed ~= true then
			M.hide_forced()
			return
		end
		if watcher_activation_crashed then
			M.hide_forced()
			return
		end
		if not watcher_callback_ran then
			M.hide_forced()
			return
		end
		if not watcher_activation_ok then return end
		_state.is_visible = true
		_visible_rows = nil
		rendered = true
	end)

	if not ok then
		Logger.error(LOG, "Crash during standard tooltip rendering: " .. tostring(err) .. ".")
		M.hide_forced()
	end
	return ok and rendered
end

--- Shows a persistent loading indicator with no auto-dismiss timer and no interaction watchers.
--- The indicator stays until explicitly replaced or hidden — it must never self-dismiss
--- mid-generation, which would leave a blank gap before the prediction tooltip arrives.
--- @param content string|userdata The loading text to display.
--- @param is_enabled boolean Guard clause to prevent rendering if disabled.
--- @param background_color table|nil Optional background tint.
function M.show_loading(content, is_enabled, background_color)
	local rendered = false
	local ok, err = pcall(function()
		if not is_enabled then return end
		if content == nil or tostring(content) == "" then M.hide_forced(); return end
		advance_ui_generation()

		-- Stop any existing watchers/timers from a previous state before rendering
		if not stop_watchers() then
			M.hide_forced()
			return
		end
		-- Hide any surviving stacked canvas from a prior hotstring preview;
		-- the loading indicator must render above a clean surface (E1 audit fix).
		if Renderer.hide_stacked() ~= true then
			M.hide_forced()
			return
		end

		_state.bg_color = Config.settings.colorization_enabled and (type(background_color) == "table" and background_color or nil) or nil

		local styled_content = type(content) == "userdata" and content or hs.styledtext.new(tostring(content), {
			font  = { name = Config.fonts.main, size = Config.sizes.main, traits = { italic = true } },
			color = { white = 0.80, alpha = 1.0 },
		})

		-- Loading owns no interaction watcher; this callback is only a synchronous
		-- commit marker proving that the canvas reached its shown state.
		local render_completed = false
		local render_committed = Renderer.render(
			styled_content, _state, function() render_completed = true end)
		if render_committed ~= true or not render_completed then
			M.hide_forced()
			return
		end
		_state.is_visible = true
		_visible_rows = nil
		rendered = true
	end)

	if not ok then
		Logger.error(LOG, "Crash during loading indicator rendering: " .. tostring(err) .. ".")
		M.hide_forced()
	end
	return ok and rendered
end

function M.is_visible()
	return _state.is_visible
end

--- Returns whether the exact leased row is still part of the visible stack.
--- A canvas-level visibility bit is insufficient: after one row dequeues, a
--- different dimmed row may keep the same canvas visible.
--- @param token any Opaque identity supplied by the preview owner.
--- @return boolean
function M.has_visible_lease(token)
	if token == nil or not _state.is_visible or not _visible_rows then return false end
	for _, row in ipairs(_visible_rows) do
		if row.lease_token == token then return true end
	end
	return false
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
	local rendered = false
	local ok, err = pcall(function()
		if not is_enabled then return end
		if not rows or #rows == 0 then M.hide_forced(); return end
		advance_ui_generation()

		-- Use the canonical Dequeue analysis so that any row (not just row[1])
		-- carrying an expire_at stamp is detected — checking only the first row
		-- caused premature stop_dequeue() on partial-expiry rebuilds (M-09)
		local is_rebuild = Dequeue.analyze_durations(rows, _dequeue_opts)
		-- An absolute first-render deadline describes row time, not native watcher
		-- ownership. Reuse is safe only when the current UI session still has every
		-- dismissal watcher live; otherwise the canvas would publish without guards.
		local reuse_watchers = is_rebuild and watchers_are_active()
		if not reuse_watchers then
			if not stop_dequeue() then
				M.hide_forced()
				return
			end
		end

		local function render_with_watcher_ownership(active_rows, reuse_watchers)
			local watcher_callback_ran = false
			local watcher_activation_ok = reuse_watchers == true and watchers_are_active() or false
			local watcher_activation_crashed = false
			local watcher_cb = function()
				watcher_callback_ran = true
				if not reuse_watchers then
					watcher_activation_ok, watcher_activation_crashed = activate_watchers_safely()
				end
			end
			local render_committed = Renderer.render_stacked(active_rows, _state, watcher_cb)
			if watcher_activation_crashed then M.hide_forced() end
			return render_committed == true and watcher_callback_ran and watcher_activation_ok
		end

		if Dequeue.should_use_dequeue_path(rows, _dequeue_opts) then
			local now = hs.timer.secondsSinceEpoch()
			_dequeue_rows = select(1, Dequeue.stamp_expiry_times(rows, now, _dequeue_opts))

			if not render_with_watcher_ownership(_dequeue_rows, reuse_watchers) then
				M.hide_forced()
				return
			end
			if not arm_dequeue_timer() then
				M.hide_forced()
				return
			end
		else
			if not stop_dequeue() then
				M.hide_forced()
				return
			end
			if not render_with_watcher_ownership(rows, false) then
				M.hide_forced()
				return
			end
		end
		_state.is_visible = true
		_visible_rows = _dequeue_rows or rows
		rendered = true
	end)
	if not ok then
		Logger.error(LOG, "Crash during stacked tooltip rendering: " .. tostring(err) .. ".")
		-- Authoritatively hide any partially committed canvas and revoke ownership.
		M.hide_forced()
	end
	return ok and rendered
end

-- Assign the dequeue tick function now that M.hide and M.show_stacked exist.
-- Prunes expired rows and re-renders the surviving stack, or hides when empty.
_dequeue_tick = function()
	local ok, err = xpcall(function()
		if not _dequeue_rows then return end
		local now = hs.timer.secondsSinceEpoch()
		local owner_expired = nil
		for _, row in ipairs(_dequeue_rows) do
			if row.expire_at and row.expire_at ~= 0 and now >= row.expire_at
				and type(row.on_expire) == "function"
			then
				owner_expired = row.on_expire
				break
			end
		end
		if owner_expired then
			-- Arbitration changed with the winner's deadline. Re-rendering the
			-- surviving rows in place would preserve stale dimmed/winner flags.
			-- Revoke the whole surface first, then ask the owner to resolve again.
			M.hide_forced()
			local callback_ok, callback_err = xpcall(owner_expired, debug.traceback)
			if not callback_ok then
				Logger.error(LOG, "Tooltip winner-expiry callback raised: %s.", tostring(callback_err))
			end
			return
		end
		local remaining = Dequeue.prune_expired(_dequeue_rows, now, _dequeue_opts)
		if #remaining == 0 then
			M.hide_forced()
			return
		end
		M.show_stacked(remaining, true)
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "Crash during tooltip dequeue callback: %s.", tostring(err))
		M.hide_forced()
	end
end

return M
