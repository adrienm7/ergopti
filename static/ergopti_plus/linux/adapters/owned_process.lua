--- adapters/owned_process.lua

--- ==============================================================================
--- MODULE: Owned Native Process Operation (Linux)
--- DESCRIPTION:
--- Retains a referenced libuv process group, bounded output and every allocated
--- native handle until actual process exit, group absence and close callbacks.
--- A cancellation signal fences delivery without manufacturing settlement.
--- ==============================================================================

local M = {}
local Logger = require("logger.shim")
local Shell = require("adapters.shell_runner")
local Exit = require("infra.libuv_exit")
local Group = require("infra.libuv_process_group")
local Defaults = require("llm.process_limits").defaults()
local available, native = pcall(require, "luv")
if not available then native = nil end

local LOG = "adapters.owned_process"
local DEFAULT_MAX_OUTPUT_BYTES = Defaults.max_output_bytes
local GROUP_RECHECK_MS = Defaults.group_recheck_ms
local owners = {}





-- ======================================
-- ======================================
-- ======= 1/ Native Receipts ===========
-- ======================================
-- ======================================

--- Admits a native operation's success return without accepting an error.
--- @param fn function
--- @param ... any
--- @return boolean
local function accepted(fn, ...)
	local ok, result, err = pcall(fn, ...)
	return ok and (result == 0 or result == true) and err == nil
end

--- Requires optional originating-source admission to acknowledge literal true.
--- @param request table
--- @return boolean
local function authorized(request)
	if request.cancelled or request.terminal then return false end
	if request.options.authorized == nil then return true end
	local ok, value = pcall(request.options.authorized)
	return ok and value == true
end

--- Publishes the result only after every physically owned resource settles.
--- @param request table
local function stdin_settled(request)
	local input = request.stdin_owner
	if not input then return true end
	local called, ack = pcall(input.is_settled, input.source)
	return called and ack == true and request.stdin_owner == input
end

local function settle(request)
	if request.settled or not request.terminal or request.dispatching then return end
	if request.spawned and (not request.exited or not request.group_absent) then return end
	if not stdin_settled(request) or request.settled then return end
	for _, receipt in pairs(request.handles) do
		if receipt.state ~= "closed" then return end
	end
	request.settled = true
	if owners[request.owner] == request.operation then owners[request.owner] = nil end
	local callback_allowed = not request.cancelled
	if callback_allowed and request.options.authorized then
		local ok, value = pcall(request.options.authorized)
		callback_allowed = ok and value == true
	end
	if callback_allowed then
		local ok = pcall(request.callback, request.operation.result)
		if not ok then Logger.error(LOG, "Owned process completion callback failed.") end
	end
	local listeners = request.listeners
	request.listeners = {}
	for _, listener in ipairs(listeners) do
		local ok = pcall(listener)
		if not ok then Logger.error(LOG, "Owned process settlement callback failed.") end
	end
end

--- Captures one newly allocated native handle before subsequent fallible work.
--- @param request table
--- @param handle any
--- @param kind string
--- @return boolean
local function own_handle(request, handle, kind)
	if type(handle) ~= "userdata" and type(handle) ~= "table" then return false end
	request.handles[handle] = { state = "open", kind = kind, active = false }
	request[kind] = handle
	return true
end

--- Stops and closes a handle, retaining refusal until its own close callback.
--- @param request table
--- @param handle any
--- @return boolean
local function close_handle(request, handle)
	if not handle then return true end
	local receipt = request.handles[handle]
	if not receipt then return false end
	if receipt.state == "closed" or receipt.state == "closing" then return true end
	if receipt.kind == "process" and not request.exited then return false end
	if receipt.kind == "stdin" then
		local input = request.stdin_owner
		local called, ready = pcall(input.can_close, input.source)
		if not called or ready ~= true or request.stdin_owner ~= input
			or request.handles[handle] ~= receipt or receipt.state ~= "open" then return false end
	end
	if receipt.active then
		local stop = native.timer_stop
		if receipt.kind == "stdout" or receipt.kind == "stderr" then stop = native.read_stop end
		if type(stop) ~= "function" or not accepted(stop, handle) then
			request.operation.cleanup_error = "native handle stop refused"
			return false
		end
		receipt.active = false
		if receipt.kind == "cleanup" then request.cleanup_watching = false end
	end
	local ok, closing = pcall(native.is_closing, handle)
	if not ok or type(closing) ~= "boolean" or closing then
		request.operation.cleanup_error = "native handle close ownership refused"
		return false
	end
	receipt.state = "closing"
	local attempt = { admitted = false, callback_seen = false }
	receipt.close_attempt = attempt
	local close_ok, close_receipt, close_error = pcall(native.close, handle, function()
		if request.handles[handle] ~= receipt or receipt.close_attempt ~= attempt
			or receipt.state ~= "closing" then return end
		attempt.callback_seen = true
		-- Physical callback authority belongs only to this acknowledged call.
		if not attempt.admitted then return end
		receipt.state = "closed"
		settle(request)
	end)
	local closed = close_ok and close_error == nil and (close_receipt == 0 or close_receipt == true)
	-- libuv close returns no value. Require its independent native transition
	-- from the pre-call open state; a malformed nil port cannot invent admission.
	if close_ok and close_error == nil and close_receipt == nil then
		local observed, now_closing = pcall(native.is_closing, handle)
		closed = observed and now_closing == true
	end
	if not closed then
		-- A rejected callback loses authority before any later attempt can retry.
		receipt.close_attempt, receipt.state = nil, "open"
		request.operation.cleanup_error = "native handle close refused"
		return false
	end
	attempt.admitted = true
	if attempt.callback_seen and receipt.close_attempt == attempt and receipt.state == "closing" then
		receipt.state = "closed"
		settle(request)
	end
	return true
end





-- ======================================
-- ======================================
-- ======= 2/ Physical Retirement =======
-- ======================================
-- ======================================

local retry_cleanup

--- Probes native group absence; accepted SIGKILL is never this receipt.
--- @param request table
--- @return boolean
local function probe_group(request)
	if not request.spawned then request.group_absent = true return true end
	if type(request.pid) ~= "number" then return false end
	local ok, absent = Group.signal(native, request.pid, 0)
	if ok and absent then request.group_absent = true return true end
	if not ok then request.operation.cleanup_error = "native process group probe refused" end
	return false
end

--- Keeps group cleanup referenced while exit, absence or closure is pending.
--- @param request table
local function watch_cleanup(request)
	local handle = request.cleanup
	local receipt = handle and request.handles[handle]
	if not receipt or receipt.state ~= "open" or request.cleanup_watching then return end
	receipt.active = true
	request.cleanup_watching = true
	if not accepted(native.timer_start, handle, GROUP_RECHECK_MS, GROUP_RECHECK_MS, function()
		retry_cleanup(request)
	end) then
		request.cleanup_watching = false
		request.operation.cleanup_error = "native cleanup monitor refused"
		return
	end
end

--- Retries only this operation's retained native resources.
--- @param request table
retry_cleanup = function(request)
	if request.settled or not request.terminal or request.dispatching then return end
	if not request.group_absent and not probe_group(request) then
		if not request.termination_accepted then
			request.termination_accepted = Group.terminate(native, request.pid) == true
			if not request.termination_accepted then
				request.operation.cleanup_error = "native process group termination refused"
			end
		end
		watch_cleanup(request)
	end
	close_handle(request, request.stdin)
	close_handle(request, request.timeout)
	close_handle(request, request.stdout)
	close_handle(request, request.stderr)
	if request.exited then close_handle(request, request.process) end
	if request.group_absent and (not request.spawned or request.exited) then
		close_handle(request, request.cleanup)
	end
	settle(request)
end

--- Fences delivery immediately and defers completion to actual retirement.
--- @param request table
--- @param reason string|nil
local function finish(request, reason)
	if not request.terminal then
		request.terminal = true
		request.operation.result = {
			ok = reason == nil and request.exit_code == 0,
			exit_code = request.exit_code or -1,
			stdout = request.stdout_text,
			stderr = request.stderr_text,
			error = reason,
		}
	end
	if request.stdin_owner and not request.stdin_cancelled then
		request.stdin_cancelled = true -- Reserve before private worker reentry.
		pcall(request.stdin_owner.cancel, request.stdin_owner.source)
	end
	retry_cleanup(request)
end

--- Completes a normal child only after its output streams end.
--- @param request table
local function maybe_complete(request)
	if request.terminal or not request.exited or not request.stdout_eof or not request.stderr_eof then return end
	if not stdin_settled(request) then return end
	local reason = request.exit_code ~= 0 and "process exited unsuccessfully" or nil
	if request.stdin_owner then
		local called, result = pcall(request.stdin_owner.result, request.stdin_owner.source)
		if not called or type(result) ~= "table" or result.ok ~= true then reason = "native stdin feed failed" end
	end
	finish(request, reason)
end

--- Retires descendants even when they have closed both inherited streams.
--- @param request table
local function observe_exit(request)
	if not request.exited or request.dispatching then return end
	close_handle(request, request.process)
	if request.terminal then retry_cleanup(request) return end
	if not probe_group(request) then
		finish(request, "native process group outlived leader")
		return
	end
	maybe_complete(request)
end





-- ======================================
-- ======================================
-- ======= 3/ Owned Operation ===========
-- ======================================
-- ======================================

--- Starts a referenced native child and retains its exact cleanup operation.
--- A missing timeout explicitly permits a long-lived child. Group absence can
--- remain pending for unreaped descendant zombies; those remain honest debt.
--- @param executable string
--- @param args table Pure string argument vector.
--- @param options table { owner, timeout_ms?, max_output_bytes?, capture_tail?, authorized?, on_output?, env?, cwd? }.
--- @param callback function Called after physical settlement unless cancelled/stale.
--- @return table operation { started, error, cleanup_error, result, cancel, is_running, is_settled, on_settled }.
function M.start(executable, args, options, callback)
	options = type(options) == "table" and options or {}
	local request = {
		owner = options.owner, options = options, callback = callback,
		handles = {}, listeners = {}, stdout_text = "", stderr_text = "",
		stdout_eof = false, stderr_eof = false, spawned = false, exited = false,
		group_absent = false, settled = false, terminal = false, cancelled = false,
		dispatching = true,
	}
	local operation = { started = false }
	request.operation = operation
	function operation:is_settled() return request.settled end
	-- This is observed owned-native lifecycle, not future liveness or HTTP
	-- responder identity. Pending closure debt cannot masquerade as a service.
	local function held_running()
		local receipt = request.handles[request.process]
		return owners[request.owner] == operation and request.spawned and not request.dispatching
			and not request.exited and not request.terminal and not request.cancelled and not request.settled
			and type(request.pid) == "number" and request.pid > 0 and request.pid % 1 == 0
			and receipt ~= nil and receipt.kind == "process" and receipt.state == "open"
	end
	function operation:is_running()
		if not held_running() then return false end
		local admitted = authorized(request)
		return admitted and held_running()
	end
	function operation:on_settled(listener)
		if type(listener) ~= "function" then return false end
		if request.settled then
			local ok = pcall(listener)
			if not ok then Logger.error(LOG, "Owned process settlement callback failed.") end
		else request.listeners[#request.listeners + 1] = listener end
		return true
	end
	function operation:cancel()
		request.cancelled = true
		finish(request, "cancelled")
		return request.settled
	end
	local function refuse(reason)
		operation.error = reason
		request.dispatching = false
		finish(request, reason)
		return operation
	end
	if type(callback) ~= "function" then
		request.callback = function() end
		return refuse("a completion callback is required")
	end
	-- A raw private stdin PIPE transfers handle-close ownership only. No archive
	-- descriptor or publication pointer crosses this bridge. Capture original
	-- receiver/methods before any fallible source admission or native allocation.
	if options.stdin_owner ~= nil then
		local source = options.stdin_owner
		if type(source) ~= "table" then return refuse("invalid stdin owner") end
		local input = { source = source, handle = rawget(source, "handle") }
		if type(input.handle) ~= "userdata" then return refuse("native stdin pipe required") end
		for _, name in ipairs({ "cancel", "is_settled", "on_settled", "can_close", "result" }) do
			input[name] = rawget(source, name)
			if type(input[name]) ~= "function" then return refuse("invalid stdin owner methods") end
		end
		request.stdin_owner = input
		if not own_handle(request, input.handle, "stdin") then return refuse("stdin ownership capture refused") end
		local called, ack = pcall(input.on_settled, input.source, function()
			if request.stdin_owner ~= input or not stdin_settled(request) then return end
			local observed, result = pcall(input.result, input.source)
			if not observed or type(result) ~= "table" or result.ok ~= true then
				finish(request, "native stdin feed failed")
			elseif not request.dispatching then
				close_handle(request, request.stdin)
				maybe_complete(request)
			end
			if request.terminal then retry_cleanup(request) end
		end)
		if not called or ack ~= true then return refuse("stdin settlement subscription refused") end
		if request.terminal then return refuse("native stdin feed failed") end
	end
	if type(request.owner) ~= "string" or request.owner == "" then return refuse("a process owner is required") end
	local refusal = Shell.validate_spawn_args(executable, args)
	if refusal ~= "" then return refuse("argument vector refused: " .. refusal) end
	if options.timeout_ms ~= nil and (type(options.timeout_ms) ~= "number"
		or options.timeout_ms <= 0 or options.timeout_ms % 1 ~= 0) then return refuse("invalid process deadline") end
	local max_output = options.max_output_bytes or DEFAULT_MAX_OUTPUT_BYTES
	if type(max_output) ~= "number" or max_output <= 0 or max_output % 1 ~= 0 then return refuse("invalid output bound") end
	if options.authorized ~= nil and type(options.authorized) ~= "function" then return refuse("invalid source admission") end
	if options.on_output ~= nil and type(options.on_output) ~= "function" then return refuse("invalid output callback") end
	if options.capture_tail ~= nil and type(options.capture_tail) ~= "boolean" then return refuse("invalid output capture policy") end
	if options.cwd ~= nil and (type(options.cwd) ~= "string" or options.cwd:sub(1, 1) ~= "/"
		or options.cwd:find("\0", 1, true)) then return refuse("invalid process working directory") end
	if options.env ~= nil then
		if Shell.validate_spawn_args(executable, options.env) ~= "" then return refuse("invalid process environment") end
		for _, value in ipairs(options.env) do
			if not value:match("^[^=]+=") then return refuse("invalid process environment binding") end
		end
	end
	if not native then return refuse("native asynchronous process support is unavailable") end
	for _, name in ipairs({ "new_pipe", "new_timer", "spawn", "read_start", "read_stop", "timer_start",
		"timer_stop", "is_closing", "close", "kill" }) do
		if type(native[name]) ~= "function" then return refuse("native process capability is unavailable") end
	end
	if owners[request.owner] then return refuse("previous process cleanup pending") end
	if not authorized(request) then return refuse("process source admission refused") end
	-- Source admission can synchronously dispatch another exact operation.
	if owners[request.owner] then return refuse("previous process cleanup pending") end
	owners[request.owner] = operation
	for _, kind in ipairs({ "stdout", "stderr", "cleanup", "timeout" }) do
		if kind ~= "timeout" or options.timeout_ms ~= nil then
			local allocator = native.new_timer
			if kind == "stdout" or kind == "stderr" then allocator = native.new_pipe end
			local ok, handle = pcall(allocator, false)
			if not ok or not own_handle(request, handle, kind) then return refuse("native handle allocation failed") end
		end
	end
	-- The source can change while a fallible allocator invokes another owner.
	if not authorized(request) then return refuse("process source admission refused") end
	local spawned, process, pid = pcall(native.spawn, executable, {
		args = args, stdio = { request.stdin, request.stdout, request.stderr },
		detached = true, env = options.env, cwd = options.cwd,
	}, function(code, signal)
		request.exited = true
		request.exit_code = Exit.status(code, signal)
		if operation.result then operation.result.exit_code = request.exit_code end
		observe_exit(request)
	end)
	if not spawned or not process then return refuse("native process dispatch failed") end
	if not own_handle(request, process, "process") then return refuse("native process handle malformed") end
	request.spawned, request.pid = true, pid
	operation.started = true
	if type(pid) ~= "number" or pid < 1 or pid % 1 ~= 0 then return refuse("native process identity malformed") end
	if not authorized(request) then
		request.cancelled = true
		return refuse("process source admission refused")
	end
	for _, kind in ipairs({ "stdout", "stderr" }) do
		if request.terminal then break end
		local handle = request[kind]
		request.handles[handle].active = true
		local started = accepted(native.read_start, handle, function(err, chunk)
			if request.terminal then return end
			if not authorized(request) then request.cancelled = true finish(request, "process source admission refused") return end
			if err ~= nil then finish(request, "native output read failed") return end
			if chunk == nil then
				request[kind .. "_eof"] = true
				close_handle(request, handle)
				maybe_complete(request)
				return
			end
			if type(chunk) ~= "string" then finish(request, "native output receipt malformed") return end
			local key = kind .. "_text"
			if options.capture_tail == true then
				-- Long-lived daemon logs keep bounded diagnostics without eventually
				-- terminating a healthy service because of its total historical output.
				request[key] = (request[key] .. chunk):sub(-max_output)
			else
				if #request[key] + #chunk > max_output then finish(request, "process output exceeds its bound") return end
				request[key] = request[key] .. chunk
			end
			if options.on_output then
				local ok = pcall(options.on_output, chunk, kind)
				if not ok then finish(request, "process output callback failed") end
			end
		end)
		if not started then return refuse("native output watch refused") end
	end
	if request.timeout and not request.terminal then
		request.handles[request.timeout].active = true
		if not accepted(native.timer_start, request.timeout, options.timeout_ms, 0, function()
			finish(request, "process deadline exceeded")
		end) then return refuse("native process deadline refused") end
	end
	request.dispatching = false
	if request.stdin_owner and stdin_settled(request) then close_handle(request, request.stdin) end
	if request.terminal then retry_cleanup(request) else observe_exit(request) end
	return operation
end

return M
