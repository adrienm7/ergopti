--- adapters/system_proxy.lua

--- ==============================================================================
--- MODULE: Owned Native System Proxy Lookup (Linux)
--- DESCRIPTION:
--- Runs GIO's blocking proxy resolver in a shell-free LuaJIT child. Request
--- bytes use a private stdin pipe; logs never contain destination, proxy
--- credentials or native stderr. Each owner retains its exact operation until
--- child exit and all native close acknowledgements, including cancellation.
--- Environment precedence, loopback admission and retry policy belong to the
--- shared HTTP policy and are applied by callers before this native adapter.
--- ==============================================================================

local M = {}

local Json = require("json")
local ExactIdentity = require("infra.curl_identity")
local Paths = require("infra.paths")
local ProcessGroup = require("infra.libuv_process_group")
local LibuvExit = require("infra.libuv_exit")
local NativeTimer = require("infra.native_timer")
local ShellRunner = require("adapters.shell_runner")
local Logger = require("logger.shim")
local LOG = "adapters.system_proxy"
local loaded, luv = pcall(require, "luv")
if not loaded then luv = nil end

local _owned = {}
local MAX_PACKET_BYTES = 65536


-- =========================================
-- =========================================
-- ======= 1/ Native Ownership =============
-- =========================================
-- =========================================

--- Publishes only after physical child retirement and native handle closure.
--- @param request table
local function settle(request)
	local operation = request.operation
	if operation._settled or not request.terminal then return end
	if request.spawned and not request.exited then return end
	for _, handle in pairs(request.handles) do
		if handle.state ~= "closed" then return end
	end
	operation._settled = true
	if _owned[request.owner] == operation then _owned[request.owner] = nil end
	if not operation._cancelled then
		local ok = pcall(request.callback, request.result)
		if not ok then Logger.error(LOG, "Native proxy completion callback raised.") end
	end
	local listeners = operation._listeners
	operation._listeners = {}
	for _, listener in ipairs(listeners) do
		local ok = pcall(listener)
		if not ok then Logger.error(LOG, "Native proxy settlement callback raised.") end
	end
end

--- Closes one exact handle and retains debt when native closure refuses.
--- @param request table
--- @param handle any
local function close_handle(request, handle)
	if not handle then return end
	local receipt = request.handles[handle]
	if not receipt or receipt.state ~= "open" then return end
	local inspected, closing = pcall(luv.is_closing, handle)
	if not inspected or closing then return end
	receipt.state = "closing"
	local called, accepted, err = pcall(luv.close, handle, function()
		receipt.state = "closed"
		settle(request)
	end)
	if not called or accepted == false or err ~= nil then
		if receipt.state ~= "closed" then receipt.state = "open" end
	end
end

--- Retries cleanup only for handles belonging to this operation.
--- @param request table
local function cleanup(request)
	if request.timer then pcall(luv.timer_stop, request.timer) end
	for _, field in ipairs({ "stdin", "stdout", "stderr" }) do
		if request[field] then pcall(luv.read_stop, request[field]) end
		close_handle(request, request[field])
	end
	close_handle(request, request.timer)
	if request.exited then close_handle(request, request.process) end
	settle(request)
end

--- Stores one terminal result while retaining all physical retirement debt.
--- @param request table
--- @param result table
local function finish(request, result)
	if request.terminal then return end
	request.terminal, request.result = true, result
	if request.on_native_terminal then
		local ok = pcall(request.on_native_terminal, result)
		if not ok then Logger.error(LOG, "Native proxy terminal callback raised.") end
	end
	cleanup(request)
end

--- Terminates only the detached group belonging to this operation.
--- @param request table
--- @return boolean
local function stop(request)
	-- libuv has reaped the leader at exit. Its numeric group ID can subsequently
	-- belong to another process, even while our inherited pipe EOF is pending.
	if not request.spawned or request.exited then return true end
	return ProcessGroup.terminate(luv, request.pid)
end

--- Admits a complete native packet after successful process and stream exit.
--- @param request table
local function complete(request)
	if request.terminal or not request.exited or not request.stdout_eof or not request.stderr_eof then return end
	if request.exit_code ~= 0 then
		finish(request, { ok = false, error = "proxy-child-failed" })
		return
	end
	local decoded, receipt = pcall(Json.decode, request.packet)
	if not decoded or type(receipt) ~= "table" or type(receipt.ok) ~= "boolean" then
		finish(request, { ok = false, error = "proxy-receipt-invalid" })
		return
	end
	if receipt.curl_capabilities ~= nil then
		local capabilities = receipt.curl_capabilities
		if type(capabilities) ~= "table" or type(capabilities.proxy_used) ~= "boolean"
			or (capabilities.version ~= nil and (type(capabilities.version) ~= "string"
				or #capabilities.version > 32 or not capabilities.version:match("^%d+%.%d+%.%d+$"))) then
			finish(request, { ok = false, error = "proxy-receipt-invalid" })
			return
		end
		if capabilities.executable ~= nil and (type(capabilities.executable) ~= "string"
			or #capabilities.executable > 4096 or capabilities.executable:sub(1, 1) ~= "/"
			or not capabilities.executable:match("/curl$") or capabilities.executable:find("[%z\r\n]")
			or capabilities.executable_observation ~= "owned-child") then
			finish(request, { ok = false, error = "proxy-receipt-invalid" })
			return
		end
		local exact = capabilities.executable_identity_exact
		if exact ~= nil then
			exact = ExactIdentity.copy(exact)
			if not exact or capabilities.executable_identity ~= nil then
				finish(request, { ok = false, error = "proxy-receipt-invalid" }); return
			end
			capabilities.executable_identity_exact = exact
		end
		local identity = capabilities.executable_identity
		if identity ~= nil then
			local fields = { device = true, inode = true, size = true, mtime_sec = true,
				mtime_nsec = true, ctime_sec = true, ctime_nsec = true }
			local count = 0
			if type(identity) ~= "table" then finish(request, { ok = false, error = "proxy-receipt-invalid" }); return end
			for name, value in pairs(identity) do
				if not fields[name] or type(value) ~= "number" or value < 0 or value > 9007199254740991
					or value % 1 ~= 0 then finish(request, { ok = false, error = "proxy-receipt-invalid" }); return end
				count = count + 1
			end
			if count ~= 7 or identity.mtime_nsec >= 1000000000 or identity.ctime_nsec >= 1000000000 then
				finish(request, { ok = false, error = "proxy-receipt-invalid" }); return
			end
		end
		-- A historical version hint alone cannot admit a new native variable.
		local major, minor
		if capabilities.version then major, minor = capabilities.version:match("^(%d+)%.(%d+)%.%d+$") end
		major, minor = tonumber(major), tonumber(minor)
		capabilities.proxy_used = capabilities.proxy_used == true and capabilities.executable ~= nil and (identity ~= nil or exact ~= nil)
			and major ~= nil and (major > 8 or (major == 8 and minor >= 7))
	end
	if receipt.ok then
		if type(receipt.proxies) ~= "table" or #receipt.proxies == 0 or #receipt.proxies > 128
			or receipt.acknowledgement ~= "native-selection"
			or receipt.failure_provenance ~= "unavailable" or type(receipt.backend) ~= "string"
			or #receipt.backend > 128 or not receipt.backend:match("^[%a_][%w_]*$") then
			finish(request, { ok = false, error = "proxy-receipt-invalid" })
			return
		end
		local count = 0
		for key, value in pairs(receipt.proxies) do
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #receipt.proxies
				or type(value) ~= "string" or value == "" or value:find("[%z\r\n]") then
				finish(request, { ok = false, error = "proxy-receipt-invalid" })
				return
			end
			count = count + 1
		end
		if count ~= #receipt.proxies then finish(request, { ok = false, error = "proxy-receipt-invalid" }); return end
	elseif type(receipt.error) ~= "string" or not receipt.error:match("^proxy%-%l[%l%-]+$") then
		finish(request, { ok = false, error = "proxy-receipt-invalid" })
		return
	end
	finish(request, receipt)
end


-- =========================================
-- =========================================
-- ======= 2/ Public API ===================
-- =========================================
-- =========================================

--- Resolves one destination through the native desktop proxy configuration.
--- Callers preserve the returned ordered proxies, including explicit DIRECT.
--- They must not interpret lookup success as PAC download/evaluation success.
--- @param url string Private destination URL.
--- @param options table { owner, timeout_ms }
--- @param callback function Receives the native selection after retirement.
--- @return table|nil operation
--- @return string|nil error Dispatch refusal.
function M.lookup_owned(url, options, callback)
	if type(url) ~= "string" or url == "" or url:find("[%z\r\n]") then return nil, "proxy-request-invalid" end
	if type(options) ~= "table" or type(options.owner) ~= "string" or options.owner == ""
		or type(options.timeout_ms) ~= "number" or options.timeout_ms <= 0
		or options.timeout_ms % 1 ~= 0 or type(callback) ~= "function"
		or (options.on_native_terminal ~= nil and type(options.on_native_terminal) ~= "function") then return nil, "proxy-options-invalid" end
	if _owned[options.owner] then return nil, "proxy-owner-busy" end
	if not luv then return nil, "proxy-async-unavailable" end
	local encoded, input = pcall(Json.encode, {
		url = url, probe_curl = options.probe_curl == true, environment_exclusions = options.environment_exclusions,
	})
	if not encoded or #input > MAX_PACKET_BYTES then return nil, "proxy-request-invalid" end
	local shared_root = Paths.shared_root()
	local driver_root = Paths.driver_root()
	if type(shared_root) ~= "string" or shared_root == "" or type(driver_root) ~= "string"
		or driver_root == "" then return nil, "proxy-installation-incomplete" end
	-- A packaged driver can run its bundled LuaJIT without putting it on PATH.
	-- Admit the actual interpreter instead of selecting a different host runtime.
	local located, executable, executable_error = pcall(luv.exepath)
	if not located or executable_error ~= nil or type(executable) ~= "string"
		or executable:sub(1, 1) ~= "/" or executable:find("\0", 1, true) then
		return nil, "proxy-runtime-unavailable"
	end
	local script = driver_root .. "/platform/network/system_proxy_probe.lua"
	local argv = { script, shared_root }
	if ShellRunner.validate_spawn_args(executable, argv) ~= "" then return nil, "proxy-argv-invalid" end
	local operation = { _settled = false, _cancelled = false, _listeners = {} }
	local request = {
		owner = options.owner, callback = callback, operation = operation,
		on_native_terminal = options.on_native_terminal,
		handles = {}, packet = "", stderr_bytes = 0,
		exited = false, spawned = false, terminal = false,
	}
	_owned[request.owner] = operation
	function operation.is_settled() return operation._settled end
	function operation.on_settled(listener)
		if type(listener) ~= "function" then return false end
		if operation._settled then
			local ok = pcall(listener)
			if not ok then Logger.error(LOG, "Native proxy settlement callback raised.") end
		else operation._listeners[#operation._listeners + 1] = listener end
		return true
	end
	function operation.cancel()
		if operation._settled then return true end
		local accepted = stop(request)
		if not accepted and options.logical_cancel == true then return false end
		operation._cancelled = true
		if not request.terminal then finish(request, { ok = false, error = "proxy-cancelled" }) else cleanup(request) end
		return accepted
	end
	function operation.retry_cleanup()
		if operation._settled then return true end
		if not request.terminal then return false end
		if request.spawned and not request.exited and not stop(request) then return false end
		cleanup(request)
		return operation._settled
	end
	local allocated = pcall(function()
		for _, field in ipairs({ "stdin", "stdout", "stderr" }) do
			request[field] = luv.new_pipe(false)
			if not request[field] then error("native allocation refused") end
			request.handles[request[field]] = { state = "open" }
		end
		request.timer = luv.new_timer()
		if not request.timer then error("native allocation refused") end
		request.handles[request.timer] = { state = "open" }
	end)
	if not allocated then finish(request, { ok = false, error = "proxy-handles-unavailable" }); return operation end
	local spawned, process, pid = pcall(luv.spawn, executable, {
		args = argv, stdio = { request.stdin, request.stdout, request.stderr }, detached = true,
	}, function(code, signal)
		request.exited, request.exit_code = true, LibuvExit.status(code, signal)
		if request.terminal then cleanup(request) else complete(request) end
	end)
	if not spawned or not process or not pid then
		finish(request, { ok = false, error = "proxy-child-unavailable" })
		return operation
	end
	request.process, request.pid, request.spawned = process, pid, true
	request.handles[process] = { state = "open" }
	local function abort(reason)
		stop(request)
		finish(request, { ok = false, error = reason })
	end
	local supervised, timer_accepted, timer_error = pcall(NativeTimer.start, luv, request.timer, options.timeout_ms, 0, function()
		if request.terminal then return end
		abort("proxy-lookup-timeout")
	end)
	if not supervised or timer_accepted == nil or timer_accepted == false or timer_error ~= nil then
		abort("proxy-supervision-failed")
		return operation
	end
	for _, field in ipairs({ "stdout", "stderr" }) do
		local stream_name = field
		local reading, accepted, read_error = pcall(luv.read_start, request[field], function(native_error, chunk)
			if request.terminal then return end
			if native_error then abort("proxy-stream-failed"); return end
			if chunk == nil then request[stream_name .. "_eof"] = true; complete(request); return end
			if stream_name == "stdout" then
				if #request.packet + #chunk > MAX_PACKET_BYTES then abort("proxy-output-too-large"); return end
				request.packet = request.packet .. chunk
			else
				request.stderr_bytes = request.stderr_bytes + #chunk
				if request.stderr_bytes > MAX_PACKET_BYTES then abort("proxy-output-too-large") end
			end
		end)
		if not reading or accepted == nil or accepted == false or read_error ~= nil then
			abort("proxy-supervision-failed")
			return operation
		end
	end
	local written, accepted, write_error = pcall(luv.write, request.stdin, input, function(native_error)
		if request.terminal then return end
		if native_error then abort("proxy-input-failed"); return end
		local shutdown, shutdown_accepted, shutdown_error = pcall(luv.shutdown, request.stdin, function(err)
			if request.terminal then return end
			if err then abort("proxy-input-failed") else close_handle(request, request.stdin) end
		end)
		if not shutdown or shutdown_accepted == nil or shutdown_accepted == false or shutdown_error ~= nil then
			abort("proxy-input-failed")
		end
	end)
	if not written or accepted == nil or accepted == false or write_error ~= nil then abort("proxy-input-failed") end
	return operation
end

--- Reports physical ownership even after logical cancellation or completion.
--- @param owner string
--- @return boolean
function M.is_owned(owner)
	return _owned[owner] ~= nil
end

return M
