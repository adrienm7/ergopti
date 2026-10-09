--- tools/test/native_python_probe_test.lua
--- Controlled exact task/timer receiving; no native Hammerspoon execution credit.
local source = debug.getinfo(1, "S").source:sub(2)
local root = assert(source:match("^(.*)/tools/test/native_python_probe_test%.lua$"))
local repository = arg[1] or root
package.loaded["infra.logger"] = { error = function() end }
local Parser = assert(loadfile(repository .. "/static/ergopti_plus/macos/adapters/python_interpreter.lua"))()
local locator = assert(loadfile(root .. "/static/ergopti_plus/_shared/lua/core/llm/managed_python_locator.lua"))()
local cases, assertions = 0, 0
local function check(value, expected, label)
	assert(value == expected, label or "private Python receiving assertion"); assertions = assertions + 1
end
local function count(table_value) local total = 0; for _ in pairs(table_value) do total = total + 1 end; return total end
local ARM = "cf fa ed fe 0c 00 00 01"
local INTEL = "cf fa ed fe 07 00 00 01"
local function with_case(options, callback)
	options = options or {}
	local fixture = { clock = 1, tasks = {}, timers = {}, system = nil, inode = 2,
		header = options.header or ARM, stop = options.timer_stop ~= false, path = nil }
	local prefix = assert(os.getenv("HOME")):gsub("/+$", "")
		.. "/Library/Application Support/Ergopti/native-bootstrap/python/"
	fixture.expected = prefix .. "cpython-3.11.16-macos-aarch64-none/bin/python3.11"
	package.loaded["adapters.python_interpreter"] = { parse_header = Parser.parse_header,
		resolve = function()
			fixture.clock = fixture.clock + (options.system_delay or 0)
			return fixture.system
		end }
	package.loaded["core.llm.managed_python_locator"] = locator
	package.loaded["modules.llm.bootstrap_retry_generated"] = { admission_seconds = 30, idle_seconds = 60, retirement_seconds = 600 }
	package.loaded["infra.logger"] = { error = function() end }
	package.loaded["adapters.file_system"] = {
		read_with_status = function() error("GUI catalogue byte reads are forbidden") end,
		classify_no_follow = function()
			if not fixture.snapshot_delayed then
				fixture.snapshot_delayed = true
				fixture.clock = fixture.clock + (options.snapshot_delay or 0)
			end
			return {
			mode = options.mode or "file", permissions = options.permissions or "rwxr-xr-x",
			dev = 1, ino = fixture.inode, size = 4096, modification = 1, change = 1,
		}, "ok" end,
	}
	_G.hs = { processInfo = { arch = "arm64" }, fs = { pathToAbsolute = function(path) return fixture.path or path end } }
	package.loaded["adapters.shell_runner"] = { spawn = function(executable, arguments, done)
		check(executable, "/usr/bin/od")
		check(table.concat(arguments, "\0"), table.concat({ "-An", "-v", "-N", "4096", "-t", "x1", fixture.expected }, "\0"))
		local task = { done = done, closed = false, observers = {}, starts = 0, terminations = 0 }
		fixture.tasks[#fixture.tasks + 1] = task
		function task.onSettled(observer)
			if options.task_observer_refused then return false end
			task.observers[#task.observers + 1] = observer
			if task.closed then observer() end
			return true
		end
		function task.isSettled() return task.closed end
		function task.start()
			task.starts = task.starts + 1
			if options.reentrant_done then
				task.done(0, fixture.header, "")
				task.closed = true
				for _, observer in ipairs(task.observers) do observer() end
			end
			return options.start_result ~= false
		end
		function task.terminate()
			task.terminations = task.terminations + 1
			return fixture.termination_result ~= false
		end
		fixture.clock = fixture.clock + (options.constructor_delay or 0)
		return task
	end }
	package.loaded["adapters.task_lifecycle"] = { start = function(task) return task.start() end,
		terminate = function(task) return task.terminate() end }
	package.loaded["adapters.timer_scheduler"] = {
		now_ns = function()
			if options.clock_refused_once and not fixture.clock_refused then
				fixture.clock_refused = true; return nil
			end
			return fixture.clock * 1e9
		end,
		after = function(delay, done)
			local timer = { timer = {}, delay = delay, done = done, observers = {}, cancellations = 0 }
			fixture.timers[#fixture.timers + 1] = timer
			if options.timer_reentrant then done() end
			fixture.clock = fixture.clock + (options.timer_delay or 0)
			return timer, options.timer_commit ~= false
		end,
		onSettled = function(timer, observer)
			if options.timer_observer_refused then return false end
			timer.observers[#timer.observers + 1] = observer
			return true
		end,
		cancel = function(timer)
			timer.cancellations = timer.cancellations + 1
			if not fixture.stop then return false end
			timer.timer = nil
			if options.stop_advances_clock then fixture.clock = 100 end
			local observers = timer.observers; timer.observers = {}
			for _, observer in ipairs(observers) do observer() end
			return true
		end,
	}
	fixture.probe = assert(loadfile(root .. "/static/ergopti_plus/macos/adapters/native_python_probe.lua"))()
	package.loaded["adapters.native_python_probe"] = fixture.probe
	fixture.provider = assert(loadfile(root .. "/static/ergopti_plus/macos/modules/llm/managed_native_python.lua"))()
	function fixture.finish(status, closed, stderr)
		local task = assert(fixture.tasks[1])
		task.done(status or 0, fixture.header, stderr or "")
		if closed then fixture.close() end
	end
	function fixture.close()
		local task = assert(fixture.tasks[1]); task.closed = true
		for _, observer in ipairs(task.observers) do observer() end
	end
	local real_open = io.open
	io.open = function() error("GUI binary bytes are forbidden") end
	local ok, result = xpcall(function() callback(fixture) end, debug.traceback)
	io.open = real_open
	if not ok then error(result, 0) end
	cases = cases + 1
end

with_case({}, function(f)
	local path, state = f.provider.resolve(2)
	check(path, nil); check(state, "pending"); check(#f.tasks, 1); check(#f.timers, 1)
	check(f.timers[1].delay, 2); check(count(f.probe._active_tasks), 2)
	f.provider.resolve(29); check(#f.tasks, 1); check(f.timers[1].delay, 2)
	f.finish(0, false); check(f.provider.resolve(29), nil); check(count(f.probe._active_tasks), 2)
	f.close(); check(f.provider.resolve(1), f.expected); check(count(f.probe._active_tasks), 0)
end)

with_case({ timer_stop = false }, function(f)
	check(f.provider.resolve(), nil); f.finish(0, true)
	local path, state = f.provider.resolve(); check(path, nil); check(state, "pending")
	check(count(f.probe._active_tasks), 2)
	f.stop = true; check(f.provider.resolve(), f.expected); check(count(f.probe._active_tasks), 0)
end)

for _, bytes in ipairs({ INTEL, "23 21 2f 62 69 6e 2f 73 68", "cf fa", "cf zz", string.rep("cf ", 4097) }) do
	with_case({ header = bytes }, function(f)
		check(f.provider.resolve(), nil); f.finish(0, false)
		f.tasks[1].closed = true
		check(f.provider.resolve(), nil); check(#f.tasks, 1); check(count(f.probe._active_tasks), 0)
	end)
end

with_case({}, function(f)
	f.path = "/foreign/python"; check(f.provider.resolve(), nil); check(#f.tasks, 0)
end)
with_case({}, function(f)
	f.path = f.expected:gsub("cpython%-3%.11%.16", "cpython-3.11.17")
	check(f.provider.resolve(), nil); check(#f.tasks, 0)
end)
with_case({ mode = "named pipe" }, function(f) check(f.provider.resolve(), nil); check(#f.tasks, 0) end)
with_case({}, function(f)
	check(f.provider.resolve(), nil); f.inode = 3; f.finish(0, false); f.tasks[1].closed = true
	check(f.provider.resolve(), nil); check(#f.tasks, 1); check(count(f.probe._active_tasks), 0)
end)
with_case({}, function(f)
	local _, state = f.provider.resolve(2); check(state, "pending")
	f.clock = 4; f.provider.resolve(29)
	check(f.tasks[1].terminations, 1); check(count(f.probe._active_tasks), 2)
	f.finish(0, false); f.tasks[1].closed = true
	check(f.provider.resolve(29), nil); check(#f.tasks, 1); check(count(f.probe._active_tasks), 0)
end)
with_case({}, function(f)
	check(f.provider.resolve(), nil)
	f.timers[1].done(); check(f.tasks[1].terminations, 1); check(count(f.probe._active_tasks), 2)
	check(f.provider.cancel(), false); f.close(); check(f.provider.cancel(), true)
	check(count(f.probe._active_tasks), 0)
end)
with_case({}, function(f)
	check(f.provider.resolve(), nil); f.termination_result = false
	check(f.provider.cancel(), false); check(f.tasks[1].terminations, 1)
	f.termination_result = true; check(f.provider.cancel(), false); check(f.tasks[1].terminations, 2)
	check(count(f.probe._active_tasks), 2); f.close(); check(f.provider.cancel(), true)
end)
for _, options in ipairs({ { start_result = false, reentrant_done = true }, { timer_commit = false },
	{ task_observer_refused = true }, { timer_observer_refused = true }, { timer_reentrant = true } }) do
	with_case(options, function(f)
		check(f.provider.resolve(), nil)
		if options.start_result == nil then check(f.tasks[1].starts, 0) end
		f.close(); check(f.provider.cancel(), true); check(count(f.probe._active_tasks), 0)
	end)
end
with_case({ reentrant_done = true }, function(f)
	check(f.provider.resolve(), f.expected); check(f.tasks[1].starts, 1)
	check(count(f.probe._active_tasks), 0)
end)
with_case({ stop_advances_clock = true }, function(f)
	check(f.provider.resolve(), nil); f.finish(0, false); f.tasks[1].closed = true
	check(f.provider.resolve(), nil); check(#f.tasks, 1); check(count(f.probe._active_tasks), 0)
end)
with_case({}, function(f)
	check(f.provider.resolve(), nil); f.system = "/actual/native/system/python"
	local path, state = f.provider.resolve(); check(path, nil); check(state, "pending")
	check(f.tasks[1].terminations, 1); f.close(); check(f.provider.resolve(), f.system)
	check(count(f.probe._active_tasks), 0)
end)
with_case({}, function(f)
	check(f.provider.resolve(0), nil); check(f.provider.resolve(-1), nil); check(#f.tasks, 0)
end)
with_case({}, function(f)
	local delivered = 0
	check(f.provider.resolve(), nil); check(f.provider.onSettled(function() delivered = delivered + 1 end), true)
	f.finish(0, false); check(delivered, 0); f.close(); check(delivered, 1)
	check(f.provider.onSettled(function() delivered = delivered + 1 end), true); check(delivered, 2)
end)

with_case({ header = INTEL }, function(f)
	local delivered, result, state = 0, false, false
	check(f.provider.resolve(2), nil)
	check(f.provider.onSettled(function()
		delivered = delivered + 1
		result, state = f.provider.resolve(1)
	end), true)
	f.finish(0, true)
	check(delivered, 1); check(result, nil); check(state, nil)
	check(#f.tasks, 1); check(count(f.probe._active_tasks), 0)
	local path, repeated = f.provider.resolve(1)
	check(path, nil); check(repeated, nil); check(#f.tasks, 1)
end)
with_case({ header = INTEL }, function(f)
	check(f.provider.resolve(), nil); f.finish(0, true)
	check(f.provider.resolve(), nil); check(#f.tasks, 1)
	check(f.provider.cancel(), true)
	local path, state = f.provider.resolve(1)
	check(path, nil); check(state, "pending"); check(#f.tasks, 2)
end)
with_case({ header = INTEL }, function(f)
	check(f.provider.resolve(), nil); f.finish(0, true)
	check(f.provider.resolve(), nil); check(#f.tasks, 1)
	f.inode = 3
	local path, state = f.provider.resolve(1)
	check(path, nil); check(state, "pending"); check(#f.tasks, 2)
end)

for _, refused in ipairs({ { status = 1, stderr = "native OD read refused" },
	{ status = 0, stderr = "unexpected native warning" } }) do
	with_case({}, function(f)
		local delivered, path, state = 0, false, false
		check(f.provider.resolve(2), nil)
		check(f.provider.onSettled(function()
			delivered = delivered + 1
			path, state = f.provider.resolve(1)
		end), true)
		f.finish(refused.status, true, refused.stderr)
		check(delivered, 1); check(path, nil); check(state, nil)
		check(#f.tasks, 1); check(count(f.probe._active_tasks), 0)
		check(f.provider.resolve(1), nil); check(#f.tasks, 1)
	end)
end

for _, bytes in ipairs({ "cf zz", "cf fa", "23 21 2f 62 69 6e 2f 73 68", string.rep("cf ", 4097) }) do
	with_case({ header = bytes }, function(f)
		local delivered, path, state = 0, false, false
		check(f.provider.resolve(2), nil)
		check(f.provider.onSettled(function()
			delivered = delivered + 1
			path, state = f.provider.resolve(1)
		end), true)
		f.finish(0, true)
		check(delivered, 1); check(path, nil); check(state, nil)
		check(#f.tasks, 1); check(count(f.probe._active_tasks), 0)
		check(f.provider.resolve(1), nil); check(#f.tasks, 1)
	end)
end
with_case({}, function(f)
	local delivered, path, state = 0, false, false
	check(f.provider.resolve(2), nil)
	check(f.provider.onSettled(function()
		delivered = delivered + 1
		-- Restoring the original witnessed path cannot renew a denied attempt.
		f.path = nil
		path, state = f.provider.resolve(1)
	end), true)
	f.path = "/foreign/python"; f.finish(0, true)
	check(delivered, 1); check(path, nil); check(state, nil)
	check(#f.tasks, 1); check(count(f.probe._active_tasks), 0)
	check(f.provider.resolve(1), nil); check(#f.tasks, 1)
end)

with_case({ snapshot_delay = 3 }, function(f)
	local path, state = f.provider.resolve(2)
	check(path, nil); check(state, nil); check(f.clock, 4)
	check(#f.tasks, 0); check(#f.timers, 0)
end)
with_case({ snapshot_delay = 1 }, function(f)
	local path, state = f.provider.resolve(2)
	check(path, nil); check(state, "pending"); check(f.timers[1].delay, 1)
	check(f.tasks[1].starts, 1); f.close(); check(f.provider.cancel(), true)
end)
with_case({ system_delay = 3 }, function(f)
	local path, state = f.provider.resolve(2)
	check(path, nil); check(state, nil); check(f.clock, 4)
	check(#f.tasks, 0); check(#f.timers, 0)
end)
with_case({ system_delay = 1, snapshot_delay = 0.5 }, function(f)
	local path, state = f.provider.resolve(2)
	check(path, nil); check(state, "pending"); check(f.timers[1].delay, 0.5)
	check(f.tasks[1].starts, 1); f.close(); check(f.provider.cancel(), true)
end)
with_case({ constructor_delay = 3 }, function(f)
	local path, state = f.provider.resolve(2)
	check(path, nil); check(state, "pending"); check(#f.tasks, 1); check(#f.timers, 0)
	check(f.tasks[1].starts, 0); check(f.tasks[1].terminations, 1)
	check(count(f.probe._active_tasks), 1); f.close(); check(f.provider.cancel(), true)
end)
with_case({ constructor_delay = 1 }, function(f)
	local path, state = f.provider.resolve(2)
	check(path, nil); check(state, "pending"); check(f.timers[1].delay, 1)
	check(f.tasks[1].starts, 1); f.close(); check(f.provider.cancel(), true)
end)
with_case({ timer_delay = 3 }, function(f)
	local path, state = f.provider.resolve(2)
	check(path, nil); check(state, "pending"); check(f.timers[1].delay, 2)
	check(f.tasks[1].starts, 0); check(f.tasks[1].terminations, 1)
	check(count(f.probe._active_tasks), 2); f.close(); check(f.provider.cancel(), true)
end)
with_case({ system_delay = 3 }, function(f)
	f.system = "/actual/native/system/python"
	local path, state = f.provider.resolve(2)
	check(path, nil); check(state, nil); check(#f.tasks, 0); check(#f.timers, 0)
end)
with_case({ snapshot_delay = 3 }, function(f)
	local namespace = assert(f.expected:match("^(.*)/bin/python3%.11$")) .. "/"
	local path, state = f.probe.get(f.expected, namespace, "arm64", 2)
	check(path, nil); check(state, nil); check(#f.tasks, 0); check(#f.timers, 0)
end)

with_case({ clock_refused_once = true }, function(f)
	local path, state = f.provider.resolve(2)
	check(path, nil); check(state, nil); check(f.clock_refused, true)
	check(#f.tasks, 0); check(#f.timers, 0)
end)

with_case({ stop_advances_clock = true }, function(f)
	check(f.provider.resolve(2), nil); f.finish(0, true)
	local path, state = f.provider.resolve(1)
	check(path, nil); check(state, "pending"); check(#f.tasks, 2)
	check(f.tasks[2].starts, 1)
	f.tasks[2].closed = true; check(f.provider.cancel(), true)
end)

print("Native Python exact preflight controls passed: " .. cases .. " cases / " .. assertions .. " assertions")
