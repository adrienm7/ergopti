-- tools/diagnostics/hs_delayed_timer_native.lua
-- Records the packaged Hammerspoon delayed-timer contract for an external judge.
-- The launch gate owns the live process; this fixture owns only its timers.

local M = {}
local GLOBAL_KEY = "__ergopti_native_delayed_timer_probe"

function M.run(receipt_path, nonce)
	assert(_G[GLOBAL_KEY] == nil, "A native delayed-timer probe already owns its callbacks")
	local owner = { nonce = nonce, timers = {}, settled = false }
	_G[GLOBAL_KEY] = owner
	local result = {
		schema_version = 1,
		contract = "hs.timer.delayed",
		nonce = nonce,
		pid = hs.processInfo.processID,
		executable = hs.processInfo.executablePath,
		bundle_id = hs.processInfo.bundleID,
		version = hs.processInfo.version,
		complete = false,
		observations = {},
		deliveries = { rearm = 0, zero = 0 },
		errors = {},
	}
	local observations = result.observations

	function owner.cleanup()
		for _, timer in ipairs(owner.timers) do
			local ok, stopped = pcall(timer.stop, timer)
			if not ok or stopped == nil or stopped == false then
				result.errors[#result.errors + 1] = "Native timer stop refused: " .. tostring(stopped)
			end
		end
		return #result.errors == 0
	end

	local function finish(complete)
		if owner.settled then return end
		owner.settled = true
		local stopped = owner.cleanup()
		result.complete = complete and stopped
		local encoded = hs.json.encode(result)
		local temporary = receipt_path .. ".pending"
		local file, open_error = io.open(temporary, "wb")
		if not file then error("Native receipt could not be opened: " .. tostring(open_error)) end
		local written, write_error = file:write(encoded .. "\n")
		local closed, close_error = file:close()
		if not written or not closed then
			error("Native receipt write refused: " .. tostring(write_error or close_error))
		end
		local renamed, rename_error = os.rename(temporary, receipt_path)
		if not renamed then error("Native receipt commit refused: " .. tostring(rename_error)) end
	end

	local function guarded(callback)
		return function()
			local ok, detail = xpcall(callback, debug.traceback)
			if not ok then
				result.errors[#result.errors + 1] = tostring(detail)
				finish(false)
			end
		end
	end

	local function observe_completion()
		if result.deliveries.rearm == 2 and result.deliveries.zero == 1 then
			-- Publish on a later callback so the repeating native timer has settled
			-- the second delivery before the external judge reads its observations.
			owner.observer = hs.timer.doAfter(0, guarded(function() finish(true) end))
			owner.timers[#owner.timers + 1] = owner.observer
		end
	end

	owner.methods = hs.timer.delayed.new(10, function()
		result.errors[#result.errors + 1] = "The stopped method-probe timer unexpectedly fired"
		finish(false)
	end)
	owner.timers[#owner.timers + 1] = owner.methods
	local methods = owner.methods
	observations.idle_running = methods:running()
	observations.idle_next_trigger_nil = methods:nextTrigger() == nil
	observations.idle_set_delay_returns_self = methods:setDelay(5) == methods
	observations.idle_set_delay_keeps_idle = not methods:running()
	observations.override_start_returns_self = methods:start(1) == methods
	observations.override_remaining = methods:nextTrigger()
	observations.default_start_returns_self = methods:start() == methods
	observations.default_remaining = methods:nextTrigger()
	observations.active_set_delay_returns_self = methods:setDelay(3) == methods
	observations.active_configured_remaining = methods:nextTrigger()
	observations.stop_returns_self = methods:stop() == methods
	observations.stopped_running = methods:running()
	observations.stopped_next_trigger_nil = methods:nextTrigger() == nil

	owner.rearm = hs.timer.delayed.new(1, guarded(function()
		result.deliveries.rearm = result.deliveries.rearm + 1
		if result.deliveries.rearm == 1 then
			observations.rearm_returns_self = owner.rearm:start(0.05) == owner.rearm
		elseif result.deliveries.rearm > 2 then
			result.errors[#result.errors + 1] = "The delayed timer delivered an unexpected third callback"
			finish(false)
		end
		observe_completion()
	end))
	owner.timers[#owner.timers + 1] = owner.rearm
	owner.zero = hs.timer.delayed.new(0, guarded(function()
		result.deliveries.zero = result.deliveries.zero + 1
		observe_completion()
	end))
	owner.timers[#owner.timers + 1] = owner.zero
	owner.rearm:start(0.05)
	owner.zero:start()
	observations.zero_running = owner.zero:running()
	observations.zero_next_trigger_nil = owner.zero:nextTrigger() == nil
	owner.watchdog = hs.timer.doAfter(10, guarded(function()
		result.errors[#result.errors + 1] = "Native delayed-timer callbacks did not complete before the watchdog"
		finish(false)
	end))
	owner.timers[#owner.timers + 1] = owner.watchdog
	return nonce
end

function M.cleanup(nonce)
	local owner = assert(_G[GLOBAL_KEY], "The native delayed-timer owner is missing")
	assert(owner.nonce == nonce, "A different native delayed-timer probe owns the callbacks")
	local stopped = owner.cleanup()
	_G[GLOBAL_KEY] = nil
	assert(stopped, "Native delayed-timer cleanup did not acknowledge every stop")
	return nonce
end

return M
