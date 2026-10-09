--- tests/unit/adapters/test_owned_process_running.lua

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

test("native running proof excludes known exit while exact close debt remains", function(owner, _, state)
	local callbacks = 0
	local op = owner.start("fixture", {}, { owner = "running-exit" }, function() callbacks = callbacks + 1 end)
	assert(op.started and op:is_running())
	state.absent = true; state.finish(0)
	assert(not op:is_settled() and not op:is_running() and callbacks == 0, "known exit is not running even before close ACKs")
	state.acknowledge(); assert(op:is_settled() and not op:is_running() and callbacks == 1)
end)
test("native running proof excludes terminal output failure with live process debt", function(owner, _, state)
	local op = owner.start("fixture", {}, { owner = "running-terminal", max_output_bytes = 4 }, function() end)
	assert(op:is_running()); state.output("overflow")
	assert(not op:is_running() and not op:is_settled(), "terminal failure cannot masquerade as healthy service")
	state.absent = true; state.finish(0); state.acknowledge(); assert(op:is_settled())
end)
test("native running proof excludes cancelled process despite refused termination", function(owner, _, state)
	local op = owner.start("fixture", {}, { owner = "running-cancel" }, function() end)
	state.signal_mode = "refused"; assert(op:cancel() == false)
	assert(not op:is_running() and not op:is_settled(), "cancellation is not running or physical settlement")
	state.signal_mode, state.absent = nil, true; state.finish(0); state.acknowledge()
	assert(op:is_settled())
end)
test("native running proof rechecks exit occurring inside source callback", function(owner, _, state)
	local armed = false
	local op = owner.start("fixture", {}, { owner = "running-source-exit", authorized = function()
		if armed then armed = false; state.absent = true; state.finish(0) end
		return true
	end }, function() end)
	assert(op:is_running()); armed = true
	assert(not op:is_running() and not op:is_settled(), "late source acknowledgement cannot lend running authority to exited child")
	state.acknowledge(); assert(op:is_settled())
end)
test("native running proof rechecks cancellation occurring inside source callback", function(owner, _, state)
	local op, armed
	op = owner.start("fixture", {}, { owner = "running-source-cancel", authorized = function()
		if armed then armed = false; op:cancel() end
		return true
	end }, function() end)
	assert(op:is_running()); armed = true
	assert(not op:is_running() and not op:is_settled(), "source callback cannot return stale running authority")
	state.absent = true; state.finish(0); state.acknowledge()
end)
test("native running proof requires source truth and suppresses source exceptions", function(owner, _, state)
	local mode = "live"
	local op = owner.start("fixture", {}, { owner = "running-source", authorized = function()
		if mode == "throw" then error("independent source exception") end
		return mode == "live"
	end }, function() end)
	assert(op:is_running()); mode = "stale"; assert(not op:is_running())
	mode = "throw"; assert(not op:is_running() and not op:is_settled())
	op:cancel(); state.absent = true; state.finish(0); state.acknowledge()
end)
test("missing native dispatch cannot manufacture a running process", function(owner, _, state)
	state.spawn_mode = "refused"
	local op = owner.start("fixture", {}, { owner = "running-missing" }, function() end)
	assert(not op.started and not op:is_running())
	state.acknowledge(); assert(op:is_settled() and not op:is_running())
end)
