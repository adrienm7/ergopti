--- modules/shortcuts/refusal_retry.lua

--- ==============================================================================
--- MODULE: Refused Shortcut Retry Schedule
--- DESCRIPTION:
--- Owns the bounded retry series of the shortcuts whose own registration was
--- refused while their layer started. Each shortcut owner (static bindings,
--- configurable keyboard shortcuts) holds one series and arms it after a start
--- that left a shortcut unregistered.
---
--- FEATURES & RATIONALE:
--- 1. Independent Refusals: a refused hotkey fails alone; the series retries it
---    without touching the shortcuts that did register.
--- 2. Bounded: after the last delay, the next keyboard-layout change (which
---    rebinds every shortcut) is the only retry left, so a permanently held
---    chord cannot keep a timer alive.
--- 3. Generation-fenced: cancel() invalidates a timer already due, so a stop or
---    a rebind can never be followed by a stale retry.
--- ==============================================================================

local M = {}

local TimerScheduler = require("adapters.timer_scheduler")
local Logger         = require("infra.logger")

-- Seconds before each retry. The first ones cover a keyboard layout that
-- settles a moment after the rebind (a reboot, a probe layout of a field run);
-- the last one admits the US-ANSI position for a key the layout still lacks.
M.DELAYS_SEC = {1, 3, 10, 30}





-- =============================
-- =============================
-- ======= 1/ Public API =======
-- =============================
-- =============================

--- Creates one retry series.
--- @param log_tag string The owner's logger tag.
--- @param attempt function Called as attempt(final); returns true when no
---   refused shortcut remains.
--- @return table series Exposes schedule() and cancel().
function M.new(log_tag, attempt)
	assert(type(log_tag) == "string" and log_tag ~= "", "refusal retry needs a log tag")
	assert(type(attempt) == "function", "refusal retry needs an attempt function")
	local series = {}
	local generation = 0
	local handle = nil

	local function arm(index)
		local armed_generation = generation
		local ok, candidate, committed = pcall(TimerScheduler.after, M.DELAYS_SEC[index], function()
			if armed_generation ~= generation then return end
			handle = nil
			local final = index == #M.DELAYS_SEC
			local ok_attempt, settled = xpcall(attempt, debug.traceback, final)
			if not ok_attempt then
				Logger.error(log_tag, "Refused shortcut retry %d raised: %s.", index, tostring(settled))
				return
			end
			if armed_generation ~= generation then return end
			if settled == true then
				Logger.info(log_tag, "Refused shortcuts registered on retry %d.", index)
			elseif final then
				Logger.warn(log_tag,
					"Some shortcuts are still unregistered after %d retries; the next keyboard-layout change retries them.",
					#M.DELAYS_SEC)
			else
				arm(index + 1)
			end
		end)
		if not ok or committed ~= true then
			Logger.error(log_tag, "Refused shortcut retry %d could not be scheduled: %s.",
				index, tostring(candidate))
			return false
		end
		handle = candidate
		return true
	end

	--- Stops the series; a retry already due is fenced by its generation.
	--- @return boolean settled
	function series.cancel()
		generation = generation + 1
		local live = handle
		handle = nil
		if live == nil then return true end
		local ok, cancelled = pcall(TimerScheduler.cancel, live)
		if not ok or cancelled == false then
			Logger.error(log_tag, "Refused shortcut retry timer did not cancel: %s.", tostring(cancelled))
			return false
		end
		return true
	end

	--- Starts a fresh bounded series, replacing any running one.
	--- @return boolean armed
	function series.schedule()
		series.cancel()
		return arm(1)
	end

	return series
end

return M
