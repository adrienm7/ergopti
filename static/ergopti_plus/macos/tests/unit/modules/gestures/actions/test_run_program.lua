--- tests/unit/modules/gestures/actions/test_run_program.lua

--- Real action, preference and native task owners with explicit test-owned tasks.
local helpers = require("tests.helpers")
local Json = require("json")
local HELPER = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"
local DIGEST = string.rep("a", 64)

local function with_program(callback, program_admission)
	local saved = {}
	for name, value in pairs(package.loaded) do saved[name] = value end
	local old_hs = _G.hs
	local path = os.tmpname()
	os.remove(path)
	local tasks, actions, auxiliary = {}, nil, nil
	local owned = { "modules.gestures.actions", "modules.gestures.actions_aux_owner", "adapters.shell_runner",
		"adapters.owned_program_runner", "platform.remap.lease_helper", "adapters.crypto",
		"adapters.task_environment", "adapters.file_system", "adapters.timer_scheduler", "infra.preferences",
		"infra.config_paths", "infra.paths", "infra.i18n", "infra.logger", "infra.timings",
		"modules.shortcuts.keyboard_shortcuts", "tests.stubs.hs", "hs" }
	for _, name in ipairs(owned) do package.loaded[name] = nil end
	local ok, failure = xpcall(function()
		local native = require("tests.stubs.hs")
		native.__reset()
		_G.hs = native
		package.loaded["hs"] = native
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.i18n"] = { get = function(key) return key end, format = function(key) return key end }
		package.loaded["infra.config_paths"] = { get = function() return path end }
		package.loaded["platform.remap.lease_helper"] = { resolve = function()
			return HELPER, nil, { ERGOPTI_LAUNCHER_EXECUTABLE = HELPER,
				ERGOPTI_LAUNCHER_DEVICE = "42", ERGOPTI_LAUNCHER_INODE = "73" }
		end }
		native.hash_inputs = {}
		native.hash = { new = function(algorithm)
			helpers.assert_eq(algorithm, "SHA256")
			local context = {}
			function context:append(bytes) native.hash_inputs[#native.hash_inputs + 1] = bytes; return self end
			function context:finish() return self end
			function context:value() return DIGEST end
			return context
		end }
		native.task.new = function(executable, terminal, chunks, arguments)
			local task = { executable = executable, arguments = arguments, starts = 0, running = false,
				inputs = {}, activations = 0, terminal = terminal, chunks = chunks,
				env = { PATH = "/usr/bin:/bin", HOME = "/Users/tester" } }
			function task:environment() local result = {}; for k, v in pairs(self.env) do result[k] = v end; return result end
			function task:setEnvironment(value) self.env = value; return self end
			function task:start() self.starts = self.starts + 1; self.running = true; return self end
			function task:isRunning() return self.running end
			function task:terminate() return self end
			function task:emit(value) return self.chunks(self, value, "") end
			function task:setInput(value)
				self.inputs[#self.inputs + 1] = value
				if value == "ACTIVATE\n" then
					self.activations = self.activations + 1
					self:emit("V1 ACTIVE\n")
				else
					self.request = Json.decode_lossless(value)
					if not native.hold_program_activation then self:emit("V1 HELD\n") end
				end
				return self
			end
			function task:closeInput() self.closed = true; return self end
			function task:helper_exit(code) self.running = false; return self.terminal(code, "", "") end
			function task:complete(code)
			self:emit("V1 RETIRED " .. tostring(code or 0) .. "\n")
				return self:helper_exit(0)
			end
			tasks[#tasks + 1] = task
			return task
		end
		actions = require("modules.gestures.actions")
		auxiliary = require("modules.gestures.actions_aux_owner")
		local preferences = require("infra.preferences")
		local state = { ga = { tap_3 = "run_program" }, action_params = {} }
		actions.init(state)
		if program_admission ~= false and type(actions.configure_program_admission) == "function" then
			helpers.assert_eq(actions.configure_program_admission(program_admission or function() return true end), true)
		end
		preferences.load(path)
		local scalar = '{"version":1,"executable":"/private/été program","arguments":["","two words","日本語","line\\nnext"]}'
		helpers.assert_eq(actions.set_action_parameter("tap_3", "run_program", scalar), true)
		local gesture_port = {
			get_all_actions = function() return state.ga end,
			get_all_action_parameters = actions.get_all_action_parameters,
		}
		helpers.assert_eq(preferences.save(path, {}, {}, { gestures = gesture_port }), true)
		callback(actions, auxiliary, preferences, native, tasks, path, scalar, state, gesture_port)
	end, debug.traceback)
	for _, task in ipairs(tasks) do if task.running then task:complete(15) end end
	if auxiliary then auxiliary.stop_programs("gestures"); auxiliary.stop_programs("shortcut_bindings") end
	local acquired_keyboard = package.loaded["modules.shortcuts.keyboard_shortcuts"]
	if type(acquired_keyboard) == "table" and acquired_keyboard ~= saved["modules.shortcuts.keyboard_shortcuts"] then
		pcall(acquired_keyboard.stop)
	end
	os.remove(path)
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	_G.hs = old_hs
	if not ok then error(failure, 0) end
end

helpers.describe("private run_program real action/preferences chain", function()
	helpers.it("dispatches the persisted gesture with opaque literal native argv", function()
		with_program(function(actions, _, preferences, _, tasks, path, scalar)
			helpers.assert_eq(actions.execute_single("run_program", "tap_3"), true)
			helpers.assert_eq(#tasks, 1)
			helpers.assert_eq(tasks[1].starts, 1)
			helpers.assert_eq(tasks[1].executable, HELPER)
			helpers.assert_eq(tasks[1].arguments, { "--owned-program-worker" })
			helpers.assert_eq(tasks[1].request.executable, "/private/été program")
			helpers.assert_eq(tasks[1].request.arguments, { "", "two words", "日本語", "line\nnext" })
			helpers.assert_eq(tasks[1].activations, 1)
			local flat = preferences.current_view(path)
			helpers.assert_eq(flat.gesture_action_parameters["tap_3__run_program"], scalar)
			tasks[1]:complete()
		end)
	end)

	helpers.it("refuses foreign canonical assignment without constructing a native task", function()
		with_program(function(actions, _, _, _, tasks, path)
			local file = assert(io.open(path, "wb")); file:write('[gestures]\ntap_3 = "none"\n'); file:close()
			helpers.assert_eq(actions.run_program("tap_3"), false)
			helpers.assert_eq(#tasks, 0)
		end)
	end)

	helpers.it("retains running child debt before accepting parameter replacement", function()
		with_program(function(actions, auxiliary, _, _, tasks, _, scalar)
			helpers.assert_eq(actions.run_program("tap_3"), true)
			helpers.assert_eq(actions.set_action_parameter("tap_3", "run_program", scalar), false)
			helpers.assert_eq(auxiliary.has_pending("gestures"), true)
			helpers.assert_eq(#tasks, 1)
			tasks[1]:complete(15)
			helpers.assert_eq(actions.set_action_parameter("tap_3", "run_program", scalar), true)
		end)
	end)
end)

helpers.describe("private program parameter transaction admission", function()
	helpers.it("requires an explicit admission owner before constructing native programs", function()
		with_program(function(actions, _, _, _, tasks)
			helpers.assert_eq(actions.program_admission_available(), false)
			helpers.assert_eq(actions.run_program("tap_3"), false)
			helpers.assert_eq(#tasks, 0)
		end, false)
	end)

	helpers.it("rejects invalid and duplicate owner registration", function()
		with_program(function(actions, _, _, _, tasks)
			for _, invalid in ipairs({ false, "owner", {} }) do
				helpers.assert_eq(actions.configure_program_admission(invalid), false)
			end
			helpers.assert_eq(actions.configure_program_admission(nil), false)
			helpers.assert_eq(actions.program_admission_available(), false)
			helpers.assert_eq(actions.configure_program_admission(function() return true end), true)
			helpers.assert_eq(actions.program_admission_available(), true)
			helpers.assert_eq(actions.configure_program_admission(function() return false end), false)
			helpers.assert_eq(actions.run_program("tap_3"), true)
			helpers.assert_eq(#tasks, 1)
		end, false)
	end)

	helpers.it("contains false, malformed and throwing admission receipts", function()
		for _, admission in ipairs({ function() return false end, function() end,
			function() return "yes" end, function() error("private admission payload") end }) do
			with_program(function(actions, _, _, _, tasks)
				helpers.assert_eq(actions.run_program("tap_3"), false)
				helpers.assert_eq(#tasks, 0)
			end, admission)
		end
	end)

	helpers.it("observes retained transaction debt while a prior native program is running", function()
		local pending = false
		with_program(function(actions, _, _, _, tasks)
			helpers.assert_eq(actions.run_program("tap_3"), true)
			pending = true
			helpers.assert_eq(actions.program_admission_available(), true,
				"a registered owner remains available for exact pending-debt recovery")
			helpers.assert_eq(actions.run_program("tap_3"), false)
			helpers.assert_eq(#tasks, 1)
			tasks[1]:complete(23)
			pending = false
			helpers.assert_eq(actions.run_program("tap_3"), true)
			helpers.assert_eq(#tasks, 2)
		end, function() return not pending end)
	end)

	helpers.it("rechecks transaction admission after a physical source callback", function()
		local pending = false
		with_program(function(actions, _, _, _, tasks)
			local filesystem = require("adapters.file_system")
			local read = filesystem.read_with_status
			filesystem.read_with_status = function(...)
				local content, status = read(...)
				pending = true
				return content, status
			end
			helpers.assert_eq(actions.run_program("tap_3"), false)
			helpers.assert_eq(#tasks, 0)
		end, function() return not pending end)
	end)

	helpers.it("refuses pending transaction debt acquired inside native construction", function()
		local pending = false
		with_program(function(actions, auxiliary, _, native, tasks)
			local create = native.task.new
			native.task.new = function(...)
				local task = create(...); pending = true; return task
			end
			helpers.assert_eq(actions.run_program("tap_3"), false)
			helpers.assert_eq(#tasks, 1)
			helpers.assert_eq(tasks[1].starts, 0)
			helpers.assert_eq(auxiliary.has_pending("gestures"), false)
		end, function() return not pending end)
	end)

	helpers.it("contains reentrant program dispatch from the admission owner", function()
		local actions_ref, nested
		with_program(function(actions, _, _, _, tasks)
			actions_ref = actions
			helpers.assert_eq(actions.run_program("tap_3"), true)
			helpers.assert_eq(nested, false)
			helpers.assert_eq(#tasks, 1)
		end, function()
			if actions_ref then nested = actions_ref.run_program("tap_3") end
			return true
		end)
	end)
end)

helpers.describe("private run_program owned source admission", function()
	helpers.it("fences unknown helper retirement debt before a successor native construction", function()
		with_program(function(actions, auxiliary, _, _, tasks)
			helpers.assert_eq(actions.run_program("tap_3"), true)
			tasks[1]:helper_exit(0)
			helpers.assert_eq(auxiliary.has_pending("gestures"), true)
			helpers.assert_eq(actions.run_program("tap_3"), false)
			helpers.assert_eq(#tasks, 1, "unknown helper retirement cannot admit a second native task")
			tasks[1]:emit("V1 RET")
			helpers.assert_eq(actions.run_program("tap_3"), false)
			helpers.assert_eq(#tasks, 1, "an incomplete late receipt still owns admission debt")
			tasks[1]:emit("IRED 0\n")
			helpers.assert_eq(auxiliary.has_pending("gestures"), false)
			helpers.assert_eq(actions.run_program("tap_3"), true)
			helpers.assert_eq(#tasks, 2, "exact late retirement releases the successor fence")
		end)
	end)

	helpers.it("fences malformed native protocol debt before constructing another program", function()
		with_program(function(actions, auxiliary, _, _, tasks)
			helpers.assert_eq(actions.run_program("tap_3"), true)
			tasks[1]:emit("V1 RETIRED private-untrusted-status\n")
			helpers.assert_eq(auxiliary.has_pending("gestures"), true)
			helpers.assert_eq(actions.run_program("tap_3"), false)
			helpers.assert_eq(#tasks, 1)
		end)
	end)

	helpers.it("permits concurrent normal programs whose native tree remains supervised", function()
		with_program(function(actions, auxiliary, _, _, tasks)
			helpers.assert_eq(actions.run_program("tap_3"), true)
			helpers.assert_eq(actions.run_program("tap_3"), true)
			helpers.assert_eq(#tasks, 2)
			tasks[1]:complete(0); tasks[2]:complete(0)
			helpers.assert_eq(auxiliary.has_pending("gestures"), false)
		end)
	end)

	helpers.it("fails closed when the exact supervised handle has no Boolean cleanup-debt receipt", function()
		for _, receipt in ipairs({ "missing", "throw", "nil", "string", "number" }) do
			with_program(function(actions, _, _, _, tasks)
				local runner = require("adapters.shell_runner")
				local spawn = runner.spawn_private
				runner.spawn_private = function(...)
					local handle = spawn(...)
					if receipt == "missing" then handle.hasCleanupDebt = nil
					else handle.hasCleanupDebt = function()
						if receipt == "throw" then error("private native receipt payload") end
						if receipt == "string" then return "false" end
						if receipt == "number" then return 0 end
						return nil
					end end
					return handle
				end
				helpers.assert_eq(actions.run_program("tap_3"), true)
				helpers.assert_eq(actions.run_program("tap_3"), false)
				helpers.assert_eq(#tasks, 1, "only literal false from the owned query permits a successor")
			end)
		end
	end)

	helpers.it("contains dispatch reentry from an owned cleanup-debt query", function()
		with_program(function(actions, _, _, _, tasks)
			local runner = require("adapters.shell_runner")
			local spawn, nested, attempted = runner.spawn_private, nil, false
			runner.spawn_private = function(...)
				local handle = spawn(...)
				local query = handle.hasCleanupDebt
				function handle.hasCleanupDebt()
					if not attempted then attempted = true; nested = actions.run_program("tap_3") end
					return query()
				end
				return handle
			end
			helpers.assert_eq(actions.run_program("tap_3"), true)
			helpers.assert_eq(actions.run_program("tap_3"), true)
			helpers.assert_eq(nested, false)
			helpers.assert_eq(#tasks, 2, "a reentrant query cannot acquire a third native task")
		end)
	end)

	helpers.it("rechecks native cancellation invoked inside a cleanup query before successor admission", function()
		with_program(function(actions, auxiliary, _, _, tasks)
			local runner = require("adapters.shell_runner")
			local spawn = runner.spawn_private
			runner.spawn_private = function(...)
				local handle = spawn(...)
				function handle.hasCleanupDebt()
					auxiliary.stop_programs("gestures")
					return false
				end
				return handle
			end
			helpers.assert_eq(actions.run_program("tap_3"), true)
			helpers.assert_eq(actions.run_program("tap_3"), false)
			helpers.assert_eq(#tasks, 1)
			helpers.assert_eq(tasks[1].closed, true)
			helpers.assert_eq(auxiliary.has_pending("gestures"), true)
			tasks[1]:complete(137)
			helpers.assert_eq(auxiliary.has_pending("gestures"), false)
		end)
	end)

	helpers.it("refuses unbundled helper availability before any native construction", function()
		with_program(function(actions, _, _, _, tasks)
			package.loaded["platform.remap.lease_helper"].resolve = function() return nil, "unavailable" end
			helpers.assert_eq(actions.run_program("tap_3"), false)
			helpers.assert_eq(#tasks, 0)
		end)
	end)

	helpers.it("rechecks exact source after the raw hash callback before acquiring a worker", function()
		with_program(function(actions, _, preferences, native, tasks, path)
			local source = preferences.source_snapshot(path)
			local create_hash = native.hash.new
			native.hash.new = function(...)
				local context = create_hash(...)
				local append = context.append
				function context:append(bytes)
					local file = assert(io.open(path, "wb"))
					file:write(source.content .. "\n# changed during hashing\n"); file:close()
					return append(self, bytes)
				end
				return context
			end
			helpers.assert_eq(actions.run_program("tap_3"), false)
			helpers.assert_eq(#tasks, 0)
			helpers.assert_eq(preferences.source_snapshot(path), source)
		end)
	end)

	helpers.it("sends the acknowledged raw source digest and requested path through the owned protocol", function()
		with_program(function(actions, _, preferences, native, tasks, path)
			local source = preferences.source_snapshot(path)
			helpers.assert_eq(actions.run_program("tap_3"), true)
			helpers.assert_eq(native.hash_inputs[#native.hash_inputs], source.content,
				"the raw-byte hash port receives exact acknowledged source bytes")
			helpers.assert_eq(tasks[1].request.source_path, path)
			helpers.assert_eq(tasks[1].request.source_sha256, DIGEST)
			helpers.assert_eq(tasks[1].request.version, 1)
			helpers.assert_eq(tasks[1].env.ERGOPTI_LAUNCHER_EXECUTABLE, nil)
			helpers.assert_eq(tasks[1].env.ERGOPTI_LAUNCHER_DEVICE, nil)
			helpers.assert_eq(tasks[1].env.ERGOPTI_LAUNCHER_INODE, nil)
			helpers.assert_eq(tasks[1].env.HOME, "/Users/tester")
			helpers.assert_eq(tasks[1].env.PATH, "/usr/bin:/bin")
			helpers.assert_eq(tasks[1].inputs[2], "ACTIVATE\n")
			tasks[1]:complete()
		end)
	end)

	helpers.it("refuses a source changed while the worker holds activation and retains exact retirement debt", function()
		with_program(function(actions, auxiliary, preferences, native, tasks, path)
			native.hold_program_activation = true
			local source = preferences.source_snapshot(path)
			helpers.assert_eq(actions.run_program("tap_3"), true)
			helpers.assert_eq(tasks[1].activations, 0)
			local foreign = source.content .. "\n# external writer before HELD\n"
			local file = assert(io.open(path, "wb")); file:write(foreign); file:close()
			tasks[1]:emit("V1 HELD\n")
			helpers.assert_eq(tasks[1].closed, true)
			helpers.assert_eq(tasks[1].activations, 0)
			helpers.assert_eq(#tasks[1].inputs, 1)
			helpers.assert_eq(auxiliary.has_pending("gestures"), true)
			tasks[1]:complete(137)
			helpers.assert_eq(auxiliary.has_pending("gestures"), false)
			helpers.assert_eq(preferences.source_snapshot(path), source)
			file = assert(io.open(path, "rb")); helpers.assert_eq(file:read("*a"), foreign); file:close()
		end)
	end)

	helpers.it("does not release action ownership after leader-only helper completion", function()
		with_program(function(actions, auxiliary, _, _, tasks, _, scalar)
			helpers.assert_eq(actions.run_program("tap_3"), true)
			tasks[1]:helper_exit(0)
			helpers.assert_eq(auxiliary.has_pending("gestures"), true)
			helpers.assert_eq(actions.set_action_parameter("tap_3", "run_program", scalar), false)
			tasks[1]:emit("V1 RETIRED 0\n")
			helpers.assert_eq(auxiliary.has_pending("gestures"), false,
				"only the exact worker's final bounded marker completes the receipt")
		end)
	end)

	helpers.it("preserves unrelated outdated parameters while executing the acknowledged program", function()
		with_program(function(actions, _, preferences, _, tasks, path, scalar)
			local Json = require("json")
			local content = '[gestures]\ntap_3 = "run_program"\n[gestures.action_parameters]\n'
				.. '"tap_3__run_program" = ' .. Json.encode(scalar) .. '\n"old__send_text" = 42\n'
			local file = assert(io.open(path, "wb")); file:write(content); file:close()
			local loaded, status = preferences.load(path)
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(loaded.gesture_action_parameters["tap_3__run_program"], scalar)
			helpers.assert_eq(loaded.gesture_action_parameters["old__send_text"], nil)
			helpers.assert_eq(preferences.current_view(path), nil,
				"the strict whole-preference view remains unchanged")
			helpers.assert_eq(actions.run_program("tap_3"), true,
				"an unrelated retained outdated field cannot refuse the owned program")
			helpers.assert_eq(#tasks, 1)
			helpers.assert_eq(tasks[1].arguments, { "--owned-program-worker" })
			helpers.assert_eq(tasks[1].request.arguments, { "", "two words", "日本語", "line\nnext" })
			helpers.assert_eq(tasks[1].activations, 1)
			file = assert(io.open(path, "rb")); helpers.assert_eq(file:read("*a"), content); file:close()
			helpers.assert_eq(preferences.source_snapshot(path).content, content)
			tasks[1]:complete()
		end)
	end)

	helpers.it("refuses an unacknowledged replacement even when the program leaves are unchanged", function()
		with_program(function(actions, _, preferences, _, tasks, path)
			local source = preferences.source_snapshot(path)
			local file = assert(io.open(path, "wb")); file:write(source.content .. "\n# external source\n"); file:close()
			helpers.assert_eq(actions.run_program("tap_3"), false)
			helpers.assert_eq(#tasks, 0)
			helpers.assert_eq(preferences.source_snapshot(path), source)
		end)
	end)

	helpers.it("refuses an outdated owned program scalar without modifying its source", function()
		with_program(function(actions, _, preferences, _, tasks, path)
			local content = '[gestures]\ntap_3 = "run_program"\n[gestures.action_parameters]\n'
				.. '"tap_3__run_program" = 42\n'
			local file = assert(io.open(path, "wb")); file:write(content); file:close()
			local _, status = preferences.load(path)
			helpers.assert_eq(status, "ok")
			helpers.assert_eq(actions.run_program("tap_3"), false)
			helpers.assert_eq(#tasks, 0)
			file = assert(io.open(path, "rb")); helpers.assert_eq(file:read("*a"), content); file:close()
			helpers.assert_eq(preferences.source_snapshot(path).content, content)
		end)
	end)

	helpers.it("rechecks exact source before starting a constructed native task", function()
		with_program(function(actions, auxiliary, preferences, native, tasks, path)
			local source = preferences.source_snapshot(path)
			local create = native.task.new
			native.task.new = function(...)
				local task = create(...)
				local file = assert(io.open(path, "wb")); file:write(source.content .. "\n# changed during construction\n"); file:close()
				return task
			end
			helpers.assert_eq(actions.run_program("tap_3"), false)
			helpers.assert_eq(#tasks, 1)
			helpers.assert_eq(tasks[1].starts, 0)
			helpers.assert_eq(auxiliary.has_pending("gestures"), false)
			helpers.assert_eq(preferences.source_snapshot(path), source)
		end)
	end)

	helpers.it("refuses configuration path changes before native adoption", function()
		with_program(function(actions, auxiliary, preferences, native, tasks, path)
			local source = preferences.source_snapshot(path)
			local create = native.task.new
			native.task.new = function(...)
				local task = create(...)
				package.loaded["infra.config_paths"].get = function() return path .. ".foreign" end
				return task
			end
			helpers.assert_eq(actions.run_program("tap_3"), false)
			helpers.assert_eq(#tasks, 1)
			helpers.assert_eq(tasks[1].starts, 0)
			helpers.assert_eq(auxiliary.has_pending("gestures"), false)
			helpers.assert_eq(preferences.source_snapshot(path), source)
		end)
	end)
end)

helpers.describe("private run_program real keyboard port", function()
	helpers.it("executes the same persisted scalar through the actual registered keyboard callback", function()
		with_program(function(actions, _, preferences, native, tasks, path, scalar, _, gesture_port)
			helpers.assert_eq(actions.set_action_parameter("keyboard__cmd_1", "run_program", scalar), true)
			helpers.assert_eq(preferences.save(path, {}, {}, { gestures = gesture_port }), true)
			local keyboard = require("modules.shortcuts.keyboard_shortcuts")
			helpers.assert_eq(keyboard.set_action("cmd_1", "run_program"), true)
			helpers.assert_eq(keyboard.start(), true)
			local count, registered = 0, nil
			for _, item in ipairs(native.hotkey._bound) do
				if item.key == "1" and #item.mods == 1 and item.mods[1] == "cmd" then
					count, registered = count + 1, item
				end
			end
			helpers.assert_eq(count, 1)
			local accepted = registered.pressed_fn()
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(#tasks, 1)
			helpers.assert_eq(tasks[1].starts, 1)
			helpers.assert_eq(tasks[1].arguments, { "--owned-program-worker" })
			helpers.assert_eq(tasks[1].request.arguments, { "", "two words", "日本語", "line\nnext" })
			helpers.assert_eq(tasks[1].activations, 1)
			tasks[1]:complete()
			helpers.assert_eq(keyboard.stop(), true)
		end)
	end)
end)

helpers.describe("private run_program actual scoped pause", function()
	helpers.it("retains native program debt through aggregate cleanup and fences held delivery", function()
		with_program(function(actions, auxiliary, _, _, tasks)
			helpers.assert_eq(actions.run_program("tap_3"), true)
			helpers.assert_eq(actions.force_cleanup("gestures"), false)
			helpers.assert_eq(auxiliary.is_paused("gestures"), true)
			helpers.assert_eq(auxiliary.has_pending("gestures"), true)
			helpers.assert_eq(actions.run_program("tap_3"), false)
			helpers.assert_eq(#tasks, 1)
			tasks[1]:complete(15)
			helpers.assert_eq(auxiliary.has_pending("gestures"), false)
			helpers.assert_eq(actions.run_program("tap_3"), false)
			helpers.assert_eq(#tasks, 1)
		end)
	end)
end)
