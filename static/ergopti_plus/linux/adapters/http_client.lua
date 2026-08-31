--- adapters/http_client.lua

--- ==============================================================================
--- MODULE: HttpClient Adapter (Linux)
--- DESCRIPTION:
--- Owns asynchronous curl subprocesses for buffered and streaming HTTP POSTs.
--- The libuv process, pipes, timeout, cancellation, and terminal callback are
--- one transaction so network I/O never blocks the grabbed-keyboard loop.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local LOG = "adapters.http_client"

local ok_luv, luv = pcall(require, "luv")
if not ok_luv then luv = nil end


-- =========================================
-- =========================================
-- ======= 1/ Constants ====================
-- =========================================
-- =========================================

local DEFAULT_TIMEOUT_MS = 30000
local STATUS_MARKER = "ERGOPTI_HTTP_STATUS:"

M.HAS_ASYNC = luv ~= nil


-- =========================================
-- =========================================
-- ======= 2/ Request Ownership ============
-- =========================================
-- =========================================

local _active = nil

--- Closes a libuv handle once.
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

--- Stops and closes a request timer.
--- @param request table
local function close_timer(request)
	if not request.timer then return end
	pcall(luv.timer_stop, request.timer)
	close_handle(request.timer)
	request.timer = nil
end

--- Stops and closes one captured stream.
--- @param request table
--- @param field string
local function close_stream(request, field)
	local stream = request[field]
	if not stream then return end
	if type(luv.read_stop) == "function" then pcall(luv.read_stop, stream) end
	close_handle(stream)
	request[field] = nil
end

--- Closes the process handle after libuv has reported its exit.
--- @param request table
local function close_process(request)
	if not request.process or not request.exited then return end
	close_handle(request.process)
	request.process = nil
end

--- Publishes one terminal result and makes all stale callbacks inert.
--- @param request table
--- @param result table
--- @param suppress_callback boolean|nil
local function finish(request, result, suppress_callback)
	if request.terminal then return end
	request.terminal = true
	if _active == request then _active = nil end
	close_timer(request)
	close_stream(request, "stdout")
	close_stream(request, "stderr")
	close_process(request)
	if result.ok then
		Logger.debug(LOG, "HTTP request completed (status=%d).", result.status or 0)
	elseif result.error ~= "cancelled" then
		Logger.error(LOG, "HTTP request failed: %s.", tostring(result.error))
	end
	if not suppress_callback and type(request.on_done) == "function" then
		local ok, err = pcall(request.on_done, result)
		if not ok then Logger.error(LOG, "HTTP terminal callback raised: %s.", tostring(err)) end
	end
end

--- Sends a signal to the detached curl process group.
--- @param request table
--- @param signal string
--- @return boolean
local function signal_group(request, signal)
	if not luv or not request.pid or type(luv.kill) ~= "function" then return false end
	local ok, accepted = pcall(luv.kill, -request.pid, signal)
	return ok and accepted ~= nil and accepted ~= false
end

--- Terminates the entire owned curl process group.
--- @param request table
--- @return boolean
local function terminate_group(request)
	if request.exited then return true end
	local terminated = signal_group(request, "sigterm")
	if terminated then signal_group(request, "sigkill") end
	return terminated
end


-- =========================================
-- =========================================
-- ======= 3/ Curl Request =================
-- =========================================
-- =========================================

--- Builds shell-free curl arguments.
--- @param url string
--- @param headers table
--- @param body string
--- @param timeout_ms number
--- @param buffered boolean
--- @return table
local function curl_args(url, headers, body, timeout_ms, buffered)
	local args = {
		"--silent", "--show-error", "--no-buffer", "--fail-with-body",
		"--max-time", tostring(math.max(1, math.ceil(timeout_ms / 1000))),
		"--request", "POST",
	}
	local names = {}
	for name in pairs(headers) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		args[#args + 1] = "--header"
		args[#args + 1] = tostring(name) .. ": " .. tostring(headers[name])
	end
	args[#args + 1] = "--data-binary"
	args[#args + 1] = body
	if buffered then
		args[#args + 1] = "--write-out"
		args[#args + 1] = "\n" .. STATUS_MARKER .. "%{http_code}\n"
	end
	args[#args + 1] = url
	return args
end

--- Converts a completed buffered curl request to the port result envelope.
--- @param request table
--- @return table
local function buffered_result(request)
	local body, status_text = request.stdout_text:match(
		"^(.*)\n" .. STATUS_MARKER .. "(%d%d%d)\n?$")
	local status = tonumber(status_text)
	if request.exit_code ~= 0 and (not status or status == 0) then
		return {
			ok = false, status = 0, body = "",
			error = request.stderr_text ~= "" and request.stderr_text
				or "curl exited with code " .. tostring(request.exit_code),
		}
	end
	if not status then
		return { ok = false, status = 0, body = "", error = "missing HTTP status" }
	end
	local succeeded = status >= 200 and status < 300
	return {
		ok = succeeded,
		status = status,
		body = succeeded and body or "",
		error = succeeded and nil or "HTTP " .. tostring(status),
	}
end

--- Completes once both the process and its two output streams ended.
--- @param request table
local function maybe_complete(request)
	if request.terminal or not request.exited or not request.stdout_eof or not request.stderr_eof then
		return
	end
	if request.buffered then
		finish(request, buffered_result(request))
	elseif request.exit_code == 0 then
		finish(request, { ok = true, status = 200, body = "", error = nil })
	else
		finish(request, {
			ok = false, status = 0, body = "",
			error = request.stderr_text ~= "" and request.stderr_text
				or "curl exited with code " .. tostring(request.exit_code),
		})
	end
	close_process(request)
end

--- Starts one asynchronous curl process.
--- @param url string
--- @param headers table
--- @param body string
--- @param options table
--- @param on_chunk function|nil
--- @param on_done function
--- @return boolean
local function start_request(url, headers, body, options, on_chunk, on_done)
	local function reject(message)
		local result = { ok = false, status = 0, body = "", error = message }
		if type(on_done) == "function" then
			local ok, err = pcall(on_done, result)
			if not ok then Logger.error(LOG, "HTTP rejection callback raised: %s.", tostring(err)) end
		end
		return false
	end
	if _active and not M.cancel() then
		return reject("previous request cancellation failed")
	end
	if not luv or type(luv.spawn) ~= "function" then
		return reject("asynchronous HTTP unavailable")
	end

	local timeout_ms = tonumber(options.timeout_ms) or DEFAULT_TIMEOUT_MS
	local request = {
		buffered = options.buffered == true,
		on_chunk = on_chunk,
		on_done = on_done,
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
		finish(request, { ok = false, status = 0, body = "", error = "libuv handle allocation failed" })
		return false
	end

	local timer_ok, timer_result = pcall(luv.timer_start, request.timer, timeout_ms, 0, function()
		if request.terminal then return end
		terminate_group(request)
		finish(request, { ok = false, status = 0, body = "", error = "timeout" })
	end)
	if not timer_ok or timer_result == false or timer_result == nil then
		finish(request, { ok = false, status = 0, body = "", error = "timeout activation failed" })
		return false
	end

	local spawn_ok, process, pid, spawn_error = pcall(luv.spawn, "curl", {
		args = curl_args(url, headers, body, timeout_ms, request.buffered),
		stdio = { nil, request.stdout, request.stderr },
		detached = true,
	}, function(code, signal)
		request.exited = true
		request.exit_code = tonumber(code) or -1
		request.exit_signal = signal
		maybe_complete(request)
		close_process(request)
	end)
	if not spawn_ok or not process or not pid then
		finish(request, {
			ok = false, status = 0, body = "",
			error = "curl spawn failed: " .. tostring(spawn_error or pid or process),
		})
		return false
	end
	request.process = process
	request.pid = pid

	local stdout_ok, stdout_result = pcall(luv.read_start, request.stdout, function(err, chunk)
		if request.terminal then return end
		if err then
			terminate_group(request)
			finish(request, { ok = false, status = 0, body = "", error = tostring(err) })
		elseif chunk == nil then
			request.stdout_eof = true
			maybe_complete(request)
		elseif request.buffered then
			request.stdout_text = request.stdout_text .. chunk
		elseif type(request.on_chunk) == "function" then
			local ok, callback_err = pcall(request.on_chunk, chunk)
			if not ok then Logger.error(LOG, "HTTP chunk callback raised: %s.", tostring(callback_err)) end
		end
	end)
	local stderr_ok, stderr_result = pcall(luv.read_start, request.stderr, function(err, chunk)
		if request.terminal then return end
		if err then
			terminate_group(request)
			finish(request, { ok = false, status = 0, body = "", error = tostring(err) })
		elseif chunk == nil then
			request.stderr_eof = true
			maybe_complete(request)
		else
			request.stderr_text = request.stderr_text .. chunk
		end
	end)
	if not stdout_ok or stdout_result == false or stdout_result == nil
		or not stderr_ok or stderr_result == false or stderr_result == nil then
		terminate_group(request)
		finish(request, { ok = false, status = 0, body = "", error = "pipe activation failed" })
		return false
	end

	_active = request
	Logger.debug(LOG, "HTTP request dispatched asynchronously (pid=%d).", pid)
	return true
end


-- =========================================
-- =========================================
-- ======= 4/ Adapter Methods ==============
-- =========================================
-- =========================================

--- Sends a buffered HTTP POST required by the shared HttpClient port.
--- @param url string
--- @param headers table
--- @param body string
--- @param callback function
function M.post(url, headers, body, callback)
	start_request(url, type(headers) == "table" and headers or {},
		type(body) == "string" and body or "", { buffered = true }, nil, callback)
end

--- Sends a streaming HTTP POST without blocking the event loop.
--- @param url string
--- @param headers table
--- @param body string
--- @param options table { timeout_ms? }
--- @param on_chunk function Called with raw response chunks.
--- @param on_done function Called once with the result envelope.
--- @return boolean Whether the asynchronous request was dispatched.
function M.postStream(url, headers, body, options, on_chunk, on_done)
	return start_request(url, type(headers) == "table" and headers or {},
		type(body) == "string" and body or "", type(options) == "table" and options or {},
		on_chunk, on_done)
end

--- Cancels the active request without invoking the port callback.
--- @return boolean Whether the owned process group accepted termination.
function M.cancel()
	if not _active then return true end
	local request = _active
	if not terminate_group(request) then
		Logger.error(LOG, "HTTP cancellation failed for pid=%s; ownership retained.",
			tostring(request.pid))
		return false
	end
	finish(request, { ok = false, status = 0, body = "", error = "cancelled" }, true)
	return true
end

--- Returns true while a request owns a live curl process.
--- @return boolean
function M.isActive()
	return _active ~= nil
end

return M
