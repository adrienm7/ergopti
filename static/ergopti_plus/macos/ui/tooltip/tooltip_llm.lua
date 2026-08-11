--- ui/tooltip/tooltip_llm.lua

--- ==============================================================================
--- MODULE: Tooltip AI (LLM)
--- DESCRIPTION:
--- Manages the rendering, interaction, and lifecycle of AI predictions.
--- 
--- FEATURES & RATIONALE:
--- 1. Dedicated Context: Separates complex AI UI from simple hotstring alerts.
--- 2. Keyboard Intercepts: Handles arrow navigation and tab acceptance.
--- ==============================================================================

local M = {}
local hs = hs
local Logger = require("infra.logger")
local EventTapGuard = require("adapters.event_tap_guard")
local EventProvenance = require("adapters.event_provenance")
local SyntheticInput = require("adapters.synthetic_input")
local Keycodes = require("infra.keycodes")
local LOG = "tooltip_llm"

local Config = require("ui.tooltip.config")
local Renderer = require("ui.tooltip.renderer")
local HotPath = require("infra.hotpath_profiler")

local MAC_KEYCODES_NUMBERS = {
	[18] = 1, [19] = 2, [20] = 3, [21] = 4, [23] = 5,
	[22] = 6, [26] = 7, [28] = 8, [25] = 9, [29] = 10
}





-- ==================================
-- ==================================
-- ======= 1/ State Variables =======
-- ==================================
-- ==================================

local _state = {
	raw_predictions    = {},
	current_index      = 1,
	on_navigate        = nil,
	on_accept          = nil,
	on_cancel          = nil,
	info_bar           = nil,
	shortcut_mod       = "alt",
	nav_mods           = {},
	nav_mod_str        = "none",
	indent             = 0,
	fixed_width        = nil,
	bg_color           = nil,
	loading_text       = nil,
	enter_validates    = false,
	reserved_count     = 0,
	-- Set to true the first time the user navigates within an open tooltip
	-- (arrow keys, shift+Tab). Used by the Enter handler to choose between
	-- "accept current prediction" (post-navigation) and "let Enter through"
	-- (no navigation happened — Enter is just a normal newline). Reset to
	-- false on every show_predictions() and hide().
	navigation_started = false,
}

local _watchers = {}
local _idle_timer = nil
local _shift_side = nil  -- "left", "right", or nil when no shift is held
local _watcher_session_active = false
local _watcher_epoch = 0
local _ui_generation = 0
local REQUIRED_WATCHER_COUNT = 3

-- ── Chain timing instrumentation ─────────────────────────────────────────────
-- Backend-agnostic TTFT / TTLT measurement done at the tooltip level.
--   * _chain_start_time          — epoch seconds at the very first request of
--                                  the active chain. Set by prediction_engine
--                                  via M.set_chain_start(); reset on M.hide()
--                                  and on M.mark_chain_complete().
--   * _tooltip_first_show_at     — epoch seconds at the first paint of the
--                                  tooltip after a chain start. Used to
--                                  derive TTFT exactly once per chain.
--   * _last_update_at            — epoch seconds at the most recent render of
--                                  the tooltip during the current chain.
--                                  Refreshed on every show_predictions().
--   * _chain_ttft_ms             — cached TTFT once computed, so we can keep
--                                  showing it while streaming further tokens.
local _chain_start_time      = nil
local _tooltip_first_show_at = nil
local _last_update_at        = nil
local _chain_ttft_ms         = nil
-- Cached TTLT once the chain completes. Persisted alongside _chain_ttft_ms so
-- every full render in assemble_blocks rebuilds an info row that already
-- matches what set_timing draws via the partial-update path. Without this
-- cache, full renders would temporarily wipe the dernier-token segment and
-- create a one-frame flicker between a complete chain's "premier — dernier"
-- and the partial "premier" rebuilt from chain timing alone.
local _chain_ttlt_ms         = nil
-- Tracks whether the tooltip canvas is currently visible. Needed because
-- is_visible() must return true even during the loading state (empty
-- predictions, canvas shown with reserved slots) — raw_predictions is empty
-- in that case so a length check would incorrectly return false.
local _is_visible            = false
local _runtime_guard = function() return true end


local function runtime_available()
	local ok, available = pcall(_runtime_guard)
	return ok and available == true
end

--- Invalidates work classified against an older tooltip render.
local function advance_ui_generation()
	_ui_generation = _ui_generation + 1
end

--- Composes the info-bar text shown beneath the prediction list.
---   * `model_info` is the static "Model · Profile" header passed by
---     prediction_engine via show_predictions(..., info_bar, ...).
---   * `ttft_ms` / `ttlt_ms` are the per-chain timings captured locally.
--- The result is a single line: "Model · Profile — ⏱ X.XX s [— Y.YY s]".
--- Empty model_info, missing TTFT, missing TTLT are all handled — no
--- placeholder is rendered when nothing is known yet so the tooltip never
--- shows "—.—— s" filler.
--- @param model_info string|nil "Model · Profile" header text.
--- @param ttft_ms number|nil First-token latency (milliseconds).
--- @param ttlt_ms number|nil Last-token latency (milliseconds).
--- @param for_sizing boolean|nil When true, reserve width for the longest
---   plausible final string (model + ⏱ TTFT — TTLT). Used by the canvas
---   width-calc loop so the frame is wide enough for the post-chain
---   "TTLT appended" partial-update; without this, TTFT-only sizing led
---   to truncation when mark_chain_complete added " — Y.YY s" later.
--- @return string|nil Composed line, or nil when there is nothing to show.
local function format_info_line(model_info, ttft_ms, ttlt_ms, for_sizing)
	local has_model = type(model_info) == "string" and model_info ~= ""
	-- Require strictly positive timings: 0 / nil / negative all hide the
	-- value. Without the strict-positive guard, a partial-update fired
	-- with ttlt_ms = 0 (race during chain reset) would render a useless
	-- " — 0.00 s" suffix or, worse, the trailing em-dash with nothing
	-- behind it.
	local has_ttft = type(ttft_ms) == "number" and ttft_ms > 0
	local has_ttlt = type(ttlt_ms) == "number" and ttlt_ms > 0

	-- Sizing pass: pretend both timings are present with a generous worst-case
	-- value so the canvas frame is wide enough for the eventual full line.
	-- 9999 ms → "9.99 s"; TTLT can exceed 10s on slow models → use 999000 ms
	-- ("999.00 s") to guarantee the placeholder is never narrower than real data.
	local SIZING_PLACEHOLDER_MS = 999000
	if for_sizing then
		if not has_ttft then ttft_ms = SIZING_PLACEHOLDER_MS ; has_ttft = true end
		if not has_ttlt then ttlt_ms = SIZING_PLACEHOLDER_MS ; has_ttlt = true end
	end

	if not has_model and not has_ttft and not has_ttlt then
		return nil
	end
	local pieces = {}
	if has_model then pieces[#pieces + 1] = model_info end
	if has_ttft then
		local timing = string.format("⏱ %.2f s", ttft_ms / 1000)
		if has_ttlt then
			timing = timing .. string.format(" — %.2f s", ttlt_ms / 1000)
		end
		pieces[#pieces + 1] = timing
	elseif has_ttlt then
		-- Edge case: TTLT known without TTFT (chain ended before first paint)
		pieces[#pieces + 1] = string.format("⏱ %.2f s", ttlt_ms / 1000)
	end
	return table.concat(pieces, " — ")
end





-- ================================
-- ================================
-- ======= 2/ Event Control =======
-- ================================
-- ================================

--- Invokes a caller-owned callback without letting an exception disappear.
--- @param label string Stable callback label for the file logger.
--- @param callback function|nil Caller callback.
--- @param ... any Arguments forwarded to the callback.
--- @return boolean succeeded
local function invoke_user_callback(label, callback, ...)
	if type(callback) ~= "function" then return true end
	local arguments = table.pack(...)
	local ok, err = xpcall(function()
		callback(table.unpack(arguments, 1, arguments.n))
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "%s callback failed: %s.", tostring(label), tostring(err))
		return false
	end
	return true
end

--- Dismisses the tooltip through the FULL cancel contract.
---
--- Hiding is only half of a dismissal. The prediction engine tracks its own
--- `predictions_visible` flag and only the cancel callback clears it, so a path
--- that merely calls M.hide() leaves the engine believing a live prediction is
--- still on screen — and the next Tab or Enter applies the stale one the user
--- watched disappear. Every dismissal therefore goes through here rather than
--- calling M.hide() directly, so the pair can never come apart again.
--- @param reason string Why the tooltip is being dismissed, for the log.
local function dismiss(reason)
	Logger.debug(LOG, "Dismissing predictions tooltip (%s).", reason)
	local callback_ok = invoke_user_callback("Prediction cancel", _state.on_cancel)
	local hidden = M.hide()
	return callback_ok and hidden == true
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

--- Clears active timers and sets a new idle timeout if applicable.
--- @return boolean True when the deadline is owned and usable.
local function reset_idle_timer()
	if _idle_timer then
		if not stop_timer_verified(_idle_timer, "tooltip idle timer") then return false end
		_idle_timer = nil
	end
	local active_timeout = Config.settings.llm_timeout_sec

	if active_timeout > 0 then
		-- Was `M.hide` alone. The tooltip vanished on idle while the engine still
		-- had predictions_visible set, so the next Tab typed the prediction that
		-- had already timed out — text the user never asked for, from a tooltip
		-- that was no longer on screen.
		local generation = _ui_generation
		local timer_handle = nil
		local timer_ok, timer_or_err = pcall(hs.timer.doAfter, active_timeout, function()
			if not timer_handle or _idle_timer ~= timer_handle then return end
			_idle_timer = nil
			if generation ~= _ui_generation or not _watcher_session_active then return end
			if not runtime_available() then
				M.hide_silent()
				return
			end
			dismiss("idle timeout")
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
		Logger.debug(LOG, "Auto-hide idle timer (re)armed: %.1fs.", active_timeout)
	end
	return true
end

--- Terminates all active keyboard and mouse watchers.
--- A watcher whose stop cannot be verified remains owned so a later render can
--- retry cleanup without creating a duplicate eventtap beside the orphan.
--- @return boolean True when every watcher and the idle timer were revoked.
local function stop_watchers()
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
	-- Ownership begins when the OS object is returned, not when start() reports
	-- success: CGEventTap can enable before a Lua wrapper throws. Keeping the
	-- reference lets stop_watchers() retry instead of losing an active orphan.
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

--- Validates modifier flags securely against expected target mods.
--- @param current_flags table Keystroke modifiers active.
--- @param target_mods table List of required modifiers.
--- @return boolean True if matched exactly.
local function evaluate_modifiers(current_flags, target_mods)
	if type(target_mods) ~= "table" then return false end
	
	local flattened_mods = {}
	for _, mod in ipairs(target_mods) do
		if type(mod) == "string" then table.insert(flattened_mods, mod:lower())
		elseif type(mod) == "table" then
			for _, sub_mod in ipairs(mod) do if type(sub_mod) == "string" then table.insert(flattened_mods, sub_mod:lower()) end end
		end
	end
	
	if #flattened_mods == 1 and flattened_mods[1] == "none" then return false end
	
	local target_map = { cmd = false, alt = false, shift = false, ctrl = false }
	for _, mod in ipairs(flattened_mods) do if target_map[mod] ~= nil then target_map[mod] = true end end
	
	if (current_flags.cmd or false)   ~= target_map.cmd   then return false end
	if (current_flags.alt or false)   ~= target_map.alt   then return false end
	if (current_flags.shift or false) ~= target_map.shift then return false end
	if (current_flags.ctrl or false)  ~= target_map.ctrl  then return false end
	
	return true
end

--- Schedules one tooltip mutation after Quartz has received the eventtap return.
--- The runtime gate is rechecked because an older fenced action may invalidate
--- this tooltip between classification and the timer callback.
--- @param label string Diagnostic label.
--- @param fn function Deferred mutation.
--- @param ... any Arguments.
--- @return boolean scheduled
local function defer_runtime_action(label, fn, ...)
	local args = table.pack(...)
	local generation = _ui_generation
	return SyntheticInput.defer_after_callback(label, function()
		if generation ~= _ui_generation or not _watcher_session_active then return end
		if not runtime_available() then return end
		return fn(table.unpack(args, 1, args.n))
	end)
end

--- Defers the full cancel contract; stale runtime state is hidden silently.
--- @param reason string Dismissal reason.
--- @return boolean scheduled
local function defer_dismiss(reason)
	local generation = _ui_generation
	return SyntheticInput.defer_after_callback("LLM tooltip dismissal", function()
		if generation ~= _ui_generation or not _watcher_session_active then return end
		if runtime_available() then dismiss(reason) else M.hide_silent() end
	end)
end

--- Reports a watcher failure off CGEventTap and closes ambiguous UI state.
--- @param watcher string Watcher label.
--- @param err any Failure detail.
local function defer_watcher_failure(watcher, err)
	local generation = _ui_generation
	SyntheticInput.defer_after_callback("LLM tooltip watcher failure", function()
		Logger.error(LOG, "%s watcher failed: %s.", watcher, tostring(err))
		if generation ~= _ui_generation or not _watcher_session_active then return end
		if runtime_available() then dismiss(watcher .. " failure") else M.hide_silent() end
	end)
end

--- Starts OS-level interception to handle LLM navigation and dismissal.
local function start_watchers()
	if watchers_are_active() then
		if reset_idle_timer() then return true end
		if runtime_available() then
			dismiss("idle timer reset failure")
		else
			M.hide_silent()
		end
		return false
	end

	if not stop_watchers() then
		if runtime_available() then
			dismiss("watcher cleanup failure")
		else
			M.hide_silent()
		end
		return false
	end
	if not reset_idle_timer() then
		if runtime_available() then
			dismiss("idle timer activation failure")
		else
			M.hide_silent()
		end
		return false
	end
	_watcher_session_active = true
	_watcher_epoch = _watcher_epoch + 1
	local watcher_epoch = _watcher_epoch
	
	local event_types = hs.eventtap.event.types
	local activation_ok = true
	
	-- Mouse Watcher
	-- mouseMoved intentionally excluded: trackpad fires it at 200+ Hz, which adds
	-- HID-thread latency on every pointer event while the tooltip is visible. Clicks
	-- and scrolls are sufficient for dismissal; pure mouse movement should not
	-- interfere with input delivery.
	local ok_mouse, watcher_mouse
	ok_mouse, watcher_mouse = pcall(hs.eventtap.new,
		{ event_types.leftMouseDown, event_types.rightMouseDown, event_types.scrollWheel },
		function(event)
			if not _watcher_session_active or watcher_epoch ~= _watcher_epoch then return false end
			if EventTapGuard.handle_disabled(event, watcher_mouse, "tooltip.llm_mouse") then
				return false
			end
			local provenance, status, fence = EventProvenance.classify_with_fence(
				event, "tooltip.llm_mouse")
			local fence_events = fence and fence.events or nil
			if provenance ~= nil then return false, fence_events end
			if status == EventProvenance.STATUS_UNREADABLE then
				defer_dismiss("unreadable mouse provenance")
				return false, fence_events
			end
			if runtime_available() then defer_dismiss("mouse activity") end
			return false, fence_events
		end)
	
	if ok_mouse then
		if not activate_watcher(watcher_mouse, "mouse") then activation_ok = false end
	else
		activation_ok = false
		Logger.error(LOG, "Failed to mount mouse event listener: %s.", tostring(watcher_mouse))
	end

	-- Keyboard Watcher
	-- Track which shift key is held so Tab navigation uses the correct direction.
	-- Left shift + Tab  → previous prediction (-1)
	-- Right shift + Tab → next prediction    (+1)
	local ok_flags, watcher_flags
	ok_flags, watcher_flags = pcall(hs.eventtap.new, { event_types.flagsChanged }, function(event)
		if not _watcher_session_active or watcher_epoch ~= _watcher_epoch then return false end
		if EventTapGuard.handle_disabled(event, watcher_flags, "tooltip.llm_flags") then
			return false
		end
		local provenance, status, fence = EventProvenance.classify_with_fence(
			event, "tooltip.llm_flags")
		local fence_events = fence and fence.events or nil
		if provenance ~= nil then return false, fence_events end
		if status == EventProvenance.STATUS_UNREADABLE then
			_shift_side = nil
			return false, fence_events
		end
		if not runtime_available() then return false, fence_events end
		local ok, err = xpcall(function()
			local keycode = event:getKeyCode()
			local flags = event:getFlags()
			if not flags.shift then
				_shift_side = nil
			elseif keycode == 56 then
				_shift_side = "left"
			elseif keycode == 60 then
				_shift_side = "right"
			end
		end, debug.traceback)
		if not ok then
			_shift_side = nil
			defer_watcher_failure("modifier", err)
		end
		return false, fence_events
	end)
	if ok_flags then
		if not activate_watcher(watcher_flags, "modifier") then activation_ok = false end
	else
		activation_ok = false
		Logger.error(LOG, "Failed to mount modifier event listener: %s.", tostring(watcher_flags))
	end

	local ok_key, watcher_key
	ok_key, watcher_key = pcall(hs.eventtap.new, { event_types.keyDown }, function(event)
		if not _watcher_session_active or watcher_epoch ~= _watcher_epoch then return false end
		if EventTapGuard.handle_disabled(event, watcher_key, "tooltip.llm_key") then
			return false
		end
		local provenance, status, fence = EventProvenance.classify_with_fence(
			event, "tooltip.llm_key")
		local fence_events = fence and fence.events or nil
		local function finish(consume) return consume == true, fence_events end
		if provenance ~= nil then return finish(false) end
		if status == EventProvenance.STATUS_UNREADABLE then
			defer_dismiss("unreadable keyboard provenance")
			return finish(false)
		end
		-- A fenced action advances the epoch during classification. Revalidate it
		-- before inspecting stale tooltip state or deciding to consume the key.
		if not runtime_available() then return finish(false) end

		local read_ok, keycode, flags, chars = xpcall(function()
			local code = event:getKeyCode()
			local event_flags = event:getFlags()
			local event_chars = event:getCharacters(true)
				or event:getCharacters(false) or ""
			return code, event_flags, event_chars
		end, debug.traceback)
		if not read_ok then
			defer_watcher_failure("keyboard", keycode)
			return finish(false)
		end
		local is_submit_key = (keycode == Keycodes.RETURN or keycode == Keycodes.ENTER
			or chars == "\r" or chars == "\n")

		-- Handling Tab presses during LLM execution
		if keycode == Keycodes.TAB then
			if flags.shift then
				local preds_count = type(_state.raw_predictions) == "table" and #_state.raw_predictions or 0
				if preds_count > 1 then
					-- Left shift → back (-1), right shift → forward (+1)
					local direction = (_shift_side == "right") and 1 or -1
					local scheduled = defer_runtime_action("LLM tooltip Shift-Tab navigation",
						function()
							_state.navigation_started = true
							M.navigate(direction)
						end)
					return finish(scheduled)
				end
			else
				local has_other_modifiers = flags.cmd or flags.alt or flags.ctrl or (flags.shift == true)
				if not has_other_modifiers then
					-- Tab always accepts directly, regardless of prior navigation
					local index = _state.current_index
					local scheduled = defer_runtime_action("LLM tooltip Tab acceptance",
						function()
							if type(_state.on_accept) == "function" then _state.on_accept(index) end
						end)
					return finish(scheduled)
				end
				defer_dismiss("modified Tab")
				return finish(false)
			end
		end

		-- Handling Enter confirmation
		if is_submit_key then
			local has_other_modifiers = flags.cmd or flags.alt or flags.ctrl or flags.shift
			if not has_other_modifiers then
				-- Contextual Enter:
				--   • If the user has navigated at least once, treat Enter like Tab and
				--     accept the currently highlighted prediction (consume the keystroke).
				--   • Otherwise, Enter is just a normal newline — close the tooltip but
				--     let the keystroke flow through to the application.
				if _state.navigation_started then
					local index = _state.current_index
					local scheduled = defer_runtime_action("LLM tooltip Enter acceptance",
						function()
							if type(_state.on_accept) == "function" then _state.on_accept(index) end
						end)
					return finish(scheduled)
				end
				if _state.enter_validates then
					local index = _state.current_index
					local scheduled = defer_runtime_action("LLM tooltip validating Enter",
						function()
							if type(_state.on_accept) == "function" then _state.on_accept(index) end
						end)
					return finish(scheduled)
				end
				defer_dismiss("newline")
				return finish(false)
			else
				defer_dismiss("modified submit")
				return finish(false)
			end
		end

		-- Handling Arrow Navigation
		if keycode >= Keycodes.LEFT_ARROW and keycode <= Keycodes.UP_ARROW then
			local preds_count = type(_state.raw_predictions) == "table" and #_state.raw_predictions or 0
			if preds_count > 1 and evaluate_modifiers(flags, _state.nav_mods) then
				local nav_direction = (keycode == Keycodes.LEFT_ARROW or keycode == Keycodes.UP_ARROW) and -1 or 1
				-- Any arrow consumed for navigation marks the session as "user is engaged"
				-- and resets the auto-dismiss timer so the user never loses the tooltip
				-- mid-decision (timer reset is also done inside M.navigate()).
				local scheduled = defer_runtime_action("LLM tooltip arrow navigation",
					function()
						_state.navigation_started = true
						M.navigate(nav_direction)
					end)
				return finish(scheduled)
			end
		end
		
		-- Handling Hotkey Selection
		local shortcut_modifier = _state.shortcut_mod or "alt"
		if shortcut_modifier ~= "none" then
			local match_all = true
			local required_flags = {}
			
			for mod_str in shortcut_modifier:gmatch("[^+]+") do 
				required_flags[mod_str] = true
				if not flags[mod_str] then match_all = false; break end 
			end
			
			if match_all then
				for flag_name, flag_active in pairs(flags) do 
					if flag_active and not required_flags[flag_name] and (flag_name == "cmd" or flag_name == "alt" or flag_name == "shift" or flag_name == "ctrl") then 
						match_all = false
						break 
					end 
				end
			end
			
			if match_all and MAC_KEYCODES_NUMBERS[keycode] then
				local pred_index = MAC_KEYCODES_NUMBERS[keycode]
				local preds_count = type(_state.raw_predictions) == "table" and #_state.raw_predictions or 0
				if pred_index <= preds_count then
					local scheduled = defer_runtime_action("LLM tooltip numbered acceptance",
						function()
							if type(_state.on_accept) == "function" then _state.on_accept(pred_index) end
						end)
					return finish(scheduled)
				end
				return finish(true)
			end
		end
		
		-- F20 ("nav layer entered") signals that the user just engaged the
		-- navigation layer — this is a strong "user is actively using the
		-- tooltip" signal, so reset the auto-dismiss timer before letting the
		-- event flow through. F20 must NOT be treated as a real keystroke that
		-- dismisses the tooltip.
		if keycode == Keycodes.F20_LAYER_NAV_ENTERED then
			defer_runtime_action("LLM tooltip navigation-layer activity", reset_idle_timer)
			return finish(false)
		end

		-- Ignored system modifier keys (preventing unintended dismissals).
		-- 54-60 are physical modifiers; the rest are owned by lib.keycodes.
		local ignored_keycodes = {
			54, 55, 56, 58, 59, 60,
			-- Escape belongs to the persistent trap, not to this watcher. This tap
			-- is created per render, so it is always NEWER than the trap and runs
			-- first: dismissing here and returning false left the trap looking at
			-- an already-invisible tooltip, which is its signal to pass Escape
			-- through — and the keystroke reached the app, opening Raycast on
			-- every dismissal after the first show. Ignoring it lets the trap see
			-- a visible tooltip, consume the key, and reset the predictions.
			Keycodes.ESCAPE,
			Keycodes.F13_KARABINER_RETURN,
			Keycodes.F14_KARABINER_BACKSPACE,
			Keycodes.F15_KARABINER_ESCAPE,
			Keycodes.F16_LLM_CHAIN_SIGNAL,
			Keycodes.F17_CYCLE_WINDOWS,
			Keycodes.LAYER_SYN_1,
			Keycodes.LAYER_SYN_2,
			Keycodes.LAYER_SYN_3,
		}
		for _, ignored_code in ipairs(ignored_keycodes) do
			if keycode == ignored_code then return finish(false) end
		end
		
		defer_dismiss("keystroke")
		return finish(false)
	end)
	
	if ok_key then
		if not activate_watcher(watcher_key, "keyboard") then activation_ok = false end
	else
		activation_ok = false
		Logger.error(LOG, "Failed to mount keyboard event listener: %s.", tostring(watcher_key))
	end

	if not activation_ok or not watchers_are_active() then
		stop_watchers()
		if runtime_available() then
			dismiss("watcher activation failure")
		else
			M.hide_silent()
		end
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





-- ==================================
-- ==================================
-- ======= 3/ Text Formatting =======
-- ==================================
-- ==================================

--- Safely appends styled segments to a result string.
local function append_segment(result, text, color, is_bold)
	if not text or tostring(text) == "" then return result end
	local font_name = is_bold and Config.fonts.bold or Config.fonts.main
	local segment = hs.styledtext.new(tostring(text), { font = { name = font_name, size = Config.sizes.main }, color = color })
	return result and (result .. segment) or segment
end

--- Builds a single line of text reflecting the diff states with precise coloring.
--- @param prediction table The prediction payload.
--- @param is_selected boolean True if this prediction is currently highlighted.
--- @return userdata|nil The styled text object.
local function build_line(prediction, is_selected)
	if type(prediction) ~= "table" then return nil end

	local result = nil
	local diff_chunks = type(prediction.chunks) == "table" and prediction.chunks or {}
	local next_words = prediction.nw or ""

	local has_corrections = prediction.has_corrections == true
	local has_gray_reference = false
	
	for _, chunk in ipairs(diff_chunks) do
		if chunk.type == "equal" and tostring(chunk.text or ""):match("%S") then
			has_gray_reference = true
			break
		end
	end

	local apply_bold = has_corrections and has_gray_reference
	if prediction.disable_bold then apply_bold = false end

	local is_first_chunk_cleaned = false
	local function clean_leading_spaces(str)
		local safe_str = tostring(str or "")
		if not is_first_chunk_cleaned and safe_str ~= "" then
			safe_str = safe_str:gsub("^%s+", "")
			if safe_str ~= "" then is_first_chunk_cleaned = true end
		end
		return safe_str
	end

	local last_character = ""

	if #diff_chunks > 0 then
		for _, chunk in ipairs(diff_chunks) do
			if type(chunk) == "table" then
				local chunk_text = clean_leading_spaces(chunk.text)
				if chunk_text and chunk_text ~= "" then
					last_character = chunk_text:sub(-1)
					
					if chunk.type == "insert" then
						-- colorization_enabled controls the background tint only; text accent colors
						-- always apply to the selected item so it remains visually distinct
						local chunk_color = is_selected and Config.colors.corr_sel or Config.colors.unsel_gray
						local chunk_bold = (not is_selected) and apply_bold
						result = append_segment(result, chunk_text, chunk_color, chunk_bold)
					elseif chunk.type == "equal" then
						result = append_segment(result, chunk_text, Config.colors.unsel_gray, false)
					end
				end
			end
		end
	end

	local safe_next_words = clean_leading_spaces(next_words)
	if safe_next_words and safe_next_words ~= "" then
		if last_character ~= "" and not last_character:match("%s") and not safe_next_words:match("^%s") then
			safe_next_words = " " .. safe_next_words
		end
		
		local nw_color = is_selected and Config.colors.nw_sel or Config.colors.unsel_gray
		local nw_bold = (not is_selected) and apply_bold
		result = append_segment(result, safe_next_words, nw_color, nw_bold)
	end

	return result
end

--- Assembles all lines and bottom hints into styled blocks ready for rendering.
--- @param state table The global orchestrator state.
--- @param reserved_count number Spaces to reserve for loading predictions.
--- @return table The block components.
local function assemble_blocks(state, reserved_count)
	local active_count = type(state.raw_predictions) == "table" and #state.raw_predictions or 0
	local display_count = math.max(active_count, tonumber(reserved_count) or active_count)

	if active_count == 0 and (not reserved_count or tonumber(reserved_count) == 0) then 
		return { preds = hs.styledtext.new("") } 
	end

	local ui = Config.llm_ui
	local active_mark = ui.active_prefix
	local prefix_selected = ""
	local prefix_unselected = ""
	local visual_compensation_space = ui.inactive_align_char

	if display_count == 1 then prefix_selected = active_mark
	elseif display_count >= 2 and state.indent > 0 then prefix_selected = string.rep(" ", state.indent) .. active_mark
	else prefix_selected = active_mark
	end

	local indent_numeric = math.floor(tonumber(state.indent) or 0)
	if indent_numeric < 0 and indent_numeric > -3 then
		prefix_unselected = string.rep(" ", -indent_numeric)
	elseif indent_numeric <= -3 then
		prefix_unselected = prefix_selected .. string.rep(" ", math.max(0, (-indent_numeric) - 3))
	end

	if indent_numeric > -3 then prefix_unselected = prefix_unselected .. visual_compensation_space end

	local styled_prefix_unselected = hs.styledtext.new(prefix_unselected, { font = { name = Config.fonts.main, size = Config.sizes.main }, color = Config.colors.invis })
	local styled_prefix_empty = hs.styledtext.new("", { font = { name = Config.fonts.main, size = Config.sizes.main }, color = Config.colors.invis })
	local styled_gap = hs.styledtext.new("\n", { font = { name = Config.fonts.main, size = Config.sizes.gap }, color = Config.colors.invis })

	local assembled_result = nil

	for i = 1, display_count do
		local prediction = state.raw_predictions[i]
		local is_selected = (i == state.current_index and prediction ~= nil)
		
		local prefix_block = is_selected
			and hs.styledtext.new(prefix_selected, { font = { name = Config.fonts.main, size = Config.sizes.main }, color = Config.colors.cursor })
			or (prefix_unselected ~= "" and styled_prefix_unselected or styled_prefix_empty)

		local body_block
		if prediction ~= nil then
			body_block = build_line(prediction, is_selected)
			if not body_block then
				body_block = hs.styledtext.new("…", { font = { name = Config.fonts.main, size = Config.sizes.main, traits = { italic = true } }, color = Config.colors.unsel_gray })
			end
		else
			local placeholder_prefix = prefix_unselected ~= "" and styled_prefix_unselected or styled_prefix_empty
			body_block = hs.styledtext.new(ui.slot_placeholder, { font = { name = Config.fonts.main, size = Config.sizes.main, traits = { italic = true } }, color = Config.colors.loading })
			assembled_result = assembled_result and (assembled_result .. styled_gap .. (placeholder_prefix .. body_block)) or (placeholder_prefix .. body_block)
			goto continue
		end

		local shortcut_string = ""
		if display_count > 1 and state.shortcut_mod ~= "none" then
			local modifier_symbol = tostring(state.shortcut_mod):gsub("cmd", "⌘"):gsub("ctrl", "⌃"):gsub("alt", "⌥"):gsub("shift", "⇧"):gsub("%+", "")
			if modifier_symbol == "" or modifier_symbol == "nil" then modifier_symbol = "⌥" end
			
			local sc_gap = ui.shortcut_label_gap
			if i <= 9 then shortcut_string = sc_gap .. modifier_symbol .. i
			elseif i == 10 then shortcut_string = sc_gap .. modifier_symbol .. "0"
			end
		end

		local full_line
		if shortcut_string ~= "" then
			local shortcut_segment = hs.styledtext.new(shortcut_string, { font = { name = Config.fonts.main, size = Config.sizes.hint }, color = is_selected and Config.colors.cmd_sel or Config.colors.cmd_dim })
			full_line = prefix_block .. body_block .. shortcut_segment
		else
			full_line = prefix_block .. body_block
		end

		assembled_result = assembled_result and (assembled_result .. styled_gap .. full_line) or full_line
		::continue::
	end

	local space_divider = ui.footer_space_divider
	local styled_hint

	if display_count > 1 then
		local hint_left  = ui.hint_nav_left
		local hint_right = ui.hint_nav_right
		if state.nav_mod_str ~= "none" then
			local optional_nav_mod = (state.nav_mod_str ~= "" and state.nav_mod_str ~= "none") and (state.nav_mod_str .. " + ") or ""
			local hint_or = ui.hint_or
			hint_left  = hint_left  .. hint_or .. optional_nav_mod .. ui.hint_arrow_left
			hint_right = hint_right .. hint_or .. optional_nav_mod .. ui.hint_arrow_right
		end

		styled_hint = hs.styledtext.new(
			hint_left .. space_divider .. ui.hint_arrow_sep_left .. space_divider
				.. ui.hint_accept_center .. space_divider
				.. ui.hint_arrow_sep_right .. space_divider .. hint_right,
			{ font = { name = Config.fonts.main, size = Config.sizes.hint }, color = Config.colors.hint, paragraphStyle = { alignment = "center" } }
		)
	else
		styled_hint = hs.styledtext.new(ui.hint_accept_single,
			{ font = { name = Config.fonts.main, size = Config.sizes.hint }, color = Config.colors.hint, paragraphStyle = { alignment = "center" } })
	end

	-- Info row composes the static model/profile header (state.info_bar) with
	-- the live chain timing (TTFT / TTLT). set_timing() partial-updates
	-- ELEM_INFO with the same composition so full renders never wipe the
	-- timing line and there is no flicker.
	-- state._sizing_pass = true is set by the width-calc loop in
	-- show_predictions; in that mode, format_info_line is asked to reserve
	-- width for the longest plausible final string (model + ⏱ TTFT — TTLT)
	-- so the post-chain partial-update appending TTLT does not exceed the
	-- canvas frame and clip the info zone.
	local styled_info = nil
	local info_text = format_info_line(state.info_bar, _chain_ttft_ms, _chain_ttlt_ms, state._sizing_pass == true)
	if info_text then
		styled_info = hs.styledtext.new(info_text, { font = { name = Config.fonts.main, size = Config.sizes.info }, color = Config.colors.info_bar, paragraphStyle = { alignment = "center" } })
	end

	return { preds = assembled_result, hint_st = styled_hint, info_st = styled_info, SP = space_divider }
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

--- Updates the variable info-bar zone with a TTFT / TTLT timing line.
--- Uses the renderer's partial-update path — does NOT recreate the canvas, so
--- there is no flicker during a streaming chain.
--- @param ttft_ms number|nil First-token latency in milliseconds (nil to omit).
--- @param ttlt_ms number|nil Last-token latency in milliseconds (nil while streaming).
function M.set_timing(ttft_ms, ttlt_ms)
	if not runtime_available() then return false end
	local ok, updated_or_err = xpcall(function()
		local text = format_info_line(_state.info_bar, ttft_ms, ttlt_ms)
		if not text then
			return Renderer.set_element_text(Renderer.ELEM_INFO, nil) == true
		end
		local styled = hs.styledtext.new(text, {
			font           = { name = Config.fonts.main, size = Config.sizes.info },
			color          = Config.colors.info_bar,
			paragraphStyle = { alignment = "center" },
		})
		return Renderer.set_element_text(Renderer.ELEM_INFO, styled) == true
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "Crash during tooltip timing update: %s.", tostring(updated_or_err))
		return false
	end
	return updated_or_err == true
end


--- Records the epoch timestamp at which the active chain started.
--- Called by prediction_engine right before the first backend dispatch of a
--- chain. Successive calls within the same chain are ignored — only the very
--- first sets the origin so TTLT spans the entire chain, not the last link.
--- @param timestamp number Epoch seconds (typically hs.timer.secondsSinceEpoch()).
function M.set_chain_start(timestamp)
	if not runtime_available() then return false end
	if type(timestamp) ~= "number" then
		Logger.error(LOG, "set_chain_start(): timestamp must be a number, got %s.", type(timestamp))
		return
	end
	-- Always overwrite. The previous "keep if already armed" guard meant a
	-- transient M.hide() between perform_check and the actual streaming
	-- show_predictions wiped the chain (M.hide used to reset timing) and
	-- the next set_chain_start was a no-op, so TTFT was never captured.
	-- A fresh overwrite per perform_check is what we want anyway: TTFT
	-- measures the latest dispatch's first-token latency, which is the
	-- number the user actually cares about.
	_chain_start_time      = timestamp
	_tooltip_first_show_at = nil
	_last_update_at        = nil
	_chain_ttft_ms         = nil
	_chain_ttlt_ms         = nil
	Logger.debug(LOG, "Chain timing armed at epoch %.3f.", timestamp)
	return true
end

--- Internal helper: must be called BEFORE assemble_blocks so the freshly
--- captured TTFT is included in the full render path. Captures the
--- first-show timestamp and refreshes the last-update timestamp.
--- Without pre-render capture, the first paint shows just the model header
--- (TTFT still nil), the partial-update from a post-render call would then
--- have to retro-fit the wider "Model · … — ⏱ X.XX s" string into a
--- canvas element whose frame was sized for the shorter model-only text —
--- which clips the timing off the visible area.
local function refresh_chain_timing()
	if not _chain_start_time then return end

	local now = hs.timer.secondsSinceEpoch()
	_last_update_at = now

	if not _tooltip_first_show_at then
		_tooltip_first_show_at = now
		_chain_ttft_ms         = (now - _chain_start_time) * 1000
		Logger.debug(LOG, "TTFT captured: %.0f ms.", _chain_ttft_ms)
	end
end

--- Finalises the active chain: computes TTLT from the last update timestamp
--- and updates the timing zone with both values. Called by prediction_engine
--- when the chain ends (success or failure — both paths benefit from timing).
--- The internal chain state is NOT reset here — only M.hide() does that. This
--- allows the function to be invoked at the end of every chain link to refresh
--- the displayed TTLT while the chain origin keeps growing across links.
function M.mark_chain_complete()
	if not runtime_available() then return false end
	if not _chain_start_time then
		Logger.debug(LOG, "mark_chain_complete: no chain in progress — ignoring.")
		return
	end

	local final_update = _last_update_at or hs.timer.secondsSinceEpoch()
	local ttlt_ms = (final_update - _chain_start_time) * 1000
	-- TTFT may still be nil if the chain ended before the tooltip ever showed
	-- (e.g. all predictions filtered out). Fall back to ttlt so the user still
	-- gets a meaningful number rather than a blank line.
	local ttft_ms = _chain_ttft_ms or ttlt_ms

	-- Cache TTLT so subsequent full renders rebuild the same "premier — dernier"
	-- string the partial-update path draws — no flicker on streaming follow-ups.
	_chain_ttlt_ms = ttlt_ms
	Logger.debug(LOG, "Chain link complete — TTFT: %.0f ms | TTLT: %.0f ms.", ttft_ms, ttlt_ms)
	return M.set_timing(ttft_ms, ttlt_ms) == true
end

function M.set_navigate_callback(callback) _state.on_navigate = callback end
function M.set_accept_callback(callback) _state.on_accept = callback end
function M.set_cancel_callback(callback) _state.on_cancel = callback end
function M.set_enter_validates(validates) _state.enter_validates = (validates == true) end
function M.get_current_index()
	if not runtime_available() then return nil end
	return _state.current_index
end

--- Sets the auto-dismiss timeout used by the internal idle timer.
--- Pass 0 to keep the tooltip visible indefinitely until user interaction.
--- @param seconds number The timeout duration in seconds.
function M.set_timeout(seconds)
	Config.settings.llm_timeout_sec = math.max(0, tonumber(seconds) or 0)
end
 
--- Resets the internal idle timer using the currently configured timeout.
--- Called by llm_bridge after every navigation and once predictions are final.
function M.reset_timer()
	if not runtime_available() then return false end
	if not _is_visible then return false end
	if not watchers_are_active() then
		dismiss("idle timer reset without active watchers")
		return false
	end
	if reset_idle_timer() then return true end
	dismiss("idle timer reset failure")
	return false
end
 

local function hide_impl(log_callsite)
	if log_callsite then
		-- Debug lens for the "prediction vanished the instant it appeared" class of
		-- bug: record WHO hid the tooltip. The action-epoch path uses hide_silent()
		-- because Logger.debug may write synchronously from the keyboard eventtap.
		local info = debug.getinfo(3, "Sl")
		local caller = info and (tostring(info.short_src) .. ":" .. tostring(info.currentline)) or "?"
		Logger.debug(LOG, "HIDE predictions tooltip (was showing %d) — caller %s.",
			type(_state.raw_predictions) == "table" and #_state.raw_predictions or 0, caller)
	end
	local stop_ok, stop_result = xpcall(stop_watchers, debug.traceback)
	local watchers_stopped = stop_ok and stop_result == true
	if not stop_ok and log_callsite then
		Logger.error(LOG, "Crash while stopping prediction tooltip watchers: %s.",
			tostring(stop_result))
	end

	local hide_ok, hide_result = xpcall(Renderer.hide, debug.traceback)
	local canvas_hidden = hide_ok and hide_result == true
	if not hide_ok and log_callsite then
		Logger.error(LOG, "Crash while hiding prediction tooltip canvas: %s.",
			tostring(hide_result))
	end

	-- Logical visibility describes native pixels, not watcher ownership.  If the
	-- canvas is observably hidden, clear the visual state even when a separate
	-- watcher teardown failed; the false return still exposes that orphan.
	if canvas_hidden then
		_is_visible               = false
		_state.raw_predictions    = {}
		_state.current_index      = 1
		_state.info_bar           = nil
		_state.fixed_width        = nil
		_state.bg_color           = nil
		_state.loading_text       = nil
		_state.enter_validates    = false
		_state.navigation_started = false
		-- IMPORTANT: do NOT reset chain timing here. The keymap layer can
		-- call hide() at any moment between set_chain_start (in
		-- perform_check) and the actual streaming show_predictions — for
		-- example after a backspace or a fresh keystroke. Wiping
		-- _chain_start_time here meant refresh_chain_timing skipped TTFT
		-- capture for the entire chain that came right after, so the
		-- timing zone never rendered. The lifecycle of chain timing is
		-- now owned exclusively by set_chain_start (overwrites on every
		-- new perform_check).
	end
	return watchers_stopped and canvas_hidden
end

function M.hide() return hide_impl(true) end

--- Hides immediately without file-backed diagnostic logging.
--- Used by keyDown reconciliation where stale UI must disappear synchronously
--- but no logger sink may run inside the eventtap callback.
function M.hide_silent() return hide_impl(false) end

function M.navigate(delta)
	if not runtime_available() then return false end
	local completed = false
	local ok, err = pcall(function()
		local active_count = type(_state.raw_predictions) == "table" and #_state.raw_predictions or 0
		if active_count < 2 then
			completed = true
			return
		end
		
		advance_ui_generation()
		_state.current_index = ((_state.current_index - 1 + delta) % active_count) + 1
		local watcher_callback_ran = false
		local watcher_activation_ok = false
		local watcher_activation_crashed = false
		local render_committed = Renderer.render(
			assemble_blocks(_state, _state.reserved_count), _state, function()
			watcher_callback_ran = true
			watcher_activation_ok, watcher_activation_crashed = activate_watchers_safely()
		end)
		if render_committed ~= true then
			dismiss("navigation render did not commit")
			return
		end
		if watcher_activation_crashed then
			dismiss("watcher activation crash")
			return
		end
		if not watcher_callback_ran then
			dismiss("render did not arm watchers")
			return
		end
		if not watcher_activation_ok then return end
		
		if not invoke_user_callback("Prediction navigation", _state.on_navigate,
			_state.current_index) then
			dismiss("navigation callback failure")
			return
		end
		completed = true
	end)
	
	if not ok then
		Logger.error(LOG, "Crash during navigation execution: " .. tostring(err) .. ".")
		if runtime_available() then dismiss("navigation render failure") else M.hide_silent() end
	end
	return ok and completed
end

function M.show_predictions(predictions, current_index, is_enabled, info_bar, shortcut_modifier, indent, navigation_modifiers, background_color, loading_text, max_reserved_count)
	if not runtime_available() then return false end
	-- Latency tripwire: this runs on the streaming hot path (re-fired per token),
	-- so a slow assemble/width-calc/render surfaces as one WARNING instead of an
	-- invisible per-keystroke drag. Silent when the render is fast.
	local _hot_t0 = HotPath.now()
	local rendered = false
	local ok, err = pcall(function()
		if not is_enabled then return end
		
		local active_count = type(predictions) == "table" and #predictions or 0
		local reserved_slots = tonumber(max_reserved_count) or 0
		
		if active_count == 0 and reserved_slots == 0 then
			M.hide()
			return
		end

		advance_ui_generation()
		_state.raw_predictions = type(predictions) == "table" and predictions or {}
		_state.current_index   = current_index or 1
		_state.info_bar        = info_bar
		_state.shortcut_mod    = shortcut_modifier or "alt"
		_state.nav_mods        = type(navigation_modifiers) == "table" and navigation_modifiers or {}
		_state.indent          = indent or 0
		_state.bg_color        = Config.settings.colorization_enabled and (type(background_color) == "table" and background_color or nil) or nil
		_state.loading_text    = loading_text
		
		local flattened_nav_modifiers = {}
		for _, mod in ipairs(_state.nav_mods) do
			if type(mod) == "string" then table.insert(flattened_nav_modifiers, mod)
			elseif type(mod) == "table" then
				for _, sub_mod in ipairs(mod) do if type(sub_mod) == "string" then table.insert(flattened_nav_modifiers, sub_mod) end end
			end
		end

		local nav_modifier_string = "none"
		if #flattened_nav_modifiers > 0 and not (#flattened_nav_modifiers == 1 and flattened_nav_modifiers[1] == "none") then
			nav_modifier_string = table.concat(flattened_nav_modifiers, "+")
			nav_modifier_string = nav_modifier_string:gsub("cmd", "⌘"):gsub("ctrl", "⌃"):gsub("alt", "⌥"):gsub("shift", "⇧"):gsub("%+", "")
		elseif #flattened_nav_modifiers == 0 then 
			nav_modifier_string = "" 
		end
		_state.nav_mod_str = nav_modifier_string

		-- Capture TTFT BEFORE the width-calculation loop so format_info_line
		-- sees a non-nil _chain_ttft_ms when it composes the info line during
		-- the simulated assemble_blocks calls below. Otherwise the width is
		-- locked to the shorter "Model · Profile" string (no timing yet) and
		-- the real render that DOES include "— ⏱ X.XX s" gets clipped to
		-- that narrower frame, hiding the timing zone off-screen.
		refresh_chain_timing()

		local render_count = math.max(1, math.floor(reserved_slots > 0 and reserved_slots or active_count))
		local calculated_max_width = 0

		-- The footer (hint / info / combined) is index-invariant: assemble_blocks
		-- derives it from display_count, nav_mod_str, info_bar and the chain
		-- timings — never from current_index. minimumTextSize is an ObjC
		-- text-layout call on the streaming hot path, so measure the footer once
		-- and reuse it, as renderer.lua already does for its hoisted size_combined.
		-- Only blocks.preds varies per slot (the highlighted row moves), so that
		-- one stays inside the loop.
		local width_hint_memo, width_info_memo, width_combined_memo

		for i = 1, render_count do
			local simulation_state = {}
			for k, v in pairs(_state) do simulation_state[k] = v end
			simulation_state.current_index = i
			-- Tell assemble_blocks to size the info row for the worst-case
			-- "Model · Profile — ⏱ X.XX s — Y.YY s" string even if TTLT is
			-- not known yet. Otherwise the post-chain partial-update that
			-- appends ' — Y.YY s' would exceed the frame and clip both ends.
			simulation_state._sizing_pass = true

			local blocks = assemble_blocks(simulation_state, render_count)
			local width_predictions = Renderer.canvas:minimumTextSize(3, blocks.preds).w
			if width_hint_memo == nil then
				width_hint_memo = blocks.hint_st and Renderer.canvas:minimumTextSize(3, blocks.hint_st).w or 0
				width_info_memo = blocks.info_st and Renderer.canvas:minimumTextSize(3, blocks.info_st).w or 0
			end
			local width_hint = width_hint_memo
			local width_info = width_info_memo

			local final_width = width_predictions
			if blocks.info_st and blocks.hint_st then
				if width_combined_memo == nil then
					local ui = Config.llm_ui
					local space_divider = blocks.SP or ui.footer_space_divider
					local combined_sep  = ui.footer_combined_sep
					local separator_styled = hs.styledtext.new(space_divider .. combined_sep .. space_divider, { font = { name = Config.fonts.main, size = Config.sizes.hint } })
					local combined_styled = hs.styledtext.new("") .. blocks.hint_st .. separator_styled .. blocks.info_st
					width_combined_memo = Renderer.canvas:minimumTextSize(3, combined_styled).w
				end

				if width_combined_memo > width_predictions then final_width = math.max(width_predictions, width_hint, width_info) end
			else
				final_width = math.max(width_predictions, width_hint, width_info)
			end
			
			if final_width > calculated_max_width then calculated_max_width = final_width end
		end

		_state.fixed_width        = calculated_max_width
		_state.reserved_count     = render_count
		_state.enter_validates    = false
		-- Fresh tooltip session: user has not navigated yet, so an Enter press
		-- right now is a "real" newline and should pass through.
		_state.navigation_started = false

		local watcher_callback_ran = false
		local watcher_activation_ok = false
		local watcher_activation_crashed = false
		local render_committed = Renderer.render(assemble_blocks(_state, render_count), _state, function()
			watcher_callback_ran = true
			watcher_activation_ok, watcher_activation_crashed = activate_watchers_safely()
		end)
		if render_committed ~= true then
			dismiss("prediction render did not commit")
			return
		end
		if watcher_activation_crashed then
			dismiss("watcher activation crash")
			return
		end
		if not watcher_callback_ran then
			dismiss("render did not arm watchers")
			return
		end
		if not watcher_activation_ok then return end

		-- Only flip the visibility flag after Renderer.render() has returned
		-- without raising. Setting it earlier (before the width-calc loop and
		-- the render call) left _is_visible stuck true forever if any of that
		-- work threw — is_visible() is read by llm_bridge.lua to decide whether
		-- keystrokes are routed to the tooltip, so a stuck-true flag with no
		-- actual canvas on screen silently misroutes every subsequent keypress.
		_is_visible = true
		rendered = true
	end)

	if not ok then
		Logger.error(LOG, "Crash during show_predictions initialization: " .. tostring(err) .. ".")
		if runtime_available() then dismiss("prediction render failure") else M.hide_silent() end
	elseif rendered then
		Logger.debug(LOG, "SHOW predictions: %d active, %d reserved (idle timer armed in start_watchers).",
			type(_state.raw_predictions) == "table" and #_state.raw_predictions or 0,
			tonumber(_state.reserved_count) or 0)
	end
	HotPath.log_if_slow("tooltip.show_predictions", _hot_t0, "LLM prediction render")
	return ok and rendered
end

function M.make_diff_styled(diff_chunks, next_words, fallback_text)
	local ok, result = pcall(function()
		local prediction_mock = { chunks = type(diff_chunks) == "table" and diff_chunks or {}, nw = tostring(next_words or ""), has_corrections = true }
		return build_line(prediction_mock, true)
	end)
	return ok and result or hs.styledtext.new(tostring(fallback_text))
end

function M.is_visible()
	return runtime_available() and _is_visible
end

--- Installs the live action-epoch predicate used by every LLM watcher/render.
--- @param fn function|nil Zero-arity predicate.
function M.set_runtime_guard(fn)
	_runtime_guard = type(fn) == "function" and fn or function() return true end
end

return M
