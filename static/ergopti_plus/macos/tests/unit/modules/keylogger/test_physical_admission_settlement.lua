--- tests/unit/modules/keylogger/test_physical_admission_settlement.lua
--- The task below models only explicit task callbacks and termination; it never
--- supplies installed/native/Core/Root ownership or production readiness.
local helpers = require("tests.helpers")
local Delivery = require("modules.keylogger.physical_delivery")
local Transport = require("modules.keylogger.physical_transport")
local Frames = require("tests.support.physical_stream_frames")

local function frames() return Frames.new("admission-fixture", "1") end

local function batch()
	return { version = 1, kind = "batch", incarnation = "admission-fixture", lease = "1",
		coverage = "fixture_only", records = {
			{ sequence = "1", device = "18446744073709551614", timestamp = "1",
				has_page = true, has_usage = true, page = 7, usage = 44,
				value = "1", has_cookie = true, cookie = 44 },
		} }
end

local function delivery(overrides)
	local observed = { admits = 0, contexts = 0, mappings = 0, presses = {} }
	local dependencies = { batch_limit = 8,
		admit = function() observed.admits = observed.admits + 1; return "fixture-capture" end,
		context = function()
			observed.contexts = observed.contexts + 1
			return { allowed = true, app = "Fixture", timestamp = "2026-09-12 12:00:00.000" }
		end,
		keycode = function(...)
			observed.mappings = observed.mappings + 1
			return Frames.keycode(...)
		end,
		emit = function(press) observed.presses[#observed.presses + 1] = press; return true end,
	}
	for name, value in pairs(overrides or {}) do dependencies[name] = value end
	return Delivery.new(dependencies), observed, dependencies
end

local function transport(behavior)
	behavior = behavior or {}
	local observed = { writes = {}, errors = {}, presses = {}, stops = 0, settled = 0 }
	local receiver = delivery({ emit = function(press)
		observed.presses[#observed.presses + 1] = press
		if behavior.emit then return behavior.emit(observed) end
		return true
	end })
	observed.receiver = receiver
	local task = {}
	function task.onSettled(callback) observed.settle = callback; return true end
	function task.start() return true end
	function task.set_input(bytes) observed.writes[#observed.writes + 1] = bytes; return true end
	function task.terminate()
		observed.stops = observed.stops + 1
		if behavior.terminate then return behavior.terminate(observed) end
		return true, "pending"
	end
	local source = frames()
	local instance = Transport.new({ receiver = receiver, frame_limit = 32,
		spawn = function(_, _, _, chunk) observed.chunk = chunk; return task end,
		decode = function(line)
			if behavior.decode then return behavior.decode(line, observed) end
			if line == "opened" then return source.opened end
			if line == "baseline" then return source.page end
			if line == "ready" then return source.ready end
			if line == "batch" then return batch() end
			return nil, "Fixture malformed frame"
		end,
		encode = function(receipt) return receipt.baseline_ack and "B" .. receipt.baseline_ack or receipt.ack end,
		on_error = function(diagnostic, raw)
			observed.errors[#observed.errors + 1] = { diagnostic = diagnostic, raw = raw }
			if behavior.report then return behavior.report(observed) end
		end,
		on_settled = function() observed.settled = observed.settled + 1 end,
	})
	observed.transport = instance
	return instance, observed
end

local function snapshot(observed)
	local accepted, status = observed.transport.stop()
	return { settled = observed.settled, actual_settled = observed.transport.isSettled(),
		accepted = accepted, status = status, active = observed.receiver.active() }
end

helpers.describe("physical baseline admission and retained callback settlement", function()
	helpers.it("acknowledges only the captured original completed baseline", function()
		local receiver, observed, dependencies
		local calls, inside = 0, nil
		receiver, observed, dependencies = delivery({ baseline_ready = function()
			calls = calls + 1
			inside = { ready = receiver.ready(), active = receiver.active(), presses = #observed.presses }
			return true
		end })
		dependencies.baseline_ready = function() error("Foreign baseline observer") end
		local source = frames()
		helpers.assert_eq(receiver.ready(), false)
		receiver.open(source.opened)
		helpers.assert_eq(receiver.ready(), false)
		helpers.assert_eq(receiver.baseline(source.page), tostring(source.page.next))
		helpers.assert_eq(receiver.ready(), false)
		helpers.assert_eq(calls, 0)
		helpers.assert_nil(receiver.baseline(source.ready))
		helpers.assert_eq(calls, 1)
		helpers.assert_eq(inside, { ready = true, active = true, presses = 0 })
		helpers.assert_eq(receiver.ready(), true)
		receiver.stop()
		helpers.assert_eq(receiver.ready(), false)
	end)

	helpers.it("refuses nonliteral or throwing baseline completion observers", function()
		local function refused(callback, original_error)
			local receiver, observed = delivery({ baseline_ready = callback })
			local source = frames()
			receiver.open(source.opened); receiver.baseline(source.page)
			local accepted, failure = pcall(receiver.baseline, source.ready)
			helpers.assert_eq(accepted, false)
			if original_error then helpers.assert_true(rawequal(failure, original_error)) end
			helpers.assert_eq(receiver.active(), false)
			helpers.assert_eq(receiver.ready(), false)
			helpers.assert_eq(#observed.presses, 0)
		end
		for _, result in ipairs({ false, 1, {} }) do refused(function() return result end) end
		refused(function() return nil end)
		local original_error = {}
		refused(function() error(original_error, 0) end, original_error)
		for _, invalid in ipairs({ false, 1, "observer", {} }) do
			local accepted = pcall(delivery, { baseline_ready = invalid })
			helpers.assert_eq(accepted, false)
		end
	end)

	helpers.it("never reactivates baseline completion revoked by reentry", function()
		for _, action in ipairs({ "stop", "deliver" }) do
			local receiver, observed
			local nested
			receiver, observed = delivery({ baseline_ready = function()
				if action == "stop" then receiver.stop()
				else nested = pcall(receiver.deliver, batch()) end
				return true
			end })
			local source = frames()
			receiver.open(source.opened); receiver.baseline(source.page)
			local accepted = pcall(receiver.baseline, source.ready)
			helpers.assert_eq(accepted, false)
			if action == "deliver" then helpers.assert_eq(nested, false) end
			helpers.assert_eq(receiver.active(), false)
			helpers.assert_eq(receiver.ready(), false)
			helpers.assert_eq(#observed.presses, 0)
		end
	end)

	helpers.it("keeps original delivery callbacks after advertised dependency mutation", function()
		local receiver, observed, dependencies = delivery()
		local foreign = 0
		for _, name in ipairs({ "admit", "context", "keycode", "emit" }) do
			dependencies[name] = function() foreign = foreign + 1; error("Foreign advertised callback") end
		end
		Frames.start(receiver, frames())
		helpers.assert_eq(receiver.deliver(batch()), "1")
		helpers.assert_eq(foreign, 0)
		helpers.assert_eq({ observed.admits, observed.contexts, observed.mappings, #observed.presses }, { 1, 1, 1, 1 })
		helpers.assert_eq(observed.presses[1].keycode, 49)
		receiver.stop()
	end)

	helpers.it("waits for actual emission and reporting frames after synchronous task close", function()
		local emission, reporting
		local instance, observed = transport({
			emit = function(state) state.settle(); emission = snapshot(state) end,
			report = function(state) reporting = snapshot(state) end,
		})
		helpers.assert_eq(instance.start("/fixture/capture", {}), true)
		observed.chunk(nil, "opened\nbaseline\nready\n")
		observed.chunk(nil, "batch\n")
		helpers.assert_eq(emission, { settled = 0, actual_settled = false, accepted = false, status = "pending", active = false })
		helpers.assert_eq(reporting, emission)
		helpers.assert_eq(#observed.errors, 1)
		helpers.assert_eq(observed.settled, 1)
		helpers.assert_eq(instance.isSettled(), true)
		observed.settle()
		helpers.assert_eq(observed.settled, 1)
	end)

	helpers.it("preserves a throwing report while retiring its exact callback frames", function()
		local report_error, reporting = {}, nil
		local instance, observed = transport({ report = function(state)
			state.settle(); reporting = snapshot(state); error(report_error, 0)
		end })
		helpers.assert_eq(instance.start("/fixture/capture", {}), true)
		local accepted, failure = pcall(observed.chunk, nil, "bad\n")
		helpers.assert_eq(accepted, false)
		helpers.assert_true(rawequal(failure, report_error))
		helpers.assert_eq(reporting, { settled = 0, actual_settled = false, accepted = false, status = "pending", active = false })
		helpers.assert_eq(observed.settled, 1)
		helpers.assert_eq(instance.isSettled(), true)
		observed.settle()
		helpers.assert_eq(observed.settled, 1)
	end)

	helpers.it("revokes before diagnostic reentry without losing correlated raw failure", function()
		local diagnostic_frame, formats = nil, 0
		local raw_error = setmetatable({}, { __tostring = function()
			formats = formats + 1
			return "fixture diagnostic"
		end })
		local instance, observed = transport({ decode = function() return nil, raw_error end })
		getmetatable(raw_error).__tostring = function()
			formats = formats + 1
			observed.settle(); diagnostic_frame = snapshot(observed)
			return "fixture diagnostic"
		end
		helpers.assert_eq(instance.start("/fixture/capture", {}), true)
		observed.chunk(nil, "bad\n")
		helpers.assert_eq(formats, 1)
		helpers.assert_eq(diagnostic_frame, { settled = 0, actual_settled = false, accepted = false, status = "pending", active = false })
		helpers.assert_eq(#observed.errors, 1)
		helpers.assert_eq(observed.errors[1].diagnostic, "fixture diagnostic")
		helpers.assert_true(rawequal(observed.errors[1].raw, raw_error))
		helpers.assert_eq(observed.settled, 1)
		helpers.assert_eq(instance.isSettled(), true)
	end)

	helpers.it("reports original failure even when native termination throws", function()
		local stop_error, raw_error = {}, {}
		local instance, observed = transport({
			decode = function() return nil, raw_error end,
			terminate = function() error(stop_error, 0) end,
		})
		helpers.assert_eq(instance.start("/fixture/capture", {}), true)
		local accepted, failure = pcall(observed.chunk, nil, "bad\n")
		helpers.assert_eq(accepted, false)
		helpers.assert_true(rawequal(failure, stop_error))
		helpers.assert_eq(#observed.errors, 1)
		helpers.assert_true(rawequal(observed.errors[1].raw, raw_error))
		helpers.assert_eq(observed.settled, 0)
		helpers.assert_eq(instance.isSettled(), false)
		observed.settle()
		helpers.assert_eq(observed.settled, 1)
		helpers.assert_eq(instance.isSettled(), true)
	end)
end)
