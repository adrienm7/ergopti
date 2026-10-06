--- tests/unit/adapters/test_owned_program_runner.lua

--- Exercises the actual private adapter boundary and closed worker protocol.
local helpers = require("tests.helpers")
local Json = require("json")
local DIGEST = string.rep("a", 64)
local SOURCE = { source_path = "/private/config.toml", source_sha256 = DIGEST }
local HELPER = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"

local function with_runner(body, options)
	options = options or {}
	local saved, old_hs = {}, _G.hs
	for name, value in pairs(package.loaded) do saved[name] = value end
	local native = { tasks = {}, logs = {}, terminals = {} }
	local ok, failure = xpcall(function()
		local logger = helpers.make_logger_stub()
		for _, level in ipairs({ "error", "warn", "trace", "done" }) do
			logger[level] = function(_, template, ...) native.logs[#native.logs + 1] = string.format(template, ...) end
		end
		package.loaded["infra.logger"] = logger
		package.loaded["adapters.task_environment"] = nil
		package.loaded["platform.remap.lease_helper"] = { resolve = function()
			if options.missing_helper then return nil, "unavailable" end
			return HELPER, nil, { ERGOPTI_LAUNCHER_EXECUTABLE = HELPER, ERGOPTI_LAUNCHER_DEVICE = "42", ERGOPTI_LAUNCHER_INODE = "73" }
		end }
		if options.real_helper then package.loaded["platform.remap.lease_helper"] = nil end
		_G.hs = { task = { new = function(executable, done, chunk, arguments)
			if options.construct_throw then error("PRIVATE executable and argv") end
			local task = { executable = executable, arguments = arguments, inputs = {}, running = false, terminate_calls = 0,
				env = { PATH = "/usr/bin:/bin", HOME = "/Users/tester", ERGOPTI_LAUNCHER_PID = "42",
					ERGOPTI_LOG_PORT = "1234", ERGOPTI_LOG_TOKEN = "private launcher token" } }
			function task:environment() local result = {}; for key, value in pairs(self.env) do result[key] = value end; return result end
			function task:setEnvironment(value) self.env = value; return self end
			function task:start()
				self.running = true
				if options.on_start then options.on_start(self) end
				if options.start_throw then error("PRIVATE executable and argv") end
				if options.start_false then return false end
				return self
			end
			function task:isRunning() return self.running end
			function task:setInput(value)
				self.inputs[#self.inputs + 1] = value
				if options.on_input then options.on_input(self, value) end
				return self
			end
			function task:closeInput()
				if options.close_false then return false end
				self.closed = true; return self
			end
			function task:terminate() self.terminate_calls = self.terminate_calls + 1; return self end
			function task:emit(value, stderr) return chunk(self, value, stderr or "") end
			function task:complete(code, stdout, stderr) self.running = false; return done(code or 0, stdout or "", stderr or "") end
			native.tasks[#native.tasks + 1] = task
			return task
		end } }
		for _, name in ipairs({ "adapters.shell_runner", "adapters.owned_program_runner" }) do package.loaded[name] = nil end
		local runner = require("adapters.shell_runner")
		local function create(admitted, source)
			return runner.spawn_private("/private/secret-tool", { "private argument", "" }, function(success, status)
				native.terminals[#native.terminals + 1] = { success, status }
			end, admitted or function() return true end, source or SOURCE)
		end
		body(create, native, runner)
	end, debug.traceback)
	_G.hs = old_hs
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not ok then error(failure, 0) end
end

helpers.describe("native private program supervision", function()
	helpers.it("does not treat leader-only exit as tree retirement", function()
		with_runner(function(create, native)
			local handle = create()
			helpers.assert_eq(handle.start(), true)
			native.tasks[1]:complete(0)
			helpers.assert_eq(handle.isSettled(), false)
			helpers.assert_eq(#native.terminals, 0)
		end)
	end)

	helpers.it("starts only the bundled supervisor and sends source proof over stdin", function()
		with_runner(function(create, native)
			local handle = create()
			helpers.assert_eq(handle.start(), true)
			local task = native.tasks[1]
			helpers.assert_eq(task.executable, HELPER)
			helpers.assert_eq(task.arguments, { "--owned-program-worker" })
			local request = Json.decode_lossless(task.inputs[1])
			helpers.assert_eq(request.source_path, SOURCE.source_path)
			helpers.assert_eq(request.source_sha256, DIGEST)
			helpers.assert_eq(request.executable, "/private/secret-tool")
			helpers.assert_eq(request.arguments[1], "private argument")
			helpers.assert_eq(request.arguments[2], "")
			helpers.assert_eq(task.closed, nil)
		end)
	end)

	helpers.it("never signals an ambiguous helper start instead of owned cancellation", function()
		with_runner(function(create, native)
			local handle = create()
			helpers.assert_eq(handle.start(), false)
			helpers.assert_eq(native.tasks[1].terminate_calls, 0)
			helpers.assert_eq(handle.isSettled(), false)
		end, { start_throw = true })
	end)
end)

helpers.describe("closed native supervisor receipts", function()
	helpers.it("activates only after fragmented HELD and waits for physical helper completion", function()
		with_runner(function(create, native)
			local rechecks = 0
			local handle = create(function() rechecks = rechecks + 1; return true end)
			helpers.assert_eq(handle.start(), true)
			local task = native.tasks[1]
			task:emit("V1 H"); task:emit("ELD\n")
			helpers.assert_eq(rechecks, 2)
			helpers.assert_eq(task.inputs[2], "ACTIVATE\n")
			helpers.assert_eq(task.closed, nil)
			task:emit("V1 ACTIVE\nV1 RETIRED 17\n")
			helpers.assert_eq(handle.isSettled(), false)
			helpers.assert_eq(#native.terminals, 0)
			task:complete(0)
			helpers.assert_eq(handle.isSettled(), true)
			helpers.assert_eq(native.terminals, { { false, 17 } })
		end)
	end)

	helpers.it("closes held input when exact captured admission becomes stale", function()
		with_runner(function(create, native)
			local admitted = true
			local handle = create(function() return admitted end)
			helpers.assert_eq(handle.start(), true)
			admitted = false
			local task = native.tasks[1]
			task:emit("V1 HELD\n")
			helpers.assert_eq(#task.inputs, 1)
			helpers.assert_eq(task.closed, true)
			helpers.assert_eq(task.terminate_calls, 0)
			task:emit("V1 PENDING 0\nV1 RETIRED 137\n")
			helpers.assert_eq(handle.isSettled(), false)
			task:complete(0)
			helpers.assert_eq(handle.isSettled(), true)
		end)
	end)

	helpers.it("contains reentrant cancellation during the HELD admission callback", function()
		with_runner(function(create, native)
			local handle, calls
			calls = 0
			handle = create(function()
				calls = calls + 1
				if calls == 2 then handle.terminate() end
				return true
			end)
			helpers.assert_eq(handle.start(), true)
			local task = native.tasks[1]
			task:emit("V1 HELD\n")
			helpers.assert_eq(#task.inputs, 1)
			helpers.assert_eq(task.closed, true)
			task:emit("V1 RETIRED 137\n"); task:complete(0)
			helpers.assert_eq(handle.isSettled(), true)
		end)
	end)

	helpers.it("keeps spontaneous native PENDING debt until trusted retirement", function()
		with_runner(function(create, native)
			local handle = create(); helpers.assert_eq(handle.start(), true)
			local task = native.tasks[1]
			task:emit("V1 HELD\nV1 ACTIVE\nV1 PENDING 5\n")
			helpers.assert_eq(task.closed, true)
			helpers.assert_eq(handle.isSettled(), false)
			task:emit("V1 RETIRED 137\n"); task:complete(0)
			helpers.assert_eq(handle.isSettled(), true)
		end)
	end)

	helpers.it("accepts only the exact helper's bounded final stream after physical completion", function()
		with_runner(function(create, native)
			local handle = create(); helpers.assert_eq(handle.start(), true)
			local task = native.tasks[1]
			task:emit("V1 HELD\nV1 ACTIVE\n")
			task:complete(0)
			helpers.assert_eq(handle.isSettled(), false)
			task:emit("V1 RETIRED 0\n")
			helpers.assert_eq(handle.isSettled(), true)
			helpers.assert_eq(native.terminals, { { true, 0 } })
		end)
	end)

	helpers.it("retains a partial final marker through helper completion until the exact suffix arrives", function()
		with_runner(function(create, native)
			local handle = create(); helpers.assert_eq(handle.start(), true)
			local task = native.tasks[1]
			task:emit("V1 HELD\nV1 ACTIVE\nV1 RETI")
			task:complete(0)
			helpers.assert_eq(handle.isSettled(), false)
			task:emit("RED 17\n")
			helpers.assert_eq(handle.isSettled(), true)
			helpers.assert_eq(native.terminals, { { false, 17 } })
		end)
	end)

	helpers.it("refuses terminal trailing junk before any business or retirement observer", function()
		with_runner(function(create, native)
			local handle = create(); helpers.assert_eq(handle.start(), true)
			local task, observed = native.tasks[1], 0
			handle.onSettled(function() observed = observed + 1 end)
			task:emit("V1 HELD\nV1 ACTIVE\n"); task:complete(0)
			task:emit("V1 RETIRED 0\nV1 JUNK\n")
			helpers.assert_eq(handle.isSettled(), false)
			helpers.assert_eq(#native.terminals, 0)
			helpers.assert_eq(observed, 0)
		end)
	end)

	helpers.it("keeps final settlement immutable across stale postretirement chunks", function()
		with_runner(function(create, native)
			local handle = create(); helpers.assert_eq(handle.start(), true)
			local task, observed = native.tasks[1], 0
			handle.onSettled(function() observed = observed + 1 end)
			task:emit("V1 HELD\nV1 ACTIVE\nV1 RETIRED 0\n"); task:complete(0)
			helpers.assert_eq(handle.isSettled(), true)
			task:emit("V1 JUNK\n")
			helpers.assert_eq(handle.isSettled(), true)
			helpers.assert_eq(#native.terminals, 1)
			helpers.assert_eq(observed, 1)
		end)
	end)

	for _, marker in ipairs({ "V1 UNKNOWN\n", "V1 RETIRED 256\n", "V1 REFUSED 00\n", "V1 HELD\nV1 HELD\n", "V1 RETIRED 0", string.rep("x", 513) }) do
		helpers.it("retains ownership after malformed or incomplete marker " .. #marker .. ":" .. marker:sub(1, 10), function()
			with_runner(function(create, native)
				local handle = create(); helpers.assert_eq(handle.start(), true)
				local task = native.tasks[1]
				task:emit(marker); task:complete(0)
				helpers.assert_eq(handle.isSettled(), false)
				helpers.assert_eq(#native.terminals, 0)
				helpers.assert_eq(task.terminate_calls, 0)
			end)
		end)
	end

	helpers.it("requires successful helper exit even after trusted retirement", function()
		with_runner(function(create, native)
			local handle = create(); helpers.assert_eq(handle.start(), true)
			local task = native.tasks[1]
			task:emit("V1 HELD\nV1 ACTIVE\nV1 RETIRED 0\n"); task:complete(1)
			helpers.assert_eq(handle.isSettled(), false)
			helpers.assert_eq(#native.terminals, 0)
		end)
	end)

	helpers.it("does not promote stale ACTIVE cancellation to user success", function()
		with_runner(function(create, native)
			local handle = create(); helpers.assert_eq(handle.start(), true)
			local task = native.tasks[1]
			task:emit("V1 HELD\n")
			local accepted, state = handle.terminate()
			helpers.assert_eq(accepted, true); helpers.assert_eq(state, "pending")
			task:emit("V1 ACTIVE\nV1 RETIRED 0\n"); task:complete(0)
			helpers.assert_eq(handle.isSettled(), true)
			helpers.assert_eq(native.terminals, { { false, 0 } })
		end)
	end)

	for _, mode in ipairs({ "start_throw", "start_false" }) do
		helpers.it("accepts exact REFUSED after ambiguous " .. mode .. " without signaling", function()
			with_runner(function(create, native)
				local handle = create(); helpers.assert_eq(handle.start(), false)
				local task = native.tasks[1]
				helpers.assert_eq(task.terminate_calls, 0)
				task:emit("V1 REFUSED 22\n"); task:complete(0)
				helpers.assert_eq(handle.isSettled(), true)
			end, { [mode] = true })
		end)
	end

	helpers.it("bounds hostile helper output during reentrant start before promotion", function()
		with_runner(function(create, native)
			local handle = create(); helpers.assert_eq(handle.start(), false)
			local task = native.tasks[1]
			helpers.assert_eq(#task.inputs, 0)
			helpers.assert_eq(task.terminate_calls, 0)
			task:complete(0)
			helpers.assert_eq(handle.isSettled(), false)
		end, { on_start = function(task) for _ = 1, 1000 do task:emit(string.rep("x", 512)) end end })
	end)

	helpers.it("refuses source-tree readiness without constructing a task", function()
		with_runner(function(create, native, runner)
			helpers.assert_eq(runner.private_program_available(), false)
			local handle = create()
			helpers.assert_eq(handle.start(), false)
			helpers.assert_eq(handle.isSettled(), true)
			helpers.assert_eq(#native.tasks, 0)
		end, { missing_helper = true })
	end)
end)

helpers.describe("private supervisor admission boundaries", function()
	helpers.it("contains recursive start inside initial admission", function()
		with_runner(function(create, native)
			local handle, calls
			calls = 0
			handle = create(function()
				calls = calls + 1
				if calls == 1 then helpers.assert_eq(handle.start(), false) end
				return true
			end)
			helpers.assert_eq(handle.start(), true)
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(native.tasks[1].terminate_calls, 0)
		end)
	end)

	helpers.it("preserves writable cancellation debt after native EOF refusal", function()
		local options = { close_false = true }
		with_runner(function(create, native)
			local handle = create(); helpers.assert_eq(handle.start(), true)
			local task = native.tasks[1]
			local accepted, state = handle.terminate()
			helpers.assert_eq(accepted, false); helpers.assert_eq(state, "refused")
			helpers.assert_eq(task.closed, nil)
			helpers.assert_eq(handle.isSettled(), false)
			options.close_false = false
			helpers.assert_eq(handle.terminate(), true)
			helpers.assert_eq(task.closed, true)
			task:emit("V1 REFUSED 89\n"); task:complete(0)
			helpers.assert_eq(handle.isSettled(), true)
		end, options)
	end)

	helpers.it("contains an actual constructor throw without exposing private fields", function()
		with_runner(function(create, native)
			local handle = create()
			helpers.assert_eq(handle.start(), false)
			helpers.assert_eq(handle.isSettled(), true)
			helpers.assert_eq(#native.tasks, 0)
			helpers.assert_eq(table.concat(native.logs, "\n"):find("PRIVATE", 1, true), nil)
		end, { construct_throw = true })
	end)

	helpers.it("uses the real resolver to refuse an unbundled driver tree", function()
		with_runner(function(create, native, runner)
			helpers.assert_eq(runner.private_program_available(), false)
			helpers.assert_eq(create().start(), false)
			helpers.assert_eq(#native.tasks, 0)
		end, { real_helper = true })
	end)

	helpers.it("requires trusted prechild REFUSED and exact physical completion", function()
		with_runner(function(create, native)
			local handle = create(); helpers.assert_eq(handle.start(), true)
			local task = native.tasks[1]
			task:emit("V1 REFUSED 22\n")
			helpers.assert_eq(handle.isSettled(), false)
			task:complete(0)
			helpers.assert_eq(handle.isSettled(), true)
			helpers.assert_eq(native.terminals, { { false } })
		end)
	end)
end)

helpers.describe("supervisor ordinary child environment", function()
	helpers.it("resolves exact helper identity without injecting launcher authority or identity overrides", function()
		with_runner(function(create, native)
			local handle = create(); helpers.assert_eq(handle.start(), true)
			helpers.assert_eq(native.tasks[1].env, { PATH = "/usr/bin:/bin", HOME = "/Users/tester" })
		end)
	end)
end)
