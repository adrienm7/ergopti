--- tests/unit/ui/test_download_window_pending_queue.lua

--- ==============================================================================
--- MODULE: Download Pending Presentation Queue Regressions
--- DESCRIPTION:
--- Verifies that log bursts cannot evict structural state, coalesced commands
--- preserve last-update order, and independent sessions never share queued work.
--- ==============================================================================

local helpers = require("tests.helpers")
local Queue = require("ui.download_window.pending_queue")

helpers.describe("download pending presentation queue (HS-263)", function()
	helpers.it("retains initialization and latest progress across a log overflow", function()
		local queue = Queue.new()
		Queue.push(queue, "setKind", "setKind('mlx_model')")
		Queue.push(queue, "setModel", "setModel('model')")
		Queue.push(queue, "update", "update(1)")
		for index = 1, 250 do Queue.push(queue, "addLog", "addLog(" .. index .. ")") end
		Queue.push(queue, "update", "update(99)")
		local codes, dropped = Queue.drain(queue)
		helpers.assert_eq(#codes, 203)
		helpers.assert_eq(dropped, 50)
		helpers.assert_eq(codes[1], "setKind('mlx_model')")
		helpers.assert_eq(codes[2], "setModel('model')")
		helpers.assert_eq(codes[3], "update(99)")
		for index = 1, 200 do
			helpers.assert_eq(codes[index + 3], "addLog(" .. (index + 50) .. ")")
		end
	end)

	helpers.it("keeps exactly the newest 200 logs through multiple ring wraps", function()
		local queue = Queue.new()
		for index = 1, 1001 do Queue.push(queue, "addLog", tostring(index)) end
		local codes, dropped = Queue.drain(queue)
		helpers.assert_eq(#codes, 200)
		helpers.assert_eq(dropped, 801)
		for index = 1, 200 do helpers.assert_eq(codes[index], tostring(index + 801)) end
	end)

	helpers.it("orders distinct state commands by their last update before log replay", function()
		local queue = Queue.new()
		Queue.push(queue, "setStep", "old step")
		Queue.push(queue, "addLog", "first log")
		Queue.push(queue, "setDetail", "detail")
		Queue.push(queue, "setProgress", "progress")
		Queue.push(queue, "setStep", "new step")
		Queue.push(queue, "done", "terminal")
		local codes, dropped = Queue.drain(queue)
		helpers.assert_true(helpers.deep_equal(codes, {
			"detail", "progress", "new step", "terminal", "first log",
		}))
		helpers.assert_eq(dropped, 0)
	end)

	helpers.it("drains once and resets counters without affecting a sibling session", function()
		local first, second = Queue.new(), Queue.new()
		for index = 1, 201 do Queue.push(first, "addLog", tostring(index)) end
		Queue.push(second, "setKind", "second kind")
		local _, dropped = Queue.drain(first)
		helpers.assert_eq(dropped, 1)
		local empty, empty_dropped = Queue.drain(first)
		helpers.assert_eq(#empty, 0)
		helpers.assert_eq(empty_dropped, 0)
		Queue.push(first, "setError", "new error")
		helpers.assert_true(helpers.deep_equal(Queue.drain(first), { "new error" }))
		helpers.assert_true(helpers.deep_equal(Queue.drain(second), { "second kind" }))
	end)

	helpers.it("rejects invalid input before modifying already accepted state", function()
		local queue = Queue.new()
		Queue.push(queue, "resetUI", "resetUI()")
		for _, key in ipairs({ "", "unknown", "__index" }) do
			helpers.assert_throws(function() Queue.push(queue, key, "code") end)
		end
		helpers.assert_throws(function() Queue.push(queue, nil, "code") end)
		helpers.assert_throws(function() Queue.push(queue, "setKind", "") end)
		helpers.assert_throws(function() Queue.push(queue, "setKind", {}) end)
		helpers.assert_throws(function() Queue.push({}, "setKind", "code") end)
		helpers.assert_throws(function() Queue.drain({}) end)
		local codes, dropped = Queue.drain(queue)
		helpers.assert_true(helpers.deep_equal(codes, { "resetUI()" }))
		helpers.assert_eq(dropped, 0)
	end)
end)
