--- tests/unit/lib/test_logger_error_notify_dedup.lua

--- ==============================================================================
--- MODULE: Regression — error-notification handler must honour log dedup
--- DESCRIPTION:
--- M.error() forwards every call to the registered notification handler
--- (init.lua wires it to a macOS system notification). The unified log
--- deduplicates consecutive identical lines inside a 5 s window, but M.error()
--- fired the notification handler UNCONDITIONALLY — so an error condition that
--- recurs on a hot path (e.g. an eventtap that throws on every keystroke) wrote
--- a single deduped log line yet emitted one system notification PER call,
--- burying the user under identical toasts the log itself suppressed.
---
--- ROOT CAUSE: M.error() calls _log() (which may suppress the line via dedup)
--- and then fires _error_notification_handler regardless of whether the line
--- was actually emitted. The notification path has no visibility into the dedup
--- decision made inside _log().
---
--- This is a BEHAVIORAL test: it fires the SAME error N times within the dedup
--- window and asserts the notification handler is invoked exactly ONCE — the
--- same number of times the line reaches the log sink — not N times.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("logger: error notifications respect dedup (no toast storm)", function()
	helpers.it("fires the notification handler once for N identical errors in the dedup window", function()
		local Logger = helpers.load_with_stubs("lib.logger")
		Logger.set_level("DEBUG")

		local log_emits  = 0
		local notif_count = 0
		Logger.set_sink(function(_line) log_emits = log_emits + 1 end)
		Logger.set_error_notification_handler(function(_mod, _msg) notif_count = notif_count + 1 end)

		-- Same error 5 times back-to-back — well inside the 5 s dedup window.
		for _ = 1, 5 do
			Logger.error("notif_dedup_test", "identical recurring failure")
		end

		Logger.set_error_notification_handler(nil)
		Logger.set_sink(nil)

		-- The log correctly emits the line only once (dedup). The notification
		-- handler must follow the same emission decision — exactly one toast.
		helpers.assert_eq(log_emits, 1,
			"the log must dedup 5 identical errors down to a single emitted line")
		helpers.assert_eq(notif_count, 1,
			"the notification handler must fire only when the line is actually emitted, not once per suppressed duplicate")
	end)

	helpers.it("still fires the handler for a genuinely new error after a deduped run", function()
		local Logger = helpers.load_with_stubs("lib.logger")
		Logger.set_level("DEBUG")

		local notif = {}
		Logger.set_error_notification_handler(function(_mod, msg) notif[#notif + 1] = msg end)

		Logger.error("notif_dedup_test", "first failure")
		Logger.error("notif_dedup_test", "first failure")  -- suppressed (dup)
		Logger.error("notif_dedup_test", "second failure") -- new line — must notify

		Logger.set_error_notification_handler(nil)

		helpers.assert_eq(#notif, 2,
			"two distinct errors must yield two notifications; the suppressed duplicate must not add a third")
		helpers.assert_true(notif[1]:find("first failure", 1, true) ~= nil)
		helpers.assert_true(notif[2]:find("second failure", 1, true) ~= nil)
	end)
end)
