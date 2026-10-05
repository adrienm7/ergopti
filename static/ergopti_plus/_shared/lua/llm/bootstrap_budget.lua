--- _shared/lua/llm/bootstrap_budget.lua

--- ==============================================================================
--- MODULE: Shared Dependency Bootstrap Budget
--- DESCRIPTION:
--- Owns one bounded bootstrap deadline and its independent native timer
--- retirement.
--- ==============================================================================

local M = {}
local MAX_INTEGER = 9007199254740991

local function integer(value)
	return type(value) == "number" and value >= 0 and value <= MAX_INTEGER and value % 1 == 0
end

--- Creates one master deadline, preserving timer acquisition/physical-close debt.
--- @param duration_ms integer Positive shared dependency bootstrap timing.
--- @param ports table { now_ms, after } with a physically owned timer operation.
--- @return table owner cancel/retire/finish/is_settled/on_settled.
--- @return table capability Opaque bound current/remaining_ms/reason/on_cancel.
function M.new(duration_ms, ports)
	assert(integer(duration_ms) and duration_ms > 0 and type(ports) == "table"
		and type(ports.now_ms) == "function" and type(ports.after) == "function", "bootstrap budget ports are invalid")
	local now_ms, after = ports.now_ms, ports.after
	local started_ok, started = pcall(now_ms)
	assert(started_ok and integer(started) and duration_ms <= MAX_INTEGER - started, "bootstrap clock is invalid")
	local deadline, last = started + duration_ms, started
	local timer, acquiring, retiring, complete, cancelled, reason = nil, true, false, false, false, nil
	local cancel_listeners, settled_listeners, pumping = {}, {}, false
	local owner, api = {}, {}
	local retire
	local function notify(callback, ...)
		local ok = pcall(callback, ...)
		if not ok then owner.observer_error = "bootstrap_observer_refused" end
	end
	local function revoke(cause)
		if cancelled or complete then return end
		cancelled, reason = true, cause
		local pending = cancel_listeners; cancel_listeners = {}
		for _, callback in ipairs(pending) do notify(callback, cause) end
		retiring = true
		if retire then retire() end
	end
	local function remaining()
		if cancelled or complete then return nil end
		local ok, now = pcall(now_ms)
		if not ok or not integer(now) or now < last then revoke("bootstrap_clock_invalid"); return nil end
		last = now
		if now >= deadline then revoke("bootstrap_timeout"); return 0 end
		return deadline - now
	end
	function api.remaining_ms() return remaining() end
	function api.current()
		local value = remaining()
		return value ~= nil and value > 0 and not cancelled and not complete
	end
	function api.reason() return reason end
	function api.on_cancel(callback)
		if type(callback) ~= "function" then return false end
		if cancelled then notify(callback, reason)
		elseif not complete then cancel_listeners[#cancel_listeners + 1] = callback end
		return true
	end
	local capability = setmetatable({}, { __index = api,
		__newindex = function() error("bootstrap capability is immutable", 2) end, __metatable = false })
	local function settled()
		if acquiring or not retiring then return false end
		if timer == nil then return owner.acquisition_error == nil end
		local ok, result = pcall(timer.is_settled, timer)
		return ok and result == true
	end
	retire = function()
		if pumping or acquiring or not retiring then return false end
		pumping = true
		if timer then
			local ok, result = pcall(timer.cancel, timer)
			if not ok or result ~= true then owner.cleanup_error = "bootstrap_timer_cleanup_pending" end
		end
		local done = settled()
		local pending
		if done then
			owner.cleanup_error = nil
			pending = settled_listeners; settled_listeners = {}
		end
		pumping = false
		-- Observers may now acknowledge retirement/reenter without borrowing an
		-- in-progress native cancel call as the physical-close receipt.
		if pending then for _, callback in ipairs(pending) do notify(callback) end end
		return done
	end
	function owner:cancel(cause)
		revoke(type(cause) == "string" and cause or "bootstrap_cancelled")
		return retire()
	end
	function owner:retire()
		retiring = true
		return retire()
	end
	function owner:is_settled() return settled() end
	function owner:on_settled(callback)
		if type(callback) ~= "function" then return false end
		if settled() then notify(callback) else settled_listeners[#settled_listeners + 1] = callback end
		return true
	end
	function owner:finish()
		if not settled() then return false end
		complete = true
		cancel_listeners = {}
		return true
	end
	local called, acquired = pcall(after, duration_ms, function() revoke("bootstrap_timeout") end)
	if called and type(acquired) == "table" and type(acquired.cancel) == "function"
		and type(acquired.is_settled) == "function" and type(acquired.on_settled) == "function" then
		timer = acquired
		if acquired.started == false then revoke("bootstrap_timer_start_refused") end
		local ok, registered = pcall(timer.on_settled, timer, function() retire() end)
		if not ok or registered ~= true then owner.acquisition_error = "bootstrap_timer_observer_refused"; revoke(owner.acquisition_error) end
	else
		-- A throwing/malformed constructor carries no physical empty receipt.
		owner.acquisition_error = "bootstrap_timer_acquisition_unknown"
		revoke(owner.acquisition_error)
	end
	acquiring = false
	if retiring then retire() end
	return owner, capability
end

return M
