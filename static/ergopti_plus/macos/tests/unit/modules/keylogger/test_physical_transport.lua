--- tests/unit/modules/keylogger/test_physical_transport.lua

--- Exercises framing and task settlement with the real physical receiver.
local helpers = require("tests.helpers")
local Delivery = require("modules.keylogger.physical_delivery")
local Transport = require("modules.keylogger.physical_transport")

local function fixture(overrides)
	local observed = { writes = {}, presses = {}, errors = {}, stops = 0, settled = 0 }
	local task = {}
	function task.onSettled(callback) observed.settle = callback; return true end
	function task.start() return true end
	function task.set_input(bytes) observed.writes[#observed.writes + 1] = bytes; return true end
	function task.terminate() observed.stops = observed.stops + 1; return true, "pending" end
	local receiver = Delivery.new({ batch_limit = 8,
		admit = function() return "fixture-capture" end,
		context = function() return { allowed = true, app = "Fixture", timestamp = "2026-09-12 12:00:00.000" } end,
		keycode = function(usage) return ({ [41] = 53, [44] = 49 })[usage] end,
		emit = function(press) observed.presses[#observed.presses + 1] = press end,
	})
	local opening = { version = 1, kind = "opened", incarnation = "fixture", lease = "1", coverage = "fixture_only" }
	local batch = { version = 1, kind = "batch", incarnation = "fixture", lease = "1", coverage = "fixture_only",
		records = { { sequence = "1", device = "18446744073709551614", timestamp = "18446744073709550000",
			has_page = true, has_usage = true, page = 7, usage = 44, value = "1" } } }
	local dependencies = { receiver = receiver, frame_limit = 16,
		spawn = function(_, _, done, chunk) observed.done, observed.chunk = done, chunk; return task end,
		decode = function(line)
			if line == "opened" then return opening end
			if line == "batch" then return batch end
			return nil, "Malformed fixture JSON"
		end,
		encode = function(receipt)
			helpers.assert_eq(receipt.incarnation, "fixture")
			helpers.assert_eq(receipt.lease, "1")
			if receipt.ack == "1" then helpers.assert_eq(#observed.presses, 1) end
			return receipt.ack
		end,
		on_error = function(reason) observed.errors[#observed.errors + 1] = reason end,
		on_settled = function() observed.settled = observed.settled + 1 end,
	}
	if overrides then overrides(dependencies, task, observed, receiver) end
	return Transport.new(dependencies), observed, receiver
end

helpers.describe("physical transport (hs274)", function()
	helpers.it("retains acquisition ownership when stopped inside spawn", function()
		local transport, observed
		transport, observed = fixture(function(dependencies, task, state)
			dependencies.spawn = function()
				transport.stop()
				state.settled_during_spawn = state.settled
				return task
			end
			function task.start() error("Revoked acquisition must not start") end
		end)
		helpers.assert_eq(transport.start("/fixture/capture", {}), false)
		helpers.assert_eq(observed.settled_during_spawn, 0, "Pending acquisition cannot settle")
		helpers.assert_eq(observed.stops, 1, "Returned task must be retired")
		helpers.assert_eq(transport.isSettled(), false)
		observed.settle()
		helpers.assert_eq(observed.settled, 1)
	end)

	helpers.it("settles acquisition failures after an early completion callback", function()
		for _, outcome in ipairs({ "task", "nil", "throw" }) do
			local transport, observed = fixture(function(dependencies, task, state)
				dependencies.spawn = function(_, _, done)
					done(1)
					state.settled_during_spawn = state.settled
					if outcome == "throw" then error("Injected acquisition failure") end
					if outcome == "task" then return task end
				end
			end)
			helpers.assert_eq(transport.start("/fixture/capture", {}), false)
			helpers.assert_eq(observed.settled_during_spawn, 0)
			helpers.assert_eq(#observed.errors, 1)
			if outcome == "task" then
				helpers.assert_eq(observed.stops, 1)
				helpers.assert_eq(transport.isSettled(), false)
				observed.settle()
			end
			helpers.assert_true(transport.isSettled())
			helpers.assert_eq(observed.settled, 1)
		end
	end)

	helpers.it("acknowledges complete frames only after the real receiver commits", function()
		local transport, observed = fixture()
		helpers.assert_true(transport.start("/fixture/capture", {}))
		observed.chunk(nil, "ope", "diagnostic")
		helpers.assert_eq(observed.writes, {})
		observed.chunk(nil, "ned\nba", "")
		helpers.assert_eq(observed.writes, { "0\n" })
		observed.chunk(nil, "tch\n", "")
		helpers.assert_eq(observed.writes, { "0\n", "1\n" })
		helpers.assert_eq(observed.presses[1].keycode, 49)
		helpers.assert_eq(observed.presses[1].device, "18446744073709551614")
		helpers.assert_eq(observed.errors, {})
	end)

	helpers.it("fences malformed oversized and replayed frames until actual settlement", function()
		for _, invalid in ipairs({ "bad\n", string.rep("x", 17), "batch\nbatch\n" }) do
			local transport, observed, receiver = fixture()
			transport.start("/fixture/capture", {})
			observed.chunk(nil, "opened\n", "")
			observed.chunk(nil, invalid, "")
			helpers.assert_eq(#observed.errors, 1)
			helpers.assert_eq(observed.stops, 1)
			helpers.assert_eq(receiver.active(), false)
			helpers.assert_eq(transport.isSettled(), false)
			local count = #observed.writes
			observed.chunk(nil, "batch\n", "")
			helpers.assert_eq(#observed.writes, count)
			observed.settle()
			observed.settle()
			helpers.assert_true(transport.isSettled())
			helpers.assert_eq(observed.settled, 1)
		end
	end)

	helpers.it("revokes delivery on acknowledgement write failure", function()
		local transport, observed, receiver = fixture(function(_, task)
			function task.set_input() return false end
		end)
		transport.start("/fixture/capture", {})
		observed.chunk(nil, "opened\n", "")
		helpers.assert_true(observed.errors[1]:find("write failed", 1, true) ~= nil)
		helpers.assert_eq(receiver.active(), false)
		helpers.assert_eq(observed.stops, 1)
	end)

	helpers.it("does not acknowledge after reentrant revocation during encoding", function()
		local transport
		local observed
		transport, observed = fixture(function(dependencies)
			dependencies.encode = function() transport.stop(); return "0" end
		end)
		transport.start("/fixture/capture", {})
		observed.chunk(nil, "opened\n", "")
		helpers.assert_eq(observed.writes, {})
		helpers.assert_eq(#observed.errors, 1)
	end)

	helpers.it("keeps refused termination retryable and rejects restarting", function()
		local transport, observed = fixture(function(_, task, observed)
			function task.terminate()
				observed.stops = observed.stops + 1
				return observed.stops > 1, observed.stops > 1 and "pending" or "refused"
			end
		end)
		transport.start("/fixture/capture", {})
		local accepted, status = transport.stop()
		helpers.assert_eq({ accepted, status }, { false, "refused" })
		helpers.assert_eq(transport.isSettled(), false)
		helpers.assert_true(transport.stop())
		observed.settle()
		local ok = pcall(transport.start, "/fixture/capture", {})
		helpers.assert_eq(ok, false)
	end)

	helpers.it("reports unexpected completion and failed start without releasing a live task", function()
		for _, refused in ipairs({ false, true }) do
			local transport, observed = fixture(function(_, task)
				function task.start() return not refused end
			end)
			helpers.assert_eq(transport.start("/fixture/capture", {}), not refused)
			if not refused then observed.chunk(nil, "ope", ""); observed.done(0, "", "") end
			helpers.assert_eq(#observed.errors, 1)
			helpers.assert_eq(transport.isSettled(), false)
			observed.settle()
			helpers.assert_true(transport.isSettled())
		end
	end)

	helpers.it("reports an already settled task as a failed launch exactly once", function()
		local transport, observed = fixture(function(_, task)
			function task.onSettled(callback) callback(); return true end
			function task.start() error("A settled task cannot start") end
		end)
		helpers.assert_eq(transport.start("/fixture/missing", {}), false)
		helpers.assert_true(transport.isSettled())
		helpers.assert_eq(observed.settled, 1)
		helpers.assert_eq(#observed.errors, 1)
		helpers.assert_true(observed.errors[1]:find("settled before start", 1, true) ~= nil)
	end)

	helpers.it("handles output delivered synchronously during start without losing ownership", function()
		local transport, observed = fixture(function(_, task, observed)
			function task.start() observed.chunk(nil, "opened\n", ""); return true end
		end)
		helpers.assert_true(transport.start("/fixture/capture", {}))
		helpers.assert_eq(observed.writes, { "0\n" })
		helpers.assert_eq(observed.errors, {})
	end)
end)
