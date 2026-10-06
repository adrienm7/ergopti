--- _shared/lua/llm/process_port.lua

--- Shared worker policy over an injected exact native process capability.
--- Shared finite/service bridge: physical IO and timer policy retain their owners.
local M = {}
local Defaults = require("llm.process_limits").defaults()

local function strings(value, environment)
	if type(value) ~= "table" then return nil end
	local copy, count, largest = {}, 0, 0
	for key, item in next, value do
		if type(key) ~= "number" or key <= 0 or key % 1 ~= 0 or type(item) ~= "string"
			or item:find("\0", 1, true) or (environment and not item:match("^[^=]+=")) then return nil end
		copy[key], count, largest = item, count + 1, math.max(largest, key)
	end
	if count ~= largest then return nil end
	return copy
end

local function result_copy(value, reason)
	if type(value) ~= "table" then return { ok = false, exit_code = -1, stdout = "", stderr = "", error = reason } end
	return { ok = value.ok == true, exit_code = value.exit_code, stdout = value.stdout,
		stderr = value.stderr, error = value.error, signal = value.signal }
end

--- Creates a singleton process port with finite and explicit service admission.
--- Worker.new is the published shared native_worker_owner API; NativeProcess.start
--- is the exact physically owned Linux process port. Native supplies timer IO.
function M.new(Worker, NativeProcess, native, retry_ms)
	assert(type(Worker) == "table" and type(Worker.new) == "function", "shared worker required")
	assert(type(NativeProcess) == "table" and type(NativeProcess.start) == "function", "exact process port required")
	assert(type(native) == "table", "native timer port required")
	retry_ms = retry_ms or Defaults.worker_retry_ms
	assert(type(retry_ms) == "number" and retry_ms > 0 and retry_ms % 1 == 0, "positive finite retry required")
	local construct, native_start = Worker.new, NativeProcess.start
	local owners, port = {}, {}

	local function start(service, executable, arguments, options, callback)
		local label = service and "service" or "finite"
		local operation = { started = false }
		local listeners, settled, cancelled, worker, facade = {}, false, false, nil, nil
		local source, owner, timeout, bound, tail, output, env, cwd
		if type(options) == "table" then
			source, owner, timeout = rawget(options, "authorized"), rawget(options, "owner"), rawget(options, "timeout_ms")
			bound, tail, output = rawget(options, "max_output_bytes"), rawget(options, "capture_tail"), rawget(options, "on_output")
			env, cwd = rawget(options, "env"), rawget(options, "cwd")
		end
		local args = strings(arguments)
		if env ~= nil then env = strings(env, true) end
		bound = bound or Defaults.max_output_bytes
		local function current()
			if cancelled then return false end
			if source == nil then return true end
			local ok, value = pcall(source)
			return ok and value == true and not cancelled
		end
		local function notify(fn, ...)
			if type(fn) == "function" then pcall(fn, ...) end
		end
		local function retire(deliver)
			if settled then return end
			settled = true
			operation.cleanup_error = nil
			if owners[owner] == operation then owners[owner] = nil end
			if not operation.result then
				operation.result = result_copy(facade and facade.native_operation and facade.native_operation.result,
					cancelled and "cancelled" or (label .. "_worker_refused"))
			end
			if deliver and current() then notify(callback, operation.result) end
			local pending = listeners; listeners = {}
			for _, listener in ipairs(pending) do notify(listener) end
		end
		function operation:is_settled() return settled end
		function operation:is_current()
			if settled or cancelled or owners[owner] ~= operation then return false end
			local admitted = current()
			return admitted and not settled and not cancelled and owners[owner] == operation
		end
		--- Requires the captured physical operation's observed running state.
		function operation:is_running()
			if not operation:is_current() or not facade or facade.acquiring or facade.unknown_debt then return false end
			local capability = facade.native_operation
			if type(capability) ~= "table" or type(capability.is_running) ~= "function" then return false end
			local ok, running = pcall(capability.is_running, capability)
			if not ok or running ~= true or not operation:is_current() then return false end
			-- The last source predicate may revoke native state as well. Recheck
			-- the same captured capability before the final logical owner claim.
			local observed, latest = pcall(capability.is_running, capability)
			return observed and latest == true and not settled and not cancelled
				and owners[owner] == operation and facade.native_operation == capability
		end
		function operation:on_settled(listener)
			if type(listener) ~= "function" then return false end
			if settled then notify(listener) else listeners[#listeners + 1] = listener end
			return true
		end
		function operation:cancel()
			cancelled = true
			if worker then
				local ok = pcall(worker.stop)
				if not ok then operation.cleanup_error = (label .. "_worker_stop_exception") end
			end
			return settled
		end
		local function refuse(reason)
			operation.result = result_copy(nil, reason)
			retire(true)
			return operation
		end
		if type(executable) ~= "string" or executable == "" or executable:find("\0", 1, true)
			or not args or type(owner) ~= "string" or owner == "" or type(callback) ~= "function"
			or not ((service and timeout == false) or (not service and type(timeout) == "number"
				and timeout > 0 and timeout % 1 == 0))
			or (service and type(source) ~= "function")
			or type(bound) ~= "number" or bound <= 0 or bound % 1 ~= 0
			or (source ~= nil and type(source) ~= "function")
			or (tail ~= nil and type(tail) ~= "boolean")
			or (output ~= nil and type(output) ~= "function")
			or (type(options) == "table" and rawget(options, "env") ~= nil and env == nil)
			or (cwd ~= nil and (type(cwd) ~= "string" or cwd:sub(1, 1) ~= "/" or cwd:find("\0", 1, true))) then
			return refuse((label .. "_process_admission_invalid"))
		end
		if owners[owner] then return refuse((label .. "_process_owner_busy")) end
		-- Reserve before any external admission predicate can synchronously reenter.
		owners[owner] = operation

		local runner = {}
		function runner.spawn(program, vector, observed, admitted)
			-- No native acquisition or external call occurs in deferred construction.
			local handle = { acquiring = false, dispatched = false, stopped = false, listeners = {} }
			facade = handle
			local function announce()
				if not handle.isSettled() then return end
				local pending = handle.listeners; handle.listeners = {}
				for _, listener in ipairs(pending) do notify(listener) end
			end
			function handle.isSettled()
				if handle.acquiring or handle.unknown_debt then return false end
				if not handle.dispatched then return true end
				if not handle.native_operation then return false end
				local ok, receipt = pcall(handle.native_operation.is_settled, handle.native_operation)
				return ok and receipt == true
			end
			function handle.onSettled(listener)
				if type(listener) ~= "function" then return false end
				if handle.isSettled() then notify(listener) else handle.listeners[#handle.listeners + 1] = listener end
				return true
			end
			function handle.terminate()
				handle.stopped = true
				if handle.native_operation then pcall(handle.native_operation.cancel, handle.native_operation) end
				announce()
				return handle.isSettled()
			end
			function handle.start()
				if handle.dispatched or handle.stopped or not admitted() then return false end
				handle.dispatched, handle.acquiring = true, true
				local ok, capability = pcall(native_start, program, vector, {
					owner = owner, authorized = admitted, max_output_bytes = bound,
					capture_tail = tail, on_output = output, env = env, cwd = cwd,
					-- Shared worker owns finite/service admission. Native owner owns physical IO.
					timeout_ms = nil,
				}, function(result)
					operation.result = result_copy(result, (label .. "_process_receipt_missing"))
					observed(type(operation.result.exit_code) == "number" and operation.result.exit_code or -1)
				end)
				handle.acquiring = false
				if not ok or type(capability) ~= "table" or type(capability.cancel) ~= "function"
					or type(capability.is_settled) ~= "function" or type(capability.on_settled) ~= "function" then
					handle.unknown_debt = true
					operation.cleanup_error = (label .. "_process_unknown_acquisition_debt")
					return false
				end
				handle.native_operation = capability
				operation.started = capability.started == true
				local registered, receipt = pcall(capability.on_settled, capability, announce)
				if not registered or receipt ~= true then
					-- isSettled remains authoritative; shared retry timer can still poll it.
					operation.cleanup_error = (label .. "_process_settlement_listener_refused")
				end
				if handle.stopped then pcall(capability.cancel, capability) end
				announce()
				-- A structurally valid refused capability still owns an explicit result.
				return true
			end
			return handle
		end

		local ok, value = pcall(construct, function()
			return { executable = executable, arguments = args }, current
		end, {
			runner = runner, native = native, timeout_ms = timeout, retry_ms = retry_ms,
			parse = function(request) return request end,
			complete = function() retire(true) end,
		})
		if not ok or type(value) ~= "table" or type(value.run) ~= "function"
			or type(value.stop) ~= "function" or type(value.when_settled) ~= "function" then
			-- Worker construction is pure under this pinned API; no runner has run.
			return refuse((label .. "_worker_construction_refused"))
		end
		worker = value
		local ran = pcall(worker.run)
		if not ran then
			operation.cleanup_error = (label .. "_worker_unknown_retirement_debt")
			return operation
		end
		local registered, receipt = pcall(worker.when_settled, function() retire(true) end)
		if not registered or receipt ~= true then
			operation.cleanup_error = (label .. "_worker_unknown_retirement_debt")
			return operation
		end
		return operation
	end
	--- Starts only an explicitly finite helper, preserving its original refusal API.
	function port.start(...) return start(false, ...) end

	--- Starts only an explicitly source-owned service with timeout_ms=false.
	function port.start_service(...) return start(true, ...) end
	return port
end

return M
