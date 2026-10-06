--- tests/unit/modules/gestures/test_program_completion_status.lua

--- Exercises private completion through the real process adapter and action owner.
local helpers = require("tests.helpers")
local Json = require("json")
local SOURCE = { source_path = "/private/config.toml", source_sha256 = string.rep("a", 64) }
local HELPER = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"

local OWNED_MODULES = {
	"modules.gestures.actions_aux_owner", "adapters.shell_runner", "adapters.task_environment",
	"adapters.timer_scheduler", "infra.logger", "tests.stubs.hs", "hs",
	"adapters.owned_program_runner", "platform.remap.lease_helper",
}

local function with_program_owner(callback)
	local saved_hs = _G.hs
	local result = table.pack(xpcall(function()
		helpers.with_fresh_modules(OWNED_MODULES, function()
			local native = require("tests.stubs.hs")
			native.__reset()
			_G.hs = native
			package.loaded["hs"] = native
			local fixture = { tasks = {}, errors = {}, admitted = true }
			local new_timer = native.timer.new
			native.timer.new = function(...)
				local timer = new_timer(...)
				local stop = timer.stop
				function timer:stop()
					local receipt = stop(self)
					if fixture.on_timer_stop then fixture.on_timer_stop() end
					return receipt
				end
				return timer
			end
			local logger = helpers.make_logger_stub()
			logger.error = function(_, format, ...)
				fixture.errors[#fixture.errors + 1] = string.format(format, ...)
			end
			package.loaded["infra.logger"] = logger
			package.loaded["platform.remap.lease_helper"] = { resolve = function()
				return HELPER, nil, { ERGOPTI_LAUNCHER_EXECUTABLE = HELPER,
					ERGOPTI_LAUNCHER_DEVICE = "42", ERGOPTI_LAUNCHER_INODE = "73" }
			end }
			native.task.new = function(executable, terminal, chunks, arguments)
				local task = { running = false, executable = executable, arguments = arguments,
					inputs = {}, env = { HOME = "/Users/tester" } }
				function task:environment()
					local copy = {}; for key, value in pairs(self.env) do copy[key] = value end
					return copy
				end
				function task:setEnvironment(values) self.env = values; return self end
				function task:start() self.running = true; return self end
				function task:isRunning() return self.running end
				function task:terminate() return self end
				function task:emit(value) return chunks(self, value, "") end
				function task:setInput(value)
					self.inputs[#self.inputs + 1] = value
					if value == "ACTIVATE\n" then self:emit("V1 ACTIVE\n")
					else self.request = Json.decode_lossless(value); self:emit("V1 HELD\n") end
					return self
				end
				function task:closeInput() self.closed = true; return self end
				function task:helper_exit(code)
					self.running = false
					terminal(code, "", "")
				end
				function task:complete(code)
					self:emit("V1 RETIRED " .. tostring(code) .. "\n")
					self:helper_exit(0)
				end
				fixture.tasks[#fixture.tasks + 1] = task
				return task
			end
			fixture.owner = require("modules.gestures.actions_aux_owner")
			fixture.runner = require("adapters.shell_runner")
			function fixture.start()
				return fixture.owner.run_program("/private/secret-executable", { "private-argument" },
					function() return fixture.admitted end, "gestures", SOURCE)
			end
			local ok, failure = xpcall(function() callback(fixture) end, debug.traceback)
			for _, task in ipairs(fixture.tasks) do if task.running then task:complete(15) end end
			fixture.owner.stop_programs("gestures")
			if not ok then error(failure, 0) end
		end)
	end, debug.traceback))
	_G.hs = saved_hs
	if not result[1] then error(result[2], 0) end
end

helpers.describe("private program closed completion receipts", function()
	helpers.it("publishes failure before synchronous deadline retirement can release the action entry", function()
		with_program_owner(function(f)
			local failures_at_timer_stop
			f.on_timer_stop = function() failures_at_timer_stop = #f.errors end
			helpers.assert_eq(f.start(), true)
			f.tasks[1]:complete(23)
			helpers.assert_eq(f.errors, { "Private user program failed (native status 23)." })
			helpers.assert_eq(failures_at_timer_stop, 1,
				"the admitted business terminal precedes exact synchronous timer settlement")
			helpers.assert_eq(f.owner.has_pending("gestures"), false)
		end)
	end)

	helpers.it("logs one admitted numeric failure without exposing private process data", function()
		with_program_owner(function(f)
			helpers.assert_eq(f.start(), true)
			f.tasks[1]:complete(23)
			helpers.assert_eq(f.errors, { "Private user program failed (native status 23)." })
			helpers.assert_eq(f.owner.has_pending("gestures"), false)
		end)
	end)

	helpers.it("logs the trusted worker's bounded signal-derived child status", function()
		with_program_owner(function(f)
			helpers.assert_eq(f.start(), true)
			f.tasks[1]:complete(137)
			helpers.assert_eq(f.errors, { "Private user program failed (native status 137)." })
		end)
	end)

	helpers.it("never interprets a signed helper exit as a user program completion", function()
		with_program_owner(function(f)
			helpers.assert_eq(f.start(), true)
			f.tasks[1]:helper_exit(-9)
			helpers.assert_eq(f.errors, {})
			helpers.assert_eq(f.owner.has_pending("gestures"), true)
		end)
	end)

	helpers.it("does not report a successful private program as a failure", function()
		with_program_owner(function(f)
			helpers.assert_eq(f.start(), true)
			f.tasks[1]:complete(0)
			helpers.assert_eq(f.errors, {})
		end)
	end)

	helpers.it("suppresses failure publication after the binding loses admission", function()
		with_program_owner(function(f)
			helpers.assert_eq(f.start(), true)
			f.admitted = false
			f.tasks[1]:complete(23)
			helpers.assert_eq(f.errors, {})
			helpers.assert_eq(f.owner.has_pending("gestures"), false)
		end)
	end)

	helpers.it("suppresses a cancelled child's completion failure", function()
		with_program_owner(function(f)
			helpers.assert_eq(f.start(), true)
			helpers.assert_eq(f.owner.stop_programs("gestures"), false)
			local before = #f.errors
			f.tasks[1]:complete(15)
			helpers.assert_eq(#f.errors, before)
			helpers.assert_eq(f.owner.has_pending("gestures"), false)
		end)
	end)

	helpers.it("projects only Boolean success and integer status from the native adapter", function()
		with_program_owner(function(f)
			local received
			local handle = f.runner.spawn_private("/private/secret-executable", { "private-argument" },
				function(...) received = table.pack(...) end, function() return true end, SOURCE)
			helpers.assert_eq(handle.start(), true)
			helpers.assert_eq(f.tasks[1].executable, HELPER)
			helpers.assert_eq(f.tasks[1].arguments, { "--owned-program-worker" })
			helpers.assert_eq(f.tasks[1].request.executable, "/private/secret-executable")
			helpers.assert_eq(f.tasks[1].request.arguments, { "private-argument" })
			helpers.assert_eq(f.tasks[1].request.source_path, SOURCE.source_path)
			helpers.assert_eq(f.tasks[1].request.source_sha256, SOURCE.source_sha256)
			helpers.assert_eq(f.tasks[1].env.ERGOPTI_LAUNCHER_EXECUTABLE, nil)
			helpers.assert_eq(f.tasks[1].env.ERGOPTI_LAUNCHER_DEVICE, nil)
			helpers.assert_eq(f.tasks[1].env.ERGOPTI_LAUNCHER_INODE, nil)
			helpers.assert_eq(f.tasks[1].env.HOME, "/Users/tester")
			f.tasks[1]:complete(23)
			helpers.assert_eq(received.n, 2)
			helpers.assert_eq(received[1], false)
			helpers.assert_eq(received[2], 23)
		end)
	end)

	helpers.it("reports malformed native status with a closed diagnostic", function()
		with_program_owner(function(f)
			helpers.assert_eq(f.start(), true)
			f.tasks[1]:complete("private-native-status")
			helpers.assert_eq(f.errors, { "Private native supervisor protocol refused." })
			helpers.assert_eq(f.owner.has_pending("gestures"), true)
		end)
	end)

	helpers.it("refuses fractional, infinite and out-of-range native status payloads", function()
		for _, status in ipairs({ 0.5, math.huge, 0 / 0, 2147483648, -2147483649 }) do
			with_program_owner(function(f)
				helpers.assert_eq(f.start(), true)
				f.tasks[1]:complete(status)
				helpers.assert_eq(f.errors, { "Private native supervisor protocol refused." })
				helpers.assert_eq(f.owner.has_pending("gestures"), true)
			end)
		end
	end)
end)
