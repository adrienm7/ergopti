--- tests/unit/modules/keylogger/test_context_tracker_active_app_snapshot.lua

--- ==============================================================================
--- REGRESSION: Metrics Apps includes the current macOS foreground interval
--- DESCRIPTION:
--- App-switch events persist only completed intervals. This verifies that the
--- context tracker exposes the still-open foreground interval so the dashboard
--- can display a long uninterrupted task before the user changes application.
--- ==============================================================================

local helpers = require("tests.helpers")

helpers.describe("context_tracker: active app snapshot", function()

	helpers.it("returns the elapsed foreground duration for the current application", function()
		local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker", {
			timer = { absoluteTime = function() return 7250000 end },
		})
		local state = { active_app_name = "Code", active_app_start = 1000 }
		tracker.init(state, {})

		local snapshot = tracker.get_active_app_snapshot()
		helpers.assert_eq(snapshot.app, "Code")
		helpers.assert_eq(snapshot.duration_ms, 6250)
	end)

	helpers.it("does not invent an interval without a tracked foreground application", function()
		local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker", {
			timer = { absoluteTime = function() return 7250000 end },
		})
		tracker.init({}, {})
		helpers.assert_eq(tracker.get_active_app_snapshot(), nil)
	end)
end)
