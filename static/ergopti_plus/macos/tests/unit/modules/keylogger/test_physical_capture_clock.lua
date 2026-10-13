--- tests/unit/modules/keylogger/test_physical_capture_clock.lua

--- Proves clock startup authority and retained native debt before opening capture.
local helpers = require("tests.helpers")
local with_capture = require("tests.support.physical_capture_fixture").run

local function begin(capture, controls)
	capture.init(controls.dependencies)
	helpers.assert_true(capture.start(controls.options))
	controls.verified()
end

local function clock_task(observed)
	helpers.assert_eq(observed.spawns[2].arguments, { "--hs274-clock" })
	return observed.tasks[2]
end

helpers.describe("dormant physical capture clock startup", function()
	helpers.it("publishes verified native clock only after successful start completion and exact settlement", function()
		with_capture(function(capture, observed, controls)
			begin(capture, controls)
			local task = clock_task(observed)
			helpers.assert_eq(capture.status().state, "clocking")
			helpers.assert_eq(observed.clocks, {})
			helpers.assert_eq(controls.mode.credit_source(), "gap")
			task.done(0, "clock\n", "")
			helpers.assert_eq(#observed.spawns, 2, "Completion cannot discharge the native clock worker")
			helpers.assert_eq(observed.clocks, {})
			task.settle()
			helpers.assert_eq(#observed.clocks, 1)
			helpers.assert_eq(observed.clocks[1].information, controls.frames.clock)
			helpers.assert_eq(observed.clocks[1].convert("45824088534"), 1909337022250)
			controls.frames.clock.numer = 1
			observed.clocks[1].information.denom = 1
			helpers.assert_eq(observed.clocks[1].convert("3"), 125, "The published converter owns its timebase")
			helpers.assert_eq(observed.spawns[3], { executable = controls.options.executable,
				arguments = { "--hs274-capture", "25" } })
			helpers.assert_eq(capture.status().state, "opening")
			helpers.assert_eq(observed.warnings, {})
		end)
	end)

	helpers.it("retains the clock worker after cancellation until its exact settlement", function()
		with_capture(function(capture, observed, controls)
			begin(capture, controls)
			local task = clock_task(observed)
			task.refuse_stop = true
			helpers.assert_eq(capture.stop(), false)
			helpers.assert_eq(capture.status().settled, false)
			helpers.assert_eq(capture.start(controls.options), false)
			task.done(0, "clock\n", "")
			helpers.assert_eq(observed.clocks, {})
			helpers.assert_eq(#observed.spawns, 2)
			helpers.assert_eq(controls.mode.credit_source(), "gap")
			task.settle()
			helpers.assert_eq(capture.status().state, "stopped")
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
			helpers.assert_true(capture.start(controls.options))
			task.done(0, "clock\n", "")
			task.settle()
			helpers.assert_eq(#observed.spawns, 3, "A retired clock cannot start its successor's stream")
		end)
	end)

	helpers.it("settles a prepared clock returned after cancellation during acquisition", function()
		with_capture(function(capture, observed, controls)
			controls.on_spawn = function(task)
				if task.arguments[1] == "--hs274-clock" then
					helpers.assert_eq(capture.stop(), false)
					helpers.assert_eq(capture.start(controls.options), false)
				end
			end
			begin(capture, controls)
			local task = clock_task(observed)
			helpers.assert_eq(task.started, nil)
			helpers.assert_eq(task.stops, 1)
			helpers.assert_eq(observed.clocks, {})
			helpers.assert_eq(#observed.spawns, 2)
			helpers.assert_eq(capture.status().state, "stopped")
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
			helpers.assert_eq(observed.errors, {})
		end)
	end)

	helpers.it("never grants clock publication from completion and settlement with refused start", function()
		with_capture(function(capture, observed, controls)
			controls.on_spawn = function(task)
				if task.arguments[1] == "--hs274-clock" then
					-- Extra hardening: ShellRunner suppresses business completion on a refused native start.
					function task.start() task.done(0, "clock\n", ""); task.settle(); return false end
				end
			end
			begin(capture, controls)
			clock_task(observed)
			helpers.assert_eq(observed.clocks, {})
			helpers.assert_eq(#observed.spawns, 2)
			helpers.assert_eq(capture.status().state, "unavailable")
			helpers.assert_eq(capture.status().reason, "clock_start_refused")
			helpers.assert_eq(#observed.warnings, 1)
			helpers.assert_eq(observed.errors, {})
			helpers.assert_true(capture.stop())
		end)
	end)

	helpers.it("refuses context ownership without opening a capture stream", function()
		for _, verdict in ipairs({ "false", "nil", "truthy", "thrown" }) do
			with_capture(function(capture, observed, controls)
				controls.dependencies.clock_ready = function()
					if verdict == "thrown" then error("Context owner unavailable") end
					if verdict == "false" then return false end
					if verdict == "truthy" then return 1 end
				end
				begin(capture, controls)
				local task = observed.tasks[2]
				task.done(0, "clock\n", "")
				task.settle()
				task.done(0, "clock\n", "")
				task.settle()
				helpers.assert_eq(capture.status().reason, "clock_context_refused")
				helpers.assert_eq(capture.status().state, "unavailable")
				helpers.assert_eq(#observed.spawns, 2)
				helpers.assert_eq(#observed.warnings, 1)
				helpers.assert_eq(observed.errors, {})
				helpers.assert_eq(controls.mode.credit_source(), "gap")
				helpers.assert_eq(capture.start(controls.options), false)
			end)
		end
	end)

	helpers.it("latches stop during clock publication until its context owner returns", function()
		with_capture(function(capture, observed, controls)
			controls.dependencies.clock_ready = function(_, convert)
				helpers.assert_eq(convert("3"), 125)
				helpers.assert_eq(capture.stop(), false)
				helpers.assert_eq(capture.status().settled, false)
				helpers.assert_eq(capture.start(controls.options), false)
				helpers.assert_eq(controls.mode.credit_source(), "gap")
				return true
			end
			begin(capture, controls)
			controls.clocked()
			helpers.assert_eq(#observed.spawns, 2)
			helpers.assert_eq(capture.status().state, "stopped")
			helpers.assert_eq(capture.status().settled, true)
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
			helpers.assert_eq(observed.warnings, {})
			helpers.assert_eq(observed.errors, {})
		end)
	end)

	helpers.it("revalidates cancellation from the injected JSON decoder before clock publication", function()
		with_capture(function(capture, observed, controls)
			local decode = controls.dependencies.decode
			controls.dependencies.decode = function(line)
				helpers.assert_true(capture.stop())
				return decode(line)
			end
			begin(capture, controls)
			controls.clocked()
			helpers.assert_eq(observed.clocks, {})
			helpers.assert_eq(#observed.spawns, 2)
			helpers.assert_eq(capture.status().state, "stopped")
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
		end)
	end)

	helpers.it("rejects unsupported clock versions with one typed warning and no context publication", function()
		with_capture(function(capture, observed, controls)
			controls.frames.clock.version = 2
			begin(capture, controls)
			controls.clocked()
			helpers.assert_eq(capture.status().state, "unavailable")
			helpers.assert_eq(capture.status().reason, "unsupported_clock_version")
			helpers.assert_eq(#observed.warnings, 1)
			helpers.assert_eq(observed.errors, {})
			helpers.assert_eq(observed.clocks, {})
			helpers.assert_eq(#observed.spawns, 2)
			helpers.assert_eq(controls.mode.credit_source(), "gap")
			helpers.assert_true(capture.stop())
		end)
	end)

	helpers.it("requires exact native JSON domain fields and bounded positive integer timebase", function()
		local invalid = {
			{}, { version = "1", domain = "mach_absolute_time", numer = 125, denom = 3 },
			{ version = 1, domain = "wall_clock", numer = 125, denom = 3 },
			{ version = 1, domain = "mach_absolute_time", numer = 125, denom = 3, extra = true },
			{ version = 1, domain = "mach_absolute_time", numer = 125 },
			{ version = 1, domain = "mach_absolute_time", numer = 0, denom = 3 },
			{ version = 1, domain = "mach_absolute_time", numer = 125, denom = 0 },
			{ version = 1, domain = "mach_absolute_time", numer = 1.5, denom = 3 },
			{ version = 1, domain = "mach_absolute_time", numer = 125, denom = "3" },
			{ version = 1, domain = "mach_absolute_time", numer = 4294967296, denom = 3 },
		}
		for _, receipt in ipairs(invalid) do
			with_capture(function(capture, observed, controls)
				controls.frames.clock = receipt
				begin(capture, controls)
				controls.clocked()
				helpers.assert_eq(capture.status().state, "unavailable")
				helpers.assert_eq(capture.status().reason, "invalid_clock")
				helpers.assert_eq(#observed.warnings, 1)
				helpers.assert_eq(observed.errors, {})
				helpers.assert_eq(observed.clocks, {})
				helpers.assert_eq(#observed.spawns, 2)
				helpers.assert_eq(controls.mode.credit_source(), "gap")
			end)
		end
	end)

	helpers.it("refuses invalid or undecodable native output even when a decoder returns an object", function()
		for _, outcome in ipairs({ "nil", "oversize", "malformed", "decode_error" }) do
			with_capture(function(capture, observed, controls)
				local output
				if outcome == "oversize" then output = string.rep("x", 1025) end
				if outcome == "malformed" then output = "{truncated" end
				if outcome == "decode_error" then
					output = "clock\n"
					controls.dependencies.decode = function() return controls.frames.clock, "duplicate JSON key" end
				end
				begin(capture, controls)
				observed.tasks[2].done(0, output, "")
				observed.tasks[2].settle()
				helpers.assert_eq(capture.status().reason, "invalid_clock")
				helpers.assert_eq(#observed.warnings, 1)
				helpers.assert_eq(observed.clocks, {})
				helpers.assert_eq(#observed.spawns, 2)
			end)
		end
	end)

	helpers.it("requires successful completion separately from native retirement", function()
		for _, outcome in ipairs({ "incomplete", "refused" }) do
			with_capture(function(capture, observed, controls)
				begin(capture, controls)
				if outcome == "refused" then observed.tasks[2].done(1, "clock\n", "native failure") end
				observed.tasks[2].settle()
				helpers.assert_eq(capture.status().reason, outcome == "incomplete" and "clock_incomplete" or "clock_command_refused")
				helpers.assert_eq(#observed.warnings, 1)
				helpers.assert_eq(observed.clocks, {})
				helpers.assert_eq(#observed.spawns, 2)
				helpers.assert_true(capture.stop())
			end)
		end
	end)

	helpers.it("accepts synchronous native clock completion only after start acceptance commits", function()
		with_capture(function(capture, observed, controls)
			controls.on_spawn = function(task)
				if task.arguments[1] == "--hs274-clock" then
					function task.start()
						task.started = true
						task.done(0, "clock\n", "")
						task.settle()
						helpers.assert_eq(observed.clocks, {})
						helpers.assert_eq(#observed.spawns, 2)
						return true
					end
				end
			end
			begin(capture, controls)
			helpers.assert_eq(#observed.clocks, 1)
			helpers.assert_eq(#observed.spawns, 3)
			helpers.assert_eq(capture.status().state, "opening")
		end)
	end)

	helpers.it("rejects already-settled clock handles without granting start authority", function()
		for _, verdict in ipairs({ "refused", "completed" }) do
			with_capture(function(capture, observed, controls)
				controls.on_spawn = function(task)
					if task.arguments[1] == "--hs274-clock" then
						-- Refused handles notify synchronously in ShellRunner; the completed
						-- variant before start is separate hostile-callback hardening.
						if verdict == "completed" then task.done(0, "clock\n", "") end
						task.state = "settled"
					end
				end
				begin(capture, controls)
				helpers.assert_eq(observed.tasks[2].started, nil)
				helpers.assert_eq(observed.clocks, {})
				helpers.assert_eq(#observed.spawns, 2)
				helpers.assert_eq(capture.status().reason, "clock_start_refused")
				helpers.assert_eq(#observed.warnings, 1)
				helpers.assert_eq(observed.errors, {})
				helpers.assert_true(capture.stop())
			end)
		end
	end)
end)
