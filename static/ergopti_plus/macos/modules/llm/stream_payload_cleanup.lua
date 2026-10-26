--- modules/llm/stream_payload_cleanup.lua

--- ==============================================================================
--- MODULE: Streaming Payload Cleanup Ownership
--- DESCRIPTION:
--- Keep refused payload unlinks owned independently of prediction generations.
--- A successful unlink consumes its pathname authority before any later callback.
--- ==============================================================================

local M = {}

--- Creates one backend's pending payload cleanup registry without allocating files.
--- @param logger table Canonical backend logger.
--- @param log string Backend log identity.
--- @return table registry Payload capture and admission settlement operations.
function M.new(logger, log)
	assert(type(logger) == "table" and type(logger.error) == "function"
		and type(logger.debug) == "function", "payload cleanup needs the canonical logger")
	assert(type(log) == "string" and log ~= "", "payload cleanup needs a backend log identity")
	local files = require("adapters.file_system")
	assert(type(files) == "table" and type(files.remove_exact) == "function"
		and type(files.classify_no_follow) == "function", "payload cleanup needs exact file cleanup ports")
	local pending, settling = {}, false
	local registry = {}

	local function retain(receipt, category)
		pending[receipt] = true
		local emitted, emit_error = true, nil
		if category then
			receipt.reported = receipt.reported or {}
			if not receipt.reported[category] then
				receipt.reported[category] = true
				emitted, emit_error = pcall(logger.error, log,
					"Streaming payload %s; exact cleanup is retained for retry.", category)
			end
		end
		receipt.busy = false
		if not emitted then error(emit_error, 0) end
		return false
	end

	local function retire(receipt)
		if receipt.path == nil then return true end
		if receipt.busy then return false end
		receipt.busy = true
		local observed, task = pcall(receipt.task_provider)
		if not observed then return retain(receipt, "settlement inspection refused") end
		if task ~= nil then
			local inspected, settled = pcall(function() return task.isSettled() end)
			if not inspected or type(settled) ~= "boolean" then
				return retain(receipt, "settlement inspection refused")
			end
			if settled ~= true then return retain(receipt) end
		end
		local removed_ok, removed = pcall(files.remove_exact, receipt.path)
		local absent = false
		if not removed_ok or removed ~= true then
			local inspected, attributes, status = pcall(files.classify_no_follow, receipt.path)
			absent = inspected and attributes == nil and status == "absent"
		end
		if (removed_ok and removed == true) or absent then
			-- Clear delete authority before diagnostics can reenter a successor.
			receipt.path, receipt.task_provider, receipt.busy = nil, nil, false
			pending[receipt] = nil
			if receipt.reported then logger.debug(log, "Retained streaming payload cleanup settled.") end
			return true
		end
		-- Business completion may retire its task now; this registry still owns
		-- the exact pathname when the fallback timer also refuses or finishes.
		return retain(receipt, "unlink refused")
	end

	--- Captures only a fully admitted payload, never a failed writer's pathname.
	--- @param path string Acknowledged payload pathname.
	--- @param task_provider function Exact ShellRunner handle, or nil before construction.
	--- @return function cleanup Exact request's idempotent cleanup operation.
	function registry.capture(path, task_provider)
		assert(type(path) == "string" and path ~= "", "payload cleanup needs a pathname")
		assert(type(task_provider) == "function", "payload cleanup needs its exact task provider")
		local receipt = { path = path, task_provider = task_provider }
		return function() return retire(receipt) end
	end

	--- Settles earlier refused cleanups before another stream allocates a payload.
	--- @return boolean settled Whether every retained pathname was retired.
	function registry.settle_pending()
		if settling then return false end
		settling = true
		local ok, settled = xpcall(function()
			local captured = {}
			for receipt in pairs(pending) do captured[#captured + 1] = receipt end
			for _, receipt in ipairs(captured) do
				if retire(receipt) ~= true then return false end
			end
			return true
		end, debug.traceback)
		settling = false
		if not ok then error(settled, 0) end
		return settled == true
	end

	return registry
end

return M
