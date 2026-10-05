--- tests/unit/adapters/test_curl_identity_helper.lua

--- ==============================================================================
--- MODULE: Test Curl Identity Helper
--- DESCRIPTION:
--- Preserves independent managed-network controls and actual production imports.
--- Source registration alone does not qualify native or installed behavior.
--- ==============================================================================

--- Executes the actual helper with independent native/stdio ports.
--- These are model receipts, not proof of a real child image or retirement.
local helpers = require("tests.helpers")
local Json = require("json")
local Paths = require("infra.paths")
local helper = helpers.driver_root() .. "/platform/network/system_proxy_probe.lua"

local function observe(config)
	local state = { handles = {}, closes = 0, reads = {}, output = "", stat_paths = {} }
	local uv = {}
	local function handle(kind)
		local value = { kind = kind, closing = false }
		state.handles[#state.handles + 1] = value
		return value
	end
	function uv.new_pipe() return handle("pipe") end
	function uv.is_closing(value) return value.closing end
	function uv.close(value)
		assert(not value.closing, "Each independent close receipt is acknowledged once")
		value.closing = true
		state.closes = state.closes + 1
	end
	function uv.spawn(executable, options, callback)
		assert(executable == "curl")
		assert(options.args[1] == "--disable" and options.args[2] == "--version" and #options.args == 2)
		state.options, state.exited = options, callback
		return handle("process"), 73
	end
	if not config.missing_readlink then
		function uv.fs_readlink(path)
			state.readlink_path = path
			if config.readlink_throws then error("fixed private dummy readlink marker") end
			return config.executable, config.native_error, config.readlink_extra_status and "EINVAL" or nil
		end
	end
	if not config.missing_stat then
		function uv.fs_stat(path)
			state.stat_paths[#state.stat_paths + 1] = path
			if config.stat_throws then error("fixed private dummy stat marker") end
			if config.stat_refusal then return nil, "EPERM" end
			local stat = { dev = 11, ino = 73, size = 71, mtime = { sec = 123, nsec = 456 }, ctime = { sec = 789, nsec = 12 } }
			if config.unsafe_integer then stat.dev = 9007199254740992 end
			if config.invalid_nanoseconds then stat.mtime.nsec = 1000000000 end
			if #state.stat_paths == 2 then
				if config.changed_inode then stat.ino = 74 end
				if config.changed_contents then stat.mtime.sec = 124 end
			end
			return stat, nil, config.stat_extra_status and "EINVAL" or nil
		end
	end
	function uv.read_start(pipe, callback)
		state.reads[pipe] = callback
		return true
	end
	function uv.run()
		local stdout, stderr = state.options.stdio[2], state.options.stdio[3]
		state.reads[stdout](nil, config.version_line or "curl 8.12.1 (fixed-fixture) libcurl/8.12.1\n")
		state.reads[stdout](nil, nil)
		state.reads[stderr](nil, nil)
		state.exited(config.exit_code or 0, 0)
	end
	local request = Json.encode({ url = "https://corporate.invalid/private", probe_curl = true })
	local saved = { luv = package.loaded.luv, ffi = package.loaded.ffi,
		stdin = io.stdin, stdout = io.stdout, arguments = arg }
	package.loaded.luv = uv
	-- Model native capability absence independently; no desktop resolver runs.
	package.loaded.ffi = { cdef = function() error("independent unavailable native ABI") end }
	io.stdin = { read = function() return request end }
	io.stdout = {
		write = function(_, ...) for _, value in ipairs({ ... }) do state.output = state.output .. value end end,
		flush = function() return true end,
	}
	arg = { [1] = assert(Paths.shared_root()) }
	local ok, err = pcall(dofile, helper)
	package.loaded.luv, package.loaded.ffi = saved.luv, saved.ffi
	io.stdin, io.stdout, arg = saved.stdin, saved.stdout, saved.arguments
	if not ok then error(err) end
	helpers.assert_eq(#state.handles, 3)
	helpers.assert_eq(state.closes, 3)
	for _, value in ipairs(state.handles) do helpers.assert_true(value.closing) end
	local receipt = Json.decode(state.output)
	helpers.assert_eq(receipt.error, "proxy-native-unavailable")
	return receipt.curl_capabilities, state
end

helpers.describe("owned curl version helper: independent executable observations", function()
	helpers.it("admits a modern observed native curl path for the same future executable", function()
		local capabilities, state = observe({ executable = "/independent/native/bin/curl" })
		helpers.assert_eq(state.readlink_path, "/proc/73/exe")
		helpers.assert_eq(capabilities.proxy_used, true)
		helpers.assert_eq(capabilities.version, "8.12.1")
		helpers.assert_eq(capabilities.executable, "/independent/native/bin/curl")
		helpers.assert_eq(capabilities.executable_observation, "owned-child")
		helpers.assert_eq(state.stat_paths[1], "/proc/73/exe")
		helpers.assert_eq(state.stat_paths[2], "/independent/native/bin/curl")
		local expected = { device = 11, inode = 73, size = 71, mtime_sec = 123, mtime_nsec = 456, ctime_sec = 789, ctime_nsec = 12 }
		for name, value in pairs(expected) do helpers.assert_eq(capabilities.executable_identity[name], value) end
	end)
	for _, case in ipairs({
		{ name = "missing port", missing_readlink = true },
		{ name = "native refusal", native_error = "EPERM" },
		{ name = "native exception", readlink_throws = true },
		{ name = "extra readlink refusal status", executable = "/independent/native/bin/curl", readlink_extra_status = true },
		{ name = "relative image", executable = "bin/curl" },
		{ name = "literal zero", executable = "/independent/curl\0" },
		{ name = "line break", executable = "/independent/\ncurl" },
		{ name = "deleted image", executable = "/independent/curl (deleted)" },
		{ name = "wrapper interpreter", executable = "/usr/bin/dash" },
	}) do
		local vector = case
		helpers.it("retains ordinary routing without a new variable after " .. case.name, function()
			local capabilities = observe(vector)
			helpers.assert_eq(capabilities.proxy_used, false)
			helpers.assert_eq(capabilities.executable, nil)
			helpers.assert_eq(capabilities.executable_observation, nil)
		end)
	end
	for _, case in ipairs({
		{ name = "missing stat port", missing_stat = true },
		{ name = "refused stat", stat_refusal = true },
		{ name = "throwing stat", stat_throws = true },
		{ name = "extra native refusal status", stat_extra_status = true },
		{ name = "unsafe integer", unsafe_integer = true },
		{ name = "invalid nanoseconds", invalid_nanoseconds = true },
		{ name = "changed inode", changed_inode = true },
		{ name = "changed contents", changed_contents = true },
	}) do
		local vector = case
		helpers.it("does not bind a modern version to " .. case.name, function()
			vector.executable = "/independent/native/bin/curl"
			local capabilities = observe(vector)
			helpers.assert_eq(capabilities.proxy_used, false)
			helpers.assert_eq(capabilities.executable, nil)
			helpers.assert_eq(capabilities.executable_identity, nil)
		end)
	end
	helpers.it("retains an observed older executable without admitting the newer variable", function()
		local capabilities = observe({ executable = "/independent/native/bin/curl", version_line = "curl 7.88.1 (fixed-fixture)\n" })
		helpers.assert_eq(capabilities.version, "7.88.1")
		helpers.assert_eq(capabilities.executable, "/independent/native/bin/curl")
		helpers.assert_eq(capabilities.proxy_used, false)
	end)
	helpers.it("does not admit a failed version command even when its image was observed", function()
		local capabilities = observe({ executable = "/independent/native/bin/curl", exit_code = 17 })
		helpers.assert_eq(capabilities.proxy_used, false)
		helpers.assert_eq(capabilities.executable, nil)
	end)
	helpers.it("does not invent feature support from malformed version bytes", function()
		local capabilities = observe({ executable = "/independent/native/bin/curl", version_line = "unknown native version\n" })
		helpers.assert_eq(capabilities.proxy_used, false)
		helpers.assert_eq(capabilities.executable, nil)
	end)
end)
