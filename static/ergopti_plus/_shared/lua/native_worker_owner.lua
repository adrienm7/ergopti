--- _shared/lua/native_worker_owner.lua

--- Native workers retain acquisition, process and timer debt until physical retirement.
local M = {}

--- Builds a native worker owner with injected IO, parsing and completion ports.
--- @param capture function Returns a request and its fresh admission callback.
--- @param ports table Native runner/timers, parse, complete, timeout_ms and retry_ms.
function M.new(capture, ports)
	assert(type(ports) == "table", "native worker ports are required")
	local runner, native, parse = ports.runner, ports.native, ports.parse
	local timeout, retry = ports.timeout_ms / 1000, ports.retry_ms / 1000
	assert(type(parse) == "function" and timeout > 0 and retry > 0, "native worker policy is invalid")
	local current, paused, generation = nil, false, 0
	local desired_paused = false
	local idle = {}
	local owner = {}
	local function notify_idle()
		if current ~= nil then return end
		local callbacks = idle; idle = {}
		for _, callback in ipairs(callbacks) do pcall(callback) end
	end
	local function release(entry)
		if current ~= entry then return end
		local deliver = not entry.cancelled and entry.status ~= nil and entry.admission and entry.admission()
		if current ~= entry then return end
		current = nil
		if desired_paused == false and paused then
			generation = generation + 1
			paused = false
		end
		if deliver and not entry.cancelled and type(ports.complete) == "function" then
			pcall(ports.complete, entry.status, entry.binding)
		end
		notify_idle()
	end
	local function settled(entry)
		if current ~= entry or entry.acquiring or entry.retiring or not entry.handle then return end
		local ok, value = pcall(entry.handle.isSettled)
		if not ok or value ~= true then return end
		if current ~= entry then return end
		if not entry.receipt_retired and type(ports.retire) == "function" then
			entry.retiring = true
			local retired, receipt = pcall(ports.retire, entry.binding, entry.status, entry.cancelled)
			entry.retiring = false
			if not retired or receipt ~= true then return end
			entry.receipt_retired = true
			if current ~= entry then return end
		end
		if entry.timer then
			if not entry.timer_stopped then
				local stop_ok, receipt = pcall(native.timer_stop, entry.timer)
				if not stop_ok or not (receipt == 0 or receipt == true) then return end
				entry.timer_stopped = true
			end
			if not entry.timer_retired then
				if entry.timer_closing then return end
				entry.timer_closing = true
				local timer = entry.timer
				local attempt = { admitted = false, callback_seen = false }
				entry.timer_close_attempt = attempt
				local close_ok, receipt, close_error = pcall(native.close, timer, function()
					if current ~= entry or entry.timer ~= timer or entry.timer_close_attempt ~= attempt then return end
					attempt.callback_seen = true
					-- Synchronous callbacks cannot borrow admission from an earlier close call.
					if not attempt.admitted then return end
					entry.timer_retired = true
					settled(entry)
				end)
				if not close_ok or close_error ~= nil or not (receipt == nil or receipt == 0 or receipt == true) then
					-- Rejected callbacks lose authority before a later attempt can be admitted.
					entry.timer_close_attempt, entry.timer_closing = nil, false
					return
				end
				attempt.admitted = true
				entry.timer_retired = attempt.callback_seen
				if not entry.timer_retired then return end
			end
			entry.timer = nil
		end
		release(entry)
	end
	local function cancel(entry)
		entry.cancelled = true
		entry.attempts = entry.attempts + 1
		if entry.handle then pcall(entry.handle.terminate, entry.attempts > 1) end
		settled(entry)
	end
	function owner.when_settled(callback)
		if type(callback) ~= "function" then return false end
		if current == nil then pcall(callback) else idle[#idle + 1] = callback end
		return true
	end
	function owner.stop()
		generation = generation + 1
		desired_paused, paused = true, true
		if current then cancel(current) end
		return current == nil
	end
	function owner.set_paused(value)
		if type(value) ~= "boolean" then return false end
		if value then return owner.stop() end
		desired_paused = false
		if current ~= nil then return false end
		generation = generation + 1
		paused = false
		return true
	end
	function owner.has_pending() return current ~= nil end
	function owner.run(binding)
		if paused or current ~= nil or type(capture) ~= "function" then return false end
		local epoch = generation
		local entry = { cancelled = false, attempts = 0, ticks = 0, acquiring = true, binding = binding }
		current = entry
		local ok, scalar, admission = pcall(capture, binding)
		local parsed_ok, parsed = pcall(parse, ok and scalar or nil)
		if not parsed_ok then parsed = nil end
		if type(parsed) ~= "table" or type(admission) ~= "function" or paused or generation ~= epoch or entry.cancelled then
			entry.acquiring = false
			release(entry)
			return false
		end
		local function admitted()
			if paused or generation ~= epoch or current ~= entry or entry.cancelled then return false end
			local holds, value = pcall(admission)
			return holds and value == true
		end
		entry.admission = admitted
		local created, handle = pcall(runner.spawn, parsed.executable, parsed.arguments,
			function(status)
				if not admitted() then return end
				entry.status = type(status) == "number" and status % 1 == 0 and status or -1
				if type(ports.observed) == "function" then pcall(ports.observed, entry.status) end
			end, admitted)
		if not created or type(handle) ~= "table" or type(handle.start) ~= "function"
			or type(handle.isSettled) ~= "function" or type(handle.terminate) ~= "function"
			or type(handle.onSettled) ~= "function" then
			entry.acquiring = false
			release(entry)
			return false
		end
		entry.handle = handle
		if paused or generation ~= epoch or entry.cancelled then
			pcall(handle.onSettled, function() settled(entry) end)
			entry.acquiring = false
			cancel(entry)
			return false
		end
		local armed = pcall(function()
			entry.timer = assert(native.new_timer())
			if paused or generation ~= epoch or current ~= entry or entry.cancelled then
				error("native worker timer acquisition revoked")
			end
			local result = native.timer_start(entry.timer, math.floor(retry * 1000), math.floor(retry * 1000), function()
				if current ~= entry then return end
				if type(ports.pulse) == "function" then
					local progressed, receipt = pcall(ports.pulse, entry.binding)
					if not progressed or receipt ~= true then cancel(entry); return end
					if current ~= entry then return end
				end
				settled(entry)
				if current ~= entry then return end
				entry.ticks = entry.ticks + 1
				if not admitted() or entry.ticks * retry >= timeout then cancel(entry) end
			end)
			if result ~= 0 and result ~= true then error("native worker timer refused") end
		end)
		if not armed then entry.acquiring = false; cancel(entry); return false end
		local started, accepted = pcall(handle.start)
		local observed, receipt = pcall(handle.onSettled, function() settled(entry) end)
		entry.acquiring = false
		if not started or accepted ~= true or not observed or receipt ~= true
			or (current ~= nil and not admitted()) or generation ~= epoch or paused then
			cancel(entry)
			return false
		end
		settled(entry)
		return true
	end
	return owner
end

return M
