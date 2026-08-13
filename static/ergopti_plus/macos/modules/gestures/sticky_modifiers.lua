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

-- Currently armed modifiers, as a set { cmd = true, … }. Empty means disarmed.
local _armed = {}

-- Handle of the auto-cancel timer; nil while disarmed.
local _timer = nil
local _timer_committed = false
local _timer_generation = 0
local _timer_cleanup_debt = {}




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
local function cancel_timer_exact(handle, reason)
	if type(handle) ~= "table" then return true end
	local ok, result_or_err = xpcall(function()
		return TimerScheduler.cancel(handle)
	end, debug.traceback)
	if ok and result_or_err == true then
		_timer_cleanup_debt[handle] = nil
		return true
	end
	_timer_cleanup_debt[handle] = true
	Logger.error(LOG, "Sticky modifier timer cleanup remains pending during %s: %s.",
		tostring(reason), tostring(result_or_err))
	return false
end

--- Retries every exact timer left by an earlier cleanup refusal.
--- @return boolean settled True only when no cleanup debt remains.
local function retry_timer_cleanup()
	local snapshot = {}
	for handle in pairs(_timer_cleanup_debt) do snapshot[#snapshot + 1] = handle end
	local settled = true
	for _, handle in ipairs(snapshot) do
		if cancel_timer_exact(handle, "cleanup retry") ~= true then settled = false end
	end
	return settled
end

--- Fences and releases the currently published timer without changing modifiers.
--- @return boolean settled True only when the timer was released exactly.
local function retire_current_timer()
	_timer_generation = _timer_generation + 1
	_timer_committed = false
	local handle = _timer
	_timer = nil
	if not handle then return true end
	return cancel_timer_exact(handle, "timer replacement")
end

--- Drops the armed set, the injector and the auto-cancel timer.
--- Safe to call when nothing is armed.
--- @param reason string What released them, for the log line.
local function release(reason)
	local settled = retire_current_timer()
	if retry_timer_cleanup() ~= true then settled = false end
	Injector.disarm()
	if has_armed() then
		Logger.done(LOG, "Sticky modifiers released — %s (%s).", reason, armed_description())
	end
	_armed = {}
	return settled
end


-- =====================================
-- ===== 1.2) Public surface ===========
-- =====================================

--- Toggles a set of modifiers, Karabiner-style: each one flips independently.
---
--- @param modifiers table Array of modifier names ("cmd", "shift", …).
--- @param timeout_sec number Seconds of inactivity after which the arm is cancelled.
--- @return boolean True when the call was accepted.
function M.toggle(modifiers, timeout_sec)
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
	if retry_timer_cleanup() ~= true then
		Logger.error(LOG, "toggle(): prior auto-cancel timer cleanup is still pending — refusing a successor arm.")
		return false
	end
	if retire_current_timer() ~= true then
		Injector.disarm()
		_armed = {}
		Logger.error(LOG, "toggle(): current auto-cancel timer could not be retired — modifier arm revoked.")
		return false
	end

	for _, name in ipairs(modifiers) do
		_armed[name] = (not _armed[name]) or nil
	end

	if not has_armed() then
		Logger.debug(LOG, "Sticky modifiers toggled back off.")
		release("toggled off")
		return true
	end

	local arm_generation = _timer_generation + 1
	_timer_generation = arm_generation
	if not Injector.arm(_armed, function()
		if arm_generation ~= _timer_generation then return end
		Logger.debug(LOG, "Sticky modifiers consumed by the next keystroke.")
		release("consumed")
		end) then
		_armed = {}
		return false
	end

	local timer_candidate = nil
	local schedule_ok, handle_or_err, committed = xpcall(function()
		local timer_committed
		timer_candidate, timer_committed = TimerScheduler.after(timeout_sec, function()
			if _timer ~= timer_candidate or _timer_committed ~= true
				or arm_generation ~= _timer_generation then return end
			release("auto-cancelled after inactivity")
		end)
		return timer_candidate, timer_committed
	end, debug.traceback)
	timer_candidate = handle_or_err
	if type(timer_candidate) == "table" and timer_candidate.timer ~= nil then
		_timer = timer_candidate
	end
	if not schedule_ok or type(timer_candidate) ~= "table" or committed ~= true then
		_timer_generation = _timer_generation + 1
		_timer_committed = false
		if type(timer_candidate) == "table" then
			cancel_timer_exact(timer_candidate, "failed acquisition rollback")
		end
		_timer = nil
		Injector.disarm()
		_armed = {}
		Logger.error(LOG, "toggle(): auto-cancel timer did not commit — modifier arm revoked: %s.",
			tostring(handle_or_err))
		return false
	end
	_timer = timer_candidate
	_timer_committed = true

	Logger.trace(LOG, "Sticky modifiers armed (%s), auto-cancel in %.3fs.", armed_description(), timeout_sec)
	return true
end

--- Releases every armed modifier immediately.
function M.clear()
	release("cleared")
end

--- The armed set, copied so a caller cannot mutate the live state.
--- @return table Set of armed modifier names.
function M.armed()
	local copy = {}
	for name in pairs(_armed) do copy[name] = true end
	return copy
end

return M
