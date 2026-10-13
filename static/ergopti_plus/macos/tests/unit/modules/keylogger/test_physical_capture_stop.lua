--- tests/unit/modules/keylogger/test_physical_capture_stop.lua

--- Proves exact-session stop notification without loading any production runtime.
local helpers = require("tests.helpers")
local with_capture = require("tests.support.physical_capture_fixture").run

local function start(capture, controls, phase)
	capture.init(controls.dependencies)
	helpers.assert_true(capture.start(controls.options))
	if phase ~= "verifier" then controls.verified() end
	if phase == "stream" then controls.open() end
end

helpers.describe("dormant physical capture stop notification", function()
	helpers.it("returns immediate absence without retaining an observer for a future owner", function()
		with_capture(function(capture, observed, controls)
			local calls = 0
			local function stopped(complete)
				calls = calls + 1
				helpers.assert_eq(complete, true)
			end
			helpers.assert_true(capture.stop(stopped))
			helpers.assert_eq(calls, 0)
			helpers.assert_eq(capture.status().state, "uninitialized")
			helpers.assert_eq(observed.spawns, {})
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
			start(capture, controls, "verifier")
			helpers.assert_eq(capture.stop(stopped), false)
			observed.tasks[1].settle()
			helpers.assert_eq(calls, 1, "Only an explicitly stopped actual owner creates a notification")
		end)
	end)

	for _, phase in ipairs({ "verifier", "clock", "stream" }) do
		helpers.it("awaits the exact " .. phase .. " settlement before one stop notification", function()
			with_capture(function(capture, observed, controls)
				start(capture, controls, phase)
				local task = observed.tasks[#observed.tasks]
				local calls = 0
				local function stopped(complete)
					calls = calls + 1
					helpers.assert_eq(complete, true)
					helpers.assert_eq(capture.status().state, "stopped")
					helpers.assert_eq(controls.mode.credit_source(), "legacy")
				end
				helpers.assert_eq(capture.stop(stopped), false)
				helpers.assert_eq(calls, 0)
				helpers.assert_eq(controls.mode.credit_source(), "gap")
				helpers.assert_eq(capture.start(controls.options), false)
				task.done(0, "clock\n", "")
				helpers.assert_eq(calls, 0, "Completion is not exact native settlement")
				task.settle()
				helpers.assert_eq(calls, 1)
				task.done(0, "clock\n", "")
				task.settle()
				helpers.assert_true(capture.stop(stopped))
				helpers.assert_eq(calls, 1, "The same retained observer is never replayed")
				helpers.assert_eq(observed.errors, {})
			end)
		end)
	end

	helpers.it("bounds one observer identity across retries without replacing its pending obligation", function()
		with_capture(function(capture, observed, controls)
			start(capture, controls, "clock")
			local task = observed.tasks[2]
			task.refuse_stop = true
			local calls, replacement_calls = 0, 0
			local function stopped() calls = calls + 1 end
			helpers.assert_eq(capture.stop(stopped), false)
			local stops = task.stops
			local accepted, reason = capture.stop(function() replacement_calls = replacement_calls + 1 end)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(reason, "observer_conflict")
			helpers.assert_eq(task.stops, stops, "Conflicting registration cannot replay native cancellation")
			helpers.assert_eq(capture.stop(stopped), false)
			helpers.assert_eq(task.stops, stops + 1)
			helpers.assert_eq(calls, 0)
			helpers.assert_eq(replacement_calls, 0)
			task.settle()
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(replacement_calls, 0)
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
		end)
	end)

	helpers.it("returns already stopped without retaining a late observer for its successor", function()
		with_capture(function(capture, observed, controls)
			start(capture, controls, "verifier")
			helpers.assert_eq(capture.stop(), false)
			observed.tasks[1].settle()
			local calls = 0
			local function stopped(complete) helpers.assert_eq(complete, true); calls = calls + 1 end
			helpers.assert_true(capture.stop(stopped))
			helpers.assert_eq(calls, 0)
			helpers.assert_true(capture.stop(stopped))
			helpers.assert_eq(calls, 0)
			helpers.assert_eq(observed.spawns[1].executable, "/usr/bin/codesign")
			helpers.assert_true(capture.start(controls.options))
			helpers.assert_eq(capture.stop(stopped), false)
			observed.tasks[2].settle()
			helpers.assert_eq(calls, 1)
		end)
	end)

	helpers.it("keeps a notification pending while native retirement precedes refused accounting release", function()
		with_capture(function(capture, observed, controls)
			local accept = true
			controls.mode.bind_settlement({}, function() return accept end)
			start(capture, controls, "verifier")
			local calls = 0
			local function stopped() calls = calls + 1 end
			accept = false
			helpers.assert_eq(capture.stop(stopped), false)
			observed.tasks[1].settle()
			helpers.assert_eq(capture.status().settled, true, "Native debt is gone but accounting release is still refused")
			helpers.assert_eq(capture.status().state, "stopping")
			helpers.assert_eq(controls.mode.credit_source(), "gap")
			helpers.assert_eq(calls, 0)
			helpers.assert_eq(capture.start(controls.options), false)
			helpers.assert_eq(capture.stop(stopped), false)
			helpers.assert_eq(calls, 0)
			accept = true
			helpers.assert_true(capture.stop(stopped))
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
		end)
	end)

	helpers.it("keeps an interrupt refusal pending without claiming native cancellation or notification", function()
		with_capture(function(capture, observed, controls)
			local accept = true
			controls.mode.bind_settlement({}, function() return accept end)
			start(capture, controls, "stream")
			local calls = 0
			local function stopped() calls = calls + 1 end
			accept = false
			local completed, reason = capture.stop(stopped)
			helpers.assert_eq(completed, false)
			helpers.assert_eq(reason, "settlement_refused")
			helpers.assert_eq(observed.tasks[3].stops, 0)
			helpers.assert_eq(calls, 0)
			helpers.assert_eq(capture.start(controls.options), false)
			accept = true
			helpers.assert_eq(capture.stop(stopped), false)
			observed.tasks[3].settle()
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
		end)
	end)

	for _, phase in ipairs({ "verifier", "clock", "stream" }) do
		helpers.it("retains the observer through " .. phase .. " acquisition and synchronous prepared cancellation", function()
			with_capture(function(capture, observed, controls)
				local calls = 0
				local function stopped() calls = calls + 1 end
				controls.on_spawn = function(task)
					local matches = phase == "verifier" and task.executable == "/usr/bin/codesign"
						or phase == "clock" and task.arguments[1] == "--hs274-clock"
						or phase == "stream" and task.arguments[1] == "--hs274-capture"
					if matches then
						helpers.assert_eq(capture.stop(stopped), false)
						helpers.assert_eq(calls, 0)
						helpers.assert_eq(capture.start(controls.options), false)
					end
				end
				capture.init(controls.dependencies)
				local started = capture.start(controls.options)
				if phase == "verifier" then helpers.assert_eq(started, false)
				else
					helpers.assert_true(started)
					controls.verified()
					if phase == "stream" then controls.clocked() end
				end
				local task = observed.tasks[#observed.tasks]
				helpers.assert_eq(task.started, nil)
				helpers.assert_eq(task.stops, 1)
				helpers.assert_eq(calls, 1)
				helpers.assert_eq(capture.status().state, "stopped")
				helpers.assert_eq(controls.mode.credit_source(), "legacy")
				helpers.assert_eq(observed.errors, {})
			end)
		end)
	end

	for _, accepted in ipairs({ true, false }) do
		helpers.it("settles notification after canceled source selection returns " .. tostring(accepted), function()
			with_capture(function(capture, observed, controls)
				local calls, selecting = 0, true
				local function stopped() calls = calls + 1 end
				controls.mode.bind_settlement({}, function()
					if selecting then
						selecting = false
						helpers.assert_eq(capture.stop(stopped), false)
						helpers.assert_eq(calls, 0)
						return accepted
					end
					return true
				end)
				capture.init(controls.dependencies)
				helpers.assert_eq(capture.start(controls.options), false)
				helpers.assert_eq(calls, 1)
				helpers.assert_eq(observed.spawns, {})
				helpers.assert_eq(controls.mode.credit_source(), "legacy")
				helpers.assert_true(capture.start(controls.options), "A canceled selection cannot retain phantom ownership")
			end)
		end)
	end

	helpers.it("defers notification and successor authority until clock publication unwinds", function()
		with_capture(function(capture, observed, controls)
			local calls = 0
			local function stopped() calls = calls + 1 end
			controls.dependencies.clock_ready = function()
				helpers.assert_eq(capture.stop(stopped), false)
				helpers.assert_eq(calls, 0)
				helpers.assert_eq(capture.start(controls.options), false)
				return true
			end
			start(capture, controls, "clock")
			controls.clocked()
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(#observed.spawns, 2)
			helpers.assert_eq(capture.status().state, "stopped")
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
		end)
	end)

	helpers.it("contains accounting release reentry until its exact publication unwinds", function()
		with_capture(function(capture, observed, controls)
			local calls, releasing = 0, false
			local function stopped() calls = calls + 1 end
			controls.mode.bind_settlement({}, function()
				if releasing then
					helpers.assert_eq(capture.stop(stopped), false)
					helpers.assert_eq(calls, 0)
				end
				return true
			end)
			start(capture, controls, "verifier")
			helpers.assert_eq(capture.stop(stopped), false)
			releasing = true
			observed.tasks[1].settle()
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
			helpers.assert_eq(observed.errors, {})
		end)
	end)

	helpers.it("commits notification before callback reentry and keeps old continuations inert after a successor", function()
		with_capture(function(capture, observed, controls)
			start(capture, controls, "clock")
			local old_task = observed.tasks[2]
			local calls = 0
			local stopped
			stopped = function(complete)
				calls = calls + 1
				helpers.assert_eq(complete, true)
				helpers.assert_true(capture.stop(stopped))
				helpers.assert_eq(calls, 1, "Reentrant notification must not replay itself")
				helpers.assert_true(capture.start(controls.options))
			end
			helpers.assert_eq(capture.stop(stopped), false)
			old_task.settle()
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(#observed.spawns, 3)
			helpers.assert_eq(capture.status().state, "verifying")
			old_task.done(0, "clock\n", "")
			old_task.settle()
			helpers.assert_eq(#observed.spawns, 3)
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(observed.errors, {})
		end)
	end)

	helpers.it("contains callback failure after stop commitment without retrying notification", function()
		with_capture(function(capture, observed, controls)
			start(capture, controls, "verifier")
			local calls = 0
			local function stopped() calls = calls + 1; error("Stop observer receipt failed") end
			helpers.assert_eq(capture.stop(stopped), false)
			observed.tasks[1].settle()
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(capture.status().state, "stopped")
			helpers.assert_eq(controls.mode.credit_source(), "legacy")
			helpers.assert_eq(#observed.errors, 1)
			helpers.assert_true(observed.errors[1]:find("Stop observer receipt failed", 1, true) ~= nil)
			helpers.assert_true(capture.stop(stopped))
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(#observed.errors, 1)
			helpers.assert_true(capture.start(controls.options))
		end)
	end)

	helpers.it("rejects an invalid observer before changing the live native owner", function()
		with_capture(function(capture, observed, controls)
			start(capture, controls, "verifier")
			local ok, reason = pcall(capture.stop, false)
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(reason):find("Invalid physical stop observer", 1, true) ~= nil)
			helpers.assert_eq(capture.status().state, "verifying")
			helpers.assert_eq(observed.tasks[1].stops, 0)
			local calls = 0
			helpers.assert_eq(capture.stop(function() calls = calls + 1 end), false)
			observed.tasks[1].settle()
			helpers.assert_eq(calls, 1, "A valid observer on the same healthy owner is admitted")
		end)
	end)
end)
