--- tests/unit/modules/test_program_lifecycle.lua

--- Exercises literal native argv and retained physical program ownership.
local helpers = require("tests.helpers")
local Runner = require("adapters.program_runner")
local Owner = require("modules.gestures.program_owner")
local Native = require("luv")
local scalar = '{"version":1,"executable":"/bin/sh","arguments":[]}'

local function fixture(options)
	options = options or {}
	local f = { admission = true, settled = false, starts = 0, kills = 0, timers = {}, observers = {} }
	local runner = {}
	function runner.spawn(_, arguments, _, admission)
		f.arguments = arguments
		if options.in_spawn then options.in_spawn(f) end
		return {
			start = function()
				f.starts = f.starts + 1
				if options.before_start then options.before_start(f) end
				return admission() and options.start ~= false
			end,
			isSettled = function() return f.settled end,
			terminate = function()
				f.kills = f.kills + 1
				if options.kill_throw then error("private terminate failure") end
				return true
			end,
			onSettled = function(callback) f.observers[#f.observers + 1] = callback; return true end,
		}
	end
	local timer_port = {
		new_timer = function() local timer = {}; f.timers[#f.timers + 1] = timer; return timer end,
		timer_start = function(timer, _, _, callback) timer.callback = callback; return 0 end,
		timer_stop = function(timer)
			if options.stop_throw then error("private native stop refused") end
			if options.stop_false then return false end
			timer.stopped = true
			return 0
		end,
		close = function(timer, callback)
			if options.close_throw then error("private native close refused") end
			if options.close_false then return false end
			timer.closed = true
			if options.close_pending then f.timer_close_receipt = callback; return end
			if callback then callback() end
		end,
	}
	f.owner = Owner.new(function()
		if options.in_capture then options.in_capture(f) end
		return scalar, function() return f.admission end
	end,
		{ runner = runner, native = timer_port })
	function f.finish()
		f.settled = true
		for _, callback in ipairs(f.observers) do callback() end
	end
	return f
end

helpers.describe("private user program lifecycle", function()
	helpers.it("retains the exact child after signal acceptance and blocks replacement", function()
		local f = fixture()
		helpers.assert_eq(f.owner.run("keyboard__F1"), true)
		helpers.assert_eq(f.owner.stop(), false)
		helpers.assert_eq(f.owner.has_pending(), true)
		helpers.assert_eq(f.owner.run("gesture__up"), false)
		helpers.assert_eq(f.starts, 1)
		f.finish()
		helpers.assert_eq(f.owner.has_pending(), false)
		helpers.assert_eq(f.timers[1].closed, true)
		helpers.assert_eq(f.owner.set_paused(false), true)
		helpers.assert_eq(f.owner.run("gesture__up"), true)
		f.finish()
	end)

	helpers.it("retains refused retirement and delivers shutdown receipt only after exit", function()
		local f = fixture({ kill_throw = true })
		local idle = 0
		helpers.assert_eq(f.owner.run("keyboard__F1"), true)
		f.owner.when_settled(function() idle = idle + 1 end)
		helpers.assert_eq(f.owner.stop(), false)
		helpers.assert_eq(idle, 0)
		f.finish()
		helpers.assert_eq(idle, 1)
		helpers.assert_eq(f.owner.stop(), true)
	end)

	helpers.it("remembers resume while cancellation is still pending", function()
		local f = fixture()
		helpers.assert_eq(f.owner.run("gesture__up"), true)
		helpers.assert_eq(f.owner.set_paused(true), false)
		helpers.assert_eq(f.owner.set_paused(false), false)
		helpers.assert_eq(f.owner.run("keyboard__F1"), false)
		f.finish()
		helpers.assert_eq(f.owner.run("keyboard__F1"), true)
		f.finish()
	end)

	helpers.it("cancels a retained child when its source admission changes", function()
		local f = fixture()
		helpers.assert_eq(f.owner.run("gesture__up"), true)
		f.admission = false
		f.timers[1].callback()
		helpers.assert_eq(f.kills, 1)
		helpers.assert_eq(f.owner.has_pending(), true)
		f.finish()
		helpers.assert_eq(f.owner.run("gesture__up"), false)
		helpers.assert_eq(f.starts, 2)
		f.finish()
	end)

	helpers.it("refuses lifecycle revocation during native acquisition", function()
		local f = fixture({ before_start = function(state) state.owner.stop() end })
		helpers.assert_eq(f.owner.run("keyboard__F1"), false)
		helpers.assert_eq(f.owner.has_pending(), true)
		helpers.assert_eq(f.owner.run("keyboard__F1"), false)
		f.finish()
		helpers.assert_eq(f.owner.has_pending(), false)
	end)

	helpers.it("requires a literal true current admission", function()
		for _, value in ipairs({ false, 0, 1, "true", {} }) do
			local f = fixture()
			f.admission = value
			helpers.assert_eq(f.owner.run("keyboard__F1"), false)
			helpers.assert_eq(f.owner.has_pending(), true)
			f.finish()
		end
	end)
end)

--- A native boundary that distinguishes signal acceptance from group absence.
--- @return table native, table state
local function group_fixture()
	local state = { absent = false, refused = false, signals = {}, closed = 0 }
	local port = {
		fs_stat = function() return { type = "file", mode = 493 } end,
		spawn = function(_, _, callback)
			state.terminal = callback
			return { close = function(_, callback)
				if state.close_throw then error("private process close refused") end
				if state.close_refused then return false end
				state.closed = state.closed + 1
				if state.close_pending then state.close_receipt = callback; return end
				if callback then callback() end
			end }, 4321
		end,
		kill = function(pid, signal)
			state.signals[#state.signals + 1] = { pid = pid, signal = signal }
			if state.refused then return nil, "permission refused", "EPERM" end
			if state.absent then return nil, "group absent", "ESRCH" end
			return 0
		end,
	}
	return port, state
end

helpers.describe("private program group retirement (program106-group)", function()
	helpers.it("retains the original group after its leader exits (program106-group)", function()
		local port, state = group_fixture()
		local completions, settlements = 0, 0
		local handle = Runner.spawn("/bin/sh", {}, function() completions = completions + 1 end,
			function() return true end, port)
		helpers.assert_eq(handle.start(), true)
		handle.onSettled(function() settlements = settlements + 1 end)
		state.terminal(0, 0)
		helpers.assert_eq(handle.isSettled(), false, "a leader exit is not a group-absence receipt")
		helpers.assert_eq(completions, 0)
		helpers.assert_eq(settlements, 0)
		helpers.assert_eq(handle.terminate(), false)
		local graceful = {}
		for _, receipt in ipairs(state.signals) do
			if receipt.signal == "sigterm" then graceful[#graceful + 1] = receipt end
		end
		helpers.assert_eq(graceful, { { pid = -4321, signal = "sigterm" } })
		state.absent = true
		helpers.assert_eq(handle.isSettled(), true)
		helpers.assert_eq(completions, 0, "cancellation must suppress the retained terminal result")
		helpers.assert_eq(settlements, 1)
		helpers.assert_eq(state.closed, 1)
	end)

	helpers.it("retains refused group retirement and accepted force until ESRCH (program106-group)", function()
		local port, state = group_fixture()
		local handle = Runner.spawn("/bin/sh", {}, function() end, function() return true end, port)
		helpers.assert_eq(handle.start(), true)
		state.terminal(0, 0)
		state.refused = true
		helpers.assert_eq(handle.terminate(), false)
		helpers.assert_eq(handle.isSettled(), false)
		state.refused = false
		helpers.assert_eq(handle.terminate(true), false)
		helpers.assert_eq(handle.isSettled(), false, "SIGKILL acceptance is not native retirement")
		helpers.assert_eq(state.signals[#state.signals], { pid = -4321, signal = 0 })
		state.absent = true
		helpers.assert_eq(handle.terminate(true), true)
		helpers.assert_eq(handle.isSettled(), true)
	end)

	helpers.it("requires leader exit even when its group is already absent (program106-group)", function()
		local port, state = group_fixture()
		local handle = Runner.spawn("/bin/sh", {}, function() end, function() return true end, port)
		helpers.assert_eq(handle.start(), true)
		state.absent = true
		helpers.assert_eq(handle.terminate(), false)
		helpers.assert_eq(handle.isSettled(), false, "native leader exit still belongs to libuv")
		state.terminal(0, 15)
		helpers.assert_eq(handle.isSettled(), true)
	end)

	helpers.it("decodes the native signal instead of reporting zero (program106-group)", function()
		local port, state = group_fixture()
		local statuses = {}
		local handle = Runner.spawn("/bin/sh", {}, function(code) statuses[#statuses + 1] = code end,
			function() return true end, port)
		helpers.assert_eq(handle.start(), true)
		state.absent = true
		state.terminal(0, 15)
		helpers.assert_eq(handle.isSettled(), true)
		helpers.assert_eq(statuses, { 143 }, "libuv's independent signal cannot become success")
		state.terminal(0, 0)
		helpers.assert_eq(statuses, { 143 }, "late native terminals cannot publish twice")
	end)

	helpers.it("retries settlement on ordinary owner timer ticks (program106-group)", function()
		local f = fixture()
		helpers.assert_eq(f.owner.run("keyboard__F1"), true)
		f.settled = true
		f.timers[1].callback()
		helpers.assert_eq(f.owner.has_pending(), false,
			"native group disappearance need not emit another direct-child callback")
		helpers.assert_eq(f.kills, 0, "normal group disappearance needs no cancellation")
	end)

	helpers.it("reports only the closed numeric execution failure (program106-group)", function()
		local Logger = require("logger.shim")
		local previous, messages = Logger.error, {}
		Logger.error = function(_, format, ...) messages[#messages + 1] = string.format(format, ...) end
		local ok, failure = xpcall(function()
			local callback
			local f = fixture()
			local runner = { spawn = function(_, _, completed, admitted)
				callback = completed
				return {
					start = function() return admitted() end,
					isSettled = function() return f.settled end,
					terminate = function() return false end,
					onSettled = function() return true end,
				}
			end }
			local port = {
				new_timer = function() return {} end,
				timer_start = function() return 0 end,
				timer_stop = function() return 0 end,
				close = function() return true end,
			}
			local owner = Owner.new(function() return scalar, function() return true end end,
				{ runner = runner, native = port })
			helpers.assert_eq(owner.run("PRIVATE_BINDING_106"), true)
			callback(7, "PRIVATE_STDOUT_106", "PRIVATE_STDERR_106")
			helpers.assert_eq(messages, { "Private user program exited with status 7." })
		end, debug.traceback)
		Logger.error = previous
		if not ok then error(failure, 0) end
	end)

	helpers.it("qualifies real descendant retirement in an owned subreaper (program106-group)", function()
		local path = require("infra.paths").driver_root() .. "/tests/hardware/run_program_group_receipts.lua"
		local code = "package.path = " .. string.format("%q", package.path) .. "; dofile("
			.. string.format("%q", path) .. ")"
		local stdout, stderr = Native.new_pipe(false), Native.new_pipe(false)
		local output, errors, status, signal = "", "", nil, nil
		local ended = 0
		local process, pid = Native.spawn("luajit", { args = { "-e", code }, stdio = { nil, stdout, stderr } },
			function(value, terminated) status, signal = value, terminated end)
		helpers.assert_not_nil(process, "native group regression requires the installed Linux LuaJIT target")
		Native.read_start(stdout, function(err, bytes)
			if err then errors = errors .. tostring(err) end
			if bytes then output = output .. bytes else ended = ended + 1 end
		end)
		Native.read_start(stderr, function(err, bytes)
			if err then errors = errors .. tostring(err) end
			if bytes then errors = errors .. bytes else ended = ended + 1 end
		end)
		local deadline = Native.hrtime() + 10000000000
		while (status == nil or ended ~= 2) and Native.hrtime() < deadline do
			Native.run("nowait"); Native.sleep(1)
		end
		if status == nil then
			-- This is the exact subprocess acquired by this fixture, never a foreign PID.
			Native.kill(pid, "sigkill")
			local cleanup = Native.hrtime() + 3000000000
			while status == nil and Native.hrtime() < cleanup do Native.run("nowait"); Native.sleep(1) end
		end
		Native.read_stop(stdout); Native.read_stop(stderr)
		Native.close(stdout); Native.close(stderr)
		if status ~= nil then Native.close(process) end
		Native.run("nowait")
		helpers.assert_eq(status, 0, errors)
		helpers.assert_eq(signal, 0, "the owned subreaper must exit normally")
		helpers.assert_eq(ended, 2, "both exact fixture streams must retire")
		helpers.assert_eq(errors, "", "the native group receipt must retain empty stderr")
		helpers.assert_eq(output, "PASS private program native group ordinary\n"
			.. "PASS private program native group stubborn\nPASS private program native group owner\n"
			.. "Private program native groups: 3 checks, 0 failures\n")
	end)
end)

helpers.describe("private program acquisition and resource debt", function()
	for _, boundary in ipairs({ "capture", "spawn" }) do
		helpers.it("fences a nested launch during " .. boundary .. " (program106-acquire)", function()
			local nested, observed = nil, false
			local options = {}
			options["in_" .. boundary] = function(f)
				if observed then return end
				observed = true
				nested = f.owner.run("nested")
			end
			local f = fixture(options)
			helpers.assert_eq(f.owner.run("outer"), true)
			helpers.assert_eq(nested, false, "an active acquisition owns the only native launch identity")
			helpers.assert_eq(f.starts, 1, "reentry cannot acquire a successor and orphan it")
			f.finish()
			helpers.assert_eq(f.owner.has_pending(), false)
		end)

		helpers.it("retains truthful stop debt during " .. boundary .. " (program106-acquire)", function()
			local stopped, acknowledged = nil, 0
			local options = {}
			options["in_" .. boundary] = function(f)
				f.owner.when_settled(function() acknowledged = acknowledged + 1 end)
				stopped = f.owner.stop()
				helpers.assert_eq(f.owner.has_pending(), true, "acquisition cannot claim idle before its return")
				helpers.assert_eq(acknowledged, 0, "shutdown acknowledgement waits for acquired resources")
			end
			local f = fixture(options)
			helpers.assert_eq(f.owner.run("outer"), false)
			helpers.assert_eq(stopped, false)
			helpers.assert_eq(f.starts, 0, "revoked acquisition cannot dispatch its lazy native handle")
			if f.owner.has_pending() then f.finish() end
			helpers.assert_eq(f.owner.has_pending(), false)
			helpers.assert_eq(acknowledged, 1)
		end)
	end

	for _, mode in ipairs({ "stop_false", "close_false", "stop_throw", "close_throw" }) do
		helpers.it("retains native timer " .. mode .. " debt (program106-acquire)", function()
			local options = { [mode] = true }
			local f = fixture(options)
			local acknowledged = 0
			helpers.assert_eq(f.owner.run("outer"), true)
			f.owner.when_settled(function() acknowledged = acknowledged + 1 end)
			f.finish()
			helpers.assert_eq(f.owner.has_pending(), true, "false native cleanup cannot acknowledge idle")
			helpers.assert_eq(f.owner.stop(), false)
			helpers.assert_eq(acknowledged, 0)
			options[mode] = false
			helpers.assert_eq(f.owner.stop(), true)
			helpers.assert_eq(acknowledged, 1)
		end)
	end

	for _, mode in ipairs({ "close_refused", "close_throw" }) do
		helpers.it("retains native process " .. mode .. " debt (program106-acquire)", function()
			local port, state = group_fixture()
			state[mode] = true
			local handle = Runner.spawn("/bin/sh", {}, function() end, function() return true end, port)
			helpers.assert_eq(handle.start(), true)
			state.absent = true
			state.terminal(0, 0)
			helpers.assert_eq(handle.isSettled(), false)
			state[mode] = false
			helpers.assert_eq(handle.isSettled(), true)
			helpers.assert_eq(state.closed, 1)
		end)
	end

	helpers.it("waits for exact native timer retirement (program106-acquire)", function()
		local f = fixture({ close_pending = true })
		local acknowledged = 0
		helpers.assert_eq(f.owner.run("outer"), true)
		f.owner.when_settled(function() acknowledged = acknowledged + 1 end)
		f.finish()
		helpers.assert_eq(f.owner.has_pending(), true, "queued close is not physical timer retirement")
		helpers.assert_eq(f.owner.stop(), false)
		helpers.assert_eq(acknowledged, 0)
		helpers.assert_eq(type(f.timer_close_receipt), "function")
		f.timer_close_receipt()
		helpers.assert_eq(f.owner.has_pending(), false)
		helpers.assert_eq(acknowledged, 1)
		f.timer_close_receipt()
		helpers.assert_eq(acknowledged, 1, "late retirement cannot release another generation")
	end)

	helpers.it("waits for exact native process retirement (program106-acquire)", function()
		local port, state = group_fixture()
		state.close_pending = true
		local acknowledged = 0
		local handle = Runner.spawn("/bin/sh", {}, function() end, function() return true end, port)
		helpers.assert_eq(handle.start(), true)
		handle.onSettled(function() acknowledged = acknowledged + 1 end)
		state.absent = true
		state.terminal(0, 0)
		helpers.assert_eq(handle.isSettled(), false, "queued close is not physical process-handle retirement")
		helpers.assert_eq(acknowledged, 0)
		helpers.assert_eq(type(state.close_receipt), "function")
		state.close_receipt()
		helpers.assert_eq(handle.isSettled(), true)
		helpers.assert_eq(acknowledged, 1)
		state.close_receipt()
		helpers.assert_eq(acknowledged, 1)
	end)
end)

local function with_bindings(callback)
	local modules = { "modules.gestures.manager", "modules.shortcuts.keyboard_shortcuts",
		"infra.config_paths", "infra.i18n", "logger.shim", "ui.gesture_conflicts" }
	local saved = {}
	for _, name in ipairs(modules) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local path = os.tmpname()
	local initial = assert(io.open(path, "wb")); initial:write("# retained foreign note\n"); initial:close()
	local manager
	local ok, failure = xpcall(function()
		package.loaded["infra.config_paths"] = { config = function() return path end, get_config_dir = function() return "/tmp" end }
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["logger.shim"] = helpers.make_logger_stub()
		package.loaded["ui.gesture_conflicts"] = { notify_boot = function() end }
		manager = require("modules.gestures.manager")
		manager.init({ persist = true, config_path = path, enabled = false, is_paused = function() return false end })
		callback(manager, require("modules.shortcuts.keyboard_shortcuts"), path)
	end, debug.traceback)
	if manager then
		manager.stop_programs()
		local deadline = Native.hrtime() + 3e9
		while manager.stop_programs() ~= true and Native.hrtime() < deadline do Native.run("nowait") end
	end
	os.remove(path)
	for _, name in ipairs(modules) do package.loaded[name] = saved[name] end
	if not ok then error(failure, 0) end
end

helpers.describe("private user program real gesture and keyboard bindings", function()
	helpers.it("persists and dispatches the same typed program through gesture and keyboard owners", function()
		with_bindings(function(manager, keyboard, path)
			local Json = require("json")
			local output = path .. ".out"
			local parameter = Json.encode({ version = 1, executable = "/bin/sh",
				arguments = { "-c", 'printf "%s" "$2" > "$1"', "fixture", output, "été 日本 literal" } })
			helpers.assert_eq(manager.set_action("swipe_3_up", "run_program"), true)
			helpers.assert_eq(manager.set_action_parameter("swipe_3_up", "run_program", parameter), true)
			manager._test_begin_reading({})
			helpers.assert_eq(manager.enable(), true)
			helpers.assert_eq(manager.dispatch_gesture({ fingers = 3, direction = "up" }), true)
			local deadline = Native.hrtime() + 3e9
			local settled = false
			manager.when_programs_settled(function() settled = true end)
			while not settled and Native.hrtime() < deadline do Native.run("nowait") end
			helpers.assert_eq(settled, true)
			local receipt = assert(io.open(output, "rb")); local bytes = receipt:read("*a"); receipt:close()
			helpers.assert_eq(bytes, "été 日本 literal")
			while manager.stop_programs() ~= true and Native.hrtime() < deadline do Native.run("nowait") end
			helpers.assert_eq(manager.set_program_paused(false), true)
			os.remove(output)
			helpers.assert_eq(keyboard.set_action("ctrl_p", "run_program"), true)
			helpers.assert_eq(manager.set_action_parameter("keyboard__ctrl_p", "run_program", parameter), true)
			helpers.assert_eq(keyboard.dispatch({ key = "p", mods = { ctrl = true } }), true)
			deadline = Native.hrtime() + 3e9
			settled = false
			manager.when_programs_settled(function() settled = true end)
			while not settled and Native.hrtime() < deadline do Native.run("nowait") end
			helpers.assert_eq(settled, true)
			local file = io.open(output, "rb")
			helpers.assert_not_nil(file)
			if file then bytes = file:read("*a"); file:close() end
			helpers.assert_eq(bytes, "été 日本 literal")
			local canonical = assert(io.open(path, "rb")); local source = canonical:read("*a"); canonical:close()
			helpers.assert_contains(source, "# retained foreign note")
			local document = require("toml_codec").decode(source)
			helpers.assert_eq(document.gesture_parameters["keyboard__ctrl_p__run_program"], parameter)
			os.remove(output)
		end)
	end)

	helpers.it("refuses canonical source disagreement even when the runtime assignment still matches", function()
		with_bindings(function(manager, _, path)
			helpers.assert_eq(manager.set_action("swipe_3_up", "run_program"), true)
			helpers.assert_eq(manager.set_action_parameter("swipe_3_up", "run_program", scalar), true)
			local file = assert(io.open(path, "wb")); file:write('[gestures]\nswipe_3_up = "none"\n'); file:close()
			helpers.assert_eq(manager.run_program("swipe_3_up"), false)
			helpers.assert_eq(manager.stop_programs(), true)
		end)
	end)
end)

local function await(predicate)
	local deadline = Native.hrtime() + 3e9
	while not predicate() and Native.hrtime() < deadline do Native.run("nowait") end
	helpers.assert_eq(predicate(), true, "owned native child did not settle")
end

helpers.describe("private user program native POSIX receipts", function()
	helpers.it("executes Unicode paths and literal empty, spaced, Unicode and newline arguments", function()
		local base = os.tmpname()
		os.remove(base)
		local script, output = base .. " été 日本.sh", base .. ".receipt"
		local file = assert(io.open(script, "wb"))
		file:write('destination=$1\nshift\nprintf "%s\\0" "$@" > "$destination"\n')
		file:close()
		local terminal, observed = nil, 0
		local ok, failure = xpcall(function()
			local arguments = { script, output, "", "two words", "日本語", "%TOKEN%;$(ignored)", "line\nnext" }
			local handle = Runner.spawn("/bin/sh", arguments,
				function(code) terminal = code end, function() return true end)
			helpers.assert_eq(handle.start(), true)
			handle.onSettled(function() observed = observed + 1 end)
			await(handle.isSettled)
			helpers.assert_eq(terminal, 0)
			helpers.assert_eq(observed, 1)
			local receipt = assert(io.open(output, "rb"))
			local bytes = receipt:read("*a"); receipt:close()
			helpers.assert_eq(bytes, "\0two words\0日本語\0%TOKEN%;$(ignored)\0line\nnext\0")
		end, debug.traceback)
		os.remove(script); os.remove(output)
		if not ok then error(failure, 0) end
	end)

	helpers.it("waits for native exit after accepting a process-group cancellation", function()
		local callbacks, settlements = 0, 0
		local handle = Runner.spawn("/bin/sh", { "-c", "exec sleep 30" },
			function() callbacks = callbacks + 1 end, function() return true end)
		helpers.assert_eq(handle.start(), true)
		handle.onSettled(function() settlements = settlements + 1 end)
		helpers.assert_eq(handle.terminate(), false)
		helpers.assert_eq(handle.isSettled(), false)
		await(handle.isSettled)
		helpers.assert_eq(settlements, 1)
		helpers.assert_eq(callbacks, 0)
		helpers.assert_eq(handle.terminate(), true)
	end)

	helpers.it("refuses a missing executable without acquiring a child", function()
		local handle = Runner.spawn("/not/a/real/program106", {}, function() end, function() return true end)
		helpers.assert_eq(handle.start(), false)
		helpers.assert_eq(handle.isSettled(), true)
	end)
end)

helpers.describe("private user program durable parameter receipts", function()
	for _, mode in ipairs({ "false", "nil", "truthy", "throw" }) do
		helpers.it("retains RAM and exact source after writer " .. mode, function()
			with_bindings(function(manager, _, path)
				local Writer = require("toml_codec.writer")
				local Logger = require("logger.shim")
				local write, log = Writer.batch_write, Logger.error
				local messages, calls = {}, 0
				local f = assert(io.open(path, "rb")); local before = f:read("*a"); f:close()
				local ok, failure = xpcall(function()
					Logger.error = function(_, format, ...) messages[#messages + 1] = string.format(format, ...) end
					Writer.batch_write = function()
						calls = calls + 1
						if mode == "throw" then error("PRIVATE_PROGRAM_PARAMETER_106") end
						if mode == "nil" then return nil, "PRIVATE_PROGRAM_PARAMETER_106" end
						if mode == "truthy" then return 2, "PRIVATE_PROGRAM_PARAMETER_106" end
						return false, "PRIVATE_PROGRAM_PARAMETER_106"
					end
					local receipt = manager.set_action_parameter("swipe_3_up", "run_program", scalar)
					helpers.assert_eq(receipt, false)
					helpers.assert_eq(calls, 1)
					helpers.assert_eq(manager.get_action_parameter("swipe_3_up", "run_program"), "")
					local actual = assert(io.open(path, "rb")); local bytes = actual:read("*a"); actual:close()
					helpers.assert_eq(bytes, before)
					helpers.assert_eq(table.concat(messages, "\n"):find("PRIVATE_PROGRAM_PARAMETER_106", 1, true), nil)
				end, debug.traceback)
				Writer.batch_write, Logger.error = write, log
				if not ok then error(failure, 0) end
				helpers.assert_eq(manager.set_action_parameter("swipe_3_up", "run_program", scalar), true)
				helpers.assert_eq(manager.get_action_parameter("swipe_3_up", "run_program"), scalar)
			end)
		end)
	end
end)

helpers.describe("private program lossless shared parameter corpus", function()
	helpers.it("checks every platform against independently declared literal vectors", function()
		local Json, Program = require("json"), require("program_parameter")
		local file = assert(io.open(require("infra.paths").shared("tests/corpus/action_parameters/program_vectors.json"), "rb"))
		local corpus = assert(Json.decode_lossless(file:read("*a"))); file:close()
		local count = 0
		for _, vector in ipairs(corpus.cases) do
			for _, platform in ipairs(vector.platforms) do
				local actual = Program.parse(vector.value, platform)
				if Json.is_null(vector.expected) then
					helpers.assert_eq(actual, nil, vector.id .. "/" .. platform)
				else
					helpers.assert_not_nil(actual, vector.id .. "/" .. platform)
					if actual then
						helpers.assert_eq(actual.executable, vector.expected.executable)
						helpers.assert_eq(actual.arguments, vector.expected.arguments)
					end
				end
				count = count + 1
			end
		end
		helpers.assert_eq(count, 63, "the whole independent cross-platform vector census executes")
	end)
end)

helpers.describe("private native program execution refusal", function()
	helpers.it("reports a nonzero child exit without retaining or publishing private streams", function()
		local code, calls, streams_absent = nil, 0, nil
		local handle = Runner.spawn("/bin/sh", { "-c", 'printf "%s" PRIVATE_STDOUT_106; printf "%s" PRIVATE_STDERR_106 >&2; exit 7' },
			function(status, stdout, stderr)
				code, calls = status, calls + 1
				streams_absent = stdout == nil and stderr == nil
			end, function() return true end)
		helpers.assert_eq(handle.start(), true)
		await(handle.isSettled)
		helpers.assert_eq(streams_absent, true)
		helpers.assert_eq(code, 7)
		helpers.assert_eq(calls, 1)
		helpers.assert_eq(handle.terminate(), true)
	end)
end)
