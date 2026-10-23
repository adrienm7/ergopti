--- tests/unit/modules/keystats/physical/capture/test_physical_capture_position.lua

--- Receives the real capture wrappers over original supervised task fixtures.
local helpers = require("tests.helpers")
local with_capture = require("tests.support.physical_capture_fixture").run
local function press(controls, sequence, down)
	controls.frames.batch = { version = 1, kind = "batch", coverage = "complete", incarnation = "production-fixture", lease = "7",
		records = { { sequence = tostring(sequence), device = "41", timestamp = tostring(sequence + 10),
			has_page = true, has_usage = true, has_cookie = true, page = 7, usage = 44, cookie = 44, value = down and "1" or "0" } } }
end
local function start(capture, controls)
	capture.init(controls.dependencies); helpers.assert_true(capture.start(controls.options)); controls.verified(); controls.open()
end
helpers.describe("capture observational position capability", function()
	helpers.it("stays unavailable without genuine native baseline admission", function()
		with_capture(function(capture, observed, controls)
			helpers.assert_eq(capture.position_available(), false)
			capture.init(controls.dependencies)
			helpers.assert_nil(capture.capture_position(function() return true end, function() end))
			helpers.assert_eq(observed.spawns, {})
			capture.start(controls.options); controls.verified()
			helpers.assert_eq(capture.position_available(), false)
			controls.open(); helpers.assert_true(capture.position_available())
		end)
	end)
	helpers.it("preserves primary metrics and native task custody during editor cancellation", function()
		with_capture(function(capture, observed, controls)
			start(capture, controls); local received = {}
			local token = capture.capture_position(function() return true end, function(facts) received[#received + 1] = facts; return true end)
			helpers.assert_true(type(token) == "table")
			press(controls, 1, true); observed.tasks[3].chunk(nil, "batch\n")
			helpers.assert_eq(received, { { native_code = 49, mods = {} } })
			helpers.assert_eq(#observed.credits, 1)
			helpers.assert_true(capture.cancel_position(token))
			helpers.assert_eq(capture.cancel_position({}), false)
			helpers.assert_eq(capture.status().state, "capturing")
			helpers.assert_eq(observed.tasks[3].stops, 0)
			helpers.assert_eq(#observed.spawns, 3)
			helpers.assert_eq(observed.errors, {})
		end)
	end)
	helpers.it("retains exact callback unwind debt without terminating the native task", function()
		with_capture(function(capture, observed, controls)
			start(capture, controls); local token, cancellation, called
			token = capture.capture_position(function() return true end, function()
				called = true; cancellation = capture.cancel_position(token); return true
			end)
			press(controls, 1, true); observed.tasks[3].chunk(nil, "batch\n")
			helpers.assert_true(called); helpers.assert_eq(cancellation, false)
			helpers.assert_true(capture.cancel_position(token)); helpers.assert_eq(observed.tasks[3].stops, 0)
		end)
	end)
	helpers.it("fences a stale page without revoking actual accounting", function()
		with_capture(function(capture, observed, controls)
			start(capture, controls); local live, called = true, false
			local token = capture.capture_position(function() return live end, function() called = true; return true end)
			live = false; press(controls, 1, true); observed.tasks[3].chunk(nil, "batch\n")
			helpers.assert_eq(called, false); helpers.assert_eq(#observed.credits, 1)
			helpers.assert_true(capture.cancel_position(token)); helpers.assert_eq(capture.status().state, "capturing")
		end)
	end)
	helpers.it("revokes old observation when the real stream stops and preserves cancellation receipt", function()
		with_capture(function(capture, observed, controls)
			start(capture, controls); local called = false
			local token = capture.capture_position(function() return true end, function() called = true; return true end)
			helpers.assert_eq(capture.stop(), false)
			helpers.assert_true(capture.cancel_position(token)); helpers.assert_eq(called, false)
			helpers.assert_eq(capture.position_available(), false)
			observed.tasks[3].settle(); helpers.assert_true(capture.stop())
		end)
	end)
end)
