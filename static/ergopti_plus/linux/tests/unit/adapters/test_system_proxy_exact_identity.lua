--- tests/unit/adapters/test_system_proxy_exact_identity.lua

--- ==============================================================================
--- MODULE: Test System Proxy Exact Identity
--- DESCRIPTION:
--- Preserves independent managed-network controls and actual production imports.
--- Source registration alone does not qualify native or installed behavior.
--- ==============================================================================

--- Executes the actual helper with independent native/stdio ports.
--- These are model receipts, not proof of a real child image or retirement.
local helpers = require("tests.helpers")
local Json = require("json")
local Paths = require("infra.paths")
local ExactPorts = require("tests.support.exact_identity_ports")
local helper = helpers.driver_root() .. "/platform/network/system_proxy_probe.lua"
local shared_root = assert(Paths.shared_root())

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
			if config.unsafe_inode then stat.ino = 9007199254740992 end
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
	local fd_state
	if config.exact then
		local native
		native, fd_state = ExactPorts.new(config.exact)
		for name, method in pairs(native) do
			if name ~= "fs_readlink" then uv[name] = method end
		end
	end
	state.fd_state = fd_state
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
	arg = { [1] = shared_root }
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

helpers.describe("helper exact uint64 native descriptor receipt", function()
	helpers.it("admits actual paired exact high inode without relaxing the legacy safe-integer guard", function()
		local capabilities, state = observe({ executable = "/independent/bin/curl", unsafe_inode = true, exact = {} })
		helpers.assert_true(capabilities.proxy_used)
		helpers.assert_eq(capabilities.executable, "/independent/bin/curl")
		helpers.assert_eq(capabilities.executable_observation, "owned-child")
		helpers.assert_nil(capabilities.executable_identity)
		helpers.assert_eq(capabilities.executable_identity_exact.inode_decimal, "9223372036855093009")
		helpers.assert_eq(#state.fd_state.opens, 4)
		helpers.assert_eq(#state.fd_state.closes, 4)
	end)
	for _, config in ipairs({ { planned_inode = "9223372036855093010" }, { no_eof = true },
		{ fail_method = "fs_close", fail_shape = "status" }, { fail_method = "fs_open", fail_shape = "error" } }) do
		local fixed = config
		helpers.it("withholds exact executable hint for failed or uncertain descriptor observation", function()
			local capabilities, state = observe({ executable = "/independent/bin/curl", unsafe_inode = true, exact = fixed })
			helpers.assert_eq(capabilities.proxy_used, false)
			helpers.assert_nil(capabilities.executable)
			helpers.assert_nil(capabilities.executable_identity)
			helpers.assert_nil(capabilities.executable_identity_exact)
			local seen = {}
			for _, fd in ipairs(state.fd_state.closes) do
				helpers.assert_nil(seen[fd], "No uncertain descriptor close is retried")
				seen[fd] = true
			end
		end)
	end
	helpers.it("preserves valid legacy observations without additional descriptor acquisition", function()
		local capabilities, state = observe({ executable = "/independent/bin/curl", exact = {} })
		helpers.assert_true(capabilities.proxy_used)
		helpers.assert_eq(capabilities.executable_identity.inode, 73)
		helpers.assert_nil(capabilities.executable_identity_exact)
		helpers.assert_eq(#state.fd_state.opens, 0)
	end)
end)
