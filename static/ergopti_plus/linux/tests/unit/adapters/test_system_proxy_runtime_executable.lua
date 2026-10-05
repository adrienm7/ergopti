--- tests/unit/adapters/test_system_proxy_runtime_executable.lua

--- tests/unit/adapters/test_system_proxy.lua

--- ==============================================================================
--- MODULE: Native System Proxy Ownership Controls (Linux)
--- DESCRIPTION:
--- Independent libuv controls exercise private stdin delivery, process exit,
--- close acknowledgements, cancellation, refused retirement and stale events.
--- Actual GIO/PAC selection belongs to the separate native loopback fixture.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local SOURCE = helpers.driver_root() .. "/adapters/system_proxy.lua"

--- Loads the candidate with independent controllable native acknowledgements.
--- @param config table|nil
--- @return table adapter, table state
local function fresh(config)
	config = config or {}
	local state = { closes = {}, kills = {}, handles = {}, callbacks = {}, exepath_calls = 0 }
	local uv = {}
	local function handle(kind)
		local value = { kind = kind, closed = false }
		state.handles[#state.handles + 1] = value
		return value
	end
	function uv.exepath()
		state.exepath_calls = state.exepath_calls + 1
		if config.exepath_throws then error("private native failure") end
		if config.exepath_nil then return nil end
		if config.exepath_error then return "/synthetic/runtime/luajit", "EINVAL" end
		return config.exepath_value or "/synthetic/runtime/luajit"
	end
	if config.exepath_missing then uv.exepath = nil end
	function uv.update_time() end
	function uv.new_pipe() return handle("pipe") end
	function uv.new_timer() state.timer = handle("timer"); return state.timer end
	function uv.is_closing(value) return value.closing or value.closed end
	function uv.close(value, callback)
		if value == config.refused_handle and not state.allow_close then return nil, "close refused" end
		value.closing = true
		state.closes[#state.closes + 1] = { handle = value, callback = callback }
		return 0
	end
	function uv.timer_start(timer, timeout, repeat_ms, callback)
		timer.timeout, timer.callback = timeout, callback
		if config.refused_ack == "timer" then return nil, "EINVAL" end
		if config.missing_ack == "timer" then return nil end
		return 0
	end
	function uv.timer_stop() return 0 end
	function uv.read_start(pipe, callback)
		pipe.callback = callback
		if config.refused_ack == "read" then return nil, "EINVAL" end
		if config.missing_ack == "read" then return nil end
		return 0
	end
	function uv.read_stop() return 0 end
	function uv.kill(pid, signal)
		state.kills[#state.kills + 1] = { pid = pid, signal = signal }
		if config.refuse_kill and not state.allow_kill then return nil, "permission refused", "EPERM" end
		return 0
	end
	function uv.spawn(program, options, callback)
		state.program, state.options, state.exit = program, options, callback
		return handle("process"), 8173
	end
	function uv.write(pipe, input, callback)
		state.input, state.write = input, callback
		if config.refused_ack == "write" then return nil, "EINVAL" end
		if config.missing_ack == "write" then return nil end
		return 0
	end
	function uv.shutdown(pipe, callback)
		state.shutdown = callback
		if config.refused_ack == "shutdown" then return nil, "EINVAL" end
		if config.missing_ack == "shutdown" then return nil end
		return 0
	end
	function state.ack_closes()
		while #state.closes > 0 do
			local close = table.remove(state.closes, 1)
			close.handle.closing, close.handle.closed = false, true
			close.callback()
		end
	end
	function state.input_finished()
		state.write(nil)
		state.shutdown(nil)
	end
	function state.output(receipt)
		state.options.stdio[2].callback(nil, Json.encode(receipt))
	end
	function state.completed(code)
		state.options.stdio[2].callback(nil, nil)
		state.options.stdio[3].callback(nil, nil)
		state.exit(code or 0, 0)
	end
	local saved = package.loaded.luv
	local saved_paths = package.loaded["infra.paths"]
	local ok, adapter = pcall(function()
	if config.nil_driver_root then
		package.loaded["infra.paths"] = {
			driver_root = function() return nil end,
			shared_root = function() return "/private/shared" end,
		}
	end
	package.loaded.luv = uv
	return dofile(SOURCE)
	end)
	package.loaded.luv = saved
	package.loaded["infra.paths"] = saved_paths
	if not ok then error(adapter, 0) end
	return adapter, state, config
end

--- Supplies an independent native acknowledgement packet.
--- @return table
local function selection()
	return {
		ok = true, proxies = { "http://proxy.invalid:8123", "direct://" },
		backend = "GLibproxyResolver", acknowledgement = "native-selection", failure_provenance = "unavailable",
	}
end

--- Dispatches a private request and captures actual completion publication.
--- @param adapter table
--- @return table operation, table results
local function dispatch(adapter)
	local results = {}
	local operation, err = adapter.lookup_owned("https://destination.invalid/private?token=private-token", {
		owner = "private-owner", timeout_ms = 317,
	}, function(receipt) results[#results + 1] = receipt end)
	helpers.assert_nil(err)
	helpers.assert_not_nil(operation)
	return operation, results
end

helpers.describe("system_proxy: actual runtime executable admission", function()
	local cases = {
		{ name = "missing native port", config = { exepath_missing = true } },
		{ name = "throwing native port", config = { exepath_throws = true } },
		{ name = "missing native receipt", config = { exepath_nil = true } },
		{ name = "relative native receipt", config = { exepath_value = "relative/luajit" } },
		{ name = "empty native receipt", config = { exepath_value = "" } },
		{ name = "NUL native receipt", config = { exepath_value = "/private/runtime\0suffix" } },
		{ name = "path plus native error", config = { exepath_error = true } },
	}
	for _, case in ipairs(cases) do
		local current = case
		helpers.it("refuses " .. case.name .. " before resources or owner admission", function()
			local adapter, state = fresh(current.config)
			local replies = {}
			local operation, err = adapter.lookup_owned("https://destination.invalid/private", {
				owner = "executable-owner", timeout_ms = 1000,
			}, function(receipt) replies[#replies + 1] = receipt end)
			local handles, kills, program, owned = #state.handles, #state.kills, state.program, adapter.is_owned("executable-owner")
			-- Retire baseline fake resources without erasing captured side effects.
			if operation then state.input_finished(); state.output(selection()); state.completed(); state.ack_closes() end
			helpers.assert_nil(operation)
			helpers.assert_eq(err, "proxy-runtime-unavailable")
			helpers.assert_eq(handles, 0)
			helpers.assert_eq(kills, 0)
			helpers.assert_nil(program)
			helpers.assert_true(not owned)
			helpers.assert_eq(#replies, 0)
		end)
	end
	for index, path in ipairs({ "/synthetic/runtime/luajit", "/synthetic moved/runtime\nfolder/luajit" }) do
		local current_path = path
		helpers.it("spawns exact absolute native executable receipt " .. index .. " without PATH reinterpretation", function()
			local adapter, state = fresh({ exepath_value = current_path })
			local operation, results = dispatch(adapter)
			local program, calls = state.program, state.exepath_calls
			state.input_finished(); state.output(selection()); state.completed()
			helpers.assert_true(not operation.is_settled())
			helpers.assert_eq(#results, 0)
			state.ack_closes()
			helpers.assert_eq(program, current_path)
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(#results, 1)
			helpers.assert_true(operation.is_settled())
		end)
	end
end)

return helpers
