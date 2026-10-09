--- tests/meta/test_root_teardown_timer_finalizer.lua

--- ==============================================================================
--- MODULE: Root Teardown Timer Finalizer Guard
--- DESCRIPTION:
--- Pins the ownership boundary between module teardown, the asynchronous native
--- logger drain, and the scheduler-wide timer release. The logger's pump is one
--- of TimerScheduler's capabilities, so cancelAll may run only after exact ACK.
--- The socket closes last so a refused timer cannot reopen the legacy sink.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("root teardown scheduler ownership", function()
	helpers.it("runs cancelAll only after the asynchronous logger drain", function()
		local source, err = helpers.read_driver_unit("local function has_common_hotstring_groups")
		helpers.assert_true(source ~= nil, "root init.lua must be unique: " .. tostring(err))
		local body_start = source:find("local function teardown_all_resources", 1, true)
		local body_end = source:find("local function shutdown_all_resources", body_start or 1, true)
		helpers.assert_true(body_start ~= nil and body_end ~= nil,
			"root teardown function must be locatable")
		local region = source:sub(body_start, body_end - 1):gsub("%-%-[^\n]*", "")
		local teardown_end = region:find("local function finalize_teardown_resources", 1, true)
		helpers.assert_true(teardown_end ~= nil, "post-drain finalizer must be locatable")
		local teardown_body = region:sub(1, teardown_end - 1)
		local finalizer_body = region:sub(teardown_end)
		local stop_start = finalizer_body:find("Logger.stop_async_sink()", 1, true)
		local cancel_start = finalizer_body:find("TimerScheduler.cancelAll()", 1, true)
		local _, cancel_count = region:gsub("TimerScheduler%.cancelAll%s*%(", "")
		helpers.assert_eq(1, cancel_count,
			"root teardown must have exactly one scheduler-wide timer drain")
		helpers.assert_true(teardown_body:find("TimerScheduler.cancelAll", 1, true) == nil,
			"local owner teardown must leave the logger pump alive for native ACK delivery")
		helpers.assert_true(stop_start ~= nil and cancel_start ~= nil and cancel_start < stop_start,
			"post-drain finalization must keep legacy fallback disabled through broad timer release")
		helpers.assert_true(source:find("begin_drain = Logger.begin_async_sink_shutdown", 1, true) ~= nil
			and source:find("finalize_teardown = finalize_teardown_resources", 1, true) ~= nil,
			"TerminationCoordinator must own the asynchronous drain-to-finalizer handoff")
		helpers.assert_true(source:find("fatal_exit = function(code) return os.exit(code) end",
			1, true) ~= nil
			and source:find("fatal_exit_code = RUNTIME_FAILURE_EXIT_CODE", 1, true) ~= nil,
			"a returned/throwing terminal action must end through the named non-zero native fallback")
	end)
end)
