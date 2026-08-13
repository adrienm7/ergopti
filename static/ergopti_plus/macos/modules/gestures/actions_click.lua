--- modules/gestures/actions_click.lua

--- ==============================================================================
--- MODULE: Gestures Synthetic Click Hold
--- DESCRIPTION:
--- Owns the synthetic left/right "click-hold" subsystem: posting a held mouse
--- button, converting idle mouse-moves into drag events, and auto-releasing the
--- hold on the next keypress. The complete native eventtap lifecycle is kept in
--- this module so a partially acquired or partially released hold stays visible
--- and retryable instead of leaving macOS with an unowned button-down state.
---
--- FEATURES & RATIONALE:
--- 1. Transactional acquisition — both required eventtaps are constructed and
---    proven active before a mouseDown or held-state bit can be published.
--- 2. Exact teardown ownership — refused native stops retain their exact handles
---    as callback-inert cleanup debt which every later acquisition must settle.
--- 3. Generation-fenced callbacks — callbacks from rolled-back or replaced taps
---    cannot release, drag, or re-engage a newer synthetic hold.
--- 4. Retryable release — a failed mouseUp keeps the held-state bit and release
---    capability visible so force_cleanup can retry rather than stranding a button.
--- ==============================================================================

local M = {}

local hs              = hs
local Logger          = require("infra.logger")
local EventProvenance = require("adapters.event_provenance")
local SyntheticInput  = require("adapters.synthetic_input")
local Timings         = require("infra.timings")
local LOG             = "gestures.click"

-- Delay to ignore the spurious mouseUp from the gesture’s own finger-lift
local CLICK_COOLDOWN_SEC = Timings.sec("gestures", "click_cooldown_ms")

local rightClickHeld = false
local leftClickHeld  = false

local rightMouseTap           = nil
local rightMouseTapCommitted  = false
local rightMouseTapGeneration = 0
local leftMouseTap            = nil
local leftMouseTapCommitted   = false
local leftMouseTapGeneration  = 0

local click_key_watcher            = nil
local click_key_watcher_committed  = false
local click_key_watcher_generation = 0

-- Exact native handles whose stop result was not positively committed
local tap_cleanup_debt = {}





-- ==========================================
-- ==========================================
-- ======= 1/ Native Tap Transactions =======
-- ==========================================
-- ==========================================

--- Returns whether a side currently owns a synthetic button-down state.
--- @param side string Either "left" or "right".
--- @return boolean held True while that exact button still requires mouseUp.
local function side_is_held(side)
	if side == "left" then return leftClickHeld end
	return rightClickHeld
end

--- Publishes the held state for one side.
--- @param side string Either "left" or "right".
--- @param held boolean New exact button ownership state.
local function set_side_held(side, held)
	if side == "left" then
		leftClickHeld = held
	else
		rightClickHeld = held
	end
end

--- Returns the currently published drag tap for one side.
--- @param side string Either "left" or "right".
--- @return table|userdata|nil tap Exact native tap handle.
local function side_tap(side)
	if side == "left" then return leftMouseTap end
	return rightMouseTap
end

--- Returns whether one side’s drag tap is committed.
--- @param side string Either "left" or "right".
--- @return boolean committed True only after native start and isEnabled succeed.
local function side_tap_is_committed(side)
	if side == "left" then return leftMouseTapCommitted end
	return rightMouseTapCommitted
end

--- Returns the current callback generation for one side.
--- @param side string Either "left" or "right".
--- @return integer generation Current lifecycle generation.
local function side_generation(side)
	if side == "left" then return leftMouseTapGeneration end
	return rightMouseTapGeneration
end

--- Publishes one exact committed drag tap.
--- @param side string Either "left" or "right".
--- @param tap table|userdata Exact native tap handle.
--- @param generation integer Callback generation captured by this handle.
local function publish_side_tap(side, tap, generation)
	if side == "left" then
		leftMouseTap = tap
		leftMouseTapCommitted = true
		leftMouseTapGeneration = generation
	else
		rightMouseTap = tap
		rightMouseTapCommitted = true
		rightMouseTapGeneration = generation
	end
end

--- Fences one side before any native stop attempt.
--- @param side string Either "left" or "right".
local function fence_side_tap(side)
	if side == "left" then
		leftMouseTapCommitted = false
		leftMouseTapGeneration = leftMouseTapGeneration + 1
	else
		rightMouseTapCommitted = false
		rightMouseTapGeneration = rightMouseTapGeneration + 1
	end
end

--- Removes a released exact handle from every owner slot it occupied.
--- @param handle table|userdata Exact native tap handle.
local function clear_released_handle(handle)
	if click_key_watcher == handle and not click_key_watcher_committed then
		click_key_watcher = nil
	end
	if leftMouseTap == handle and not leftMouseTapCommitted then
		leftMouseTap = nil
	end
	if rightMouseTap == handle and not rightMouseTapCommitted then
		rightMouseTap = nil
	end
end

--- Calls one native tap stop method and interprets its exact result.
--- @param handle table|userdata Exact native tap handle.
--- @return boolean stopped True only when stop returned a truthy capability.
--- @return string|nil detail Traceback or refusal detail.
local function stop_native_tap(handle)
	local method_ok, stop_method = pcall(function() return handle.stop end)
	if not method_ok or type(stop_method) ~= "function" then
		return false, method_ok and "stop method unavailable" or tostring(stop_method)
	end
	local stopped, result_or_err = xpcall(function()
		return stop_method(handle)
	end, debug.traceback)
	if not stopped or result_or_err == nil or result_or_err == false then
		return false, tostring(result_or_err)
	end
	local enabled_method_ok, enabled_method = pcall(function() return handle.isEnabled end)
	if not enabled_method_ok or type(enabled_method) ~= "function" then
		return false, enabled_method_ok and "isEnabled method unavailable" or tostring(enabled_method)
	end
	local enabled_ok, enabled_or_err = xpcall(function()
		return enabled_method(handle)
	end, debug.traceback)
	if not enabled_ok or enabled_or_err ~= false then
		return false, enabled_ok and "tap remained enabled" or tostring(enabled_or_err)
	end
	return true
end

--- Releases one exact tap or retains it as retryable cleanup debt.
--- @param handle table|userdata|nil Exact native tap handle.
--- @param label string Diagnostic owner label.
--- @return boolean settled True only when no native capability remains.
--- @return string|nil detail Native refusal detail.
local function release_tap_handle(handle, label)
	if handle == nil or handle == false then return true end
	local settled, detail = stop_native_tap(handle)
	if settled then
		tap_cleanup_debt[handle] = nil
		clear_released_handle(handle)
		return true
	end
	tap_cleanup_debt[handle] = label
	return false, detail
end

--- Retries every exact tap retained after a refused rollback or stop.
--- @return boolean settled True only when no cleanup debt remains.
local function retry_tap_cleanup()
	local snapshot = {}
	for handle, label in pairs(tap_cleanup_debt) do
		snapshot[#snapshot + 1] = { handle = handle, label = label }
	end
	local settled = true
	for _, item in ipairs(snapshot) do
		local released, detail = release_tap_handle(item.handle, item.label)
		if not released then
			settled = false
			Logger.error(LOG, "%s cleanup remains pending: %s.", item.label, tostring(detail))
		end
	end
	return settled
end

--- Starts one native tap and verifies that it is actually enabled.
--- @param candidate table|userdata Exact candidate handle.
--- @return boolean committed True only after start and isEnabled commit.
--- @return string|nil detail Native refusal detail.
local function start_native_tap(candidate)
	local start_method_ok, start_method = pcall(function() return candidate.start end)
	if not start_method_ok or type(start_method) ~= "function" then
		return false, start_method_ok and "start method unavailable" or tostring(start_method)
	end
	local started, result_or_err = xpcall(function()
		return start_method(candidate)
	end, debug.traceback)
	if not started or result_or_err == nil or result_or_err == false then
		return false, tostring(result_or_err)
	end

	local enabled_method_ok, enabled_method = pcall(function() return candidate.isEnabled end)
	if not enabled_method_ok or type(enabled_method) ~= "function" then
		return false, enabled_method_ok and "isEnabled method unavailable" or tostring(enabled_method)
	end
	local enabled_ok, enabled_or_err = xpcall(function()
		return enabled_method(candidate)
	end, debug.traceback)
	if not enabled_ok or enabled_or_err ~= true then
		return false, tostring(enabled_or_err)
	end
	return true
end

--- Constructs one native eventtap without publishing it.
--- @param watched_types table Native event types.
--- @param callback function Generation-fenced native callback.
--- @return table|userdata|nil candidate Exact constructed handle.
--- @return string|nil detail Constructor refusal detail.
local function construct_eventtap(watched_types, callback)
	local candidate = nil
	local constructed, result_or_err = xpcall(function()
		candidate = hs.eventtap.new(watched_types, callback)
		return candidate
	end, debug.traceback)
	if not constructed or result_or_err == nil or result_or_err == false then
		return nil, tostring(result_or_err)
	end
	return candidate
end

--- Stops every candidate created by one rejected acquisition attempt.
--- @param candidates table Array of exact candidate/label pairs.
--- @return boolean settled True only when every candidate was released.
local function rollback_candidates(candidates)
	local settled = true
	for index = #candidates, 1, -1 do
		local item = candidates[index]
		local released, detail = release_tap_handle(item.handle, item.label)
		if not released then
			settled = false
			Logger.error(LOG, "%s rollback remains pending: %s.", item.label, tostring(detail))
		end
	end
	return settled
end





-- ================================================
-- ================================================
-- ======= 2/ Keyboard Auto-Release Watcher =======
-- ================================================
-- ================================================

--- Stops the keyboard watcher after fencing every queued callback.
--- @return boolean settled True only when its exact native handle was released.
local function stop_click_key_watcher()
	local candidate = click_key_watcher
	click_key_watcher_committed = false
	click_key_watcher_generation = click_key_watcher_generation + 1
	if not candidate then return true end
	return release_tap_handle(candidate, "Click-hold key watcher")
end

--- Fences and stops one side’s drag tap.
--- @param side string Either "left" or "right".
--- @return boolean settled True only when its exact native handle was released.
local function stop_side_tap(side)
	local candidate = side_tap(side)
	fence_side_tap(side)
	if not candidate then return true end
	return release_tap_handle(candidate, side .. " click-hold drag tap")
end

--- Constructs a generation-fenced keyboard auto-release watcher.
--- @param generation integer Prospective watcher generation.
--- @return table|userdata|nil candidate Exact constructed watcher.
--- @return string|nil detail Constructor refusal detail.
local function construct_click_key_watcher(generation)
	local candidate = nil
	local ev_types = hs.eventtap.event.types
	local callback = function(e)
		if click_key_watcher ~= candidate
			or click_key_watcher_committed ~= true
			or click_key_watcher_generation ~= generation then
			return false
		end

		local provenance, status, fence = EventProvenance.classify_with_fence(
			e, "gestures.click_key")
		local ordered_events = {}
		for _, older in ipairs((fence and fence.events) or {}) do
			ordered_events[#ordered_events + 1] = older
		end
		if provenance or status == EventProvenance.STATUS_UNREADABLE then
			return false, (#ordered_events > 0 and ordered_events or nil)
		end

		-- Build the complete release batch before fencing a single live hold
		local release_left  = leftClickHeld
		local release_right = rightClickHeld
		local ok_pos, pos = pcall(hs.mouse.absolutePosition)
		local release_events = {}
		local construction_error = nil
		if not ok_pos or type(pos) ~= "table" then
			construction_error = tostring(pos or "mouse position unavailable")
		end
		local function build_release(event_type)
			if construction_error then return end
			local ok_event, mouse_up = pcall(hs.eventtap.event.newMouseEvent, event_type, pos)
			if not ok_event or mouse_up == nil or mouse_up == false then
				construction_error = tostring(mouse_up or "newMouseEvent returned nil")
				return
			end
			release_events[#release_events + 1] = mouse_up
		end
		if release_left then build_release(ev_types.leftMouseUp) end
		if release_right then build_release(ev_types.rightMouseUp) end
		if construction_error then
			SyntheticInput.defer_after_callback("click-hold release diagnostic", function()
				Logger.error(LOG, "Could not construct click-hold mouseUp: %s.",
					construction_error)
			end)
			return false, (#ordered_events > 0 and ordered_events or nil)
		end

		-- Returned events commit before the original key; stale native callbacks
		-- are fenced before any stop which may refuse or throw
		local cleanup_failures = {}
		if release_left then
			set_side_held("left", false)
			local settled, detail = stop_side_tap("left")
			if not settled then cleanup_failures[#cleanup_failures + 1] = tostring(detail) end
		end
		if release_right then
			set_side_held("right", false)
			local settled, detail = stop_side_tap("right")
			if not settled then cleanup_failures[#cleanup_failures + 1] = tostring(detail) end
		end
		local key_settled, key_detail = stop_click_key_watcher()
		if not key_settled then cleanup_failures[#cleanup_failures + 1] = tostring(key_detail) end

		for _, mouse_up in ipairs(release_events) do
			ordered_events[#ordered_events + 1] = mouse_up
		end
		SyntheticInput.defer_after_callback("click-hold release log", function()
			if release_left then Logger.info(LOG, "Synthetic Left-Click RELEASED by keydown.") end
			if release_right then Logger.info(LOG, "Synthetic Right-Click RELEASED by keydown.") end
			for _, detail in ipairs(cleanup_failures) do
				Logger.error(LOG, "Click-hold release cleanup remains pending: %s.", detail)
			end
		end)
		return false, (#ordered_events > 0 and ordered_events or nil)
	end

	local constructed, detail = construct_eventtap({ ev_types.keyDown, ev_types.flagsChanged }, callback)
	candidate = constructed
	return candidate, detail
end

--- Starts a preconstructed keyboard watcher without publishing it.
--- @param candidate table|userdata Exact candidate watcher.
--- @return boolean committed True only when native activation is exact.
--- @return string|nil detail Native refusal detail.
local function start_click_key_watcher(candidate)
	return start_native_tap(candidate)
end





-- ========================================
-- ========================================
-- ======= 3/ Drag Tap Construction =======
-- ========================================
-- ========================================

--- Constructs one generation-fenced drag/release tap without starting it.
--- @param side string Either "left" or "right".
--- @param generation integer Prospective side generation.
--- @param started_at number Hold-start timestamp for the finger-lift cooldown.
--- @return table|userdata|nil candidate Exact constructed drag tap.
--- @return string|nil detail Constructor refusal detail.
local function construct_side_tap(side, generation, started_at)
	local candidate = nil
	local ev_types = hs.eventtap.event.types
	local mouse_up_type = side == "left" and ev_types.leftMouseUp or ev_types.rightMouseUp
	local dragged_type = side == "left" and ev_types.leftMouseDragged or ev_types.rightMouseDragged
	local callback = function(e)
		if side_tap(side) ~= candidate
			or side_tap_is_committed(side) ~= true
			or side_generation(side) ~= generation
			or not side_is_held(side) then
			return false
		end

		local event_type = e:getType()
		if event_type == mouse_up_type then
			if hs.timer.secondsSinceEpoch() - started_at < CLICK_COOLDOWN_SEC then return true end
			-- The physical mouseUp is the only crash-proof release capability: fence
			-- internal ownership synchronously, then let that exact event reach Quartz
			set_side_held(side, false)
			local tap_settled, tap_detail = stop_side_tap(side)
			local key_settled, key_detail = true, nil
			if not leftClickHeld and not rightClickHeld then
				key_settled, key_detail = stop_click_key_watcher()
			end
			pcall(SyntheticInput.defer_after_callback,
				side .. " click-hold physical release log", function()
				Logger.info(LOG, "Synthetic %s-Click RELEASED by physical mouseUp.",
					side == "left" and "Left" or "Right")
				if not tap_settled then
					Logger.error(LOG, "%s click-hold drag tap cleanup remains pending: %s.",
						side, tostring(tap_detail))
				end
				if not key_settled then
					Logger.error(LOG, "Click-hold key watcher cleanup remains pending: %s.",
						tostring(key_detail))
				end
			end)
			return false
		end
		if event_type == ev_types.mouseMoved then
			pcall(function()
				hs.eventtap.event.newMouseEvent(dragged_type, e:location()):post()
			end)
			return false
		end
		return false
	end

	local constructed, detail = construct_eventtap({ ev_types.mouseMoved, mouse_up_type }, callback)
	candidate = constructed
	return candidate, detail
end





-- =========================================
-- =========================================
-- ======= 4/ Mouse Event Commitment =======
-- =========================================
-- =========================================

--- Builds one exact mouse event at the current pointer position.
--- @param event_type integer Native mouse event type.
--- @param use_hid_source boolean Whether to apply the HID source property.
--- @return table|userdata|nil event Constructed native event.
--- @return string|nil detail Construction or property refusal detail.
local function construct_mouse_event(event_type, use_hid_source)
	local position_ok, position_or_err = xpcall(hs.mouse.absolutePosition, debug.traceback)
	if not position_ok or type(position_or_err) ~= "table" then
		return nil, tostring(position_or_err or "mouse position unavailable")
	end
	local event_ok, event_or_err = xpcall(function()
		return hs.eventtap.event.newMouseEvent(event_type, position_or_err)
	end, debug.traceback)
	if not event_ok or event_or_err == nil or event_or_err == false then
		return nil, tostring(event_or_err)
	end

	if use_hid_source then
		local property_ok, property_result = xpcall(function()
			return event_or_err:setProperty(
				hs.eventtap.event.properties.eventSourceStateID, 1)
		end, debug.traceback)
		if not property_ok or property_result == nil or property_result == false then
			return nil, tostring(property_result)
		end
	end
	return event_or_err
end

--- Posts one preconstructed mouse event with exact result handling.
--- @param event table|userdata Native mouse event.
--- @return boolean committed True only when post returned a truthy event.
--- @return string|nil detail Native refusal detail.
local function post_mouse_event(event)
	local posted, result_or_err = xpcall(function() return event:post() end, debug.traceback)
	if not posted or result_or_err == nil or result_or_err == false then
		return false, tostring(result_or_err)
	end
	return true
end

--- Maps a side to its native button event types and display label.
--- @param side string Either "left" or "right".
--- @return integer mouse_down_type Native mouseDown type.
--- @return integer mouse_up_type Native mouseUp type.
--- @return string label Capitalized log label.
local function side_event_types(side)
	local ev_types = hs.eventtap.event.types
	if side == "left" then
		return ev_types.leftMouseDown, ev_types.leftMouseUp, "Left"
	end
	return ev_types.rightMouseDown, ev_types.rightMouseUp, "Right"
end





-- =========================================
-- =========================================
-- ======= 5/ Hold State Transitions =======
-- =========================================
-- =========================================

--- Rejects one hold acquisition and rolls back its exact candidate handles.
--- @param side string Either "left" or "right".
--- @param reason string Exact failed lifecycle boundary.
--- @param candidates table Exact candidates created by this attempt.
--- @return boolean Always false.
local function reject_hold_acquisition(side, reason, candidates)
	rollback_candidates(candidates)
	Logger.error(LOG, "Synthetic %s-click hold acquisition failed: %s.", side, tostring(reason))
	return false
end

--- Acquires both eventtaps before publishing mouseDown or held state.
--- @param side string Either "left" or "right".
--- @return boolean committed True only after every native effect committed.
local function acquire_hold(side)
	if retry_tap_cleanup() ~= true then
		Logger.error(LOG, "Synthetic %s-click hold refused while tap cleanup remains pending.", side)
		return false
	end

	-- A stale uncommitted owner must be retired before any successor exists
	if side_tap(side) and side_tap_is_committed(side) ~= true then
		tap_cleanup_debt[side_tap(side)] = side .. " click-hold drag tap"
		if retry_tap_cleanup() ~= true then return false end
	end
	if click_key_watcher and click_key_watcher_committed ~= true then
		tap_cleanup_debt[click_key_watcher] = "Click-hold key watcher"
		if retry_tap_cleanup() ~= true then return false end
	end

	local mouse_down_type, mouse_up_type, label = side_event_types(side)
	local down_event, down_error = construct_mouse_event(mouse_down_type, true)
	if not down_event then
		Logger.error(LOG, "Synthetic %s-Click mouseDown construction failed: %s.",
			label, tostring(down_error))
		return false
	end

	local candidates = {}
	local owns_new_key_watcher = click_key_watcher == nil
	local key_candidate = click_key_watcher
	local key_generation = click_key_watcher_generation
	if owns_new_key_watcher then
		key_generation = click_key_watcher_generation + 1
		local key_error
		key_candidate, key_error = construct_click_key_watcher(key_generation)
		if not key_candidate then
			return reject_hold_acquisition(side,
				"key watcher construction failed: " .. tostring(key_error), candidates)
		end
		candidates[#candidates + 1] = {
			handle = key_candidate,
			label = "Click-hold key watcher",
		}
	end

	local tap_generation = side_generation(side) + 1
	local started_at = hs.timer.secondsSinceEpoch()
	local drag_candidate, drag_error = construct_side_tap(side, tap_generation, started_at)
	if not drag_candidate then
		return reject_hold_acquisition(side,
			side .. " drag tap construction failed: " .. tostring(drag_error), candidates)
	end
	candidates[#candidates + 1] = {
		handle = drag_candidate,
		label = side .. " click-hold drag tap",
	}

	-- Both taps now exist; native activation is still callback-inert until publish
	if owns_new_key_watcher then
		local key_started, key_error = start_click_key_watcher(key_candidate)
		if not key_started then
			return reject_hold_acquisition(side,
				"key watcher start failed: " .. tostring(key_error), candidates)
		end
	end
	local drag_started, drag_start_error = start_native_tap(drag_candidate)
	if not drag_started then
		return reject_hold_acquisition(side,
			side .. " drag tap start failed: " .. tostring(drag_start_error), candidates)
	end

	-- Both required taps are proven active before either visible state is exposed
	if owns_new_key_watcher then
		click_key_watcher = key_candidate
		click_key_watcher_generation = key_generation
		click_key_watcher_committed = true
	end
	publish_side_tap(side, drag_candidate, tap_generation)

	local down_posted, post_error = post_mouse_event(down_event)
	if not down_posted then
		-- post() may throw after handing the event to Quartz; a compensating mouseUp
		-- makes that uncertainty safe before the taps are rolled back
		local emergency_up = construct_mouse_event(mouse_up_type, false)
		local emergency_released = emergency_up and post_mouse_event(emergency_up) == true
		if emergency_released then
			stop_side_tap(side)
			if owns_new_key_watcher then stop_click_key_watcher() end
		else
			-- The OS may own the down event, so retain explicit release ownership
			set_side_held(side, true)
		end
		Logger.error(LOG, "Synthetic %s-Click mouseDown post failed: %s.",
			label, tostring(post_error))
		return false
	end

	set_side_held(side, true)
	Logger.info(LOG, "Synthetic %s-Click HELD.", label)
	return true
end

--- Releases one held side while preserving retry ownership on mouseUp failure.
--- @param side string Either "left" or "right".
--- @param reason string Human-readable release attribution.
--- @return boolean settled True only after mouseUp and exact tap cleanup commit.
local function release_hold(side, reason)
	if not side_is_held(side) then return true end
	local _, mouse_up_type, label = side_event_types(side)
	local up_event, construction_error = construct_mouse_event(mouse_up_type, false)
	if not up_event then
		Logger.error(LOG, "Synthetic %s-Click release construction failed: %s.",
			label, tostring(construction_error))
		return false
	end

	-- The drag tap watches mouseUp itself; fence it before posting the release so
	-- a refused stop cannot swallow or re-toggle the exact cleanup event
	fence_side_tap(side)
	local posted, post_error = post_mouse_event(up_event)
	if not posted then
		Logger.error(LOG, "Synthetic %s-Click release post failed; held state retained: %s.",
			label, tostring(post_error))
		return false
	end

	set_side_held(side, false)
	local tap_settled = release_tap_handle(side_tap(side), side .. " click-hold drag tap")
	local key_settled = true
	if not leftClickHeld and not rightClickHeld then
		key_settled = stop_click_key_watcher()
	end
	Logger.info(LOG, "Synthetic %s-Click RELEASED%s.", label, reason)
	if not tap_settled or not key_settled then
		Logger.error(LOG, "Synthetic %s-Click released, but tap cleanup remains retryable.", label)
		return false
	end
	return true
end





-- ===================================
-- ===================================
-- ======= 6/ Public Click API =======
-- ===================================
-- ===================================

--- Forcefully releases every held synthetic click and retries all tap cleanup.
--- @return boolean settled True only when no button or native tap remains owned.
function M.force_cleanup()
	Logger.debug(LOG, "Forcefully releasing all held clicks…")
	local settled = retry_tap_cleanup()
	if leftClickHeld and release_hold("left", " forcefully") ~= true then settled = false end
	if rightClickHeld and release_hold("right", " forcefully") ~= true then settled = false end
	if not leftClickHeld and not rightClickHeld then
		if stop_click_key_watcher() ~= true then settled = false end
	end
	if retry_tap_cleanup() ~= true then settled = false end
	return settled and not leftClickHeld and not rightClickHeld
end

--- Toggles a held synthetic right-click.
--- @return boolean committed True only when the requested state transition commits.
function M.toggle_right_click()
	if rightClickHeld then return release_hold("right", "") end
	Logger.debug(LOG, "Enabling right-click hold mode…")
	return acquire_hold("right")
end

--- Toggles a held synthetic left-click.
--- @return boolean committed True only when the requested state transition commits.
function M.toggle_left_click()
	if leftClickHeld then return release_hold("left", "") end
	Logger.debug(LOG, "Enabling left-click hold mode…")
	return acquire_hold("left")
end

--- Releases every held click before a non-toggle tap action fires.
--- @param name string Tap action name used only for release attribution.
--- @return boolean settled True only when every required release commits.
function M.release_held_for_tap(name)
	local settled = true
	if leftClickHeld
		and release_hold("left", string.format(" by tap action '%s'", name)) ~= true then
		settled = false
	end
	if rightClickHeld
		and release_hold("right", string.format(" by tap action '%s'", name)) ~= true then
		settled = false
	end
	return settled
end

--- Returns whether a synthetic left-click is currently held.
--- @return boolean held Current exact left-button ownership state.
function M.is_left_click_held()
	return leftClickHeld
end

--- Returns whether a synthetic right-click is currently held.
--- @return boolean held Current exact right-button ownership state.
function M.is_right_click_held()
	return rightClickHeld
end

return M
