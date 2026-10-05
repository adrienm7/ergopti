--- tests/unit/adapters/test_owned_process_close_attempts.lua

local helpers = require("tests.helpers")

--- Creates a controllable native backend with independently acknowledged handles.
--- @return table native
--- @return table state
local function backend()
	local state = { handles = {}, spawns = 0, kills = {}, absent = false }
	local native = {}
	local function handle(kind)
		local value = { kind = kind, closing = false }
		state.handles[#state.handles + 1] = value
		return value
	end
	function native.new_pipe() return handle("pipe") end
	function native.new_timer() return handle("timer") end
	function native.is_closing(value) return value.closing end
	function native.read_start(value, callback) value.read = callback return 0 end
	function native.read_stop(value) value.read_stopped = true return 0 end
	function native.timer_start(value, _, _, callback) value.fire = callback return 0 end
	function native.timer_stop(value) value.timer_stopped = true return 0 end
	function native.close(value, callback)
		if state.close_mode == "refused" then return false end
		if state.close_mode == "malformed" then return nil end
		value.closing, value.close_ack = true, callback
		return 0
	end
	function native.spawn(executable, options, callback)
		state.spawns = state.spawns + 1
		state.executable, state.options, state.exit = executable, options, callback
		if state.spawn_mode == "refused" then return nil, "ENOENT", "ENOENT" end
		state.process = handle("process")
		return state.process, 8001
	end
	function native.kill(pid, signal)
		state.kills[#state.kills + 1] = { pid = pid, signal = signal }
		if state.signal_mode == "refused" then return nil, "EPERM", "EPERM" end
		if state.absent then return nil, "ESRCH", "ESRCH" end
		return 0
	end
	function state.acknowledge()
		for _, value in ipairs(state.handles) do
			if value.close_ack and not value.closed then
				value.closed = true
				value.close_ack()
			end
		end
	end
	function state.output(text, kind) state.options.stdio[kind == "stderr" and 3 or 2].read(nil, text) end
	function state.finish(code)
		state.output(nil)
		state.output(nil, "stderr")
		state.exit(code or 0, 0)
	end
	return native, state
end

--- Loads the scratch production module without replacing repository files.
--- @param native table
--- @return table
local function load(native)
	-- ShellRunner captures both luv and its monotonic clock at module load.
	-- Restore exact prior owners, including absent/false caches, on every path.
	local scoped = { "adapters.owned_process", "adapters.shell_runner", "infra.monotonic" }
	local previous = {}
	for _, name in ipairs(scoped) do
		previous[name] = package.loaded[name]
		package.loaded[name] = nil
	end
	local ok, owner = pcall(helpers.load_module_with_dependency,
		"adapters.owned_process", "luv", native)
	for _, name in ipairs(scoped) do package.loaded[name] = previous[name] end
	if not ok then error(owner, 0) end
	return owner
end

--- Runs one independent regression with a fresh native owner.
--- @param name string
--- @param check function
local function test(name, check)
	helpers.it(name, function()
		local native, state = backend()
		check(load(native), native, state)
	end)
end

for _, mode in ipairs({ "false", "nil-error", "exception" }) do
	for _, timing in ipairs({ "sync", "delayed" }) do
		test("rejected " .. mode .. " " .. timing .. " close cannot settle or borrow fresh admission", function(owner, native, state)
			local attempts, rejecting, callbacks, retired = {}, true, 0, 0
			function native.close(handle, callback)
				local item = { handle = handle, callback = callback, rejected = rejecting }
				attempts[#attempts + 1] = item
				if rejecting then
					if timing == "sync" then callback() end
					if mode == "exception" then error("independent close exception") end
					if mode == "nil-error" then return nil, "independent close error" end
					return false
				end
				handle.closing = true
				return 0
			end
			local operation = owner.start("fixture", {}, { owner = "close-attempt", timeout_ms = 1000 }, function() callbacks = callbacks + 1 end)
			operation:on_settled(function() retired = retired + 1 end)
			state.absent = true; state.finish(0)
			assert(#attempts >= 4, "independent rejected native calls must occur")
			assert(not operation:is_settled() and callbacks == 0 and retired == 0, "rejected synchronous close callback is not retirement")
			local rejected_count = #attempts
			for index = 1, rejected_count do attempts[index].callback() end
			assert(not operation:is_settled() and callbacks == 0 and retired == 0, "rejected delayed callback has no authority")
			rejecting = false; operation:cancel()
			assert(#attempts > rejected_count and not operation:is_settled(), "public cleanup retry still requires each fresh ACK")
			for index = 1, rejected_count do attempts[index].callback() end
			assert(not operation:is_settled() and retired == 0, "old attempt cannot borrow freshly accepted close")
			for index = rejected_count + 1, #attempts do attempts[index].callback() end
			assert(operation:is_settled() and retired == 1 and callbacks == 0, "exact fresh ACKs retire cancelled native operation once")
			local successor = owner.start("fixture", {}, { owner = "close-attempt", timeout_ms = 1000 }, function() callbacks = callbacks + 1 end)
			assert(successor.started and not successor:is_settled(), "actual retirement releases successor")
			for index = 1, #attempts do attempts[index].callback() end
			assert(not successor:is_settled() and retired == 1, "old exact callbacks cannot retire successor")
			local offset = #attempts; state.finish(0)
			for index = offset + 1, #attempts do attempts[index].callback() end
			assert(successor:is_settled() and callbacks == 1, "successor retires only its own attempts")
		end)
	end
end
test("accepted synchronous native close ACK retires without a lost callback", function(owner, native, state)
	local callbacks = 0
	function native.close(handle, callback) handle.closing = true; callback(); return 0 end
	local operation = owner.start("fixture", {}, { owner = "sync-close", timeout_ms = 1000 }, function() callbacks = callbacks + 1 end)
	state.absent = true; state.finish(0)
	assert(operation:is_settled() and callbacks == 1, "same-call synchronous accepted ACK must qualify")
end)
test("nil close needs independent native closing transition and exact ACK", function(owner, native, state)
	local callbacks, attempts = 0, {}
	function native.close(handle, callback)
		handle.closing = true; attempts[#attempts + 1] = callback; return nil
	end
	local operation = owner.start("fixture", {}, { owner = "nil-native-close" }, function() callbacks = callbacks + 1 end)
	state.absent = true; state.finish(0)
	assert(not operation:is_settled() and callbacks == 0, "native closing transition does not replace physical ACK")
	for _, callback in ipairs(attempts) do callback() end
	assert(operation:is_settled() and callbacks == 1, "real nil ABI plus all exact ACKs settles")
end)
test("nil close without native transition cannot borrow synchronous ACK", function(owner, native, state)
	local callbacks = 0
	function native.close(_, callback) callback(); return nil end
	local operation = owner.start("fixture", {}, { owner = "nil-refused-close" }, function() callbacks = callbacks + 1 end)
	state.absent = true; state.finish(0)
	assert(not operation:is_settled() and callbacks == 0, "nil requires independent native transition")
	function native.close(handle, callback) handle.closing = true; callback(); return nil end
	operation:cancel(); assert(operation:is_settled() and callbacks == 0, "fresh actual transition plus own ACK settles cancellation")
end)
