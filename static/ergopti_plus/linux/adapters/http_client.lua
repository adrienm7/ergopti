--- adapters/http_client.lua

--- ==============================================================================
--- MODULE: HttpClient Adapter (Linux)
--- DESCRIPTION:
--- Owns asynchronous curl subprocesses for buffered GET and POST requests and
--- streaming HTTP POSTs.
--- The libuv process, pipes, timeout, cancellation, and terminal callback are
--- one transaction so network I/O never blocks the grabbed-keyboard loop.
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local ShellRunner = require("adapters.shell_runner")
local LibuvExit = require("infra.libuv_exit")
local ProcessGroup = require("infra.libuv_process_group")
local RedirectPolicy = require("infra.http_redirect_policy")
local HeaderPolicy = require("infra.http_header_policy")
local TransportPolicy = require("infra.http_transport_policy")
local LOG = "adapters.http_client"

local ok_luv, luv = pcall(require, "luv")
if not ok_luv then luv = nil end


-- =========================================
-- =========================================
-- ======= 1/ Constants ====================
-- =========================================
-- =========================================

local DEFAULT_TIMEOUT_MS = 30000
local DEFAULT_OWNER = "default"
local MAX_DIAGNOSTIC_BYTES = 65536
local STATUS_MARKER = "ERGOPTI_HTTP_STATUS:"

M.HAS_ASYNC = luv ~= nil


-- =========================================
-- =========================================
-- ======= 2/ Request Ownership ============
-- =========================================
-- =========================================

local _active = {}
-- Logical activity preserves the historical boolean port. Owned requests retain
-- a separate exact operation until process exit AND every native close callback.
local _owned = {}
local settle_owned
local retry_owned_cleanup

--- Resolves a stable request owner without allowing an empty table key.
--- @param owner any
--- @return string
local function request_owner(owner)
	return type(owner) == "string" and owner ~= "" and owner or DEFAULT_OWNER
end

--- Closes a libuv handle once.
--- @param handle any
local function close_handle(handle, request)
	if not handle or not luv then return false end
	if request and request.operation then
		local receipt = request.handles[handle]
		if not receipt then return false end
		if receipt.state == "closed" or receipt.state == "closing" then return true end
		local ok_closing, closing = pcall(luv.is_closing, handle)
		-- Another actor's scheduled close is not our closure acknowledgment.
		if not ok_closing or closing then return false end
		receipt.state = "closing"
		local ok, accepted, err = pcall(luv.close, handle, function()
			receipt.state = "closed"
			settle_owned(request)
		end)
		if not ok or accepted == false or err ~= nil then
			if receipt.state ~= "closed" then receipt.state = "open" end
			return false
		end
		return true
	end
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
	if close_handle(request.timer, request) or not request.operation then request.timer = nil end
end

--- Stops and closes one captured stream.
--- @param request table
--- @param field string
local function close_stream(request, field)
	local stream = request[field]
	if not stream then return end
	if type(luv.read_stop) == "function" then pcall(luv.read_stop, stream) end
	if close_handle(stream, request) or not request.operation then request[field] = nil end
end

--- Closes the process handle after libuv has reported its exit.
--- @param request table
local function close_process(request)
	if not request.process or not request.exited then return end
	if close_handle(request.process, request) or not request.operation then request.process = nil end
end

--- Releases an owned operation only after physical exit and native close ACKs.
--- @param request table
settle_owned = function(request)
	local operation = request.operation
	if not operation or operation._settled or not request.terminal then return end
	if request.spawned and not request.exited then return end
	for _, receipt in pairs(request.handles) do
		if receipt.state ~= "closed" then return end
	end
	operation._settled = true
	if _owned[request.owner] == operation then _owned[request.owner] = nil end
	local result = request.result
	if not operation._cancelled and not request.suppress_callback and type(request.on_done) == "function" then
		local ok, err = pcall(request.on_done, result)
		if not ok then Logger.error(LOG, "Owned HTTP terminal callback raised: %s.", tostring(err)) end
	end
	local listeners = operation._listeners
	operation._listeners = {}
	for _, listener in ipairs(listeners) do
		local ok, err = pcall(listener)
		if not ok then Logger.error(LOG, "Owned HTTP settlement callback raised: %s.", tostring(err)) end
	end
end

--- Retries only this request's exact native handles after a close refusal.
--- @param request table
retry_owned_cleanup = function(request)
	close_timer(request)
	close_stream(request, "stdin")
	close_stream(request, "stdout")
	close_stream(request, "stderr")
	close_process(request)
	settle_owned(request)
end

--- Publishes one terminal result and makes all stale callbacks inert.
--- @param request table
--- @param result table
--- @param suppress_callback boolean|nil
local function finish(request, result, suppress_callback)
	if request.terminal then return end
	request.terminal = true
	request.result = result
	request.suppress_callback = suppress_callback == true
	if _active[request.owner] == request then _active[request.owner] = nil end
	close_timer(request)
	close_stream(request, "stdin")
	close_stream(request, "stdout")
	close_stream(request, "stderr")
	close_process(request)
	if result.ok then
		Logger.debug(LOG, "HTTP request completed (status=%d).", result.status or 0)
	elseif result.error ~= "cancelled" then
		Logger.error(LOG, "HTTP request failed: %s.", tostring(result.error))
	end
	if request.operation then
		settle_owned(request)
		return
	end
	if not suppress_callback and type(request.on_done) == "function" then
		local ok, err = pcall(request.on_done, result)
		if not ok then Logger.error(LOG, "HTTP terminal callback raised: %s.", tostring(err)) end
	end
end

--- Terminates the entire owned curl process group.
--- @param request table
--- @return boolean
local function terminate_group(request)
	return ProcessGroup.terminate(luv, request.pid)
end


-- =========================================
-- =========================================
-- ======= 3/ Curl Request =================
-- =========================================
-- =========================================

--- Quotes one value for a curl config file, escaping what its parser reads
--- inside quotes: backslash, double quote, and the control escapes.
--- @param value string
--- @return string
local function config_quote(value)
	local escaped = value:gsub('[\\"]', "\\%0"):gsub("\n", "\\n"):gsub("\r", "\\r")
		:gsub("\t", "\\t"):gsub("\v", "\\v")
	return '"' .. escaped .. '"'
end

--- Builds shell-free curl arguments and the config curl reads from stdin.
--- @param url string
--- @param headers table
--- @param body string|nil
--- @param options table
--- @return table
local function curl_args(url, headers, body, options)
	local timeout_ms = options.timeout_ms
	local args = {
		-- Curl only ignores personal config when this is its first argument.
		-- Inherited location/insecure/output can otherwise override our policy.
		"--disable",
		"--silent", "--show-error", "--no-buffer", "--fail-with-body",
		"--max-time", tostring(math.max(1, math.ceil(timeout_ms / 1000))),
		"--request", options.method,
		"--proto", options.protocols,
	}
	if options.follow_redirects then
		args[#args + 1] = "--location"
		-- An HTTPS caller keeps TLS on every native-followed hop even without
		-- the updater's separate https_only constraint on the initial request.
		if options.https_only or url:lower():match("^https://") then
			args[#args + 1] = "--proto-redir"
			args[#args + 1] = "=https"
		end
	end
	if options.https_only then
		args[#args + 1] = "--tlsv1.2"
	end
	if options.etag_compare then
		args[#args + 1] = "--etag-compare"
		args[#args + 1] = options.etag_compare
	end
	if options.etag_save then
		args[#args + 1] = "--etag-save"
		args[#args + 1] = options.etag_save
	end
	if options.output_path then
		args[#args + 1] = "--output"
		args[#args + 1] = options.output_path
	end
	if options.max_download_bytes then
		args[#args + 1] = "--max-filesize"
		args[#args + 1] = tostring(options.max_download_bytes)
	end
	args[#args + 1] = "--write-out"
	-- Streaming bodies go directly to NDJSON consumers. Curl's stderr channel
	-- carries the receipt separately, so split status markers are never data.
	args[#args + 1] = (options.buffered and "" or "%{stderr}")
		.. "\n" .. STATUS_MARKER .. "%{http_code}\n"
	-- Headers, body and URL go through a config read from stdin. On the command
	-- line they were readable by every local process through /proc/<pid>/cmdline:
	-- an API key in a header or a Gemini URL, and the typed text in the body.
	args[#args + 1] = "--config"
	args[#args + 1] = "-"
	local lines = {}
	local names = {}
	for name in pairs(headers) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		local header_name, header_value = tostring(name), tostring(headers[name])
		local allowed, err = HeaderPolicy.validate(header_name, header_value)
		if not allowed then error(err) end
		lines[#lines + 1] = "header = " .. config_quote(header_name .. ": " .. header_value)
	end
	-- The port body is literal caller text. data-binary treats leading @ as a
	-- filename (or stdin), even inside a quoted config value.
	if body ~= nil then lines[#lines + 1] = "data-raw = " .. config_quote(body) end
	lines[#lines + 1] = "url = " .. config_quote(url)
	return args, table.concat(lines, "\n") .. "\n"
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
	local http_success = status >= 200 and status < 300
	local succeeded = http_success and request.exit_code == 0
	local failure
	if not http_success then
		failure = "HTTP " .. tostring(status)
	elseif not succeeded then
		failure = request.stderr_text ~= "" and request.stderr_text
			or "curl exited with code " .. tostring(request.exit_code)
	end
	return {
		ok = succeeded,
		status = status,
		body = succeeded and body or "",
		-- A refused request explains itself in its body ("invalid API key").
		error_body = not http_success and body or nil,
		error = failure,
	}
end

--- Converts a completed stream without treating curl exit or stderr as HTTP status.
--- @param request table
--- @return table
local function streaming_result(request)
	local status = tonumber(request.stderr_tail:match("\n" .. STATUS_MARKER .. "(%d%d%d)\n?$"))
	local diagnostic = request.stderr_text:gsub("\n" .. STATUS_MARKER .. "%d%d%d\n?$", "")
	if not status or status == 0 then
		return { ok = false, status = 0, body = "", error = diagnostic ~= "" and diagnostic
			or (request.exit_code ~= 0 and "curl exited with code " .. tostring(request.exit_code)
				or "missing HTTP status") }
	end
	local http_success = status >= 200 and status < 300
	local succeeded = http_success and request.exit_code == 0
	local failure
	if not http_success then
		failure = "HTTP " .. tostring(status)
	elseif not succeeded then
		failure = diagnostic ~= "" and diagnostic or "curl exited with code " .. tostring(request.exit_code)
	end
	return {
		ok = succeeded, status = status, body = "",
		error_body = not http_success and not request.error_body_truncated and request.error_body_text or nil,
		error = failure,
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
	else
		finish(request, streaming_result(request))
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
local function start_request(url, headers, body, options, on_chunk, on_done, operation)
	local function reject(message)
		if operation then operation._settled = true end
		local result = { ok = false, status = 0, body = "", error = message }
		if type(on_done) == "function" then
			local ok, err = pcall(on_done, result)
			if not ok then Logger.error(LOG, "HTTP rejection callback raised: %s.", tostring(err)) end
		end
		return false
	end
	if type(url) ~= "string" or url == "" then return reject("curl URL must be a non-empty string") end
	-- Curl reads the URL from a C-string config value. NUL silently selects a
	-- shorter address, so refuse before native side effects or owner replacement.
	if url:find("\0", 1, true) then
		Logger.error(LOG, "Cannot compose curl configuration: request URL contains NUL.")
		return reject("curl config URL cannot contain NUL")
	end
	local protocols, transport_error = TransportPolicy.resolve(url, options.https_only == true)
	if not protocols then return reject(transport_error) end
	if options.follow_redirects then
		local allowed, err = RedirectPolicy.allows_native_follow(headers)
		if allowed == nil then
			Logger.error(LOG, "%s.", err)
			return reject(err)
		end
		-- Curl protects Authorization but forwards custom API-key headers.
		-- Keep the original request and its HTTP receipt; refuse native follow
		-- until the adapter owns and filters every redirect hop explicitly.
		options.follow_redirects = allowed
	end
	local timeout_ms = tonumber(options.timeout_ms) or DEFAULT_TIMEOUT_MS
	local request_options = {
		protocols = protocols,
		buffered = options.buffered == true,
		method = options.method or "POST",
		timeout_ms = timeout_ms,
		follow_redirects = options.follow_redirects == true,
		https_only = options.https_only == true,
		etag_compare = options.etag_compare,
		etag_save = options.etag_save,
		output_path = options.output_path,
		max_download_bytes = options.max_download_bytes,
	}
	-- Metadata refusal is transactional too: an invalid replacement must not
	-- retire a valid owner or leave timers/pipes behind after composition raises.
	local composed, argv, config
	if not operation then
		composed, argv, config = pcall(curl_args, url, headers, body, request_options)
		if not composed then
			Logger.error(LOG, "Cannot compose curl configuration; request refused.")
			return reject("curl configuration refused")
		end
		local argv_refusal = ShellRunner.validate_spawn_args("curl", argv)
		if argv_refusal ~= "" then return reject("curl argument vector refused: " .. argv_refusal) end
	end
	local owner = request_owner(options.owner)
	if _owned[owner] then return reject("previous request cleanup pending") end
	if _active[owner] and not M.cancel(owner) then
		return reject("previous request cancellation failed")
	end
	if not luv or type(luv.spawn) ~= "function" then
		return reject("asynchronous HTTP unavailable")
	end

	local request = {
		owner = owner,
		operation = operation,
		handles = {},
		spawned = false,
		buffered = options.buffered == true,
		max_body_bytes = tonumber(options.max_body_bytes),
		on_chunk = on_chunk,
		on_done = on_done,
		stdout_text = "",
		stderr_text = "",
		stderr_tail = "",
		error_body_text = "",
		error_body_truncated = false,
		stdout_eof = false,
		stderr_eof = false,
		exited = false,
		terminal = false,
	}
	local handles_ok
	if operation then
		operation._request = request
		_owned[owner] = operation
		-- Capture each allocation immediately: a later constructor throw must not
		-- discard earlier handles or turn cleanup debt into a settled refusal.
		handles_ok = pcall(function()
			for _, field in ipairs({ "stdin", "stdout", "stderr", "timer" }) do
				local handle
				if field == "timer" then handle = luv.new_timer() else handle = luv.new_pipe(false) end
				if not handle then error("native handle allocation refused") end
				request[field] = handle
				request.handles[handle] = { state = "open" }
			end
		end)
	else
		local stdin, stdout, stderr, timer
		handles_ok, stdin, stdout, stderr, timer = pcall(function()
			return luv.new_pipe(false), luv.new_pipe(false), luv.new_pipe(false), luv.new_timer()
		end)
		request.stdin, request.stdout, request.stderr, request.timer = stdin, stdout, stderr, timer
	end
	if not handles_ok or not request.stdin or not request.stdout or not request.stderr or not request.timer then
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

	-- Owned requests retain the new cleanup contract when construction raises
	-- after allocation; ordinary replacements complete preflight beforehand.
	if operation then
		local built
		built, argv, config = pcall(curl_args, url, headers, body, request_options)
		if not built then
			finish(request, { ok = false, status = 0, body = "", error = "curl request construction failed" })
			return false
		end
		local owned_refusal = ShellRunner.validate_spawn_args("curl", argv)
		if owned_refusal ~= "" then
			finish(request, { ok = false, status = 0, body = "", error = "curl argument vector refused: " .. owned_refusal })
			return false
		end
	end
	local spawn_ok, process, pid, spawn_error = pcall(luv.spawn, "curl", {
		args = argv,
		stdio = { request.stdin, request.stdout, request.stderr },
		detached = true,
	}, function(code, signal)
		request.exited = true
		request.exit_code = LibuvExit.status(code, signal)
		request.exit_signal = signal
		maybe_complete(request)
		close_process(request)
		settle_owned(request)
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
	request.spawned = true
	if operation then request.handles[process] = { state = "open" } end

	local write_ok, write_result = pcall(luv.write, request.stdin, config, function(write_err)
		if write_err and not request.terminal then
			terminate_group(request)
			finish(request, { ok = false, status = 0, body = "", error = "curl config write failed: " .. tostring(write_err) })
			return
		end
		close_stream(request, "stdin")
	end)
	if not write_ok or write_result == false or write_result == nil then
		terminate_group(request)
		finish(request, { ok = false, status = 0, body = "", error = "curl config write failed" })
		return false
	end

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
			if request.max_body_bytes
				and #request.stdout_text > request.max_body_bytes + #STATUS_MARKER + 16 then
				terminate_group(request)
				finish(request, {
					ok = false, status = 0, body = "", error = "response body exceeds limit",
				})
			end
		else
			-- Status is known only at curl completion. Keep a bounded body prefix
			-- for refused HTTP receipts independently of the caller's parser.
			local remaining = MAX_DIAGNOSTIC_BYTES - #request.error_body_text
			-- A prefix can itself be valid JSON while discarded trailing bytes
			-- invalidate the complete response. Never publish it as evidence.
			if #chunk > remaining then request.error_body_truncated = true end
			if remaining > 0 then request.error_body_text = request.error_body_text .. chunk:sub(1, remaining) end
			if type(request.on_chunk) == "function" then
				local ok, callback_err = pcall(request.on_chunk, chunk)
				if not ok then Logger.error(LOG, "HTTP chunk callback raised: %s.", tostring(callback_err)) end
			end
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
			-- Preserve the receipt's final bytes even when preceding diagnostics
			-- exhaust their budget; stderr can split at every marker boundary.
			request.stderr_tail = (request.stderr_tail .. chunk):sub(-(#STATUS_MARKER + 16))
			local remaining = MAX_DIAGNOSTIC_BYTES - #request.stderr_text
			if remaining > 0 then request.stderr_text = request.stderr_text .. chunk:sub(1, remaining) end
		end
	end)
	if not stdout_ok or stdout_result == false or stdout_result == nil
		or not stderr_ok or stderr_result == false or stderr_result == nil then
		terminate_group(request)
		finish(request, { ok = false, status = 0, body = "", error = "pipe activation failed" })
		return false
	end

	_active[owner] = request
	Logger.debug(LOG, "HTTP request dispatched asynchronously (owner=%s, pid=%d).", owner, pid)
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
--- @param options table|nil { timeout_ms?, owner?, max_body_bytes? }
function M.post(url, headers, body, callback, options)
	local request_options = {}
	if type(options) == "table" then
		for key, value in pairs(options) do request_options[key] = value end
	end
	request_options.buffered = true
	request_options.method = "POST"
	return start_request(url, type(headers) == "table" and headers or {},
		type(body) == "string" and body or "", request_options, nil, callback)
end

--- Sends a bounded buffered HTTP GET without blocking the event loop.
--- @param url string
--- @param headers table
--- @param options table|nil { timeout_ms?, max_body_bytes?, owner?, follow_redirects?, https_only?, etag_compare?, etag_save? }
--- @param callback function
--- @return boolean Whether the asynchronous request was dispatched.
function M.get(url, headers, options, callback)
	local request_options = {}
	if type(options) == "table" then
		for key, value in pairs(options) do request_options[key] = value end
	end
	request_options.buffered = true
	request_options.method = "GET"
	return start_request(url, type(headers) == "table" and headers or {}, nil,
		request_options, nil, callback)
end

--- Starts a buffered GET with retained physical cleanup ownership.
--- The existing get/cancel booleans remain logical dispatch/signal receipts.
--- This optional operation supplies the stronger contract needed by discovery:
--- cancellation fences delivery immediately, while successors wait for actual
--- process exit and all owned native handle close callbacks.
--- @param url string
--- @param headers table
--- @param options table|nil
--- @param callback function
--- @return table Operation { started, cancel, is_settled, on_settled }.
function M.get_owned(url, headers, options, callback)
	local operation = { started = false, _settled = false, _cancelled = false, _listeners = {} }
	function operation:is_settled() return self._settled end
	function operation:on_settled(listener)
		if type(listener) ~= "function" then return false end
		if self._settled then
			local ok, err = pcall(listener)
			if not ok then Logger.error(LOG, "Owned HTTP settlement callback raised: %s.", tostring(err)) end
		else
			self._listeners[#self._listeners + 1] = listener
		end
		return true
	end
	function operation:cancel()
		self._cancelled = true
		if self._settled then return true end
		local request = self._request
		if not request then return false end
		if not request.terminal then
			if not terminate_group(request) then return false end
			finish(request, { ok = false, status = 0, body = "", error = "cancelled" }, true)
		else
			if request.spawned and not request.exited and not terminate_group(request) then return false end
			retry_owned_cleanup(request)
		end
		return self._settled
	end
	local request_options = {}
	if type(options) == "table" then
		for key, value in pairs(options) do request_options[key] = value end
	end
	request_options.buffered = true
	request_options.method = "GET"
	operation.started = start_request(url, type(headers) == "table" and headers or {}, nil,
		request_options, nil, callback, operation)
	return operation
end

--- Downloads one response body directly to a caller-owned temporary file.
--- @param url string
--- @param headers table
--- @param destination string Absolute destination path.
--- @param options table|nil { timeout_ms?, max_download_bytes?, owner?, https_only? }
--- @param callback function
--- @return boolean Whether the asynchronous request was dispatched.
function M.download(url, headers, destination, options, callback)
	if type(destination) ~= "string" or destination:sub(1, 1) ~= "/" then
		if type(callback) == "function" then
			callback({ ok = false, status = 0, body = "", error = "invalid download path" })
		end
		return false
	end
	local request_options = {}
	if type(options) == "table" then
		for key, value in pairs(options) do request_options[key] = value end
	end
	request_options.buffered = true
	request_options.method = "GET"
	request_options.follow_redirects = true
	request_options.output_path = destination
	return start_request(url, type(headers) == "table" and headers or {}, nil,
		request_options, nil, callback)
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
	local request_options = {}
	if type(options) == "table" then
		for key, value in pairs(options) do request_options[key] = value end
	end
	request_options.method = "POST"
	return start_request(url, type(headers) == "table" and headers or {},
		type(body) == "string" and body or "", request_options,
		on_chunk, on_done)
end

--- Cancels the active request without invoking the port callback.
--- @param owner string|nil Request owner; defaults to the canonical port owner.
--- @return boolean Whether the owned process group accepted termination.
function M.cancel(owner)
	local key = request_owner(owner)
	if not _active[key] then return true end
	local request = _active[key]
	if not terminate_group(request) then
		Logger.error(LOG, "HTTP cancellation failed for pid=%s; ownership retained.",
			tostring(request.pid))
		return false
	end
	finish(request, { ok = false, status = 0, body = "", error = "cancelled" }, true)
	return true
end

--- Returns true while a request owns a live curl process.
--- @param owner string|nil Request owner; defaults to the canonical port owner.
--- @return boolean
function M.isActive(owner)
	return _active[request_owner(owner)] ~= nil
end

return M
