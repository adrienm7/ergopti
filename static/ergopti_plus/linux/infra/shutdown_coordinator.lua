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

	local requested, complete, polling = false, false, false
	local registering, input_stopped = false, false
	local pending, native_claims = {}, {}
	local coordinator = {}

	local function finish()
		if not complete and not registering and not polling and input_stopped and next(pending) == nil then
			complete = true
			event_loop.stop()
			Logger.done(LOG, "Shutdown quiescence complete.")
		end
	end

	--- Rechecks one immutable native claim without recursively borrowing its acknowledgment.
	--- @param claim table Captured cleanup and observer callbacks.
	local function acknowledge(claim)
		if not pending[claim] or claim.checking then return end
		claim.checking = true
		local ok, settled = xpcall(claim.stop, debug.traceback)
		claim.checking = false
		if ok and settled == true then pending[claim] = nil end
		finish()
	end

	--- Quiesces every registered owner exactly once.
	--- @param reason string Human-readable shutdown trigger.
	--- @param emergency_reason string|nil Passed to the hook's emergency stop.
	--- @return boolean started True only for the first request.
	function coordinator.request(reason, emergency_reason)
		if requested then return false end
		requested, polling, registering = true, true, true
		-- Pin both polling and observer owners before diagnostics or earlier cleanup can reenter.
		local owners, claims, waits_for_native = {}, {}, false
		for index, owner in ipairs(pre_wait) do
			owners[index] = owner
			if owner.wait_for_ack == true or type(owner.when_settled) == "function" then
				local claim = { name = owner.name, stop = owner.stop, when_settled = owner.when_settled }
				claims[index] = claim
				native_claims[#native_claims + 1] = claim
				waits_for_native = true
			end
		end
		if waits_for_native then
			pcall(Logger.start, LOG, "Shutdown quiescence started (%s).", tostring(reason or "unspecified"))
		else
			Logger.start(LOG, "Shutdown quiescence started (%s).", tostring(reason or "unspecified"))
		end

		for index, owner in ipairs(owners) do
			local claim = claims[index]
			local stop, name = claim and claim.stop or owner.stop, claim and claim.name or owner.name
			local ok, failure = xpcall(stop, debug.traceback)
			if claim and (not ok or failure ~= true) then pending[claim] = true end
			if not ok then
				if waits_for_native then
					pcall(Logger.error, LOG, "Shutdown owner '%s' failed: %s", name, tostring(failure))
				else
					Logger.error(LOG, "Shutdown owner '%s' failed: %s", name, tostring(failure))
				end
			end
			if claim and pending[claim] and type(claim.when_settled) == "function" then
				pcall(claim.when_settled, function() acknowledge(claim) end)
			end
		end

		if keyboard_hook.isRunning() then
			if type(emergency_reason) == "string" and emergency_reason ~= "" then
				keyboard_hook.emergency_stop(emergency_reason)
			else
				keyboard_hook.stop()
			end
		end
		input_stopped, registering, polling = true, false, false
		finish()
		return true
	end

	--- Retries only opt-in native owners while the existing event loop remains alive.
	--- Ordinary owners retain their original one-shot cleanup contract.
	--- @return boolean complete Every opt-in owner acknowledged physical retirement.
	function coordinator.poll()
		if not requested or complete or polling then return complete end
		polling = true
		for _, claim in ipairs(native_claims) do acknowledge(claim) end
		polling = false
		finish()
		return complete
	end

	--- Reports the retained native cleanup barrier independently of first request.
	--- @return boolean pending
	function coordinator.is_pending() return requested and not complete end

	--- Reports whether a request already owns shutdown.
	--- @return boolean
	function coordinator.is_requested()
		return requested
	end

	return coordinator
end

return M
