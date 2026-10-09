--- tests/unit/modules/shortcuts/test_script_control_extra_callback_errors.lua

--- ==============================================================================
--- MODULE: Script-Control Callback Error Regression Tests
--- DESCRIPTION:
--- Drives the real deferred sentinel and configurable-hotkey owners with
--- callbacks that throw. The event remains contained, the callback boundary
--- records one contextual traceback, and no failed action is reported as true.
---
--- ROOT CAUSE ENCODED:
--- Bare pcall sites discarded their false/error tuple. Script-control then
--- consumed a physical key after an extension produced no output, while the
--- configurable-hotkey owner and gesture dispatcher independently published
--- success after a thrown action.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.script_control_callback_fixture")

helpers.describe("HS-016 script-control callbacks are visible and truthful", function()
	helpers.it("contains a throwing extra on the real deferred sentinel path", function()
		Fixture.with_sentinel(function(fixture)
			local subject, failures = fixture.subject, fixture.failures
			local deferred = fixture.deferred
			local started = subject.start({}, {}, {}, nil)
			local consumed = fixture.get_tap_handler()({
				getProperty = function() return 0 end,
				getKeyCode = function() return 0x6A end,
				getFlags = function() return {ctrl = true, shift = true} end,
			})
			local deferred_ok, deferred_handled = false, nil
			if #deferred == 1 then
				deferred_ok, deferred_handled = pcall(deferred[1])
			end
			local stopped = subject.stop()

			helpers.assert_true(started, "the fixture must own the real eventtap callback")
			helpers.assert_true(consumed, "the tagged physical sentinel must reach deferred dispatch")
			helpers.assert_true(deferred_ok,
				"the external exception must not escape the deferred runloop callback")
			helpers.assert_eq(deferred_handled, false,
				"the deferred owner must not report a throwing extra as handled")
			helpers.assert_true(stopped)
			helpers.assert_eq(#failures, 1, "one throwing extra must emit one callback failure")
			helpers.assert_contains(failures[1], "Script-control extra 'open_config'")
			helpers.assert_contains(failures[1], "extra exploded")
			helpers.assert_contains(failures[1], "stack traceback")
		end)
	end)

	helpers.it("returns false when a configurable gesture action throws", function()
		Fixture.with_configurable(function(fixture)
			local subject, failures = fixture.subject, fixture.failures
			local started = subject.start()
			local call_ok, handled = pcall(fixture.get_bound_callback())
			local stopped = subject.stop()

			helpers.assert_true(started)
			helpers.assert_true(call_ok, "the hotkey callback must contain the gesture exception")
			helpers.assert_eq(handled, false,
				"a thrown gesture action cannot be reported as handled")
			helpers.assert_true(stopped)
			helpers.assert_eq(#failures, 1)
			helpers.assert_contains(failures[1], "Configurable shortcut 'cmd_a'")
			helpers.assert_contains(failures[1], "gesture exploded")
			helpers.assert_contains(failures[1], "stack traceback")
		end)
	end)

end)

return true
