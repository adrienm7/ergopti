--- adapters/file_digest.lua

--- ==============================================================================
--- MODULE: Asynchronous File Digest Adapter (Linux)
--- DESCRIPTION:
--- Computes SHA-256 for a file in a shell-free sha256sum subprocess owned by
--- libuv. Large release archives never enter Lua memory and hashing never blocks
--- the keyboard event-loop thread.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local LOG = "adapters.file_digest"

local ok_luv, luv = pcall(require, "luv")
if not ok_luv then luv = nil end


-- =========================================
-- =========================================
-- ======= 1/ Constants & State ============
-- =========================================
-- =========================================

local DEFAULT_TIMEOUT_MS = 30000
local MAX_OUTPUT_BYTES = 1024

local _active = nil

M.HAS_ASYNC = luv ~= nil


-- =========================================
-- =========================================
-- ======= 2/ Lifecycle ====================
-- =========================================
-- =========================================

--- Closes one libuv handle at most once.
--- @param handle any
local function close_handle(handle)
	if not handle or not luv then return end
	local closing = false
	if type(luv.is_closing) == "function" then
		local ok, value = pcall(luv.is_closing, handle)
		closing = ok and value == true
	end
	if not closing then pcall(luv.close, handle) end
end

--- Releases completed process ownership.
--- @param request table
local function close_process(request)
	if not request.process or not request.exited then return end
	close_handle(request.process)
	request.process = nil
end

--- Releases one captured stream.
--- @param request table
--- @param field string
local function close_stream(request, field)
	local stream = request[field]
	if not stream then return end
	if type(luv.read_stop) == "function" then pcall(luv.read_stop, stream) end
	close_handle(stream)
	request[field] = nil
end

--- Releases the deadline timer.
--- @param request table
local function close_timer(request)
	if not request.timer then return end
	pcall(luv.timer_stop, request.timer)
	close_handle(request.timer)
	request.timer = nil
end

--- Sends a signal to the detached sha256sum process group.
--- @param request table
--- @param signal string
--- @return boolean
local function signal_group(request, signal)
	if not luv or not request.pid or type(luv.kill) ~= "function" then return false end
	local ok, accepted = pcall(luv.kill, -request.pid, signal)
	return ok and accepted ~= nil and accepted ~= false
end

--- Terminates the entire owned process group.
--- @param request table
--- @return boolean
local function terminate_group(request)
	if request.exited then return true end
	local terminated = signal_group(request, "sigterm")
	if terminated then signal_group(request, "sigkill") end
	return terminated
end

--- Publishes one terminal result and makes every late callback inert.
--- @param request table
--- @param digest string|nil
--- @param err string|nil
--- @param suppress_callback boolean|nil
local function finish(request, digest, err, suppress_callback)
	if request.terminal then return end
	request.terminal = true
	if _active == request then _active = nil end
	close_timer(request)
	close_stream(request, "stdout")
	close_stream(request, "stderr")
	close_process(request)
	if err and err ~= "cancelled" then
		Logger.error(LOG, "SHA-256 file digest failed: %s.", tostring(err))
	end
	if not suppress_callback and type(request.callback) == "function" then
		local ok, callback_error = pcall(request.callback, digest, err)
		if not ok then Logger.error(LOG, "Digest callback raised: %s.", tostring(callback_error)) end
	end
end


-- =========================================
-- =========================================
-- ======= 3/ Completion ===================
-- =========================================
-- =========================================

--- Completes once the child and both streams have ended.
--- @param request table
local function maybe_complete(request)
	if request.terminal or not request.exited or not request.stdout_eof or not request.stderr_eof then
		return
	end
	if request.exit_code ~= 0 then
		finish(request, nil, request.stderr_text ~= "" and request.stderr_text
			or "sha256sum exited with code " .. tostring(request.exit_code))
		close_process(request)
		return
	end
	local digest = request.stdout_text:match("^([0-9a-fA-F]+)%s+[%* ]")
	if not digest or #digest ~= 64 then
		finish(request, nil, "invalid sha256sum output")
	else
		finish(request, digest:lower(), nil)
	end
	close_process(request)
end


-- =========================================
-- =========================================
-- ======= 4/ Public API ===================
-- =========================================
-- =========================================

--- Computes one file's SHA-256 asynchronously.
--- @param path string Absolute file path.
--- @param options table|nil { timeout_ms? }
--- @param callback function Receives digest, error exactly once.
--- @return boolean Whether hashing was dispatched.
function M.sha256(path, options, callback)
	local function reject(message)
		if type(callback) == "function" then callback(nil, message) end
		return false
	end
	if type(path) ~= "string" or path:sub(1, 1) ~= "/" then return reject("invalid digest path") end
	if _active and not M.cancel() then return reject("previous digest cancellation failed") end
	if not luv or type(luv.spawn) ~= "function" then return reject("asynchronous digest unavailable") end

	local request_options = type(options) == "table" and options or {}
	local timeout_ms = tonumber(request_options.timeout_ms) or DEFAULT_TIMEOUT_MS
	local request = {
		callback = callback,
		stdout_text = "",
		stderr_text = "",
		stdout_eof = false,
		stderr_eof = false,
		exited = false,
		terminal = false,
	}
	local handles_ok, stdout, stderr, timer = pcall(function()
		return luv.new_pipe(false), luv.new_pipe(false), luv.new_timer()
	end)
	request.stdout, request.stderr, request.timer = stdout, stderr, timer
	if not handles_ok or not request.stdout or not request.stderr or not request.timer then
		finish(request, nil, "libuv handle allocation failed")
		return false
	end
	local timer_ok, timer_result = pcall(luv.timer_start, request.timer, timeout_ms, 0, function()
		if request.terminal then return end
		terminate_group(request)
		finish(request, nil, "timeout")
	end)
	if not timer_ok or timer_result == false or timer_result == nil then
		finish(request, nil, "timeout activation failed")
		return false
	end

	local spawn_ok, process, pid, spawn_error = pcall(luv.spawn, "sha256sum", {
		args = { "--binary", "--zero", "--", path },
		stdio = { nil, request.stdout, request.stderr },
		detached = true,
	}, function(code)
		request.exited = true
		request.exit_code = tonumber(code) or -1
		maybe_complete(request)
		close_process(request)
	end)
	if not spawn_ok or not process or not pid then
		finish(request, nil, "sha256sum spawn failed: " .. tostring(spawn_error or pid or process))
		return false
	end
	request.process = process
	request.pid = pid

	local function consume(field, eof_field, err, chunk)
		if request.terminal then return end
		if err then
			terminate_group(request)
			finish(request, nil, tostring(err))
		elseif chunk == nil then
			request[eof_field] = true
			maybe_complete(request)
		elseif #request[field] + #chunk > MAX_OUTPUT_BYTES then
			terminate_group(request)
			finish(request, nil, "sha256sum output exceeds limit")
		else
			request[field] = request[field] .. chunk
		end
	end
	local stdout_ok, stdout_result = pcall(luv.read_start, request.stdout, function(err, chunk)
		consume("stdout_text", "stdout_eof", err, chunk)
	end)
	local stderr_ok, stderr_result = pcall(luv.read_start, request.stderr, function(err, chunk)
		consume("stderr_text", "stderr_eof", err, chunk)
	end)
	if not stdout_ok or stdout_result == false or stdout_result == nil
		or not stderr_ok or stderr_result == false or stderr_result == nil then
		terminate_group(request)
		finish(request, nil, "pipe activation failed")
		return false
	end

	_active = request
	Logger.debug(LOG, "SHA-256 file digest dispatched asynchronously (pid=%d).", pid)
	return true
end

--- Cancels the active digest without publishing its callback.
--- @return boolean
function M.cancel()
	if not _active then return true end
	local request = _active
	if not terminate_group(request) then
		Logger.error(LOG, "Digest cancellation failed for pid=%s; ownership retained.",
			tostring(request.pid))
		return false
	end
	finish(request, nil, "cancelled", true)
	return true
end

--- Returns true while one file owns a live digest process.
--- @return boolean
function M.isActive()
	return _active ~= nil
end

return M
