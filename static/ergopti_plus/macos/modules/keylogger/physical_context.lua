--- modules/keylogger/physical_context.lua

--- Retains observed privacy decisions for delayed physical input, without guessing
--- the OS focus-transition time from asynchronous watcher delivery.
local M = {}
local Interval = require("keylogger.physical_interval")

local function timestamp(value)
	assert(math.type(value) == "integer" and value >= 0, "Invalid physical context timestamp")
	return value
end

--- Creates a bounded context owner. Exhaustion requires retiring the capture;
--- evicting history could silently misattribute a delayed record from another device.
---@param capacity integer Maximum retained observations.
---@param format_epoch function Formats a captured wall-clock instant.
---@return table owner
function M.new(capacity, format_epoch)
	assert(math.type(capacity) == "integer" and capacity > 0, "Invalid physical context capacity")
	assert(type(format_epoch) == "function", "Missing physical context timestamp formatter")
	local observations, active = {}, true
	local interval_pending = false
	local owner = {}

	--- Revokes lookup before external native owners are stopped.
	function owner.stop() active, observations = false, {} end

	--- Copies a complete decision at its observed absolute nanosecond boundary.
	---@param observed_ns integer Observation time, not an inferred OS activation time.
	---@param context table allowed, app and epoch, with no live mutable state retained.
	function owner.observe(observed_ns, context)
		assert(active, "Physical context owner is retired")
		active = false
		timestamp(observed_ns)
		local previous = observations[#observations]
		assert(not previous or observed_ns > previous.at, "Physical context observations are not ordered")
		assert(#observations < capacity, "Physical context history exhausted")
		assert(type(context) == "table" and type(context.allowed) == "boolean", "Missing physical privacy decision")
		local snapshot = { at = observed_ns, allowed = context.allowed }
		if context.allowed then
			assert(type(context.app) == "string" and context.app ~= "", "Missing physical context application")
			assert(type(context.epoch) == "number" and context.epoch == context.epoch
				and math.abs(context.epoch) < math.huge, "Invalid physical context wall clock")
			snapshot.app, snapshot.epoch = context.app, context.epoch
		end
		observations[#observations + 1], active = snapshot, true
	end

	--- Resolves an original event against retained observations, never current app state.
	---@param original_ns integer Original timestamp converted into host nanoseconds.
	---@return table context Independent delivery decision.
	function owner.resolve(original_ns)
		assert(active, "Physical context owner is retired")
		timestamp(original_ns)
		local low, high, selected = 1, #observations, nil
		while low <= high do
			local middle = (low + high) // 2
			if observations[middle].at <= original_ns then
				selected, low = observations[middle], middle + 1
			else high = middle - 1 end
		end
		assert(selected, "Physical event predates retained context")
		if not selected.allowed then return { allowed = false } end
		local formatted = format_epoch(selected.epoch + (original_ns - selected.at) / 1000000000)
		assert(active, "Physical context owner was revoked during formatting")
		assert(type(formatted) == "string" and formatted ~= "", "Invalid physical context formatted timestamp")
		return { allowed = true, app = selected.app, timestamp = formatted }
	end

	--- Resolves an entire retained hold using the original permitted press context.
	--- Permission boundaries use their observed times, never inferred OS transition
	--- times. Any forbidden part cancels the hold; app changes keep press attribution.
	--- Source gaps must separately revoke the matched capture owner.
	---@param first_ns integer Original press converted into host nanoseconds.
	---@param last_ns integer Original release in the same clock domain.
	---@return table context Copied initial press context, or only allowed=false.
	function owner.resolve_interval(first_ns, last_ns)
		assert(active, "Physical context owner is retired")
		if interval_pending then
			active = false
			error("Physical context interval resolution reentered", 2)
		end
		timestamp(first_ns)
		timestamp(last_ns)
		assert(first_ns <= last_ns, "Physical context interval is reversed")
		assert(observations[1] and observations[1].at <= first_ns,
			"Physical event predates retained context")
		if not Interval.permits(observations, first_ns, last_ns) then return { allowed = false } end
		local retained, count = observations, #observations
		interval_pending = true
		local ok, context = pcall(owner.resolve, first_ns)
		interval_pending = false
		if not ok then error(context, 0) end
		assert(active, "Physical context owner was revoked during formatting")
		assert(observations == retained and #observations == count,
			"Physical interval history changed during formatting")
		return context
	end

	return owner
end

return M
