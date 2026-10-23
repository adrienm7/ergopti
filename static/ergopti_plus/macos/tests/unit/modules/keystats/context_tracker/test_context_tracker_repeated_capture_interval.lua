--- tests/unit/modules/keystats/context_tracker/test_context_tracker_repeated_capture_interval.lua

--- ==============================================================================
--- MODULE: Repeated Foreground Capture Interval Regression
--- DESCRIPTION:
--- Event-tap recovery recaptures the current app through the public tracker API.
--- Refreshing its native metadata must preserve the unpersisted focus interval.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Drives real context writers with deterministic native app and clock ports.
--- @param callback function Receives tracker, state, native controls and emitted rows.
local function with_capture(callback)
	return helpers.with_stub_scope({ "modules.keystats.context_tracker",
		"adapters.secure_field_detector", "infra.logger", "keystats.private_window" }, function()
		local native = { now = 1000, name = "Editor", bundle = "test.editor", path = "/Editor.app",
			pid = 42, title = "Document", secure = false, available = true }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.secure_field_detector"] = {
			refresh = function() end,
			isSecureField = function() return native.secure end,
			isSecureApp = function() return false end,
		}
		local app = {
			name = function() return native.name end,
			bundleID = function() return native.bundle end,
			path = function() return native.path end,
			pid = function() return native.pid end,
		}
		local tracker = helpers.load_with_stubs("modules.keystats.context_tracker", {
			timer = { absoluteTime = function() return native.now * 1000000 end },
			application = { watcher = { activated = 1 },
				frontmostApplication = function() if native.available then return app end end },
			window = { focusedWindow = function() return {
				title = function() return native.title end,
				isFullScreen = function() return false end,
			} end },
			axuielement = { observer = { new = function() return nil end },
				windowElement = function() return nil end },
		})
		local state = {}
		local rows, flushes = {}, 0
		local log_manager = {
			flush_buffer = function() flushes = flushes + 1 end,
			append_log = function() end,
			log_app_switch = function(previous, next_app, duration)
				rows[#rows + 1] = { previous = previous, next_app = next_app, duration = duration }
			end,
		}
		helpers.assert_true(tracker.init(state, log_manager, function() return false end))
		-- Establish the healthy interval through the same public capture used by recovery.
		helpers.assert_true(tracker.capture_frontmost_app())
		helpers.assert_eq(tracker.get_active_app_snapshot().duration_ms, 0)
		helpers.assert_eq(#rows, 0)
		native.now = 9000
		return callback(tracker, state, native, rows, function() return flushes end)
	end)
end

helpers.describe("foreground interval survives recovery captures", function()
	helpers.it("(repeated-capture-interval) keeps live duration after the same app is recaptured", function()
		with_capture(function(tracker, state, native, rows, flushes)
			helpers.assert_eq(tracker.get_active_app_snapshot().duration_ms, 8000)
			helpers.assert_true(tracker.capture_frontmost_app())
			native.now = 11000
			helpers.assert_eq(tracker.get_active_app_snapshot().duration_ms, 10000)
			helpers.assert_eq(state.active_app_start, 1000)
			helpers.assert_eq(#rows, 0)
			helpers.assert_eq(flushes(), 0)
		end)
	end)

	helpers.it("(repeated-capture-interval) closes the complete interval after recovery", function()
		with_capture(function(tracker, _, native, rows)
			helpers.assert_true(tracker.capture_frontmost_app())
			native.now = 11000
			helpers.assert_true(tracker.close_active_app())
			helpers.assert_eq(#rows, 1)
			helpers.assert_eq(rows[1], { previous = "Editor", duration = 10000 })
		end)
	end)

	helpers.it("(repeated-capture-interval) credits the complete interval on the next real switch", function()
		with_capture(function(tracker, state, native, rows, flushes)
			helpers.assert_true(tracker.capture_frontmost_app())
			native.now, native.name = 11000, "Terminal"
			helpers.assert_true(tracker.capture_frontmost_app())
			helpers.assert_eq(rows[1], { previous = "Editor", next_app = "Terminal", duration = 10000 })
			helpers.assert_eq(flushes(), 1)
			helpers.assert_eq(state.active_app_start, 11000)
			helpers.assert_eq(state.focus_pending_at, 11000)
			helpers.assert_eq(state.focus_pending_app, "Terminal")
			native.now = 12000
			helpers.assert_eq(tracker.get_active_app_snapshot().duration_ms, 1000)
		end)
	end)

	helpers.it("(repeated-capture-interval) retains time across several watchdog recoveries", function()
		with_capture(function(tracker, _, native, rows)
			for _, instant in ipairs({ 4000, 7000, 9000 }) do
				native.now = instant
				helpers.assert_true(tracker.capture_frontmost_app())
			end
			native.now = 11000
			helpers.assert_true(tracker.close_active_app())
			helpers.assert_eq(#rows, 1)
			helpers.assert_eq(rows[1].duration, 10000)
		end)
	end)

	helpers.it("(repeated-capture-interval) still refreshes metadata and privacy for the same app", function()
		with_capture(function(tracker, state, native)
			native.bundle, native.path, native.title = "test.refreshed", "/Updated Editor.app", "New Document"
			native.secure = true
			helpers.assert_true(tracker.capture_frontmost_app())
			helpers.assert_eq(state.active_app_bundle, native.bundle)
			helpers.assert_eq(state.active_app_path, native.path)
			helpers.assert_eq(state.active_app_pid, 42)
			helpers.assert_eq(state.active_win_title, native.title)
			helpers.assert_eq(state.is_secure_field, true)
			helpers.assert_eq(state.active_app_start, 1000)
		end)
	end)

	helpers.it("(repeated-capture-interval) starts a missing same-app interval at the current clock", function()
		with_capture(function(tracker, state, native, rows)
			state.active_app_start = nil
			helpers.assert_true(tracker.capture_frontmost_app())
			helpers.assert_eq(state.active_app_start, native.now)
			helpers.assert_eq(tracker.get_active_app_snapshot().duration_ms, 0)
			helpers.assert_eq(#rows, 0)
		end)
	end)

	helpers.it("(repeated-capture-interval) leaves the interval unchanged when no app can be read", function()
		with_capture(function(tracker, state, native, rows)
			native.available = false
			helpers.assert_eq(tracker.capture_frontmost_app(), false)
			helpers.assert_eq(state.active_app_start, 1000)
			helpers.assert_eq(tracker.get_active_app_snapshot().duration_ms, 8000)
			helpers.assert_eq(#rows, 0)
		end)
	end)

	helpers.it("(repeated-capture-interval) preserves an outstanding first-key measurement", function()
		with_capture(function(tracker, state)
			state.focus_pending_at, state.focus_pending_app = 1000, "Editor"
			helpers.assert_true(tracker.capture_frontmost_app())
			helpers.assert_eq(state.focus_pending_at, 1000)
			helpers.assert_eq(state.focus_pending_app, "Editor")
		end)
	end)

	helpers.it("(repeated-capture-interval) does not rearm a first-key sample already consumed", function()
		with_capture(function(tracker, state)
			state.focus_pending_at, state.focus_pending_app = nil, nil
			helpers.assert_true(tracker.capture_frontmost_app())
			helpers.assert_eq(state.focus_pending_at, nil)
			helpers.assert_eq(state.focus_pending_app, nil)
		end)
	end)

	helpers.it("(repeated-capture-interval) arms both clocks when the previous interval was closed", function()
		with_capture(function(tracker, state, native, rows)
			helpers.assert_true(tracker.close_active_app())
			helpers.assert_eq(rows[1].duration, 8000)
			native.now = 11000
			helpers.assert_true(tracker.capture_frontmost_app())
			helpers.assert_eq(state.active_app_start, 11000)
			helpers.assert_eq(state.focus_pending_at, 11000)
			helpers.assert_eq(state.focus_pending_app, "Editor")
		end)
	end)

end)
