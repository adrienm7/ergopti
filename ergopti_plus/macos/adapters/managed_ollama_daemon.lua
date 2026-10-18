--- adapters/managed_ollama_daemon.lua

--- ==============================================================================
--- MODULE: Managed Ollama daemon transport binding
--- DESCRIPTION:
--- Binds the existing Mac transport budget and original physical predicate to
--- the shared lifecycle receiver. Native qualification remains with its owners.
--- ==============================================================================

local M = {}
local Receipt = require("core.llm.managed_ollama_daemon_receipt")
local MAX_PROTOCOL_BYTES = require("adapters.owned_program_runner").MAX_PROTOCOL_BYTES

--- Prepares observations without launching or acquiring native resources.
--- @param task table Original ShellRunner handle, retained by its caller.
--- @param nonce string Exact lowercase hexadecimal caller nonce.
--- @return table|nil receiver Fixed shared lifecycle observations.
--- @return string|nil reason Fixed protocol refusal.
function M.new(task, nonce)
	local method
	if type(task) == "table" then
		local ok, value = pcall(function() return task.isSettled end)
		if ok and type(value) == "function" then method = value end
	end
	local ports = {
		max_protocol_bytes = MAX_PROTOCOL_BYTES,
		is_settled = function(original)
			if not rawequal(original, task) or not method then return nil end
			return method()
		end,
	}
	local ok, attempted = pcall(function() return task and task.wasStartAttempted end)
	if ok and type(attempted) == "function" then
		ports.was_start_attempted = function(original)
			if not rawequal(original, task) then return nil end
			return attempted()
		end
	end
	return Receipt.new(task, nonce, ports)
end

--- Acquires one original foreground task, with stdin kept open by streaming.
--- No detach, inherited startup file, sibling task, or readiness timer is used.
function M.prepare(command, nonce, callbacks)
	local ShellRunner = require("adapters.shell_runner")
	local Lifecycle = require("core.llm.managed_ollama_daemon_lifecycle")
	local task, handle
	local acquiring = true
	local early_delivery = false
	local function done(status, stdout)
		if acquiring or not handle then early_delivery = true; return end
		handle.complete(status, stdout)
	end
	local function chunk(_, stdout)
		if acquiring or not handle then early_delivery = true; return true end
		if type(stdout) == "string" and stdout ~= "" then handle.feed(stdout) end
		return true
	end
	task = ShellRunner.spawn("/bin/sh", { "-c", command }, done, chunk, nil, true, true)
	local start, cancel, settled, attempted, observe
	local capture_ok = pcall(function()
		start, cancel, settled, attempted, observe = task.start, task.terminate,
			task.isSettled, task.wasStartAttempted, task.onSettled
	end)
	if not capture_ok or type(start) ~= "function" or type(cancel) ~= "function"
		or type(settled) ~= "function" or type(attempted) ~= "function"
		or type(observe) ~= "function" or early_delivery then
		-- Return the exact partial transport to the caller for retained cleanup.
		return nil, "preparation", task
	end
	handle = Lifecycle.new(task, nonce, {
		max_protocol_bytes = MAX_PROTOCOL_BYTES,
		start = function(original) if rawequal(original, task) then return start() end end,
		cancel = function(original) if rawequal(original, task) then return cancel() end end,
		is_settled = function(original) if rawequal(original, task) then return settled() end end,
		was_start_attempted = function(original) if rawequal(original, task) then return attempted() end end,
		observe = function(original, callback)
			if rawequal(original, task) then return observe(callback) end
		end,
	}, callbacks)
	acquiring = false
	if not handle then return nil, "preparation", task end
	return handle, nil, nil
end

return M
