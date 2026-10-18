--- infra/sqlite_batch_process.lua
--- ==============================================================================
--- MODULE: Private SQLite Batch Process
--- DESCRIPTION:
--- Sends SQL through an owned stdin pipe, independently of the shell argv limit.
--- Only the caller's small protocol stdout is staged; native errors and private
--- SQL never enter process output tails or logs. The supervisor owns pipe close.
--- ==============================================================================

local M = {}
local OwnedProcess = require("adapters.owned_process")
local Paths = require("infra.paths")
local loaded, Native = pcall(require, "luv")
if not loaded then Native = nil end

--- Returns whether the required native event-loop transport is installed.
--- @return boolean
function M.is_available()
	return type(Native) == "table" and type(Native.update_time) == "function"
end

--- Starts one SQLite process with private in-memory SQL input.
--- @param path string Exact database path.
--- @param sql string Complete SQL script.
--- @param options table { owner, timeout_ms }.
--- @return table|nil Retained request with poll(), cancel(), and is_settled().
function M.start(path, sql, options)
	assert(type(path) == "string" and path ~= "" and not path:find("\0", 1, true))
	assert(type(sql) == "string" and sql ~= "" and not sql:find("\0", 1, true))
	assert(type(options) == "table" and type(options.owner) == "string")
	if not M.is_available() then return nil end
	-- libuv timer_start uses cached loop time. Synchronous reads/initialization
	-- may precede the first loop tick; anchor this NEW operation to now before
	-- acquiring any native resource. Never refresh or reset a running deadline.
	Native.update_time()
	local executable = rawget(_G, "jit") and Native.exepath() or "luajit"
	local args = {
		Paths.driver_root() .. "/adapters/sqlite_process_worker.lua", string.format("%d", Native.os_getpid()),
		path:sub(1, 1) == "/" and path or ("./" .. path),
	}
	local pipe = Native.new_pipe(false)
	if not pipe then return nil end
	local input, request = { handle = pipe }, {}
	local state = { pending = nil, settled = false, cancelled = false, ok = false, listeners = {}, text = sql }
	local output, overflow, completion = "", false, nil
	local operation

	local function settle(ok)
		if state.settled or state.pending then return end
		state.settled, state.ok, state.text = true, ok == true, nil
		local listeners = state.listeners
		state.listeners = {}
		for _, listener in ipairs(listeners) do pcall(listener) end
	end

	function input:is_settled() return state.settled end
	function input:can_close() return state.settled and state.pending == nil end
	function input:result() return { ok = state.ok } end
	function input:on_settled(listener)
		if type(listener) ~= "function" then return false end
		if state.settled then pcall(listener) else state.listeners[#state.listeners + 1] = listener end
		return true
	end
	function input:cancel()
		state.cancelled = true
		settle(false)
		return state.settled
	end

	-- A throwing native submit may already own work. Only its captured callback
	-- can retire that exact request; failure cannot invent a cleanup receipt.
	local function submit(kind, invoke, callback)
		local work = { kind = kind }
		state.pending = work
		local called, native_request = pcall(invoke, function(err)
			if state.pending ~= work then return end
			state.pending = nil
			if err or state.cancelled then settle(false) else callback() end
		end)
		if not called then work.uncertain = true
		elseif not native_request and state.pending == work then state.pending = nil; settle(false) end
	end

	-- Production is LuaJIT. A PUC Lua parent used by the native compatibility
	-- suite still launches the installation's required LuaJIT for this FFI-only
	-- pre-exec binding; it never substitutes an unbound SQLite process.
	operation = OwnedProcess.start(executable, args, {
		owner = options.owner, timeout_ms = options.timeout_ms, stdin_owner = input,
		capture_output = false, max_output_bytes = 65536,
		on_output = function(chunk, stream)
			if stream ~= "stdout" or overflow then return end
			if #output + #chunk > 256 then output, overflow = "", true else output = output .. chunk end
		end,
	}, function(result)
		completion = { ok = result.ok == true, exit_code = result.exit_code }
	end)

	function request:is_settled() return operation:is_settled() == true end
	function request:cancel() return operation:cancel() end
	function request:poll()
		if not self:is_settled() then return nil end
		local result = completion or operation.result
		local protocol
		if not overflow then protocol = output end
		return {
			ok = type(result) == "table" and result.ok == true and not overflow,
			exit_code = type(result) == "table" and result.exit_code or nil,
			output = protocol,
		}
	end

	if operation.started == true and not state.cancelled and not state.settled then
		submit("write", function(callback) return Native.write(pipe, state.text, callback) end, function()
			state.text = nil
			submit("shutdown", function(callback) return Native.shutdown(pipe, callback) end, function() settle(true) end)
		end)
	else input:cancel() end
	return request
end

return M
