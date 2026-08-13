--- tests/meta/test_root_teardown_timer_finalizer.lua

--- ==============================================================================
--- MODULE: Root Teardown Timer Finalizer Guard
--- DESCRIPTION:
--- Pins the ownership boundary between module teardown and the scheduler-wide
--- timer drain. A failed module stop leaves the Hammerspoon process alive and
--- retains exact cleanup capabilities, so cancelAll may run only after every
--- module owner has settled.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("root teardown scheduler ownership", function()
	helpers.it("runs cancelAll only as the dependent teardown finalizer", function()
		local source, err = helpers.read_driver_unit("local function has_common_hotstring_groups")
		helpers.assert_true(source ~= nil, "root init.lua must be unique: " .. tostring(err))
		local body_start = source:find("local function teardown_all_resources", 1, true)
		local body_end = source:find("local function shutdown_all_resources", body_start or 1, true)
		helpers.assert_true(body_start ~= nil and body_end ~= nil,
			"root teardown function must be locatable")
		local body = source:sub(body_start, body_end - 1):gsub("%-%-[^\n]*", "")
		local compact_body = body:gsub("%s+", "")
		local finalizer_start = body:find("local timer_finalizer", 1, true)
		local cancel_start = body:find("TimerScheduler.cancelAll", 1, true)
		local transaction_start = body:find("TeardownTransaction.run_with_finalizer", 1, true)

		local _, cancel_count = body:gsub("TimerScheduler%.cancelAll%s*%(", "")
		helpers.assert_eq(1, cancel_count,
			"root teardown must have exactly one scheduler-wide timer drain")
		helpers.assert_true(finalizer_start ~= nil and cancel_start ~= nil
			and transaction_start ~= nil and finalizer_start < cancel_start
			and cancel_start < transaction_start,
			"cancelAll must belong to the finalizer descriptor passed to the transaction")
		helpers.assert_true(
			compact_body:find(
				"TeardownTransaction.run_with_finalizer(_local_teardown_state,steps,timer_finalizer)",
				1,
				true
			) ~= nil,
			"the timer drain must be passed as a dependent finalizer, never as an independent sibling"
		)
	end)
end)
