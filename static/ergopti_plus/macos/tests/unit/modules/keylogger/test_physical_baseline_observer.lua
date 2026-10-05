--- tests/unit/modules/keylogger/test_physical_baseline_observer.lua

--- Completed-baseline publication over actual delivery, transport and capture.
--- Native tasks here are modeled; these controls do not qualify a physical device.
local helpers = require("tests.helpers")
local Delivery = require("modules.keylogger.physical_delivery")
local Frames = require("tests.support.physical_stream_frames")
local Fixture = require("tests.support.physical_capture_fixture")

local function row()
	return { sequence = "1", timestamp = "30", value = "1", device = "41",
		has_page = true, has_usage = true, page = 7, usage = 44, has_cookie = true, cookie = 44 }
end
local function direct(observer)
	local frames = Frames.new("baseline-observer", "7", { "41" })
	local emitted = {}
	local receiver = Delivery.new({ batch_limit = 8, baseline_ready = observer,
		admit = function() return "baseline-observer/7" end, keycode = Frames.keycode,
		context = function() return { allowed = true, app = "Original", timestamp = "2026-10-05 12:00:00.000" } end,
		emit = function(press) emitted[#emitted + 1] = press; return true end })
	frames.batch = { version = 1, kind = "batch", incarnation = frames.opened.incarnation,
		lease = frames.opened.lease, coverage = frames.opened.coverage, records = { row() } }
	return receiver, frames, emitted
end
local function prepare(receiver, frames)
	receiver.open(frames.opened)
	return receiver.baseline(frames.page)
end
local function actual(callback)
	Fixture.run(function(capture, observed, controls)
		local f = { capture = capture, observed = observed, controls = controls, owner = {} }
		controls.frames.batch = { version = 1, kind = "batch", incarnation = controls.frames.opened.incarnation,
			lease = controls.frames.opened.lease, coverage = "complete", records = { row() } }
		local original_clock = controls.dependencies.clock_ready
		controls.dependencies.clock_ready = function(...)
			local accepted = original_clock(...)
			local bound, scope = capture.bind_history_scope(f.owner)
			assert(bound == true, scope)
			f.scope, f.token = scope, scope.identity()
			return accepted
		end
		function f.start()
			assert(capture.init(controls.dependencies) == true)
			assert(capture.start(controls.options) == true)
			controls.verified(); controls.clocked()
		end
		function f.page() observed.tasks[3].chunk(nil, "opened\npage\n") end
		function f.complete(bytes) observed.tasks[3].chunk(nil, bytes or "ready\nbatch\n") end
		callback(f)
	end)
end

helpers.describe("physical completed baseline observer", function()
	helpers.it("validates optional observers before acquiring or binding ports", function()
		local ok = pcall(direct, false)
		helpers.assert_eq(ok, false)
		actual(function(f)
			f.controls.dependencies.baseline_ready = false
			local initialized = pcall(f.capture.init, f.controls.dependencies)
			helpers.assert_eq(initialized, false)
			helpers.assert_eq(#f.observed.tasks, 0)
			f.controls.dependencies.baseline_ready = function() return true end
			helpers.assert_eq(f.capture.init(f.controls.dependencies), true)
		end)
	end)

	helpers.it("preserves absent-observer delivery and native acknowledgement inventory", function()
		local receiver, frames, emitted = direct()
		helpers.assert_eq(prepare(receiver, frames), "5")
		helpers.assert_eq(receiver.ready(), false)
		helpers.assert_eq(receiver.baseline(frames.ready), nil)
		helpers.assert_eq(receiver.deliver(frames.batch), "1")
		helpers.assert_eq(#emitted, 1)
		actual(function(f)
			f.start(); f.page(); f.complete()
			helpers.assert_eq(f.observed.writes, { "0\n", "5\n", "1\n" })
			helpers.assert_eq(#f.observed.credits, 1)
			helpers.assert_eq(f.scope.admitted(f.token), "production-fixture/7")
		end)
	end)

	helpers.it("notifies once only on real completion with no arguments and no raw credit", function()
		local receiver, frames, emitted
		local calls, arguments, ready_inside = 0
		receiver, frames, emitted = direct(function(...)
			calls, arguments = calls + 1, select("#", ...)
			ready_inside = receiver.ready()
			return true
		end)
		prepare(receiver, frames)
		helpers.assert_eq(calls, 0); helpers.assert_eq(receiver.ready(), false)
		helpers.assert_eq(receiver.baseline(frames.ready), nil)
		helpers.assert_eq(calls, 1); helpers.assert_eq(arguments, 0)
		helpers.assert_eq(ready_inside, true); helpers.assert_eq(#emitted, 0)
		local replayed = pcall(receiver.baseline, frames.ready)
		helpers.assert_eq(replayed, false); helpers.assert_eq(calls, 1)
		helpers.assert_eq(receiver.ready(), false)
	end)

	helpers.it("does not notify a premature marker or revive a stopped baseline", function()
		local calls = 0
		local receiver, frames = direct(function() calls = calls + 1; return true end)
		receiver.open(frames.opened)
		local accepted = pcall(receiver.baseline, frames.ready)
		helpers.assert_eq(accepted, false); helpers.assert_eq(calls, 0)
		helpers.assert_eq(receiver.ready(), false)
		receiver, frames = direct(function() calls = calls + 1; return true end)
		prepare(receiver, frames); receiver.stop()
		local stopped = pcall(receiver.baseline, frames.ready)
		helpers.assert_eq(stopped, false)
		helpers.assert_eq(calls, 0); helpers.assert_eq(receiver.ready(), false)
	end)

	helpers.it("requires literal true and preserves the original thrown callback object", function()
		for _, kind in ipairs({ "false", "nil", "truthy", "throw" }) do
			local calls, marker = 0, {}
			local receiver, frames, emitted = direct(function()
				calls = calls + 1
				if kind == "throw" then error(marker, 0) end
				if kind == "false" then return false end
				if kind == "truthy" then return "true" end
			end)
			prepare(receiver, frames)
			local accepted, reason = pcall(receiver.baseline, frames.ready)
			helpers.assert_eq(accepted, false)
			if kind == "throw" then helpers.assert_eq(rawequal(reason, marker), true) end
			helpers.assert_eq(calls, 1); helpers.assert_eq(receiver.ready(), false)
			local delivered = pcall(receiver.deliver, frames.batch)
			helpers.assert_eq(delivered, false)
			helpers.assert_eq(#emitted, 0)
		end
	end)

	helpers.it("cannot admit caught direct baseline or batch reentry", function()
		for _, kind in ipairs({ "baseline", "batch" }) do
			local receiver, frames, emitted
			local nested, calls = nil, 0
			receiver, frames, emitted = direct(function()
				calls = calls + 1
				if kind == "baseline" then nested = pcall(receiver.baseline, frames.ready)
				else nested = pcall(receiver.deliver, frames.batch) end
				return true
			end)
			prepare(receiver, frames)
			local accepted = pcall(receiver.baseline, frames.ready)
			helpers.assert_eq(accepted, false); helpers.assert_eq(nested, false)
			helpers.assert_eq(calls, 1); helpers.assert_eq(receiver.ready(), false)
			helpers.assert_eq(#emitted, 0)
		end
	end)

	helpers.it("publishes actual admitted scope before the next raw frame in the same chunk", function()
		actual(function(f)
			local trace, facts = {}, {}
			f.controls.dependencies.baseline_ready = function(...)
				trace[#trace + 1] = "baseline"
				facts = { arguments = select("#", ...), current = f.scope.current(f.token),
					admitted = f.scope.admitted(f.token), information = f.scope.clock(f.token) }
				return true
			end
			f.controls.dependencies.context = function()
				trace[#trace + 1] = "context"
				return { allowed = true, app = "Original", timestamp = "2026-10-05 12:00:00.000" }
			end
			local emit = f.controls.dependencies.emit
			f.controls.dependencies.emit = function(press) trace[#trace + 1] = "emit"; return emit(press) end
			f.start(); f.page()
			helpers.assert_eq(f.scope.admitted(f.token), nil); helpers.assert_eq(trace, {})
			f.complete()
			helpers.assert_eq(trace, { "baseline", "context", "emit" })
			helpers.assert_eq(facts.arguments, 0); helpers.assert_eq(facts.current, true)
			helpers.assert_eq(facts.admitted, "production-fixture/7")
			helpers.assert_eq(facts.information, f.controls.frames.clock)
			helpers.assert_eq(#f.observed.credits, 1)
		end)
	end)

	helpers.it("fences refused or throwing native observers before context and accounting credit", function()
		for _, kind in ipairs({ "false", "nil", "truthy", "throw" }) do
			actual(function(f)
				local calls, contexts = 0, 0
				f.controls.dependencies.baseline_ready = function()
					calls = calls + 1
					if kind == "throw" then error("baseline-observer-thrown") end
					if kind == "false" then return false end
					if kind == "truthy" then return "accepted" end
				end
				f.controls.dependencies.context = function() contexts = contexts + 1; return { allowed = false } end
				f.start(); f.page(); f.complete()
				helpers.assert_eq(calls, 1); helpers.assert_eq(contexts, 0)
				helpers.assert_eq(#f.observed.credits, 0)
				helpers.assert_eq(f.scope.admitted(f.token), nil)
				helpers.assert_eq(f.controls.mode.admitted_capture(), nil)
				helpers.assert_eq(f.capture.status().state, "failed")
				helpers.assert_eq(f.observed.tasks[3].stops, 1)
				f.complete("ready\n"); helpers.assert_eq(calls, 1)
			end)
		end
	end)

	helpers.it("retains actual native debt when stop is requested inside completion", function()
		actual(function(f)
			local calls, inside = 0, {}
			f.controls.dependencies.baseline_ready = function()
				calls = calls + 1
				local stopped, reason = f.capture.stop()
				inside = { stopped = stopped, reason = reason, current = f.scope.current(f.token),
					settled = f.scope.settled(f.token), admitted = f.scope.admitted(f.token) }
				return true
			end
			f.start(); f.page(); f.complete()
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(inside, { stopped = false, reason = "pending", current = false, settled = false })
			helpers.assert_eq(#f.observed.credits, 0)
			helpers.assert_eq(f.capture.status().state, "stopping")
			helpers.assert_eq(f.observed.tasks[3].stops, 1)
			helpers.assert_eq(f.scope.settled(f.token), false)
			f.observed.tasks[3].settle()
			helpers.assert_eq(f.scope.settled(f.token), true)
			helpers.assert_eq(f.controls.mode.admitted_capture(), nil)
		end)
	end)

	helpers.it("defers synchronous settlement and accounting release until callback unwind", function()
		actual(function(f)
			local calls, inside = 0, {}
			f.controls.dependencies.baseline_ready = function()
				calls = calls + 1
				local stopped, reason = f.capture.stop()
				f.observed.tasks[3].settle()
				inside = { stopped = stopped, reason = reason, settled = f.scope.settled(f.token),
					status_settled = f.capture.status().settled, accounting = f.controls.mode.admitted_capture() }
				return true
			end
			f.start(); f.page(); f.complete()
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(inside, { stopped = false, reason = "pending", settled = false,
				status_settled = false, accounting = "production-fixture/7" })
			helpers.assert_eq(f.capture.status().state, "stopped")
			helpers.assert_eq(f.scope.settled(f.token), true)
			helpers.assert_eq(f.controls.mode.admitted_capture(), nil)
			helpers.assert_eq(#f.observed.credits, 0)
		end)
	end)

	helpers.it("cannot restore credit after raw transport reentry or spontaneous native settlement", function()
		for _, kind in ipairs({ "reentry", "settle" }) do
			actual(function(f)
				local calls = 0
				f.controls.dependencies.baseline_ready = function()
					calls = calls + 1
					if kind == "reentry" then f.observed.tasks[3].chunk(nil, "batch\n")
					else f.observed.tasks[3].settle() end
					return true
				end
				f.start(); f.page(); f.complete()
				helpers.assert_eq(calls, 1); helpers.assert_eq(#f.observed.credits, 0)
				helpers.assert_eq(f.capture.status().state, "failed")
				helpers.assert_eq(f.scope.admitted(f.token), nil)
				helpers.assert_eq(f.controls.mode.admitted_capture(), nil)
			end)
		end
	end)

	helpers.it("captures the optional port and ignores late completion after actual stop", function()
		actual(function(f)
			local calls, replacement = 0, 0
			f.controls.dependencies.baseline_ready = function() calls = calls + 1; return true end
			f.start()
			f.controls.dependencies.baseline_ready = function() replacement = replacement + 1; return false end
			f.page(); f.complete("ready\n")
			helpers.assert_eq(calls, 1); helpers.assert_eq(replacement, 0)
			local stopped = f.capture.stop()
			helpers.assert_eq(stopped, false)
			f.observed.tasks[3].settle()
			helpers.assert_eq(f.scope.settled(f.token), true)
			f.complete("ready\nbatch\n")
			helpers.assert_eq(calls, 1); helpers.assert_eq(#f.observed.credits, 0)
		end)
	end)
end)

helpers.describe("completed baseline accounting debt", function()
	helpers.it("retains refused revocation after native settlement until an actual stop retry", function()
		actual(function(f)
			local permitted, calls, settlements = true, 0, 0
			f.controls.mode.bind_settlement({}, function() settlements = settlements + 1; return permitted end)
			f.controls.dependencies.baseline_ready = function()
				calls = calls + 1
				permitted = false
				f.capture.stop()
				return true
			end
			f.start(); f.page(); f.complete()
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(settlements, 3)
			f.observed.tasks[3].settle()
			helpers.assert_eq(settlements, 3)
			helpers.assert_eq(f.scope.settled(f.token), false)
			helpers.assert_eq(f.capture.status().state, "stopping")
			helpers.assert_eq(f.controls.mode.admitted_capture(), "production-fixture/7")
			permitted = true
			helpers.assert_eq(f.capture.stop(), true)
			helpers.assert_eq(settlements, 5)
			helpers.assert_eq(f.scope.settled(f.token), true)
			helpers.assert_eq(f.controls.mode.admitted_capture(), nil)
			helpers.assert_eq(f.observed.tasks[3].stops, 1)
			helpers.assert_eq(#f.observed.credits, 0)
		end)
	end)
end)

helpers.describe("synchronous native baseline completion", function()
	helpers.it("publishes completed admission before input while Capture.start is still running", function()
		actual(function(f)
			local starting, calls, admitted, before_return = true, 0, nil, false
			local trace = {}
			f.controls.dependencies.baseline_ready = function()
				calls = calls + 1; trace[#trace + 1] = "baseline"
				before_return = starting
				admitted = f.scope.admitted(f.token)
				return true
			end
			local emit = f.controls.dependencies.emit
			f.controls.dependencies.emit = function(press) trace[#trace + 1] = "emit"; return emit(press) end
			f.controls.on_spawn = function(task)
				local command = task.arguments[1]
				task.start = function()
					task.started, task.state = true, "running"
					if command == "--verify" then task.done(0); task.settle()
					elseif command == "--hs274-clock" then task.done(0, "clock\n", ""); task.settle()
					else task.chunk(nil, "opened\npage\nready\nbatch\n") end
					return true
				end
			end
			f.capture.init(f.controls.dependencies)
			local accepted = f.capture.start(f.controls.options); starting = false
			helpers.assert_eq(accepted, true); helpers.assert_eq(calls, 1)
			helpers.assert_eq(before_return, true); helpers.assert_eq(admitted, "production-fixture/7")
			helpers.assert_eq(trace, { "baseline", "emit" })
			helpers.assert_eq(#f.observed.credits, 1)
		end)
	end)
end)

helpers.describe("unbound baseline observer inventory", function()
	helpers.it("does not query a caller metatable to invent an absent optional observer", function()
		local lookups = {}
		local dependencies = { batch_limit = 8, admit = function() return "inventory" end,
			context = function() return { allowed = false } end, keycode = function() return 49 end,
			emit = function() return true end }
		setmetatable(dependencies, { __index = function(_, name) lookups[#lookups + 1] = name; return nil end })
		Delivery.new(dependencies)
		helpers.assert_eq(lookups, { "holds" })
		actual(function(f)
			local queried = {}
			setmetatable(f.controls.dependencies, { __index = function(_, name)
				queried[#queried + 1] = name
				return nil
			end })
			f.capture.init(f.controls.dependencies)
			helpers.assert_eq(queried, {})
			helpers.assert_eq(#f.observed.tasks, 0)
		end)
	end)
end)
