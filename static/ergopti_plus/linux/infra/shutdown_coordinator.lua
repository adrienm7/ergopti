--- infra/shutdown_coordinator.lua

--- ==============================================================================
--- MODULE: Linux Shutdown Coordinator
--- DESCRIPTION:
--- Quiesces every external event-loop owner before stopping input and asking
--- the loop to return. The coordinator is a factory so tests and daemon instances
--- have independent one-shot ownership.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")

local LOG = "infra.shutdown_coordinator"

--- Builds one shutdown owner.
--- @param opts table { pre_wait, keyboard_hook, event_loop }
--- @return table
function M.new(opts)
	if type(opts) ~= "table" then error("shutdown coordinator options must be a table", 2) end
	local pre_wait = opts.pre_wait
	local keyboard_hook = opts.keyboard_hook
	local event_loop = opts.event_loop
	if type(pre_wait) ~= "table" then error("shutdown pre_wait registry must be a table", 2) end
	if type(keyboard_hook) ~= "table" or type(keyboard_hook.isRunning) ~= "function"
		or type(keyboard_hook.stop) ~= "function" or type(keyboard_hook.emergency_stop) ~= "function" then
		error("shutdown keyboard_hook contract is incomplete", 2)
	end
	if type(event_loop) ~= "table" or type(event_loop.stop) ~= "function" then
		error("shutdown event_loop contract is incomplete", 2)
	end
	for index, owner in ipairs(pre_wait) do
		if type(owner) ~= "table" or type(owner.name) ~= "string" or owner.name == ""
			or type(owner.stop) ~= "function" then
			error(string.format("shutdown pre_wait owner %d is invalid", index), 2)
		end
	end

	local requested = false
	local coordinator = {}

	--- Quiesces every registered owner exactly once.
	--- @param reason string Human-readable shutdown trigger.
	--- @param emergency_reason string|nil Passed to the hook's emergency stop.
	--- @return boolean started True only for the first request.
	function coordinator.request(reason, emergency_reason)
		if requested then return false end
		requested = true
		Logger.start(LOG, "Shutdown quiescence started (%s).", tostring(reason or "unspecified"))

		for _, owner in ipairs(pre_wait) do
			local ok, failure = xpcall(owner.stop, debug.traceback)
			if not ok then
				Logger.error(LOG, "Shutdown owner '%s' failed: %s", owner.name, tostring(failure))
			end
		end

		if keyboard_hook.isRunning() then
			if type(emergency_reason) == "string" and emergency_reason ~= "" then
				keyboard_hook.emergency_stop(emergency_reason)
			else
				keyboard_hook.stop()
			end
		end
		event_loop.stop()
		Logger.done(LOG, "Shutdown quiescence complete.")
		return true
	end

	--- Reports whether a request already owns shutdown.
	--- @return boolean
	function coordinator.is_requested()
		return requested
	end

	return coordinator
end

return M
