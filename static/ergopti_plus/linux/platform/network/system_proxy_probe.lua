--- platform/network/system_proxy_probe.lua

--- ==============================================================================
--- MODULE: Native GIO Proxy Lookup Child (Linux)
--- DESCRIPTION:
--- Reads one private destination from stdin and returns the operating system's
--- ordered proxy selection. The parent owns this blocking child, its deadline
--- and its retirement; the grabbed-keyboard process never calls GIO directly.
--- GIO/libproxy acknowledges selection, not successful PAC retrieval or
--- evaluation: a native DIRECT selection preserves that explicit limitation.
--- ==============================================================================

local shared_root = arg[1]
if type(shared_root) ~= "string" or shared_root == "" then os.exit(2) end
package.path = shared_root .. "/lua/?.lua;" .. package.path
local Json = require("json")

-- Resolve the installed native module only from this helper's actual source.
-- The helper keeps its existing one-argument shared-root contract.
local source_info = type(debug) == "table" and type(debug.getinfo) == "function" and debug.getinfo(1, "S") or nil
local helper_source = type(source_info) == "table" and source_info.source or nil
local driver_root = type(helper_source) == "string"
	and helper_source:match("^@(/.+)/platform/network/system_proxy_probe%.lua$") or nil
local ExactIdentity
if driver_root then
	package.path = driver_root .. "/?.lua;" .. package.path
	local loaded, module = pcall(require, "infra.curl_identity")
	if loaded then ExactIdentity = module end
end
-- These exact descriptor owners remain reachable until this contained helper
-- exits. An uncertain fs_close is not retried or converted into a close ACK;
-- the parent's actual helper-exit ACK is the later kernel retirement boundary.
local identity_owners = {}
local NativeRuntime
if driver_root then
	local loaded, module = pcall(require, "platform.network.native_proxy_runtime")
	if loaded then NativeRuntime = module end
end

--- Emits one machine receipt without native diagnostic text or request bytes.
--- @param receipt table
local function emit(receipt)
	io.stdout:write(Json.encode(receipt), "\n")
	io.stdout:flush()
end

--- Uses the native ABI shared with installed package capability inspection.
--- @return table|nil
local function native_backend()
	return NativeRuntime and NativeRuntime.load() or nil
end

--- Performs the actual system lookup and frees every native result allocation.
--- @param url string
--- @return table
local function lookup(url, exclusions)
	local native = native_backend()
	if not native then return { ok = false, error = "proxy-native-unavailable" } end
	local ffi = native.ffi
	if exclusions ~= nil then
		if type(exclusions) ~= "table" or #exclusions > 32 then return { ok = false, error = "proxy-request-invalid" } end
		for key, name in pairs(exclusions) do
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #exclusions
				or type(name) ~= "string" or not name:match("^[%a_][%w_]*$") then
				return { ok = false, error = "proxy-request-invalid" }
			end
			if ffi.C.unsetenv(name) ~= 0 then return { ok = false, error = "proxy-native-failed" } end
		end
	end
	local resolver, backend, refusal = NativeRuntime.default_resolver(native)
	if not resolver then return { ok = false, error = refusal, backend = backend } end
	local error_slot = ffi.new("ErgoptiProxyError *[1]")
	local proxies = native.gio.g_proxy_resolver_lookup(resolver, url, nil, error_slot)
	local native_error = error_slot[0]
	local receipt = { ok = false, error = "proxy-lookup-failed", backend = backend }
	if native_error ~= nil then
		receipt.native_error_code = tonumber(native_error.code)
		native.glib.g_error_free(native_error)
	end
	if proxies ~= nil then
		local values = {}
		local valid = native_error == nil
		local index = 0
		while proxies[index] ~= nil do
			local value = ffi.string(proxies[index])
			if #values >= 128 or #value > 65536 or value:find("[%z\r\n]") then
				valid = false
				break
			end
			values[#values + 1] = value
			index = index + 1
		end
		native.glib.g_strfreev(proxies)
		if valid and #values > 0 then
			receipt = {
				ok = true, proxies = values, backend = backend,
				acknowledgement = "native-selection",
				failure_provenance = "unavailable",
			}
		end
	end
	return receipt
end

--- Converts a native image stat to one bounded safe-integer receipt.
--- @param stat table|nil
--- @return table|nil
local function image_identity(stat)
	if type(stat) ~= "table" or type(stat.mtime) ~= "table" or type(stat.ctime) ~= "table" then return nil end
	local identity = {
		device = stat.dev, inode = stat.ino, size = stat.size,
		mtime_sec = stat.mtime.sec, mtime_nsec = stat.mtime.nsec,
		ctime_sec = stat.ctime.sec, ctime_nsec = stat.ctime.nsec,
	}
	for _, name in ipairs({ "device", "inode", "size", "mtime_sec", "mtime_nsec", "ctime_sec", "ctime_nsec" }) do
		local value = identity[name]
		if type(value) ~= "number" or value < 0 or value > 9007199254740991 or value % 1 ~= 0 then return nil end
	end
	if identity.mtime_nsec >= 1000000000 or identity.ctime_nsec >= 1000000000 then return nil end
	return identity
end

--- Matches the live owned image and planned path without claiming immutability.
--- @param uv table
--- @param image string
--- @param executable string
--- @return table|nil
local function observed_identity(uv, image, executable)
	if type(uv.fs_stat) ~= "function" then return nil end
	local called, live, native_error, native_status = pcall(uv.fs_stat, image)
	if not called or native_error ~= nil or native_status ~= nil then return nil end
	live = image_identity(live)
	local planned, stat, stat_error, stat_status = pcall(uv.fs_stat, executable)
	if not planned or stat_error ~= nil or stat_status ~= nil then return nil end
	stat = image_identity(stat)
	if not live or not stat then return nil end
	for name, value in pairs(live) do if stat[name] ~= value then return nil end end
	return live
end

--- Observes the actual curl executable's version in an owned shell-free child.
--- The outer helper deadline owns this process group. The native event loop
--- retains the child until exit and its captured pipes/handles have closed.
--- @return table
local function curl_capabilities()
	local loaded, uv = pcall(require, "luv")
	if not loaded then return { proxy_used = false } end
	local stdout, stderr = uv.new_pipe(false), uv.new_pipe(false)
	if not stdout or not stderr then
		if stdout then uv.close(stdout) end
		if stderr then uv.close(stderr) end
		uv.run()
		return { proxy_used = false }
	end
	local output, bytes, code, exited = "", 0, nil, false
	local process, pid
	local function close(handle)
		if handle and not uv.is_closing(handle) then uv.close(handle) end
	end
	local function refuse()
		if pid and not exited then uv.kill(pid, "sigkill") end
		close(stdout)
		close(stderr)
	end
	process, pid = uv.spawn("curl", {
		args = { "--disable", "--version" }, stdio = { nil, stdout, stderr },
	}, function(exit_code, signal)
		exited, code = true, signal == 0 and exit_code or -1
		close(process)
	end)
	if not process or not pid then close(stdout); close(stderr); uv.run(); return { proxy_used = false } end
	-- Observe the owned version child's actual native image, never a PATH guess.
	-- Wrapper interpreters/deleted images cannot admit new write-out features.
	local executable, executable_identity, executable_identity_exact
	if type(uv.fs_readlink) == "function" then
		local observed, value, native_error, native_status = pcall(uv.fs_readlink, "/proc/" .. tostring(pid) .. "/exe")
		if observed and native_error == nil and native_status == nil and type(value) == "string" and #value <= 4096
			and value:sub(1, 1) == "/" and value:match("/curl$") and not value:find("[%z\r\n]") then
			executable_identity = observed_identity(uv, "/proc/" .. tostring(pid) .. "/exe", value)
			if executable_identity then executable = value end
		end
	end
	if not executable_identity and ExactIdentity then
		local identity_owner = ExactIdentity.new(uv)
		identity_owners[#identity_owners + 1] = identity_owner
		local exact, planned = identity_owner:observe_owned_child(pid)
		if exact and identity_owner:is_settled() then
			executable_identity_exact, executable = exact, planned
		end
	end
	for _, stream in ipairs({ { stdout, true }, { stderr, false } }) do
		local pipe = stream[1]
		local is_output = stream[2]
		local accepted, err = uv.read_start(pipe, function(native_error, chunk)
			if native_error then refuse(); return end
			if not chunk then close(pipe); return end
			bytes = bytes + #chunk
			if bytes > 8192 then refuse(); return end
			if is_output then output = output .. chunk end
		end)
		if accepted == nil or accepted == false or err ~= nil then refuse() end
	end
	uv.run()
	local major, minor, patch = output:match("^curl (%d+)%.(%d+)%.(%d+) ")
	if code ~= 0 or not major then return { proxy_used = false } end
	major, minor, patch = tonumber(major), tonumber(minor), tonumber(patch)
	return {
		version = string.format("%d.%d.%d", major, minor, patch),
		proxy_used = executable ~= nil and (major > 8 or (major == 8 and minor >= 7)),
		executable = executable,
		executable_observation = executable and "owned-child" or nil,
		executable_identity = executable and executable_identity or nil,
		executable_identity_exact = executable and executable_identity_exact or nil,
	}
end

-- Bounded stdin keeps the destination and any signed query out of argv, logs
-- and temporary files. The HTTP owner admits schemes before this native seam.
local bytes = io.stdin:read(65537)
local decoded, request = pcall(Json.decode, bytes or "")
if not decoded or type(request) ~= "table" or type(request.url) ~= "string"
	or request.url == "" or #bytes > 65536 or request.url:find("[%z\r\n]") then
	emit({ ok = false, error = "proxy-request-invalid" })
	os.exit(0)
end
local succeeded, receipt = pcall(lookup, request.url, request.environment_exclusions)
if succeeded and request.probe_curl == true then
	local probed, capabilities = pcall(curl_capabilities)
	receipt.curl_capabilities = probed and capabilities or { proxy_used = false }
end
emit(succeeded and receipt or { ok = false, error = "proxy-native-failed" })
