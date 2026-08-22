--- adapters/task_lifecycle.lua

--- ==============================================================================
--- MODULE: Native Task Lifecycle Adapter
--- DESCRIPTION:
--- Centralises the two independent failure contracts of raw Hammerspoon tasks:
--- construction may raise or return nil, while start may raise or return false.
--- Callers retain ownership of their GC pin and feature-specific rollback, but
--- receive one literal boolean that means the subprocess really launched.
---
--- FEATURES & RATIONALE:
--- 1. Nullable construction: nil is a logged failure, never an indexable handle.
--- 2. Strict start commitment: only a truthy native return commits the launch.
--- 3. Traceback preservation: native boundary exceptions remain searchable in
---    the central file logger after the async owner has returned.
--- ==============================================================================

local M = {}

local hs = hs
local Logger = require("infra.logger")

local LOG = "adapters.task_lifecycle"





-- =========================================
-- =========================================
-- ======= 1/ Native Task Operations =======
-- =========================================
-- =========================================

--- Wraps a native async callback so any exception reaches the central logger.
--- Successful return values are preserved verbatim; a throwing streaming
--- callback returns false so Hammerspoon stops delivering further chunks.
--- @param callback function|nil Native callback, or nil when none is required.
--- @param label string Human-readable operation label.
--- @return function|nil Guarded callback with the same success return contract.
function M.guard_callback(callback, label)
	if callback == nil then return nil end
	if type(callback) ~= "function" then
		Logger.error(LOG, "%s task callback is not callable.", tostring(label))
		return nil
	end
	return function(...)
		local args = table.pack(...)
		local results = table.pack(xpcall(function()
			return callback(table.unpack(args, 1, args.n))
		end, debug.traceback))
		if not results[1] then
			Logger.error(LOG, "%s task callback raised: %s.", tostring(label),
				tostring(results[2]))
			return false
		end
		return table.unpack(results, 2, results.n)
	end
end

--- Constructs one native task through a protected factory.
--- @param factory function Zero-argument function returning the native task.
--- @param label string Human-readable operation label.
--- @return any|nil Native task handle, or nil when construction failed.
function M.create(factory, label)
	if type(factory) ~= "function" then
		Logger.error(LOG, "%s task factory is not callable.", tostring(label))
		return nil
	end
	local ok, task_or_err = xpcall(factory, debug.traceback)
	if not ok then
		Logger.error(LOG, "%s task creation raised: %s.", tostring(label),
			tostring(task_or_err))
		return nil
	end
	if not task_or_err then
		Logger.error(LOG, "%s task creation returned nil.", tostring(label))
		return nil
	end
	return task_or_err
end

--- Constructs one hs.task with guarded completion and streaming callbacks.
--- Four-argument native form: native(label, path, on_done, args).
--- Five-argument native form: native(label, path, on_done, on_chunk, args).
--- A streaming callback with no arguments may omit args; an empty argv is used.
--- @param label string Human-readable operation label.
--- @param executable string Absolute launch path.
--- @param on_done function|nil Completion callback.
--- @param on_chunk_or_args function|table Streaming callback or argv table.
--- @param args table|nil Argv for the streaming form.
--- @return any|nil Native task handle, or nil on construction failure.
function M.native(label, executable, on_done, on_chunk_or_args, args)
	return M.create(function()
		local guarded_done = M.guard_callback(on_done, tostring(label) .. " completion")
		if type(on_chunk_or_args) == "function" then
			local guarded_chunk = M.guard_callback(on_chunk_or_args,
				tostring(label) .. " stream")
			return hs.task.new(executable, guarded_done, guarded_chunk, args or {})
		end
		return hs.task.new(executable, guarded_done, on_chunk_or_args)
	end, label)
end

--- Starts one native task and checks the operation's return value.
--- @param task any Native task handle returned by create().
--- @param label string Human-readable operation label.
--- @return boolean True only when the native start returned a truthy value.
function M.start(task, label)
	if not task then
		Logger.error(LOG, "%s task start received no native handle.", tostring(label))
		return false
	end
	local ok, started_or_err = xpcall(function() return task:start() end,
		debug.traceback)
	if not ok then
		Logger.error(LOG, "%s task start raised: %s.", tostring(label),
			tostring(started_or_err))
		return false
	end
	if not started_or_err then
		Logger.error(LOG, "%s task start was refused.", tostring(label))
		return false
	end
	return true
end

--- Sends one termination signal to an exact native task handle.
--- A truthy native return means only that signal delivery was accepted; the
--- owning feature must retain the task until its native completion callback.
--- @param task any Native task handle retained by the caller.
--- @param label string Human-readable operation label.
--- @return boolean accepted True only for a truthy native signal result.
function M.terminate(task, label)
	if not task then
		Logger.error(LOG, "%s task termination received no native handle.", tostring(label))
		return false
	end
	local ok_method, terminate_method = xpcall(function()
		return task.terminate
	end, debug.traceback)
	if not ok_method or type(terminate_method) ~= "function" then
		Logger.error(LOG, "%s task termination method is unavailable.", tostring(label))
		return false
	end
	local ok, accepted_or_err = xpcall(function()
		return terminate_method(task)
	end, debug.traceback)
	if not ok then
		Logger.error(LOG, "%s task termination raised: %s.", tostring(label),
			tostring(accepted_or_err))
		return false
	end
	if accepted_or_err == false or accepted_or_err == nil then
		Logger.error(LOG, "%s task termination was refused.", tostring(label))
		return false
	end
	return true
end

return M
