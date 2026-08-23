--- adapters/modifier_injector.lua

--- ==============================================================================
--- MODULE: ModifierInjector Adapter (Hammerspoon)
--- DESCRIPTION:
--- Adds a set of modifier flags to the NEXT key event the user produces, then
--- removes itself. This is the OS half of a one-shot ("sticky") modifier; the
--- policy half — which modifiers, for how long, and what toggling one twice
--- means — lives in modules/gestures/sticky_modifiers.lua and never touches
--- Hammerspoon.
---
--- FEATURES & RATIONALE:
--- 1. The tap exists only while armed. A permanent keyDown tap for a feature
---    almost nobody has bound would put this adapter on the critical path of
---    every keystroke on the machine. It is created on arm and destroyed the
---    moment it fires or is cancelled, so the cost is paid only by the user who
---    asked for it.
--- 2. The event is MUTATED, never replaced. Deleting the key and posting a copy
---    loses the event source, and applications that read it — terminal
---    emulators, games, anything using IOHID — treat a synthesised copy
---    differently from the key the user actually pressed. Returning false with
---    the flags already set is what lets the real event continue.
--- ==============================================================================

local M = {}

local hs            = hs
local Logger        = require("infra.logger")
local EventProvenance = require("adapters.event_provenance")
local SyntheticInput = require("adapters.synthetic_input")

local LOG = "adapters.modifier_injector"

-- The live tap while armed; nil otherwise.
local _tap = nil

-- Logical delivery authority is revoked before native cleanup.  A refused
-- eventtap stop therefore leaves one retryable capability, never a callback
-- that can still mutate a key while the gesture runtime is suspended.
local _delivering = false

-- Flags to add to the next key event, as a set { cmd = true, … }.
local _flags = {}

-- Invoked after the flags land, so the policy layer can drop its own state
-- without polling this adapter.
local _on_applied = nil




-- =========================================
-- =========================================
-- ======= 1/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Stops and forgets the tap. Safe to call when not armed.
--- The exact handle is retained when native cleanup refuses or cannot be
--- observed, so a later pause/clear can retry the same capability.
--- @return boolean settled True only after the tap is observably disabled.
function M.disarm()
	local tap = _tap
	_delivering = false
	_flags      = {}
	_on_applied = nil
	if not tap then return true end

	local method_ok, stop_method = pcall(function() return tap.stop end)
	if not method_ok or type(stop_method) ~= "function" then
		Logger.error(LOG, "disarm(): eventtap stop is unavailable; exact handle retained.")
		return false
	end
	local stopped, stop_result = xpcall(function()
		return stop_method(tap)
	end, debug.traceback)
	local probe_ok, enabled = xpcall(function()
		if type(tap.isEnabled) ~= "function" then
			error("eventtap isEnabled is unavailable")
		end
		return tap:isEnabled()
	end, debug.traceback)
	if not stopped or stop_result == nil or stop_result == false
		or not probe_ok or enabled ~= false then
		Logger.error(LOG,
			"disarm(): eventtap stop did not settle; exact handle retained — %s.",
			tostring(not stopped and stop_result
				or (stop_result == nil and "returned nil")
				or (stop_result == false and "returned false")
				or (not probe_ok and enabled)
				or "tap remained enabled"))
		return false
	end
	if _tap == tap then _tap = nil end
	return true
end

--- Arms a set of modifier flags for the next key event.
--- Re-arming while already armed replaces the flags and keeps the same tap,
--- which is what makes a second gesture before the first has fired cheap.
---
--- @param flags table Set of modifier names, e.g. { cmd = true, shift = true }.
--- @param on_applied function|nil Called with no arguments once the flags land.
--- @return boolean True when the tap is running and the flags are armed.
function M.arm(flags, on_applied)
	if type(flags) ~= "table" or next(flags) == nil then
		Logger.error(LOG, "arm(): expected a non-empty set of modifier flags — nothing armed.")
		return false
	end

	local copy = {}
	for name, on in pairs(flags) do
		if on then copy[name] = true end
	end
	if next(copy) == nil then
		Logger.error(LOG, "arm(): every flag in the set was false — nothing armed.")
		return false
	end

	-- A prior refused disarm is logically fenced but still owns its exact tap.
	-- Never acquire a successor until that same handle settles.
	if _tap and _delivering ~= true and M.disarm() ~= true then
		Logger.error(LOG, "arm(): prior eventtap cleanup is still pending — refusing a successor arm.")
		return false
	end

	_flags      = copy
	_on_applied = type(on_applied) == "function" and on_applied or nil

	if _tap then
		local probe_ok, enabled = xpcall(function()
			if type(_tap.isEnabled) ~= "function" then error("eventtap isEnabled is unavailable") end
			return _tap:isEnabled()
		end, debug.traceback)
		if probe_ok and enabled == true then
			_delivering = true
			return true
		end
		_delivering = false
		if M.disarm() ~= true then
			Logger.error(LOG, "arm(): existing eventtap is not enabled and could not be released.")
			return false
		end
		_flags      = copy
		_on_applied = type(on_applied) == "function" and on_applied or nil
	end

	local tap_candidate = nil
	local ok, tap_or_err = pcall(hs.eventtap.new, { hs.eventtap.event.types.keyDown }, function(event)
		if _delivering ~= true or _tap ~= tap_candidate then return false end
		local provenance, status, fence = EventProvenance.classify_with_fence(
			event, "modifier_injector")
		local fence_events = fence and fence.events or nil
		if fence and fence.consume_original == true then return true, fence_events end
		-- A delayed Ergopti batch is not the user's "next key". Mutating it would
		-- corrupt that output, disarm the sticky modifier, and leave the subsequent
		-- physical key unmodified. Unreadable provenance is equally non-authoritative.
		if provenance or status == EventProvenance.STATUS_UNREADABLE then
			return false, fence_events
		end
		local applied = _on_applied
		local committed = false
		if applied then
			-- Reserve the policy handoff before mutating the physical event. If the
			-- post-callback dispatcher is unavailable, the sticky modifier must stay
			-- armed and the untouched key must pass through for a later retry.
			local scheduled = SyntheticInput.defer_after_callback(
				"modifier injector on_applied", function()
					if committed then applied() end
				end)
			if not scheduled then return false, fence_events end
		end
		local ok_apply, err = pcall(function()
			local event_flags = event:getFlags()
			for name in pairs(_flags) do event_flags[name] = true end
			event:setFlags(event_flags)
		end)
		if not ok_apply then
			SyntheticInput.defer_after_callback("modifier injector setFlags diagnostic",
				function()
					Logger.error(LOG, "Could not set flags on the next key event: %s",
						tostring(err))
				end)
			return false, fence_events
		end
		M.disarm()
		-- The already-queued callback observes true only after the event mutation
		-- and adapter state transition both completed. A setFlags failure therefore
		-- leaves that callback inert while keeping the arm recoverable.
		committed = true
		return false, fence_events
	end)

	if not ok then
		Logger.error(LOG, "arm(): hs.eventtap.new failed — %s", tostring(tap_or_err))
		_delivering = false
		_flags      = {}
		_on_applied = nil
		return false
	end
	if tap_or_err == nil or tap_or_err == false then
		Logger.error(LOG, "arm(): hs.eventtap.new returned no handle.")
		_delivering = false
		_flags      = {}
		_on_applied = nil
		return false
	end

	tap_candidate = tap_or_err
	_tap = tap_candidate
	_delivering = true
	local ok_start, start_result = xpcall(function() return tap_candidate:start() end,
		debug.traceback)
	local probe_ok, enabled = xpcall(function()
		if type(tap_candidate.isEnabled) ~= "function" then
			error("eventtap isEnabled is unavailable")
		end
		return tap_candidate:isEnabled()
	end, debug.traceback)
	if not ok_start or start_result == nil or start_result == false
		or not probe_ok or enabled ~= true then
		Logger.error(LOG, "arm(): eventtap:start() did not commit — %s",
			tostring(not ok_start and start_result
				or (start_result == nil and "returned nil")
				or (start_result == false and "returned false")
				or (not probe_ok and enabled)
				or "tap remained disabled"))
		M.disarm()
		return false
	end
	return true
end

--- True while a set of flags is waiting for the next key event.
--- @return boolean
function M.is_armed()
	return _tap ~= nil and _delivering == true
end

return M
