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
function M.disarm()
	if _tap then
		pcall(function() _tap:stop() end)
		_tap = nil
	end
	_flags      = {}
	_on_applied = nil
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

	_flags      = copy
	_on_applied = type(on_applied) == "function" and on_applied or nil

	if _tap then return true end

	local ok, tap_or_err = pcall(hs.eventtap.new, { hs.eventtap.event.types.keyDown }, function(event)
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
		_flags      = {}
		_on_applied = nil
		return false
	end

	_tap = tap_or_err
	local ok_start, err = pcall(function() _tap:start() end)
	if not ok_start then
		Logger.error(LOG, "arm(): eventtap:start() failed — %s", tostring(err))
		M.disarm()
		return false
	end
	return true
end

--- True while a set of flags is waiting for the next key event.
--- @return boolean
function M.is_armed()
	return _tap ~= nil
end

return M
