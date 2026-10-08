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
	local state = { closes = {}, kills = {}, handles = {}, callbacks = {} }
	local uv = {}
	local function handle(kind)
		local value = { kind = kind, closed = false }
		state.handles[#state.handles + 1] = value
		return value
	end
	function uv.exepath() return "/independent/installed runtime/luajit" end
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

helpers.describe("system_proxy: exact native process ownership", function()
	helpers.it("uses private stdin and publishes only after exit and every close acknowledgement", function()
		local adapter, state = fresh()
		local operation, results = dispatch(adapter)
		helpers.assert_eq(state.program, "/independent/installed runtime/luajit")
		helpers.assert_true(state.options.detached)
		helpers.assert_eq(#state.options.args, 2)
		for _, value in ipairs(state.options.args) do
			helpers.assert_nil(value:find("private-token", 1, true))
		end
		helpers.assert_eq(Json.decode(state.input).url, "https://destination.invalid/private?token=private-token")
		helpers.assert_eq(state.timer.timeout, 317)
		state.input_finished()
		state.output(selection())
		state.completed()
		helpers.assert_eq(#results, 0)
		helpers.assert_true(adapter.is_owned("private-owner"))
		helpers.assert_true(not operation.is_settled())
		state.ack_closes()
		helpers.assert_eq(#results, 1)
		helpers.assert_eq(results[1].proxies, { "http://proxy.invalid:8123", "direct://" })
		helpers.assert_true(operation.is_settled())
		helpers.assert_true(not adapter.is_owned("private-owner"))
	end)

	helpers.it("cancellation suppresses completion and reserves the owner through physical exit", function()
		local adapter, state = fresh()
		local operation, results = dispatch(adapter)
		local settled = 0
		operation.on_settled(function() settled = settled + 1 end)
		helpers.assert_true(operation.cancel())
		helpers.assert_eq(state.kills, { { pid = -8173, signal = "sigterm" }, { pid = -8173, signal = "sigkill" } })
		state.ack_closes()
		helpers.assert_true(not operation.is_settled())
		local duplicate, err = adapter.lookup_owned("https://other.invalid/", { owner = "private-owner", timeout_ms = 317 }, function() end)
		helpers.assert_nil(duplicate)
		helpers.assert_eq(err, "proxy-owner-busy")
		state.output(selection())
		state.completed(137)
		state.ack_closes()
		helpers.assert_true(operation.is_settled())
		helpers.assert_eq(#results, 0)
		helpers.assert_eq(settled, 1)
	end)

	helpers.it("retains a refused exact close until the same native handle acknowledges retry", function()
		local adapter, state, config = fresh()
		local operation, results = dispatch(adapter)
		config.refused_handle = state.options.stdio[2]
		state.output(selection())
		state.completed()
		state.ack_closes()
		helpers.assert_true(not operation.is_settled())
		helpers.assert_eq(#results, 0)
		state.allow_close = true
		helpers.assert_true(not operation.retry_cleanup())
		state.ack_closes()
		helpers.assert_true(operation.is_settled())
		helpers.assert_eq(#results, 1)
	end)

	helpers.it("does not claim retirement when the native group signal refuses", function()
		local adapter, state = fresh({ refuse_kill = true })
		local operation, results = dispatch(adapter)
		helpers.assert_true(not operation.cancel())
		state.ack_closes()
		helpers.assert_true(not operation.is_settled())
		helpers.assert_true(adapter.is_owned("private-owner"))
		state.allow_kill = true
		helpers.assert_true(not operation.retry_cleanup())
		state.completed(137)
		state.ack_closes()
		helpers.assert_true(operation.is_settled())
		helpers.assert_eq(#results, 0)
	end)

	helpers.it("deadline failure is published only after physical exit and cannot expose native stderr", function()
		local adapter, state = fresh()
		local operation, results = dispatch(adapter)
		state.options.stdio[3].callback(nil, "private-token raw credential diagnostic")
		state.timer.callback()
		state.ack_closes()
		helpers.assert_eq(#results, 0)
		state.completed(137)
		state.ack_closes()
		helpers.assert_true(operation.is_settled())
		helpers.assert_eq(results, { { ok = false, error = "proxy-lookup-timeout" } })
	end)

	helpers.it("rejects malformed native selection instead of passing it to the downloader", function()
		local adapter, state = fresh()
		local operation, results = dispatch(adapter)
		state.output({ ok = true, proxies = { "http://proxy.invalid:81\nprivate-token" } })
		state.completed()
		state.ack_closes()
		helpers.assert_true(operation.is_settled())
		helpers.assert_eq(results, { { ok = false, error = "proxy-receipt-invalid" } })
	end)

	helpers.it("cleanup cannot accidentally cancel an active lookup", function()
		local adapter, state = fresh()
		local operation = dispatch(adapter)
		helpers.assert_true(not operation.retry_cleanup())
		helpers.assert_eq(#state.kills, 0)
		helpers.assert_eq(#state.closes, 0)
		operation.cancel()
		state.completed(137)
		state.ack_closes()
	end)

	helpers.it("cancelling after leader exit never signals a potentially reused process group", function()
		local adapter, state = fresh()
		local operation, results = dispatch(adapter)
		state.exit(0, 0)
		helpers.assert_true(not operation.is_settled())
		helpers.assert_true(operation.cancel())
		helpers.assert_eq(#state.kills, 0)
		helpers.assert_true(not operation.is_settled())
		state.ack_closes()
		helpers.assert_true(operation.is_settled())
		helpers.assert_eq(#results, 0)
	end)

	helpers.it("refuses the native timer error acknowledgement before continuing dispatch", function()
		local adapter, state = fresh({ refused_ack = "timer" })
		local operation, results = dispatch(adapter)
		helpers.assert_eq(state.kills, { { pid = -8173, signal = "sigterm" }, { pid = -8173, signal = "sigkill" } })
		helpers.assert_nil(state.options.stdio[2].callback)
		state.ack_closes()
		helpers.assert_true(not operation.is_settled())
		state.exit(137, 0)
		state.ack_closes()
		helpers.assert_eq(results, { { ok = false, error = "proxy-supervision-failed" } })
	end)

	for _, boundary in ipairs({ "timer", "read", "write", "shutdown" }) do
		local native_boundary = boundary
		helpers.it("requires a native " .. native_boundary .. " acknowledgement, not an empty successful Lua call", function()
			local adapter, state = fresh({ missing_ack = native_boundary })
			local operation, results = dispatch(adapter)
			if native_boundary == "shutdown" then state.write(nil) end
			helpers.assert_eq(state.kills, { { pid = -8173, signal = "sigterm" }, { pid = -8173, signal = "sigkill" } })
			state.ack_closes()
			helpers.assert_true(not operation.is_settled())
			state.exit(137, 0)
			state.ack_closes()
			local reason = (native_boundary == "timer" or native_boundary == "read")
				and "proxy-supervision-failed" or "proxy-input-failed"
			helpers.assert_eq(results, { { ok = false, error = reason } })
		end)
	end

	helpers.it("refuses an unavailable installation root before allocating any native resource", function()
		local adapter, state = fresh({ nil_driver_root = true })
		local returned, operation, err = pcall(adapter.lookup_owned, "https://destination.invalid/", {
			owner = "private-owner", timeout_ms = 317,
		}, function() error("must not publish") end)
		helpers.assert_true(returned)
		helpers.assert_nil(operation)
		helpers.assert_eq(err, "proxy-installation-incomplete")
		helpers.assert_eq(#state.handles, 0)
		helpers.assert_nil(state.options)
	end)

	helpers.it("refuses an oversized native proxy inventory", function()
		local adapter, state = fresh()
		local operation, results = dispatch(adapter)
		local receipt = selection()
		receipt.proxies = {}
		for index = 1, 129 do receipt.proxies[index] = "direct://" end
		state.output(receipt)
		state.completed()
		state.ack_closes()
		helpers.assert_true(operation.is_settled())
		helpers.assert_eq(results, { { ok = false, error = "proxy-receipt-invalid" } })
	end)

	helpers.it("refuses a malformed or unbounded native backend identity", function()
		for _, backend in ipairs({ string.rep("A", 129), "native\nprivate-token" }) do
			local adapter, state = fresh()
			local operation, results = dispatch(adapter)
			local receipt = selection()
			receipt.backend = backend
			state.output(receipt)
			state.completed()
			state.ack_closes()
			helpers.assert_true(operation.is_settled())
			helpers.assert_eq(results, { { ok = false, error = "proxy-receipt-invalid" } })
		end
	end)
end)

return helpers
