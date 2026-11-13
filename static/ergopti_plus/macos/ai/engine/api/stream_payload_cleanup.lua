--- ai/engine/api/stream_payload_cleanup.lua

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
	local files = require("core.fs.adapters.file_system")
	assert(type(files) == "table" and type(files.remove_if_unchanged) == "function"
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
		local function consume()
			receipt.path, receipt.task_provider, receipt.busy = nil, nil, false
			pending[receipt] = nil
			if receipt.reported then logger.debug(log, "Retained streaming payload cleanup settled.") end
			return true
		end
		if receipt.uncertain then
			local ok, attributes, status = pcall(files.classify_no_follow, receipt.path)
			if ok and attributes == nil and status == "absent" then return consume() end
			return retain(receipt, "unlink outcome unknown")
		end
		if receipt.release then
			local ok, released = pcall(receipt.release)
			if not ok or released ~= true then return retain(receipt, "cleanup release refused") end
			receipt.release = nil
			if receipt.removed then return consume() end
		end
		local inspected, attributes, status = pcall(files.classify_no_follow, receipt.path)
		if inspected and attributes == nil and status == "absent" then return consume() end
		local expected = receipt.identity
		if not inspected or status ~= "ok" or type(attributes) ~= "table" or attributes.mode ~= "file"
			or type(expected) ~= "table" or type(expected.dev) ~= "number" or math.tointeger(expected.dev) == nil
			or type(expected.ino) ~= "number" or math.tointeger(expected.ino) == nil
			or attributes.dev ~= expected.dev or attributes.ino ~= expected.ino
			or type(receipt.content) ~= "string" then
			return retain(receipt, "source identity unavailable or changed")
		end
		-- The adapter serializes cooperating writers and rechecks bytes. This
		-- admission catches an already-replaced inode, but cannot make the later
		-- pathname unlink atomic against a noncooperating external process.
		local function same_identity()
			local ok, current, current_status = pcall(files.classify_no_follow, receipt.path)
			return ok and current_status == "ok" and type(current) == "table" and current.mode == "file"
				and current.dev == expected.dev and current.ino == expected.ino
		end
		local called, removed, _, physical, release = pcall(files.remove_if_unchanged,
			receipt.path, { status = "ok", content = receipt.content }, function() end, same_identity)
		if not called or type(removed) ~= "boolean" then
			receipt.uncertain = true
			return retain(receipt, "unlink outcome unknown")
		end
		if removed == true then return consume() end
		if type(release) == "function" then
			receipt.release = release
			receipt.removed = type(physical) == "table" and physical.removed == true
		end
		return retain(receipt, "unlink refused")
	end

	--- Captures only a fully admitted payload, never a failed writer's pathname.
	--- @param path string Acknowledged payload pathname.
	--- @param task_provider function Exact ShellRunner handle, or nil before construction.
	--- @param identity table|nil Original allocation device and inode.
	--- @param content string|nil Exact admitted payload bytes.
	--- @return function cleanup Exact request's idempotent cleanup operation.
	function registry.capture(path, task_provider, identity, content)
		assert(type(path) == "string" and path ~= "", "payload cleanup needs a pathname")
		assert(type(task_provider) == "function", "payload cleanup needs its exact task provider")
		local captured_identity = type(identity) == "table" and { dev = identity.dev, ino = identity.ino } or nil
		local receipt = { path = path, task_provider = task_provider, identity = captured_identity, content = content }
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
