--- adapters/synthetic_input_loopback_owner.lua

--- ==============================================================================
--- MODULE: Loopback Native Release Owner
--- DESCRIPTION:
--- Retains one independently posted loopback pair through uncertain Down/Up
--- effects and exact periodic-timer retirement. It never retries a possible Down,
--- never bounds the required Up, and does not borrow the clipboard serializer.
--- ==============================================================================

local M = {}

--- Prepares an owner without starting a native timer or invoking a callback.
--- @param scheduler table Real TimerScheduler adapter.
--- @param events table Exact preconstructed Down and Up native events.
--- @param callbacks table admit, withdraw, discard, terminal and diagnostic operations.
--- @return table owner Lifecycle API for the exact pair.
function M.new(scheduler, events, callbacks)
	local owner = { down_attempted = false }
	local timer, arming, pumping, cancelled, retiring, finished = nil, false, false, false, false, false
	local failure, reported

	local function complete()
		if not retiring or timer ~= nil or arming or finished then return end
		finished = true
		callbacks.terminal(cancelled and "cancelled" or (failure and "failed" or "dispatched"), failure)
	end

	local function retire(detail)
		failure = failure or detail
		retiring = true
		if timer ~= nil then
			local ok, settled = pcall(scheduler.cancel, timer)
			if not ok or settled ~= true then
				pcall(callbacks.diagnostic, "Loopback native timer cleanup remains pending: %s.", tostring(settled))
			end
		end
		complete()
	end

	--- Cancellation is only a request until native Up and the timer are settled.
	--- @return boolean cancelled_now Always false while this owner is retained.
	function owner.cancel()
		if finished then return false end
		cancelled = true
		if not owner.down_attempted then
			callbacks.withdraw()
			callbacks.discard()
		end
		return false
	end

	local function pump()
		if arming or pumping or retiring or finished or owner.admission_uncertain then return end
		pumping = true
		local ok, detail = xpcall(function()
			if not owner.down_attempted then
				if cancelled or callbacks.admit() ~= true then
					callbacks.discard()
					if cancelled then retire() else retire("loopback publication is no longer current") end
					return
				end
				if cancelled then return end
				-- A reentrant consumer cannot mistake this pair for an untouched
				-- delayed echo once a native Down has become possible.
				owner.down_attempted = true
				callbacks.withdraw()
				local posted, post_error = pcall(events[1].post, events[1])
				if not posted then failure = tostring(post_error) end
			end
			local released, release_error = pcall(events[2].post, events[2])
			if not released then
				failure = failure or tostring(release_error)
				if not reported then
					reported = true
					pcall(callbacks.diagnostic, "Loopback native Up cleanup remains pending: %s.", tostring(release_error))
				end
				return
			end
			if failure then pcall(callbacks.diagnostic, "Loopback native pair failed: %s.", failure) end
			retire()
		end, debug.traceback)
		pumping = false
		if not ok then
			failure = failure or tostring(detail)
			if not owner.down_attempted then callbacks.discard(); retire() end
		end
	end

	--- Acquires the exact periodic wake before any native Down can be attempted.
	--- @param interval number Native retry interval in seconds.
	--- @return boolean accepted
	function owner.start(interval)
		arming = true
		local ok, accepted = xpcall(function()
			local handle, committed, detail = scheduler.every(interval, pump)
			timer = handle
			assert(scheduler.onSettled(handle, function()
				if timer ~= handle then return end
				timer = nil
				complete()
			end) == true, "loopback timer settlement observer refused")
			if committed ~= true or cancelled then
				callbacks.discard()
				retire(committed ~= true and tostring(detail or "loopback timer admission refused") or nil)
				return false
			end
			return true
		end, debug.traceback)
		arming = false
		if not ok then
			-- The real scheduler returns its exact handle on every native refusal.
			-- A broken diagnostic hook can instead raise before exposing it. Do not
			-- invent a stop acknowledgement for that unknown native capability.
			owner.admission_uncertain = true
			failure = failure or tostring(accepted)
			callbacks.withdraw()
			callbacks.discard()
			pcall(callbacks.diagnostic, "Loopback timer admission remains uncertain: %s.", failure)
			error(accepted, 0)
		end
		complete()
		return accepted
	end

	return owner
end

return M
