--- _shared/lua/owned_timer_slots.lua

--- ==============================================================================
--- MODULE: Owned Timer Slots
--- DESCRIPTION:
--- Named one-shot timers whose exact native handle stays owned from the
--- moment it is requested until the scheduler proves it settled: through a
--- refused start, a delivery during acquisition, a cancellation that joins an
--- in-flight acquisition, and a cancel the native layer refuses.
---
--- FEATURES & RATIONALE:
--- 1. One copy: the MLX and Ollama dependency checkers carried the same
---    128-line arm/cancel/settle state machine; a fix to one copy's
---    settlement path was missing from the other.
--- 2. Port, not adapter: the scheduler is passed in. It must offer
---    after(delay, fn) -> handle, committed; cancel(handle) -> settled;
---    onSettled(handle, fn) -> true. A handle is a table whose timer field is
---    non-nil while its native timer is unsettled (the TimerScheduler handle).
--- 3. Explicit ownership: new() is called once by the module that owns the
---    slots; slots is its table, read by that owner's admission checks.
--- 4. Refusals stay owned: a refused cancel keeps the exact handle as cleanup
---    debt, and a new arm in that slot is refused until it settles.
--- ==============================================================================

local M = {}

--- Creates one owner's timer slots.
--- @param options table { scheduler = TimerScheduler port, logger = logger with
---   error() and debug(), log = the owner's module tag }.
--- @return table timers { slots, arm, cancel, when_settled }
function M.new(options)
	assert(type(options) == "table" and getmetatable(options) == nil, "owned timers: options must be a plain table")
	for key in pairs(options) do
		assert(key == "scheduler" or key == "logger" or key == "log", "owned timers: unknown option " .. tostring(key))
	end
	local scheduler, logger, log = options.scheduler, options.logger, options.log
	-- The scheduler's and logger's methods are looked up at each call, as the
	-- owners did before: a scheduler call runs under xpcall, so a refusing or
	-- missing native method is a logged refusal that keeps the handle owned.
	assert(type(scheduler) == "table", "owned timers: scheduler must be the TimerScheduler port")
	assert(type(logger) == "table", "owned timers: logger must be the owner's logger")
	assert(type(log) == "string" and log ~= "", "owned timers: log must name the owner")

	local slots = {}
	local timers = { slots = slots }

	--- Arms and retains one exact backend-local timer.
	--- @param slot string Timer slot name.
	--- @param delay_sec number Delay in seconds.
	--- @param callback function Authorized user callback.
	--- @param label string Diagnostic label.
	--- @return boolean committed
	function timers.arm(slot, delay_sec, callback, label)
		local prior = slots[slot]
		if type(prior) == "table" and prior.settled ~= true then
			logger.error(log, "%s timer acquisition refused while its predecessor remains owned.", label)
			return false
		end
		local owner = {
			acquiring = true,
			cancel_requested = false,
			acquisition_valid = false,
			delivery_requested = false,
			delivery_seen = false,
			delivery_during_acquisition = false,
			native_settled = false,
			observer_attached = false,
			settled = false,
			handle = nil,
			settlement_callbacks = {},
		}
		-- Publish identity before crossing scheduler.after(): native start may
		-- synchronously re-enter ScriptControl PAUSE before the handle is returned.
		slots[slot] = owner
		local release_owner
		local deliver_owner
		local observe_owner
		release_owner = function()
			if owner.settled == true then return false end
			owner.settled = true
			if slots[slot] == owner then slots[slot] = nil end
			local callbacks = owner.settlement_callbacks
			owner.settlement_callbacks = {}
			for _, settled_callback in ipairs(callbacks) do
				local callback_ok, callback_error = xpcall(settled_callback, debug.traceback)
				if callback_ok ~= true then
					logger.error(log, "%s timer settlement callback failed: %s.",
						label, tostring(callback_error))
				end
			end
			return true
		end
		observe_owner = function()
			if owner.settled == true or owner.observer_attached == true then return true end
			local handle = owner.handle
			if type(handle) ~= "table" or handle.timer == nil then
				owner.native_settled = true
				if owner.delivery_requested == true then
					return deliver_owner()
				end
				if owner.cancel_requested == true or owner.acquisition_valid ~= true then
					release_owner()
				end
				return true
			end
			-- Publish observer ownership before registration because onSettled may
			-- synchronously call back for an already-settled native handle.
			owner.observer_attached = true
			local observed_ok, observed = xpcall(function()
				return scheduler.onSettled(handle, function()
					owner.observer_attached = false
					owner.native_settled = true
					if owner.delivery_requested == true then
						deliver_owner()
					elseif owner.cancel_requested == true or owner.acquisition_valid ~= true then
						release_owner()
					end
				end)
			end, debug.traceback)
			if not observed_ok or observed ~= true then
				owner.observer_attached = false
				logger.error(log, "%s timer settlement observer refused: %s.",
					label, tostring(observed_ok and observed or observed))
				return false
			end
			return true
		end
		deliver_owner = function()
			if owner.delivery_seen == true or owner.settled == true then return false end
			owner.delivery_requested = true
			if owner.acquiring == true then
				owner.delivery_during_acquisition = true
				return false
			end
			local handle = owner.handle
			if type(handle) == "table" and handle.timer ~= nil then
				observe_owner()
				return false
			end
			owner.native_settled = true
			local authorized = owner.acquisition_valid == true
				and owner.cancel_requested ~= true
				and slots[slot] == owner
			owner.delivery_seen = true
			release_owner()
			if not authorized then return false end
			callback()
			return true
		end
		local candidate
		local ok, handle_or_error, committed = xpcall(function()
			return scheduler.after(delay_sec, function()
				deliver_owner()
			end)
		end, debug.traceback)
		if ok and type(handle_or_error) == "table" then candidate = handle_or_error end
		owner.handle = candidate
		owner.acquiring = false
		if ok and committed == true and type(candidate) == "table"
			and candidate.timer ~= nil and owner.delivery_during_acquisition ~= true
			and owner.cancel_requested ~= true
			and slots[slot] == owner then
			owner.acquisition_valid = true
			observe_owner()
			return true
		end
		owner.acquisition_valid = false
		owner.cancel_requested = true
		if type(candidate) == "table" and candidate.timer ~= nil then
			local cancel_ok, settled = xpcall(function()
				return scheduler.cancel(candidate)
			end, debug.traceback)
			if cancel_ok and settled == true then
				owner.native_settled = true
				release_owner()
			else
				observe_owner()
			end
		else
			owner.native_settled = true
			release_owner()
		end
		logger.error(log, "%s timer acquisition refused: %s.",
			label, tostring(ok and committed or handle_or_error))
		return false
	end

	--- Cancels one exact timer without dropping refused native cleanup debt.
	--- @param slot string Timer slot name.
	--- @param label string Diagnostic label.
	--- @return boolean settled
	function timers.cancel(slot, label)
		local owner = slots[slot]
		if type(owner) == "table" and owner.acquiring == true then
			owner.cancel_requested = true
			owner.acquisition_valid = false
			logger.debug(log, "%s timer cancellation joined an in-flight acquisition.", label)
			return false
		end
		if type(owner) ~= "table" or owner.settled == true then
			slots[slot] = nil
			return true
		end
		owner.cancel_requested = true
		owner.acquisition_valid = false
		local handle = owner.handle
		if type(handle) ~= "table" or handle.timer == nil then
			owner.native_settled = true
			owner.settled = true
			if slots[slot] == owner then slots[slot] = nil end
			return true
		end
		local ok, settled_or_error = xpcall(function()
			return scheduler.cancel(handle)
		end, debug.traceback)
		if ok and settled_or_error == true then
			owner.native_settled = true
			owner.settled = true
			if slots[slot] == owner then slots[slot] = nil end
			return true
		end
		logger.error(log, "%s timer cancellation refused; exact handle retained: %s.",
			label, tostring(settled_or_error))
		return false
	end

	--- Registers one continuation behind an exact timer settlement.
	--- @param slot string Timer slot name.
	--- @param callback function Continuation invoked after native settlement.
	--- @return boolean registered
	function timers.when_settled(slot, callback)
		local owner = slots[slot]
		if type(callback) ~= "function" then return false end
		if type(owner) ~= "table" or owner.settled == true then
			callback()
			return true
		end
		owner.settlement_callbacks[#owner.settlement_callbacks + 1] = callback
		return true
	end

	return timers
end

return M
