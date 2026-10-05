--- tests/unit/adapters/test_owned_process.lua

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

test("exit and native group absence still wait for every owned close ACK", function(owner, _, state)
	local callbacks, settled, result = 0, 0, nil
	-- Keep result assertions outside the product's protected callback boundary.
	local operation = owner.start("program", {}, { owner = "owner" }, function(value)
		callbacks, result = callbacks + 1, value
	end)
	assert(operation.started and not operation:is_settled())
	assert(operation:on_settled(function() settled = settled + 1 end))
	state.output("original bytes")
	state.absent = true
	state.finish(0)
	assert(not operation:is_settled() and callbacks == 0 and settled == 0)
	state.acknowledge()
	assert(operation:is_settled() and callbacks == 1 and settled == 1)
	assert(result and result.ok and result.stdout == "original bytes")
	operation:on_settled(function() settled = settled + 1 end)
	assert(settled == 2)
	state.acknowledge()
	assert(callbacks == 1 and settled == 2)
end)

test("accepted cancellation signals cannot release a successor", function(owner, _, state)
	local callbacks = 0
	local operation = owner.start("program", {}, { owner = "owner", timeout_ms = 1000 }, function() callbacks = callbacks + 1 end)
	assert(operation:cancel() == false and not operation:is_settled())
	local successor = owner.start("other", {}, { owner = "owner" }, function() end)
	assert(not successor.started and successor.error == "previous process cleanup pending")
	assert(state.spawns == 1)
	state.acknowledge()
	assert(not operation:is_settled(), "close ACKs cannot replace actual process exit")
	state.exit(0, 15)
	state.acknowledge()
	assert(not operation:is_settled(), "leader exit cannot replace group absence")
	state.absent = true
	assert(operation:cancel() == false, "cleanup timer still needs its native close ACK")
	state.acknowledge()
	assert(operation:is_settled() and operation:cancel() == true and callbacks == 0)
	local second = owner.start("other", {}, { owner = "owner" }, function() end)
	assert(second.started and state.spawns == 2)
	second:cancel()
	state.exit(0, 15)
	state.acknowledge()
end)

test("a leader with closed pipes cannot hide a remaining descendant group", function(owner, _, state)
	local callbacks, result = 0, nil
	local operation = owner.start("program", {}, { owner = "owner" }, function(value)
		callbacks, result = callbacks + 1, value
	end)
	state.finish(0)
	state.acknowledge()
	assert(not operation:is_settled() and callbacks == 0)
	state.absent = true
	for _, value in ipairs(state.handles) do
		if value.kind == "timer" and value.fire then value.fire() end
	end
	state.acknowledge()
	assert(operation:is_settled() and callbacks == 1)
	assert(result and not result.ok and result.error == "native process group outlived leader")
end)

test("a refused cleanup monitor can be rearmed by the exact owner", function(owner, native, state)
	local starts = 0
	local timer_start = native.timer_start
	function native.timer_start(handle, first, interval, callback)
		if handle == state.handles[3] then
			starts = starts + 1
			if starts == 1 then return false end
		end
		return timer_start(handle, first, interval, callback)
	end
	local operation = owner.start("program", {}, { owner = "owner" }, function() end)
	assert(operation:cancel() == false and starts == 1)
	assert(operation.cleanup_error == "native cleanup monitor refused")
	assert(operation:cancel() == false and starts == 2)
	state.exit(0, 15)
	state.acknowledge()
	assert(not operation:is_settled())
	state.absent = true
	state.handles[3].fire()
	state.acknowledge()
	assert(operation:is_settled())
end)

test("refused group termination remains exact debt and can be retried", function(owner, _, state)
	local operation = owner.start("program", {}, { owner = "owner" }, function() end)
	state.signal_mode = "refused"
	assert(operation:cancel() == false)
	assert(operation.cleanup_error == "native process group termination refused")
	state.acknowledge()
	assert(not operation:is_settled())
	state.signal_mode, state.absent = nil, true
	state.exit(0, 15)
	operation:cancel()
	state.acknowledge()
	assert(operation:is_settled())
end)

for _, mode in ipairs({ "refused", "malformed" }) do
	test(mode .. " close receipt does not become retirement", function(owner, _, state)
		local operation = owner.start("program", {}, { owner = "owner" }, function() end)
		state.close_mode, state.absent = mode, true
		state.finish(0)
		state.acknowledge()
		assert(not operation:is_settled())
		assert(operation.cleanup_error == "native handle close refused")
		state.close_mode = nil
		operation:cancel()
		state.acknowledge()
		assert(operation:is_settled())
	end)
end

test("partial allocation preserves its first handle until close acknowledgement", function(owner, native, state)
	local calls = 0
	local allocate = native.new_pipe
	function native.new_pipe()
		calls = calls + 1
		if calls == 2 then error("allocation refused") end
		return allocate()
	end
	local operation = owner.start("program", {}, { owner = "owner" }, function() end)
	assert(not operation.started and state.spawns == 0 and not operation:is_settled())
	assert(operation.error == "native handle allocation failed")
	state.acknowledge()
	assert(operation:is_settled())
end)

test("an unauthorized source allocates no native resources", function(owner, _, state)
	local operation = owner.start("program", {}, { owner = "owner", authorized = function() return false end }, function() end)
	assert(not operation.started and operation:is_settled() and #state.handles == 0 and state.spawns == 0)
end)

test("reentrant source admission cannot overwrite another exact operation", function(owner, _, state)
	local first, nested = true, nil
	local outer = owner.start("outer", {}, { owner = "owner", authorized = function()
		if first then
			first = false
			nested = owner.start("nested", {}, { owner = "owner" }, function() end)
		end
		return true
	end }, function() end)
	assert(nested and nested.started and not nested:is_settled())
	assert(not outer.started and outer:is_settled() and outer.error == "previous process cleanup pending")
	assert(state.spawns == 1 and state.executable == "nested")
	local blocked = owner.start("successor", {}, { owner = "owner" }, function() end)
	assert(not blocked.started and blocked.error == "previous process cleanup pending")
	assert(nested:cancel() == false)
	state.absent = true
	state.exit(0, 15)
	nested:cancel()
	state.acknowledge()
	assert(nested:is_settled())
	local successor = owner.start("successor", {}, { owner = "owner" }, function() end)
	assert(successor.started and state.spawns == 2)
	successor:cancel()
	state.exit(0, 15)
	state.acknowledge()
end)

test("source change during allocation refuses dispatch but retains native close debt", function(owner, native, state)
	local current = true
	local allocate = native.new_timer
	function native.new_timer() current = false return allocate() end
	local operation = owner.start("program", {}, { owner = "owner", authorized = function() return current end }, function() end)
	assert(not operation.started and state.spawns == 0 and not operation:is_settled())
	state.acknowledge()
	assert(operation:is_settled())
end)

test("source changes fence output and completion while retaining cleanup", function(owner, _, state)
	local current, outputs, completions = true, 0, 0
	local operation = owner.start("program", {}, { owner = "owner", authorized = function() return current end,
		on_output = function() outputs = outputs + 1 end }, function() completions = completions + 1 end)
	state.output("accepted")
	current = false
	state.output("stale")
	assert(outputs == 1 and completions == 0 and not operation:is_settled())
	state.absent = true
	state.exit(0, 15)
	operation:cancel()
	state.acknowledge()
	assert(operation:is_settled() and outputs == 1 and completions == 0)
end)

test("output bound preserves prior bytes and requires physical teardown", function(owner, _, state)
	local result
	local operation = owner.start("program", {}, { owner = "owner", max_output_bytes = 4 }, function(value) result = value end)
	state.output("four")
	state.output("overflow")
	assert(not operation:is_settled() and result == nil)
	state.absent = true
	state.exit(0, 9)
	state.acknowledge()
	assert(operation:is_settled() and result.error == "process output exceeds its bound" and result.stdout == "four")
end)

test("explicit daemon tail capture remains bounded without killing ordinary output", function(owner, _, state)
	local result, streamed = nil, ""
	local operation = owner.start("program", {}, { owner = "owner", max_output_bytes = 4,
		capture_tail = true, on_output = function(chunk) streamed = streamed .. chunk end },
		function(value) result = value end)
	state.output("first")
	state.output("last")
	assert(not operation:is_settled() and result == nil and #state.kills == 0)
	assert(streamed == "firstlast")
	state.absent = true
	state.finish(0)
	state.acknowledge()
	assert(operation:is_settled() and result and result.ok and result.stdout == "last")
end)

test("malformed tail capture refuses before native allocation", function(owner, _, state)
	local operation = owner.start("program", {}, { owner = "owner", capture_tail = "true" }, function() end)
	assert(not operation.started and operation:is_settled() and operation.error == "invalid output capture policy")
	assert(state.spawns == 0 and #state.handles == 0)
end)

test("malformed argv refuses before allocation and cannot be silently truncated", function(owner, _, state)
	for _, argv in ipairs({ { "bad\0argument" }, { 123 }, { [2] = "sparse" }, { foreign = "key" } }) do
		local operation = owner.start("program", argv, { owner = "owner" }, function() end)
		assert(not operation.started and operation:is_settled() and state.spawns == 0 and #state.handles == 0)
	end
end)

test("native spawn refusal waits for handles and completes exactly once", function(owner, _, state)
	state.spawn_mode = "refused"
	local callbacks, result = 0, nil
	local operation = owner.start("missing", {}, { owner = "owner" }, function(value)
		callbacks, result = callbacks + 1, value
	end)
	assert(not operation.started and not operation:is_settled() and callbacks == 0)
	state.acknowledge()
	assert(operation:is_settled() and callbacks == 1)
	assert(result and not result.ok and result.error == "native process dispatch failed")
end)
