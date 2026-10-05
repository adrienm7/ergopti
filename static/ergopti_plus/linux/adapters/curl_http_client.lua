--- adapters/curl_http_client.lua

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
local BodyPipe = require("infra.http_body_pipe")
local NativeTimer = require("infra.native_timer")
local ExactIdentity = require("infra.curl_identity")
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
local PROXY_MARKER = "ERGOPTI_PROXY_STATUS:"
local NATIVE_TRAILER_BYTES = #STATUS_MARKER + #PROXY_MARKER + 32
local MAX_SAFE_INTEGER = 9007199254740991

--- Exposes the existing native default to the private managed wrapper.
--- @return number
function M.default_timeout_ms() return DEFAULT_TIMEOUT_MS end

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

--- Retains exceptional body cleanup in the existing physical settlement owner.
--- @param request table
local function retain_body_cleanup(request)
	if request.operation or not request.body_owner then return end
	local operation = { _settled = false, _cancelled = false, _listeners = {},
		_request = request, _body_cleanup = true }
	request.operation = operation
	_owned[request.owner] = operation
end

--- Closes a libuv handle once.
--- @param handle any
local function close_handle(handle, request)
	if not handle or not luv then return false end
	if request and (request.operation or request.body_owner) then
		local receipt = request.handles[handle]
		if not receipt then return false end
		if receipt.state == "closed" or receipt.state == "closing" then return true end
		local ok_closing, closing = pcall(luv.is_closing, handle)
		-- Another actor's scheduled close is not our closure acknowledgment.
		if not ok_closing or closing then retain_body_cleanup(request); return false end
		receipt.state = "closing"
		local ok, accepted, err = pcall(luv.close, handle, function()
			receipt.state = "closed"
			settle_owned(request)
		end)
		if not ok or accepted == false or err ~= nil then
			if receipt.state ~= "closed" then receipt.state = "open" end
			retain_body_cleanup(request)
			return false
		end
		if request.body_owner and receipt.state ~= "closed" then
			local state_ok, scheduled = pcall(luv.is_closing, handle)
			if not state_ok or not scheduled then
				receipt.state = "open"
				retain_body_cleanup(request)
				return false
			end
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

--- Closes one owned anonymous-pipe descriptor before handle transfer/inheritance.
--- @param request table
--- @param field string
--- @return boolean
local function close_body_descriptor(request, field)
	local descriptor = request[field]
	if descriptor == nil then return true end
	-- An errored close can still retire its FD. Verify the original pipe object
	-- before retrying a number that another open may already have reused.
	local stat_ok, stat, _, code = pcall(luv.fs_fstat, descriptor)
	local identity = request[field .. "_identity"]
	if stat_ok and (code == "EBADF" or (stat and identity and
		(stat.dev ~= identity.dev or stat.ino ~= identity.ino or stat.type ~= identity.type))) then
		request[field] = nil
		return true
	end
	if not stat_ok or type(stat) ~= "table" or not identity then
		-- Unknown initial metadata cannot become a new ownership claim on retry.
		retain_body_cleanup(request)
		return false
	end
	local ok, accepted = pcall(luv.fs_close, descriptor)
	if not ok or accepted == nil or accepted == false then retain_body_cleanup(request); return false end
	request[field] = nil
	return true
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
	if not operation or operation._settled or not request.terminal or request.observing_terminal
		or request.observing_identity then return end
	if request.identity_owner and not request.identity_owner:is_settled() then return end
	if request.spawned and not request.exited then return end
	if request.body_readfd ~= nil or request.body_writefd ~= nil then return end
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
	if request.identity_owner then request.identity_owner:cancel() end
	close_body_descriptor(request, "body_readfd")
	close_body_descriptor(request, "body_writefd")
	close_timer(request)
	close_stream(request, "stdin")
	close_stream(request, "body_pipe")
	close_stream(request, "body_reader")
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
	-- Logical observation precedes even an immediately acknowledged close.
	-- Its copy cannot mutate the pending physical completion receipt.
	if request.operation and type(request.operation._on_terminal) == "function" then
		request.observing_terminal = true
		local snapshot = {}
		for key, value in pairs(result) do
			if type(value) == "table" then
				local copy = {}
				for field, fact in pairs(value) do copy[field] = fact end
				snapshot[key] = copy
			else snapshot[key] = value end
		end
		local observed = pcall(request.operation._on_terminal, snapshot)
		request.observing_terminal = false
		if not observed then Logger.error(LOG, "Native HTTP terminal observer raised.") end
	end
	if request.identity_owner then request.identity_owner:cancel() end
	close_body_descriptor(request, "body_readfd")
	close_body_descriptor(request, "body_writefd")
	close_timer(request)
	close_stream(request, "stdin")
	close_stream(request, "body_pipe")
	close_stream(request, "body_reader")
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
		-- A caller URL is one literal target, never curl's range/list language.
		"--globoff",
		"--silent", "--show-error", "--no-buffer", "--fail-with-body",
		"--max-time", tostring(math.max(1, math.ceil(timeout_ms / 1000))),
		"--proto", options.protocols,
	}
	-- Data selects POST itself. A custom POST word would survive 303 even
	-- when curl switches to retrieval and discards the original body.
	if options.method ~= "POST" then
		args[#args + 1] = "--request"
		args[#args + 1] = options.method
	end
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
	local private_trailer = ""
	if options.proxy_selection then
		private_trailer = "%{stderr}\n" .. PROXY_MARKER .. "%{http_connect}:"
			.. (options.proxy_metrics_available and "%{proxy_used}" or "?") .. "\n"
	end
	args[#args + 1] = private_trailer
		.. (options.buffered and (private_trailer ~= "" and "%{stdout}" or "") or "%{stderr}")
		.. "\n" .. STATUS_MARKER .. "%{http_code}\n"
	-- Headers, body and URL go through a config read from stdin. On the command
	-- line they were readable by every local process through /proc/<pid>/cmdline:
	-- an API key in a header or a Gemini URL, and the typed text in the body.
	args[#args + 1] = "--config"
	args[#args + 1] = "-"
	local lines = {}
	local selection = options.proxy_selection
	if selection then
		if selection.mode == "selected" then
			lines[#lines + 1] = "proxy = " .. config_quote(selection.proxy)
		elseif selection.mode == "direct" then
			lines[#lines + 1] = 'proxy = ""'
			lines[#lines + 1] = 'noproxy = "*"'
		end
	end
	local names = {}
	for name in pairs(headers) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		local header_name, header_value = tostring(name), tostring(headers[name])
		local allowed, err = HeaderPolicy.validate(header_name, header_value)
		if not allowed then error(err) end
		-- Curl's empty colon form removes a field; semicolon sends an empty
		-- value, preserving the caller's distinction between present and absent.
		local wire_header = header_value:match("^[ \t]*$") and header_name .. ";"
			or header_name .. ": " .. header_value
		lines[#lines + 1] = "header = " .. config_quote(wire_header)
	end
	-- Curl config lines are limited to 10 MB. A separate inherited pipe carries
	-- admitted caller text without putting it in a config line, argv or a file.
	-- Only this fixed reference is interpreted as a filename; caller @ is data.
	if body ~= nil then lines[#lines + 1] = 'data-binary = "@/dev/fd/3"' end
	lines[#lines + 1] = "url = " .. config_quote(url)
	return args, table.concat(lines, "\n") .. "\n"
end

--- Withholds managed native diagnostics that can contain private proxy data.
--- @param request table
--- @param text string
--- @return string
local function public_diagnostic(request, text)
	if request.proxy_selection then return "curl exited with code " .. tostring(request.exit_code) end
	return text
end

--- Adds only observed, complete terminal native metrics to managed results.
--- @param request table
--- @param result table
--- @return table
local function native_receipt(request, result)
	if not request.proxy_selection then return result end
	local tail = request.stderr_tail:gsub("\n" .. STATUS_MARKER .. "%d%d%d\n?$", "")
	local connect_text, used = tail:match("\n" .. PROXY_MARKER .. "(%d%d%d):([01?])\n?$")
	local connect = tonumber(connect_text)
	local stage, provenance = "connect", "unavailable"
	if request.exit_code == 5 and connect ~= nil then stage, provenance = "proxy_resolve", "verified"
	elseif request.exit_code == 60 then stage, provenance = "tls", "verified"
	elseif connect and connect >= 300 then stage, provenance = "proxy_connect", "verified"
	elseif result.status and result.status > 0 then stage, provenance = "http", "verified"
	elseif request.exit_code == 7 and connect ~= nil and request.proxy_metrics_available and used == "1" then
		stage, provenance = "proxy_connect", "verified"
	end
	result.failure_receipt = {
		stage = stage, backend = "curl", failure_provenance = provenance,
		curl_exit = request.exit_code, http_status = result.status or 0,
		proxy_connect_status = connect,
		proxy_mode = request.proxy_selection.capability == "unavailable" and "unavailable" or request.proxy_selection.mode,
		tls_verification = "enforced",
	}
	if request.proxy_metrics_available and (used == "0" or used == "1") then result.proxy_used = used == "1" end
	return result
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
			error = public_diagnostic(request, request.stderr_text ~= "" and request.stderr_text
				or "curl exited with code " .. tostring(request.exit_code)),
		}
	end
	if not status then
		return { ok = false, status = 0, body = "", error = "missing HTTP status" }
	end
	-- The read budget includes room for curl's receipt. Once separated, neither
	-- successful bytes nor refused HTTP diagnostics may borrow that allowance.
	if request.max_body_bytes and #body > request.max_body_bytes then
		return { ok = false, status = 0, body = "", error = "response body exceeds limit" }
	end
	local http_success = status >= 200 and status < 300
	local succeeded = http_success and request.exit_code == 0
	local failure
	if not http_success then
		failure = "HTTP " .. tostring(status)
	elseif not succeeded then
		failure = public_diagnostic(request, request.stderr_text ~= "" and request.stderr_text
			or "curl exited with code " .. tostring(request.exit_code))
	end
	return {
		ok = succeeded,
		status = status,
		body = succeeded and body or "",
		-- A refused request explains itself in its body ("invalid API key").
		-- Curl's fail-with-body exit 22 still proves a completed HTTP rejection;
		-- other exits can leave a valid JSON prefix before transport truncation.
		error_body = not http_success and (request.exit_code == 0 or request.exit_code == 22) and body or nil,
		error = failure,
	}
end

--- Converts a completed stream without treating curl exit or stderr as HTTP status.
--- @param request table
--- @return table
local function streaming_result(request)
	local status = tonumber(request.stderr_tail:match("\n" .. STATUS_MARKER .. "(%d%d%d)\n?$"))
	local diagnostic = public_diagnostic(request, request.stderr_text:gsub("\n" .. STATUS_MARKER .. "%d%d%d\n?$", ""))
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
		error_body = not http_success and (request.exit_code == 0 or request.exit_code == 22)
			and not request.error_body_truncated and request.error_body_text or nil,
		error = failure,
	}
end

--- Completes once both the process and its two output streams ended.
--- @param request table
local function maybe_complete(request)
	if request.terminal or not request.exited or not request.stdout_eof or not request.stderr_eof then
		return
	end
	if request.proxy_selection then
		request.stderr_text = request.stderr_text:gsub("\n" .. PROXY_MARKER .. "%d%d%d:[01?]\n", "")
	end
	if request.buffered then
		finish(request, native_receipt(request, buffered_result(request)))
	else
		finish(request, native_receipt(request, streaming_result(request)))
	end
	close_process(request)
end

--- Copies only finite safe scalar identity observations from the private owner.
--- @param value table|nil
--- @return table|nil
local function copy_executable_identity(value)
	if type(value) ~= "table" then return nil end
	local copy = {}
	for _, key in ipairs({ "device", "inode", "size", "mtime_sec", "mtime_nsec", "ctime_sec", "ctime_nsec" }) do
		local field = value[key]
		if type(field) ~= "number" or field < 0 or field > MAX_SAFE_INTEGER or field % 1 ~= 0 then return nil end
		if (key == "mtime_nsec" or key == "ctime_nsec") and field >= 1000000000 then return nil end
		copy[key] = field
	end
	return copy
end

--- Rechecks requested native feature admission at actual composition time.
--- This practical stat fence creates no handle, probe process or file owner.
--- @param options table
local function admit_curl_metrics(options)
	if not options.proxy_metrics_available then return end
	options.proxy_metrics_available = false
	if not luv or type(luv.fs_stat) ~= "function" then return end
	local observed, stat, native_error, native_status = pcall(luv.fs_stat, options.curl_executable)
	if not observed or native_error ~= nil or native_status ~= nil or type(stat) ~= "table"
		or type(stat.mtime) ~= "table" or type(stat.ctime) ~= "table" then return end
	local actual = copy_executable_identity({ device = stat.dev, inode = stat.ino, size = stat.size,
		mtime_sec = stat.mtime.sec, mtime_nsec = stat.mtime.nsec, ctime_sec = stat.ctime.sec, ctime_nsec = stat.ctime.nsec })
	if not actual then return end
	for key, value in pairs(options.curl_executable_identity) do
		if actual[key] ~= value then return end
	end
	options.proxy_metrics_available = true
end

--- Normalizes native metadata once without acquiring or cancelling resources.
--- @param url string
--- @param headers table
--- @param body string|nil
--- @param options table
--- @return table|nil
--- @return string|nil
local function admit_metadata(url, headers, body, options)
	if type(options) ~= "table" then return nil, "native HTTP options are invalid" end
	if type(headers) ~= "table" then return nil, "native HTTP headers are invalid" end
	if body ~= nil and type(body) ~= "string" then return nil, "native HTTP body is invalid" end
	if type(url) ~= "string" or url == "" then return nil, ("curl URL must be a non-empty string") end
	-- Curl reads the URL from a C-string config value. NUL silently selects a
	-- shorter address, so refuse before native side effects or owner replacement.
	if url:find("\0", 1, true) then
		-- Private refusal text does not include caller data.
		return nil, ("curl config URL cannot contain NUL")
	end
	-- Curl's previous config parser truncated literal NUL. Refuse it before
	-- owner replacement; JSON's literal \\u0000 escape remains exact text.
	if body ~= nil and body:find("\0", 1, true) then return nil, ("curl request body cannot contain NUL") end
	local protocols, transport_error = TransportPolicy.resolve(url, options.https_only == true)
	if not protocols then return nil, (transport_error) end
	local follow_redirects = options.follow_redirects
	if follow_redirects then
		local allowed, err = RedirectPolicy.allows_native_follow(headers)
		if allowed == nil then
			-- Keep the canonical redirect refusal.
			return nil, (err)
		end
		-- Curl protects Authorization but forwards custom API-key headers.
		-- Keep the original request and its HTTP receipt; refuse native follow
		-- until the adapter owns and filters every redirect hop explicitly.
		follow_redirects = allowed
	end
	local timeout_ms = tonumber(options.timeout_ms) or DEFAULT_TIMEOUT_MS
	local request_options = {
		protocols = protocols,
		buffered = options.buffered == true,
		method = options.method or "POST",
		timeout_ms = timeout_ms,
		follow_redirects = follow_redirects == true,
		https_only = options.https_only == true,
		etag_compare = options.etag_compare,
		etag_save = options.etag_save,
		output_path = options.output_path,
		max_download_bytes = options.max_download_bytes,
		proxy_selection = options.proxy_selection,
		curl_executable = options.curl_executable or "curl",
		curl_executable_identity = copy_executable_identity(options.curl_executable_identity),
		curl_executable_identity_exact = ExactIdentity.copy(options.curl_executable_identity_exact),
		proxy_metrics_available = options.proxy_metrics_available == true and type(options.curl_executable) == "string",
	}
	if options.curl_executable ~= nil and (type(options.curl_executable) ~= "string"
		or options.curl_executable:sub(1, 1) ~= "/" or options.curl_executable:find("[%z\r\n]")) then
		return nil, "native curl executable is invalid"
	end
	if options.curl_executable_identity_exact ~= nil and (not request_options.curl_executable_identity_exact
		or options.curl_executable_identity ~= nil) then return nil, "native curl exact identity is invalid" end
	request_options.proxy_metrics_available = request_options.proxy_metrics_available
		and (request_options.curl_executable_identity ~= nil or request_options.curl_executable_identity_exact ~= nil)
	local selection = request_options.proxy_selection
	if selection ~= nil then
		if type(selection) ~= "table" or (selection.mode ~= "selected" and selection.mode ~= "direct"
			and selection.mode ~= "environment") then return nil, "native proxy selection is invalid" end
		if selection.mode == "selected" and (selection.bypass ~= "environment" or type(selection.proxy) ~= "string" or selection.proxy == ""
			or selection.proxy:find("[%z\r\n]")) then return nil, "native proxy selection is invalid" end
		-- Snapshot private admitted inputs; caller mutation cannot change a child.
		request_options.proxy_selection = { mode = selection.mode, proxy = selection.proxy, capability = selection.capability,
			bypass = selection.bypass }
	end
	return request_options
end

--- Refuses metadata before the managed owner starts any native child.
--- @param url string
--- @param headers table
--- @param body string|nil
--- @param options table
--- @return boolean
--- @return string|nil
function M.preflight(url, headers, body, options)
	local normalized, err = admit_metadata(url, headers, body, options)
	if not normalized then return false, err end
	local composed, argv = pcall(curl_args, url, headers, body, normalized)
	if not composed then return false, "curl configuration refused" end
	local refused = ShellRunner.validate_spawn_args(normalized.curl_executable, argv)
	if refused ~= "" then return false, "curl argument vector refused: " .. refused end
	return true
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
	local request_options, admission_error = admit_metadata(url, headers, body, options)
	if not request_options then return reject(admission_error) end
	local timeout_ms = request_options.timeout_ms
	-- The new descriptor-bearing representation requires the physical native
	-- operation used by the managed wrapper. Legacy boolean ports are unchanged.
	if request_options.curl_executable_identity_exact and not operation then
		return reject("owned curl exact identity observation unavailable")
	end
	-- Metadata refusal is transactional too: an invalid replacement must not
	-- retire a valid owner or leave timers/pipes behind after composition raises.
	local owner = request_owner(options.owner)
	local predecessor = _active[owner]
	local composed, argv, config
	if not operation or (predecessor and not predecessor.operation) then
		if request_options.curl_executable_identity_exact then
			-- Transactional early composition must remain free of descriptor I/O.
			-- Rebuild after the exact operation is registered and observed below.
			local requested = request_options.proxy_metrics_available
			request_options.proxy_metrics_available = false
			composed, argv, config = pcall(curl_args, url, headers, body, request_options)
			request_options.proxy_metrics_available = requested
		else
			admit_curl_metrics(request_options)
			composed, argv, config = pcall(curl_args, url, headers, body, request_options)
		end
		if not composed then
			Logger.error(LOG, "Cannot compose curl configuration; request refused.")
			return reject("curl configuration refused")
		end
		local argv_refusal = ShellRunner.validate_spawn_args(request_options.curl_executable, argv)
		if argv_refusal ~= "" then return reject("curl argument vector refused: " .. argv_refusal) end
	end
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
		body_owner = body ~= nil,
		handles = {},
		spawned = false,
		buffered = options.buffered == true,
		proxy_selection = request_options.proxy_selection,
		proxy_metrics_available = request_options.proxy_metrics_available,
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
	if operation or request.body_owner then
		if operation then operation._request = request; _owned[owner] = operation end
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
	if body ~= nil then
		local body_ok = pcall(function()
			request.body_pipe = luv.new_pipe(false)
			if not request.body_pipe then error("native body handle allocation refused") end
			request.handles[request.body_pipe] = { state = "open" }
			request.body_reader = luv.new_pipe(false)
			if not request.body_reader then error("native body reader allocation refused") end
			request.handles[request.body_reader] = { state = "open" }
			local pair = BodyPipe.allocate(luv)
			if not pair then error("native body pipe allocation refused") end
			request.body_readfd, request.body_writefd = pair.read, pair.write
			if type(pair.read) ~= "number" or type(pair.write) ~= "number" then error("invalid native body pipe") end
			for _, field in ipairs({ "body_readfd", "body_writefd" }) do
				local stat = assert(luv.fs_fstat(request[field]))
				request[field .. "_identity"] = { dev = stat.dev, ino = stat.ino, type = stat.type }
			end
			-- A spawn-created luv channel is a socketpair, which curl cannot reopen
			-- through /dev/fd. Inherit a real anonymous pipe's read descriptor.
			local accepted, err = luv.pipe_open(request.body_reader, pair.read)
			if accepted == nil or accepted == false or err ~= nil then error("native body reader attachment refused") end
			request.body_readfd = nil -- The reader handle now owns this descriptor.
			accepted, err = luv.pipe_open(request.body_pipe, pair.write)
			if accepted == nil or accepted == false or err ~= nil then error("native body pipe attachment refused") end
			request.body_writefd = nil -- The tracked handle now owns this descriptor.
		end)
		if not body_ok then
			finish(request, { ok = false, status = 0, body = "", error = "libuv handle allocation failed" })
			return false
		end
	end

	local timer_ok, timer_result = pcall(NativeTimer.start, luv, request.timer, timeout_ms, 0, function()
		if request.terminal then return end
		terminate_group(request)
		finish(request, { ok = false, status = 0, body = "", error = "timeout" })
	end)
	if not timer_ok or timer_result == false or timer_result == nil then
		finish(request, { ok = false, status = 0, body = "", error = "timeout activation failed" })
		return false
	end

	if request_options.curl_executable_identity_exact then
		local requested = request_options.proxy_metrics_available
		request_options.proxy_metrics_available = false
		if requested then
			request.observing_identity = true
			local observed, actual = pcall(function()
				local identity_owner = ExactIdentity.new(luv, function(message) Logger.error(LOG, "%s", message) end)
				request.identity_owner = identity_owner -- Registered before the first open.
				local registered, registration_error, registration_status = identity_owner:on_settled(function() settle_owned(request) end)
				if registered ~= true or registration_error ~= nil or registration_status ~= nil then
					error("Exact image settlement registration refused.")
				end
				return identity_owner:observe_planned(request_options.curl_executable)
			end)
			request.observing_identity = false -- Finally, even after constructor/observer refusal.
			local identity_owner = request.identity_owner
			if not observed then
				if identity_owner then identity_owner:cancel() end
				finish(request, { ok = false, status = 0, body = "", error = "curl exact identity observation failed" })
				return false
			end
			if request.terminal or operation._cancelled then settle_owned(request); return false end
			if not identity_owner:is_settled() then
				finish(request, { ok = false, status = 0, body = "", error = "curl exact identity retirement unavailable" })
				return false
			end
			request_options.proxy_metrics_available = ExactIdentity.equal(actual, request_options.curl_executable_identity_exact)
		end
		-- Even a regular predecessor's already-admitted argv cannot reuse an
		-- unobserved exact feature. Compose once more from the current FD receipt.
		composed = nil
	end

	-- First owned requests retain late construction and its physical close debt.
	-- Replacements of regular owners reuse metadata admitted before cancellation.
	if operation and not composed then
		local built
		if not request_options.curl_executable_identity_exact then admit_curl_metrics(request_options) end
		request.proxy_metrics_available = request_options.proxy_metrics_available
		built, argv, config = pcall(curl_args, url, headers, body, request_options)
		if not built then
			finish(request, { ok = false, status = 0, body = "", error = "curl request construction failed" })
			return false
		end
		local owned_refusal = ShellRunner.validate_spawn_args(request_options.curl_executable, argv)
		if owned_refusal ~= "" then
			finish(request, { ok = false, status = 0, body = "", error = "curl argument vector refused: " .. owned_refusal })
			return false
		end
	end
	local spawn_ok, process, pid, spawn_error = pcall(luv.spawn, request_options.curl_executable, {
		args = argv,
		stdio = { request.stdin, request.stdout, request.stderr, request.body_reader },
		detached = true,
	}, function(code, signal)
		request.exited = true
		request.exit_code = LibuvExit.status(code, signal)
		request.exit_signal = signal
		maybe_complete(request)
		close_process(request)
		if request.operation and request.operation._body_cleanup then retry_owned_cleanup(request)
		else settle_owned(request) end
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
	if operation or request.body_owner then request.handles[process] = { state = "open" } end
	-- The child inherited its own fd3. Retaining the parent's reader would hide
	-- a child exit from the writer; release it before asynchronous body delivery.
	if request.body_reader and not close_handle(request.body_reader, request) then
		terminate_group(request)
		finish(request, { ok = false, status = 0, body = "", error = "curl body pipe retirement failed" })
		return false
	end
	request.body_reader = nil

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
			request.stderr_tail = (request.stderr_tail .. chunk):sub(-(request.proxy_selection and NATIVE_TRAILER_BYTES or (#STATUS_MARKER + 16)))
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
	if request.body_pipe then
		local body_ok, body_result = pcall(luv.write, request.body_pipe, body, function(write_err)
			if write_err and not request.terminal then
				terminate_group(request)
				finish(request, { ok = false, status = 0, body = "", error = "curl body write failed" })
				return
			end
			close_stream(request, "body_pipe")
		end)
		if not body_ok or body_result == false or body_result == nil then
			terminate_group(request)
			finish(request, { ok = false, status = 0, body = "", error = "curl body write failed" })
			return false
		end
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
local function owned_request(url, headers, body, options, on_chunk, callback)
	local logical_api = options.owned_api == false
	local operation = { started = false, _settled = false, _cancelled = false, _listeners = {},
		_on_terminal = options.on_native_terminal }
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
	function operation:request_cancel()
		-- Owned intent fences delivery even when the native signal is refused.
		if not logical_api then self._cancelled = true end
		if self._settled then return true end
		local request = self._request
		if not request then return false end
		-- A reaped leader can leave group descendants holding captured pipes.
		if request.spawned and (not request.terminal or not request.exited)
			and not terminate_group(request) then return false end
		self._cancelled = true
		if not request.terminal then
			finish(request, { ok = false, status = 0, body = "", error = "cancelled" }, true)
		else retry_owned_cleanup(request) end
		return true
	end
	function operation:cancel()
		self:request_cancel()
		return self._settled
	end

	local request_options = {}
	if type(options) == "table" then
		for key, value in pairs(options) do request_options[key] = value end
	end
	operation.started = start_request(url, type(headers) == "table" and headers or {}, body,
		request_options, on_chunk, callback, operation)
	return operation
end

--- Starts a buffered owned GET preserving the established public native API.
function M.get_owned(url, headers, options, callback)
	local request = {}
	for key, value in pairs(type(options) == "table" and options or {}) do request[key] = value end
	request.buffered, request.method = true, "GET"
	return owned_request(url, headers, nil, request, nil, callback)
end

--- Dispatches one native transaction for the private managed coordinator.
--- @param url string
--- @param headers table
--- @param body string|nil
--- @param options table
--- @param on_chunk function|nil
--- @param on_done function
--- @return table
function M.dispatch_owned(url, headers, body, options, on_chunk, on_done)
	local invalid
	if type(options) ~= "table" then invalid = "native HTTP options are invalid"
	elseif type(headers) ~= "table" then invalid = "native HTTP headers are invalid"
	elseif body ~= nil and type(body) ~= "string" then invalid = "native HTTP body is invalid" end
	if invalid then
		local operation = { started = false }
		function operation:is_settled() return true end
		function operation:cancel() return true end
		function operation:request_cancel() return true end
		function operation:on_settled(listener)
			if type(listener) ~= "function" then return false end
			local observed = pcall(listener)
			if not observed then Logger.error(LOG, "Owned HTTP refusal observer raised.") end
			return true
		end
		if type(on_done) == "function" then
			local observed = pcall(on_done, { ok = false, status = 0, body = "", error = invalid })
			if not observed then Logger.error(LOG, "Owned HTTP refusal callback raised.") end
		end
		return operation
	end
	return owned_request(url, headers, body, options, on_chunk, on_done)
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
	if not _active[key] then
		local operation = _owned[key]
		if operation and operation._request and operation._request.identity_owner then return operation:cancel() end
		if not operation or not operation._body_cleanup then return true end
		operation._cancelled = true
		local retained = operation._request
		if retained.spawned and not retained.exited and not terminate_group(retained) then return false end
		retry_owned_cleanup(retained)
		return operation._settled
	end
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
	local key = request_owner(owner)
	local operation = _owned[key]
	local request = operation and operation._request
	if request and request.identity_owner and not request.identity_owner:is_settled() then return true end
	return _active[key] ~= nil
end

return M
