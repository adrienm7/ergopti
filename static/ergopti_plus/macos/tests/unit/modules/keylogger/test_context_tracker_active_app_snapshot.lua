--- tests/unit/modules/keylogger/test_context_tracker_active_app_snapshot.lua

--- ==============================================================================
--- REGRESSION: Metrics Apps includes the current macOS foreground interval
--- DESCRIPTION:
--- App-switch events persist only completed intervals. This verifies that the
--- context tracker exposes the still-open foreground interval so the dashboard
--- can display a long uninterrupted task before the user changes application.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The tracker now requires a pause predicate: its writers must be silent
--- while the script is paused. These scenarios exercise the RUNNING state.
local function NOT_PAUSED() return false end

helpers.describe("context_tracker: active app snapshot", function()

	helpers.it("returns the elapsed foreground duration for the current application", function()
		local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker", {
			-- hs.timer.absoluteTime() is nanoseconds; the tracker converts it to ms.
			timer = { absoluteTime = function() return 7250000000 end },
		})
		local state = { active_app_name = "Code", active_app_start = 1000 }
		tracker.init(state, {}, NOT_PAUSED)

		local snapshot = tracker.get_active_app_snapshot()
		helpers.assert_eq(snapshot.app, "Code")
		helpers.assert_eq(snapshot.duration_ms, 6250)
	end)

	helpers.it("does not invent an interval without a tracked foreground application", function()
		local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker", {
			timer = { absoluteTime = function() return 7250000000 end },
		})
		tracker.init({}, {}, NOT_PAUSED)
		helpers.assert_eq(tracker.get_active_app_snapshot(), nil)
	end)

	helpers.it("closes a running interval without inventing a destination app", function()
		local recorded = {}
		local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker", {
			timer = { absoluteTime = function() return 7250000000 end },
		})
		local state = { active_app_name = "Code", active_app_start = 1000 }
		tracker.init(state, {
			log_app_switch = function(prev_app, next_app, duration_ms, timestamp)
				recorded = { prev_app, next_app, duration_ms, timestamp }
			end,
		}, NOT_PAUSED)

		helpers.assert_true(tracker.close_active_app())
		helpers.assert_eq(recorded[1], "Code")
		helpers.assert_eq(recorded[2], nil)
		helpers.assert_eq(recorded[3], 6250)
		helpers.assert_eq(state.active_app_name, nil)
	end)

	helpers.it("credits a cross-midnight interval to the previous day and continues tracking", function()
		local recorded = {}
		local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker", {
			timer = { absoluteTime = function() return 8000000000 end },
		})
		local state = { active_app_name = "Code", active_app_start = 1000 }
		tracker.init(state, {
			log_app_switch = function(prev_app, next_app, duration_ms, timestamp)
				recorded = { prev_app, next_app, duration_ms, timestamp }
			end,
		}, NOT_PAUSED)

		local real_date = os.date
		local ok, err = pcall(function()
			os.date = function(format)
				if format == "*t" then return { hour = 0, min = 0, sec = 5 } end
				return real_date(format)
			end
			helpers.assert_true(tracker.split_active_app_at_midnight("2026-07-17"))
			helpers.assert_eq(recorded[1], "Code")
			helpers.assert_eq(recorded[2], nil)
			helpers.assert_eq(recorded[3], 2000)
			helpers.assert_eq(recorded[4], "2026-07-17 23:59:59.999")
		helpers.assert_eq(state.active_app_start, 3000)
		end)
		os.date = real_date
		if not ok then error(err) end
	end)

	helpers.it("uses the application display name when priming the foreground context", function()
		local tracker = helpers.load_with_stubs("modules.keylogger.context_tracker", {
			timer = { absoluteTime = function() return 7250000000 end },
			axuielement = { observer = { new = function() return nil end } },
			application = {
				watcher = { activated = 1 },
				frontmostApplication = function()
					return {
						name = function() return "Terminal" end,
						bundleID = function() return "com.apple.Terminal" end,
						path = function() return "/System/Applications/Utilities/Terminal.app" end,
						pid = function() return 42 end,
					}
				end,
			},
		})
		local state = {}
		tracker.init(state, {}, NOT_PAUSED)

		helpers.assert_true(tracker.capture_frontmost_app())
		helpers.assert_eq(state.active_app_name, "Terminal")
		helpers.assert_eq(state.active_app_start, 7250)
	end)
end)
