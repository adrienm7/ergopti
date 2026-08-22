--- modules/gestures/sticky_modifiers.lua

--- ==============================================================================
--- MODULE: Sticky (one-shot) Modifiers
--- DESCRIPTION:
--- Arms one or more modifiers for the NEXT keystroke, then releases them. This is
--- the gesture-side implementation of Karabiner's `sticky_modifier`, which a
--- gesture cannot reach any other way.
---
--- FEATURES & RATIONALE:
--- 1. Why not Karabiner. `sticky_modifier` is a manipulator construct: it only
---    exists as the `to` of a key Karabiner is already grabbing. `karabiner_cli`
---    can set VARIABLES, not fire a manipulator, so there is no IPC that makes a
---    swipe produce a sticky Shift. The behaviour is therefore reimplemented
---    here rather than delegated, and it is the one action family in the
---    Karabiner catalogue that macOS has to own itself.
--- 2. Karabiner's toggle semantics, exactly. Each modifier in the set toggles
---    INDEPENDENTLY, because `sticky_cmd_shift` is two `sticky_modifier` entries
---    in the catalogue, not one compound. Arming cmd+shift while cmd is already
---    armed therefore leaves shift armed and cmd released — mirroring what the
---    same action does when the remap layer performs it.
--- 3. Policy only. Every OS call lives in adapters/modifier_injector.lua and
---    adapters/timer_scheduler.lua; this file decides WHICH modifiers and for
---    HOW LONG, and can be tested without Hammerspoon at all.
--- 4. Auto-cancel is the user's value, never a default invented here. The delay
---    is the same `sticky_timeout_ms` the remap menu writes, passed in by the
---    caller; a call with no usable delay is refused rather than run on a guess.
--- ==============================================================================

local M = {}

local Logger         = require("infra.logger")
local Injector       = require("adapters.modifier_injector")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "gestures.sticky"

-- The modifier names a key event's flag table carries. A closed set: a typo
-- like "command" would arm a flag no key event ever holds, and the gesture
-- would then look like it simply did nothing.
local VALID_MODIFIERS = { cmd = true, ctrl = true, alt = true, shift = true, fn = true }
local DEFAULT_ACTION_PARENT = "gestures"

-- Currently armed modifiers, as a set { cmd = true, … }. Empty means disarmed.
local _armed = {}
local _armed_parent = nil

-- Handle of the auto-cancel timer; nil while disarmed.
local _timer = nil
local _timer_committed = false
local _timer_generation = 0
local _timer_cleanup_debt = {}
local _sticky_lifecycle_epoch = 0
local _sticky_acquisition = nil




-- ===============================================
-- ===============================================
-- ======= 1/ Arming and Releasing ===============
-- ===============================================
-- ===============================================


-- ==========================================
-- ===== 1.1) Internal state transitions ====
-- ==========================================

--- True when at least one modifier is armed.
--- @return boolean
local function has_armed()
	return next(_armed) ~= nil
end

--- Renders the armed set as a stable, sorted string for the logs.
--- @return string
local function armed_description()
	local names = {}
	for name in pairs(_armed) do names[#names + 1] = name end
	table.sort(names)
	return #names > 0 and table.concat(names, "+") or "none"
end

--- Cancels one exact timer and retains it when native cleanup refuses.
--- @param handle table|nil TimerScheduler handle.
--- @param reason string Cleanup context for diagnostics.
--- @return boolean settled True only when no native timer remains owned.
local function cancel_timer_exact(handle, reason, parent)
	if type(handle) ~= "table" then return true end
	local ok, result_or_err = xpcall(function()
		return TimerScheduler.cancel(handle)
	end, debug.traceback)
	if ok and result_or_err == true then
		_timer_cleanup_debt[handle] = nil
		return true
	end
	_timer_cleanup_debt[handle] = parent or _armed_parent or DEFAULT_ACTION_PARENT
	Logger.error(LOG, "Sticky modifier timer cleanup remains pending during %s: %s.",
		tostring(reason), tostring(result_or_err))
	return false
end

--- Retries every exact timer left by an earlier cleanup refusal.
--- @return boolean settled True only when no cleanup debt remains.
local function retry_timer_cleanup(parent)
	local scope_id = type(parent) == "string" and parent ~= ""
		and parent or DEFAULT_ACTION_PARENT
	local snapshot = {}
	for handle, debt_parent in pairs(_timer_cleanup_debt) do
		if debt_parent == scope_id then snapshot[#snapshot + 1] = handle end
	end
	local settled = true
	for _, handle in ipairs(snapshot) do
		if cancel_timer_exact(handle, "cleanup retry", scope_id) ~= true then settled = false end
	end
	return settled
end

--- Fences and releases the currently published timer without changing modifiers.
--- @return boolean settled True only when the timer was released exactly.
local function retire_current_timer(parent)
	_timer_generation = _timer_generation + 1
	_timer_committed = false
	local handle = _timer
	_timer = nil
	if not handle then return true end
	return cancel_timer_exact(handle, "timer replacement", parent)
end

--- Revokes the exact native modifier injector without losing cleanup debt.
--- @param reason string Diagnostic boundary.
--- @return boolean settled
local function disarm_injector_exact(reason)
	local disarm_ok, disarm_result = xpcall(Injector.disarm, debug.traceback)
	if disarm_ok and disarm_result == true then return true end
	Logger.error(LOG,
		"Sticky modifier injector cleanup remains pending during %s: %s.",
		tostring(reason), tostring(disarm_result))
	return false
end

--- Settles the native injector before forgetting its exact logical owner.
--- A refused disarm is cleanup debt: retaining both the armed identity and its
--- parent prevents a sibling feature from consuming or replacing that debt.
--- @param reason string Diagnostic boundary.
--- @return boolean settled
local function settle_armed_injector(reason)
	if disarm_injector_exact(reason) ~= true then return false end
	if has_armed() then
		Logger.done(LOG, "Sticky modifiers released — %s (%s).", reason, armed_description())
	end
	_armed = {}
	_armed_parent = nil
	return true
end

--- Drops the armed set, the injector and the auto-cancel timer.
--- Safe to call when nothing is armed.
--- @param reason string What released them, for the log line.
local function release(reason, parent)
	local scope_id = type(parent) == "string" and parent ~= ""
		and parent or _armed_parent or DEFAULT_ACTION_PARENT
	if _armed_parent ~= nil and _armed_parent ~= scope_id then return true end
	local settled = retire_current_timer(scope_id)
	if retry_timer_cleanup(scope_id) ~= true then settled = false end
	if settle_armed_injector(reason) ~= true then settled = false end
	return settled == true
end

local function sticky_acquisition_is_current(attempt)
	return _sticky_acquisition == attempt
		and _sticky_lifecycle_epoch == attempt.epoch
end

local function finish_sticky_acquisition(attempt)
	if _sticky_acquisition == attempt then _sticky_acquisition = nil end
end

local function rollback_sticky_acquisition(attempt, timer_candidate, reason)
	if _sticky_acquisition == attempt then
		_sticky_acquisition = nil
		_sticky_lifecycle_epoch = _sticky_lifecycle_epoch + 1
	end
	if type(timer_candidate) == "table" then
		cancel_timer_exact(timer_candidate, reason .. " timer rollback", attempt.parent)
		if _timer == timer_candidate then _timer = nil end
	end
	-- A re-entrant clear may have removed the logical identity while the native
	-- arm call subsequently returned success. Restore that exact identity solely
	-- for its original parent so disarm debt remains retryable and sibling-safe.
	if _armed_parent == nil and type(attempt.armed) == "table" then
		_armed = attempt.armed
		_armed_parent = attempt.parent
	end
	if _armed_parent == attempt.parent then release(reason, attempt.parent) end
	return false
end


-- =====================================
-- ===== 1.2) Public surface ===========
-- =====================================

--- Toggles a set of modifiers, Karabiner-style: each one flips independently.
---
--- @param modifiers table Array of modifier names ("cmd", "shift", …).
--- @param timeout_sec number Seconds of inactivity after which the arm is cancelled.
--- @return boolean True when the call was accepted.
function M.toggle(modifiers, timeout_sec, parent)
	local scope_id = type(parent) == "string" and parent ~= ""
		and parent or DEFAULT_ACTION_PARENT
	if type(modifiers) ~= "table" or #modifiers == 0 then
		Logger.error(LOG, "toggle(): expected a non-empty array of modifier names — gesture is a no-op.")
		return false
	end
	for _, name in ipairs(modifiers) do
		if not VALID_MODIFIERS[name] then
			Logger.error(LOG, "toggle(): '%s' is not a modifier a key event carries — gesture is a no-op.",
				tostring(name))
			return false
		end
	end
	-- No fallback delay on purpose: the value is the one the user set in the
	-- remap menu, and inventing 3 s here would silently override that choice on
	-- exactly the boot where the configuration failed to load.
	if type(timeout_sec) ~= "number" or timeout_sec <= 0 then
		Logger.error(LOG, "toggle(): no usable auto-cancel delay (%s) — refusing to arm.", tostring(timeout_sec))
		return false
	end
	if _armed_parent ~= nil and _armed_parent ~= scope_id then
		Logger.debug(LOG,
			"toggle(): refused while sibling parent '%s' owns the sticky arm.",
			tostring(_armed_parent))
		return false
	end
	if retry_timer_cleanup(scope_id) ~= true then
		Logger.error(LOG, "toggle(): prior auto-cancel timer cleanup is still pending — refusing a successor arm.")
		return false
	end
	if _sticky_acquisition ~= nil then
		Logger.error(LOG, "toggle(): another sticky acquisition is still in flight.")
		return false
	end
	_sticky_lifecycle_epoch = _sticky_lifecycle_epoch + 1
	local attempt = { parent = scope_id, epoch = _sticky_lifecycle_epoch }
	_sticky_acquisition = attempt
	if retire_current_timer(_armed_parent or scope_id) ~= true then
		finish_sticky_acquisition(attempt)
		settle_armed_injector("timer replacement rollback")
		Logger.error(LOG, "toggle(): current auto-cancel timer could not be retired — modifier arm revoked.")
		return false
	end

	for _, name in ipairs(modifiers) do
		_armed[name] = (not _armed[name]) or nil
	end
	_armed_parent = scope_id
	attempt.armed = {}
	for name in pairs(_armed) do attempt.armed[name] = true end

	if not has_armed() then
		Logger.debug(LOG, "Sticky modifiers toggled back off.")
		finish_sticky_acquisition(attempt)
		return release("toggled off", scope_id) == true
	end

	local arm_generation = _timer_generation + 1
	_timer_generation = arm_generation
	local arm_ok, arm_result = xpcall(function()
		return Injector.arm(_armed, function()
			if arm_generation ~= _timer_generation then return end
			Logger.debug(LOG, "Sticky modifiers consumed by the next keystroke.")
			release("consumed", scope_id)
		end)
	end, debug.traceback)
	if not arm_ok or arm_result ~= true
		or not sticky_acquisition_is_current(attempt) then
		return rollback_sticky_acquisition(
			attempt, nil, "injector arm rollback")
	end

	local timer_candidate = nil
	local schedule_ok, handle_or_err, committed = xpcall(function()
		local timer_committed
		timer_candidate, timer_committed = TimerScheduler.after(timeout_sec, function()
			if _timer ~= timer_candidate or _timer_committed ~= true
				or arm_generation ~= _timer_generation then return end
				release("auto-cancelled after inactivity", scope_id)
		end)
		return timer_candidate, timer_committed
	end, debug.traceback)
	timer_candidate = handle_or_err
	if type(timer_candidate) == "table" and timer_candidate.timer ~= nil
		and sticky_acquisition_is_current(attempt) then
		_timer = timer_candidate
	end
	if not schedule_ok or type(timer_candidate) ~= "table" or committed ~= true
		or not sticky_acquisition_is_current(attempt) then
		_timer_generation = _timer_generation + 1
		_timer_committed = false
		Logger.error(LOG, "toggle(): auto-cancel timer did not commit — modifier arm revoked: %s.",
			tostring(handle_or_err))
		return rollback_sticky_acquisition(
			attempt, timer_candidate, "timer acquisition rollback")
	end
	_timer = timer_candidate
	_timer_committed = true
	finish_sticky_acquisition(attempt)

	Logger.trace(LOG, "Sticky modifiers armed (%s), auto-cancel in %.3fs.", armed_description(), timeout_sec)
	return true
end

--- Releases every armed modifier immediately.
function M.clear(parent)
	local scope_id = type(parent) == "string" and parent ~= ""
		and parent or DEFAULT_ACTION_PARENT
	local acquisition_in_flight = false
	if _sticky_acquisition and _sticky_acquisition.parent == scope_id then
		acquisition_in_flight = true
		_sticky_lifecycle_epoch = _sticky_lifecycle_epoch + 1
		-- Keep the exact on-stack marker published until Injector.arm() or
		-- TimerScheduler.after() returns. The outer acquisition observes the epoch
		-- change and owns final rollback; cleanup cannot certify settlement while
		-- that native boundary may still publish a capability.
	end
	if _armed_parent ~= nil and _armed_parent ~= scope_id then
		return retry_timer_cleanup(scope_id)
	end
	local settled = release("cleared", scope_id) == true
	if acquisition_in_flight then return false end
	return settled
end

--- The armed set, copied so a caller cannot mutate the live state.
--- @return table Set of armed modifier names.
function M.armed()
	local copy = {}
	for name in pairs(_armed) do copy[name] = true end
	return copy
end

return M
